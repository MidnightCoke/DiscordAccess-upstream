import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The gate end to end: a fake engine listens on a loopback port in this process, and the client is this process
/// (admitted through `diagnosticAllowed`) or a `/usr/bin/nc` child. Modelled on the Windows `ProxyTransportChecks.cs`,
/// `ProxyDiagnosticsChecks.cs` and the media admission fixture of `MediaPolicyChecks.cs`.
@Suite struct ProxyGateTests {
    static let payload = Array("transport-fixture-payload".utf8)
    static let pattern = (0..<(256 * 1024)).map { UInt8($0 % 251) }
    static let connect = Array("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\n\r\n".utf8)
    /// The fake engine's credential, `fake-engine:fixture-password`.
    static let authorization = "Basic ZmFrZS1lbmdpbmU6Zml4dHVyZS1wYXNzd29yZA=="
    static let netcat = ApprovedExecutable(path: "/usr/bin/nc", requirement: "identifier \"com.apple.nc\" and anchor apple")

    /// Values collected from other threads.
    final class Collected<Value> {
        private let lock = NSLock()
        private var values: [Value] = []

        func append(_ value: Value) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var all: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// The gate's diagnostic lines.
    final class Lines {
        let collected = Collected<String>()

        /// Whether a line holding every part arrives within 5 seconds.
        func contain(_ parts: String...) -> Bool {
            waitFor { collected.all.contains { line in parts.allSatisfy(line.contains) } ? true : nil } == true
        }

        /// No line holds the engine credential, the fixture payload or private fixture text.
        var arePrivate: Bool {
            collected.all.allSatisfy { line in
                ["ZmFrZS1lbmdpbmU", "fixture-password", "transport-fixture-payload", "PRIVATE_FIXTURE"].allSatisfy { !line.contains($0) }
            }
        }
    }

    /// An engine stand-in on a loopback port: each connection goes to `serve` on its own thread and is closed after it.
    final class FakeEngine: GateEngine {
        let pid: pid_t
        let port: UInt16
        let authorization = ProxyGateTests.authorization
        let accepted = Collected<Int32>()
        private let running: () -> Bool
        private let listener: Int32
        private let stop: (read: Int32, write: Int32)
        private let accepting = DispatchGroup()

        var isRunning: Bool { running() }

        /// `acceptDelay` holds back each accept, as an engine that accepts on its own schedule.
        init(pid: pid_t = getpid(), running: @escaping () -> Bool = { true }, acceptDelay: useconds_t = 0, serve: @escaping (Int32) -> Void) throws {
            self.pid = pid
            self.running = running
            stop = try LoopbackSocket.stopPipe()
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ready = descriptor >= 0 && fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 && withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, length) == 0 && listen(descriptor, 64) == 0 && getsockname(descriptor, $0, &length) == 0
                }
            }
            guard ready else {
                let error = lastPOSIXError()
                for unused in [descriptor, stop.read, stop.write] where unused >= 0 { close(unused) }
                throw error
            }
            listener = descriptor
            port = UInt16(bigEndian: address.sin_port)
            // The thread holds only what it uses, so releasing the engine stops it.
            let (stopRead, accepting, accepted) = (stop.read, accepting, accepted)
            accepting.enter()
            Thread {
                defer { accepting.leave() }
                while true {
                    var watched = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0), pollfd(fd: stopRead, events: Int16(POLLIN), revents: 0)]
                    if poll(&watched, 2, -1) < 0 && errno != EINTR { return }
                    if watched[1].revents != 0 { return }
                    if acceptDelay > 0 { usleep(acceptDelay) }
                    let connection = accept(descriptor, nil, nil)
                    guard connection >= 0 else { continue }
                    _ = fcntl(connection, F_SETFL, 0)
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    var noSignal: Int32 = 1
                    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    accepted.append(connection)
                    Thread {
                        serve(connection)
                        close(connection)
                    }.start()
                }
            }.start()
        }

        deinit {
            close(stop.write)
            accepting.wait()
            close(listener)
            close(stop.read)
        }
    }

    // MARK: Byte helpers, also used on the fake engine's threads (so they throw instead of recording issues).

    static func send(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw lastPOSIXError() }
                offset += count
            }
        }
    }

    /// Exactly `count` bytes, or nil when the stream ends or fails first.
    static func receive(_ descriptor: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let read = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + offset, count - offset) }
            if read < 0 && errno == EINTR { continue }
            guard read > 0 else { return nil }
            offset += read
        }
        return bytes
    }

    /// Everything until the end of the stream; what arrived before a failure.
    static func receiveAll(_ descriptor: Int32) -> [UInt8] {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return bytes }
            bytes += chunk[0..<count]
        }
    }

    /// A header up to and including CR LF CR LF, or nil when the stream ends first.
    static func receiveHeader(_ descriptor: Int32) -> [UInt8]? {
        var bytes: [UInt8] = []
        while bytes.count < 16384 {
            guard let next = receive(descriptor, count: 1) else { return nil }
            bytes += next
            if bytes.suffix(4).elementsEqual([13, 10, 13, 10]) { return bytes }
        }
        return nil
    }

    /// The Windows transport fixture: the fake engine answers the CONNECT, then acts out the mode the client sends first.
    /// `N` replies 256 KiB, `C` replies after the client half-closes, `S` sends 1 KiB and half-closes itself, `H` stays
    /// silent after the client half-closes, `F` resets the connection and `K` keeps it until the gate hangs up (and marks
    /// that it waits and that it saw the gate's close).
    static func transport(_ marks: Collected<String>) -> (Int32) -> Void {
        { connection in
            guard receiveHeader(connection) != nil, (try? send(connection, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))) != nil,
                  let mode = receive(connection, count: 1).map({ Unicode.Scalar($0[0]) }) else { return }
            if mode == "S" {
                try? send(connection, [UInt8](repeating: 0, count: 1024))
                shutdown(connection, SHUT_WR)
                if receive(connection, count: payload.count) == payload { marks.append("server-half") }
                return
            }
            guard receive(connection, count: payload.count) == payload else { return }
            switch mode {
            case "F":
                // The close after `serve` then resets the connection.
                var reset = linger(l_onoff: 1, l_linger: 0)
                setsockopt(connection, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
                return
            case "C", "H":
                guard receive(connection, count: 1) == nil else { return }
                if mode == "H" {
                    usleep(3_000_000)
                    return
                }
            case "K":
                marks.append("engine-waiting")
                var watched = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                // The gate's close reaches the engine as the end of the stream.
                if poll(&watched, 1, 10_000) == 1 && receive(connection, count: 1) == nil { marks.append("engine-saw-close") }
                return
            default:
                break
            }
            usleep(50_000)
            try? send(connection, pattern)
        }
    }

    // MARK: Gate and client helpers.

    /// A started gate in front of `engine` that admits this process while `diagnostic` is set.
    static func gate(_ engine: GateEngine, lines: Lines, approved: [ApprovedExecutable] = [netcat], diagnostic: Bool = true,
                     headerTimeout: TimeInterval = 5, drainTimeout: TimeInterval = 0.5, capacity: Int = ProxyGate.maxConnections) throws -> ProxyGate {
        let admission = try PeerAdmission(approved: approved, readyTime: Date())
        admission.diagnosticAllowed = diagnostic
        let gate = try ProxyGate(admission: admission, engine: engine, headerTimeout: headerTimeout, drainTimeout: drainTimeout,
                                 capacity: capacity, trace: lines.collected.append)
        gate.start()
        return gate
    }

    /// A connection from this process to the gate; reads give up after 5 seconds.
    static func dial(_ gate: ProxyGate) throws -> LoopbackClient {
        let client = try LoopbackClient(port: gate.port)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(client.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client.descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return client
    }

    /// Sends `request` from this process and returns everything the gate sends back.
    static func exchange(_ gate: ProxyGate, _ request: [UInt8]) throws -> [UInt8] {
        let client = try dial(gate)
        try send(client.descriptor, request)
        return receiveAll(client.descriptor)
    }

    /// A CONNECT through the gate that the fake engine answered, followed by `mode` (and the payload, except in `S`).
    /// The header goes in `parts`, sent 50 ms apart.
    static func open(_ gate: ProxyGate, mode: Unicode.Scalar, parts: [[UInt8]] = [connect]) throws -> LoopbackClient {
        let client = try dial(gate)
        for (index, part) in parts.enumerated() {
            if index > 0 { usleep(50_000) }
            try send(client.descriptor, part)
        }
        guard receiveHeader(client.descriptor) == Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8) else { throw POSIXError(.EPROTO) }
        try send(client.descriptor, [UInt8(mode.value)] + (mode == "S" ? [] : payload))
        return client
    }

    /// The length of the fake engine's reply; it must follow the fixture pattern when `verify` is set.
    static func reply(_ client: LoopbackClient, verify: Bool) throws -> Int {
        let bytes = receiveAll(client.descriptor)
        if verify && !bytes.elementsEqual(pattern.prefix(bytes.count)) { throw POSIXError(.EBADMSG) }
        return bytes.count
    }

    /// A whole request through the gate: modes `C` and `H` half-close after the payload.
    static func request(_ gate: ProxyGate, mode: Unicode.Scalar) throws -> Int {
        let client = try open(gate, mode: mode)
        if mode == "C" || mode == "H" { shutdown(client.descriptor, SHUT_WR) }
        return try reply(client, verify: true)
    }

    /// A gate that admits this process, on a port in `range` (outside the range the system hands out, 49152-65535) where
    /// nothing answered before, so no other test or process is given that port while the test runs.
    static func quietGate(_ range: Range<UInt16>, engine: GateEngine, capacity: Int = ProxyGate.maxConnections,
                          trace: ((String) -> Void)? = nil) throws -> ProxyGate {
        let admission = try PeerAdmission(approved: [netcat], readyTime: Date())
        admission.diagnosticAllowed = true
        let stop = try LoopbackSocket.stopPipe()
        defer {
            close(stop.read)
            close(stop.write)
        }
        for port in range {
            // A port that something answers on, or swallows connections on, is skipped.
            do {
                close(try LoopbackSocket.connect(port: port, until: .now + .milliseconds(200), stop: stop.read))
                continue
            } catch GateFailure.socket(let code) where code == ECONNREFUSED {
            } catch {
                continue
            }
            if let gate = try? ProxyGate(admission: admission, engine: engine, port: port, capacity: capacity, trace: trace) { return gate }
        }
        throw POSIXError(.EADDRINUSE)
    }

    static func settles(_ gate: ProxyGate) -> Bool {
        waitFor { gate.activeConnections == 0 ? true : nil } == true
    }

    // MARK: Transport (Windows `ProxyTransportChecks.cs`).

    @Test func relaysRepliesAndPassesHalfClosesOnInBothDirections() throws {
        let marks = Collected<String>()
        let engine = try FakeEngine(serve: Self.transport(marks))
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        #expect(try Self.request(gate, mode: "N") == Self.pattern.count)
        #expect(try Self.request(gate, mode: "C") == Self.pattern.count)
        // The engine half-closes first; what the client sends afterwards must still reach it.
        let client = try Self.open(gate, mode: "S")
        #expect(try Self.reply(client, verify: false) == 1024)
        try Self.send(client.descriptor, Self.payload)
        shutdown(client.descriptor, SHUT_WR)
        #expect(waitFor { marks.all.contains("server-half") ? true : nil } == true)
        #expect(lines.contain("Owned request discord.com:443"))
        #expect(lines.contain("Backend identity verified target=discord.com:443"))
        #expect(Self.settles(gate))
        #expect(lines.arePrivate)
    }

    @Test func relaysSixteenConnectionsAtOnce() throws {
        let engine = try FakeEngine(serve: Self.transport(Collected<String>()))
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        let lengths = Collected<Int>()
        let finished = DispatchGroup()
        for _ in 0..<16 {
            finished.enter()
            Thread {
                lengths.append((try? Self.request(gate, mode: "N")) ?? -1)
                finished.leave()
            }.start()
        }
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(lengths.all == Array(repeating: Self.pattern.count, count: 16))
    }

    @Test func boundsTheDrainAndNamesTheDirectionThatStalled() throws {
        let engine = try FakeEngine(serve: Self.transport(Collected<String>()))
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        let started = Date()
        #expect(try Self.request(gate, mode: "H") == 0)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(Self.settles(gate))
        #expect(lines.contain("Failure stage=Relay target=discord.com:443 category=Timeout direction=engine_to_client elapsed_ms="))
        #expect(lines.arePrivate)
    }

    @Test func namesTheSocketErrorAndDirectionOfAnEngineReset() throws {
        let engine = try FakeEngine(serve: Self.transport(Collected<String>()))
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        #expect(try Self.request(gate, mode: "F") == 0)
        #expect(Self.settles(gate))
        #expect(lines.contain("Failure stage=Relay target=discord.com:443 category=IO socket=ConnectionReset direction=engine_to_client elapsed_ms="))
        #expect(lines.arePrivate)
    }

    @Test func closingTheGateEndsItsConnectionsAtOnce() throws {
        let marks = Collected<String>()
        let engine = try FakeEngine(serve: Self.transport(marks))
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        let client = try Self.open(gate, mode: "K")
        #expect(waitFor { marks.all.contains("engine-waiting") ? true : nil } == true)
        let started = Date()
        gate.close()
        gate.close()
        #expect(try Self.reply(client, verify: false) == 0)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(waitFor { marks.all.contains("engine-saw-close") ? true : nil } == true)
        #expect(Self.settles(gate))
        // Ending connections on close is not a failure.
        #expect(!lines.collected.all.contains { $0.contains("stage=Relay") })
    }

    // MARK: Admission, header and policy (Windows `ProxyDiagnosticsChecks.cs`, `MediaPolicyChecks.cs`).

    @Test func answersAClientThatIsNotAdmittedWith403() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines, diagnostic: false)
        defer { gate.close() }
        let client = try Self.dial(gate)
        try Self.send(client.descriptor, Self.connect)
        #expect(Self.receiveAll(client.descriptor) == ProxyGate.forbidden)
        #expect(lines.contain("Failure stage=Ownership target=unknown category=UnownedClient reason="))
        #expect(engine.accepted.all.isEmpty)
    }

    /// A client that runs no approved executable is never inspected, so no process is found holding its connection.
    @Test func refusesAClientThatRunsNoApprovedExecutable() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let sleeper = ApprovedExecutable(path: "/bin/sleep", requirement: "identifier \"com.apple.sleep\" and anchor apple")
        let gate = try Self.gate(engine, lines: lines, approved: [sleeper])
        defer { gate.close() }
        let client = try startChild("/usr/bin/nc", ["-d", "127.0.0.1", String(gate.port)])
        defer {
            client.terminate()
            client.waitUntilExit()
        }
        #expect(lines.contain("Failure stage=Ownership target=unknown category=UnownedClient reason=NoHolder"))
        #expect(engine.accepted.all.isEmpty)
    }

    @Test func logsARefusedRequestWithOnlyItsStageTargetAndCategory() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        let request = "GET http://telemetry.example.invalid/PRIVATE_FIXTURE?token=PRIVATE_FIXTURE HTTP/1.1\r\nHost: telemetry.example.invalid\r\n" +
            "Authorization: PRIVATE_FIXTURE\r\n\r\n"
        #expect(try Self.exchange(gate, Array(request.utf8)) == [])
        #expect(lines.contain("Failure stage=RequestPolicy target=telemetry.example.invalid:80 category=ForbiddenHost"))
        #expect(lines.collected.all == ["Failure stage=RequestPolicy target=telemetry.example.invalid:80 category=ForbiddenHost"])
        #expect(engine.accepted.all.isEmpty)
    }

    @Test(arguments: [Array("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nUser-Agent: caf\u{E9}\r\n\r\n".utf8),
                      [UInt8](repeating: UInt8(ascii: "a"), count: 32_768)])
    func refusesAHeaderThatIsNotASCIIOrNeverEnds(request: [UInt8]) throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        #expect(try Self.exchange(gate, request) == [])
        #expect(lines.contain("Failure stage=HeaderRead target=unknown category=InvalidData"))
        #expect(engine.accepted.all.isEmpty)
    }

    @Test func closesAConnectionWhoseHeaderDoesNotArriveInTime() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines, headerTimeout: 0.3)
        defer { gate.close() }
        let started = Date()
        #expect(try Self.exchange(gate, []) == [])
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(lines.contain("Failure stage=HeaderRead target=unknown category=Timeout"))
    }

    /// The policy's view and the engine's view are the same bytes: the rewritten header, then whatever followed the
    /// header in the client's stream, unchanged (binary bytes included).
    @Test func forwardsTheRewrittenHeaderAndTheBytesAfterItUntouched() throws {
        let header = "CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nProxy-Authorization: Basic client-fixture\r\n\r\n"
        let tunnel: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0xFF, 0x0D, 0x0A, 0x0D, 0x0A, 0xC3, 0x28]
        let expected = Array(("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nProxy-Authorization: " + Self.authorization +
            "\r\n\r\n").utf8) + tunnel
        let received = Collected<[UInt8]>()
        let engine = try FakeEngine(serve: { connection in received.append(Self.receive(connection, count: expected.count) ?? []) })
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        // The client keeps its sending side open: only established connections are matched to their processes.
        #expect(try Self.exchange(gate, Array(header.utf8) + tunnel) == [])
        #expect(received.all == [expected])
    }

    /// A header of exactly 32 KiB is the longest the gate reads; the engine gets it rewritten with its credential.
    @Test func forwardsAHeaderOfExactly32KiB() throws {
        let frame = ("GET http://discord.com/", " HTTP/1.1\r\nHost: discord.com\r\n\r\n")
        let header = frame.0 + String(repeating: "a", count: 32_768 - frame.0.utf8.count - frame.1.utf8.count) + frame.1
        // Bytes, not Characters: Swift treats CR LF as one Character.
        let expected = Array(header.utf8.dropLast(2)) + Array(("Proxy-Authorization: " + Self.authorization + "\r\n\r\n").utf8)
        let received = Collected<[UInt8]>()
        let engine = try FakeEngine(serve: { connection in received.append(Self.receive(connection, count: expected.count) ?? []) })
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        #expect(header.utf8.count == 32_768)
        #expect(try Self.exchange(gate, Array(header.utf8)) == [])
        #expect(received.all == [expected])
    }

    /// The end of the header may arrive in a later packet than the rest of it.
    @Test func joinsAHeaderEndThatArrivesSeparately() throws {
        let engine = try FakeEngine(serve: Self.transport(Collected<String>()))
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        let client = try Self.open(gate, mode: "N", parts: [Array(Self.connect.dropLast(1)), [10]])
        #expect(try Self.reply(client, verify: true) == Self.pattern.count)
    }

    enum Backend: CaseIterable, Sendable {
        case launchd, otherProcess, stoppedEngine, engineStoppingDuringTheCheck
    }

    /// The media port exception must not bypass the engine identity: a backend whose end of the connection is not held
    /// by the engine's pid (launchd, whose descriptors cannot be read, or a child of this process, which holds no such
    /// connection), or an engine that is not running before or after the check, receives no byte at all.
    @Test(arguments: Backend.allCases)
    func sendsNothingToABackendThatIsNotTheRunningEngine(backend: Backend) throws {
        let other = try startChild("/bin/sleep", ["30"])
        defer {
            other.terminate()
            other.waitUntilExit()
        }
        let pid = backend == .launchd ? 1 : backend == .otherProcess ? other.processIdentifier : getpid()
        let reads = Collected<Int>()
        let running: () -> Bool = {
            reads.append(1)
            switch backend {
            case .stoppedEngine: return false
            // Running when the check starts, stopped when it ends.
            case .engineStoppingDuringTheCheck: return reads.all.count == 1
            case .launchd, .otherProcess: return true
            }
        }
        let received = Collected<[UInt8]>()
        let engine = try FakeEngine(pid: pid, running: running, serve: { connection in received.append(Self.receiveAll(connection)) })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        let authority = "c-waw04-9501efbe.discord.media:2087"
        #expect(try Self.exchange(gate, Array(("CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\n\r\n").utf8)) == [])
        #expect(lines.contain("Failure stage=BackendIdentity target=" + authority + " category=InvalidData"))
        #expect(waitFor { received.all.isEmpty ? nil : true } == true)
        #expect(received.all == [[]])
    }

    @Test func turnsAwayConnectionsBeyondItsCapacity() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        // A long header timeout keeps the admitted clients in their slots however slowly the next one starts.
        let gate = try Self.gate(engine, lines: lines, headerTimeout: 60, capacity: 2)
        defer { gate.close() }
        // Two netcat clients are admitted and wait with their headers unsent; a refused one would give its slot back.
        var clients = try (0..<2).map { _ in try startChild("/usr/bin/nc", ["-d", "127.0.0.1", String(gate.port)]) }
        defer {
            for client in clients {
                client.terminate()
                client.waitUntilExit()
            }
        }
        #expect(waitFor { gate.activeConnections == 2 ? true : nil } == true)
        let third = try Self.dial(gate)
        #expect(Self.receiveAll(third.descriptor) == [])
        #expect(lines.contain(GateDiagnostics.capacityFailure))
        #expect(gate.activeConnections == 2)
        // A slot that frees up is used again.
        let leaving = clients.removeFirst()
        leaving.terminate()
        leaving.waitUntilExit()
        #expect(waitFor { gate.activeConnections == 1 ? true : nil } == true)
        clients.append(try startChild("/usr/bin/nc", ["-d", "127.0.0.1", String(gate.port)]))
        #expect(waitFor { gate.activeConnections == 2 ? true : nil } == true)
    }

    /// The engine accepts on its own schedule: the gate waits up to a second for the engine's end of the connection.
    @Test func relaysThroughAnEngineThatAcceptsLate() throws {
        let engine = try FakeEngine(acceptDelay: 300_000, serve: Self.transport(Collected<String>()))
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        #expect(try Self.request(gate, mode: "N") == Self.pattern.count)
    }

    @Test func matchesOnlyPeersAtExactly127001() {
        var peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = UInt16(40_000).bigEndian
        peer.sin_addr.s_addr = inet_addr("127.0.0.1")
        #expect(LoopbackSocket.loopbackPeerPort(peer) == 40_000)
        peer.sin_addr.s_addr = inet_addr("127.0.0.2")
        #expect(LoopbackSocket.loopbackPeerPort(peer) == nil)
        peer.sin_addr.s_addr = inet_addr("127.0.0.1")
        peer.sin_family = sa_family_t(AF_INET6)
        #expect(LoopbackSocket.loopbackPeerPort(peer) == nil)
    }

    @Test func aGateClosedBeforeItStartsReleasesItsPort() throws {
        let engine = try FakeEngine(serve: { _ in })
        let gate = try Self.quietGate(20_000..<20_200, engine: engine)
        gate.close()
        gate.start()
        // A child that another test is spawning may hold a copy of the listener until it executes.
        #expect(waitFor {
            do {
                _ = try LoopbackClient(port: gate.port)
                return nil
            } catch {
                return error as? POSIXError == POSIXError(.ECONNREFUSED) ? true : nil
            }
        } == true)
    }

    /// `close()` returns only once the listener is closed, even while the accept thread is busy (here in a slow
    /// diagnostic callback), so a new gate can take the port at once (Windows `Dispose`). Only this process's descriptors
    /// are inspected: a child that another test is spawning may briefly hold a copy of the listener.
    @Test func closingAStartedGateClosesItsListenerBeforeReturning() throws {
        let engine = try FakeEngine(serve: { _ in })
        let busy = DispatchSemaphore(value: 0)
        let gate = try Self.quietGate(22_000..<22_200, engine: engine, capacity: 1, trace: { line in
            guard line == GateDiagnostics.capacityFailure else { return }
            busy.signal()
            usleep(300_000)
        })
        gate.start()
        let first = try Self.dial(gate)
        #expect(waitFor { gate.activeConnections == 1 ? true : nil } == true)
        let second = try Self.dial(gate)
        #expect(busy.wait(timeout: .now() + 5) == .success)
        gate.close()
        #expect(ProcessInspector.tcpSockets(of: getpid())?.contains { $0.listening && $0.localPort == gate.port } == false)
        // The first connection ended with the close: refused with a 403 if its admission was still running (one that
        // finishes after `close()` does not count), otherwise while it waited for its header.
        let rest = Self.receiveAll(first.descriptor)
        #expect(rest == [] || rest == ProxyGate.forbidden)
        withExtendedLifetime(second) {}
    }
}
