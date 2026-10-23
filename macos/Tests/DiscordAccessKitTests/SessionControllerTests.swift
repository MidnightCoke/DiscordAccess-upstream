import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The session end to end with the real engine, gate and bridge, a stand-in Discord.app and a stand-in profile. The DNS
/// provider is named, so no connectivity check runs and nothing goes to the network; Discord is never started, and the
/// user's own Discord profile is never touched.
@Suite struct SessionControllerTests {
    typealias Collected = ProxyGateTests.Collected
    static let hook = TestEngine.packageRoot.deletingLastPathComponent().appendingPathComponent("bridge/attachment-download.cjs").path

    /// Whether the stand-in Discord runs, as the session reads it; changed by the test from any thread.
    final class Discord {
        private let lock = NSLock()
        private var answers: [Bool] = []
        private var current = false
        let launches = Collected<[String]>()
        /// The versions asked to quit.
        let quits = Collected<String>()

        /// Later reads return `running`.
        func set(_ running: Bool) {
            lock.lock()
            current = running
            lock.unlock()
        }

        /// The next reads return `answers` in order, then the current value.
        func answer(_ answers: [Bool]) {
            lock.lock()
            self.answers = answers
            lock.unlock()
        }

        func read() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return answers.isEmpty ? current : answers.removeFirst()
        }
    }

    final class Session {
        let fixture: DiscordProfileChangesTests.Fixture
        var installation: DiscordInstallation
        let discord = Discord()
        let lines = Collected<String>()
        let states = Collected<String>()
        var hook = SessionControllerTests.hook
        var onRunning: (() -> Void)?
        var onLocate: (() -> Void)?
        var locateFailure: Error?
        /// Whether the stand-in Discord quits when asked.
        var quitEnds = true
        /// The main processes of the stand-in bundle, when they differ from whether any Discord runs.
        var mainProcesses: (() -> [pid_t])?
        static let updated = "0.0.418"
        static let core = "/modules/discord_desktop_core-1/discord_desktop_core/"

        init() throws {
            fixture = try DiscordProfileChangesTests.Fixture()
            // A Discord.app laid out as the gate expects: each approved executable exists.
            let bundle = fixture.directory.path + "/Discord.app"
            for executable in DiscordApplication.approvedExecutables(bundle: bundle) {
                try FileManager.default.createDirectory(atPath: (executable.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try SafeFileTests.write(executable.path, "", mode: 0o755)
            }
            installation = DiscordInstallation(bundle: bundle, version: DiscordProfileChangesTests.version)
        }

        func controller() -> SessionController {
            let settings = SessionController.Settings(engine: TestEngine.path, hook: hook, dns: DnsOptions(provider: .google), profile: fixture.profile,
                                                      state: fixture.state, downloads: fixture.directory.path + "/downloads")
            let system = SessionController.System(
                locate: { [unowned self] _ in
                    onLocate?()
                    if let locateFailure { throw locateFailure }
                    return installation
                },
                running: { [weak self] _ in
                    self?.onRunning?()
                    return self?.discord.read() ?? false
                },
                launch: { [discord] _, arguments in discord.launches.append(arguments) },
                anyRunning: { [discord] in discord.read() },
                mainProcesses: { [unowned self] _ in mainProcesses?() ?? (discord.read() ? [1] : []) },
                quit: { [unowned self] installation in
                    discord.quits.append(installation.version)
                    if quitEnds { discord.set(false) }
                })
            let controller = SessionController(settings: settings, system: system, log: lines.append, changed: { [states] _, message in states.append(message) })
            controller.updateWaits = (verify: 2, relaunch: 0.5, quit: 0.5)
            return controller
        }

        var updatedEntry: String { fixture.profile + "/app-" + Self.updated + Self.core + "index.js" }

        /// Discord updates itself in place: a new version's folder with its own entry, the old one removed unless `keepOld`.
        func update(keepOld: Bool) throws {
            if !keepOld { try FileManager.default.removeItem(atPath: fixture.profile + "/app-" + DiscordProfileChangesTests.version) }
            let folder = (updatedEntry as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try SafeFileTests.write(updatedEntry, DiscordProfileChangesTests.official)
            try SafeFileTests.write(folder + "/core.asar", "archive")
            installation = DiscordInstallation(bundle: installation.bundle, version: Self.updated)
        }

        /// ShipIt installs the host update: a new bundle takes the old one's place in one step.
        func swapBundle() throws {
            let bundle = installation.bundle
            let incoming = bundle + ".incoming-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: incoming, withIntermediateDirectories: false)
            guard renamex_np(incoming, bundle, UInt32(RENAME_SWAP)) == 0 else { throw lastPOSIXError() }
        }

        /// Discord's own entries and settings are as they were before the session.
        var untouched: Bool {
            let settings = try? fixture.settings()
            return SafeFileTests.text(fixture.entry(1)) == DiscordProfileChangesTests.official &&
                SafeFileTests.text(fixture.entry(2)) == DiscordProfileChangesTests.official &&
                settings?["UPDATE_ENDPOINT"] as? String == "https://updates.discord.com/" && settings?["NEW_UPDATE_ENDPOINT"] == nil &&
                SafeFileTests.text(fixture.journal) == nil && fixture.leftovers.isEmpty
        }
    }

    /// Whether the process `pid` is gone (reaped, as the session's engine must be).
    static func gone(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return waitFor { kill(pid, 0) == -1 && errno == ESRCH ? true : nil } == true
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func connectsChangesTheProfileAndUndoesItOnDisconnect() throws {
        let session = try Session()
        let controller = session.controller()
        try controller.connect()
        let pid = try #require(controller.enginePID)
        #expect(kill(pid, 0) == 0)
        let wrapper = try #require(SafeFileTests.text(session.fixture.entry(1)))
        let port = try #require(wrapper.firstMatch(of: #/const proxy = "http://127\.0\.0\.1:([0-9]+)";/#)).output.1
        #expect(wrapper.hasPrefix(SessionWrapper.marker) && SafeFileTests.text(session.fixture.entry(2)) == wrapper)
        let settings = try session.fixture.settings()
        let legacy = try #require(settings["UPDATE_ENDPOINT"] as? String)
        let modern = try #require(settings["NEW_UPDATE_ENDPOINT"] as? String)
        #expect(legacy.hasPrefix("http://127.0.0.1:") && legacy.hasSuffix("/legacy") && modern == String(legacy.dropLast("legacy".count)) + "updates/")
        #expect(!legacy.contains(":" + port + "/") && settings["BACKGROUND_COLOR"] as? String == "#202225")
        #expect(session.states.all == ["Connecting", "Connection ready; Discord can be opened from its own icon."] && controller.isActive)
        #expect(!controller.discordRunning())
        #expect(session.lines.all.contains("DNS: " + DnsOptions(provider: .google).description))

        #expect(try controller.openDiscord() == "Sent the request to open the official Discord.")
        #expect(session.discord.launches.all == [["--proxy-server=http://127.0.0.1:" + port, "--proxy-bypass-list=127.0.0.1;localhost", "--disable-quic"]])
        session.discord.set(true)
        #expect(try controller.openDiscord() == "Discord is already open; it was not opened again.")
        #expect(session.discord.launches.all.count == 1)
        #expect(throws: AttachmentDownloadFailure(message: AttachmentDownloader.invalidLink)) { try controller.download("https://example.com/file") }

        session.discord.set(false)
        try controller.disconnect()
        #expect(session.untouched && Self.gone(pid) && controller.enginePID == nil && !controller.isActive && !controller.hasUnreapedEngine)
        #expect(session.states.all.last == "Disconnected")
        #expect(throws: KitError.sessionNotReady()) { try controller.openDiscord() }
        #expect(try controller.diagnose() == "The connection is not open.")
        #expect(throws: AttachmentDownloadFailure(message: "Open the connection with DiscordAccess before downloading a file.")) { try controller.download(Self.hook) }
        try controller.disconnect()
    }

    /// Discord's signature check before an open can take seconds; disconnecting does not wait for it, and Discord is not
    /// opened for a session that ended meanwhile.
    @Test(.enabled(if: TestEngine.isAvailable))
    func anOpenDoesNotHoldUpDisconnecting() throws {
        let session = try Session()
        let controller = session.controller()
        try controller.connect()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        session.onLocate = {
            entered.signal()
            release.wait()
        }
        let opened = Collected<Result<String, Error>>()
        Thread { opened.append(Result { try controller.openDiscord() }) }.start()
        #expect(entered.wait(timeout: .now() + 5) == .success)
        try controller.disconnect()
        #expect(session.untouched)
        release.signal()
        let result = try #require(waitFor { opened.all.first })
        #expect(throws: KitError.sessionNotReady()) { try result.get() }
        #expect(session.discord.launches.all.isEmpty)
    }

    @Test func refusesWhileDiscordRuns() throws {
        let session = try Session()
        session.discord.set(true)
        let controller = session.controller()
        #expect(throws: KitError.discordRunning()) { try controller.connect() }
        #expect(session.untouched && controller.enginePID == nil)
        #expect(session.states.all == ["Connecting", "Could not connect"])
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func stopsWhenDiscordOpensDuringPreparation() throws {
        let session = try Session()
        let controller = session.controller()
        let pids = Collected<pid_t>()
        session.onRunning = { [weak controller] in
            if let pid = controller?.enginePID { pids.append(pid) }
        }
        session.discord.answer([false, true])
        #expect(throws: KitError.discordOpenedDuringPreparation()) { try controller.connect() }
        let pid = try #require(pids.all.first)
        #expect(session.untouched && Self.gone(pid) && controller.enginePID == nil)
    }

    /// Discord still open at the end keeps the changes and their journal; the next session undoes them first.
    @Test(.enabled(if: TestEngine.isAvailable))
    func keepsTheChangesWhileDiscordRunsAndTheNextSessionUndoesThem() throws {
        let session = try Session()
        let first = session.controller()
        try first.connect()
        let pid = try #require(first.enginePID)
        session.discord.set(true)
        #expect(throws: KitError.sessionRestoreDeferred()) { try first.disconnect() }
        #expect(Self.gone(pid) && SafeFileTests.text(session.fixture.journal) != nil)
        #expect(SafeFileTests.text(session.fixture.entry(1))?.hasPrefix(SessionWrapper.marker) == true)
        #expect(session.lines.all.contains("DiscordAccess: preparing the connection."))

        let second = session.controller()
        #expect(throws: KitError.discordRunning()) { try second.connect() }
        #expect(SafeFileTests.text(session.fixture.journal) != nil)
        session.discord.set(false)
        let third = session.controller()
        try third.connect()
        #expect(session.lines.all.contains("Restored the temporary Discord settings of the previous session."))
        try third.disconnect()
        #expect(session.untouched)
    }

    /// Discord updating itself mid-session leaves the new version without the wrapper; the next open applies it there,
    /// once, and disconnecting undoes it. Discord usually deletes the old version's folder; the session must not need it.
    @Test(.enabled(if: TestEngine.isAvailable), arguments: [false, true])
    func opensAnUpdatedDiscordThroughTheSession(keepOld: Bool) throws {
        let session = try Session()
        let controller = session.controller()
        // A failed expectation must not leave the engine running.
        defer { try? controller.disconnect() }
        try controller.connect()
        try session.update(keepOld: keepOld)

        #expect(try controller.openDiscord() == "Sent the request to open the official Discord.")
        #expect(SafeFileTests.text(session.updatedEntry)?.hasPrefix(SessionWrapper.marker) == true)
        if keepOld { #expect(SafeFileTests.text(session.fixture.entry(1)) == DiscordProfileChangesTests.official) }
        #expect(try controller.openDiscord() == "Sent the request to open the official Discord.")
        #expect(session.discord.launches.all.count == 2)
        #expect(session.lines.all.filter { $0.hasPrefix("Discord was updated to ") } == ["Discord was updated to " + Session.updated + "; the session now applies to that version."])
        try controller.disconnect()
        #expect(SafeFileTests.text(session.updatedEntry) == DiscordProfileChangesTests.official)
        #expect(try SafeFileTests.text(session.fixture.journal) == nil && session.fixture.settings()["NEW_UPDATE_ENDPOINT"] == nil)
        #expect(session.fixture.leftovers.isEmpty)
    }

    /// The updated Discord relaunching itself is left alone: its profile may not change while it runs.
    @Test(.enabled(if: TestEngine.isAvailable))
    func leavesAnUpdatedDiscordThatRuns() throws {
        let session = try Session()
        let controller = session.controller()
        // A failed expectation must not leave the engine running.
        defer { try? controller.disconnect() }
        try controller.connect()
        try session.update(keepOld: false)
        session.discord.set(true)
        #expect(try controller.openDiscord() == "Discord is already open; it was not opened again.")
        #expect(SafeFileTests.text(session.updatedEntry) == DiscordProfileChangesTests.official && session.discord.launches.all.isEmpty)
        session.discord.set(false)
        #expect(try controller.openDiscord() == "Sent the request to open the official Discord.")
        #expect(SafeFileTests.text(session.updatedEntry)?.hasPrefix(SessionWrapper.marker) == true)
        try controller.disconnect()
        #expect(SafeFileTests.text(session.updatedEntry) == DiscordProfileChangesTests.official)
    }

    /// An updated version the session cannot wrap ends the session with Discord's profile restored, never half-moved.
    @Test(.enabled(if: TestEngine.isAvailable))
    func endsTheSessionWhenAnUpdateCannotBeFollowed() throws {
        let session = try Session()
        let controller = session.controller()
        defer { try? controller.disconnect() }
        try controller.connect()
        let pid = try #require(controller.enginePID)
        try session.update(keepOld: true)
        try FileManager.default.removeItem(atPath: (session.updatedEntry as NSString).deletingLastPathComponent + "/core.asar")

        #expect(throws: KitError.profileMissingModule()) { try controller.openDiscord() }
        #expect(!controller.isActive && Self.gone(pid) && session.discord.launches.all.isEmpty)
        #expect(session.states.all.last == "Discord was updated, but the connection could not follow it; connect again.")
        #expect(session.untouched && SafeFileTests.text(session.updatedEntry) == DiscordProfileChangesTests.official)
    }

    /// ShipIt reopens an updated Discord without the session; the session asks it to quit, moves to the new version and
    /// opens Discord through the connection, on its own.
    @Test(.enabled(if: TestEngine.isAvailable))
    func reopensADiscordThatUpdatedAndRelaunchedItself() throws {
        let session = try Session()
        let controller = session.controller()
        defer { try? controller.disconnect() }
        try controller.connect()
        try session.update(keepOld: false)
        session.discord.set(true)
        try session.swapBundle()

        let launch = try #require(waitFor { session.discord.launches.all.first })
        #expect(launch.count == 3 && launch[0].hasPrefix("--proxy-server=http://127.0.0.1:") && launch[2] == "--disable-quic")
        #expect(session.discord.quits.all == [Session.updated] && controller.isActive)
        #expect(SafeFileTests.text(session.updatedEntry)?.hasPrefix(SessionWrapper.marker) == true)
        #expect(session.lines.all.contains("Discord was updated to " + Session.updated + "; the session follows it."))
        #expect(session.lines.all.contains("Sent the request to open the official Discord."))
        try controller.disconnect()
        #expect(SafeFileTests.text(session.updatedEntry) == DiscordProfileChangesTests.official && SafeFileTests.text(session.fixture.journal) == nil)
        #expect(session.fixture.leftovers.isEmpty)
    }

    /// An updated Discord that does not come back is only adopted: nothing is opened uninvited, and Open Discord works.
    @Test(.enabled(if: TestEngine.isAvailable))
    func adoptsAnUpdatedDiscordThatDoesNotReturn() throws {
        let session = try Session()
        let controller = session.controller()
        defer { try? controller.disconnect() }
        try controller.connect()
        try session.update(keepOld: false)
        try session.swapBundle()

        #expect(waitFor { SafeFileTests.text(session.updatedEntry)?.hasPrefix(SessionWrapper.marker) == true ? true : nil } == true)
        #expect(session.discord.quits.all.isEmpty && session.discord.launches.all.isEmpty && controller.isActive)
        #expect(try controller.openDiscord() == "Sent the request to open the official Discord.")
        #expect(session.discord.launches.all.count == 1)
        // Open Discord found the session already moved and did not move it again.
        #expect(session.lines.all.filter { $0.hasSuffix("; the session now applies to that version.") }.count == 1)
    }

    /// An updated Discord that will not quit is left alone and reported; Open Discord still follows the update later.
    @Test(.enabled(if: TestEngine.isAvailable))
    func leavesAnUpdatedDiscordThatWillNotQuit() throws {
        let session = try Session()
        session.quitEnds = false
        let controller = session.controller()
        defer { try? controller.disconnect() }
        try controller.connect()
        try session.update(keepOld: false)
        session.discord.set(true)
        try session.swapBundle()

        let notice = "The updated Discord did not quit; quit it yourself (Cmd+Q), then choose Open Discord."
        #expect(waitFor { session.lines.all.contains(notice) ? true : nil } == true)
        #expect(session.discord.quits.all == [Session.updated] && session.discord.launches.all.isEmpty && controller.isActive)
        #expect(SafeFileTests.text(session.updatedEntry) == DiscordProfileChangesTests.official)
        session.discord.set(false)
        #expect(try controller.openDiscord() == "Sent the request to open the official Discord.")
        #expect(SafeFileTests.text(session.updatedEntry)?.hasPrefix(SessionWrapper.marker) == true)
    }

    /// Open Discord chosen while the follow-up still verifies the bundle moves the session itself; the Discord it opened
    /// came through the session and is not quit.
    @Test(.enabled(if: TestEngine.isAvailable))
    func leavesADiscordThatOpenDiscordMovedTheSessionFor() throws {
        let session = try Session()
        let controller = session.controller()
        defer { try? controller.disconnect() }
        try controller.connect()
        try session.update(keepOld: false)
        var clicked = false
        session.onLocate = {
            guard !clicked else { return }
            clicked = true
            let opened = try? controller.openDiscord()
            #expect(opened == "Sent the request to open the official Discord.")
            session.discord.set(true)
        }
        try session.swapBundle()

        #expect(waitFor { session.lines.all.contains("Open Discord already applied the update.") ? true : nil } == true)
        #expect(session.discord.quits.all.isEmpty && session.discord.launches.all.count == 1 && controller.isActive)
        #expect(SafeFileTests.text(session.updatedEntry)?.hasPrefix(SessionWrapper.marker) == true)
    }

    /// A Discord that runs when the update would be adopted (opened from its icon, or another copy) keeps the profile
    /// as it is; Open Discord follows the update once it is closed.
    @Test(.enabled(if: TestEngine.isAvailable))
    func leavesTheProfileWhileADiscordRunsWithoutTheSession() throws {
        let session = try Session()
        let controller = session.controller()
        defer { try? controller.disconnect() }
        try controller.connect()
        try session.update(keepOld: false)
        // No main process of the bundle came back, but some Discord runs.
        session.mainProcesses = { [] }
        session.discord.set(true)
        try session.swapBundle()

        let notice = "Discord is open without the connection; quit it (Cmd+Q), then choose Open Discord."
        #expect(waitFor { session.lines.all.contains(notice) ? true : nil } == true)
        #expect(session.discord.quits.all.isEmpty && session.discord.launches.all.isEmpty && controller.isActive)
        #expect(SafeFileTests.text(session.updatedEntry) == DiscordProfileChangesTests.official)
        session.discord.set(false)
        #expect(try controller.openDiscord() == "Sent the request to open the official Discord.")
        #expect(SafeFileTests.text(session.updatedEntry)?.hasPrefix(SessionWrapper.marker) == true)
    }

    /// Disconnecting during a follow-up ends its waits early; that is not reported as Discord failing to quit.
    @Test(.enabled(if: TestEngine.isAvailable))
    func disconnectingEndsAFollowUpQuietly() throws {
        let session = try Session()
        let controller = session.controller()
        try controller.connect()
        try session.update(keepOld: false)
        // The reopened Discord never quits; no other Discord runs, so disconnecting restores the profile.
        session.mainProcesses = { [1] }
        try session.swapBundle()
        #expect(waitFor { session.discord.quits.all.isEmpty ? nil : true } == true)

        try controller.disconnect()
        usleep(800_000)
        #expect(!session.lines.all.contains { $0.hasPrefix("The updated Discord did not quit") || $0.hasPrefix("Discord.app changed") })
        #expect(session.discord.launches.all.isEmpty && SafeFileTests.text(session.updatedEntry) == DiscordProfileChangesTests.official)
        #expect(try SafeFileTests.text(session.fixture.journal) == nil && session.fixture.settings()["NEW_UPDATE_ENDPOINT"] == nil)
    }

    /// A Discord.app that changes without a new version, or cannot be verified, is left as it is; the watch ends with
    /// the session.
    @Test(.enabled(if: TestEngine.isAvailable))
    func ignoresABundleChangeWithoutANewVersion() throws {
        let session = try Session()
        let controller = session.controller()
        defer { try? controller.disconnect() }
        try controller.connect()
        try session.swapBundle()
        let unchanged = "Discord.app changed; the version is still " + DiscordProfileChangesTests.version + "."
        #expect(waitFor { session.lines.all.contains(unchanged) ? true : nil } == true)

        session.locateFailure = KitError.discordUnverified(session.installation.bundle)
        try session.swapBundle()
        let unverified = "Discord.app changed but could not be verified; the session keeps version " + DiscordProfileChangesTests.version + "."
        #expect(waitFor { session.lines.all.contains(unverified) ? true : nil } == true, "\(session.lines.all.suffix(6))")
        #expect(session.discord.quits.all.isEmpty && session.discord.launches.all.isEmpty && controller.isActive)

        try controller.disconnect()
        let count = session.lines.all.count
        try session.swapBundle()
        usleep(300_000)
        #expect(session.lines.all.count == count && session.untouched)
    }

    /// Quitting asks the bundle's main process only; its helpers (and any other Discord) are left alone. Engine copies
    /// stand in for Discord's executables: they wait for a configuration on stdin that never comes.
    @Test(.enabled(if: TestEngine.isAvailable))
    func quitsOnlyTheMainProcessOfTheBundle() throws {
        let main = try TestEngine.runnableCopy(named: "quit-probe.app/Contents/MacOS/Discord")
        let helper = try TestEngine.runnableCopy(named: "quit-probe.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper")
        let installation = DiscordInstallation(bundle: String(main.dropLast("/Contents/MacOS/Discord".count)), version: DiscordProfileChangesTests.version)
        let arguments = ["run", "-c", "stdin", "--disable-color"]
        let mainProcess = try startChild(main, arguments, input: Pipe())
        let helperProcess = try startChild(helper, arguments, input: Pipe())
        defer {
            for process in [mainProcess, helperProcess] {
                process.terminate()
                process.waitUntilExit()
            }
        }
        #expect(waitFor { ProcessInspector.record(for: mainProcess.processIdentifier)?.path == main ? true : nil } == true)

        try SessionController.System().quit(installation)
        #expect(waitFor { mainProcess.isRunning ? nil : true } == true)
        #expect(helperProcess.isRunning)
    }

    /// Only an update in place is followed; a Discord.app that is gone or no longer verifies is refused.
    @Test(.enabled(if: TestEngine.isAvailable))
    func refusesADiscordThatIsNoLongerTheSame() throws {
        let session = try Session()
        let controller = session.controller()
        // A failed expectation must not leave the engine running.
        defer { try? controller.disconnect() }
        try controller.connect()
        session.locateFailure = KitError.discordUnverified(session.installation.bundle)
        #expect(throws: KitError.discordChanged()) { try controller.openDiscord() }
        #expect(session.discord.launches.all.isEmpty && SafeFileTests.text(session.fixture.entry(1))?.hasPrefix(SessionWrapper.marker) == true)
        try controller.disconnect()
        #expect(session.untouched)
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func endsTheSessionWhenTheEngineStops() throws {
        let session = try Session()
        let controller = session.controller()
        try controller.connect()
        let pid = try #require(controller.enginePID)
        kill(pid, SIGKILL)
        #expect(waitFor { session.states.all.contains("The connection engine stopped; the connection was closed.") ? true : nil } == true)
        #expect(session.untouched && controller.enginePID == nil)
        #expect(throws: KitError.sessionNotReady()) { try controller.openDiscord() }
        try controller.disconnect()
    }

    @Test func refusesWithoutTheDataFolderOrTheHook() throws {
        let session = try Session()
        chmod(session.fixture.profile, 0)
        defer { chmod(session.fixture.profile, 0o755) }
        #expect(throws: KitError.profileAccessDenied()) { try session.controller().connect() }
        chmod(session.fixture.profile, 0o755)
        #expect(session.untouched)

        let missing = try Session()
        try FileManager.default.removeItem(atPath: missing.fixture.profile)
        #expect(throws: KitError.profileMissingModule()) { try missing.controller().connect() }

        let hooked = try Session()
        hooked.hook = hooked.fixture.directory.path + "/hook.cjs"
        #expect(throws: KitError.engineMissing(hooked.hook)) { try hooked.controller().connect() }
        try SafeFileTests.write(hooked.hook, "module.exports = { install() {} };")
        #expect(throws: KitError.hookIntegrity()) { try hooked.controller().connect() }
        #expect(hooked.untouched)
    }

    @Test func endsWhenCanceledBeforeConnecting() throws {
        let session = try Session()
        let controller = session.controller()
        controller.cancel()
        #expect(throws: CancellationError.self) { try controller.connect() }
        #expect(session.untouched)
    }

    /// `--restore` undoes a journal only while Discord is closed.
    @Test func restoresOnlyWhileDiscordIsClosed() throws {
        let fixture = try DiscordProfileChangesTests.Fixture()
        let asked = Collected<Bool>()
        #expect(try !SessionController.restore(profile: fixture.profile, state: fixture.state, running: { asked.append(true); return true }))
        #expect(asked.all.isEmpty)
        let changes = try DiscordProfileChangesTests.prepare(fixture)
        try changes.configure(legacy: DiscordProfileChangesTests.legacy, modern: DiscordProfileChangesTests.modern)
        #expect(throws: KitError.discordRunningDuringRestore()) { try SessionController.restore(profile: fixture.profile, state: fixture.state, running: { true }) }
        #expect(SafeFileTests.text(fixture.journal) != nil)
        #expect(try SessionController.restore(profile: fixture.profile, state: fixture.state, running: { false }))
        #expect(SafeFileTests.text(fixture.entry(1)) == DiscordProfileChangesTests.official && SafeFileTests.text(fixture.journal) == nil)
        #expect(try fixture.settings()["UPDATE_ENDPOINT"] as? String == "https://updates.discord.com/")
    }
}
