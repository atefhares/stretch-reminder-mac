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
//
// Flags:  --test   show the screen once right now, then exit
//         --status print what the detectors currently see, then exit

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
    static var message: String {
        UserDefaults.standard.string(forKey: "message") ?? "انت قاعد بقالك كتير قوم حرك جسمك"
    }
    /// Also treat a Focus *schedule* window as "Focus on".
    static var checkFocusSchedules: Bool {
        guard UserDefaults.standard.object(forKey: "checkFocusSchedules") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "checkFocusSchedules")
    }

    /// Locked / display-off for at least this long counts as a real break.
    static let minimumBreakSeconds: TimeInterval = 120
    /// No keyboard/mouse input for this long (and nothing playing) counts as "away".
    static let idleAwaySeconds: TimeInterval = 300
    /// When a reminder is due but postponed, look again this often.
    static let recheckSeconds: TimeInterval = 60
    static let tickSeconds: TimeInterval = 5

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

/// Why a due reminder should wait, or nil when it is fine to show it.
func postponeReason() -> String? {
    if let app = microphoneUser() { return "microphone in use by \(app) (call / meeting)" }
    if cameraInUse() { return "camera in use (call / meeting)" }
    if case .on(let mode) = currentFocus() { return "Focus is on: \(mode)" }
    return nil
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

final class AppDelegate: NSObject, NSApplicationDelegate {
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

        lastTick = Date()
        let timer = Timer(timeInterval: Config.tickSeconds, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    @objc private func showTestOverlay() {
        showOverlay()
    }

    @objc private func systemWillSleep() {
        hideOverlay(completed: false, why: "the Mac is going to sleep")
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
        let now = Date()
        let delta = now.timeIntervalSince(lastTick)
        lastTick = now

        // The timer did not fire for a long time: the Mac was asleep.
        if delta > 120 || delta < 0 {
            hideOverlay(completed: false, why: "the Mac was asleep")
            resetSitting("the Mac was asleep")
            awaySince = nil
            return
        }

        let locked = screenIsLocked()
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

let application = NSApplication.shared
let appDelegate = AppDelegate(testMode: launchArguments.contains("--test"))
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
