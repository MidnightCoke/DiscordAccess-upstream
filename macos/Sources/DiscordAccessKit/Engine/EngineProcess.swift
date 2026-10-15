import Darwin
import Foundation

/// One engine run (Windows `DnsConnection`). The engine starts suspended and resumes only if its code matches the
/// pinned cdhash; the policy then goes in on stdin with a random credential, and the engine must own its loopback
/// listener before the run is handed out.
public final class EngineProcess {
    public let pid: pid_t
    public let port: UInt16
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var reaped = false

    private init(pid: pid_t, port: UInt16, username: String, password: String) {
        self.pid = pid
        self.port = port
        self.username = username
        self.password = password
    }

    deinit { stop() }

    /// Starts an engine for `dns` and waits up to `readyTimeout` for its listener. Canceling `cancel` ends the wait: the
    /// engine is stopped and `CancellationError` is thrown.
    public static func start(image: EngineImage, dns: DnsProvider, readyTimeout: TimeInterval = 12, cancel: Cancellation? = nil) throws -> EngineProcess {
        // The file may have changed since `image` was verified; measuring it again keeps the PKG-E* codes accurate.
        let current = try EngineImage.verify(path: image.path, expected: image.identity)
        let port = try reserveLoopbackPort()
        let username = try Secrets.randomToken()
        let password = try Secrets.randomToken()
        let config = try EngineConfig.json(dns: dns, username: username, password: password, port: port)
        let engine = EngineProcess(pid: try spawn(image: current, input: config), port: port, username: username, password: password)
        do {
            try engine.waitUntilListening(timeout: readyTimeout, cancel: cancel)
            return engine
        } catch {
            engine.stop()
            throw error
        }
    }

    /// `Proxy-Authorization` value for this run's credential.
    public var authorization: String { "Basic " + Data((username + ":" + password).utf8).base64EncodedString() }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !reapIfExited()
    }

    /// Kills the engine at once, as closing the Windows job object does (it keeps no state), and reaps it; returns false
    /// only if it was not reaped within `timeout`. Can block that long, and so can releasing the last reference
    /// (`deinit` stops the engine); keep both off the main thread.
    @discardableResult
    public func stop(timeout: TimeInterval = 5) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if reapIfExited() { return true }
        kill(pid, SIGKILL)
        return waitForExit(timeout: timeout)
    }

    /// Terminates engines of `enginePath` left behind by a crashed session: same user, adopted by launchd.
    /// Each process is re-identified (pid, start time, path) before it is force-killed.
    @discardableResult
    public static func terminateOrphans(enginePath: String, uid: uid_t = getuid()) -> [pid_t] {
        let orphans = ProcessInspector.userProcessIDs(uid: uid).compactMap(ProcessInspector.record(for:))
            .filter { $0.parentPid == 1 && $0.uid == uid && $0.path == enginePath }
            .filter { kill($0.pid, SIGTERM) == 0 }
        let deadline = Date().addingTimeInterval(3)
        var remaining = orphans
        while !remaining.isEmpty && Date() < deadline {
            usleep(50_000)
            remaining = remaining.filter { ProcessInspector.record(for: $0.pid) == $0 }
        }
        for orphan in remaining where ProcessInspector.record(for: orphan.pid) == orphan { kill(orphan.pid, SIGKILL) }
        return orphans.map(\.pid)
    }

    private func waitUntilListening(timeout: TimeInterval, cancel: Cancellation?) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try cancel?.check()
            guard isRunning else { throw KitError.engineStartFailed() }
            if ProcessInspector.ownsLoopbackListener(pid: pid, port: port) { return }
            usleep(40_000)
        }
        throw KitError.engineStartFailed()
    }

    /// Must be called with `lock` held.
    private func reapIfExited() -> Bool {
        if reaped { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) { reaped = true }
        return reaped
    }

    /// Must be called with `lock` held.
    private func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if reapIfExited() { return true }
            usleep(20_000)
        } while Date() < deadline
        return reapIfExited()
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw KitError.engineStartFailed() }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else { throw KitError.engineStartFailed() }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func spawn(image: EngineImage, input: Data) throws -> pid_t {
        // Every setup call is checked: without these attributes the engine would run before the signature check.
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw KitError.engineStartFailed() }
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors set up below reach the engine; it gets its own process group and starts suspended,
        // so none of its code runs before the signature check.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw KitError.engineStartFailed() }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw KitError.engineStartFailed() }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw KitError.engineStartFailed() }
        let readEnd = ends[0], writeEnd = ends[1]
        // Neither end may leak into a process spawned elsewhere meanwhile; dup2 clears the flag on the engine's stdin.
        guard fcntl(readEnd, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeEnd, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeEnd, F_SETNOSIGPIPE, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, (image.path as NSString).deletingLastPathComponent) == 0 else {
            close(readEnd)
            close(writeEnd)
            throw KitError.engineStartFailed()
        }
        var pid: pid_t = 0
        let status = withCStringArray([image.path, "run", "-c", "stdin", "--disable-color"]) { arguments in
            withCStringArray(["PATH=/usr/bin:/bin"]) { environment in
                posix_spawn(&pid, image.path, &actions, &attributes, arguments, environment)
            }
        }
        close(readEnd)
        guard status == 0 else {
            close(writeEnd)
            throw KitError.engineStartFailed()
        }
        guard ProcessInspector.satisfies(pid: pid, requirement: image.identity.requirement) else {
            close(writeEnd)
            discard(pid)
            throw KitError.engineIntegrity(image.path)
        }
        kill(pid, SIGCONT)
        let delivered = input.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(writeEnd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        close(writeEnd)
        guard delivered else {
            discard(pid)
            throw KitError.engineStartFailed()
        }
        return pid
    }

    /// Kills and reaps a child that was never handed out.
    private static func discard(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var ignored: Int32 = 0
        while waitpid(pid, &ignored, 0) == -1 && errno == EINTR {}
    }
}

private func withCStringArray<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
