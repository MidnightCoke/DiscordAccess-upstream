import CryptoKit
import Darwin
import Foundation

/// Careful file operations on Discord's profile and DiscordAccess's own state (design 8, "File operations"; Windows
/// `FileTransaction`). Paths are absolute and spelled as the system reports them, and no existing component may be a
/// symbolic link. Files are regular, owned by this user, and read with a size limit.
///
/// A replacement is a compare-and-swap: the new bytes go into a new file beside the target, which is swapped in
/// atomically (`renamex_np` with `RENAME_SWAP`); what that displaced must be what was expected. Anything else is put back
/// while the new bytes are still in place, and kept beside the target as `.discordaccess-fs-<id>.preserved` either way:
/// unknown bytes are never deleted. Failures are `PRF-E01`; a file macOS keeps from this process (`EPERM`) is `PRF-E04`.
enum SafeFile {
    /// The file's bytes, or nil when it does not exist.
    static func read(_ path: String, limit: Int) throws -> [UInt8]? {
        try requireNoLinks(path)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw failure(errno)
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(), status.st_size >= 0,
              status.st_size <= off_t(limit), realPath(descriptor) == path else { throw KitError.profileConflict() }
        // One byte more than the size, so that a file growing while it is read shows.
        var bytes = [UInt8](repeating: 0, count: Int(status.st_size) + 1)
        var count = 0
        while count < bytes.count {
            let result = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + count, $0.count - count) }
            if result < 0 {
                if errno == EINTR { continue }
                throw failure(errno)
            }
            if result == 0 { break }
            count += result
        }
        guard count <= Int(status.st_size) else { throw KitError.profileConflict() }
        return Array(bytes[..<count])
    }

    /// Replaces the file holding exactly `expected` (nil: no file) with `replacement`. A replaced file keeps its
    /// permission bits; a new one gets `mode`. `keepDisplaced` keeps even the expected old bytes beside the file, for
    /// content DiscordAccess recognized but did not write itself. `beforeSwap` lets tests act as another writer at the
    /// last moment.
    static func replace(_ path: String, expected: [UInt8]?, with replacement: [UInt8], limit: Int, mode: mode_t,
                        keepDisplaced: Bool = false, beforeSwap: (() -> Void)? = nil) throws {
        try requireNoLinks(path)
        guard expected != replacement else { return }
        var status = stat()
        let kept = expected != nil && lstat(path, &status) == 0 ? status.st_mode & 0o777 : mode
        let stamp = (path as NSString).deletingLastPathComponent + "/.discordaccess-fs-" + UUID().uuidString.lowercased()
        let pending = stamp + ".pending"
        try writeNew(pending, replacement, mode: kept)
        // What `pending` holds: the new bytes, then what the swap displaced.
        var owned = replacement
        defer { removeOwned(pending, expected: owned, limit: limit) }
        guard let expected else {
            // A file that appeared meanwhile is never overwritten.
            beforeSwap?()
            guard renamex_np(pending, path, UInt32(RENAME_EXCL)) == 0 else { throw failure(errno) }
            syncDirectory(of: path)
            return
        }
        guard try read(path, limit: limit) == expected else { throw KitError.profileConflict() }
        beforeSwap?()
        guard renamex_np(pending, path, UInt32(RENAME_SWAP)) == 0 else { throw failure(errno) }
        syncDirectory(of: path)
        let displaced = try? read(pending, limit: limit)
        guard displaced == expected else {
            // Another writer replaced the file between the comparison and the swap: its bytes are kept and put back.
            if renamex_np(pending, stamp + ".preserved", UInt32(RENAME_EXCL)) == 0, let displaced {
                undo(path, replacement: replacement, unknown: displaced, stamp: stamp, limit: limit, mode: kept)
            }
            throw KitError.profileConflict()
        }
        if keepDisplaced { _ = renamex_np(pending, stamp + ".preserved", UInt32(RENAME_EXCL)) }
        owned = expected
    }

    /// Deletes the file holding exactly `expected`. Other bytes stay, at the path or beside it, and are reported.
    static func delete(_ path: String, expected: [UInt8], limit: Int) throws {
        try requireNoLinks(path)
        let stamp = (path as NSString).deletingLastPathComponent + "/.discordaccess-fs-" + UUID().uuidString.lowercased()
        let moving = stamp + ".deleting"
        guard renamex_np(path, moving, UInt32(RENAME_EXCL)) == 0 else { throw failure(errno) }
        guard let bytes = try? read(moving, limit: limit), bytes == expected else {
            if renamex_np(moving, path, UInt32(RENAME_EXCL)) != 0 { _ = renamex_np(moving, stamp + ".preserved", UInt32(RENAME_EXCL)) }
            throw KitError.profileConflict()
        }
        guard unlink(moving) == 0 else { throw failure(errno) }
        syncDirectory(of: path)
        // A file that took the name meanwhile stays, and is reported.
        var status = stat()
        guard lstat(path, &status) != 0, errno == ENOENT else { throw KitError.profileConflict() }
    }

    /// A folder only this user can use: owned by it, without access for group or others, and without access control
    /// entries (which could grant what the mode does not show). `create` makes it when it is missing; its parent must
    /// exist.
    static func ensurePrivateDirectory(_ path: String, create: Bool) throws {
        try requireNoLinks(path)
        var status = stat()
        if lstat(path, &status) != 0 {
            guard errno == ENOENT, create else { throw failure(errno) }
            guard mkdir(path, 0o700) == 0 || errno == EEXIST, lstat(path, &status) == 0 else { throw failure(errno) }
        }
        guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid(), status.st_mode & 0o077 == 0 else { throw KitError.profileConflict() }
        if let entries = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(entries))
            throw KitError.profileConflict()
        }
    }

    /// The path is absolute and canonical, and no existing component of it is a symbolic link.
    static func requireNoLinks(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), path.utf8.count < Int(MAXPATHLEN), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw KitError.profileConflict() }
        var current = ""
        for component in components {
            current += "/" + component
            var status = stat()
            guard lstat(current, &status) == 0 else {
                if errno == ENOENT { return }
                throw failure(errno)
            }
            guard status.st_mode & S_IFMT != S_IFLNK else { throw KitError.profileConflict() }
        }
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The error for a failed call: macOS keeping the file from this process (TCC) is reported as such.
    static func failure(_ code: Int32) -> KitError {
        code == EPERM ? KitError.profileAccessDenied() : KitError.profileConflict()
    }

    private static func writeNew(_ path: String, _ bytes: [UInt8], mode: mode_t) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw failure(errno) }
        var written = 0
        var failed = false
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + written, $0.count - written) }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else {
                failed = true
                break
            }
            written += result
        }
        // F_FULLFSYNC reaches the disk itself, so that a journal written first stays first after a power loss.
        if failed || fchmod(descriptor, mode) != 0 || (fcntl(descriptor, F_FULLFSYNC) != 0 && fsync(descriptor) != 0) {
            let error = errno
            close(descriptor)
            unlink(path)
            throw failure(error)
        }
        close(descriptor)
    }

    /// Puts unknown bytes back while the new bytes are still in place; their preserved copy stays either way.
    private static func undo(_ path: String, replacement: [UInt8], unknown: [UInt8], stamp: String, limit: Int, mode: mode_t) {
        let restoring = stamp + ".restore"
        guard (try? writeNew(restoring, unknown, mode: mode)) != nil else { return }
        guard (try? read(path, limit: limit)) == replacement, renamex_np(restoring, path, UInt32(RENAME_SWAP)) == 0 else {
            removeOwned(restoring, expected: unknown, limit: limit)
            return
        }
        // `restoring` now holds what this displaced: the new bytes, unless yet another writer came.
        removeOwned(restoring, expected: replacement, limit: limit)
    }

    /// Makes a rename in the folder of `path` durable; best effort.
    private static func syncDirectory(of path: String) {
        let directory = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }
        if fcntl(directory, F_FULLFSYNC) != 0 { _ = fsync(directory) }
        close(directory)
    }

    /// Removes a file of this transaction, but only while it holds exactly `expected`; best effort.
    private static func removeOwned(_ path: String, expected: [UInt8], limit: Int) {
        guard let bytes = try? read(path, limit: limit), bytes == expected else { return }
        unlink(path)
    }

    private static func realPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }
}
