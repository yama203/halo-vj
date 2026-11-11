# Installing and Updating

How to install Halo VJ on a Mac, and how to replace it with a newer version.

## Supported Macs

- A Mac with Apple silicon.
- macOS 14 or later.

## Installing

1. Download `Halo-VJ-x.y.z.zip` from [Releases](https://github.com/yama203/halo-vj/releases) and open it.
2. Move “Halo VJ” to the Applications folder.

### Opening for the first time

The app is not notarized by Apple, so macOS blocks it the first time you open it. Allow it once in System Settings → “Privacy & Security” → “Open Anyway”.

## Updating

- The app checks for new versions on its own (once a day). You can also check with “Check for Updates…” in the app menu.
- If a new version is found at launch, a window appears.
- If one is found while the app is running, only a small “New version” button appears at the top (no window pops up in the middle of a show).
- Click it to see the changes and decide whether to install. Installing replaces the app and relaunches it.
- In the “Updates” section of the settings, you can turn automatic checking on or off.
- Updates are installed by Sparkle, which verifies the signature with the public key (SUPublicEDKey in Info.plist) first.

## Checking the version number

Click the icon at the left end of the top bar to open “About Halo VJ”, which shows the version number.

## Caution

- This is work-in-progress software (pre-1.0).
- It is built by “vibe coding” — writing code in conversation with an AI (Claude). It has not been thoroughly tested.
- **Please avoid using it for important live shows.** If you do use it, test it thoroughly beforehand and have a backup, such as another VJ app.
