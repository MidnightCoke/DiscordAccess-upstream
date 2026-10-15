import Foundation

/// The result of a lifecycle request, known once and given to everyone who asks (Windows `Task`).
public final class LifecycleRequest<Value> {
    private let lock = NSLock()
    private let done = DispatchGroup()
    private var outcome: Result<Value, Error>?
    private var observers: [(queue: DispatchQueue, handler: (Result<Value, Error>) -> Void)] = []

    init() {
        done.enter()
    }

    static func failed(_ error: Error) -> LifecycleRequest {
        let request = LifecycleRequest()
        request.complete(.failure(error))
        return request
    }

    /// The result, once known.
    public var result: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    /// Runs `handler` with the result on `queue`, always asynchronously, so a handler may make new requests.
    public func observe(on queue: DispatchQueue = .main, _ handler: @escaping (Result<Value, Error>) -> Void) {
        lock.lock()
        guard let outcome else {
            observers.append((queue, handler))
            lock.unlock()
            return
        }
        lock.unlock()
        queue.async { handler(outcome) }
    }

    /// Whether the result was known by `deadline`.
    public func wait(until deadline: Date) -> Bool {
        done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success
    }

    /// Waits for the result and returns or throws it.
    func get() throws -> Value {
        done.wait()
        return try result!.get()
    }

    /// The first result counts.
    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = observers
        observers = []
        lock.unlock()
        done.leave()
        for observer in waiting { observer.queue.async { observer.handler(result) } }
    }
}

/// The menu bar app's session (Windows `BackgroundLifecycle`), apart from the app's interface: no window, preference or
/// process list is used here. Requests while connecting share one preparation, and opens requested meanwhile share one
/// open that follows it, so Discord is never opened twice because a second click arrived. A login launch opens Discord at
/// most once, after the connection is ready and only if Discord is not running. Shutdown disconnects within a bounded
/// time, and the lifecycle then accepts nothing more; reconnecting takes a new lifecycle once this one has shut down.
public final class ResidentLifecycle {
    public struct Operations {
        public var connect: () throws -> Void
        public var disconnect: () throws -> Void
        public var openDiscord: () throws -> String
        /// Whether the session is active; it must not wait for an operation under way.
        public var ready: () -> Bool
        /// Whether Discord runs; an observation that failed must count as running.
        public var running: () -> Bool

        public init(connect: @escaping () throws -> Void, disconnect: @escaping () throws -> Void, openDiscord: @escaping () throws -> String,
                    ready: @escaping () -> Bool, running: @escaping () -> Bool) {
            self.connect = connect
            self.disconnect = disconnect
            self.openDiscord = openDiscord
            self.ready = ready
            self.running = running
        }

        /// The operations of `controller`.
        public init(_ controller: SessionController) {
            self.init(connect: controller.connect, disconnect: controller.disconnect, openDiscord: controller.openDiscord,
                      ready: { controller.isActive }, running: controller.discordRunning)
        }
    }

    public static let shutdownLimit: TimeInterval = 15

    private let lock = NSLock()
    private let operations: Operations
    private let changed: (Bool, String) -> Void
    private var prepared: LifecycleRequest<Void>?
    private var connected: LifecycleRequest<Void>?
    private var opening: LifecycleRequest<String>?
    private var stopped: LifecycleRequest<Bool>?
    private var ready = false
    private var stopping = false
    private var startupRequested = false
    private var startupConsumed = false

    /// `changed` gets the lifecycle's own state messages, from its threads.
    public init(operations: Operations, changed: @escaping (Bool, String) -> Void = { _, _ in }) {
        self.operations = operations
        self.changed = changed
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready && !stopping && operations.ready()
    }

    public var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    /// Connects, or joins the connection under way. A `startup` request (a login launch) is kept even when it joins a
    /// manual preparation, and opens Discord once the connection is ready; ordinary preparation never opens Discord.
    @discardableResult
    public func connect(startup: Bool = false) -> LifecycleRequest<Void> {
        lock.lock()
        guard !stopping else {
            lock.unlock()
            return .failed(CancellationError())
        }
        if startup { startupRequested = true }
        let start = prepareLocked()
        let result = connected!
        var lateStartup = false
        if !start, ready, case .success? = result.result { lateStartup = startupRequested && !startupConsumed }
        lock.unlock()
        if start { Self.background(connectCore) }
        guard lateStartup else { return result }
        let late = LifecycleRequest<Void>()
        Self.background { late.complete(Result { try self.launchStartup() }) }
        return late
    }

    /// Opens Discord once the connection is ready, connecting first if needed; requests while one runs share it.
    public func open() -> LifecycleRequest<String> {
        lock.lock()
        guard !stopping else {
            lock.unlock()
            return .failed(CancellationError())
        }
        if let opening {
            lock.unlock()
            return opening
        }
        let start = prepareLocked()
        let request = LifecycleRequest<String>()
        opening = request
        let preparation = prepared!
        lock.unlock()
        if start { Self.background(connectCore) }
        Self.background { self.openCore(request, after: preparation) }
        return request
    }

    /// Disconnects and waits for the connection and an open under way to end, all within `timeout` (15 seconds at most).
    /// True when everything ended in time; false when the time ran out; the disconnection's failure otherwise. Asking
    /// again returns the same request.
    @discardableResult
    public func shutdown(timeout: TimeInterval = shutdownLimit) -> LifecycleRequest<Bool> {
        lock.lock()
        if let stopped {
            lock.unlock()
            return stopped
        }
        stopping = true
        ready = false
        let completion = LifecycleRequest<Bool>()
        stopped = completion
        let connection = connected
        let open = opening
        lock.unlock()
        let deadline = Date().addingTimeInterval(min(max(timeout, 0), Self.shutdownLimit))
        Self.background { self.shutdownCore(completion, connection: connection, open: open, deadline: deadline) }
        return completion
    }

    /// Must be called with `lock` held.
    private func prepareLocked() -> Bool {
        guard connected == nil else { return false }
        prepared = LifecycleRequest()
        connected = LifecycleRequest()
        return true
    }

    private func connectCore() {
        lock.lock()
        let prepared = self.prepared!
        let connected = self.connected!
        lock.unlock()
        do {
            changed(false, "Connecting...")
            try checkRunning()
            // Disconnecting cancels a connection under way before it waits for it (`SessionController.disconnect`).
            try operations.connect()
            lock.lock()
            guard !stopping else {
                lock.unlock()
                throw CancellationError()
            }
            guard operations.ready() else {
                lock.unlock()
                throw KitError.sessionNotReady()
            }
            ready = true
            lock.unlock()
            prepared.complete(.success(()))
            changed(true, "Connection ready.")
            try launchStartup()
            connected.complete(.success(()))
        } catch {
            prepared.complete(.failure(error))
            lock.lock()
            let active = ready && !stopping
            lock.unlock()
            changed(active, active ? "Connection ready; Discord could not be opened." : "Could not connect.")
            connected.complete(.failure(error))
        }
    }

    /// Throws once the lifecycle is stopping.
    private func checkRunning() throws {
        lock.lock()
        defer { lock.unlock() }
        if stopping { throw CancellationError() }
    }

    /// The login launch's open, at most once.
    private func launchStartup() throws {
        lock.lock()
        guard !stopping, ready, startupRequested, !startupConsumed else {
            lock.unlock()
            return
        }
        startupConsumed = true
        // An observation that failed counts as running and must not open Discord.
        let running = operations.running()
        lock.unlock()
        if running { return }
        _ = try open().get()
    }

    private func openCore(_ request: LifecycleRequest<String>, after preparation: LifecycleRequest<Void>) {
        let result = Result { () throws -> String in
            try preparation.get()
            lock.lock()
            guard !stopping else {
                lock.unlock()
                throw CancellationError()
            }
            guard ready, operations.ready() else {
                lock.unlock()
                throw KitError.sessionNotReady()
            }
            // A click joining a login launch's preparation fulfils the same intent.
            if startupRequested { startupConsumed = true }
            let running = operations.running()
            lock.unlock()
            return running ? "Discord is already open." : try operations.openDiscord()
        }
        // The request completes before its slot clears, so no second open can start in between.
        lock.lock()
        request.complete(result)
        if opening === request { opening = nil }
        lock.unlock()
    }

    private func shutdownCore(_ completion: LifecycleRequest<Bool>, connection: LifecycleRequest<Void>?, open: LifecycleRequest<String>?, deadline: Date) {
        let disconnecting = LifecycleRequest<Void>()
        Self.background { disconnecting.complete(Result { try self.operations.disconnect() }) }
        guard disconnecting.wait(until: deadline) else {
            completion.complete(.success(false))
            return
        }
        var failure: Error?
        if case .failure(let error)? = disconnecting.result { failure = error }
        // A connection or open canceled by disconnecting, or the connection's own failure, does not matter here.
        guard connection?.wait(until: deadline) ?? true, open?.wait(until: deadline) ?? true else {
            completion.complete(.success(false))
            return
        }
        changed(false, failure == nil ? "Connection closed." : "The recovery record was kept; Discord's settings could not be fully restored.")
        completion.complete(failure.map { .failure($0) } ?? .success(true))
    }

    private static func background(_ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = "DiscordAccess lifecycle"
        thread.start()
    }
}

/// The menu bar app's preferences in the private state folder (`preferences.json`, 0600): whether the user chose to start
/// at login (nil until they or the first working connection did, as Windows records it) and whether Discord opens too
/// then (off by default). A missing file reads as the defaults; one that exists but cannot be read safely reads as a
/// refusal to start at login, so the app never registers itself while the user's choice is unknown.
public struct ResidentPreferences: Equatable {
    static let limit = 4096

    public var startAtLogin: Bool?
    public var openDiscordAtLogin = false

    public init(startAtLogin: Bool? = nil, openDiscordAtLogin: Bool = false) {
        self.startAtLogin = startAtLogin
        self.openDiscordAtLogin = openDiscordAtLogin
    }

    public static func load(state: String = StateStore.standardRoot) -> ResidentPreferences {
        let path = state + "/preferences.json"
        var status = stat()
        guard lstat(path, &status) == 0 || errno != ENOENT else { return ResidentPreferences() }
        guard (try? SafeFile.ensurePrivateDirectory(state, create: false)) != nil, let bytes = try? SafeFile.read(path, limit: limit),
              let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return ResidentPreferences(startAtLogin: false) }
        return ResidentPreferences(startAtLogin: object["startAtLogin"] as? Bool, openDiscordAtLogin: object["openDiscordAtLogin"] as? Bool ?? false)
    }

    /// Replaces the file as this call reads it, or creates it; one that changes before the swap is not overwritten
    /// (PRF-E01).
    public func save(state: String = StateStore.standardRoot) throws {
        try SafeFile.ensurePrivateDirectory(state, create: true)
        let path = state + "/preferences.json"
        let current = try SafeFile.read(path, limit: Self.limit)
        var object: [String: Any] = ["openDiscordAtLogin": openDiscordAtLogin]
        if let startAtLogin { object["startAtLogin"] = startAtLogin }
        let bytes = Array(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        try SafeFile.replace(path, expected: current, with: bytes, limit: Self.limit, mode: 0o600)
    }
}
