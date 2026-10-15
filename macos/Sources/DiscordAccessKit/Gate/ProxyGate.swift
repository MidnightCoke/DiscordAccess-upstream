import Darwin
import Foundation

/// What the gate needs of the engine run it forwards to. `isRunning` must stay false once the engine has exited, and
/// `pid` must not belong to another process while `isRunning` is true; an unreaped child, as `EngineProcess`, meets both.
public protocol GateEngine: AnyObject {
    var pid: pid_t { get }
    var port: UInt16 { get }
    var authorization: String { get }
    var isRunning: Bool { get }
}

extension EngineProcess: GateEngine {}

/// The local proxy Discord uses (Windows `ProcessGate`). Each connection goes through these steps in order:
/// 1. The process holding its client end must be admitted (`PeerAdmission`); a refused client gets `403 Forbidden`.
/// 2. The request header (32 KiB at most, read within `headerTimeout`) must pass `RequestPolicy`, which adds the
///    engine credential.
/// 3. The engine must have accepted the gate's connection itself before a single byte is sent to it.
/// 4. Bytes are relayed both ways; once one side has finished, the other may finish within `drainTimeout`.
///
/// At most `capacity` connections run at once, each on its own thread. Diagnostic lines (`GateDiagnostics`) go to
/// `trace`, within `TraceBudget`. The gate runs until `close()`.
public final class ProxyGate {
    public static let maxConnections = 64
    static let forbidden = Array("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

    public let port: UInt16
    private let admission: PeerAdmission
    private let engine: GateEngine
    private let headerTimeout: TimeInterval
    private let drainTimeout: TimeInterval
    private let capacity: Int
    private let trace: ((String) -> Void)?
    /// Internal so that tests can stand in for an accept failure, which they cannot cause.
    let faulted: (() -> Void)?
    private let budget = TraceBudget()
    private let listener: Int32
    private let stopRead: Int32
    private let lock = NSLock()
    /// Left when the accept thread has closed the listener.
    private let acceptEnded = DispatchGroup()
    /// Weak: the thread's block holds the gate, so a strong reference would keep both alive for good.
    private weak var acceptThread: Thread?
    private var stopWrite: Int32
    private var active = 0
    private var started = false
    private var closed = false

    /// Listens on 127.0.0.1:`port` (0 picks a free port). `trace` and `faulted` are called concurrently from the gate's
    /// threads, so they must be thread-safe and must not block; connections that were ending may still call `trace`
    /// briefly after `close()` returns. `faulted` reports that the gate closed itself because accepting connections
    /// failed; its listener is closed by then, so the handler may start a new gate on the same port at once.
    public init(admission: PeerAdmission, engine: GateEngine, port: UInt16 = 0, headerTimeout: TimeInterval = 15,
                drainTimeout: TimeInterval = 30, capacity: Int = ProxyGate.maxConnections,
                trace: ((String) -> Void)? = nil, faulted: (() -> Void)? = nil) throws {
        precondition(headerTimeout > 0 && drainTimeout > 0 && drainTimeout <= 30 && (1...Self.maxConnections).contains(capacity))
        let stop = try LoopbackSocket.stopPipe()
        let bound: (descriptor: Int32, port: UInt16)
        do {
            bound = try LoopbackSocket.listen(port: port, backlog: Int32(Self.maxConnections))
        } catch {
            Darwin.close(stop.read)
            Darwin.close(stop.write)
            throw error
        }
        listener = bound.descriptor
        self.port = bound.port
        (stopRead, stopWrite) = stop
        self.admission = admission
        self.engine = engine
        self.headerTimeout = headerTimeout
        self.drainTimeout = drainTimeout
        self.capacity = capacity
        self.trace = trace
        self.faulted = faulted
    }

    deinit {
        // A started gate lives until its accept thread ends, which happens only after `close()`.
        if !closed {
            Darwin.close(listener)
            Darwin.close(stopWrite)
        }
        Darwin.close(stopRead)
    }

    /// Connections being handled now.
    public var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Whether the gate is started and still accepts: neither `close()` nor a failure closed it. A session reads it once
    /// its `faulted` handler is in place, since a failure before then was reported to no one (design 8).
    public var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !closed
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !closed else { return }
        started = true
        acceptEnded.enter()
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "DiscordAccess gate"
        acceptThread = thread
        thread.start()
    }

    /// Stops accepting and ends every connection; calling it again changes nothing. When it returns the listener is
    /// closed, so a new gate can take the port at once (Windows `Dispose`); only when called from `trace` on the accept
    /// thread does it return before that. It waits for the accept thread, which may be inside `trace`, so it must not be
    /// called while holding a lock or queue that `trace` waits for. Waits end at once; a connection whose admission is
    /// being checked ends when the check returns.
    public func close() {
        _ = markClosed()
        lock.lock()
        let thread = acceptThread
        lock.unlock()
        // The accept thread closes the listener as soon as it wakes. Called on that thread (from `trace`), close() must
        // not wait for it.
        if Thread.current !== thread { acceptEnded.wait() }
    }

    /// Marks the gate closed and closes the write end of the stop pipe, which wakes every wait of the gate; closes the
    /// listener too when no accept thread was started. False when the gate was closed already.
    private func markClosed() -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        closed = true
        let write = stopWrite
        stopWrite = -1
        let ownsListener = !started
        lock.unlock()
        Darwin.close(write)
        if ownsListener { Darwin.close(listener) }
        return true
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func acceptLoop() {
        let failed = acceptConnections()
        // A failure closes the gate as `close()` would; the listener is closed before `faulted` is reported (as Windows
        // stops its listener before `Faulted`).
        let unexpected = failed && markClosed()
        Darwin.close(listener)
        acceptEnded.leave()
        if unexpected { faulted?() }
    }

    /// Accepts connections until the gate closes (false) or accepting fails (true).
    private func acceptConnections() -> Bool {
        while true {
            var watched = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: stopRead, events: Int16(POLLIN), revents: 0)]
            if poll(&watched, 2, -1) < 0 {
                if errno == EINTR { continue }
                return true
            }
            if watched[1].revents != 0 { return false }
            guard watched[0].revents & Int16(POLLIN) != 0 else { return true }
            let accepted: (descriptor: Int32, peer: sockaddr_in)?
            do {
                accepted = try LoopbackSocket.accept(listener)
            } catch {
                return true
            }
            guard let (client, peer) = accepted else { continue }
            lock.lock()
            if closed || active >= capacity {
                let full = !closed
                lock.unlock()
                Darwin.close(client)
                if full { emit(GateDiagnostics.capacityFailure, failure: true) }
                continue
            }
            active += 1
            lock.unlock()
            Thread { [self] in handle(client, peer: peer) }.start()
        }
    }

    private func handle(_ client: Int32, peer: sockaddr_in) {
        var backend: Int32 = -1
        defer {
            Darwin.close(client)
            if backend >= 0 { Darwin.close(backend) }
            lock.lock()
            active -= 1
            lock.unlock()
        }
        if let reason = refusal(peer: peer) {
            if !isClosed { emit(GateDiagnostics.unownedClient(reason: reason), failure: true) }
            try? LoopbackSocket.write(client, Self.forbidden, until: .now + .seconds(2), stop: stopRead)
            return
        }
        var stage = GateStage.headerRead
        var target = "unknown"
        do {
            let (header, remainder) = try LoopbackSocket.readHeader(client, until: .now + .seconds(headerTimeout), stop: stopRead)
            let text = String(decoding: header, as: UTF8.self)
            target = GateDiagnostics.safeTarget(text)
            stage = .requestPolicy
            let outgoing: String
            do {
                outgoing = try RequestPolicy.rewrite(text, authorization: engine.authorization)
            } catch let refusal as RequestFailure {
                throw GateFailure.refused(refusal)
            }
            emit("Owned request " + target, failure: false)
            stage = .backendConnect
            backend = try LoopbackSocket.connect(port: engine.port, until: .now + .seconds(5), stop: stopRead)
            // No request, credential or tunnel byte is sent to a peer that is not the engine.
            stage = .backendIdentity
            guard let local = LoopbackSocket.localPort(backend), engineAccepted(localPort: local) else { throw GateFailure.invalidData }
            emit("Backend identity verified target=" + target, failure: false)
            stage = .backendWrite
            try LoopbackSocket.write(backend, Array(outgoing.utf8) + remainder, until: .now + .seconds(5), stop: stopRead)
            stage = .relay
            let outcome = Relay.run(client: client, engine: backend, stop: stopRead, drainTimeout: drainTimeout)
            if case .failed(let error, let direction, let elapsed) = outcome, !isClosed {
                emit(GateDiagnostics.relayFailure(target: target, error: error, direction: direction, elapsedMilliseconds: elapsed), failure: true)
            }
        } catch {
            if !isClosed { emit(GateDiagnostics.failure(stage: stage, target: target, error: error as? GateFailure ?? .unexpected), failure: true) }
        }
    }

    /// Why the client may not use the gate (the diagnostic reason), or nil when the process holding its end is admitted.
    /// Only a peer at exactly 127.0.0.1 is matched against the processes' sockets.
    private func refusal(peer: sockaddr_in) -> String? {
        guard let clientPort = LoopbackSocket.loopbackPeerPort(peer) else { return "RemoteAddress" }
        if let refusal = admission.refusal(clientPort: clientPort, gatePort: port) { return refusal.diagnostic }
        // An admission can finish after `close()`; the gate's own state decides.
        return isClosed ? PeerAdmission.Refusal.closed.diagnostic : nil
    }

    /// The engine accepted the gate's connection itself (Windows `ExpectedBackend`): it is running, it holds its end of
    /// the connection, and it is still running afterwards, so the pid that held it was not reused in between. Only the
    /// engine's descriptors are inspected. The engine accepts on its own schedule, so its end may take a moment to appear.
    private func engineAccepted(localPort: UInt16) -> Bool {
        guard engine.isRunning else { return false }
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline && !isClosed {
            if ProcessInspector.holdsLoopbackConnection(pid: engine.pid, localPort: engine.port, remotePort: localPort) == true { return engine.isRunning }
            usleep(5_000)
        }
        return false
    }

    private func emit(_ line: String, failure: Bool) {
        guard let trace, budget.admit(failure: failure) else { return }
        trace(line)
    }
}
