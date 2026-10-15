import Foundation

/// A user-facing failure. Codes follow the Windows `PKG-E*` family where the meaning is the same.
public struct KitError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "[" + code + "] " + message }

    static func engineMissing(_ path: String) -> KitError {
        KitError(code: "PKG-E01", message: path + " was not found. The package is incomplete; reinstall DiscordAccess.")
    }

    static func engineUnreadable(_ path: String) -> KitError {
        KitError(code: "PKG-E02", message: path + " could not be read. Reinstall DiscordAccess and try again.")
    }

    static func engineIntegrity(_ path: String) -> KitError {
        KitError(code: "PKG-E03", message: path + " failed the integrity check. Reinstall DiscordAccess.")
    }

    static func engineUnsafePath(_ path: String) -> KitError {
        KitError(code: "PKG-E04", message: path + " could not be verified as a safe file path. Install DiscordAccess in a normal local folder.")
    }

    static func engineStartFailed() -> KitError {
        KitError(code: "ENG-E01", message: "The connection engine did not become ready.")
    }

    static func engineStopped() -> KitError {
        KitError(code: "ENG-E02", message: "The connection engine stopped.")
    }

    static func invalidDnsOption() -> KitError {
        KitError(code: "DNS-E01", message: "The DNS option is invalid or repeated. Choose --dns=auto, --dns=cloudflare, --dns=cloudflare-ip or " +
            "--dns=google; add --dns-record-fragment once if needed.")
    }

    /// Every candidate failed its check; only this fixed message is shown (Windows `DnsSelectionException`).
    static func dnsSelectionFailed() -> KitError {
        KitError(code: "DNS-E02", message: "No DNS connection could reach Discord. Check your internet connection and reconnect.")
    }

    static func dnsCandidateNotClosed() -> KitError {
        KitError(code: "DNS-E03", message: "The DNS connection could not be closed safely; no other candidate was started.")
    }

    static func randomUnavailable() -> KitError {
        KitError(code: "SYS-E01", message: "A secure random value could not be generated.")
    }

    static func hookIntegrity() -> KitError {
        KitError(code: "PKG-E05", message: "The attachment download hook failed the integrity check. Reinstall DiscordAccess.")
    }

    static func discordNotFound() -> KitError {
        KitError(code: "DSC-E01", message: "The official Discord (Stable) installation was not found. Install Discord in the Applications folder " +
            "or give its path with --discord-path.")
    }

    static func discordUnverified(_ path: String) -> KitError {
        KitError(code: "DSC-E02", message: path + " could not be verified as the official Discord (Stable) app: its signature, bundle identifier, " +
            "release channel or path is not valid.")
    }

    /// The process list could not be read completely, so Discord may be running.
    static func discordStateUnknown() -> KitError {
        KitError(code: "DSC-E04", message: "Could not check whether Discord is open. Quit Discord completely and try again.")
    }

    static func discordAmbiguous() -> KitError {
        KitError(code: "DSC-E03", message: "More than one official Discord installation was found. Choose one with --discord-path.")
    }

    static func discordRunning() -> KitError {
        KitError(code: "DSC-E05", message: "Quit Discord completely first (Discord > Quit Discord, or Cmd+Q), then open DiscordAccess again. " +
            "The open Discord was not changed.")
    }

    static func discordOpenedDuringPreparation() -> KitError {
        KitError(code: "DSC-E06", message: "Discord was opened during preparation. Quit Discord completely and open DiscordAccess again; no " +
            "settings were changed.")
    }

    /// `--restore` changes nothing while Discord runs.
    static func discordRunningDuringRestore() -> KitError {
        KitError(code: "DSC-E07", message: "Quit Discord completely first (Discord > Quit Discord, or Cmd+Q), then run DiscordAccess --restore. " +
            "The pending recovery record is kept.")
    }

    static func discordLaunchFailed() -> KitError {
        KitError(code: "DSC-E08", message: "The request to open Discord could not be sent. You can open Discord from the Dock, Launchpad or " +
            "Spotlight; the connection stays open.")
    }

    /// Discord was open when the session ended, or undoing failed: the journal is kept for the next start or `--restore`.
    static func sessionRestoreDeferred() -> KitError {
        KitError(code: "SES-E01", message: "The connection closed. Quit Discord completely and run DiscordAccess --restore, or open DiscordAccess " +
            "again. The recovery record of the temporary settings was kept.")
    }

    static func sessionNotReady() -> KitError {
        KitError(code: "SES-E02", message: "The connection is not ready.")
    }

    static func discordChanged() -> KitError {
        KitError(code: "SES-E03", message: "Discord has changed. Quit Discord completely, then quit DiscordAccess and open it again.")
    }

    /// `--restore` while another DiscordAccess holds the session (Windows `ResidentInstance`).
    static func sessionStillOpen() -> KitError {
        KitError(code: "SES-E04", message: "DiscordAccess is still running. Close the current connection first.")
    }

    /// Windows `Safety.RejectElevation`: root would own the files it writes in the user's folders.
    static func runningAsRoot() -> KitError {
        KitError(code: "SYS-E02", message: "DiscordAccess does not run as an administrator (root). Open it with your own user account, without sudo.")
    }

    /// Windows `StartupPathTrust`: an app that others could change must not start by itself at login.
    static func startupLocationUnsafe() -> KitError {
        KitError(code: "SYS-E03", message: "DiscordAccess is not in a trusted location, so start at login was not set up. Move the app to the " +
            "Applications folder and open it from there.")
    }

    static func startupRegistrationFailed() -> KitError {
        KitError(code: "SYS-E04", message: "Start at login could not be changed. Check System Settings > General > Login Items.")
    }

    /// Windows `InstalledDiscord.Conflict`: nothing that changed since is overwritten.
    static func profileConflict() -> KitError {
        KitError(code: "PRF-E01", message: "Discord's temporary settings could not be verified safely. No changed file or preference was overwritten.")
    }

    static func profileUnsupported() -> KitError {
        KitError(code: "PRF-E02", message: "The official Discord version or its startup module was not recognized; Discord's files were not changed.")
    }

    static func profileMissingModule() -> KitError {
        KitError(code: "PRF-E03", message: "Discord's expected startup module was not found. Open and quit Discord normally once, then " +
            "try again.")
    }

    /// PRF-E04 as the app shows it: run outside an app bundle (from a terminal), macOS asks Full Disk Access of the
    /// terminal app.
    public static func profileAccessDenied(inTerminal: Bool) -> KitError {
        inTerminal ? profileAccessDeniedInTerminal() : profileAccessDenied()
    }

    /// Run from a terminal, macOS asks Full Disk Access of the terminal app, not of DiscordAccess.
    static func profileAccessDeniedInTerminal() -> KitError {
        KitError(code: "PRF-E04", message: "DiscordAccess cannot access Discord's data folder. When it runs from Terminal, macOS grants this " +
            "permission to the terminal app: turn on Terminal (or the terminal app you use) under System Settings > Privacy & Security > Full " +
            "Disk Access, quit and reopen that app, and run DiscordAccess again. Discord's settings are never changed without this permission.")
    }

    /// macOS keeps Discord's data folder from other apps without asking (TCC); only Full Disk Access opens it.
    static func profileAccessDenied() -> KitError {
        KitError(code: "PRF-E04", message: "DiscordAccess cannot access Discord's data folder. Turn on DiscordAccess under System Settings > " +
            "Privacy & Security > Full Disk Access. Discord's settings are never changed without this permission.")
    }
}

/// Alerts and notifications show the message with its code.
extension KitError: LocalizedError {
    public var errorDescription: String? { description }
}
