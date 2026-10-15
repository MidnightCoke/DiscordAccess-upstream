# Changelog

This file is a short summary of the verified source history. Full source versions are kept in Git tags; package and verification details are in the corresponding release notes. Real-account use, voice/streaming, tray interaction and Windows restarts are evaluated separately from synthetic tests.

## macos-v0.2 (macOS pre-release)

- The interface is in English: the menu, notifications, alerts, error messages, Terminal mode and help.
- The attachment download hook's messages inside Discord are in English and fit both platforms.
- The notes in the package are now `README.md`, `LICENSES.txt` and `SOURCE.txt`.
- In Terminal mode, `quit` and `exit` stop the session as `Q` does. A download without a usable name is saved as `Discord-file`.
- The engine, the gate policy, the update bridge and the profile changes are unchanged; the engine keeps the same SHA-256 and cdhash.

## macos-v0.1 (macOS pre-release)

- Native Swift version for Apple Silicon: a menu bar app and a `--console` Terminal mode. It uses the existing official Discord and account; you open Discord from its own icon.
- Same engine source, Go 1.26.9, dependency locks and HTTP limits as Windows, with a separate pinned SHA-256 and cdhash for macOS arm64. The gate policy and update bridge are the same as on Windows.
- The session wrapper and two update settings in Discord's profile are changed with journaling. The changes are undone on exit, on the next launch or with `--restore`; no rollback is done while Discord is open.
- Added Full Disk Access guidance, start at login (with a location trust check), a single-session lock and crash recovery.
- The app is not signed by Apple; the first launch is approved with "Open Anyway". Live-tested only on macOS 27; the Windows packages are unchanged.

## v4.22

- Desktop/Downloads packages that other standard users can write to are copied, on a normal manual launch, to a verified personal folder and run from there. Windows startup can now be registered to the safe package copy.
- Added copying limited to the EXE, the hash-pinned engine and the usage/license/source texts; parent folder/ACL/content verification; and operations that protect a different existing file. Existing permissions are not changed.
- Automatic startup, rollback, console and Discord launch do not create an installation; if the user turned startup off, that preference is kept.
- Added synthetic regression checks for the personal package copy, repeated launches, a different version, a wrong engine, an unsafe user folder and file conflicts.
- The engine and the five-file package / four-release-file layout are unchanged. The official Discord/profile/network flow is not changed.

## v4.21

- Fixed the license and corresponding source inventory so it also covers the engine's WireGuard wrapper/native components; refreshed the distribution materials.
- Added contribution, security reporting and release preparation documents, plus issue/PR templates with privacy warnings.
- Documented how to turn off the old startup entry and re-enable it in the new permanent folder when upgrading from a previous version.
- The v4.20 app flow and the `1.14.3-discordaccess.2` engine are unchanged. No official Discord/profile copy, global Windows proxy/DNS setting, driver or service is added.
- Old ready-made binary packages with incomplete notices are no longer offered as supported downloads; old tags and commit history are kept.

## v4.20

- Strengthened executable download support and the ownership/permission checks of recovery files.
- Moved the resident lock and the open/status/startup channels to private namespaces restricted to the user SID, with a new GUID for each primary process.
- Limited the engine's pre-authentication HTTP headers, absolute wait time and pending connection count; authenticated file bodies and CONNECT/WSS tunnels are preserved.
- Removed GitHub Actions; Windows verification is run manually with explicit commands.

## v4.19

- Added plain HTTP Upgrade rejection, startup target trust checks and operations that preserve conflicting file/recovery content.
- Prepared an engine rebuild path with pinned sources and Go dependencies.

## v4.18

- Improved the separation between the ready-made package and the source ZIP, the usage/PowerShell instructions and the distribution notices.

## v4.17

- Added tray mode and coordination with the official Discord's personal Windows startup preference.

## v4.16

- Published this repository's first tracked Windows sources and the ready-made package usage documents.
