import Darwin
import Foundation

/// An executable that may use the gate, and the code-signing requirement its running processes must satisfy.
public struct ApprovedExecutable: Equatable, Sendable {
    public let path: String
    public let requirement: String

    public init(path: String, requirement: String) {
        self.path = path
        self.requirement = requirement
    }
}

/// Which local processes may use the gate (Windows `ExternalDiscordScope` with `ProcessGate.PermittedOwner`).
///
/// Every same-user holder of the client end of a connection must be admitted. A process is admitted when it runs an
/// approved executable for this user, started at or after `readyTime`, and its running code satisfies the executable's
/// requirement. This process itself is admitted only while `diagnosticAllowed` is set. Admissions are remembered per
/// process instance (pid, start time and path), at most `capacity` at a time; refusals are not remembered.
public final class PeerAdmission {
    public enum ConfigurationError: Error, Equatable {
        case noExecutables
        case tooManyExecutables
        case unsafePath(String)
    }

    public static let maxExecutables = 16
    private let approved: [String: String]
    private let readyMicroseconds: UInt64
    private let uid: uid_t
    private let capacity: Int
    private let lock = NSLock()
    private var admitted: [pid_t: ProcessInspector.Record] = [:]
    private var diagnostic = false
    private var closed = false

    /// Each path must be the real path of an existing executable: matching compares real paths exactly.
    public init(approved executables: [ApprovedExecutable], readyTime: Date, uid: uid_t = getuid(), capacity: Int = 256) throws {
        guard !executables.isEmpty else { throw ConfigurationError.noExecutables }
        guard executables.count <= Self.maxExecutables else { throw ConfigurationError.tooManyExecutables }
        for executable in executables where canonicalPath(executable.path) != executable.path {
            throw ConfigurationError.unsafePath(executable.path)
        }
        approved = Dictionary(executables.map { ($0.path, $0.requirement) }, uniquingKeysWith: { first, _ in first })
        readyMicroseconds = UInt64(max(0, readyTime.timeIntervalSince1970 * 1_000_000))
        self.uid = uid
        self.capacity = capacity
    }

    /// Lets this process use the gate, for the controller's own diagnostics.
    public var diagnosticAllowed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return diagnostic
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            diagnostic = newValue
        }
    }

    /// Whether the connection whose client end is 127.0.0.1:`clientPort` to 127.0.0.1:`gatePort` may use the gate.
    /// A process being spawned holds copies of its parent's descriptors until it executes, so a refusal is retried
    /// three times, 10 ms apart (Windows `FindPeer` retries the same way); lasting extra holders are still refused.
    public func permits(clientPort: UInt16, gatePort: UInt16) -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { usleep(10_000) }
            guard let holders = ProcessInspector.loopbackConnectionHolders(localPort: clientPort, remotePort: gatePort, uid: uid),
                  !holders.isEmpty, holders.allSatisfy(permits(pid:)) else { continue }
            // The connection must still belong to exactly the processes that were checked.
            if ProcessInspector.loopbackConnectionHolders(localPort: clientPort, remotePort: gatePort, uid: uid).map(Set.init) == Set(holders) {
                return true
            }
        }
        return false
    }

    /// Whether `pid` is admitted: this process only through `diagnosticAllowed`, any other through its checks.
    public func permits(pid: pid_t) -> Bool {
        lock.lock()
        guard !closed, pid > 0 else {
            lock.unlock()
            return false
        }
        if pid == getpid() {
            let allowed = diagnostic
            lock.unlock()
            return allowed
        }
        pruneGone()
        if let known = admitted[pid] {
            defer { lock.unlock() }
            // Kept as running or as unreadable: only a readable instance that still meets the checks is admitted.
            guard let current = ProcessInspector.record(for: pid) else { return false }
            return Self.sameInstance(current, known) && requirement(for: current) != nil
        }
        let full = admitted.count >= capacity
        lock.unlock()
        // The signature check runs without the lock, so a slow one does not hold up processes admitted before.
        guard !full, let before = ProcessInspector.record(for: pid), let requirement = requirement(for: before),
              ProcessInspector.satisfies(pid: pid, requirement: requirement),
              let after = ProcessInspector.record(for: pid), Self.sameInstance(after, before) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !closed, admitted.count < capacity || admitted[pid] != nil else { return false }
        admitted[pid] = before
        return true
    }

    /// Whether a process admitted earlier is still running (Windows `AnyRunning`); one that cannot be read but still
    /// exists counts as running.
    public var anyAdmittedRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneGone()
        return !admitted.isEmpty
    }

    /// Admits nothing afterwards; running processes are not affected.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        admitted.removeAll()
    }

    /// The requirement of the approved executable `record` runs, when it is this user's and started after readiness.
    func requirement(for record: ProcessInspector.Record) -> String? {
        guard record.uid == uid, record.startSeconds > 0,
              record.startSeconds * 1_000_000 + record.startMicroseconds >= readyMicroseconds else { return nil }
        return approved[canonicalPath(record.path) ?? ""]
    }

    /// Drops admissions whose process instance is gone. One that cannot be read but still exists is kept (Windows keeps
    /// `Unknown` the same way). Must be called with `lock` held.
    private func pruneGone() {
        admitted = admitted.filter { pid, known in
            guard let current = ProcessInspector.record(for: pid) else { return kill(pid, 0) == 0 || errno == EPERM }
            return Self.sameInstance(current, known)
        }
    }

    /// The parent may change (a process whose parent exits moves to launchd); the pid, start time and path may not.
    private static func sameInstance(_ current: ProcessInspector.Record, _ known: ProcessInspector.Record) -> Bool {
        current.pid == known.pid && current.startSeconds == known.startSeconds &&
            current.startMicroseconds == known.startMicroseconds && current.path == known.path
    }
}

/// The real path (links resolved, letter case as on disk), or nil when it does not exist.
private func canonicalPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
