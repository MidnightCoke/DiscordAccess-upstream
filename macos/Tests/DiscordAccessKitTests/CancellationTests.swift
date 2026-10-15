import Foundation
import Testing
@testable import DiscordAccessKit

@Suite struct CancellationTests {
    final class Counter {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test func throwsOnlyOnceCanceled() throws {
        let cancel = Cancellation()
        #expect(!cancel.isCanceled)
        try cancel.check()
        cancel.cancel()
        cancel.cancel()
        #expect(cancel.isCanceled)
        #expect(throws: CancellationError.self) { try cancel.check() }
    }

    @Test func runsEachRegisteredHandlerOnce() {
        let cancel = Cancellation()
        let kept = Counter(), removed = Counter(), late = Counter()
        _ = cancel.whenCanceled { kept.increment() }
        let unregister = cancel.whenCanceled { removed.increment() }
        unregister()
        // A handler may cancel again without deadlocking.
        _ = cancel.whenCanceled { cancel.cancel() }
        cancel.cancel()
        cancel.cancel()
        #expect(kept.count == 1 && removed.count == 0)
        // Registered after the cancellation: runs at once.
        _ = cancel.whenCanceled { late.increment() }
        #expect(late.count == 1)
    }

    @Test func runsAHandlerOnceWhenCanceledFromManyThreads() {
        let cancel = Cancellation()
        let calls = Counter()
        _ = cancel.whenCanceled { calls.increment() }
        DispatchQueue.concurrentPerform(iterations: 32) { _ in cancel.cancel() }
        #expect(calls.count == 1)
    }
}
