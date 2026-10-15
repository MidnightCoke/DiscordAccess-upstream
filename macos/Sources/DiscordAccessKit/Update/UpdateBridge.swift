import Darwin
import Foundation

/// The loopback endpoint Discord's own updater uses during a session (Windows `UpdateBridge`). Discord's native updater
/// ignores Chromium's proxy, so the session points its update settings here (`newEndpoint`, `legacyEndpoint`); every
/// request still leaves through the gate and the engine. Each connection goes through these steps in order:
/// 1. The process holding its client end must be admitted, as by the gate (`PeerAdmission`); a refused client gets 403.
/// 2. The request header (16 KiB at most, read within 10 seconds) must be a GET or HEAD whose path maps to a Discord
///    address under the bridge's random token (`BridgeRequest`).
/// 3. The request goes to that address through the gate, with fixed headers, and without following a redirect or keeping
///    or offering a cookie or credential.
/// 4. The response is passed on with its status, content type, length and location. Discord addresses in a JSON body and
///    in `Location` are rewritten to the bridge (`UpdateRewriter`); any other body streams through as it arrives, paced by
///    the client.
///
/// A request takes at most 180 seconds in all, a download included (as on Windows). At most 16 connections run at once,
/// each on its own thread. Failures go to `log` with fixed categories only (`BridgeResponse.describe`), within
/// `TraceBudget`. The bridge runs until `close()`.
public final class UpdateBridge {
    public static let maxConnections = 16
    static let headerTimeout: TimeInterval = 10
    static let requestTimeout: TimeInterval = 180
    /// URLSession's limit between two packets of a response (Windows `ReadWriteTimeout`).
    static let readTimeout: TimeInterval = 30

    public let port: UInt16
    let token: String
    private let proxyPort: UInt16
    private let admission: PeerAdmission
    private let log: ((String) -> Void)?
    private let faulted: (() -> Void)?
    private let headerTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let protocolClasses: [AnyClass]?
    private let budget = TraceBudget()
    private let listener: Int32
    private let stopRead: Int32
    private let lock = NSLock()
    /// Left when the accept thread has closed the listener.
    private let acceptEnded = DispatchGroup()
    /// Weak: the thread's block holds the bridge, so a strong reference would keep both alive for good.
    private weak var acceptThread: Thread?
    private var stopWrite: Int32
    private var active = 0
    private var requests: Set<URLSessionTask> = []
    private var started = false
    private var closed = false

    /// Listens on a free port of 127.0.0.1. Requests leave through the gate on 127.0.0.1:`proxyPort`, which must admit
    /// this process (its diagnostic permission, as for the connectivity checks). `log` and `faulted` are called from the
    /// bridge's threads, so they must be thread-safe and must not block. `faulted` reports that the bridge closed itself
    /// because accepting connections failed.
    public convenience init(proxyPort: UInt16, admission: PeerAdmission, log: ((String) -> Void)? = nil, faulted: (() -> Void)? = nil) throws {
        try self.init(proxyPort: proxyPort, admission: admission, log: log, faulted: faulted, headerTimeout: Self.headerTimeout,
                      requestTimeout: Self.requestTimeout, protocolClasses: nil)
    }

    /// Tests shorten the limits, and `protocolClasses` stand in for Discord's servers inside URLSession.
    init(proxyPort: UInt16, admission: PeerAdmission, log: ((String) -> Void)?, faulted: (() -> Void)?, headerTimeout: TimeInterval,
         requestTimeout: TimeInterval, protocolClasses: [AnyClass]?) throws {
        precondition(proxyPort > 0 && headerTimeout > 0 && requestTimeout > 0)
        let token = try Secrets.randomPathToken()
        let stop = try LoopbackSocket.stopPipe()
        let bound: (descriptor: Int32, port: UInt16)
        do {
            bound = try LoopbackSocket.listen(port: 0, backlog: Int32(Self.maxConnections))
        } catch {
            Darwin.close(stop.read)
            Darwin.close(stop.write)
            throw error
        }
        listener = bound.descriptor
        port = bound.port
        (stopRead, stopWrite) = stop
        self.token = token
        self.proxyPort = proxyPort
        self.admission = admission
        self.log = log
        self.faulted = faulted
        self.headerTimeout = headerTimeout
        self.requestTimeout = requestTimeout
        self.protocolClasses = protocolClasses
    }

    deinit {
        // A started bridge lives until its accept thread ends, which happens only after `close()`.
        if !closed {
            Darwin.close(listener)
            Darwin.close(stopWrite)
        }
        Darwin.close(stopRead)
    }

    /// `http://127.0.0.1:<port>/<token>`; every path of the bridge starts with this random token.
    public var baseURL: String { "http://127.0.0.1:" + String(port) + "/" + token }
    /// For Discord's `NEW_UPDATE_ENDPOINT` setting, the native updater.
    public var newEndpoint: String { baseURL + "/updates/" }
    /// For Discord's `UPDATE_ENDPOINT` setting, the old updater.
    public var legacyEndpoint: String { baseURL + "/legacy" }

    /// Connections being handled now.
    public var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Requests to Discord in flight now.
    var activeRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !closed else { return }
        started = true
        acceptEnded.enter()
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "DiscordAccess update bridge"
        acceptThread = thread
        thread.start()
    }

    /// Stops accepting, cancels the requests to Discord and ends every connection; calling it again changes nothing.
    /// When it returns the listener is closed (Windows `Dispose`); only when called from `faulted` on the accept thread
    /// does it return before that. It must not be called while holding a lock or queue that `log` waits for.
    public func close() {
        _ = markClosed()
        lock.lock()
        let pending = requests
        let thread = acceptThread
        lock.unlock()
        pending.forEach { $0.cancel() }
        if Thread.current !== thread { acceptEnded.wait() }
    }

    /// The URLSession settings of a request: the gate as the proxy for every scheme, no state kept, URLSession's own
    /// limits within the request's, and no proxy script.
    func configuration() -> URLSessionConfiguration {
        let configuration = ConnectivityProbe.configuration(proxyPort: proxyPort, deadline: requestTimeout)
        configuration.timeoutIntervalForRequest = min(Self.readTimeout, requestTimeout)
        configuration.timeoutIntervalForResource = requestTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    /// Marks the bridge closed and closes the write end of the stop pipe, which wakes every wait of the bridge; closes
    /// the listener too when no accept thread was started. False when the bridge was closed already.
    private func markClosed() -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        closed = true
        let write = stopWrite
        stopWrite = -1
        let ownsListener = !started
        lock.unlock()
        Darwin.close(write)
        if ownsListener { Darwin.close(listener) }
        return true
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func acceptLoop() {
        let failed = acceptConnections()
        let unexpected = failed && markClosed()
        if unexpected {
            lock.lock()
            let pending = requests
            lock.unlock()
            pending.forEach { $0.cancel() }
        }
        Darwin.close(listener)
        acceptEnded.leave()
        if unexpected { faulted?() }
    }

    /// Accepts connections until the bridge closes (false) or accepting fails (true). A connection over the limit is
    /// closed at once (Windows).
    private func acceptConnections() -> Bool {
        while true {
            var watched = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: stopRead, events: Int16(POLLIN), revents: 0)]
            if poll(&watched, 2, -1) < 0 {
                if errno == EINTR { continue }
                return true
            }
            if watched[1].revents != 0 { return false }
            guard watched[0].revents & Int16(POLLIN) != 0 else { return true }
            let accepted: (descriptor: Int32, peer: sockaddr_in)?
            do {
                accepted = try LoopbackSocket.accept(listener)
            } catch {
                return true
            }
            guard let (client, peer) = accepted else { continue }
            lock.lock()
            if closed || active >= Self.maxConnections {
                lock.unlock()
                Darwin.close(client)
                continue
            }
            active += 1
            lock.unlock()
            Thread { [self] in handle(client, peer: peer) }.start()
        }
    }

    private func handle(_ client: Int32, peer: sockaddr_in) {
        defer {
            Darwin.close(client)
            lock.lock()
            active -= 1
            lock.unlock()
        }
        let deadline = ContinuousClock.now + .seconds(requestTimeout)
        guard admitted(peer) else {
            if !isClosed { try? LoopbackSocket.write(client, BridgeResponse.forbidden, until: .now + .seconds(2), stop: stopRead) }
            return
        }
        var stage = BridgeStage.clientHeader
        do {
            guard let header = try Self.readHeader(client, until: min(deadline, .now + .seconds(headerTimeout)), stop: stopRead) else { return }
            stage = .clientRequest
            let request = try BridgeRequest.parse(header, port: port, token: token)
            stage = .upstreamResponse
            let outcome = try forward(request, client: client, deadline: deadline)
            if let failure = outcome.failure { report(failure, stage: outcome.stage, status: outcome.status, started: outcome.started, client: client) }
        } catch {
            report(Self.failure(error), stage: stage, status: nil, started: false, client: client)
        }
    }

    /// Whether the process holding the client's end is admitted. Only a peer at exactly 127.0.0.1 is matched.
    private func admitted(_ peer: sockaddr_in) -> Bool {
        guard let clientPort = LoopbackSocket.loopbackPeerPort(peer), admission.refusal(clientPort: clientPort, gatePort: port) == nil else { return false }
        // An admission can finish after `close()`; the bridge's own state decides.
        return !isClosed
    }

    private func forward(_ request: BridgeRequest, client: Int32, deadline: ContinuousClock.Instant) throws -> Forwarder.Outcome {
        let forwarder = try Forwarder(request: request, client: client, rewriter: UpdateRewriter(base: baseURL), deadline: deadline, stop: stopRead)
        let session = URLSession(configuration: configuration(), delegate: forwarder, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var upstream = URLRequest(url: request.target)
        upstream.httpMethod = request.method
        upstream.setValue("DiscordAccess/3", forHTTPHeaderField: "User-Agent")
        upstream.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        // URLSession would otherwise send the languages of this Mac.
        upstream.setValue("en", forHTTPHeaderField: "Accept-Language")
        let task = session.dataTask(with: upstream)
        lock.lock()
        guard !closed else {
            lock.unlock()
            return Forwarder.Outcome(failure: .canceled, stage: .upstreamResponse, status: nil, started: false)
        }
        requests.insert(task)
        lock.unlock()
        defer {
            lock.lock()
            requests.remove(task)
            lock.unlock()
        }
        task.resume()
        if forwarder.done.wait(timeout: Self.dispatchTime(deadline)) == .timedOut {
            forwarder.abandon()
            task.cancel()
            _ = forwarder.done.wait(timeout: .now() + 5)
        }
        return forwarder.outcome
    }

    /// Reports a failed request (unless the bridge closed) and answers it with 400 for a broken rule, otherwise 502, if
    /// no response had started (Windows).
    private func report(_ failure: BridgeFailure, stage: BridgeStage, status: Int?, started: Bool, client: Int32) {
        guard !isClosed else { return }
        if let log, budget.admit(failure: true) {
            log("Güncelleme köprüsü isteği tamamlanamadı: " + BridgeResponse.describe(stage: stage, failure: failure, status: status))
        }
        guard !started, let answer = try? BridgeResponse.header(status: failure == .invalidData ? 400 : 502, contentType: "text/plain", length: 0,
                                                                  location: nil) else { return }
        try? LoopbackSocket.write(client, answer, until: .now + .seconds(2), stop: stopRead)
    }

    /// The request header up to and including its empty line, or nil when the client closed without sending a byte: an
    /// unused preconnection is no failed request (Windows `ReadHeader`). Bytes after the header are refused, since a
    /// request has no body and is not pipelined; the header must be ASCII and at most 16 KiB.
    static func readHeader(_ descriptor: Int32, until deadline: ContinuousClock.Instant, stop: Int32) throws -> [UInt8]? {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1024)
        var scan = 0
        while bytes.count < BridgeRequest.maxHeaderBytes {
            do {
                try LoopbackSocket.wait(descriptor, for: Int16(POLLIN), until: deadline, stop: stop)
            } catch {
                throw failure(error)
            }
            let wanted = min(chunk.count, BridgeRequest.maxHeaderBytes - bytes.count)
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw BridgeFailure.io(errno)
            }
            if count == 0 {
                if bytes.isEmpty { return nil }
                throw BridgeFailure.io(nil)
            }
            bytes += chunk[0..<count]
            while scan + 3 < bytes.count {
                if bytes[scan] == 13 && bytes[scan + 1] == 10 && bytes[scan + 2] == 13 && bytes[scan + 3] == 10 {
                    guard scan + 4 == bytes.count, bytes.allSatisfy({ $0 <= 127 }) else { throw BridgeFailure.invalidData }
                    return bytes
                }
                scan += 1
            }
        }
        throw BridgeFailure.invalidData
    }

    static func failure(_ error: Error) -> BridgeFailure {
        if let failure = error as? BridgeFailure { return failure }
        if let failure = error as? GateFailure { return BridgeFailure(failure) }
        return .unexpected
    }

    private static func dispatchTime(_ deadline: ContinuousClock.Instant) -> DispatchTime {
        let (seconds, attoseconds) = max(.zero, deadline - .now).components
        return .now() + .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}

/// Forwards one request to Discord and passes the response on to the client (Windows `UpdateBridge.Handle` from the
/// upstream request on). URLSession calls it on one queue at a time, so writing to the client there paces the download.
/// It writes through its own duplicates of the connection and of the stop pipe, closed when URLSession releases it: a
/// callback that comes after the connection gave up never reaches a descriptor that was reused meanwhile.
private final class Forwarder: NSObject, URLSessionDataDelegate {
    static let jsonType = "application/json; charset=utf-8"

    struct Outcome {
        var failure: BridgeFailure?
        var stage: BridgeStage
        var status: Int?
        /// Whether the response header was being written: no error response may follow it.
        var started: Bool
    }

    let done = DispatchSemaphore(value: 0)
    private let request: BridgeRequest
    private let client: Int32
    private let rewriter: UpdateRewriter
    private let deadline: ContinuousClock.Instant
    private let stop: Int32
    private let lock = NSLock()
    private var state = Outcome(failure: nil, stage: .upstreamResponse, status: nil, started: false)
    private var abandoned = false
    // Used on URLSession's queue only.
    private var manifest: (status: Int, location: String?)?
    private var body = Data()
    private var streaming = false

    init(request: BridgeRequest, client: Int32, rewriter: UpdateRewriter, deadline: ContinuousClock.Instant, stop: Int32) throws {
        let ownClient = fcntl(client, F_DUPFD_CLOEXEC, 0)
        let ownStop = fcntl(stop, F_DUPFD_CLOEXEC, 0)
        guard ownClient >= 0, ownStop >= 0 else {
            let error = errno
            if ownClient >= 0 { Darwin.close(ownClient) }
            if ownStop >= 0 { Darwin.close(ownStop) }
            throw BridgeFailure.socket(error)
        }
        self.request = request
        self.client = ownClient
        self.rewriter = rewriter
        self.deadline = deadline
        self.stop = ownStop
    }

    deinit {
        Darwin.close(client)
        Darwin.close(stop)
    }

    var outcome: Outcome {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// The connection stops waiting, as the deadline passed: the request counts as timed out unless it had failed already,
    /// and a response that has not started may no longer start, so that it never mixes with the bridge's own answer.
    func abandon() {
        lock.lock()
        abandoned = true
        if state.failure == nil { state.failure = .timeout }
        lock.unlock()
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
        guard let http = response as? HTTPURLResponse else {
            record(.unexpected)
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode
        update { $0.status = status; $0.stage = .upstreamHeaders }
        do {
            let location = try rewriter.location(http.value(forHTTPHeaderField: "Location"), from: request.target)
            let noBody = request.method == "HEAD" || status == 204 || status == 304
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            let json = UpdateRewriter.isJSON(contentType)
            if json && !noBody {
                guard http.expectedContentLength <= Int64(UpdateRewriter.maxJSONBytes) else { throw BridgeFailure.invalidData }
                manifest = (status, location)
                update { $0.stage = .upstreamBody }
                completionHandler(.allow)
                return
            }
            let length = BridgeResponse.length(rewritten: nil, json: json, contentLength: http.expectedContentLength,
                                               contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding"), status: status)
            guard begin() else {
                completionHandler(.cancel)
                return
            }
            try write(BridgeResponse.header(status: status, contentType: json ? Self.jsonType : contentType, length: length, location: location))
            streaming = !noBody
            update { $0.stage = .upstreamBody }
            completionHandler(.allow)
        } catch {
            record(UpdateBridge.failure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard outcome.failure == nil else { return }
        if manifest != nil {
            body.append(data)
            guard body.count > UpdateRewriter.maxJSONBytes else { return }
            record(.invalidData)
            dataTask.cancel()
            return
        }
        guard streaming else { return }
        update { $0.stage = .clientResponseBody }
        do {
            try write([UInt8](data))
            update { $0.stage = .upstreamBody }
        } catch {
            record(UpdateBridge.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { done.signal() }
        if let error { record(.upstream(error)) }
        guard outcome.failure == nil, let manifest else { return }
        do {
            update { $0.stage = .manifestRewrite }
            let rewritten = try rewriter.rewrite(json: body)
            guard begin() else { return }
            try write(BridgeResponse.header(status: manifest.status, contentType: Self.jsonType, length: Int64(rewritten.count), location: manifest.location))
            update { $0.stage = .clientResponseBody }
            try write([UInt8](rewritten))
        } catch {
            record(UpdateBridge.failure(error))
        }
    }

    private func write(_ bytes: [UInt8]) throws {
        do {
            try LoopbackSocket.write(client, bytes, until: deadline, stop: stop)
        } catch {
            throw UpdateBridge.failure(error)
        }
    }

    /// Marks the response started, unless the request failed or the connection gave up.
    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !abandoned, state.failure == nil else { return false }
        state.started = true
        state.stage = .clientResponseHeader
        return true
    }

    /// Keeps the first failure.
    private func record(_ failure: BridgeFailure) {
        update { if $0.failure == nil { $0.failure = failure } }
    }

    private func update(_ change: (inout Outcome) -> Void) {
        lock.lock()
        change(&state)
        lock.unlock()
    }
}
