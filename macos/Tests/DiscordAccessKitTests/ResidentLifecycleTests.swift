import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The menu bar app's session with stand-in operations (Windows `BackgroundLifecycle.RunOfflineChecks`): no engine,
/// Discord or network.
@Suite struct ResidentLifecycleTests {
    /// Counters and flags the stand-in operations share with the test, from any thread.
    final class Fixture {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        private var activeValue = false

        var active: Bool {
            get { lock.lock(); defer { lock.unlock() }; return activeValue }
            set { lock.lock(); activeValue = newValue; lock.unlock() }
        }

        func add(_ name: String) {
            lock.lock()
            values[name, default: 0] += 1
            lock.unlock()
        }

        subscript(_ name: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return values[name, default: 0]
        }
    }

    struct FixtureFailure: Error, Equatable {}

    /// Operations that connect at once and count their calls; each closure may be replaced.
    static func operations(_ fixture: Fixture, running: Bool = false) -> ResidentLifecycle.Operations {
        ResidentLifecycle.Operations(
            connect: { fixture.active = true },
            disconnect: {
                fixture.active = false
                fixture.add("disconnect")
            },
            openDiscord: {
                fixture.add("open")
                return "opened"
            },
            ready: { fixture.active },
            running: { running })
    }

    static func value<Value>(_ request: LifecycleRequest<Value>) throws -> Value {
        try #require(request.wait(until: Date().addingTimeInterval(5)), "The request did not complete.")
        return try request.result!.get()
    }

    static func canceled<Value>(_ request: LifecycleRequest<Value>) -> Bool {
        guard request.wait(until: Date().addingTimeInterval(5)), case .failure(let error)? = request.result else { return false }
        return error is CancellationError
    }

    @Test func aManualSessionNeverOpensDiscordAndShutsDownOnce() throws {
        let fixture = Fixture()
        let manual = ResidentLifecycle(operations: Self.operations(fixture))
        try Self.value(manual.connect())
        #expect(manual.isReady && fixture["open"] == 0)
        let stopping = manual.shutdown()
        #expect(try Self.value(stopping) && fixture["disconnect"] == 1 && !manual.isReady && manual.isStopping)
        #expect(manual.shutdown() === stopping && fixture["disconnect"] == 1)
        #expect(Self.canceled(manual.open()) && Self.canceled(manual.connect(startup: true)))
    }

    @Test func clicksWhileConnectingShareOneOpenThatFollowsTheConnection() throws {
        let fixture = Fixture()
        let entered = DispatchSemaphore(value: 0)
        let prepared = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        var operations = Self.operations(fixture)
        operations.connect = {
            entered.signal()
            prepared.wait()
        }
        operations.openDiscord = {
            fixture.add("open")
            released.wait()
            return "opened"
        }
        let deferred = ResidentLifecycle(operations: operations)
        let connection = deferred.connect()
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let first = deferred.open()
        #expect(deferred.open() === first && fixture["open"] == 0)
        fixture.active = true
        prepared.signal()
        #expect(waitFor { fixture["open"] == 1 ? true : nil } == true)
        #expect(deferred.open() === first && fixture["open"] == 1)
        released.signal()
        #expect(try Self.value(first) == "opened")
        try Self.value(connection)
        #expect(try Self.value(deferred.shutdown()))
    }

    @Test func aLoginLaunchOpensDiscordOnceWhenReady() throws {
        let fixture = Fixture()
        var operations = Self.operations(fixture)
        operations.openDiscord = {
            #expect(fixture.active)
            fixture.add("open")
            return "opened"
        }
        let startup = ResidentLifecycle(operations: operations)
        try Self.value(startup.connect(startup: true))
        try Self.value(startup.connect(startup: true))
        #expect(fixture["open"] == 1)
        #expect(try Self.value(startup.shutdown()))
    }

    @Test func aLoginLaunchJoiningAManualConnectionAndAClickOpenOnce() throws {
        let fixture = Fixture()
        let entered = DispatchSemaphore(value: 0)
        let prepared = DispatchSemaphore(value: 0)
        var operations = Self.operations(fixture)
        operations.connect = {
            entered.signal()
            prepared.wait()
        }
        let merged = ResidentLifecycle(operations: operations)
        let first = merged.connect()
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let joining = merged.connect(startup: true)
        let click = merged.open()
        #expect(first === joining && fixture["open"] == 0)
        fixture.active = true
        prepared.signal()
        try Self.value(joining)
        _ = try Self.value(click)
        #expect(fixture["open"] == 1)
        #expect(try Self.value(merged.shutdown()))
    }

    @Test func aLateLoginLaunchOpensOnce() throws {
        let fixture = Fixture()
        let late = ResidentLifecycle(operations: Self.operations(fixture))
        try Self.value(late.connect())
        try Self.value(late.connect(startup: true))
        try Self.value(late.connect(startup: true))
        #expect(fixture["open"] == 1)
        #expect(try Self.value(late.shutdown()))
    }

    @Test func aRunningDiscordIsNotOpenedAgain() throws {
        let fixture = Fixture()
        let existing = ResidentLifecycle(operations: Self.operations(fixture, running: true))
        try Self.value(existing.connect(startup: true))
        #expect(try Self.value(existing.open()) == "Discord is already open." && fixture["open"] == 0)
        #expect(try Self.value(existing.shutdown()))
    }

    @Test func aFailedConnectionOpensNothing() throws {
        let fixture = Fixture()
        var operations = Self.operations(fixture)
        operations.connect = { throw FixtureFailure() }
        let messages = ProxyGateTests.Collected<String>()
        let failed = ResidentLifecycle(operations: operations, changed: { _, message in messages.append(message) })
        #expect(throws: FixtureFailure.self) { try Self.value(failed.connect(startup: true)) }
        #expect(fixture["open"] == 0 && !failed.isReady)
        #expect(throws: FixtureFailure.self) { try Self.value(failed.open()) }
        #expect(try Self.value(failed.shutdown()) && fixture["disconnect"] == 1)
        #expect(messages.all == ["Connecting...", "Could not connect.", "Connection closed."])
    }

    /// Disconnecting cancels a connection under way (as `SessionController.disconnect` does); everything waiting ends.
    @Test func shutdownEndsAConnectionUnderWay() throws {
        let fixture = Fixture()
        let entered = DispatchSemaphore(value: 0)
        let canceled = DispatchSemaphore(value: 0)
        var operations = Self.operations(fixture)
        operations.connect = {
            entered.signal()
            canceled.wait()
            throw CancellationError()
        }
        operations.ready = { true }
        operations.disconnect = {
            fixture.add("disconnect")
            canceled.signal()
        }
        let lifecycle = ResidentLifecycle(operations: operations)
        let connection = lifecycle.connect(startup: true)
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let queued = lifecycle.open()
        #expect(try Self.value(lifecycle.shutdown()) && fixture["disconnect"] == 1 && fixture["open"] == 0)
        #expect(connection.result != nil && queued.result != nil)
        #expect(Self.canceled(queued))
    }

    @Test func shutdownWaitsForAnOpenUnderWay() throws {
        let fixture = Fixture()
        let entered = DispatchSemaphore(value: 0)
        let canceled = DispatchSemaphore(value: 0)
        var operations = Self.operations(fixture)
        operations.openDiscord = {
            entered.signal()
            canceled.wait()
            throw CancellationError()
        }
        operations.disconnect = { canceled.signal() }
        let lifecycle = ResidentLifecycle(operations: operations)
        try Self.value(lifecycle.connect())
        let inFlight = lifecycle.open()
        #expect(entered.wait(timeout: .now() + 5) == .success)
        #expect(try Self.value(lifecycle.shutdown()) && Self.canceled(inFlight))
    }

    @Test func aCleanupFailureIsReported() throws {
        let fixture = Fixture()
        var operations = Self.operations(fixture)
        operations.disconnect = { throw KitError.sessionRestoreDeferred() }
        let messages = ProxyGateTests.Collected<String>()
        let conflicted = ResidentLifecycle(operations: operations, changed: { _, message in messages.append(message) })
        try Self.value(conflicted.connect())
        #expect(throws: KitError.sessionRestoreDeferred()) { try Self.value(conflicted.shutdown()) }
        #expect(conflicted.isStopping && messages.all.last == "The recovery record was kept; Discord's settings could not be fully restored.")
    }

    @Test func aHangingDisconnectEndsWithinItsTime() throws {
        let fixture = Fixture()
        let hung = DispatchSemaphore(value: 0)
        var operations = Self.operations(fixture)
        operations.disconnect = { hung.wait() }
        let bounded = ResidentLifecycle(operations: operations)
        try Self.value(bounded.connect())
        let started = Date()
        #expect(try !Self.value(bounded.shutdown(timeout: 0.03)) && Date().timeIntervalSince(started) < 2)
        hung.signal()
    }

    @Test func aRequestHasOneResultForEveryObserver() throws {
        let request = LifecycleRequest<Int>()
        let seen = ProxyGateTests.Collected<Int>()
        let queue = DispatchQueue(label: "observer")
        request.observe(on: queue) { if case .success(let value) = $0 { seen.append(value) } }
        request.complete(.success(1))
        request.complete(.success(2))
        request.observe(on: queue) { if case .success(let value) = $0 { seen.append(value) } }
        #expect(waitFor { seen.all.count == 2 ? seen.all : nil } == [1, 1])
        #expect(try request.get() == 1 && request.wait(until: Date()))
    }

    @Test func keepsPreferencesPrivately() throws {
        let directory = try TemporaryDirectory()
        let state = directory.path + "/DiscordAccess"
        #expect(ResidentPreferences.load(state: state) == ResidentPreferences())
        try ResidentPreferences(openDiscordAtLogin: true).save(state: state)
        #expect(ResidentPreferences.load(state: state).openDiscordAtLogin)
        var status = stat()
        #expect(lstat(state + "/preferences.json", &status) == 0 && status.st_mode & 0o777 == 0o600)
        try ResidentPreferences(openDiscordAtLogin: false).save(state: state)
        #expect(!ResidentPreferences.load(state: state).openDiscordAtLogin)
        // A link in its place is neither read nor written through, and an unreadable file never lets the app register itself.
        unlink(state + "/preferences.json")
        try SafeFileTests.write(directory.path + "/other.json", "{\"openDiscordAtLogin\":true}")
        try FileManager.default.createSymbolicLink(atPath: state + "/preferences.json", withDestinationPath: directory.path + "/other.json")
        #expect(ResidentPreferences.load(state: state) == ResidentPreferences(startAtLogin: false))
        #expect(throws: KitError.profileConflict()) { try ResidentPreferences(openDiscordAtLogin: true).save(state: state) }
        #expect(SafeFileTests.text(directory.path + "/other.json") == "{\"openDiscordAtLogin\":true}")
        try FileManager.default.createDirectory(atPath: directory.path + "/open", withIntermediateDirectories: false)
        chmod(directory.path + "/open", 0o755)
        try SafeFileTests.write(directory.path + "/open/preferences.json", "{\"openDiscordAtLogin\":true}", mode: 0o600)
        #expect(ResidentPreferences.load(state: directory.path + "/open") == ResidentPreferences(startAtLogin: false))
        try SafeFileTests.write(directory.path + "/open/preferences.json", "not json", mode: 0o600)
        chmod(directory.path + "/open", 0o700)
        #expect(ResidentPreferences.load(state: directory.path + "/open") == ResidentPreferences(startAtLogin: false))
        #expect(ResidentPreferences.load(state: directory.path + "/missing") == ResidentPreferences())
    }
}
