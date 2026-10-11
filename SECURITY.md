# Security

## What matters here

StretchReminder runs on your Mac with the permissions you give it, and it asks
for Full Disk Access to read the Focus state. That makes a few things worth
reporting privately instead of in a public issue:

- anything that makes the app or the installer read, write or send data beyond
  what the [Privacy section of the README](README.md#privacy-and-what-the-app-touches)
  lists,
- a way for another program or a crafted file to make the app or the installer
  run code,
- a problem in how the installer builds, signs or installs the app.

## How to report

Please do not open a public issue for these.

On GitHub, open the repository's **Security** tab and choose
**Report a vulnerability**. That sends the report privately to the maintainer.

Say what you found, how to reproduce it, and which version you used. This is a
spare-time project with one maintainer, so replies are best effort.

## Supported versions

Only the newest release is maintained. Please check that the problem still exists
there before reporting.

## Checking the app yourself

The installer compiles the app from the source in this repository on your own
Mac, so what you run is what you can read. The app has no networking code.
[docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) lists every step the installer
takes and everything the app touches.
