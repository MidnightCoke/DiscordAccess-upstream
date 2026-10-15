# Security boundaries (macOS)

This document summarizes what the macOS version relies on and what it does not. Details and reasons are in section 8 of the [design document](DESIGN.md). Passing automated tests does not prove that the software has no vulnerabilities or that it works under every Discord and network condition. Real-account use, voice and start at login are verified separately; the checks performed are listed with their dates in section 10 of the design document.

## Protected technical boundaries

- **Local gate:** listens only on 127.0.0.1.
  - It admits processes that run one of the five executables of the selected Discord.app (`Discord` and the four `Discord Helper` apps), started after the session became ready, and that carry Discord's signature (Team ID `53Q6R32WPB`).
  - The app's own diagnostic requests are admitted as well.
  - The gate verifies the owner of every connection. It allows only the Discord domains on the Windows allow list and at most 64 connections.
  - Its log holds fixed categories only, never an address, header or body.
- **Engine:** verified by a pinned SHA-256 and cdhash.
  - It starts suspended and is killed before any of its code runs if its signature does not match the pinned value.
  - It listens only on loopback, with a random credential for every run.
  - It is embedded in the bundle unchanged.
  - An engine left behind by a crash is stopped at the next launch.
- **Update bridge:** listens on loopback with a random path token, for Discord's own updater.
  - Like the gate, it answers only admitted processes.
  - It goes only to Discord's domains, over HTTPS and through the gate.
  - It refuses redirects that leave Discord.
- **Profile changes:** written to a recovery record first, applied with an atomic compare-and-swap (`renamex_np`) and flushed to disk with `F_FULLFSYNC`.
  - A value the user changed later is never overwritten; unrecognized content is preserved as `.discordaccess-fs-*.preserved`.
  - Nothing is undone while Discord runs; renamed copies of Discord count as running too.
  - Recovery touches only the standard Discord folder and writes back only Discord's own HTTPS addresses to the update settings.
- **State folder:** 0700 without ACLs; files 0600. If the user does not own the folder or others can access it, no profile change is made.
- **Single session:** enforced with a `flock` lock in the state folder. The lock is held until the process exits, so a second instance cannot touch the first one's changes.
- **Opening Discord:** done with `/usr/bin/open`.
  - `open` starts with only its standard descriptors, all on /dev/null (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
  - Launch Services starts Discord; Discord does not inherit this process's environment.
- **Start at login:** only an app bundle in a trusted location registers. A trusted location means:
  - every folder from the root down and every file in the bundle belongs to the user or root;
  - no one else can write to it (the group may write only if it is admin), and no access control entry grants changes;
  - the path holds no links and the app is not under App Translocation;
  - the volume is local and does not ignore ownership.

  The location is checked again on every login launch; if it is no longer trusted, the registration is removed.
- **Attachment download (D in Terminal):** only Discord attachment links are accepted (HTTPS, port 443).
  - At most three redirects are followed, each validated again.
  - The file is saved into a new folder, without following links and without overwriting an existing file.
  - The file is marked as downloaded from the internet (quarantine attribute).
  - The signed link never reaches the log, the screen or the file name.
- **Screen and log lines:** control characters and text-direction marks are replaced with spaces, so a file name cannot steer the terminal or disguise its extension.
- **Full Disk Access:** used only for the owned files in Discord's data folder. The app never grants itself the permission; it explains why it is needed and opens System Settings.

## Scope

DiscordAccess runs with standard user privileges. It changes no system-wide proxy, DNS or routing setting and installs no system service, driver or network extension. It never runs downloaded files.

No separate security boundary is claimed against:

- Malware that already runs with the same user's privileges, or a root attacker. For example, Discord's Electron configuration leaves `NODE_OPTIONS` enabled: a process running as the same user can run code inside a Discord-signed process. The same holds on Windows.
- Any guarantee a signature gives about content. A code signature proves which file runs, not what code runs inside it.
- Gatekeeper approval. The app is unsigned or signed with a local certificate. Developer ID signing and notarization for distribution are a separate decision.
- Permission changes after registration. A past check cannot vouch for permissions that the user changes independently after start at login is registered. The check on each login launch catches only a moved app or loosened permissions.

In regular bug reports, do not share account tokens, profile files, the recovery record, signed attachment links, `.preserved` files or personal paths. The vulnerability reporting process is in [SECURITY.md](../../SECURITY.md) in the repository root.
