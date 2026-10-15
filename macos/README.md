# DiscordAccess for macOS — usage

These notes cover the **macos-v0.1** pre-release. It runs only on Apple Silicon (arm64) Macs and has been tested only on macOS 27. The app's interface is in Turkish. Design details: [DESIGN.md](https://github.com/alpertknn/DiscordAccess/blob/main/macos/docs/DESIGN.md).

## Requirements

- An Apple Silicon Mac with macOS 13 or later.
- The official Discord (Stable) app in `/Applications/Discord.app` or `~/Applications/Discord.app`. PTB and Canary are not supported.
- A standard user account. DiscordAccess does not run as root.

## Installing the release package

1. On the [Releases](https://github.com/alpertknn/DiscordAccess/releases) page, download `DiscordAccess-macos-v0.1.zip` from the **macos-v0.1** release and open it. `DiscordAccess-macos-v0.1-engine-source.zip` is the engine's source package; you do not need it to run the app.
2. Drag `DiscordAccess.app` into the Applications folder in Finder.
3. The app is not signed or notarized by Apple, so on first launch macOS says that Apple could not verify that "DiscordAccess" is free of malware:
   - Click **Done**.
   - Open System Settings > Privacy & Security. In the **Security** section at the bottom, click **Open Anyway** for DiscordAccess and enter your password.
   - Open the app again and choose **Open Anyway** in the final dialog.

   You only need to approve it once.
4. Then follow "First launch" below.

The package's `LICENSES.txt` holds the license notices and `SOURCE.txt` identifies the source package. In the macos-v0.1 package these files are named `LISANSLAR.txt` and `KAYNAK.txt`, and these notes are included in Turkish as `OKU-BENI.md`. You can compare the SHA-256 of a downloaded file with the release's `SHA256SUMS.txt`:
```bash
shasum -a 256 DiscordAccess-macos-v0.1.zip
```
A hash file is not a code signature.

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
3. macOS protects Discord's data folder from other apps and shows no permission prompt for it. On first launch an alert titled "Tam Disk Erişimi gerekiyor" (Full Disk Access required) appears:
   - Click "Sistem Ayarları'nı aç" (Open System Settings) and turn on DiscordAccess under Full Disk Access.
   - Then restart the app.
   - Discord's settings are never changed without this permission.
   - With an ad-hoc signed build, the permission has to be granted again after every new build.
4. Wait for the "Bağlantı hazır" (Connection ready) notification. Open Discord from its own icon (Dock, Launchpad, Spotlight) or with "Discord'u aç" in the menu. Your existing installation and account are used; no copy is made.
5. When you are done, quit Discord first, then choose "Çıkış" (Quit) in the menu. If you quit while Discord is still open, Discord is not closed: the recovery record of the temporary settings is kept, and the settings are undone at the next launch or with `--restore`.

## Menu

- **Status line:** the state of the connection.
- **"Discord'u aç" (Open Discord):** opens Discord while the connection is ready. If Discord is already open, it is not opened again.
- **"Yeniden bağlan" (Reconnect):** re-establishes a connection that closed or could not be set up.
- **"Bağlantıyı kontrol et" (Check connection):** anonymously checks HTTPS access to Discord and the Gateway connection (HELLO). No account data is sent.
- **"Oturum açılışında başlat" (Start at login):** starts DiscordAccess at login.
  - After the first working connection it turns itself on, unless you turned it off. Once you turn it off, it stays off.
  - Only an app in a trusted location registers; the Applications folder qualifies. External drives and folders other users can change are refused.
  - If macOS asks for approval, allow DiscordAccess under System Settings > General > Login Items.
- **"Girişte Discord'u da aç" (Also open Discord at login):** opens Discord once at login, after the connection is ready. Off by default. Turn off Discord's own "open at startup" setting; otherwise Discord opens before the connection and connecting fails.
- **"Çıkış" (Quit):** closes the connection and undoes the temporary settings.

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

- **[DSC-E05]:** Discord is open. Quit Discord with Cmd+Q and choose "Yeniden bağlan" (Reconnect).
- **[PRF-E04]:** Full Disk Access is missing. Follow the first-launch steps.
- **[SES-E01]:** The connection closed while Discord was open. Quit Discord and open DiscordAccess again, or run `--restore`.
- **[SYS-E03]:** The app is not in a trusted location. Move it to Applications and open it from there.

When reporting a problem, include the version, the short error code and the steps. Do not share account tokens, profile files, the recovery record, signed attachment links or personal paths. For security reports, see [SECURITY.md](https://github.com/alpertknn/DiscordAccess/blob/main/SECURITY.md) in the repository root; the macOS trust boundaries are in [SECURITY-NOTES.md](https://github.com/alpertknn/DiscordAccess/blob/main/macos/docs/SECURITY-NOTES.md).
