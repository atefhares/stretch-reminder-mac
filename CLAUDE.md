# Notes for Claude

This repository is the source of truth for StretchReminder. Every change the
owner asks for is made here and committed.

## Workflow for a change

1. Edit `src/main.swift` (the app) and/or `installer/installer-template.sh`.
2. Bump `CFBundleShortVersionString` and `CFBundleVersion` in the template when
   users would notice the change, and add a `CHANGELOG.md` entry.
3. `bash build.sh` and check `dist/install-stretch-reminder.sh` (`bash -n`).
4. Commit with a subject like `v1.9: what changed`, and tag `v1.9`.
5. If the app reads, writes or runs anything new, update the Privacy table in
   `README.md` and `docs/HOW_IT_WORKS.md` in the same commit.

## Things to know

- The project is public at https://github.com/atefhares/stretch-reminder-mac.
  History there is published: add commits, never rewrite them. The owner pushes.
- The owner's email must not appear anywhere in the repository, including commit
  author fields (the repo's git config uses a placeholder address).

- The app cannot be compiled outside macOS. The owner runs
  `bash build.sh install` on the Mac; a failed build changes nothing there.
- Every rebuild loses Full Disk Access (ad hoc signature), so batch changes
  instead of shipping many small updates.
- `~/Library/Logs/StretchReminder.log` on the Mac records every decision the app
  makes and is the first place to look when behaviour is questioned.
- The app must keep making no network connections; the README promises it.
- `dist/` is generated and ignored by git.
