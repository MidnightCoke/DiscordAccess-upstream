# DiscordAccess for macOS — usage

These notes cover the **macos-v0.3** pre-release for Apple Silicon (arm64). The app was built on macOS 27; no test suite or live Discord session was run for this release build. The app's interface is in English. Design details: [DESIGN.md](https://github.com/alpertknn/DiscordAccess/blob/main/macos/docs/DESIGN.md).

## Requirements

- An Apple Silicon Mac with macOS 13 or later.
- The official Discord (Stable) app in `/Applications/Discord.app` or `~/Applications/Discord.app`. PTB and Canary are not supported.
- A standard user account. DiscordAccess does not run as root.

## Installing the release package

1. Quit Discord and any earlier DiscordAccess. The old app's **Quit** item is at the bottom of its menu bar menu.
2. Download `DiscordAccess-macos-v0.3-installer.zip` from the [macos-v0.3 combined release](https://github.com/alpertknn/DiscordAccess/releases/tag/macos-v0.3) and extract it. Open `DiscordAccess-macos-v0.3-Installer.pkg` and complete Installer's steps. It installs `/Applications/DiscordAccess.app`; no drag or manual copy is needed.
3. Open **DiscordAccess** from Applications. It runs in the menu bar and has no Dock window. The installer and app are not signed with an Apple Developer ID or notarized. If macOS blocks either one, try opening it once, then use **Open Anyway** for that item under System Settings > Privacy & Security. macOS may ask for your password and a second confirmation. A later download may require approval again.
4. Follow "First launch" below to grant Full Disk Access to the installed app. Gatekeeper approval does not grant this data permission.

The ZIP includes `LICENSES.txt` and `SOURCE.txt`. The engine's SHA-256 and cdhash are unchanged from macos-v0.2, so the verified `DiscordAccess-macos-v0.2-engine-source.zip` in this release is its corresponding source package. Keep that package and the notices with the installer if you redistribute it. Compare the downloaded ZIP with the release's `SHA256SUMS.txt`:

```bash
shasum -a 256 DiscordAccess-macos-v0.3-installer.zip
```

A checksum is not a code signature.

## Building from source

1. Build the engine. The script refuses to copy an engine that does not match its pinned SHA-256 and cdhash:
   ```bash
   python3 macos/scripts/build-engine.py --out macos/build/engine/sing-box
   ```
2. Assemble the app bundle. The script prints the bundle's path last (`macos/build/apps.noindex/<time>/DiscordAccess.app`) and never deletes earlier builds.
   ```bash
   macos/scripts/build-app.sh
   ```
   If your keychain holds a code-signing identity, you can sign with it so that Full Disk Access survives rebuilds:
   ```bash
   DISCORDACCESS_SIGN_IDENTITY="DiscordAccess Local Signing" macos/scripts/build-app.sh
   ```
3. Copy the bundle to Applications. A bundle you built yourself does not come from the internet, so it needs no "Open Anyway" step:
   ```bash
   ditto macos/build/apps.noindex/<time>/DiscordAccess.app /Applications/DiscordAccess.app
   ```

## First launch

1. Quit Discord completely (Discord > Quit Discord, or Cmd+Q).
2. Open DiscordAccess from Applications. Its icon appears in the menu bar, not in the Dock.
3. macOS protects Discord's data folder from other apps and shows no automatic permission prompt for it. On first launch an alert titled "Full Disk Access required" appears:
   - Click **Open Full Disk Access**, or open System Settings > Privacy & Security > Full Disk Access yourself.
   - If DiscordAccess is absent, click **+**, choose `/Applications/DiscordAccess.app`, click **Open**, and turn on its switch. If a previous DiscordAccess entry is present but access still fails, remove that entry with **−** and add this installed copy again.
   - Quit DiscordAccess and open it again from Applications.
   - Discord's settings are never changed without this permission.
   - Because the app is signed ad hoc, a future build may need this permission again. The app and installer cannot add or enable their own Full Disk Access entry.
4. Wait for the "Connection ready" notification. Open Discord from its own icon (Dock, Launchpad, Spotlight) or with "Open Discord" in the menu. Your existing installation and account are used; no copy is made.
5. When you are done, quit Discord first, then choose "Quit" in the menu. If you quit while Discord is still open, Discord is not closed: the recovery record of the temporary settings is kept, and the settings are undone at the next launch or with `--restore`.

## Menu

- **Status line:** the state of the connection.
- **Open Discord:** opens Discord while the connection is ready. If Discord is already open, it is not opened again.
- **Reconnect:** re-establishes a connection that closed or could not be set up.
- **Check connection:** anonymously checks HTTPS access to Discord and the Gateway connection (HELLO). No account data is sent.
- **Start at login:** starts DiscordAccess at login.
  - After the first working connection it turns itself on, unless you turned it off. Once you turn it off, it stays off.
  - Only an app in a trusted location registers; the Applications folder qualifies. External drives and folders other users can change are refused.
  - If macOS asks for approval, allow DiscordAccess under System Settings > General > Login Items.
- **Also open Discord at login:** opens Discord once at login, after the connection is ready. Off by default. Turn off Discord's own "open at startup" setting; otherwise Discord opens before the connection and connecting fails.
- **Quit:** closes the connection and undoes the temporary settings.

Opening DiscordAccess again does not start a second session; the running app reports its status.

## Command line

Options go to the program inside the app: `/Applications/DiscordAccess.app/Contents/MacOS/DiscordAccess <option>`.

| Option | What it does |
| --- | --- |
| `--console` | Opens the connection in Terminal. A + Enter: open Discord. Q + Enter or Ctrl+C: quit. T: diagnostics. D: paste an attachment link to download it under `~/Downloads/DiscordAccess`. |
| `--restore` | Undoes the temporary Discord settings while Discord is closed. |
| `--verify-package` | Verifies the integrity of the engine and the hook without starting the engine. |
| `--dns=auto`, `--dns=cloudflare`, `--dns=cloudflare-ip`, `--dns=google` | DNS choice; automatic selection is the default. |
| `--dns-record-fragment` | Turns on TLS record fragmentation for the selected DoH connection. |
| `--discord-path=/…/Discord.app` | Selects a Discord installation outside the standard locations. |
| `--help` | Shows usage. |

When run from Terminal, macOS asks the terminal app for Full Disk Access. While the menu bar app runs, no second session starts.

## What changes and what does not

- The Discord.app bundle is never modified.
- Only two things change in the profile, temporarily: the entry file of Discord's core module (the session wrapper) and two update settings in `settings.json`. Every change is written to a recovery record first and undone when you quit. Values you change later are never overwritten.
- No system-wide proxy, DNS or routing setting changes. No system service, driver or network extension is installed.
- Voice and video UDP traffic stays direct, as on Windows.
- Discord's Spotify integration does not work during a session; the allow list is the same as on Windows.
- Attachments download from within Discord through the save dialog. D in Terminal is only a fallback.

## Logs and files

- `~/Library/Application Support/DiscordAccess/` (folder 0700, files 0600):
  - `session.log`: the session log; it starts over once it reaches 256 KiB.
  - `preferences.json`: menu preferences.
  - `session.lock`: the single-session lock.
  - `installed-session/journal.json`: the recovery record while a session runs. It is personal data.
- `~/Library/Application Support/discord/DiscordAccess-downloads.log`: the log of the in-Discord download support. It holds only fixed codes and byte counts.
- `.discordaccess-fs-*.preserved`: content preserved during a conflict. Do not delete or share these files.

## Common messages

- **[DSC-E05]:** Discord is open. Quit Discord with Cmd+Q and choose "Reconnect".
- **[PRF-E04]:** Full Disk Access is missing. Follow the first-launch steps.
- **[PRF-E03]:** The installed Discord version's startup module was not found in a supported layout or was incomplete. The older macos-v0.2 app checked only numbered modules under `app-<version>/modules`; v0.3 also recognizes the flat `<version>/modules/discord_desktop_core` layout. This layout mismatch could explain the earlier error, but the affected Mac's Discord profile was not inspected, so its exact cause is unconfirmed. Open official Discord, let its initial installation or update finish, quit it with Cmd+Q, then choose **Reconnect**. If the error persists, report the code and Discord version. Full Disk Access or Open Anyway cannot create a missing module.
- **[SES-E01]:** The connection closed while Discord was open. Quit Discord and open DiscordAccess again, or run `--restore`.
- **[SYS-E03]:** The app is not in a trusted location. Move it to Applications and open it from there.

When reporting a problem, include the version, the short error code and the steps. Do not share account tokens, profile files, the recovery record, signed attachment links or personal paths. For security reports, see [SECURITY.md](https://github.com/alpertknn/DiscordAccess/blob/main/SECURITY.md) in the repository root; the macOS trust boundaries are in [SECURITY-NOTES.md](https://github.com/alpertknn/DiscordAccess/blob/main/macos/docs/SECURITY-NOTES.md).
