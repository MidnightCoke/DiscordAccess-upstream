import Darwin
import Foundation

/// Discord's data folder, as DiscordAccess may use it (design 3, TCC finding; 7.1).
public enum DiscordProfile {
    /// `~/Library/Application Support/discord`: settings, and the host versions with their modules.
    public static var standardRoot: String { home() + "/Library/Application Support/discord" }

    /// System Settings' Full Disk Access page: macOS shows no permission prompt for another app's data.
    public static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!

    public enum Access: Equatable, Sendable {
        case granted
        /// macOS keeps the folder from this process (TCC), or its permissions do.
        case denied
        case missing
    }

    /// Opens System Settings at Full Disk Access; true when the request went out.
    @discardableResult
    public static func openFullDiskAccessSettings() -> Bool {
        Launcher.open([fullDiskAccessSettings.absoluteString])
    }

    /// Whether this process may read the folder at `root`. macOS protects Discord's data from other apps without asking,
    /// so without Full Disk Access reading its contents fails.
    public static func access(root: String) -> Access {
        guard let directory = opendir(root) else { return errno == ENOENT ? .missing : .denied }
        defer { closedir(directory) }
        errno = 0
        while readdir(directory) != nil {}
        guard errno == 0 else { return .denied }
        let settings = open(root + "/settings.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if settings >= 0 {
            close(settings)
        } else if errno == EPERM || errno == EACCES {
            return .denied
        }
        return .granted
    }

    /// Where Discord's process writes the attachment download hook's records: in Discord's own folder, which Discord can
    /// always reach, whatever macOS does with DiscordAccess's folder (design 12).
    public static func downloadLog(root: String) -> String {
        root + "/DiscordAccess-downloads.log"
    }

    static func home() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}

/// DiscordAccess's own data folder (design 8, "State folder"): `~/Library/Application Support/DiscordAccess`, private to
/// this user, with the profile changes' journal in `installed-session`.
public enum StateStore {
    public static var standardRoot: String { DiscordProfile.home() + "/Library/Application Support/DiscordAccess" }

    /// The folder of the profile changes' journal under `root`; both folders are made, or checked, private.
    static func sessionDirectory(root: String, create: Bool) throws -> String {
        try SafeFile.ensurePrivateDirectory(root, create: create)
        let session = root + "/installed-session"
        try SafeFile.ensurePrivateDirectory(session, create: create)
        return session
    }
}
