import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// A DNS candidate with the real engine and gate. The connectivity check itself needs the internet, so these tests put
/// their own check in its place; the live check is `LiveConnectivityTests`.
@Suite struct DnsConnectionTests {
    typealias Collected = ProxyGateTests.Collected

    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    static func admission() throws -> PeerAdmission {
        try PeerAdmission(approved: [ProxyGateTests.netcat], readyTime: Date())
    }

    static func open(image: EngineImage? = nil, trace: ((String) -> Void)? = nil, cancel: Cancellation = Cancellation(),
                     check: @escaping (UInt16, Cancellation) throws -> Void) throws -> DnsConnection {
        try DnsConnection.open(provider: DnsProvider(.cloudflareIP), image: image ?? EngineImage.verify(path: TestEngine.path), admission: admission(),
                               trace: trace, cancel: cancel, readyTimeout: DnsConnection.readyTimeout, check: check)
    }

    /// The check gets the gate's port, and the gate admits this process: a request for a host outside the policy is
    /// refused without the 403 that a client that is not admitted gets.
    @Test(.enabled(if: TestEngine.isAvailable))
    func opensAnEngineAndAGateThatAdmitsThisProcess() throws {
        let lines = Collected<String>()
        let checked = Collected<UInt16>()
        let connection = try Self.open(trace: lines.append) { port, _ in
            checked.append(port)
            let reply = try exchange(port: port, request: "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
            #expect(reply == "")
        }
        #expect(connection.engine.isRunning && ProcessInspector.ownsLoopbackListener(pid: connection.engine.pid, port: connection.engine.port))
        try connection.verify(cancel: Cancellation())
        #expect(checked.all == [connection.gate.port] && connection.gate.port != connection.engine.port)
        #expect(waitFor { lines.all.contains("Proxy: Failure stage=RequestPolicy target=example.com:443 category=ForbiddenHost") ? true : nil } == true)
        try connection.close()
        try connection.close()
        #expect(!connection.engine.isRunning)
        // A child that another test is spawning may hold a copy of the listener until it executes.
        #expect(waitFor {
            do {
                _ = try LoopbackClient(port: connection.gate.port)
                return nil
            } catch {
                return error as? POSIXError == POSIXError(.ECONNREFUSED) ? true : nil
            }
        } == true)
    }

    /// An engine that stopped is reported as such, so that selection does not try another provider: whether the check
    /// failed as the engine went or still passed.
    @Test(.enabled(if: TestEngine.isAvailable), arguments: [true, false])
    func reportsAStoppedEngineInsteadOfAConnectivityFailure(checkFails: Bool) throws {
        let engine = Box<EngineProcess?>(nil)
        let connection = try Self.open { _, _ in
            let process = try #require(engine.value)
            kill(process.pid, SIGKILL)
            // Thrown at once: the engine has not exited yet, let alone been reaped.
            if checkFails { throw ConnectivityFailure(endpoint: .gateway, reason: .connect) }
            #expect(waitFor { process.isRunning ? nil : true } == true)
        }
        engine.value = connection.engine
        #expect(throws: KitError.engineStopped()) { try connection.verify(cancel: Cancellation()) }
        try connection.close()
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func passesOnTheConnectivityFailureOfARunningEngine() throws {
        let failure = ConnectivityFailure(endpoint: .gateway, reason: .timeout)
        let connection = try Self.open { _, _ in throw failure }
        defer { try? connection.close() }
        #expect(throws: failure) { try connection.verify(cancel: Cancellation()) }
        #expect(connection.engine.isRunning)
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func startsNothingWhenCanceled() throws {
        let copy = try TestEngine.runnableCopy(named: "dns-connection")
        let image = try EngineImage.verify(path: copy)
        let cancel = Cancellation()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try Self.open(image: image, cancel: cancel) { _, _ in } }
        #expect(EngineProcessTests.processes(at: copy, parent: getpid()).isEmpty)
        let checking = try Self.open(image: image) { _, _ in }
        let running = Cancellation()
        running.cancel()
        #expect(throws: CancellationError.self) { try checking.verify(cancel: running) }
        try checking.close()
        #expect(EngineProcessTests.processes(at: copy, parent: getpid()).isEmpty)
    }

    /// Canceling ends the wait for a starting engine's listener; the engine is stopped and nothing is left running.
    @Test(.enabled(if: TestEngine.isAvailable))
    func stopsAStartingEngineWhenCanceled() throws {
        let copy = try TestEngine.runnableCopy(named: "dns-connection-start")
        let cancel = Cancellation()
        cancel.cancel()
        #expect(throws: CancellationError.self) {
            _ = try EngineProcess.start(image: EngineImage.verify(path: copy), dns: DnsProvider(.google), readyTimeout: 30, cancel: cancel)
        }
        #expect(EngineProcessTests.processes(at: copy, parent: getpid()).isEmpty)
    }

    /// A gate that closes itself reaches the handler set once the candidate is selected (Windows `Gate.Faulted`). A test
    /// cannot make accepting fail, so it calls the gate's `faulted` as the gate would.
    @Test(.enabled(if: TestEngine.isAvailable))
    func relaysAGateFaultToTheHandlerSetLater() throws {
        let connection = try Self.open { _, _ in }
        defer { try? connection.close() }
        let faulted = try #require(connection.gate.faulted)
        let calls = CancellationTests.Counter()
        faulted()
        connection.onGateFault = { calls.increment() }
        faulted()
        connection.onGateFault = nil
        faulted()
        // Closing clears the handler: it does not outlive the candidate.
        connection.onGateFault = { calls.increment() }
        try connection.close()
        faulted()
        #expect(calls.count == 1)
    }

    @Test func waitsLongerThanWindowsForTheFirstEngineStart() {
        #expect(DnsConnection.readyTimeout == 30)
    }
}
