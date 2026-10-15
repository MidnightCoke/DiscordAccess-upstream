import Darwin
import Foundation

/// The stage at which a gate connection ended (Windows `ProcessGate.RelayStage`).
public enum GateStage: String, Sendable {
    case admission = "Admission"
    case ownership = "Ownership"
    case headerRead = "HeaderRead"
    case requestPolicy = "RequestPolicy"
    case backendConnect = "BackendConnect"
    case backendIdentity = "BackendIdentity"
    case backendWrite = "BackendWrite"
    case relay = "Relay"
}

/// A direction of the relay, as diagnostics name it.
public enum RelayDirection: String, Sendable {
    case clientToEngine = "client_to_engine"
    case engineToClient = "engine_to_client"
}

/// Why a gate step failed, in the categories of the Windows diagnostics. A failed socket call carries its `errno`.
public enum GateFailure: Error, Equatable, Sendable {
    /// The request policy refused the header.
    case refused(RequestFailure)
    case timeout
    /// The gate closed.
    case canceled
    /// Creating, binding, accepting or connecting a socket failed.
    case socket(Int32)
    /// A read or write failed (`errno`), or the peer ended the stream early (nil).
    case io(Int32?)
    /// The header is too long or not ASCII, or the engine did not accept the connection itself.
    case invalidData
    case unexpected
}

/// The gate's diagnostic lines (Windows `ProcessGate` traces). A line holds only the stage, a validated host and port,
/// a fixed category and a known socket error name: never a URL, header, body, credential or error message.
public enum GateDiagnostics {
    public static let capacityFailure = "Failure stage=Admission target=unknown category=Capacity"

    /// A refused client (Windows `category=UnownedClient`) with the reason of the refusal. Callers pass
    /// `PeerAdmission.Refusal.diagnostic` or a fixed reason; the reason is not checked against that vocabulary, but it is
    /// filtered here: letters, digits, spaces and `._()=-` are kept, anything else becomes `_`, and at most 96 characters
    /// remain, so a reason can never start another line.
    public static func unownedClient(reason: String) -> String {
        let safe = reason.unicodeScalars.prefix(96).map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " ._()=-".unicodeScalars.contains(scalar)) ? Character(scalar) : "_"
        }
        return "Failure stage=Ownership target=unknown category=UnownedClient reason=" + String(safe)
    }

    public static func failure(stage: GateStage, target: String, error: GateFailure) -> String {
        "Failure stage=" + stage.rawValue + " target=" + safeAuthority(target) + " category=" + category(of: error) + socketDetail(of: error)
    }

    /// A relay failure with the direction that failed first and how long the relay ran, clamped to one day.
    public static func relayFailure(target: String, error: GateFailure, direction: RelayDirection?, elapsedMilliseconds: Int64) -> String {
        failure(stage: .relay, target: target, error: error) + " direction=" + (direction?.rawValue ?? "unknown") +
            " elapsed_ms=" + String(min(86_400_000, max(0, elapsedMilliseconds)))
    }

    /// The validated `host:port` a request header names, with the host in lower case, or `unknown` (Windows `SafeTarget`).
    public static func safeTarget(_ header: String) -> String {
        let bytes = Array(header.utf8)
        guard !bytes.isEmpty, bytes.count <= RequestPolicy.maxHeaderLength,
              let end = bytes.indices.dropLast().first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 }) else { return "unknown" }
        let line = bytes[..<end].split(separator: 32, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard line.count == 3 else { return "unknown" }
        if line[0] == "CONNECT" { return safeAuthority(line[1]) }
        let target = Array(line[1].utf8)
        guard target.count > 7, String(decoding: target.prefix(7), as: UTF8.self).lowercased() == "http://", !target.contains(92) else {
            return "unknown"
        }
        // The authority ends at the path, query or fragment; user information is never logged.
        let authority = target.dropFirst(7).prefix { $0 != 47 && $0 != 63 && $0 != 35 }
        guard !authority.contains(64) else { return "unknown" }
        let text = String(decoding: authority, as: UTF8.self)
        return safeAuthority(authority.contains(58) ? text : text + ":80")
    }

    /// `host:port` with the host in lower case, or `unknown` unless the host is a DNS name and the port is 1-65535
    /// (Windows `SafeAuthority`).
    static func safeAuthority(_ authority: String) -> String {
        guard authority.utf8.count <= 259 else { return "unknown" }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...5).contains(parts[1].utf8.count), parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = Int(parts[1]), (1...65535).contains(port), RequestPolicy.validDNSHost(String(parts[0])) else { return "unknown" }
        return parts[0].lowercased() + ":" + String(port)
    }

    static func category(of error: GateFailure) -> String {
        switch error {
        case .refused(let refusal): return refusal.rawValue
        case .timeout: return "Timeout"
        case .canceled: return "Canceled"
        case .socket: return "Socket"
        case .io: return "IO"
        case .invalidData: return "InvalidData"
        case .unexpected: return "Unexpected"
        }
    }

    /// ` socket=<name>` for an error that Windows names the same way (`SocketError`); nothing for any other.
    static func socketDetail(of error: GateFailure) -> String {
        let code: Int32?
        switch error {
        case .socket(let value): code = value
        case .io(let value): code = value
        default: code = nil
        }
        guard let code, let name = socketErrorNames[code] else { return "" }
        return " socket=" + name
    }

    static let socketErrorNames: [Int32: String] = [
        ECONNREFUSED: "ConnectionRefused", ECONNRESET: "ConnectionReset", ECONNABORTED: "ConnectionAborted", ETIMEDOUT: "TimedOut",
        ENETUNREACH: "NetworkUnreachable", EHOSTUNREACH: "HostUnreachable", ENETDOWN: "NetworkDown", EHOSTDOWN: "HostDown",
        EADDRINUSE: "AddressAlreadyInUse", EADDRNOTAVAIL: "AddressNotAvailable", ENOTCONN: "NotConnected", EPIPE: "Shutdown",
        ENOBUFS: "NoBufferSpaceAvailable", EMFILE: "TooManyOpenSockets",
    ]
}

/// Limits diagnostic lines per minute. Successes and failures have separate budgets, so success lines never use up the
/// failure budget, and both renew every minute (Windows `ProcessGate.TraceBudget`).
public final class TraceBudget {
    public static let successLimit = 32
    public static let failureLimit = 64
    private let lock = NSLock()
    private var window: Date?
    private var successes = 0
    private var failures = 0

    public init() {}

    public func admit(failure: Bool, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A clock set back starts a new window, so it cannot silence failures for good.
        if let start = window, now >= start, now.timeIntervalSince(start) < 60 {} else {
            window = now
            successes = 0
            failures = 0
        }
        if failure {
            guard failures < Self.failureLimit else { return false }
            failures += 1
        } else {
            guard successes < Self.successLimit else { return false }
            successes += 1
        }
        return true
    }
}
