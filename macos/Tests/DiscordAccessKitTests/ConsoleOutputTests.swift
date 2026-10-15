import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The terminal's output queues and the session's log file and lock.
@Suite struct ConsoleOutputTests {
    typealias Collected = ProxyGateTests.Collected

    @Test func showsOneCleanLine() {
        #expect(ConsoleOutput.clean("  a\tb\r\nc\u{7}  ") == "a b  c")
        #expect(ConsoleOutput.clean("evil\u{202E}txt.exe") == "evil txt.exe")
        #expect(ConsoleOutput.clean("x\u{2066}y\u{200F}z") == "x y z")
        #expect(ConsoleOutput.clean("café 🙂") == "café 🙂")
        let long = String(repeating: "a", count: 1001)
        #expect(ConsoleOutput.clean(long) == String(repeating: "a", count: 1000) + "…")
        #expect(ConsoleOutput.clean(String(repeating: "a", count: 1000)) == String(repeating: "a", count: 1000))
    }

    /// A screen that does not take its lines holds up neither the producer nor the file log, and what it missed is counted.
    @Test func aBlockedScreenHoldsUpNothing() {
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let files = Collected<String>()
        let screen = Collected<String>()
        let output = ConsoleOutput(file: files.append, screen: { line in
            if line == "first" {
                entered.signal()
                release.wait()
            }
            screen.append(line)
        })
        output.show("first")
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let started = Date()
        for index in 0..<100 { output.show("line " + String(index)) }
        output.file("file only")
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(waitFor { files.all.count == 102 ? true : nil } == true && files.all.last == "file only")
        release.signal()
        #expect(waitFor { screen.all.count == 34 ? true : nil } == true)
        #expect(screen.all.first == "first" && screen.all[1] == "Skipped 68 diagnostic lines because of heavy logging." && screen.all[2] == "line 0")
        #expect(!screen.all.contains("file only"))
        output.close()
    }

    /// Closing writes what is queued, and gives up on a write that never returns.
    @Test func closingFinishesTheQueueWithinItsTime() {
        let files = Collected<String>()
        let never = DispatchSemaphore(value: 0)
        let output = ConsoleOutput(file: files.append, screen: { _ in never.wait() })
        for index in 0..<10 { output.file(String(index)) }
        output.show("blocked")
        let started = Date()
        output.close()
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(files.all == (0..<10).map(String.init) + ["blocked"])
        output.show("after")
        usleep(100_000)
        #expect(files.all.count == 11)
        never.signal()
    }

    @Test func logsPrivatelyAndStartsAnewWhenFull() throws {
        let directory = try TemporaryDirectory()
        let state = directory.path + "/DiscordAccess"
        let log = try SessionLog(state: state)
        log.write("Connection ready.")
        var status = stat()
        #expect(lstat(log.path, &status) == 0 && status.st_mode & 0o777 == 0o600 && lstat(state, &status) == 0 && status.st_mode & 0o777 == 0o700)
        let text = try #require(SafeFileTests.text(log.path))
        #expect(text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  Connection ready\.\n\z"#, options: .regularExpression) != nil)
        try SafeFileTests.write(log.path, String(repeating: "x", count: Int(SessionLog.limit)), mode: 0o600)
        log.write("yeni")
        #expect(SafeFileTests.text(log.path)?.hasSuffix("  yeni\n") == true && (SafeFileTests.text(log.path)?.count ?? 0) < 64)
        // A link in its place is not followed, and nothing is written through it.
        unlink(log.path)
        try SafeFileTests.write(directory.path + "/other", "other")
        try FileManager.default.createSymbolicLink(atPath: log.path, withDestinationPath: directory.path + "/other")
        log.write("link")
        #expect(SafeFileTests.text(directory.path + "/other") == "other")
        // A state folder others can enter is refused.
        try FileManager.default.createDirectory(atPath: directory.path + "/open", withIntermediateDirectories: false)
        chmod(directory.path + "/open", 0o755)
        #expect(throws: KitError.profileConflict()) { try SessionLog(state: directory.path + "/open") }
    }

    @Test func holdsOneSessionAtATime() throws {
        let directory = try TemporaryDirectory()
        let state = directory.path + "/DiscordAccess"
        var first = try SessionLock.acquire(state: state)
        #expect(first != nil)
        #expect(try SessionLock.acquire(state: state) == nil)
        first = nil
        // A process another test is spawning holds a copy of every descriptor for a moment, until its exec closes them.
        let second = waitFor { try? SessionLock.acquire(state: state) }
        #expect(second != nil)
        withExtendedLifetime(second) {}
        try FileManager.default.createDirectory(atPath: directory.path + "/shared", withIntermediateDirectories: false)
        chmod(directory.path + "/shared", 0o755)
        #expect(throws: KitError.profileConflict()) { try SessionLock.acquire(state: directory.path + "/shared") }
    }
}
