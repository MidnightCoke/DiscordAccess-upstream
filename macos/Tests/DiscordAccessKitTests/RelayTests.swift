import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The relay between two real loopback TCP connections in this process: the test plays the client on one and the engine
/// on the other.
@Suite struct RelayTests {
    /// Both ends of one loopback TCP connection; the caller closes them.
    static func connection() throws -> (near: Int32, far: Int32) {
        let listener = try TCPListener()
        let near = socket(AF_INET, SOCK_STREAM, 0)
        guard near >= 0 else { throw lastPOSIXError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = listener.port.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(near, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        do {
            guard connected else { throw lastPOSIXError() }
            return (near, try listener.acceptClient().descriptor)
        } catch {
            close(near)
            throw error
        }
    }

    /// The relay running on its own thread between the relay ends of a client and an engine connection. Every
    /// descriptor is closed exactly once: a descriptor number closed twice could belong to another test by then.
    final class Run {
        private final class Result {
            let done = DispatchSemaphore(value: 0)
            var outcome: Relay.Outcome?
        }

        private(set) var client: Int32
        private(set) var engine: Int32
        private let relayClient: Int32
        private let relayEngine: Int32
        private let stopRead: Int32
        private var stopWrite: Int32
        private let finished = Result()

        init(drainTimeout: TimeInterval = 5) throws {
            let clientSide = try RelayTests.connection()
            let engineSide: (near: Int32, far: Int32)
            let stop: (read: Int32, write: Int32)
            do {
                engineSide = try RelayTests.connection()
                do {
                    stop = try LoopbackSocket.stopPipe()
                } catch {
                    for descriptor in [engineSide.near, engineSide.far] { Darwin.close(descriptor) }
                    throw error
                }
            } catch {
                for descriptor in [clientSide.near, clientSide.far] { Darwin.close(descriptor) }
                throw error
            }
            (client, relayClient) = clientSide
            (relayEngine, engine) = engineSide
            (stopRead, stopWrite) = stop
            var one: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            // The relay's ends are set up as the gate sets up its own.
            for descriptor in [relayClient, relayEngine] {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
                setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, size)
            }
            // The test's ends give up after 5 seconds instead of hanging.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            for descriptor in [client, engine] {
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
            }
            // The thread holds only what it uses, so releasing the run stops it.
            let (relayClient, relayEngine, stopRead, finished) = (relayClient, relayEngine, stopRead, finished)
            Thread {
                finished.outcome = Relay.run(client: relayClient, engine: relayEngine, stop: stopRead, drainTimeout: drainTimeout)
                finished.done.signal()
            }.start()
        }

        /// The outcome, once the relay ends within `timeout`.
        func result(timeout: TimeInterval = 5) -> Relay.Outcome? {
            guard finished.done.wait(timeout: .now() + timeout) == .success else { return nil }
            finished.done.signal()
            return finished.outcome
        }

        /// Closes the write end of the stop pipe, as closing the gate does.
        func cancel() {
            guard stopWrite >= 0 else { return }
            Darwin.close(stopWrite)
            stopWrite = -1
        }

        /// Closes the engine's socket with a reset instead of an orderly end.
        func resetEngine() {
            RelayTests.reset(engine)
            engine = -1
        }

        /// Closes the client's socket with a reset instead of an orderly end.
        func resetClient() {
            RelayTests.reset(client)
            client = -1
        }

        deinit {
            cancel()
            guard result() != nil else { return }  // never close what a running relay still uses
            for descriptor in [client, engine, relayClient, relayEngine, stopRead] where descriptor >= 0 { Darwin.close(descriptor) }
        }
    }

    static func reset(_ descriptor: Int32) {
        var reset = linger(l_onoff: 1, l_linger: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
        Darwin.close(descriptor)
    }

    static func send(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard count > 0 else { throw lastPOSIXError() }
                offset += count
            }
        }
    }

    /// Everything until the peer's end of stream (or `limit` bytes).
    static func receive(_ descriptor: Int32, limit: Int = .max) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while bytes.count < limit {
            let count = read(descriptor, &chunk, min(chunk.count, limit - bytes.count))
            guard count >= 0 else { throw lastPOSIXError() }
            if count == 0 { break }
            bytes += chunk[0..<count]
        }
        return bytes
    }

    static let pattern = (0..<(256 * 1024)).map { UInt8($0 % 251) }

    @Test func copiesBothWaysAndPassesEachHalfCloseOn() throws {
        let run = try Run()
        try Self.send(run.client, Array("ping".utf8))
        #expect(try Self.receive(run.engine, limit: 4) == Array("ping".utf8))
        try Self.send(run.engine, Self.pattern)
        shutdown(run.engine, SHUT_WR)
        #expect(try Self.receive(run.client) == Self.pattern)
        // The engine has finished sending; what the client still sends must arrive.
        try Self.send(run.client, Array("late".utf8))
        shutdown(run.client, SHUT_WR)
        #expect(try Self.receive(run.engine) == Array("late".utf8))
        #expect(run.result() == .finished)
    }

    /// Streams larger than the socket buffers in both directions at once, so the relay meets full buffers, partial writes
    /// and both events on one socket.
    @Test func copiesLargeStreamsBothWaysAtOnce() throws {
        let run = try Run()
        let upstream = (0..<(2 << 20)).map { UInt8($0 % 241) }
        let downstream = (0..<(2 << 20)).map { UInt8($0 % 239) }
        let sent = DispatchGroup()
        for (descriptor, bytes) in [(run.client, upstream), (run.engine, downstream)] {
            sent.enter()
            Thread {
                // A failed send ends the stream early, so the comparison below fails instead of the test hanging.
                _ = try? RelayTests.send(descriptor, bytes)
                shutdown(descriptor, SHUT_WR)
                sent.leave()
            }.start()
        }
        // If a check below fails early, the senders may still use their descriptors: the run must outlive them.
        defer {
            _ = sent.wait(timeout: .now() + 15)
            withExtendedLifetime(run) {}
        }
        #expect(try Self.receive(run.engine) == upstream)
        #expect(try Self.receive(run.client) == downstream)
        #expect(sent.wait(timeout: .now() + 5) == .success)
        #expect(run.result() == .finished)
    }

    /// After the client's half-close the engine may still answer, for at most the drain time counted from that end.
    @Test func boundsTheDrainOnceOneDirectionHasEnded() throws {
        let run = try Run(drainTimeout: 0.3)
        usleep(200_000)
        shutdown(run.client, SHUT_WR)
        let halfClosed = ContinuousClock.now
        #expect(try Self.receive(run.engine) == [])
        try Self.send(run.engine, Array("late".utf8))
        #expect(try Self.receive(run.client, limit: 4) == Array("late".utf8))
        let outcome = try #require(run.result())
        let drained = ContinuousClock.now - halfClosed
        guard case .failed(.timeout, .engineToClient, let elapsed) = outcome else {
            Issue.record("unexpected outcome \(outcome)")
            return
        }
        // A drain counted from the start of the relay, 200 ms before the half-close, would end about 100 ms after it.
        #expect(drained >= .milliseconds(280) && elapsed < 3000)
    }

    /// With nothing pending, a reset is seen by the direction that reads from the side that reset. With bytes pending,
    /// the other direction's write may see it first; Windows names whichever copy failed first in the same way.
    @Test func reportsAResetWithTheDirectionItCameFrom() throws {
        let run = try Run()
        try Self.send(run.client, Array("ping".utf8))
        #expect(try Self.receive(run.engine, limit: 4) == Array("ping".utf8))
        run.resetEngine()
        let outcome = try #require(run.result())
        guard case .failed(.io(ECONNRESET), .engineToClient, _) = outcome else {
            Issue.record("unexpected outcome \(outcome)")
            return
        }
    }

    @Test func reportsAClientResetInTheOtherDirection() throws {
        let run = try Run()
        try Self.send(run.engine, Array("pong".utf8))
        #expect(try Self.receive(run.client, limit: 4) == Array("pong".utf8))
        run.resetClient()
        let outcome = try #require(run.result())
        guard case .failed(.io(ECONNRESET), .clientToEngine, _) = outcome else {
            Issue.record("unexpected outcome \(outcome)")
            return
        }
    }

    @Test func endsAtOnceWhenTheStopPipeCloses() throws {
        let run = try Run()
        let started = Date()
        run.cancel()
        #expect(run.result(timeout: 2) == .canceled)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
