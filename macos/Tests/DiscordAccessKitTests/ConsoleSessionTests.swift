import Foundation
import Testing
@testable import DiscordAccessKit

/// The terminal session with stand-in operations (Windows `ConsoleHost.RunOfflineChecks`): no engine, Discord or network.
@Suite struct ConsoleSessionTests {
    typealias Collected = ProxyGateTests.Collected

    final class Counter {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func add(_ name: String) {
            lock.lock()
            counts[name, default: 0] += 1
            lock.unlock()
        }

        subscript(_ name: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[name, default: 0]
        }
    }

    struct PrivateFailure: Error, CustomStringConvertible {
        var description: String { "SYNTHETIC_PRIVATE_PATH" }
    }

    /// Operations that count their calls; each closure may be replaced.
    static func operations(_ state: ConsoleSession.State, _ counter: Counter) -> ConsoleSession.Operations {
        ConsoleSession.Operations(
            connect: {
                counter.add("connect")
                state.stateChanged(true)
            },
            readyMessage: { "Bağlantı hazır." },
            openDiscord: {
                counter.add("open")
                return "opened-fixture"
            },
            diagnose: {
                counter.add("diagnose")
                return "diagnosis-fixture"
            },
            download: { _ in
                counter.add("download")
                return "/fixture/sample.txt"
            },
            disconnect: { counter.add("disconnect") })
    }

    /// Runs the session; `react` sees each shown line and may type the next command.
    static func run(_ session: ConsoleSession.Operations, _ state: ConsoleSession.State, timeout: TimeInterval = 2,
                    react: @escaping (String) -> Void = { _ in }) -> (code: Int32, lines: [String]) {
        let lines = Collected<String>()
        let code = ConsoleSession.run(session, state: state, show: { line in
            lines.append(line)
            react(line)
        }, shutdownTimeout: timeout)
        return (code, lines.all)
    }

    @Test func connectingDoesNotOpenDiscordWithoutA() {
        let state = ConsoleSession.State()
        let counter = Counter()
        let result = Self.run(Self.operations(state, counter), state) { if $0 == "Bağlantı hazır." { state.command("Q") } }
        #expect(result.code == 0 && counter["open"] == 0 && counter["disconnect"] == 1)
        #expect(result.lines == ["Bağlantı hazır.", "Bağlantı kapatıldı."])
    }

    @Test func anATypedWhileConnectingOpensDiscordOnceReady() {
        let state = ConsoleSession.State()
        let counter = Counter()
        var session = Self.operations(state, counter)
        let ready = Collected<Bool>()
        session.connect = {
            counter.add("connect")
            state.stateChanged(true)
            ready.append(true)
        }
        session.openDiscord = {
            #expect(ready.all == [true] && counter["disconnect"] == 0)
            counter.add("open")
            return "opened-fixture"
        }
        state.command("A")
        let result = Self.run(session, state) { line in
            if line == "opened-fixture" { state.command(counter["open"] == 1 ? "a" : "Q") }
        }
        #expect(result.code == 0 && counter["connect"] == 1 && counter["open"] == 2 && counter["disconnect"] == 1)
    }

    @Test func aFailedOpenKeepsTheSessionAndShowsNoPrivateText() {
        let state = ConsoleSession.State()
        let counter = Counter()
        var session = Self.operations(state, counter)
        session.connect = {
            state.stateChanged(true)
            state.command("A")
        }
        session.openDiscord = {
            counter.add("open")
            if counter["open"] == 1 {
                state.command("A")
                throw PrivateFailure()
            }
            return "opened-fixture"
        }
        let result = Self.run(session, state) { if $0 == "opened-fixture" { state.command("Q") } }
        #expect(result.code == 0 && counter["open"] == 2 && counter["disconnect"] == 1)
        #expect(result.lines.contains("Discord açılamadı: İşlem tamamlanamadı (PrivateFailure)."))
        #expect(result.lines.allSatisfy { !$0.contains("SYNTHETIC_PRIVATE_PATH") })
    }

    @Test func anAWhileTheLinkIsAwaitedOpensDiscordAndTheNextLineIsTheLink() {
        let state = ConsoleSession.State()
        let counter = Counter()
        var session = Self.operations(state, counter)
        let links = Collected<String>()
        session.connect = {
            state.stateChanged(true)
            state.command("D")
            state.command("A")
            state.command("  fixture-link  ")
        }
        session.download = { link in
            links.append(link)
            return "/fixture/folder/sample.txt"
        }
        let result = Self.run(session, state) { if $0.hasPrefix("Kaydedildi:") { state.command("Q") } }
        #expect(result.code == 0 && counter["open"] == 1 && links.all == ["fixture-link"])
        #expect(result.lines.contains("Discord ek dosyasının bağlantısını yapıştırıp Enter'a basın. Q: kapat."))
        #expect(result.lines.contains("Kaydedildi: sample.txt | /fixture/folder"))
    }

    @Test func aFailedDownloadShowsItsFixedMessage() {
        let state = ConsoleSession.State()
        var session = Self.operations(state, Counter())
        session.download = { _ in throw AttachmentDownloadFailure(message: AttachmentDownloader.invalidLink) }
        state.command("d")
        state.command("not-a-link")
        let result = Self.run(session, state) { if $0.hasPrefix("Dosya indirilemedi:") { state.command("q") } }
        #expect(result.code == 0 && result.lines.contains("Dosya indirilemedi: " + AttachmentDownloader.invalidLink))
    }

    @Test func aClosedInputEndsTheLinkPrompt() {
        let state = ConsoleSession.State()
        let session = Self.operations(state, Counter())
        state.command("D")
        state.command(nil)
        let result = Self.run(session, state) { if $0 == "Dosya bağlantısı alınamadı; komut girişi kapalı." { state.requestStop(0) } }
        #expect(result.code == 0 && state.inputClosed)
    }

    @Test func qWaitsForAPendingOpenToBeCleanedUp() {
        let state = ConsoleSession.State()
        var session = Self.operations(state, Counter())
        let release = DispatchSemaphore(value: 0)
        let cleaned = Collected<Bool>()
        session.connect = {
            state.stateChanged(true)
            state.command("A")
        }
        session.openDiscord = {
            state.command("Q")
            release.wait()
            cleaned.append(true)
            throw CancellationError()
        }
        session.disconnect = {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { release.signal() }
        }
        let result = Self.run(session, state)
        #expect(result.code == 0 && cleaned.all == [true] && result.lines.last == "Bağlantı kapatıldı.")
    }

    @Test func aPendingOpenCannotHoldShutdownBeyondItsTime() {
        let state = ConsoleSession.State()
        var session = Self.operations(state, Counter())
        let release = DispatchSemaphore(value: 0)
        session.connect = {
            state.stateChanged(true)
            state.command("A")
        }
        session.openDiscord = {
            state.command("Q")
            release.wait()
            return ""
        }
        let started = Date()
        let result = Self.run(session, state, timeout: 0.05)
        release.signal()
        #expect(result.code == 130 && Date().timeIntervalSince(started) < 1)
        #expect(result.lines.contains("Discord açılışının kapanış süresi doldu.") && !result.lines.contains("Bağlantı kapatıldı."))
    }

    @Test func aDisconnectThatHangsEndsWithTheTimeoutCode() {
        let state = ConsoleSession.State()
        var session = Self.operations(state, Counter())
        let release = DispatchSemaphore(value: 0)
        session.disconnect = { release.wait() }
        state.command("Q")
        let result = Self.run(session, state, timeout: 0.05)
        release.signal()
        #expect(result.code == 130 && result.lines.contains("Kapanış süresi doldu; bağlantı motoru program kapanırken durdurulacak."))
    }

    @Test func aDownloadEndedByDisconnectingIsCleanedUpQuietly() {
        let state = ConsoleSession.State()
        var session = Self.operations(state, Counter())
        let release = DispatchSemaphore(value: 0)
        session.connect = {
            state.stateChanged(true)
            state.command("D")
            state.command("fixture-link")
        }
        session.download = { _ in
            state.command("Q")
            release.wait()
            throw CancellationError()
        }
        session.disconnect = { release.signal() }
        let result = Self.run(session, state)
        #expect(result.code == 0 && !result.lines.contains { $0.hasPrefix("İndirme temizliği") })

        let failing = ConsoleSession.State()
        var other = Self.operations(failing, Counter())
        let next = DispatchSemaphore(value: 0)
        other.connect = {
            failing.stateChanged(true)
            failing.command("D")
            failing.command("fixture-link")
        }
        other.download = { _ in
            failing.command("Q")
            next.wait()
            throw AttachmentDownloadFailure(message: "Dosya kaydedilemedi. İndirilenler klasörüne erişimi kontrol edin.")
        }
        other.disconnect = { next.signal() }
        let cleanup = Self.run(other, failing)
        #expect(cleanup.code == 1 && cleanup.lines.contains("İndirme temizliği: Dosya kaydedilemedi. İndirilenler klasörüne erişimi kontrol edin."))
    }

    @Test func tShowsTheDiagnosisAndAnythingElseTheHelp() {
        let state = ConsoleSession.State()
        let counter = Counter()
        var session = Self.operations(state, counter)
        session.connect = {
            state.stateChanged(true)
            state.command("x")
            state.command("T")
        }
        let failing = Collected<Bool>()
        session.diagnose = {
            counter.add("diagnose")
            if counter["diagnose"] == 2 {
                failing.append(true)
                throw ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 503)
            }
            return "diagnosis-fixture"
        }
        let result = Self.run(session, state) { line in
            if line == "diagnosis-fixture" { state.command("t") }
            if line.hasPrefix("Tanılama tamamlanamadı:") { state.command("Q") }
        }
        #expect(result.code == 0 && result.lines.first == "Bağlantı hazır." && result.lines[1] == ConsoleSession.help)
        #expect(result.lines.contains("diagnosis-fixture") && failing.all == [true])
        #expect(result.lines.contains("Tanılama tamamlanamadı: " + ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 503).message))
    }

    @Test func aFailedConnectionIsReportedAndStillDisconnected() {
        let state = ConsoleSession.State()
        let counter = Counter()
        var session = Self.operations(state, counter)
        session.connect = { throw KitError.discordRunning() }
        let result = Self.run(session, state)
        #expect(result.code == 1 && counter["disconnect"] == 1)
        #expect(result.lines == ["Bağlantı kurulamadı: " + KitError.discordRunning().description, "Bağlantı kapatıldı."])
    }

    @Test func anInterruptWhileConnectingStopsWithItsCode() {
        let state = ConsoleSession.State()
        let counter = Counter()
        var session = Self.operations(state, counter)
        let canceled = DispatchSemaphore(value: 0)
        session.connect = {
            state.requestStop(130)
            canceled.wait()
            throw CancellationError()
        }
        session.disconnect = {
            counter.add("disconnect")
            canceled.signal()
        }
        let result = Self.run(session, state)
        #expect(result.code == 130 && counter["disconnect"] == 1 && result.lines == ["Bağlantı kapatıldı."])
    }

    @Test func theConnectionEndingEndsTheSession() {
        let state = ConsoleSession.State()
        let counter = Counter()
        var session = Self.operations(state, counter)
        session.connect = {
            state.stateChanged(true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { state.stateChanged(false) }
        }
        let result = Self.run(session, state)
        #expect(result.code == 0 && state.ended && counter["disconnect"] == 1)
    }

    @Test func aDeferredRestoreIsReported() {
        let state = ConsoleSession.State()
        var session = Self.operations(state, Counter())
        session.disconnect = { throw KitError.sessionRestoreDeferred() }
        state.command("Q")
        let result = Self.run(session, state)
        #expect(result.code == 1 && result.lines == ["Oturum temizliği: " + KitError.sessionRestoreDeferred().description, "Bağlantı kapatıldı."])
    }

    @Test func commandsAreTrimmedBoundedAndStopAfterQ() {
        let state = ConsoleSession.State()
        state.command("   ")
        state.command(String(repeating: "x", count: ConsoleSession.maxCommandLength + 1))
        state.command(" t ")
        #expect(state.nextCommand() == "t" && state.nextCommand() == nil)
        for index in 0..<(ConsoleSession.maxQueued + 5) { state.command("c" + String(index)) }
        var queued: [String] = []
        while let command = state.nextCommand() { queued.append(command) }
        #expect(queued.count == ConsoleSession.maxQueued && queued.first == "c0")
        for word in ["çıkış", "ÇIKIŞ", "cikis", "Q"] {
            let stopping = ConsoleSession.State()
            stopping.command(word)
            stopping.command("A")
            #expect(stopping.stopRequested && stopping.exitCode == 0 && stopping.nextCommand() == nil)
        }
        let interrupted = ConsoleSession.State()
        interrupted.requestStop(130)
        interrupted.requestStop(0)
        #expect(interrupted.exitCode == 130)
        let ended = ConsoleSession.State()
        ended.stateChanged(false)
        #expect(!ended.ended)
        ended.stateChanged(true)
        ended.stateChanged(false)
        ended.command("A")
        #expect(ended.ended && ended.nextCommand() == nil)
    }

    /// Lines are read at most 32 KiB far; a longer one is dropped, and a last line without a newline still counts.
    @Test func readsBoundedLines() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        let input = Array("a\r\nçıkış\n".utf8) + [UInt8](repeating: 120, count: 40_000) + Array("\nb\n\nc".utf8)
        let writer = Thread {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = write(ends[1], buffer.baseAddress! + offset, buffer.count - offset)
                    guard count > 0 else { break }
                    offset += count
                }
            }
            close(ends[1])
        }
        writer.start()
        var lines: [String?] = []
        ConsoleProgram.readLines(from: ends[0]) { line in
            lines.append(line)
            return true
        }
        close(ends[0])
        #expect(lines == ["a", "çıkış", "b", "", "c", nil])

        try #require(pipe(&ends) == 0)
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        #expect(write(ends[1], "q\nnot read\n", 11) == 11)
        var first: [String?] = []
        ConsoleProgram.readLines(from: ends[0]) { line in
            first.append(line)
            return false
        }
        close(ends[0])
        close(ends[1])
        #expect(first == ["q"])
    }

    @Test func failuresShowFixedText() {
        #expect(ConsoleSession.message(KitError.engineStopped()) == "[ENG-E02] Bağlantı motoru durdu.")
        #expect(ConsoleSession.message(CancellationError()) == "İşlem iptal edildi.")
        #expect(ConsoleSession.message(AttachmentDownloadFailure(message: "fixed")) == "fixed")
        #expect(ConsoleSession.message(GatewayHelloFailure(opened: false, reason: .timeout)) == GatewayHelloFailure(opened: false, reason: .timeout).message)
        #expect(ConsoleSession.message(PrivateFailure()) == "İşlem tamamlanamadı (PrivateFailure).")
        // Foundation's errors show as NSError: their kind, never their text.
        #expect(ConsoleSession.message(CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/private/secret"])) == "İşlem tamamlanamadı (NSError).")
    }
}
