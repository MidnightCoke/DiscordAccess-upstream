import Foundation

/// The stage at which an update bridge request ended (Windows `UpdateBridge.RequestStage`).
enum BridgeStage: String, Sendable {
    case clientOwnership = "ClientOwnership"
    case clientHeader = "ClientHeader"
    case clientRequest = "ClientRequest"
    case upstreamResponse = "UpstreamResponse"
    case upstreamHeaders = "UpstreamHeaders"
    case upstreamBody = "UpstreamBody"
    case manifestRewrite = "ManifestRewrite"
    case clientResponseHeader = "ClientResponseHeader"
    case clientResponseBody = "ClientResponseBody"
}

/// Why an update bridge request failed, in the categories of Windows `UpdateBridge.DescribeFailure`.
enum BridgeFailure: Error, Equatable, Sendable {
    /// The request, a redirect or a manifest broke a rule; the client gets 400 if no response had started.
    case invalidData
    case timeout
    /// The bridge closed.
    case canceled
    /// A read or write on the client connection failed (`errno`), or the client ended the stream early (nil).
    case io(Int32?)
    case socket(Int32)
    /// URLSession could not complete the request through the gate: the error's domain and code.
    case upstream(domain: String, code: Int)
    /// For example a manifest that is not UTF-8 or JSON, as Windows reports its parser's errors.
    case unexpected

    init(_ failure: GateFailure) {
        switch failure {
        case .timeout: self = .timeout
        case .canceled: self = .canceled
        case .io(let code): self = .io(code)
        case .socket(let code): self = .socket(code)
        case .invalidData, .refused: self = .invalidData
        case .unexpected: self = .unexpected
        }
    }

    /// A failure reported by URLSession. Its own timeout and a canceled request keep their categories, as on Windows.
    static func upstream(_ error: Error) -> BridgeFailure {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorTimedOut { return .timeout }
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return .canceled }
        return .upstream(domain: failure.domain, code: failure.code)
    }
}

/// The bridge's own response headers and diagnostic lines (Windows `WriteHeader` and `DescribeFailure`).
enum BridgeResponse {
    /// The answer to a client that is not admitted, as `header` writes it.
    static let forbidden = Array("HTTP/1.1 403 Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n".utf8)

    /// `HTTP/1.1 <status> Response` with `Connection: close`, `Cache-Control: no-store`, the content type
    /// (application/octet-stream when there is none), and the length and location when given. A status outside 200-599,
    /// a content type longer than 256 characters and a value with a control or non-ASCII character are refused.
    static func header(status: Int, contentType: String?, length: Int64?, location: String?) throws -> [UInt8] {
        guard (200...599).contains(status) else { throw BridgeFailure.invalidData }
        let type = contentType.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "application/octet-stream"
        guard type.utf8.count <= 256, type.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { throw BridgeFailure.invalidData }
        var text = "HTTP/1.1 " + String(status) + " Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: " + type + "\r\n"
        if let length {
            guard length >= 0 else { throw BridgeFailure.invalidData }
            text += "Content-Length: " + String(length) + "\r\n"
        }
        if let location {
            guard location.utf8.count <= 16384, location.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw BridgeFailure.invalidData }
            text += "Location: " + location + "\r\n"
        }
        return Array((text + "\r\n").utf8)
    }

    /// The length to announce (Windows): a rewritten manifest's own length; Discord's length for any other body that is
    /// passed on as it came, unless URLSession decoded it; none for 204 and 304.
    static func length(rewritten: Int?, json: Bool, contentLength: Int64, contentEncoding: String?, status: Int) -> Int64? {
        if status == 204 || status == 304 { return nil }
        if let rewritten { return Int64(rewritten) }
        guard !json, contentLength >= 0, contentEncoding?.isEmpty ?? true else { return nil }
        return contentLength
    }

    /// The fixed stage and category of a failure, with the HTTP status and a numeric error code when known (Windows
    /// `DescribeFailure`): never a URL, the bridge's token, a header, a body or an error message.
    static func describe(stage: BridgeStage, failure: BridgeFailure, status: Int?) -> String {
        var line = "stage=" + stage.rawValue + "; category=" + category(of: failure)
        if let status { line += "; HTTP=" + String(status) }
        switch failure {
        case .upstream(let domain, let code):
            if domain == NSURLErrorDomain { line += "; url-error=" + String(code) }
            if domain == kCFErrorDomainCFNetwork as String { line += "; cfnetwork-error=" + String(code) }
            if domain == NSPOSIXErrorDomain, let name = GateDiagnostics.socketErrorNames[Int32(truncatingIfNeeded: code)] { line += "; socket=" + name }
        case .io(let code?), .socket(let code):
            if let name = GateDiagnostics.socketErrorNames[code] { line += "; socket=" + name }
        default:
            break
        }
        return line
    }

    static func category(of failure: BridgeFailure) -> String {
        switch failure {
        case .invalidData: return "invalid-data"
        case .timeout: return "timeout"
        case .canceled: return "cancelled"
        case .io: return "io"
        case .socket: return "socket"
        case .upstream: return "upstream-network"
        case .unexpected: return "unexpected"
        }
    }
}
