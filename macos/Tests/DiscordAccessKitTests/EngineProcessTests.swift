import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Tests that count engine processes use their own copy of the engine, because `EngineConfigTests` runs `sing-box check`
/// children from `TestEngine.path` in parallel. Copies that are run stay under `build/test-engines` (`TestEngine.runnableCopy`).
@Suite(.serialized) struct EngineProcessTests {
    /// A copy that is never run, so it may be changed and deleted.
    static func copyOfEngine(in directory: TemporaryDirectory, named name: String = "sing-box") throws -> String {
        let path = directory.path + "/" + name
        try FileManager.default.copyItem(atPath: TestEngine.path, toPath: path)
        return path
    }

    static func processes(at path: String, parent: pid_t) -> [ProcessInspector.Record] {
        ProcessInspector.userProcessIDs().compactMap(ProcessInspector.record(for:)).filter { $0.parentPid == parent && $0.path == path }
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func startsOwnsItsListenerRequiresTheCredentialAndStops() throws {
        let engine = try EngineProcess.start(image: try EngineImage.verify(path: TestEngine.path), dns: DnsProvider(.cloudflareIP))
        #expect(engine.isRunning)
        #expect(ProcessInspector.ownsLoopbackListener(pid: engine.pid, port: engine.port))
        #expect(ProcessInspector.satisfies(pid: engine.pid, requirement: EngineIdentity.pinned.requirement))
        // example.com matches no route: with the credential the engine answers 200 and then rejects the tunnel,
        // so no traffic leaves the machine.
        let connect = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n"
        #expect(try exchange(port: engine.port, request: connect + "\r\n").hasPrefix("HTTP/1.1 407"))
        #expect(try exchange(port: engine.port, request: connect + "Proxy-Authorization: Basic dTpw\r\n\r\n").hasPrefix("HTTP/1.1 407"))
        #expect(try exchange(port: engine.port, request: connect + "Proxy-Authorization: " + engine.authorization + "\r\n\r\n")
            .hasPrefix("HTTP/1.1 200"))
        #expect(engine.stop())
        #expect(engine.stop())
        #expect(!engine.isRunning)
        #expect(throws: POSIXError(.ECONNREFUSED)) { try exchange(port: engine.port, request: "") }
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func refusesAnEngineOutsideTheCdhashPinBeforeItRuns() throws {
        let copy = try TestEngine.runnableCopy(named: "refused-sing-box")
        let wrong = EngineIdentity(sha256: EngineIdentity.pinned.sha256, cdhash: String(repeating: "0", count: 40))
        let image = try EngineImage.verify(path: copy, expected: wrong)
        #expect(throws: KitError.engineIntegrity(copy)) { try EngineProcess.start(image: image, dns: DnsProvider(.cloudflare)) }
        #expect(Self.processes(at: copy, parent: getpid()).isEmpty)
    }

    /// The file may change after it was verified; `start` measures it again and reports the package error.
    @Test(.enabled(if: TestEngine.isAvailable))
    func reportsAFileChangedAfterVerificationAsAPackageError() throws {
        let directory = try TemporaryDirectory()
        let copy = try Self.copyOfEngine(in: directory)
        let image = try EngineImage.verify(path: copy)
        try Data("not an engine".utf8).write(to: URL(fileURLWithPath: copy))
        #expect(throws: KitError.engineIntegrity(copy)) { try EngineProcess.start(image: image, dns: DnsProvider(.google)) }
        try FileManager.default.removeItem(atPath: copy)
        #expect(throws: KitError.engineMissing(copy)) { try EngineProcess.start(image: image, dns: DnsProvider(.google)) }
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func stopsAnEngineThatIsNotReadyInTime() throws {
        let copy = try TestEngine.runnableCopy(named: "not-ready-sing-box")
        let image = try EngineImage.verify(path: copy)
        #expect(throws: KitError.engineStartFailed()) { try EngineProcess.start(image: image, dns: DnsProvider(.google), readyTimeout: 0) }
        #expect(Self.processes(at: copy, parent: getpid()).isEmpty)
    }

    /// Uses the built engine, not a fresh copy: macOS scans a new executable on its first run, which can delay readiness.
    @Test(.enabled(if: TestEngine.isAvailable))
    func releasingTheRunStopsTheEngine() throws {
        var engine: EngineProcess? = try EngineProcess.start(image: try EngineImage.verify(path: TestEngine.path), dns: DnsProvider(.google))
        let pid = try #require(engine?.pid)
        #expect(ProcessInspector.record(for: pid)?.parentPid == getpid())
        engine = nil
        #expect(ProcessInspector.record(for: pid) == nil)
    }

    /// Uses copies of the engine: copies of Apple system binaries are killed outside system paths (launch constraints).
    /// A process of another user cannot be started without root, so the uid filter is not exercised here.
    @Test(.enabled(if: TestEngine.isAvailable))
    func terminatesOnlyLaunchdAdoptedCopiesOfTheEnginePath() throws {
        let directory = try TemporaryDirectory()
        let fakeEngine = try TestEngine.runnableCopy(named: "orphan-sing-box")
        let otherEngine = try TestEngine.runnableCopy(named: "other-sing-box")
        let emptyConfig = directory.path + "/empty.json"
        try Data("{\"log\":{\"disabled\":true}}".utf8).write(to: URL(fileURLWithPath: emptyConfig))
        let child = try startChild(fakeEngine, ["run", "-c", emptyConfig])
        defer {
            child.terminate()
            child.waitUntilExit()
            // Nothing is left behind even if an expectation below fails.
            for leftover in Self.processes(at: fakeEngine, parent: 1) + Self.processes(at: otherEngine, parent: 1) { kill(leftover.pid, SIGKILL) }
        }
        for engine in [fakeEngine, otherEngine] {
            let launcher = try startChild("/bin/sh", ["-c", "\"$0\" run -c \"$1\" >/dev/null 2>&1 &", engine, emptyConfig])
            launcher.waitUntilExit()
        }
        let orphan = try #require(waitFor { Self.processes(at: fakeEngine, parent: 1).first })
        let other = try #require(waitFor { Self.processes(at: otherEngine, parent: 1).first })
        #expect(EngineProcess.terminateOrphans(enginePath: fakeEngine) == [orphan.pid])
        #expect(waitFor { ProcessInspector.record(for: orphan.pid) == orphan ? nil : true } == true)
        #expect(child.isRunning)
        #expect(ProcessInspector.record(for: other.pid) == other)
    }
}
