import Darwin
import Foundation

/// Non-blocking TCP sockets on 127.0.0.1 for the gate. Every socket is close-on-exec and never raises SIGPIPE, and
/// connections send without Nagle's delay. Every wait also ends when `stop` becomes readable: the gate closes the write
/// end of that pipe when it closes, which wakes all waits at once. Deadlines use a monotonic clock, so changing the
/// system time does not shorten or extend them.
enum LoopbackSocket {
    static let loopback = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)

    /// A listener on 127.0.0.1:`port` (0 picks a free port) and the port it got. `SO_REUSEADDR` lets a new gate take
    /// the port of a closed one while its old connections linger in TIME_WAIT; no other socket can bind 127.0.0.1:`port`
    /// while this one listens, since that would need `SO_REUSEPORT` on both.
    static func listen(port: UInt16, backlog: Int32) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GateFailure.socket(errno) }
        var address = loopbackAddress(port: port)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var one: Int32 = 1
        let reusable = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        let ready = setFlags(descriptor) && reusable && withGenericAddress(&address) { generic in
            bind(descriptor, generic, length) == 0 && Darwin.listen(descriptor, backlog) == 0 && getsockname(descriptor, generic, &length) == 0
        }
        guard ready else {
            let error = errno
            Darwin.close(descriptor)
            throw GateFailure.socket(error)
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    /// The next pending connection and its peer address, or nil when none is pending (or it went away meanwhile).
    static func accept(_ listener: Int32) throws -> (descriptor: Int32, peer: sockaddr_in)? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let descriptor = withGenericAddress(&address) { Darwin.accept(listener, $0, &length) }
        guard descriptor >= 0 else {
            if errno == EAGAIN || errno == EINTR || errno == ECONNABORTED { return nil }
            throw GateFailure.socket(errno)
        }
        guard setFlags(descriptor), setConnectionOptions(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }
        return (descriptor, address)
    }

    /// A connection to 127.0.0.1:`port`, established before `deadline`.
    static func connect(port: UInt16, until deadline: ContinuousClock.Instant, stop: Int32) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GateFailure.socket(errno) }
        do {
            guard setFlags(descriptor), setConnectionOptions(descriptor) else { throw GateFailure.socket(errno) }
            var address = loopbackAddress(port: port)
            let started = withGenericAddress(&address) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            if started != 0 {
                guard errno == EINPROGRESS || errno == EINTR else { throw GateFailure.socket(errno) }
                try wait(descriptor, for: Int16(POLLOUT), until: deadline, stop: stop)
                var status: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &status, &length) == 0 else { throw GateFailure.socket(errno) }
                guard status == 0 else { throw GateFailure.socket(status) }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// The request header: the bytes up to and including the first CR LF CR LF, at most 32 KiB in all, read before
    /// `deadline`; the header must be ASCII. Bytes that arrived after it are returned untouched (Windows `ReadHeader`).
    static func readHeader(_ descriptor: Int32, until deadline: ContinuousClock.Instant, stop: Int32) throws -> (header: [UInt8], remainder: [UInt8]) {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1024)
        var scan = 0
        while bytes.count < RequestPolicy.maxHeaderLength {
            try wait(descriptor, for: Int16(POLLIN), until: deadline, stop: stop)
            let wanted = min(chunk.count, RequestPolicy.maxHeaderLength - bytes.count)
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw GateFailure.io(errno)
            }
            guard count > 0 else { throw GateFailure.io(nil) }
            bytes += chunk[0..<count]
            while scan + 3 < bytes.count {
                if bytes[scan] == 13 && bytes[scan + 1] == 10 && bytes[scan + 2] == 13 && bytes[scan + 3] == 10 {
                    let end = scan + 4
                    guard bytes[..<end].allSatisfy({ $0 <= 127 }) else { throw GateFailure.invalidData }
                    return (Array(bytes[..<end]), Array(bytes[end...]))
                }
                scan += 1
            }
        }
        throw GateFailure.invalidData
    }

    /// Writes all of `bytes` before `deadline`.
    static func write(_ descriptor: Int32, _ bytes: [UInt8], until deadline: ContinuousClock.Instant, stop: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0 && errno != EAGAIN && errno != EINTR { throw GateFailure.io(errno) }
            try wait(descriptor, for: Int16(POLLOUT), until: deadline, stop: stop)
        }
    }

    /// Waits until `descriptor` is ready for `events`, or has an error or hang-up to report. Throws `.timeout` at
    /// `deadline` and `.canceled` once `stop` is readable.
    static func wait(_ descriptor: Int32, for events: Int16, until deadline: ContinuousClock.Instant, stop: Int32) throws {
        while true {
            guard let timeout = pollTimeout(until: deadline) else { throw GateFailure.timeout }
            var watched = [pollfd(fd: descriptor, events: events, revents: 0), pollfd(fd: stop, events: Int16(POLLIN), revents: 0)]
            let result = poll(&watched, 2, timeout)
            if result < 0 {
                if errno == EINTR { continue }
                throw GateFailure.unexpected
            }
            if watched[1].revents != 0 { throw GateFailure.canceled }
            if watched[0].revents != 0 { return }
        }
    }

    /// Whole milliseconds from `now` until `deadline` for `poll`, rounded up so a wait never ends early and at most one
    /// day; nil once the deadline has passed.
    static func pollTimeout(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Int32? {
        let remaining = deadline - now
        guard remaining > .zero else { return nil }
        let (seconds, attoseconds) = remaining.components
        return Int32(min(seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000, 86_400_000))
    }

    static func localPort(_ descriptor: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withGenericAddress(&address, { getsockname(descriptor, $0, &length) }) == 0, address.sin_family == sa_family_t(AF_INET) else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    /// The client port of a peer that connected from exactly 127.0.0.1, otherwise nil.
    static func loopbackPeerPort(_ peer: sockaddr_in) -> UInt16? {
        guard peer.sin_family == sa_family_t(AF_INET), peer.sin_addr.s_addr == loopback.s_addr else { return nil }
        return UInt16(bigEndian: peer.sin_port)
    }

    /// A pipe whose read end becomes readable for good once the write end is closed; both ends are close-on-exec.
    static func stopPipe() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw GateFailure.socket(errno) }
        guard fcntl(ends[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(ends[1], F_SETFD, FD_CLOEXEC) == 0 else {
            let error = errno
            Darwin.close(ends[0])
            Darwin.close(ends[1])
            throw GateFailure.socket(error)
        }
        return (ends[0], ends[1])
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = loopback
        address.sin_port = port.bigEndian
        return address
    }

    /// Close-on-exec and non-blocking.
    private static func setFlags(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 && flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// No SIGPIPE on a write to a closed peer, and no Nagle delay (Windows `NoDelay`).
    private static func setConnectionOptions(_ descriptor: Int32) -> Bool {
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, size) == 0 && setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, size) == 0
    }

    private static func withGenericAddress<Result>(_ address: inout sockaddr_in, _ body: (UnsafeMutablePointer<sockaddr>) -> Result) -> Result {
        withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, body) }
    }
}
