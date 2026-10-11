# Contributing to StretchReminder

Thank you for wanting to help. This is a small project with one maintainer, so
the process is kept light.

## Reporting a bug

[Open a bug report](../../issues/new/choose). The form asks for the things that
make a bug fixable:

- your macOS version and whether the Mac is Apple Silicon or Intel,
- the StretchReminder version (menu > About StretchReminder),
- what you expected and what happened,
- the output of `bash install-stretch-reminder.sh status`,
- the last lines of the log (menu > Open log).

The log and the status output contain the names of apps that were using audio on
your Mac. Read them before you paste them, and remove anything you would rather
not share.

## Asking for a feature

[Open a feature request](../../issues/new/choose). Say what you are trying to do,
not only the change you have in mind; there may be a simpler way to get there.

## Sending a change

1. For anything bigger than a small fix, open an issue first so the approach can
   be agreed before you spend time on it.
2. Fork the repository and make a branch.
3. Make the change (see below), build it and try it on your Mac.
4. Open a pull request. The template has a short checklist.

### Where things are

- `src/main.swift` is the whole app.
- `installer/installer-template.sh` is the installer.
- `docs/HOW_IT_WORKS.md` explains both.

### Build and run

```
bash build.sh install
```

This assembles `dist/install-stretch-reminder.sh` and runs it, which compiles
and installs the app. You will have to give Full Disk Access again after each
build (the README explains why).

Useful while testing:

- Menu > Remind me every > Other… > `1` gives a one-minute period.
- Menu > Show reminder now shows the reminder under the real rules.
- `bash dist/install-stretch-reminder.sh preview` shows it no matter what.
- `bash dist/install-stretch-reminder.sh status` prints what the detectors see.
- Menu > Open log shows every decision the app made.

### What to check before a pull request

There are no automated tests; the app is mostly about how macOS behaves, so
please test by hand what your change touches:

- the reminder shows on every display and closes with the button, Esc and the timer,
- it waits during a call (join a test meeting) and shows after the call ends,
- it waits during a Focus,
- locking the screen turns it off (with the option on) and resets the count,
- `bash -n dist/install-stretch-reminder.sh` passes,
- install, `restart` and `uninstall` still work.

Say in the pull request which macOS version and which kind of Mac you tested on.

### Ground rules for changes

- **No network access.** The app makes no connections, and that is a promise in
  the README. A change that adds any will not be merged.
- **No new permissions** unless there is no other way, and then say why in the
  pull request and update the Privacy section of the README.
- **Keep the docs true.** If you change what the app reads, writes or runs,
  update the README's Privacy table and `docs/HOW_IT_WORKS.md` in the same pull
  request.
- **One file, no dependencies.** Please keep the app building with nothing but
  Apple's Command Line Tools.
- Match the style of the code around your change.

### Versions

Maintainer steps for a release:

1. Change `CFBundleShortVersionString` and `CFBundleVersion` in
   `installer/installer-template.sh`.
2. Add an entry to `CHANGELOG.md`.
3. `bash build.sh`, install and test.
4. Commit, tag (`git tag v1.9`), push with tags.
5. Create a GitHub release for the tag and attach
   `dist/install-stretch-reminder.sh`.

## Good places to help

- **Keeping Full Disk Access across updates.** It is lost on every rebuild
  because the app is signed ad hoc. A stable local signing identity might fix it.
- **Detecting a Focus without Full Disk Access**, if there is a way.
- **Testing** on Intel Macs and on macOS versions other than the newest.
- **Focus synced from an iPhone**: confirm whether it is detected.
- **Translations** of the menu.

## Conduct

Be kind and assume good intent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
