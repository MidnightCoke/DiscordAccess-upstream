import Foundation

/// Why the Gateway WebSocket check failed (Windows `GatewayProbeException`): whether the connection had opened, and a
/// fixed reason. The message holds nothing from the peer.
public struct GatewayHelloFailure: Error, Equatable, CustomStringConvertible {
    public enum Reason: String, Sendable {
        case timeout = "TIMEOUT"
        case response = "RESPONSE"
        case webSocket = "WEBSOCKET"
        case transport = "TRANSPORT"
        case canceled = "CANCELLED"
        case failed = "FAILED"
    }

    /// Whether the WebSocket connection had opened: `[WS-HELLO-…]` then, `[WS-CONNECT-…]` before.
    public let opened: Bool
    public let reason: Reason

    public var message: String {
        "[WS-" + (opened ? "HELLO" : "CONNECT") + "-" + reason.rawValue + "] The Gateway WebSocket check did not finish. A working HTTP API does not prove " +
            "the live message connection."
    }

    public var description: String { message }
}

/// The anonymous Gateway WebSocket check through the loopback proxy (Windows `GatewayChecks`): it connects to Discord's
/// Gateway, reads only the public HELLO and closes normally. It never sends IDENTIFY, a token or account data. Like
/// `ConnectivityProbe`, it goes only through the proxy and ends within 10 seconds.
public enum GatewayHello {
    static let url = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    static let maxHelloBytes = 16384
    static let deadline: TimeInterval = 10

    /// Returns the summary to show; throws `GatewayHelloFailure`, or `CancellationError` once `cancel` is canceled.
    public static func check(proxyPort: UInt16, cancel: Cancellation = Cancellation()) throws -> String {
        try check(url: url, proxyPort: proxyPort, cancel: cancel)
        return "[WS-OK] The Gateway WebSocket connection and the HELLO reply were verified through the proxy. This check does not " +
            "verify the account session, sending messages, or voice and screen sharing."
    }

    static func check(url: URL, proxyPort: UInt16, cancel: Cancellation, deadline: TimeInterval = deadline) throws {
        try cancel.check()
        let observer = SocketObserver()
        let session = URLSession(configuration: ConnectivityProbe.configuration(proxyPort: proxyPort, deadline: deadline), delegate: observer,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        ConnectivityProbe.setFixedHeaders(&request)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maxHelloBytes
        let unregister = cancel.whenCanceled { task.cancel() }
        defer { unregister() }
        task.resume()
        task.receive { observer.received($0) }
        let expired = observer.done.wait(timeout: .now() + deadline) == .timedOut
        if expired {
            task.cancel()
            _ = observer.done.wait(timeout: .now() + 5)
        }
        try cancel.check()
        let (opened, outcome) = observer.result
        if expired { throw GatewayHelloFailure(opened: opened, reason: .timeout) }
        switch outcome {
        case .success(.string(let text))?:
            guard valid(hello: text) else { throw GatewayHelloFailure(opened: true, reason: .response) }
        case .success?:
            throw GatewayHelloFailure(opened: true, reason: .response)
        case .failure(let error)?:
            // Whether the peer closed is known for certain once the task has completed.
            _ = observer.completed.wait(timeout: .now() + 1)
            throw GatewayHelloFailure(opened: opened, reason: reason(for: error, closedByPeer: observer.peerClosed || task.closeCode != .invalid))
        case nil:
            throw GatewayHelloFailure(opened: opened, reason: .failed)
        }
        // A completed check closes normally: a reset tunnel would look like a failed Gateway connection in the log.
        // Waiting for the close is bounded and best effort.
        task.cancel(with: .normalClosure, reason: Data("diagnostic complete".utf8))
        _ = observer.completed.wait(timeout: .now() + 1)
    }

    /// `{"op": 10, "d": {"heartbeat_interval": 1...300000}}` with integers only (Windows `ValidateHello`).
    static func valid(hello text: String) -> Bool {
        guard text.utf8.count <= maxHelloBytes, let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              integer(payload["op"]) == 10, let data = payload["d"] as? [String: Any],
              let interval = integer(data["heartbeat_interval"]), (1...300_000).contains(interval) else { return false }
        return true
    }

    /// Windows `FailureCategory`: a closing peer, a message over the limit or of the wrong kind is a response failure;
    /// a refused handshake is a WebSocket failure; the proxy, the connection or TLS failing is a transport failure.
    static func reason(for error: Error, closedByPeer: Bool) -> GatewayHelloFailure.Reason {
        if closedByPeer { return .response }
        let failure = error as NSError
        let cfNetwork = failure.domain == NSURLErrorDomain || failure.domain == kCFErrorDomainCFNetwork as String
        if cfNetwork && [306, 310, 311].contains(failure.code) { return .transport }
        if failure.domain == NSPOSIXErrorDomain { return failure.code == Int(EMSGSIZE) ? .response : .transport }
        guard failure.domain == NSURLErrorDomain else { return .failed }
        switch URLError.Code(rawValue: failure.code) {
        case .timedOut: return .timeout
        case .cancelled: return .canceled
        case .badServerResponse: return .webSocket
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .transport
        default: return .failed
        }
    }

    /// A JSON integer: not a Boolean, and without a fraction or exponent.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return nil }
        return number.intValue
    }
}

/// Watches one WebSocket task for `GatewayHello`; a redirect is not followed.
private final class SocketObserver: NSObject, URLSessionWebSocketDelegate {
    let done = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false
    private var closed = false
    private var outcome: Result<URLSessionWebSocketTask.Message, Error>?

    var result: (opened: Bool, outcome: Result<URLSessionWebSocketTask.Message, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        return (opened, outcome)
    }

    /// Whether the WebSocket closing handshake took place.
    var peerClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func received(_ outcome: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
        done.signal()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        opened = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(ConnectivityProbe.answer(challenge), nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completed.signal()
    }
}
