import Foundation

/// A cancellation signal shared by a DNS selection and its checks (Windows `CancellationToken`). Canceling runs each
/// registered handler once, on the canceling thread.
public final class Cancellation {
    private let lock = NSLock()
    private var canceled = false
    private var handlers: [Int: () -> Void] = [:]
    private var nextHandler = 0

    public init() {}

    public var isCanceled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceled
    }

    public func cancel() {
        lock.lock()
        guard !canceled else {
            lock.unlock()
            return
        }
        canceled = true
        let pending = handlers.values
        handlers.removeAll()
        lock.unlock()
        for handler in pending { handler() }
    }

    /// Throws `CancellationError` once canceled.
    public func check() throws {
        if isCanceled { throw CancellationError() }
    }

    /// Runs `handler` when this is canceled, at once when it already is; the returned function unregisters it.
    func whenCanceled(_ handler: @escaping () -> Void) -> () -> Void {
        lock.lock()
        guard !canceled else {
            lock.unlock()
            handler()
            return {}
        }
        let key = nextHandler
        nextHandler += 1
        handlers[key] = handler
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.handlers[key] = nil
            self.lock.unlock()
        }
    }
}
