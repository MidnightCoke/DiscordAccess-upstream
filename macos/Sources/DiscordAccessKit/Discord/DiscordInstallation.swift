import Darwin
import Foundation
import Security

/// The official Discord (Stable) app of the session (Windows `DiscordInstallation`; design 8, "Discord kurulumu"): a
/// `Discord.app` on a local volume whose path holds no link, with Discord's bundle identifier and executable, the stable
/// release channel, and a valid signature by Discord's Developer ID (`DiscordApplication.requirement`), its nested code
/// and every architecture included.
public struct DiscordInstallation: Equatable, Sendable {
    static let bundleIdentifier = "com.hnc.Discord"
    static let maxMetadataBytes = 1_048_576

    /// The real path, in the form processes report (`/Applications/...`, never `/System/Volumes/Data/...`).
    public let bundle: String
    /// The host version (`build_info.json`), as in the profile's `app-<version>` folder.
    public let version: String

    /// `/Applications/Discord.app` and `~/Applications/Discord.app`.
    public static var standardLocations: [String] {
        ["/Applications/Discord.app", DiscordProfile.home() + "/Applications/Discord.app"]
    }

    /// The installation at `path`, or the one standard location that holds one; more than one is not chosen between.
    public static func locate(path: String? = nil, candidates: [String] = standardLocations) throws -> DiscordInstallation {
        if let path { return try verify(bundle: path) }
        var status = stat()
        let found = try candidates.filter { lstat($0, &status) == 0 }.map(verify)
        guard found.count <= 1 else { throw KitError.discordAmbiguous() }
        guard let installation = found.first else { throw KitError.discordNotFound() }
        return installation
    }

    /// The signature is checked first, so that only Discord's own files are read afterwards.
    public static func verify(bundle path: String) throws -> DiscordInstallation {
        let bundle = try processPath(path)
        let contents = bundle + "/Contents"
        guard signed(bundle), let info = metadata(contents + "/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier, plist["CFBundleExecutable"] as? String == "Discord",
              let build = metadata(contents + "/Resources/build_info.json"),
              let buildInfo = try? JSONSerialization.jsonObject(with: build) as? [String: Any], buildInfo["releaseChannel"] as? String == "stable",
              let version = buildInfo["version"] as? String, DiscordProfileChanges.validVersion(version) else {
            throw KitError.discordUnverified(path)
        }
        return DiscordInstallation(bundle: bundle, version: version)
    }

    /// The executables of this Discord.app that may use the gate and the update bridge.
    public var approvedExecutables: [ApprovedExecutable] {
        DiscordApplication.approvedExecutables(bundle: bundle)
    }

    /// This user's processes running from this or any other Discord.app (a copy elsewhere, or a translocated one, shares
    /// the profile); the profile may only change while there are none. A process list that cannot be read completely is
    /// DSC-E04: Discord may be running.
    public func runningProcesses() throws -> [pid_t] {
        guard let processes = ProcessInspector.completeUserProcessIDs(uid: getuid()) else { throw KitError.discordStateUnknown() }
        return processes.filter { pid in
            guard let path = ProcessInspector.record(for: pid)?.path else { return false }
            return path.hasPrefix(bundle + "/Contents/") || path.contains("/Discord.app/Contents/")
        }
    }

    /// `path` as processes report it: a `/System/Volumes/Data/...` spelling becomes the firmlinked one if it names the
    /// same bundle. It must be an absolute `.app` path without links, its own real path, on a local volume.
    static func processPath(_ path: String) throws -> String {
        let data = "/System/Volumes/Data"
        let bundle = path.hasPrefix(data + "/") ? String(path.dropFirst(data.count)) : path
        var original = stat()
        var mapped = stat()
        var volume = statfs()
        guard bundle.hasSuffix(".app"), (try? SafeFile.requireNoLinks(bundle)) != nil, let real = realpath(bundle, nil) else {
            throw KitError.discordUnverified(path)
        }
        defer { free(real) }
        guard String(cString: real) == bundle, lstat(path, &original) == 0, lstat(bundle, &mapped) == 0, original.st_dev == mapped.st_dev,
              original.st_ino == mapped.st_ino, mapped.st_mode & S_IFMT == S_IFDIR, statfs(bundle, &volume) == 0,
              volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw KitError.discordUnverified(path) }
        return bundle
    }

    /// A small regular file of the bundle, read without following a link or waiting on a pipe.
    private static func metadata(_ path: String) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size <= off_t(maxMetadataBytes),
              let data = try? handle.read(upToCount: maxMetadataBytes + 1), data.count <= maxMetadataBytes else { return nil }
        return data
    }

    private static func signed(_ bundle: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundle) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(DiscordApplication.requirement(identifier: bundleIdentifier) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }
}
