import Darwin
import Foundation
import ServiceManagement

/// Starting DiscordAccess at login (design 7.4): a launch agent inside the app bundle (`Contents/Library/LaunchAgents`)
/// that starts the app with `--startup`, registered through `SMAppService`. Only an app bundle in a trusted location
/// registers (`verifyLocation`); turning it off unregisters it, and quitting changes nothing.
public enum StartupRegistration {
    public static let agentName = "io.github.alpertknn.DiscordAccess.agent.plist"

    public enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but macOS waits for the user's approval in System Settings > General > Login Items.
        case needsApproval
    }

    /// Only an app bundle can register a launch agent.
    public static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static var state: State {
        guard isAvailable else { return .disabled }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        default: return .disabled
        }
    }

    /// Registers the agent once the app's location is trusted (SYS-E03); SYS-E04 when macOS refuses.
    @discardableResult
    public static func enable() throws -> State {
        guard isAvailable else { throw KitError.startupRegistrationFailed() }
        try verifyLocation(Bundle.main.bundlePath)
        if state == .disabled {
            do {
                try service.register()
            } catch {
                throw KitError.startupRegistrationFailed()
            }
        }
        return state
    }

    public static func disable() throws {
        guard isAvailable, state != .disabled else { return }
        do {
            try service.unregister()
        } catch {
            guard state == .disabled else { throw KitError.startupRegistrationFailed() }
        }
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static var service: SMAppService {
        SMAppService.agent(plistName: agentName)
    }

    /// Whether the app at `bundle` may start by itself at login (Windows `StartupPathTrust`): an app bundle at its own real
    /// path, outside App Translocation, where every folder from the root down and everything in the bundle belongs to
    /// this user or root and no one else can change it. The admin group may write, as it can in /Applications: its
    /// members can become root anyway. An access control entry that allows a change is refused as well, and so is a
    /// volume that is not local or ignores ownership (macOS ignores it on external drives by default, where every file
    /// then seems to belong to whoever asks). SYS-E03 otherwise.
    public static func verifyLocation(_ bundle: String = Bundle.main.bundlePath) throws {
        let failure = KitError.startupLocationUnsafe()
        guard bundle.hasSuffix(".app"), !bundle.contains("/AppTranslocation/"), (try? SafeFile.requireNoLinks(bundle)) != nil,
              let resolved = realpath(bundle, nil) else { throw failure }
        let real = String(cString: resolved)
        free(resolved)
        guard real == bundle else { throw failure }
        var folder = ""
        try trusted("/")
        for component in bundle.split(separator: "/").dropLast() {
            folder += "/" + component
            try trusted(folder)
        }
        try trusted(bundle)
        // A folder the enumeration cannot read fails the check instead of being skipped.
        var unreadable = false
        guard let contents = FileManager.default.enumerator(at: URL(fileURLWithPath: bundle), includingPropertiesForKeys: nil, options: [],
                                                            errorHandler: { _, _ in
                                                                unreadable = true
                                                                return false
                                                            }) else { throw failure }
        while let item = contents.nextObject() as? URL { try trusted(item.path) }
        guard !unreadable else { throw failure }
    }

    private static func trusted(_ path: String) throws {
        var status = stat()
        var volume = statfs()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR || status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid() || status.st_uid == 0, status.st_mode & S_IWOTH == 0,
              status.st_mode & S_IWGRP == 0 || status.st_gid == 0 || status.st_gid == 80, statfs(path, &volume) == 0,
              volume.f_flags & UInt32(MNT_LOCAL) != 0, volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0, !allowsChanges(path) else {
            throw KitError.startupLocationUnsafe()
        }
    }

    /// Whether an access control entry of `path` allows anyone to change it or what it holds; a list that cannot be read
    /// counts as allowing.
    private static func allowsChanges(_ path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let changes: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
                                     ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        var entry: acl_entry_t?
        var next = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, next, &entry) == 0, let current = entry {
            next = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(current, &tag) == 0, acl_get_permset(current, &permissions) == 0, let permissions else { return true }
            if tag == ACL_EXTENDED_ALLOW && changes.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) { return true }
        }
        return false
    }
}
