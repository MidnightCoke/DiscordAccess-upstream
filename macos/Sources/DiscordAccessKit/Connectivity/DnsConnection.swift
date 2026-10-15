import Foundation

/// One DNS candidate's engine and gate (Windows `DnsConnection`). The selected candidate becomes the session's engine and
/// gate. Its gate admits this process (`PeerAdmission.diagnosticAllowed`) for the connectivity checks, as on Windows.
public final class DnsConnection: DnsCandidate {
    /// The engine may take this long to own its listener: macOS scans a new executable the first time it runs, which
    /// took 7-10 seconds under load. An engine that exits is reported at once, without waiting.
    public static let readyTimeout: TimeInterval = 30

    public let provider: DnsProvider
    public let engine: EngineProcess
    public let gate: ProxyGate
    private let faults: FaultRelay
    private let check: (UInt16, Cancellation) throws -> Void
    private let lock = NSLock()
    private var closed = false

    private init(provider: DnsProvider, engine: EngineProcess, gate: ProxyGate, faults: FaultRelay,
                 check: @escaping (UInt16, Cancellation) throws -> Void) {
        self.provider = provider
        self.engine = engine
        self.gate = gate
        self.faults = faults
        self.check = check
    }

    /// Called on the gate's thread when the gate closes itself because accepting connections failed. Set it once the
    /// candidate is selected, as Windows sets `Gate.Faulted` after selection. Closing the candidate clears it; a fault
    /// that raced with closing may still be reported once (as a Windows event may). The gate holds the handler until
    /// then, so the handler should hold the session weakly.
    public var onGateFault: (() -> Void)? {
        get { faults.handler }
        set { faults.handler = newValue }
    }

    /// Starts the engine for `provider` from `image` and a gate in front of it that admits through `admission`; gate
    /// lines go to `trace` with a `Proxy: ` prefix. Throws what starting the engine throws (`PKG-E*`, `ENG-E01`), or
    /// `CancellationError` (also while the engine starts). A started engine is stopped then; either error ends the
    /// selection, so no other candidate starts even if that engine could not be reaped.
    public static func open(provider: DnsProvider, image: EngineImage, admission: PeerAdmission, trace: ((String) -> Void)? = nil,
                            cancel: Cancellation) throws -> DnsConnection {
        try open(provider: provider, image: image, admission: admission, trace: trace, cancel: cancel, readyTimeout: readyTimeout) { port, cancel in
            try ConnectivityProbe.checkGateway(proxyPort: port, cancel: cancel)
        }
    }

    static func open(provider: DnsProvider, image: EngineImage, admission: PeerAdmission, trace: ((String) -> Void)?, cancel: Cancellation,
                     readyTimeout: TimeInterval, check: @escaping (UInt16, Cancellation) throws -> Void) throws -> DnsConnection {
        try cancel.check()
        let engine = try EngineProcess.start(image: image, dns: provider, readyTimeout: readyTimeout, cancel: cancel)
        let faults = FaultRelay()
        let gate: ProxyGate
        do {
            admission.diagnosticAllowed = true
            gate = try ProxyGate(admission: admission, engine: engine, trace: trace.map { trace in { trace("Proxy: " + $0) } }, faulted: faults.fire)
        } catch {
            guard engine.stop() else { throw KitError.dnsCandidateNotClosed() }
            throw error
        }
        let connection = DnsConnection(provider: provider, engine: engine, gate: gate, faults: faults, check: check)
        gate.start()
        do {
            try cancel.check()
        } catch {
            try connection.close()
            throw error
        }
        return connection
    }

    /// Checks Discord through this candidate's gate. An engine that stopped is reported as such (ENG-E02) rather than
    /// as a connectivity failure, so selection does not move on to another provider.
    public func verify(cancel: Cancellation) throws {
        try cancel.check()
        do {
            try check(gate.port, cancel)
        } catch let failure as ConnectivityFailure {
            try cancel.check()
            // A crashed engine's sockets close before it can be reaped: it gets a moment to show as stopped.
            guard !stops(within: 0.5) else { throw KitError.engineStopped() }
            throw failure
        }
        try cancel.check()
        guard engine.isRunning else { throw KitError.engineStopped() }
    }

    /// Whether the engine shows as stopped within `timeout`.
    private func stops(within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.isRunning {
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    /// Closes the gate and stops the engine; calling it again does nothing. Throws DNS-E03 when the engine could not be
    /// reaped: no other candidate may start then (Windows `Dispose`).
    public func close() throws {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        // The handler may hold the session, which holds this candidate: clearing it breaks that cycle.
        faults.handler = nil
        gate.close()
        guard engine.stop() else { throw KitError.dnsCandidateNotClosed() }
    }
}

/// Forwards a gate's fault to a handler that may be set after the gate was created.
private final class FaultRelay {
    private let lock = NSLock()
    private var current: (() -> Void)?

    var handler: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    func fire() {
        handler?()
    }
}
