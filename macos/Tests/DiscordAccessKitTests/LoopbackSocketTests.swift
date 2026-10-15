import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The gate's sockets on their own, over real loopback connections in this process that the code under test makes.
@Suite struct LoopbackSocketTests {
    /// A stop pipe whose ends are each closed once: the write end by `fire()` or at the end, the read end at the end.
    final class Stop {
        let read: Int32
        private var write: Int32

        init() throws {
            (read, write) = try LoopbackSocket.stopPipe()
        }

        func fire() {
            guard write >= 0 else { return }
            close(write)
            write = -1
        }

        deinit {
            fire()
            close(read)
        }
    }

    /// The next connection of `listener` within 5 seconds.
    static func accept(_ listener: Int32, stop: Stop) throws -> (descriptor: Int32, peer: sockaddr_in) {
        try LoopbackSocket.wait(listener, for: Int16(POLLIN), until: .now + .seconds(5), stop: stop.read)
        guard let accepted = try LoopbackSocket.accept(listener) else { throw POSIXError(.ECONNABORTED) }
        return accepted
    }

    /// Runs `body` with both ends of one connection, the accepted end first, and closes them afterwards.
    static func withConnection(_ body: (_ accepted: Int32, _ connected: Int32, _ stop: Stop) throws -> Void) throws {
        let stop = try Stop()
        let listener = try LoopbackSocket.listen(port: 0, backlog: 4)
        defer { close(listener.descriptor) }
        let connected = try LoopbackSocket.connect(port: listener.port, until: .now + .seconds(5), stop: stop.read)
        defer { close(connected) }
        let accepted = try accept(listener.descriptor, stop: stop)
        defer { close(accepted.descriptor) }
        try body(accepted.descriptor, connected, stop)
    }

    /// The value of an integer socket option, or 0 when it cannot be read.
    static func option(_ descriptor: Int32, _ level: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, level, name, &value, &length) == 0 ? value : 0
    }

    @Test func setsTheOptionsTheGateReliesOn() throws {
        let stop = try Stop()
        let listener = try LoopbackSocket.listen(port: 0, backlog: 4)
        defer { close(listener.descriptor) }
        let connected = try LoopbackSocket.connect(port: listener.port, until: .now + .seconds(5), stop: stop.read)
        defer { close(connected) }
        let accepted = try Self.accept(listener.descriptor, stop: stop)
        defer { close(accepted.descriptor) }
        let pipe = try LoopbackSocket.stopPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }
        #expect(LoopbackSocket.loopbackPeerPort(accepted.peer) == LoopbackSocket.localPort(connected))
        #expect(Self.option(listener.descriptor, SOL_SOCKET, SO_REUSEADDR) != 0)
        for descriptor in [listener.descriptor, connected, accepted.descriptor, pipe.read, pipe.write] {
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }
        for descriptor in [listener.descriptor, connected, accepted.descriptor] {
            #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0)
        }
        for descriptor in [connected, accepted.descriptor] {
            #expect(Self.option(descriptor, SOL_SOCKET, SO_NOSIGPIPE) != 0)
            #expect(Self.option(descriptor, IPPROTO_TCP, TCP_NODELAY) != 0)
        }
    }

    /// The header ends at the first CR LF CR LF; what follows it, even bytes that are not ASCII, comes back untouched.
    @Test func returnsTheHeaderAndTheBytesAfterItUntouched() throws {
        let header = Array("GET http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\n\r\n".utf8)
        let rest: [UInt8] = [0xC3, 0x28, 0x00, 13, 10, 13, 10]
        try Self.withConnection { accepted, connected, stop in
            try LoopbackSocket.write(connected, header + rest, until: .now + .seconds(5), stop: stop.read)
            let read = try LoopbackSocket.readHeader(accepted, until: .now + .seconds(5), stop: stop.read)
            #expect(read.header == header)
            #expect(read.remainder == rest)
        }
    }

    /// A header with a byte that is not ASCII, one of 32 KiB without its end, and one whose end would finish past 32 KiB.
    static let refusedHeaders: [[UInt8]] = [
        Array("GET http://discord.com/ HTTP/1.1\r\nUser-Agent: caf".utf8) + [0xC3, 0xA9] + Array("\r\n\r\n".utf8),
        [UInt8](repeating: 97, count: 32_768),
        [UInt8](repeating: 97, count: 32_766) + [13, 10, 13, 10],
    ]

    @Test(arguments: refusedHeaders)
    func refusesAHeaderThatIsNotASCIIOrDoesNotEndWithin32KiB(bytes: [UInt8]) throws {
        try Self.withConnection { accepted, connected, stop in
            try LoopbackSocket.write(connected, bytes, until: .now + .seconds(5), stop: stop.read)
            #expect(throws: GateFailure.invalidData) { try LoopbackSocket.readHeader(accepted, until: .now + .seconds(5), stop: stop.read) }
        }
    }

    @Test func reportsAStreamThatEndsBeforeTheHeaderDoes() throws {
        try Self.withConnection { accepted, connected, stop in
            try LoopbackSocket.write(connected, Array("GET http://discord.com/ HTTP/1.1\r\n".utf8), until: .now + .seconds(5), stop: stop.read)
            shutdown(connected, SHUT_WR)
            #expect(throws: GateFailure.io(nil)) { try LoopbackSocket.readHeader(accepted, until: .now + .seconds(5), stop: stop.read) }
        }
    }

    /// Reads and writes end at their deadline, and at once when the stop pipe closes, even with time left.
    @Test func endsReadsAndWritesAtTheDeadlineOrTheStop() throws {
        // Nobody reads the other end, so the buffers fill up and the write has to wait.
        let large = [UInt8](repeating: 0, count: 16 << 20)
        try Self.withConnection { accepted, connected, stop in
            #expect(throws: GateFailure.timeout) { try LoopbackSocket.readHeader(accepted, until: .now + .milliseconds(100), stop: stop.read) }
            #expect(throws: GateFailure.timeout) { try LoopbackSocket.write(connected, large, until: .now + .milliseconds(100), stop: stop.read) }
            stop.fire()
            let started = ContinuousClock.now
            #expect(throws: GateFailure.canceled) { try LoopbackSocket.readHeader(accepted, until: .now + .seconds(5), stop: stop.read) }
            #expect(throws: GateFailure.canceled) { try LoopbackSocket.write(connected, large, until: .now + .seconds(5), stop: stop.read) }
            #expect(ContinuousClock.now - started < .seconds(1))
        }
    }

    /// A socket bound to 127.0.0.1:`port` (0 picks one) that does not listen, and its port; the caller closes it.
    static func boundSocket(port: UInt16 = 0) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw lastPOSIXError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
        }
        guard bound else {
            let error = lastPOSIXError()
            close(descriptor)
            throw error
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    /// A bound socket that does not listen keeps its port from every other test, and macOS drops the connection attempts
    /// it gets without an answer: a connection to it ends only at its deadline or with the stop.
    @Test func endsAConnectionAttemptAtTheDeadlineOrTheStop() throws {
        let stop = try Stop()
        let holder = try Self.boundSocket()
        defer { close(holder.descriptor) }
        #expect(throws: GateFailure.timeout) { _ = try LoopbackSocket.connect(port: holder.port, until: .now + .milliseconds(200), stop: stop.read) }
        stop.fire()
        let started = ContinuousClock.now
        #expect(throws: GateFailure.canceled) { _ = try LoopbackSocket.connect(port: holder.port, until: .now + .seconds(5), stop: stop.read) }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    /// A port outside the range the system hands out (49152-65535) stays free once its socket is closed, since no other
    /// test binds there; a connection to it is refused.
    @Test func reportsARefusedConnection() throws {
        let stop = try Stop()
        var free: UInt16?
        for candidate in UInt16(21_000)..<21_200 where free == nil {
            guard let holder = try? Self.boundSocket(port: candidate) else { continue }
            close(holder.descriptor)
            free = holder.port
        }
        let port = try #require(free)
        #expect(throws: GateFailure.socket(ECONNREFUSED)) { _ = try LoopbackSocket.connect(port: port, until: .now + .seconds(5), stop: stop.read) }
    }

    /// `poll` gets whole milliseconds, rounded up so that a wait never wakes before its deadline, and at most one day.
    @Test func roundsPollTimeoutsUpToWholeMilliseconds() {
        let now = ContinuousClock.now
        #expect(LoopbackSocket.pollTimeout(until: now, now: now) == nil)
        #expect(LoopbackSocket.pollTimeout(until: now - .milliseconds(1), now: now) == nil)
        #expect(LoopbackSocket.pollTimeout(until: now + .nanoseconds(1), now: now) == 1)
        #expect(LoopbackSocket.pollTimeout(until: now + .milliseconds(1), now: now) == 1)
        #expect(LoopbackSocket.pollTimeout(until: now + .microseconds(1_001), now: now) == 2)
        #expect(LoopbackSocket.pollTimeout(until: now + .seconds(15), now: now) == 15_000)
        #expect(LoopbackSocket.pollTimeout(until: now + .seconds(200_000), now: now) == 86_400_000)
    }
}
