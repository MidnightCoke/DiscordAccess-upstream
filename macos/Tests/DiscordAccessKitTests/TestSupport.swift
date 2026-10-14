import CryptoKit
import Darwin
import Foundation

/// The engine built by `macos/scripts/build-engine.py`; engine tests are skipped when it is absent.
enum TestEngine {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var path: String { realPath(packageRoot.appendingPathComponent("build/engine/sing-box").path) }
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// A copy of the engine for tests that run a copy, kept under `build/test-engines/<SHA-256 prefix>`. macOS scans every
    /// newly run file in the background; its scanner (syspolicyd) crashed when test copies were deleted mid-scan. Copies
    /// are therefore never deleted or replaced: a rebuilt engine gets a new folder.
    static func runnableCopy(named name: String) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
        let folder = packageRoot.appendingPathComponent("build/test-engines/" + digest.prefix(16)).path
        let copy = folder + "/" + name
        if !FileManager.default.fileExists(atPath: copy) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            // An interrupted copy never takes the final name, and a copy made meanwhile by another run is kept.
            let partial = copy + ".partial-" + UUID().uuidString
            try FileManager.default.copyItem(atPath: path, toPath: partial)
            guard renamex_np(partial, copy, UInt32(RENAME_EXCL)) == 0 || errno == EEXIST else { throw lastPOSIXError() }
        }
        return realPath(copy)
    }
}

func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A temporary directory addressed by its real (link-free) path; removed when released.
final class TemporaryDirectory {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("discordaccess-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = realPath(base.path)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// A TCP listener owned by the test process, on 127.0.0.1 unless another IPv4 address is given.
final class TCPListener {
    let descriptor: Int32
    let port: UInt16

    init(address host: String = "127.0.0.1") throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw lastPOSIXError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard ready else {
            let error = lastPOSIXError()
            close(fd)
            throw error
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(descriptor) }

    /// Accepts one connection within 5 seconds; returns its descriptor (the caller closes it) and the client's port.
    func acceptClient() throws -> (descriptor: Int32, clientPort: UInt16) {
        var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 5000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(descriptor, $0, &length) }
        }
        guard client >= 0 else { throw lastPOSIXError() }
        return (client, UInt16(bigEndian: address.sin_port))
    }
}

/// A TCP connection from the test process to 127.0.0.1:`port`.
final class LoopbackClient {
    let descriptor: Int32
    let localPort: UInt16

    init(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw lastPOSIXError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let connected = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(fd, generic, length) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard connected else {
            let error = lastPOSIXError()
            close(fd)
            throw error
        }
        descriptor = fd
        localPort = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(descriptor) }
}

/// Starts `executable` with `descriptor` as its descriptor 3, so that both processes hold the same socket.
func spawnSharing(_ descriptor: Int32, executable: String, arguments: [String]) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_adddup2(&actions, descriptor, 3) == 0,
          posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw POSIXError(.EINVAL) }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, argv, nil)
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    return pid
}

/// Kills and reaps a child started with `spawnSharing`.
func reap(_ pid: pid_t) {
    kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
}

func startChild(_ executable: String, _ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func waitFor<Value>(timeout: TimeInterval = 5, _ probe: () -> Value?) -> Value? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let value = probe() { return value }
        usleep(50_000)
    } while Date() < deadline
    return probe()
}

/// The current `errno` as a thrown error.
func lastPOSIXError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

/// Sends one request to 127.0.0.1:`port` and returns the first bytes of the reply, or "" when the peer closes
/// without replying. Throws `EAGAIN` when no reply arrives within 3 seconds.
func exchange(port: UInt16, request: String) throws -> String {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw lastPOSIXError() }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    var noSignal: Int32 = 1
    // A peer that resets the connection fails this call instead of killing the test runner with SIGPIPE.
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw lastPOSIXError() }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
    guard connected else { throw lastPOSIXError() }
    try Array(request.utf8).withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw lastPOSIXError() }
            offset += count
        }
    }
    var buffer = [UInt8](repeating: 0, count: 1024)
    var count: Int
    repeat { count = read(descriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
    guard count >= 0 else { throw lastPOSIXError() }
    return String(decoding: buffer[0..<count], as: UTF8.self)
}
