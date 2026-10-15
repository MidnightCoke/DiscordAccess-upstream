import Darwin
import Foundation

/// The session's log in the private state folder (Windows `SessionLog`): `session.log`, 0600, started anew once it reaches
/// 256 KiB. It gets the terminal's lines and the gate's and bridge's fixed-category diagnostics, never a link, token or
/// header. A line that cannot be written is dropped: logging must never stop the session or its cleanup.
public final class SessionLog {
    static let limit: off_t = 256 * 1024

    public let path: String
    private let lock = NSLock()
    private let format: DateFormatter

    public init(state: String = StateStore.standardRoot) throws {
        try SafeFile.ensurePrivateDirectory(state, create: true)
        path = state + "/session.log"
        format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(), status.st_nlink == 1,
              status.st_mode & 0o077 == 0 || fchmod(descriptor, 0o600) == 0 else { return }
        if status.st_size >= Self.limit && ftruncate(descriptor, 0) != 0 { return }
        let bytes = Array((format.string(from: Date()) + "  " + text + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            offset += count
        }
    }
}

/// The one DiscordAccess session of this user (Windows `ResidentInstance`): an exclusive lock on `session.lock` in the
/// private state folder, held while the process runs and released by the system when it ends, a crash included. A second
/// instance must neither undo nor make profile changes while the first one's are in place.
public final class SessionLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    /// The lock, or nil while another process holds it.
    public static func acquire(state: String = StateStore.standardRoot) throws -> SessionLock? {
        try SafeFile.ensurePrivateDirectory(state, create: true)
        let descriptor = open(state + "/session.lock", O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw SafeFile.failure(errno) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid() else {
            close(descriptor)
            throw KitError.profileConflict()
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw SafeFile.failure(code)
        }
        return SessionLock(descriptor: descriptor)
    }
}
