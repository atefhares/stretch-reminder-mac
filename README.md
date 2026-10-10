# StretchReminder

A small macOS menu bar app. After a set time of sitting at the Mac it covers every
screen with a big message, by default:

> انت قاعد بقالك كتير قوم حرك جسمك

It never closes any app. It only sends a "pause" to whatever is playing.

Owner: Atef Hares

## What it does

- **Reminder screen** on every display after 30 minutes of sitting (adjustable). It
  closes by itself after 60 seconds (adjustable), or with the button / Esc after 5 seconds.
- **Stays quiet** while a Focus / Do Not Disturb is on, while the microphone or camera
  is in use (call, meeting, recording), and while the screen is locked or the Mac is asleep.
  A reminder that comes due during a call or Focus waits and shows within a minute after it ends.
- **Menu bar icon**: green = on, gray = off, with an optional countdown to the next reminder.
- **Caffeine-style auto-off**: locking the screen or sleeping turns it off until you
  choose Turn on again (can be unticked in the menu).
- **Menu settings**: period, how long the screen stays, the message, start at login,
  countdown in the menu bar.

## Layout

| Path | What it is |
| --- | --- |
| `src/main.swift` | The whole app (AppKit, one file) |
| `installer/installer-template.sh` | Install / test / status / restart / uninstall script, with placeholders for the app source and icon |
| `assets/icon-1024.png` | The app icon |
| `tools/make_icon.py` | Redraws the icon (only needed to change it; needs Pillow) |
| `build.sh` | Puts the three parts together into `dist/install-stretch-reminder.sh` |
| `CHANGELOG.md` | What changed in each version |

`dist/` is generated and not tracked.

## Build and install

Needs Apple's Command Line Tools (`xcode-select --install`). No sudo.

```
bash build.sh install
```

or in two steps:

```
bash build.sh
bash dist/install-stretch-reminder.sh
```

The installer compiles `main.swift` on the Mac, creates `/Applications/StretchReminder.app`
(or `~/Applications` if that is not writable), signs it ad hoc and starts it.

Other installer commands:

```
bash dist/install-stretch-reminder.sh test       # act as if a reminder is due now
bash dist/install-stretch-reminder.sh preview    # show the screen no matter what
bash dist/install-stretch-reminder.sh status     # what it detects right now
bash dist/install-stretch-reminder.sh restart
bash dist/install-stretch-reminder.sh uninstall
```

### Full Disk Access after every rebuild

Reading the Focus state needs Full Disk Access. The app is signed ad hoc, so macOS
treats every rebuild as a new app and the permission has to be given again:
System Settings > Privacy & Security > Full Disk Access, remove the old StretchReminder
entry, add `/Applications/StretchReminder.app`, then run the installer with `restart`.
Without it everything works except that a Focus will not hold reminders back.

## Working on it

1. Edit `src/main.swift` (the app) or `installer/installer-template.sh` (the installer).
2. For a new version, change `CFBundleShortVersionString` and `CFBundleVersion` in the
   template and add an entry to `CHANGELOG.md`.
3. `bash build.sh install`, try it, then commit and tag:

```
git add -A
git commit -m "v1.8: what changed"
git tag v1.8
```

Useful while testing:

- Log: `~/Library/Logs/StretchReminder.log` (also menu > Open log). Every decision is
  written there, and each "Show reminder now" records what the detectors saw.
- A short period for testing: menu > Remind me every > Other… > 1.

## How the detection works

- **Call / meeting**: Core Audio's per-process "is running input" flag (macOS 14.2+),
  falling back to "an input device is running"; plus CoreMediaIO's "camera is running".
- **Focus**: `~/Library/DoNotDisturb/DB/Assertions.json`, plus schedule windows from
  `ModeConfigurations.json`. A Focus switched on from an iPhone and synced to the Mac
  has not been confirmed to show up there.
- **Locked / asleep**: the session dictionary, the display sleep state, the system
  sleep notification, and a gap in the one-second timer.
- **Pausing media**: the system MediaRemote "pause" command, sent directly and through
  `osascript`. This is a private interface that Apple has been restricting.
