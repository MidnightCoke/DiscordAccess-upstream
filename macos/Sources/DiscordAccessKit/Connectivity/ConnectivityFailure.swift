import Foundation

/// Why a connectivity check failed (Windows `ConnectivityFailureException`). Only fixed categories, an HTTP status and
/// the type of a response are kept: never a URL, header, body or error text.
public struct ConnectivityFailure: Error, Equatable, CustomStringConvertible {
    public enum Endpoint: Equatable, Sendable {
        case gateway
        case updates
    }

    public enum Reason: Equatable, Sendable {
        case http, dns, tls, connect, timeout, invalidResponse, responseTooLarge, incompleteResponse, canceled, other
    }

    public enum ResponseKind: Equatable, Sendable {
        case none, json, html, other
    }

    public let endpoint: Endpoint
    public let reason: Reason
    /// The status of an `http` failure when it is 100-599, otherwise 0.
    public let httpStatus: Int
    public let responseKind: ResponseKind

    public init(endpoint: Endpoint, reason: Reason, httpStatus: Int = 0, responseKind: ResponseKind = .none) {
        self.endpoint = endpoint
        self.reason = reason
        self.httpStatus = reason == .http && (100...599).contains(httpStatus) ? httpStatus : 0
        self.responseKind = responseKind
    }

    public var description: String { message }

    /// Windows `MessageFor`, word for word.
    public var message: String {
        let label = endpoint == .gateway ? "Discord Gateway API" : "Discord update server"
        var detail: String
        switch reason {
        case .http: detail = httpStatus == 0 ? "HTTP error response" : "HTTP " + String(httpStatus)
        case .dns: detail = "DNS resolution failed"
        case .tls: detail = "TLS connection or certificate validation failed"
        case .connect: detail = "could not connect to the network or the local proxy"
        case .timeout: detail = "timed out"
        case .invalidResponse: detail = "the expected response format could not be verified"
        case .responseTooLarge: detail = "the response exceeds the size limit"
        case .incompleteResponse: detail = "the response transfer did not finish"
        case .canceled: detail = "the operation was canceled"
        case .other: detail = "access could not be verified"
        }
        switch responseKind {
        case .none: break
        case .json: detail += "; response type JSON"
        case .html: detail += "; response type HTML"
        case .other: detail += "; response type other"
        }
        return label + " check failed (" + detail + ")."
    }

    /// The type of a response from its `Content-Type` (Windows `ContentKind`).
    static func responseKind(contentType: String?) -> ResponseKind {
        guard let contentType, !contentType.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        guard contentType.utf8.count <= 256 else { return .other }
        let kind = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch kind {
        case "application/json", "text/json": return .json
        case "text/html", "application/xhtml+xml": return .html
        default: return .other
        }
    }

    /// The failure of a URLSession task, by its error (Windows `From`); `expired` reports that the check's own deadline
    /// ended the task.
    static func from(_ error: Error, endpoint: Endpoint, expired: Bool) -> ConnectivityFailure {
        if expired { return ConnectivityFailure(endpoint: endpoint, reason: .timeout) }
        if let known = error as? ConnectivityFailure { return known }
        let failure = error as NSError
        // CFNetwork reports a proxy it cannot use as kCFErrorHTTPProxyConnectionFailure (306) for plain HTTP, and as
        // kCFErrorHTTPSProxyConnectionFailure (310) or an unexpected answer to CONNECT (311) for HTTPS and WebSocket; the
        // proxy refusing the connection, answering 403 or dropping the tunnel all end this way, in either domain.
        if [306, 310, 311].contains(failure.code) && (failure.domain == NSURLErrorDomain || failure.domain == kCFErrorDomainCFNetwork as String) {
            return ConnectivityFailure(endpoint: endpoint, reason: .connect)
        }
        // A socket error, as Windows `SocketException`: a timeout, or a connection that could not be made or was lost.
        if failure.domain == NSPOSIXErrorDomain {
            if failure.code == Int(ETIMEDOUT) { return ConnectivityFailure(endpoint: endpoint, reason: .timeout) }
            let connection = [ECONNREFUSED, ECONNRESET, ECONNABORTED, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ENOTCONN, EPIPE]
            return ConnectivityFailure(endpoint: endpoint, reason: connection.contains(Int32(failure.code)) ? .connect : .other)
        }
        guard failure.domain == NSURLErrorDomain else { return ConnectivityFailure(endpoint: endpoint, reason: .other) }
        let reason: Reason
        switch URLError.Code(rawValue: failure.code) {
        case .timedOut: reason = .timeout
        case .cancelled: reason = .canceled
        case .cannotFindHost, .dnsLookupFailed: reason = .dns
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired: reason = .tls
        case .cannotConnectToHost, .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed: reason = .connect
        case .networkConnectionLost, .zeroByteResource: reason = .incompleteResponse
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData: reason = .invalidResponse
        case .dataLengthExceedsMaximum: reason = .responseTooLarge
        default: reason = .other
        }
        return ConnectivityFailure(endpoint: endpoint, reason: reason)
    }
}
