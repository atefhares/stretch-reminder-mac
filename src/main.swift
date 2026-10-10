// StretchReminder — a small background agent for macOS.
//
// Every N minutes of sitting at the Mac it covers every screen with a big
// Arabic "get up and move" message. It never closes or quits any app; it only
// sends a "pause" command to whatever is playing.
//
// It stays quiet when:
//   * a Focus / Do Not Disturb mode is on
//   * the screen is locked, the display is asleep, or the Mac is asleep
//   * the microphone or the camera is in use (call / meeting / recording)
//
// Settings (optional), then restart the agent:
//   defaults write local.stretch-reminder intervalMinutes -float 30
//   defaults write local.stretch-reminder breakSeconds -float 60
//   defaults write local.stretch-reminder dismissAfterSeconds -float 5
//   defaults write local.stretch-reminder message -string "..."
//   defaults write local.stretch-reminder checkFocusSchedules -bool false
//   defaults write local.stretch-reminder turnOffOnLock -bool false
//   defaults write local.stretch-reminder showCountdownInMenuBar -bool false
//
// It shows an icon in the menu bar: green = on, gray = off. The menu turns it
// on or off, shows a reminder now, switches "Start at login", and quits.
// Like Caffeine, it switches itself OFF when the screen locks or the Mac
// sleeps, and stays off until you turn it on again (this can be unticked in
// the menu).
//
// Flags:  --test           show the screen once right now, then exit
//         --status         print what the detectors currently see, then exit
//         --enable-login   write the start-at-login entry, then exit
//         --disable-login  remove the start-at-login entry, then exit

import AppKit
import CoreAudio
import CoreGraphics
import CoreMediaIO
import Foundation

// MARK: - Settings

enum Config {
    static func number(_ key: String, default fallback: Double, allowZero: Bool = false) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        let value = UserDefaults.standard.double(forKey: key)
        if value > 0 { return value }
        return (allowZero && value == 0) ? 0 : fallback
    }

    /// Sitting time before a reminder.
    static var interval: TimeInterval { number("intervalMinutes", default: 30) * 60 }
    /// How long the screen stays up before it closes by itself.
    static var breakSeconds: TimeInterval { number("breakSeconds", default: 60) }
    /// How long before the "done" button / Esc key starts working.
    static var dismissAfter: TimeInterval { number("dismissAfterSeconds", default: 5, allowZero: true) }
    /// The big message.
    static let defaultMessage = "انت قاعد بقالك كتير قوم حرك جسمك"
    static var message: String {
        let saved = UserDefaults.standard.string(forKey: "message") ?? ""
        return saved.isEmpty ? defaultMessage : saved
    }
    /// The owner shown in the About window (written into the app by the installer).
    static var owner: String {
        return Bundle.main.object(forInfoDictionaryKey: "StretchReminderOwner") as? String ?? ""
    }
    /// Also treat a Focus *schedule* window as "Focus on".
    static var checkFocusSchedules: Bool {
        guard UserDefaults.standard.object(forKey: "checkFocusSchedules") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "checkFocusSchedules")
    }
    /// Show the time left until the next reminder next to the menu bar icon.
    static var showCountdownInMenuBar: Bool {
        guard UserDefaults.standard.object(forKey: "showCountdownInMenuBar") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "showCountdownInMenuBar")
    }
    /// Switch off when the screen locks or the Mac sleeps, until turned on again by hand.
    static var turnOffOnLock: Bool {
        guard UserDefaults.standard.object(forKey: "turnOffOnLock") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "turnOffOnLock")
    }

    /// Locked / display-off for at least this long counts as a real break.
    static let minimumBreakSeconds: TimeInterval = 120
    /// No keyboard/mouse input for this long (and nothing playing) counts as "away".
    static let idleAwaySeconds: TimeInterval = 300
    /// When a reminder is due but postponed, look again this often.
    static let recheckSeconds: TimeInterval = 60
    static let tickSeconds: TimeInterval = 1

    static let pauseScript = """
    ObjC.import('Foundation');
    function run() {
      const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
      framework.load;
      const Controller = $.NSClassFromString('MRNowPlayingController');
      const controller = Controller.localRouteController;
      controller.sendCommandOptionsCompletion(1, $.NSDictionary.alloc.init, null);
      delay(0.5);
      return 'pause sent';
    }
    """
}

// MARK: - Logging

func note(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date()))  \(message)\n"
    let path = NSHomeDirectory() + "/Library/Logs/StretchReminder.log"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        _ = FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
    }
}

func trimLogIfLarge() {
    let path = NSHomeDirectory() + "/Library/Logs/StretchReminder.log"
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber, size.intValue > 512 * 1024 else { return }
    try? FileManager.default.removeItem(atPath: path)
}

// MARK: - Core Audio helpers (raw four-character codes, so this builds on any SDK)

func fourCC(_ text: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in text.utf8 { result = (result << 8) | UInt32(byte) }
    return result
}

func audioObjectList(_ object: AudioObjectID, _ selector: String, scope: String = "glob") -> [AudioObjectID]? {
    var address = AudioObjectPropertyAddress(mSelector: fourCC(selector), mScope: fourCC(scope), mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == 0 else { return nil }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    if count == 0 { return [] }
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == 0 else { return nil }
    let returned = Int(size) / MemoryLayout<AudioObjectID>.size
    return Array(ids.prefix(returned))
}

func audioNumber(_ object: AudioObjectID, _ selector: String, scope: String = "glob") -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: fourCC(selector), mScope: fourCC(scope), mElement: 0)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == 0 else { return nil }
    return value
}

func audioString(_ object: AudioObjectID, _ selector: String) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: fourCC(selector), mScope: fourCC("glob"), mElement: 0)
    var reference: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &reference) { pointer -> OSStatus in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
    }
    guard status == 0, let value = reference else { return nil }
    let text = value.takeRetainedValue() as String
    return text.isEmpty ? nil : text
}

enum AudioSystem {
    static let object: AudioObjectID = 1
}

// MARK: - Detectors

/// Returns the app holding the microphone open, or nil when nobody is.
func microphoneUser() -> String? {
    // macOS 14.2+: ask per process whether it is capturing input ('prs#', 'piri', 'ppid', 'pbid').
    if let processes = audioObjectList(AudioSystem.object, "prs#") {
        let ownPID = UInt32(bitPattern: getpid())
        for process in processes {
            guard let running = audioNumber(process, "piri"), running != 0 else { continue }
            let pid = audioNumber(process, "ppid")
            if pid == ownPID { continue }
            let bundle = audioString(process, "pbid")
            if let bundle = bundle {
                // System voice-trigger daemons are not a call.
                let lowered = bundle.lowercased()
                if lowered.contains("corespeech") || lowered.contains("voicetrigger") || lowered.contains("com.apple.siri") {
                    continue
                }
                return bundle
            }
            if let pid = pid { return "process \(pid)" }
            return "an unknown process"
        }
        return nil
    }
    // Older macOS: any device that has input streams and is running somewhere.
    for device in audioObjectList(AudioSystem.object, "dev#") ?? [] {
        let inputStreams = audioObjectList(device, "stm#", scope: "inpt") ?? []
        if inputStreams.isEmpty { continue }
        if let running = audioNumber(device, "gone"), running != 0 { return "an input device" }
    }
    return nil
}

/// True when something has the default output device running (music, video, call audio).
func audioOutputActive() -> Bool {
    guard let device = audioNumber(AudioSystem.object, "dOut"), device != 0 else { return false }
    guard let running = audioNumber(device, "gone") else { return false }
    return running != 0
}

/// True when any camera is in use by any app.
func cameraInUse() -> Bool {
    let systemObject = CMIOObjectID(1)
    var address = CMIOObjectPropertyAddress(mSelector: fourCC("dev#"), mScope: fourCC("glob"), mElement: 0)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == 0, size > 0 else { return false }
    let count = Int(size) / MemoryLayout<CMIOObjectID>.size
    var devices = [CMIOObjectID](repeating: 0, count: count)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(systemObject, &address, 0, nil, size, &used, &devices) == 0 else { return false }
    let returned = min(count, Int(used) / MemoryLayout<CMIOObjectID>.size)
    for device in devices.prefix(returned) {
        var runningAddress = CMIOObjectPropertyAddress(mSelector: fourCC("gone"), mScope: fourCC("glob"), mElement: 0)
        var running: UInt32 = 0
        var runningUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &runningAddress, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &runningUsed, &running)
        if status == 0 && running != 0 { return true }
    }
    return false
}

func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let locked = session["CGSSessionScreenIsLocked"] as? NSNumber, locked.boolValue { return true }
    if let onConsole = session["kCGSSessionOnConsoleKey"] as? NSNumber, !onConsole.boolValue { return true }
    return false
}

func displayIsAsleep() -> Bool {
    return CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

func secondsSinceLastInput() -> TimeInterval {
    let anyInput = CGEventType(rawValue: ~0) ?? .mouseMoved
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
}

// MARK: - Focus / Do Not Disturb

enum FocusState {
    case off
    case on(String)
    case unknown(String)
}

func readJSONFile(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
    return object as? [String: Any]
}

func focusModeName(_ identifier: String, configurations: [String: Any]?) -> String {
    if identifier == "com.apple.donotdisturb.mode.default" { return "Do Not Disturb" }
    let entries = configurations?["data"] as? [[String: Any]] ?? []
    for entry in entries {
        let modes = entry["modeConfigurations"] as? [String: Any] ?? [:]
        if let config = modes[identifier] as? [String: Any],
           let mode = config["mode"] as? [String: Any],
           let name = mode["name"] as? String {
            return name
        }
    }
    return identifier
}

/// Reads the system Focus database. This needs Full Disk Access for this app.
func currentFocus() -> FocusState {
    let directory = NSHomeDirectory() + "/Library/DoNotDisturb/DB/"
    guard let assertions = readJSONFile(directory + "Assertions.json") else {
        return .unknown("cannot read the Focus database — give StretchReminder Full Disk Access")
    }
    let configurations = readJSONFile(directory + "ModeConfigurations.json")

    // A Focus that is on right now.
    for entry in assertions["data"] as? [[String: Any]] ?? [] {
        let records = entry["storeAssertionRecords"] as? [[String: Any]] ?? []
        if let record = records.last {
            let details = record["assertionDetails"] as? [String: Any]
            let identifier = details?["assertionDetailsModeIdentifier"] as? String ?? "a Focus mode"
            return .on(focusModeName(identifier, configurations: configurations))
        }
    }

    // A Focus that is on because of its time schedule.
    if Config.checkFocusSchedules, let configurations = configurations {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        for entry in configurations["data"] as? [[String: Any]] ?? [] {
            let modes = entry["modeConfigurations"] as? [String: Any] ?? [:]
            for (identifier, value) in modes {
                guard let config = value as? [String: Any],
                      let triggerBox = config["triggers"] as? [String: Any],
                      let triggers = triggerBox["triggers"] as? [[String: Any]] else { continue }
                for trigger in triggers {
                    guard let enabled = trigger["enabledSetting"] as? Int, enabled == 2,
                          let startHour = trigger["timePeriodStartTimeHour"] as? Int,
                          let startMinute = trigger["timePeriodStartTimeMinute"] as? Int,
                          let endHour = trigger["timePeriodEndTimeHour"] as? Int,
                          let endMinute = trigger["timePeriodEndTimeMinute"] as? Int else { continue }
                    let start = startHour * 60 + startMinute
                    let end = endHour * 60 + endMinute
                    var inside = false
                    if start < end {
                        inside = now >= start && now < end
                    } else if start > end {
                        inside = now >= start || now < end
                    }
                    if inside {
                        return .on(focusModeName(identifier, configurations: configurations) + " (schedule)")
                    }
                }
            }
        }
    }
    return .off
}

/// "com.brave.Browser.helper" -> "Brave Browser". Falls back to the identifier itself.
func appDisplayName(_ bundleID: String) -> String {
    var candidate = bundleID
    if let helper = bundleID.range(of: ".helper", options: [.caseInsensitive]) {
        candidate = String(bundleID[..<helper.lowerBound])
    }
    for _ in 0..<4 {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            if !name.isEmpty { return name }
        }
        guard let dot = candidate.lastIndex(of: ".") else { break }
        candidate = String(candidate[..<dot])
        if !candidate.contains(".") { break }
    }
    return bundleID
}

/// One plain sentence for the menu: what is being detected right now and what it means.
func friendlyWaitLine() -> String? {
    if let app = microphoneUser() {
        return "In a call (\(appDisplayName(app))) — the reminder will wait until it ends"
    }
    if cameraInUse() {
        return "Camera is on — the reminder will wait until it is off"
    }
    if case .on(let mode) = currentFocus() {
        return "Focus is on (\(mode)) — the reminder will wait until it is off"
    }
    return nil
}

/// Why a due reminder should wait, or nil when it is fine to show it.
func postponeReason() -> String? {
    if let app = microphoneUser() { return "microphone in use by \(appDisplayName(app)) (call / meeting)" }
    if cameraInUse() { return "camera in use (call / meeting)" }
    if case .on(let mode) = currentFocus() { return "Focus is on: \(mode)" }
    return nil
}

/// Runs a small command-line tool and returns what it printed (nil on failure or timeout).
func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning && Date() < deadline {
        usleep(20_000)
    }
    if task.isRunning {
        task.terminate()
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

/// One log line describing everything the detectors see right now (for troubleshooting).
func detectorSnapshot() -> String {
    var parts: [String] = []
    parts.append("mic=" + (microphoneUser() ?? "free"))
    parts.append("camera=" + (cameraInUse() ? "in use" : "free"))
    switch currentFocus() {
    case .off: parts.append("focus=off")
    case .on(let mode): parts.append("focus=on(" + mode + ")")
    case .unknown: parts.append("focus=unreadable")
    }

    // Every app that has audio running, and in which direction.
    var clients: [String] = []
    for process in audioObjectList(AudioSystem.object, "prs#") ?? [] {
        let input = (audioNumber(process, "piri") ?? 0) != 0
        let output = (audioNumber(process, "piro") ?? 0) != 0
        if !input && !output { continue }
        var name = audioString(process, "pbid") ?? ""
        if name.isEmpty { name = "pid " + String(audioNumber(process, "ppid") ?? 0) }
        var direction = ""
        if input && output {
            direction = "in+out"
        } else if input {
            direction = "in"
        } else {
            direction = "out"
        }
        clients.append(name + "[" + direction + "]")
    }
    parts.append("audio=" + (clients.isEmpty ? "none" : clients.joined(separator: ", ")))

    // What apps told macOS they are doing (calls and playback keep the Mac awake).
    var assertions: [String] = []
    if let output = runTool("/usr/bin/pmset", ["-g", "assertions"], timeout: 2) {
        for rawLine in output.components(separatedBy: "\n") {
            guard rawLine.contains("named:") else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            assertions.append(String(line.prefix(170)))
            if assertions.count >= 25 { break }
        }
    }
    parts.append("assertions=" + (assertions.isEmpty ? "none" : assertions.joined(separator: " | ")))
    return parts.joined(separator: "; ")
}

func printStatus() {
    func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
    switch currentFocus() {
    case .off: print("Focus / Do Not Disturb : off")
    case .on(let mode): print("Focus / Do Not Disturb : ON (\(mode))")
    case .unknown(let why): print("Focus / Do Not Disturb : UNKNOWN — \(why)")
    }
    if let app = microphoneUser() {
        print("Microphone in use      : yes (\(app))")
    } else {
        print("Microphone in use      : no")
    }
    print("Camera in use          : \(yesNo(cameraInUse()))")
    print("Screen locked          : \(yesNo(screenIsLocked()))")
    print("Display asleep         : \(yesNo(displayIsAsleep()))")
    print("Something is playing   : \(yesNo(audioOutputActive()))")
    print("Seconds since input    : \(Int(secondsSinceLastInput()))")
    print("Reminder every         : \(Int(Config.interval / 60)) min, screen stays \(Int(Config.breakSeconds)) s")
    if let reason = postponeReason() {
        print("A reminder right now   : would be postponed (\(reason))")
    } else {
        print("A reminder right now   : would be shown")
    }
}

// MARK: - Start at login (a LaunchAgent in the user's Library)

enum LoginItem {
    static let label = "local.stretch-reminder"

    static var plistPath: String {
        return NSHomeDirectory() + "/Library/LaunchAgents/" + label + ".plist"
    }

    static var isEnabled: Bool {
        return FileManager.default.fileExists(atPath: plistPath)
    }

    /// Start at every login, and restart only if it crashes (so Quit really quits).
    static func enable() -> Bool {
        guard let executable = Bundle.main.executablePath else { return false }
        let keepAlive: [String: Any] = ["SuccessfulExit": false]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": keepAlive,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardErrorPath": NSHomeDirectory() + "/Library/Logs/StretchReminder.stderr.log"
        ]
        let directory = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return false
        }
        return FileManager.default.createFile(atPath: plistPath, contents: data, attributes: nil)
    }

    static func disable() {
        try? FileManager.default.removeItem(atPath: plistPath)
    }
}

/// Only one background copy may run. Returns false when another one already holds the lock.
func acquireSingleInstanceLock() -> Bool {
    let directory = NSHomeDirectory() + "/Library/Caches"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
    let descriptor = open(directory + "/local.stretch-reminder.lock", O_CREAT | O_RDWR, 0o600)
    if descriptor < 0 { return true } // cannot check; carry on
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        close(descriptor)
        return false
    }
    return true // the descriptor stays open (and locked) for the life of the process
}

// MARK: - The blocking window

final class OverlayWindow: NSWindow {
    weak var controller: AppDelegate?

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func keyDown(with event: NSEvent) {
        // Esc, Return, keypad Enter, Space close it (once allowed); everything else is swallowed.
        let closingKeys: [UInt16] = [53, 36, 76, 49]
        if closingKeys.contains(event.keyCode) {
            controller?.dismissPressed()
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let testMode: Bool

    private var sitting: TimeInterval = 0
    private var lastTick = Date()
    private var awaySince: Date?
    private var nextEvaluation = Date.distantPast
    private var lastPostponeReason = ""
    private var focusWarningLogged = false

    private var windows: [OverlayWindow] = []
    private var countdownLabels: [NSTextField] = []
    private var buttons: [NSButton] = []
    private var shownAt = Date()
    private var previousApp: NSRunningApplication?

    private var tickTimer: Timer?
    private var countdownTimer: Timer?
    private var pauseTask: Process?
    private var activity: NSObjectProtocol?

    private var pausedUntil: Date?
    private var statusItem: NSStatusItem?
    private var shownSymbol = ""
    private var stateMenuItem: NSMenuItem?
    private var nowMenuItem: NSMenuItem?
    private var focusWarningItem: NSMenuItem?
    private var pauseHourItem: NSMenuItem?
    private var pauseOpenItem: NSMenuItem?
    private var resumeItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var lockOffMenuItem: NSMenuItem?
    private var countdownMenuItem: NSMenuItem?

    init(testMode: Bool) {
        self.testMode = testMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if testMode {
            perform(#selector(showTestOverlay), with: nil, afterDelay: 0.5)
            return
        }

        trimLogIfLarge()
        // Keep App Nap from stretching the timer while nothing of ours is on screen.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Counting sitting time for the stretch reminder")

        note("Started. Reminder after \(Int(Config.interval / 60)) min of sitting; screen stays \(Int(Config.breakSeconds)) s.")
        switch currentFocus() {
        case .unknown(let why):
            note("focus-detection: blocked — \(why)")
        case .on(let mode):
            note("focus-detection: ok (Focus is on: \(mode))")
        case .off:
            note("focus-detection: ok (no Focus on)")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)

        installEditMenu()
        setUpStatusItem()

        lastTick = Date()
        let timer = Timer(timeInterval: Config.tickSeconds, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: Menu bar icon

    @discardableResult
    private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let state = NSMenuItem(title: "StretchReminder", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        stateMenuItem = state
        let nowLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        nowLine.isEnabled = false
        nowLine.isHidden = true
        menu.addItem(nowLine)
        nowMenuItem = nowLine
        focusWarningItem = addMenuItem(menu, "Focus is not detected — open Full Disk Access…", #selector(openFullDiskAccess))

        menu.addItem(NSMenuItem.separator())
        resumeItem = addMenuItem(menu, "Turn on", #selector(resumeReminders))
        pauseOpenItem = addMenuItem(menu, "Turn off", #selector(pauseIndefinitely))
        pauseHourItem = addMenuItem(menu, "Turn off for 1 hour", #selector(pauseOneHour))
        addMenuItem(menu, "Show reminder now", #selector(showNow))
        addMenuItem(menu, "Change reminder message…", #selector(changeMessage))

        menu.addItem(NSMenuItem.separator())
        loginMenuItem = addMenuItem(menu, "Start at login", #selector(toggleStartAtLogin))
        lockOffMenuItem = addMenuItem(menu, "Turn off when the Mac locks or sleeps", #selector(toggleTurnOffOnLock))
        countdownMenuItem = addMenuItem(menu, "Show countdown in menu bar", #selector(toggleCountdownInMenuBar))
        addMenuItem(menu, "Open log", #selector(openLog))

        menu.addItem(NSMenuItem.separator())
        addMenuItem(menu, "About StretchReminder", #selector(showAbout))
        addMenuItem(menu, "Uninstall StretchReminder…", #selector(uninstallApp))
        addMenuItem(menu, "Quit StretchReminder", #selector(quitApp))

        // Digits of equal width, so the countdown does not make the icon jump around.
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.menu = menu
        statusItem = item
        refreshStatusItem(checkFocus: true)
    }

    /// Walking figure: green when reminders are on, system gray when they are off.
    private func statusImage(active: Bool) -> NSImage? {
        guard #available(macOS 11.0, *) else { return nil }
        guard let base = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "StretchReminder") else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let symbol = base.withSymbolConfiguration(configuration) ?? base
        if !active {
            // A template image shown "disabled" is the standard dimmed gray of the menu bar.
            symbol.isTemplate = true
            return symbol
        }
        let green = NSColor.systemGreen
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            green.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private func refreshStatusItem(checkFocus: Bool) {
        guard let item = statusItem else { return }
        let active = pausedUntil == nil
        var text = ""
        var barText = ""
        if let until = pausedUntil {
            if until == Date.distantFuture {
                text = "Off — choose Turn on to start again"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                text = "Off until \(formatter.string(from: until))"
            }
        } else if !windows.isEmpty {
            text = "On — the reminder is on screen"
        } else if sitting >= Config.interval && !lastPostponeReason.isEmpty {
            text = "On — a reminder is due and waiting"
            barText = "wait"
        } else {
            let remaining = max(0, Int((Config.interval - sitting).rounded(.up)))
            let clock = String(format: "%d:%02d", remaining / 60, remaining % 60)
            text = "On — next reminder in \(clock)"
            barText = clock
        }

        stateMenuItem?.title = text
        if !Config.showCountdownInMenuBar { barText = "" }
        let lookKey = active ? "on" : "off"
        if let button = item.button {
            if lookKey != shownSymbol {
                button.image = statusImage(active: active)
                button.appearsDisabled = !active
                shownSymbol = lookKey
            }
            var title = ""
            if button.image == nil {
                // No symbol available on this macOS: fall back to words.
                title = active ? "Stretch" : "Stretch (off)"
                if !barText.isEmpty { title += " " + barText }
            } else if !barText.isEmpty {
                title = " " + barText
            }
            if button.title != title { button.title = title }
            let position: NSControl.ImagePosition = title.isEmpty ? .imageOnly : .imageLeading
            if button.imagePosition != position { button.imagePosition = position }
        }
        item.button?.toolTip = "StretchReminder: \(text)"

        pauseHourItem?.isHidden = !active
        pauseOpenItem?.isHidden = !active
        resumeItem?.isHidden = active
        loginMenuItem?.state = LoginItem.isEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        lockOffMenuItem?.state = Config.turnOffOnLock ? NSControl.StateValue.on : NSControl.StateValue.off
        countdownMenuItem?.state = Config.showCountdownInMenuBar ? NSControl.StateValue.on : NSControl.StateValue.off

        if checkFocus {
            var blocked = false
            if case .unknown = currentFocus() { blocked = true }
            focusWarningItem?.isHidden = !blocked

            // Tell at a glance whether a call / Focus is being seen right now.
            if active, let line = friendlyWaitLine() {
                nowMenuItem?.title = line
                nowMenuItem?.isHidden = false
            } else {
                nowMenuItem?.isHidden = true
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatusItem(checkFocus: true)
    }

    @objc private func showNow() {
        note("Show reminder now: " + detectorSnapshot())
        guard let reason = postponeReason() else {
            showOverlay()
            return
        }
        // Same rule as a real reminder: not during a call or a Focus.
        note("Show reminder now: not shown (\(reason)).")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No reminder right now"
        alert.informativeText = "Reminders are waiting because: \(reason).\n\nThe reminder shows by itself within a minute after that ends."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show it anyway")
        if alert.runModal() == .alertSecondButtonReturn {
            showOverlay()
        }
    }

    private func pauseReminders(until: Date, label: String) {
        pausedUntil = until
        sitting = 0
        lastPostponeReason = ""
        note("Turned off from the menu (\(label)).")
        refreshStatusItem(checkFocus: false)
    }

    @objc private func pauseOneHour() {
        pauseReminders(until: Date().addingTimeInterval(3600), label: "for 1 hour")
    }

    @objc private func pauseIndefinitely() {
        pauseReminders(until: Date.distantFuture, label: "until turned on again")
    }

    @objc private func resumeReminders() {
        pausedUntil = nil
        note("Turned on from the menu.")
        refreshStatusItem(checkFocus: false)
    }

    @objc private func toggleStartAtLogin() {
        if LoginItem.isEnabled {
            LoginItem.disable()
            note("Start at login turned off.")
        } else if LoginItem.enable() {
            note("Start at login turned on.")
        } else {
            note("Could not turn on start at login.")
        }
        refreshStatusItem(checkFocus: false)
    }

    /// Without an Edit menu, Cmd-V / Cmd-C / Cmd-A do nothing in the message box.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func changeMessage() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Reminder message"
        alert.informativeText = "This text is shown in big letters on the reminder screen."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = Config.message
        field.placeholderString = Config.defaultMessage
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use the original")
        alert.window.initialFirstResponder = field

        let answer = alert.runModal()
        if answer == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == Config.defaultMessage {
                UserDefaults.standard.removeObject(forKey: "message")
            } else {
                UserDefaults.standard.set(text, forKey: "message")
            }
            note("Reminder message changed.")
        } else if answer == .alertThirdButtonReturn {
            UserDefaults.standard.removeObject(forKey: "message")
            note("Reminder message set back to the original.")
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var lines = "Reminds you to get up and move."
        if !Config.owner.isEmpty { lines += "\nOwner: " + Config.owner }
        let credits = NSAttributedString(string: lines, attributes: [
            NSAttributedString.Key.paragraphStyle: paragraph,
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12),
            NSAttributedString.Key.foregroundColor: NSColor.labelColor
        ])
        NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
    }

    @objc private func toggleCountdownInMenuBar() {
        UserDefaults.standard.set(!Config.showCountdownInMenuBar, forKey: "showCountdownInMenuBar")
        refreshStatusItem(checkFocus: false)
    }

    @objc private func toggleTurnOffOnLock() {
        let newValue = !Config.turnOffOnLock
        UserDefaults.standard.set(newValue, forKey: "turnOffOnLock")
        note("Turn off when the Mac locks or sleeps: \(newValue ? "yes" : "no").")
        refreshStatusItem(checkFocus: false)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/StretchReminder.log"))
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        note("Quit from the menu.")
        NSApp.terminate(nil)
    }

    @objc private func uninstallApp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Uninstall StretchReminder?"
        alert.informativeText = "This stops the reminders, removes the start-at-login entry and moves the app to the Trash."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        LoginItem.disable()
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        note("Uninstalled from the menu.")
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            try? FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        }
        NSApp.terminate(nil)
    }

    @objc private func showTestOverlay() {
        showOverlay()
    }

    @objc private func systemWillSleep() {
        hideOverlay(completed: false, why: "the Mac is going to sleep")
        turnOffBecauseAway("the Mac went to sleep")
    }

    @objc private func screenDidLock() {
        hideOverlay(completed: false, why: "screen locked")
        turnOffBecauseAway("the screen was locked")
    }

    /// Caffeine-style: locking or sleeping switches reminders off until turned on by hand.
    private func turnOffBecauseAway(_ why: String) {
        guard Config.turnOffOnLock else { return }
        if let until = pausedUntil, until == Date.distantFuture { return }
        pausedUntil = Date.distantFuture
        sitting = 0
        lastPostponeReason = ""
        note("Turned off automatically (\(why)). Turn it on again from the menu bar icon.")
        refreshStatusItem(checkFocus: false)
    }

    // MARK: Sitting timer

    private func resetSitting(_ why: String) {
        if sitting > 0 {
            note("Sitting timer reset (\(why)) after \(Int(sitting / 60)) min.")
        }
        sitting = 0
        nextEvaluation = Date.distantPast
        lastPostponeReason = ""
    }

    @objc private func tick() {
        defer { refreshStatusItem(checkFocus: false) }
        let now = Date()
        let delta = now.timeIntervalSince(lastTick)
        lastTick = now

        // The timer did not fire for a long time: the Mac was asleep.
        if delta > 120 || delta < 0 {
            hideOverlay(completed: false, why: "the Mac was asleep")
            resetSitting("the Mac was asleep")
            awaySince = nil
            turnOffBecauseAway("the Mac was asleep")
            return
        }

        let locked = screenIsLocked()
        if locked {
            hideOverlay(completed: false, why: "screen locked")
            turnOffBecauseAway("the screen was locked")
        }

        // Turned off from the menu (or by a lock / sleep): count nothing, show nothing.
        if let until = pausedUntil {
            if now < until {
                sitting = 0
                awaySince = nil
                return
            }
            pausedUntil = nil
            note("The hour is over; reminders are on again.")
        }

        let displayOff = displayIsAsleep()
        if locked || displayOff {
            let why = locked ? "screen locked" : "display asleep"
            hideOverlay(completed: false, why: why)
            if awaySince == nil { awaySince = now }
            if let since = awaySince, now.timeIntervalSince(since) >= Config.minimumBreakSeconds {
                resetSitting(why)
            }
            return
        }
        awaySince = nil

        if !windows.isEmpty { return } // the reminder is on screen right now

        // Nobody touched the Mac for a while and nothing is playing: you already got up.
        if secondsSinceLastInput() >= Config.idleAwaySeconds && !audioOutputActive() {
            resetSitting("no keyboard or mouse activity")
            return
        }

        sitting += delta
        if sitting >= Config.interval && now >= nextEvaluation {
            evaluate()
        }
    }

    private func evaluate() {
        if case .unknown(let why) = currentFocus(), !focusWarningLogged {
            note("Warning: \(why). Until then a Focus mode will NOT stop reminders.")
            focusWarningLogged = true
        }
        if let reason = postponeReason() {
            if reason != lastPostponeReason {
                note("Reminder due but postponed: \(reason).")
                lastPostponeReason = reason
            }
            nextEvaluation = Date().addingTimeInterval(Config.recheckSeconds)
            return
        }
        lastPostponeReason = ""
        showOverlay()
    }

    // MARK: Pausing media

    private func pauseMedia() {
        // Nothing is playing: nothing to pause.
        guard audioOutputActive() else { return }
        // 1) Direct call into the system media-remote framework ("pause" = command 1).
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
           let symbol = dlsym(handle, "MRMediaRemoteSendCommand") {
            typealias SendCommand = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool
            let send = unsafeBitCast(symbol, to: SendCommand.self)
            _ = send(1, nil)
        }
        // 2) The same "pause" sent through osascript, which newer macOS versions still accept.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-l", "JavaScript", "-e", Config.pauseScript]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            pauseTask = task
        } catch {
            note("Could not run osascript to pause media: \(error.localizedDescription)")
        }
    }

    // MARK: Overlay

    private func makeContent(for screen: NSScreen) -> NSView {
        let size = screen.frame.size
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))

        let title = NSTextField(wrappingLabelWithString: Config.message)
        title.isSelectable = false
        title.alignment = .center
        title.textColor = NSColor.white
        title.font = NSFont.systemFont(ofSize: max(40, min(96, size.width / 20)), weight: .heavy)
        title.preferredMaxLayoutWidth = size.width * 0.85

        let subtitle = NSTextField(labelWithString: "Stand up and move your body — you have been sitting for a while.")
        subtitle.alignment = .center
        subtitle.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.7)
        subtitle.font = NSFont.systemFont(ofSize: max(16, min(26, size.width / 70)), weight: .regular)

        let countdown = NSTextField(labelWithString: "")
        countdown.alignment = .center
        countdown.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.85)
        countdown.font = NSFont.monospacedDigitSystemFont(ofSize: max(18, min(30, size.width / 60)), weight: .medium)
        countdownLabels.append(countdown)

        let button = NSButton(title: "تمام، قمت", target: self, action: #selector(dismissPressed))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        button.isEnabled = false
        buttons.append(button)

        let stack = NSStackView(views: [title, subtitle, countdown, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 30
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.9),
            title.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.85)
        ])
        return container
    }

    private func showOverlay() {
        guard windows.isEmpty else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        pauseMedia()

        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                       backing: .buffered, defer: false)
            window.controller = self
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.hasShadow = false
            window.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: 0.94)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = makeContent(for: screen)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)

        shownAt = Date()
        updateCountdown()
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(countdownTick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
        note("Reminder shown after \(Int(sitting / 60)) min of sitting.")
    }

    private func updateCountdown() {
        let elapsed = Date().timeIntervalSince(shownAt)
        let remaining = max(0, Int((Config.breakSeconds - elapsed).rounded(.up)))
        for label in countdownLabels {
            label.stringValue = "الرسالة هتختفي بعد \(remaining) ثانية"
        }
        let unlockIn = Int((Config.dismissAfter - elapsed).rounded(.up))
        for button in buttons {
            if unlockIn > 0 {
                button.isEnabled = false
                button.title = "تمام، قمت (\(unlockIn))"
            } else {
                button.isEnabled = true
                button.title = "تمام، قمت"
            }
        }
    }

    @objc private func countdownTick() {
        guard !windows.isEmpty else { return }
        if Date().timeIntervalSince(shownAt) >= Config.breakSeconds {
            hideOverlay(completed: true, why: "time is up")
            return
        }
        updateCountdown()
        // Stay on top even if another app was brought forward.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        for window in windows { window.orderFrontRegardless() }
        if NSApp.keyWindow == nil { windows.first?.makeKey() }
    }

    @objc func dismissPressed() {
        guard !windows.isEmpty else { return }
        if Date().timeIntervalSince(shownAt) >= Config.dismissAfter {
            hideOverlay(completed: true, why: "closed by you")
        }
    }

    private func hideOverlay(completed: Bool, why: String) {
        guard !windows.isEmpty else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        countdownLabels.removeAll()
        buttons.removeAll()

        if let app = previousApp, !app.isTerminated {
            _ = app.activate(options: [])
        }
        previousApp = nil

        note("Reminder closed (\(why)).")
        if completed {
            sitting = 0
            nextEvaluation = Date.distantPast
            lastPostponeReason = ""
        }
        if testMode { NSApp.terminate(nil) }
    }
}

// MARK: - Entry point

let launchArguments = CommandLine.arguments
if launchArguments.contains("--status") {
    printStatus()
    exit(0)
}

if launchArguments.contains("--enable-login") {
    exit(LoginItem.enable() ? 0 : 1)
}
if launchArguments.contains("--disable-login") {
    LoginItem.disable()
    exit(0)
}

let isTestRun = launchArguments.contains("--test")
if !isTestRun && !acquireSingleInstanceLock() {
    // Another copy is already running in the background.
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate(testMode: isTestRun)
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
