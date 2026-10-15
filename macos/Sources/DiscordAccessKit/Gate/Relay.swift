import Darwin
import Foundation

/// Copies bytes both ways between a client and the engine (Windows: the two `CopyToAsync` pumps of
/// `ProcessGate.Handle`). A direction ends when its input ends and everything read has been written; then the sending
/// side of its destination is shut down, so a TCP half-close passes through, and the other direction may still finish
/// within `drainTimeout` (more than 0 and at most 30 seconds). Both sockets must be non-blocking; one thread does all the
/// work with `poll`. The relay never closes a descriptor; its caller does.
enum Relay {
    enum Outcome: Equatable {
        case finished
        case canceled
        /// The first failure, the direction it happened in (nil when shutting down a sending side failed) and how long
        /// the relay had run.
        case failed(GateFailure, RelayDirection?, elapsedMilliseconds: Int64)
    }

    static let bufferSize = 16384

    private struct Pump {
        let direction: RelayDirection
        let source: Int32
        let destination: Int32
        var buffer = [UInt8](repeating: 0, count: Relay.bufferSize)
        /// Bytes read but not yet written.
        var pending = 0..<0
        var inputEnded = false
        var finished = false
    }

    static func run(client: Int32, engine: Int32, stop: Int32, drainTimeout: TimeInterval) -> Outcome {
        precondition(drainTimeout > 0 && drainTimeout <= 30)
        let started = ContinuousClock.now
        func elapsed() -> Int64 {
            let (seconds, attoseconds) = (ContinuousClock.now - started).components
            return seconds * 1000 + attoseconds / 1_000_000_000_000_000
        }
        var pumps = [Pump(direction: .clientToEngine, source: client, destination: engine),
                     Pump(direction: .engineToClient, source: engine, destination: client)]
        var drainDeadline: ContinuousClock.Instant?
        while !(pumps[0].finished && pumps[1].finished) {
            var timeout: Int32 = -1
            if let drainDeadline {
                guard let remaining = LoopbackSocket.pollTimeout(until: drainDeadline) else {
                    return .failed(.timeout, pumps.first(where: { !$0.finished })?.direction, elapsedMilliseconds: elapsed())
                }
                timeout = remaining
            }
            var watched = [pollfd(fd: stop, events: Int16(POLLIN), revents: 0), pollfd(fd: client, events: 0, revents: 0),
                           pollfd(fd: engine, events: 0, revents: 0)]
            for pump in pumps where !pump.finished {
                if !pump.pending.isEmpty {
                    watched[pump.destination == client ? 1 : 2].events |= Int16(POLLOUT)
                } else if !pump.inputEnded {
                    watched[pump.source == client ? 1 : 2].events |= Int16(POLLIN)
                }
            }
            let result = poll(&watched, 3, timeout)
            if result < 0 {
                if errno == EINTR { continue }
                return .failed(.unexpected, nil, elapsedMilliseconds: elapsed())
            }
            if watched[0].revents != 0 { return .canceled }
            let failed = Int16(POLLHUP | POLLERR | POLLNVAL)
            for index in pumps.indices where !pumps[index].finished {
                let sourceReady = watched[pumps[index].source == client ? 1 : 2].revents & (Int16(POLLIN) | failed) != 0
                let destinationReady = watched[pumps[index].destination == client ? 1 : 2].revents & (Int16(POLLOUT) | failed) != 0
                do {
                    try step(&pumps[index], sourceReady: sourceReady, destinationReady: destinationReady)
                } catch {
                    return .failed(error as? GateFailure ?? .unexpected, pumps[index].direction, elapsedMilliseconds: elapsed())
                }
                if pumps[index].inputEnded && pumps[index].pending.isEmpty {
                    // A shutdown error cannot be put down to either copy (Windows logs `direction=unknown`).
                    guard shutdown(pumps[index].destination, SHUT_WR) == 0 || errno == ENOTCONN else {
                        return .failed(.io(errno), nil, elapsedMilliseconds: elapsed())
                    }
                    pumps[index].finished = true
                    if drainDeadline == nil { drainDeadline = .now + .seconds(drainTimeout) }
                }
            }
        }
        return .finished
    }

    /// Writes pending bytes when the destination is ready, otherwise reads more when the source is ready.
    private static func step(_ pump: inout Pump, sourceReady: Bool, destinationReady: Bool) throws {
        if !pump.pending.isEmpty {
            guard destinationReady else { return }
            let range = pump.pending
            let count = pump.buffer.withUnsafeBytes { write(pump.destination, $0.baseAddress! + range.lowerBound, range.count) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                throw GateFailure.io(errno)
            }
            pump.pending = (range.lowerBound + count)..<range.upperBound
        } else if !pump.inputEnded && sourceReady {
            let count = pump.buffer.withUnsafeMutableBytes { read(pump.source, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                throw GateFailure.io(errno)
            }
            if count == 0 { pump.inputEnded = true } else { pump.pending = 0..<count }
        }
    }
}
