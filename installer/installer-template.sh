#!/bin/bash
# StretchReminder installer for macOS.
#
#   bash install-stretch-reminder.sh            build, install (or update) and start it
#   bash install-stretch-reminder.sh test       act as if a reminder is due now (respects meetings, Focus, ...)
#   bash install-stretch-reminder.sh preview    show the reminder screen now, no matter what
#   bash install-stretch-reminder.sh status     show what it currently detects
#   bash install-stretch-reminder.sh restart    restart it
#   bash install-stretch-reminder.sh uninstall  stop it and remove everything
#
# What gets installed (no sudo):
#   /Applications/StretchReminder.app                     (or ~/Applications if /Applications is not writable)
#   ~/Library/LaunchAgents/local.stretch-reminder.plist   (the "Start at login" entry; the menu bar icon can switch it off)
#   ~/Library/Logs/StretchReminder.log                    (what it did and why)

set -euo pipefail

# The name shown as owner in the app's About window. Change it here if you like.
OWNER_NAME="Atef Hares"

LABEL="local.stretch-reminder"
SYSTEM_APP="/Applications/StretchReminder.app"
USER_APP="$HOME/Applications/StretchReminder.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/StretchReminder.log"
DOMAIN="gui/$(id -u)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer only works on macOS." >&2
  exit 1
fi

# Where is it installed right now (if anywhere)?
APP=""
if [ -d "$SYSTEM_APP" ]; then
  APP="$SYSTEM_APP"
elif [ -d "$USER_APP" ]; then
  APP="$USER_APP"
fi
BIN="$APP/Contents/MacOS/StretchReminder"

stop_app() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  # Give launchd a moment to let go of the old one.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
  done
  # A copy that was opened by hand (not by launchd).
  pkill -x StretchReminder >/dev/null 2>&1 || true
  sleep 0.5
}

start_app() {
  local attempt
  if [ -f "$PLIST" ]; then
    for attempt in 1 2 3 4 5; do
      if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
        return 0
      fi
      sleep 1
    done
  fi
  # "Start at login" is off (or launchd refused): just open the app.
  open -g "$APP" >/dev/null 2>&1 || {
    echo "Could not start StretchReminder. Open it by hand: $APP" >&2
    return 1
  }
}

require_installed() {
  if [ -z "$APP" ] || [ ! -x "$BIN" ]; then
    echo "StretchReminder is not installed yet. Run:  bash \"$0\"" >&2
    exit 1
  fi
}

FOCUS_LINES_BEFORE=0
mark_log() {
  # Remember how many start-up lines the log already has, so we read the new one.
  FOCUS_LINES_BEFORE="$(grep -c 'focus-detection:' "$LOG" 2>/dev/null || true)"
  FOCUS_LINES_BEFORE="${FOCUS_LINES_BEFORE:-0}"
}

report_focus_access() {
  # The app writes one "focus-detection:" line each time it starts.
  local line="" count=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    count="$(grep -c 'focus-detection:' "$LOG" 2>/dev/null || true)"
    count="${count:-0}"
    if [ "$count" -gt "$FOCUS_LINES_BEFORE" ]; then
      line="$(grep 'focus-detection:' "$LOG" 2>/dev/null | tail -n 1 || true)"
      break
    fi
    sleep 0.5
  done
  case "$line" in
    *"focus-detection: ok"*)
      echo "Focus / Do Not Disturb detection: working."
      return 0
      ;;
    *)
      echo
      echo "ONE MANUAL STEP LEFT — Full Disk Access (needed only to see whether a Focus / Do Not Disturb is on)."
      echo "macOS asks for this again after every update of the app."
      echo "  1. System Settings > Privacy & Security > Full Disk Access (opening it for you now)"
      echo "  2. If StretchReminder is already in the list, select it and press  -  to remove it."
      echo "  3. Press  +  and pick:  $APP   then make sure it is switched on."
      echo "  4. Run:  bash \"$0\" restart"
      echo "Until you do this, reminders still work, but a Focus mode will not stop them."
      open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" >/dev/null 2>&1 || true
      open -R "$APP" >/dev/null 2>&1 || true
      return 0
      ;;
  esac
}

case "${1:-install}" in
  uninstall)
    stop_app
    rm -f "$PLIST"
    rm -rf "$SYSTEM_APP" "$USER_APP"
    rm -f "$HOME/Library/Caches/$LABEL.lock"
    defaults delete "$LABEL" >/dev/null 2>&1 || true
    echo "StretchReminder removed. (The log is still at $LOG if you want to delete it.)"
    exit 0
    ;;
  test)
    # Same decision the app makes when a reminder is due.
    require_installed
    report="$("$BIN" --status 2>/dev/null || true)"
    verdict="$(printf '%s\n' "$report" | grep 'A reminder right now' || true)"
    case "$verdict" in
      *"would be postponed"*)
        echo "No reminder right now: it ${verdict#*: }"
        echo "It will show within a minute after that ends."
        echo "(To see the screen anyway:  bash \"$0\" preview)"
        exit 0
        ;;
    esac
    case "$report" in
      *"UNKNOWN"*)
        echo "Note: Focus cannot be checked from this Terminal window; the app checks it itself."
        ;;
    esac
    echo "No call or Focus detected, so the reminder screen is showing now."
    "$BIN" --test
    exit 0
    ;;
  preview)
    require_installed
    echo "Showing the reminder screen now, ignoring meetings and Focus."
    "$BIN" --test
    exit 0
    ;;
  status)
    require_installed
    echo "Installed at            : $APP"
    if pgrep -x StretchReminder >/dev/null 2>&1; then
      echo "Running                 : yes (menu bar icon: green = on, gray = off)"
    else
      echo "Running                 : NO  (open it from Applications, or run: bash \"$0\" restart)"
    fi
    if [ -f "$PLIST" ]; then
      echo "Start at login          : on"
    else
      echo "Start at login          : off"
    fi
    "$BIN" --status
    echo
    echo "Note: the Focus line above is as seen from this Terminal. The app's own view is in the log:"
    grep 'focus-detection:' "$LOG" 2>/dev/null | tail -n 1 || echo "  (no log yet)"
    echo
    echo "Last log lines:"
    tail -n 8 "$LOG" 2>/dev/null || true
    exit 0
    ;;
  restart)
    require_installed
    stop_app
    mark_log
    start_app
    report_focus_access
    exit 0
    ;;
  install)
    ;;
  *)
    echo "Unknown command: $1   (use: install | test | preview | status | restart | uninstall)" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------- build

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Install Apple's Command Line Tools first:" >&2
  echo "    xcode-select --install" >&2
  echo "then run this installer again." >&2
  exit 1
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

cat > "$BUILD/main.swift" <<'STRETCH_SWIFT_SOURCE'
@@SWIFT_SOURCE@@
STRETCH_SWIFT_SOURCE

echo "Building StretchReminder (takes about 20-60 seconds)..."
if ! xcrun swiftc -swift-version 5 -O -o "$BUILD/StretchReminder" "$BUILD/main.swift" 2> "$BUILD/build.log"; then
  echo "The build failed. Nothing was changed on your Mac. Compiler output:" >&2
  cat "$BUILD/build.log" >&2
  exit 1
fi

# ---------------------------------------------------------------- install

# Keep "Start at login" off if you had switched it off in an earlier install.
KEEP_LOGIN_OFF="no"
if [ -n "$APP" ] && [ ! -f "$PLIST" ]; then
  KEEP_LOGIN_OFF="yes"
fi

# Put the whole app together first, so a failure cannot leave a half-installed app.
STAGED="$BUILD/StretchReminder.app"
mkdir -p "$STAGED/Contents/MacOS"
cp "$BUILD/StretchReminder" "$STAGED/Contents/MacOS/StretchReminder"
chmod 755 "$STAGED/Contents/MacOS/StretchReminder"

cat > "$STAGED/Contents/Info.plist" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>StretchReminder</string>
  <key>CFBundleDisplayName</key><string>StretchReminder</string>
  <key>CFBundleExecutable</key><string>StretchReminder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.7</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) $OWNER_NAME</string>
  <key>StretchReminderOwner</key><string>$OWNER_NAME</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST_END

# App icon: the picture travels inside this file; macOS's own tools turn it into an icon.
make_icon() {
  local png="$BUILD/icon.png" set="$BUILD/AppIcon.iconset" size double
  { base64 --decode < "$BUILD/icon.b64" > "$png" 2>/dev/null || base64 -D < "$BUILD/icon.b64" > "$png"; } || return 1
  mkdir -p "$set" "$STAGED/Contents/Resources"
  for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$png" --out "$set/icon_${size}x${size}.png" >/dev/null 2>&1 || return 1
    sips -z "$double" "$double" "$png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || return 1
  done
  iconutil -c icns "$set" -o "$STAGED/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || return 1
}
cat > "$BUILD/icon.b64" <<'STRETCH_ICON_PNG'
@@ICON_BASE64@@
STRETCH_ICON_PNG
make_icon || echo "Note: could not make the app icon (the app works, it just keeps the plain icon)."

codesign --force --sign - "$STAGED" >/dev/null 2>&1 || echo "Note: could not sign the app (it will still run)."

if [ -w "/Applications" ]; then
  TARGET="$SYSTEM_APP"
else
  TARGET="$USER_APP"
fi

stop_app
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$(dirname "$TARGET")"

if ! { rm -rf "$TARGET" && cp -R "$STAGED" "$TARGET"; } 2> "$BUILD/install.log"; then
  echo "Could not put the app in $(dirname "$TARGET"):" >&2
  cat "$BUILD/install.log" >&2
  if [ -n "$APP" ] && [ -x "$BIN" ]; then
    echo "Starting the version you already had again." >&2
    start_app || true
  fi
  exit 1
fi

# Only one copy should exist.
if [ "$TARGET" = "$SYSTEM_APP" ]; then
  rm -rf "$USER_APP" 2>/dev/null || true
fi
APP="$TARGET"
BIN="$APP/Contents/MacOS/StretchReminder"
touch "$APP" 2>/dev/null || true   # nudges Finder to pick up the new icon
defaults write "$LABEL" NSAppSleepDisabled -bool YES

if [ "$KEEP_LOGIN_OFF" = "yes" ]; then
  LOGIN_STATE="off (as you had it; switch it on from the menu bar icon)"
else
  # The app writes its own start-at-login entry, the same one its menu switch uses.
  rm -f "$PLIST"
  if "$BIN" --enable-login; then
    LOGIN_STATE="on (switch it off from the menu bar icon > Start at login)"
  else
    LOGIN_STATE="could not be set; use the menu bar icon > Start at login"
  fi
fi

mark_log
start_app

echo
echo "Installed and running:  $APP"
echo "  Menu bar icon      :  green = on (with the time left until the next reminder), gray = off"
echo "  Lock / sleep       :  switches it OFF until you choose Turn on (untick this in the menu if you prefer)"
echo "  Start at login     :  $LOGIN_STATE"
echo "  Test it for real   :  bash \"$0\" test      (stays quiet in a call or Focus)"
echo "  Just see the screen:  bash \"$0\" preview"
echo "  See what it detects:  bash \"$0\" status"
echo "  Remove everything  :  bash \"$0\" uninstall   (or menu bar icon > Uninstall)"
echo "  Log                :  $LOG"
report_focus_access
