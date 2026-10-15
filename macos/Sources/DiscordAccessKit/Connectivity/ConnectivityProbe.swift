import Foundation

/// HTTPS checks through the session's loopback proxy (Windows `ConnectivityChecks`). A request goes only through
/// 127.0.0.1:`proxyPort`: no system proxy, no proxy script and no direct connection, even when the proxy refuses. It
/// follows no redirect, keeps no cookie, cache or credential and offers none, sends only fixed header values, reads at
/// most 16 KiB of a body and has a 10-second deadline. The proxy must admit this process (the gate's diagnostic
/// permission). Nothing in the system, the account or Discord changes.
public enum ConnectivityProbe {
    static let deadline: TimeInterval = 10
    static let maxResponseBytes = 16384
    static let gatewayURL = URL(string: "https://discord.com/api/v10/gateway")!
    static let updatesURL = URL(string: "https://updates.discord.com/")!

    /// Discord's Gateway API answers with its Gateway address (Windows `CheckDnsCandidate`). Throws
    /// `ConnectivityFailure`, or `CancellationError` once `cancel` is canceled.
    public static func checkGateway(proxyPort: UInt16, cancel: Cancellation = Cancellation()) throws {
        try checkGateway(url: gatewayURL, proxyPort: proxyPort, cancel: cancel)
    }

    /// The Gateway API and the update server both answer (Windows `Check`); returns the summary to show.
    public static func check(proxyPort: UInt16, cancel: Cancellation = Cancellation()) throws -> String {
        try check(gateway: gatewayURL, updates: updatesURL, proxyPort: proxyPort, cancel: cancel)
        return "HTTPS access to the Discord API and the update server was verified through the proxy. Desktop updates, account " +
            "sign-in and voice chat must be checked separately."
    }

    static func check(gateway: URL, updates: URL, proxyPort: UInt16, cancel: Cancellation, deadline: TimeInterval = deadline) throws {
        try checkGateway(url: gateway, proxyPort: proxyPort, cancel: cancel, deadline: deadline)
        let (response, _, _) = try fetch(updates, method: "HEAD", proxyPort: proxyPort, endpoint: .updates, cancel: cancel, deadline: deadline,
                                         readsBody: { _ in false })
        // The root is no documented manifest: 404 or 405 proves HTTPS reachability, not a completed desktop update.
        guard acceptsUpdateStatus(response.statusCode) else { throw statusFailure(.updates, response) }
    }

    static func checkGateway(url: URL, proxyPort: UInt16, cancel: Cancellation, deadline: TimeInterval = deadline) throws {
        // Windows reads the body only for a 200: any other status counts as it arrives, so a 429 stays a 429 whether
        // its page is long, cut off or slow.
        let (response, body, truncated) = try fetch(url, method: "GET", proxyPort: proxyPort, endpoint: .gateway, cancel: cancel, deadline: deadline,
                                                    readsBody: { $0.statusCode == 200 })
        guard response.statusCode == 200 else { throw statusFailure(.gateway, response) }
        guard !truncated else { throw ConnectivityFailure(endpoint: .gateway, reason: .responseTooLarge) }
        try validateGateway(body)
    }

    /// The response of one request, its body and whether the body was cut off at the limit; the caller judges the status.
    /// The body of a response for which `readsBody` is false is not read: the request ends with the response head. A
    /// failed request and the deadline throw `ConnectivityFailure`; a canceled `cancel` throws `CancellationError`.
    static func fetch(_ url: URL, method: String, proxyPort: UInt16, endpoint: ConnectivityFailure.Endpoint, cancel: Cancellation,
                      deadline: TimeInterval = deadline, readsBody: @escaping (HTTPURLResponse) -> Bool)
        throws -> (response: HTTPURLResponse, body: Data, truncated: Bool) {
        try cancel.check()
        let collector = ResponseCollector(limit: maxResponseBytes, readsBody: readsBody)
        let session = URLSession(configuration: configuration(proxyPort: proxyPort, deadline: deadline), delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        setFixedHeaders(&request)
        let task = session.dataTask(with: request)
        let unregister = cancel.whenCanceled { task.cancel() }
        defer { unregister() }
        task.resume()
        // The check's own deadline bounds the whole response, also against a peer that sends slowly.
        let expired = collector.done.wait(timeout: .now() + deadline) == .timedOut
        if expired {
            task.cancel()
            _ = collector.done.wait(timeout: .now() + 5)
        }
        try cancel.check()
        let result = collector.result
        // A response that completed only as the deadline passed does not count either (Windows).
        if expired { throw ConnectivityFailure(endpoint: endpoint, reason: .timeout) }
        // A response read without its body, or whose body went over the limit, ended the task; it still stands.
        if result.headOnly || result.tooLarge, let response = result.response { return (response, result.body, result.tooLarge) }
        if let error = result.error { throw ConnectivityFailure.from(error, endpoint: endpoint, expired: false) }
        guard let response = result.response else { throw ConnectivityFailure(endpoint: endpoint, reason: .invalidResponse) }
        return (response, result.body, false)
    }

    /// Header values that do not depend on this Mac: URLSession would otherwise send the user's languages and its own
    /// agent string. Windows sends neither.
    static func setFixedHeaders(_ request: inout URLRequest) {
        request.setValue("DiscordAccess/3 (connectivity check)", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    /// Server trust gets the system's own evaluation; no credential of any kind is offered, so an authentication request
    /// is answered as it is (`URLSession` would otherwise try the system's single sign-on).
    static func answer(_ challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .rejectProtectionSpace
    }

    /// One proxy for every scheme, URLSession's own timeouts behind the check's deadline, and no state kept.
    static func configuration(proxyPort: UInt16, deadline: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort), kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: Int(proxyPort),
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
        ]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = deadline + 5
        configuration.timeoutIntervalForResource = deadline + 5
        return configuration
    }

    /// `{"url": "wss://gateway.discord.gg"}`, the address on port 443 with no user information or fragment (Windows
    /// `ValidateGateway`).
    static func validateGateway(_ body: Data) throws {
        guard body.count <= maxResponseBytes, let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = payload["url"] as? String, let address = URLComponents(string: text), address.scheme?.lowercased() == "wss",
              address.host?.lowercased() == "gateway.discord.gg", address.port == nil || address.port == 443,
              address.user == nil, address.password == nil, address.fragment == nil else {
            throw ConnectivityFailure(endpoint: .gateway, reason: .invalidResponse)
        }
    }

    static func acceptsUpdateStatus(_ status: Int) -> Bool {
        (200...299).contains(status) || status == 404 || status == 405
    }

    static func statusFailure(_ endpoint: ConnectivityFailure.Endpoint, _ response: HTTPURLResponse) -> ConnectivityFailure {
        ConnectivityFailure(endpoint: endpoint, reason: .http, httpStatus: response.statusCode,
                            responseKind: ConnectivityFailure.responseKind(contentType: response.value(forHTTPHeaderField: "Content-Type")))
    }
}

/// Collects one response for `ConnectivityProbe.fetch`; a redirect is answered as it is, a body is read only when
/// `readsBody` says so, and it may not exceed `limit` bytes.
private final class ResponseCollector: NSObject, URLSessionDataDelegate {
    let done = DispatchSemaphore(value: 0)
    private let limit: Int
    private let readsBody: (HTTPURLResponse) -> Bool
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var body = Data()
    private var error: Error?
    private var headOnly = false
    private var tooLarge = false

    init(limit: Int, readsBody: @escaping (HTTPURLResponse) -> Bool) {
        self.limit = limit
        self.readsBody = readsBody
    }

    var result: (response: HTTPURLResponse?, body: Data, error: Error?, headOnly: Bool, tooLarge: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (response, body, error, headOnly, tooLarge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(ConnectivityProbe.answer(challenge), nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let headOnly = http.map { !readsBody($0) } ?? false
        let over = !headOnly && response.expectedContentLength > Int64(limit)
        lock.lock()
        self.response = http
        self.headOnly = headOnly
        if over { tooLarge = true }
        lock.unlock()
        completionHandler(headOnly || over ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        body.append(data)
        let over = body.count > limit
        if over { tooLarge = true }
        lock.unlock()
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
        done.signal()
    }
}
