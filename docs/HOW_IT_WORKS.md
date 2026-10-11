# How StretchReminder works

This page is for people who want to check what the app does before running it,
or who want to change it. The whole app is one file, `src/main.swift`.

## The parts

| Path | What it is |
| --- | --- |
| `src/main.swift` | The app: AppKit, no third-party code, no dependencies |
| `installer/installer-template.sh` | The install / test / preview / status / restart / uninstall script, with two placeholders |
| `assets/icon-1024.png` | The app icon |
| `tools/make_icon.py` | Redraws the icon. Only needed to change it; needs Python with Pillow |
| `build.sh` | Puts the three parts into one file, `dist/install-stretch-reminder.sh` |

`dist/` is generated and not tracked by git.

## Build stages

There are two stages, and they happen in different places.

### Stage 1: `build.sh` (on the developer's machine)

`build.sh` does no compiling. It copies the installer template and replaces two
placeholder lines:

- `@@SWIFT_SOURCE@@` becomes the contents of `src/main.swift`
- `@@ICON_BASE64@@` becomes `assets/icon-1024.png`, base64-encoded

The result is one self-contained shell script. It then checks the script's
syntax with `bash -n`. It needs only `bash`, `awk`, `base64`, `fold` and `tr`.

### Stage 2: the installer (on the user's Mac)

`bash install-stretch-reminder.sh` runs these steps, in this order:

1. Checks that it is on macOS and that `swiftc` exists (`xcrun --find swiftc`).
2. Writes the embedded source to a temporary folder and compiles it:
   `xcrun swiftc -swift-version 5 -O`. If this fails it stops here and nothing
   on the Mac has been changed.
3. Builds the app bundle in the temporary folder: the binary, an `Info.plist`,
   and the icon (decoded from the embedded picture and converted with macOS's
   own `sips` and `iconutil`).
4. Signs the bundle ad hoc: `codesign --force --sign -`. No certificate is involved.
5. Stops a running copy: `launchctl bootout`, then `pkill -x StretchReminder`.
6. Copies the bundle to `/Applications` (or `~/Applications` if that is not
   writable). When it installs into `/Applications` it removes an older copy
   from `~/Applications`.
7. Runs `defaults write local.stretch-reminder NSAppSleepDisabled -bool YES`, so
   macOS does not slow the app's timer down while it has no window.
8. Asks the app to write its own start-at-login entry (`--enable-login`), unless
   you had switched that off in an earlier install.
9. Starts the app (`launchctl bootstrap`, or `open` when start at login is off).
10. Reads the app's log to see whether it could read the Focus state. If not, it
    prints the Full Disk Access steps and opens that page of System Settings.

The installer uses no `sudo`, downloads nothing, and removes its temporary folder
when it finishes.

## What runs afterwards

One process, `StretchReminder`, started at login by a LaunchAgent
(`~/Library/LaunchAgents/local.stretch-reminder.plist`). The LaunchAgent restarts
it only if it crashes, so Quit really quits. A lock file makes sure only one copy
runs.

Once a second the app:

1. Checks for a long gap since the last tick, which means the Mac was asleep.
2. Checks whether the screen is locked. If so, and the option is on, it turns
   itself off.
3. If it is off, does nothing more.
4. Checks whether the display is asleep, and whether you have been idle for
   5 minutes with nothing playing. Either one means "away", and the sitting
   count is reset (after 2 minutes for a lock or a sleeping display).
5. Otherwise adds one second to the sitting count.
6. When the count reaches the period, asks the three questions below. If any
   answer is yes, it waits and asks again every 60 seconds. If all are no, it
   shows the reminder.

### Is there a call?

- On macOS 14.2 or later it asks Core Audio for the list of processes that
  currently have audio **input** running, and takes the first one that is not
  the app itself or a system voice-trigger service.
- On older versions it falls back to "is any input device running".
- Separately it asks CoreMediaIO whether any camera device is running.

Neither needs microphone or camera permission, because nothing is captured.

### Is a Focus on?

It reads `~/Library/DoNotDisturb/DB/Assertions.json`. A non-empty
`storeAssertionRecords` list means a Focus is on. If that is empty, it also
checks the schedule windows in `ModeConfigurations.json` (time of day only).
There is no public macOS interface for this that works without a paid developer
certificate, which is why the app needs Full Disk Access.

### Is the Mac locked or asleep?

- Locked: `CGSessionCopyCurrentDictionary`, plus the system's
  `com.apple.screenIsLocked` notification so a short lock is not missed.
- Display asleep: `CGDisplayIsAsleep`.
- Mac asleep: the `NSWorkspace` will-sleep notification, plus a gap of more
  than 2 minutes between timer ticks.

### Showing the reminder

One borderless window per display, above everything else, including full-screen
apps. Before showing it the app sends a "pause" to macOS's media controls, but
only if the default audio output is running. It uses the private `MediaRemote`
framework, once directly and once through `/usr/bin/osascript`, because recent
macOS versions accept the command only from Apple's own tools.

When the reminder closes, the app you were using becomes active again.

## Settings

The menu covers the common ones. All of them are stored in the app's defaults
under `local.stretch-reminder`:

| Key | Default | Meaning |
| --- | --- | --- |
| `intervalMinutes` | 30 | Sitting time before a reminder |
| `breakSeconds` | 60 | How long the reminder stays on screen |
| `dismissAfterSeconds` | 5 | How long before the button and Esc work |
| `message` | the Arabic text | The big message |
| `turnOffOnLock` | true | Turn off when the Mac locks or sleeps |
| `showCountdownInMenuBar` | true | Show the time left next to the icon |
| `checkFocusSchedules` | true | Treat a Focus schedule window as "Focus on" |

Keys without a menu item can be set from Terminal, then restart the app:

```
defaults write local.stretch-reminder dismissAfterSeconds -float 10
bash install-stretch-reminder.sh restart
```

## Command-line flags of the app

`/Applications/StretchReminder.app/Contents/MacOS/StretchReminder` accepts:

| Flag | What it does |
| --- | --- |
| `--status` | Prints what the detectors see, then exits |
| `--test` | Shows the reminder once, ignoring calls and Focus, then exits |
| `--enable-login` / `--disable-login` | Writes or removes the start-at-login entry, then exits |

The installer's `test`, `preview` and `status` commands are built on these.
