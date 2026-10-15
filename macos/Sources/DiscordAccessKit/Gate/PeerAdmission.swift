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
/// The client end of a connection is looked for only in this process and in processes running an approved executable,
/// and the process found there must be admitted (Windows likewise checks the one owner `TcpOwner.Find` reports). No
/// other process is inspected (see `ProcessInspector.tcpSockets`). A process is admitted when it runs an approved
/// executable for this user, started at or after `readyTime`, and its running code satisfies the executable's
/// requirement; this process itself is admitted only while `diagnosticAllowed` is set. Admissions are remembered per
/// process instance (pid, start time and path), at most `capacity` at a time; refusals are not remembered.
public final class PeerAdmission {
    public enum ConfigurationError: Error, Equatable {
        case noExecutables
        case tooManyExecutables
        case unsafePath(String)
        case missingExecutable(String)
    }

    /// Why a connection or process was refused; the gate writes `diagnostic` to its diagnostic lines.
    public enum Refusal: Error, Equatable, Sendable {
        case closed
        /// A process or descriptor list could not be read completely.
        case unreadable
        /// Neither this process nor a process running an approved executable holds the client end.
        case noHolder
        /// The process holding the connection let go of it during the checks.
        case holdersChanged
        /// This process, while `diagnosticAllowed` is off.
        case diagnosticNotAllowed
        /// The process could not be read, or it was not the same process after the checks.
        case unknownProcess
        case otherUser
        case startedBeforeReady
        /// The file name of the executable that is not approved.
        case unapprovedExecutable(String)
        case requirementNotMet
        case capacity

        /// The name of the refusal; for an unapproved executable also its file name, reduced to letters, digits and
        /// `._()-` (anything else becomes `_`) and to 64 characters.
        public var diagnostic: String {
            switch self {
            case .closed: return "Closed"
            case .unreadable: return "Unreadable"
            case .noHolder: return "NoHolder"
            case .holdersChanged: return "HoldersChanged"
            case .diagnosticNotAllowed: return "DiagnosticNotAllowed"
            case .unknownProcess: return "UnknownProcess"
            case .otherUser: return "OtherUser"
            case .startedBeforeReady: return "StartedBeforeReady"
            case .requirementNotMet: return "RequirementNotMet"
            case .capacity: return "Capacity"
            case .unapprovedExecutable(let name):
                let safe = name.unicodeScalars.prefix(64).map { scalar -> Character in
                    scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._()-".unicodeScalars.contains(scalar)) ? Character(scalar) : "_"
                }
                return "UnapprovedExecutable executable=" + String(safe)
            }
        }
    }

    public static let maxExecutables = 16
    private let approved: [String: String]
    /// The file names of the approved executables in lower case: a cheap first test before a process path is resolved.
    private let approvedNames: Set<String>
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
        for executable in executables {
            guard executable.path.hasPrefix("/") else { throw ConfigurationError.unsafePath(executable.path) }
            guard let resolved = realpath(executable.path, nil) else {
                throw errno == ENOENT ? ConfigurationError.missingExecutable(executable.path) : ConfigurationError.unsafePath(executable.path)
            }
            defer { free(resolved) }
            guard String(cString: resolved) == executable.path else { throw ConfigurationError.unsafePath(executable.path) }
        }
        approved = Dictionary(executables.map { ($0.path, $0.requirement) }, uniquingKeysWith: { first, _ in first })
        approvedNames = Set(executables.map { fileName($0.path).lowercased() })
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
    public func permits(clientPort: UInt16, gatePort: UInt16) -> Bool {
        refusal(clientPort: clientPort, gatePort: gatePort) == nil
    }

    /// Why the connection whose client end is 127.0.0.1:`clientPort` to 127.0.0.1:`gatePort` may not use the gate, or
    /// nil when it may. Refusals that can pass (an incomplete list, a process that changed during the checks, a failed
    /// signature check) are retried three times, 10 ms apart, as Windows `FindPeer` retries; the last reason counts.
    /// A connection no candidate holds is refused at once: looking again would not change that, and connections of
    /// another local user would otherwise each hold a gate slot for the retries.
    public func refusal(clientPort: UInt16, gatePort: UInt16) -> Refusal? {
        var last = Refusal.noHolder
        for attempt in 0..<4 {
            if attempt > 0 { usleep(10_000) }
            let holder: pid_t
            switch self.holder(clientPort: clientPort, gatePort: gatePort) {
            case .failure(let refusal):
                last = refusal
                continue
            case .success(nil):
                return .noHolder
            case .success(let pid?):
                holder = pid
            }
            if let refused = refusal(pid: holder) {
                guard refused == .unknownProcess || refused == .requirementNotMet else { return refused }
                last = refused
                continue
            }
            // The connection must still be held by the process that was checked.
            switch ProcessInspector.holdsLoopbackConnection(pid: holder, localPort: clientPort, remotePort: gatePort) {
            case true?: break
            case false?:
                last = .holdersChanged
                continue
            case nil:
                last = .unreadable
                continue
            }
            // `close()` or the diagnostic permission may have changed meanwhile.
            lock.lock()
            let revoked: Refusal? = closed ? .closed : holder == getpid() && !diagnostic ? .diagnosticNotAllowed : nil
            lock.unlock()
            return revoked
        }
        return last
    }

    /// The process holding the client end, looked for in this process first and then in the processes of this user that
    /// run an approved executable; nil when none of them holds it.
    private func holder(clientPort: UInt16, gatePort: UInt16) -> Result<pid_t?, Refusal> {
        guard let pids = ProcessInspector.completeUserProcessIDs(uid: uid) else { return .failure(.unreadable) }
        let candidates = [getpid()] + pids.filter { pid in
            guard pid != getpid(), let record = ProcessInspector.record(for: pid),
                  approvedNames.contains(fileName(record.path).lowercased()) else { return false }
            return approved[canonicalPath(record.path) ?? ""] != nil
        }
        var unreadable = false
        for pid in candidates {
            switch ProcessInspector.holdsLoopbackConnection(pid: pid, localPort: clientPort, remotePort: gatePort) {
            case true?: return .success(pid)
            case false?: continue
            case nil: unreadable = true
            }
        }
        return unreadable ? .failure(.unreadable) : .success(nil)
    }

    /// Whether `pid` is admitted: this process only through `diagnosticAllowed`, any other through its checks.
    public func permits(pid: pid_t) -> Bool {
        refusal(pid: pid) == nil
    }

    /// Why `pid` is not admitted, or nil when it is.
    public func refusal(pid: pid_t) -> Refusal? {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return .closed
        }
        guard pid > 0 else {
            lock.unlock()
            return .unknownProcess
        }
        if pid == getpid() {
            let allowed = diagnostic
            lock.unlock()
            return allowed ? nil : .diagnosticNotAllowed
        }
        pruneGone()
        if let known = admitted[pid] {
            defer { lock.unlock() }
            // Kept as running or as unreadable: only a readable instance that still meets the checks is admitted.
            guard let current = ProcessInspector.record(for: pid), Self.sameInstance(current, known) else { return .unknownProcess }
            if case .failure(let refusal) = requirement(for: current) { return refusal }
            return nil
        }
        let full = admitted.count >= capacity
        lock.unlock()
        guard !full else { return .capacity }
        // The signature check runs without the lock, so a slow one does not hold up processes admitted before.
        guard let before = ProcessInspector.record(for: pid) else { return .unknownProcess }
        let requirement: String
        switch self.requirement(for: before) {
        case .success(let value): requirement = value
        case .failure(let refusal): return refusal
        }
        guard ProcessInspector.satisfies(pid: pid, requirement: requirement) else { return .requirementNotMet }
        guard let after = ProcessInspector.record(for: pid), Self.sameInstance(after, before) else { return .unknownProcess }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return .closed }
        guard admitted.count < capacity || admitted[pid] != nil else { return .capacity }
        admitted[pid] = before
        return nil
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

    /// The requirement of the approved executable `record` runs, or why the record is refused: it must be this user's,
    /// started at or after readiness.
    func requirement(for record: ProcessInspector.Record) -> Result<String, Refusal> {
        guard record.uid == uid else { return .failure(.otherUser) }
        guard record.startSeconds > 0, record.startSeconds * 1_000_000 + record.startMicroseconds >= readyMicroseconds else {
            return .failure(.startedBeforeReady)
        }
        guard let requirement = approved[canonicalPath(record.path) ?? ""] else {
            return .failure(.unapprovedExecutable(fileName(record.path)))
        }
        return .success(requirement)
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

/// The last component of `path`, without touching the file system. `URL(fileURLWithPath:)` would look the path up; the
/// candidate search does this for every process of the user on each connection, and one may run from an unresponsive
/// network volume.
private func fileName(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// The real path (links resolved, letter case as on disk), or nil when it does not exist.
private func canonicalPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
