import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The session's changes to a stand-in Discord profile (Windows `InstalledDiscord.RunOfflineChecks` scenarios). The
/// user's own Discord profile is never touched.
@Suite struct DiscordProfileChangesTests {
    static let version = "0.0.416"
    static let official = "module.exports = require('./core.asar');\n"
    static let token = String(repeating: "5a", count: 24)
    static let legacy = "http://127.0.0.1:42000/" + token + "/legacy"
    static let modern = "http://127.0.0.1:42000/" + token + "/updates/"

    /// A profile laid out like Discord's: settings, and the core generations of one host version.
    final class Fixture {
        let directory: TemporaryDirectory
        let profile: String
        let state: String

        init(modules: [Int] = [1, 2], settings: String? = "{\"BACKGROUND_COLOR\":\"#202225\",\"UPDATE_ENDPOINT\":\"https://updates.discord.com/\"}") throws {
            directory = try TemporaryDirectory()
            profile = directory.path + "/discord"
            state = directory.path + "/DiscordAccess"
            try FileManager.default.createDirectory(atPath: profile + "/app-" + DiscordProfileChangesTests.version + "/modules", withIntermediateDirectories: true)
            for module in modules { try add(module) }
            if let settings { try SafeFileTests.write(profile + "/settings.json", settings) }
        }

        func add(_ module: Int, entry: String = DiscordProfileChangesTests.official, archive: Bool = true) throws {
            let folder = (self.entry(module) as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try SafeFileTests.write(self.entry(module), entry)
            if archive { try SafeFileTests.write(folder + "/core.asar", "archive") }
        }

        func entry(_ module: Int) -> String {
            profile + "/app-" + DiscordProfileChangesTests.version + "/modules/discord_desktop_core-" + String(module) + "/discord_desktop_core/index.js"
        }

        var journal: String { state + "/installed-session/journal.json" }

        func settings() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: profile + "/settings.json"))) as? [String: Any])
        }

        /// Files a transaction left anywhere in the profile.
        var leftovers: [String] {
            (FileManager.default.subpaths(atPath: profile) ?? []).filter { ($0 as NSString).lastPathComponent.hasPrefix(".discordaccess-fs-") }
        }
    }

    static func wrapper(port: Int = 41000) throws -> SessionWrapper {
        try SessionWrapper(proxy: "http://127.0.0.1:" + String(port), hook: try SessionWrapperTests.hook(), downloadLog: "/tmp/downloads.log")
    }

    static func prepare(_ fixture: Fixture, wrapper: SessionWrapper? = nil) throws -> DiscordProfileChanges {
        try DiscordProfileChanges.prepare(profile: fixture.profile, version: version, state: fixture.state, wrapper: wrapper ?? Self.wrapper())
    }

    @Test func wrapsEveryCoreGenerationAndPointsTheUpdateSettingsAtTheBridge() throws {
        let fixture = try Fixture()
        let wrapper = try Self.wrapper()
        let changes = try Self.prepare(fixture, wrapper: wrapper)
        #expect(try SafeFile.read(fixture.entry(1), limit: 1 << 20) == wrapper.bytes && SafeFile.read(fixture.entry(2), limit: 1 << 20) == wrapper.bytes)
        var status = stat()
        #expect(lstat(fixture.journal, &status) == 0 && status.st_mode & 0o777 == 0o600 && lstat(fixture.state, &status) == 0 && status.st_mode & 0o777 == 0o700)
        #expect(try fixture.settings()["UPDATE_ENDPOINT"] as? String == "https://updates.discord.com/")
        #expect(try DiscordProfileChanges.hasPendingRecovery(state: fixture.state))
        try changes.configure(legacy: Self.legacy + "/", modern: String(Self.modern.dropLast()))
        var settings = try fixture.settings()
        #expect(settings["UPDATE_ENDPOINT"] as? String == Self.legacy && settings["NEW_UPDATE_ENDPOINT"] as? String == Self.modern)
        #expect(settings["BACKGROUND_COLOR"] as? String == "#202225")
        try changes.configure(legacy: Self.legacy, modern: Self.modern)
        #expect(throws: KitError.profileConflict()) { try changes.configure(legacy: Self.legacy, modern: Self.legacy) }
        try changes.restore()
        settings = try fixture.settings()
        #expect(settings["UPDATE_ENDPOINT"] as? String == "https://updates.discord.com/" && settings["NEW_UPDATE_ENDPOINT"] == nil)
        #expect(settings["BACKGROUND_COLOR"] as? String == "#202225")
        #expect(SafeFileTests.text(fixture.entry(1)) == Self.official && SafeFileTests.text(fixture.entry(2)) == Self.official)
        #expect(SafeFileTests.text(fixture.journal) == nil && fixture.leftovers.isEmpty)
        #expect(try !DiscordProfileChanges.hasPendingRecovery(state: fixture.state))
    }

    /// Windows: an owned setting the user changed since is never overwritten; the rest is restored, the journal kept.
    @Test func keepsWhatTheUserChangedSince() throws {
        let fixture = try Fixture()
        let changes = try Self.prepare(fixture)
        try changes.configure(legacy: Self.legacy, modern: Self.modern)
        var settings = try fixture.settings()
        settings["UPDATE_ENDPOINT"] = "https://mine.example/"
        settings["NEW_SETTING"] = 7
        try Data(JSONSerialization.data(withJSONObject: settings)).write(to: URL(fileURLWithPath: fixture.profile + "/settings.json"))
        #expect(throws: KitError.profileConflict()) { try changes.restore() }
        settings = try fixture.settings()
        #expect(settings["UPDATE_ENDPOINT"] as? String == "https://mine.example/" && settings["NEW_UPDATE_ENDPOINT"] == nil && settings["NEW_SETTING"] as? Int == 7)
        #expect(SafeFileTests.text(fixture.entry(1)) == Self.official && SafeFileTests.text(fixture.journal) != nil)
        #expect(throws: KitError.profileConflict()) { try changes.restore() }
        #expect(try fixture.settings()["UPDATE_ENDPOINT"] as? String == "https://mine.example/")
    }

    /// An update may reset or remove a core generation; that is fine. Unknown content is left and reported.
    @Test func leavesWhatAnUpdateReplaced() throws {
        let fixture = try Fixture(modules: [1, 2, 3])
        let changes = try Self.prepare(fixture)
        try SafeFileTests.write(fixture.entry(2), "module.exports = require(\"./core.asar\")")
        try FileManager.default.removeItem(atPath: fixture.profile + "/app-" + Self.version + "/modules/discord_desktop_core-3")
        try changes.restore()
        #expect(SafeFileTests.text(fixture.entry(1)) == Self.official && SafeFileTests.text(fixture.entry(2)) == "module.exports = require(\"./core.asar\")")
        #expect(SafeFileTests.text(fixture.journal) == nil)
        let other = try Fixture()
        let replaced = try Self.prepare(other)
        try SafeFileTests.write(other.entry(2), "SYNTHETIC_UPDATE();")
        #expect(throws: KitError.profileConflict()) { try replaced.restore() }
        #expect(SafeFileTests.text(other.entry(2)) == "SYNTHETIC_UPDATE();" && SafeFileTests.text(other.entry(1)) == Self.official)
        #expect(SafeFileTests.text(other.journal) != nil)
    }

    /// A previous session's wrapper whose journal is gone is taken back: its original is Discord's own entry, and the
    /// wrapper itself is kept beside the entry. Restoring takes back such a wrapper too.
    @Test func takesBackAWrapperAnEarlierSessionLeft() throws {
        let fixture = try Fixture(modules: [1, 2])
        let earlier = String(decoding: try Self.wrapper(port: 1).bytes, as: UTF8.self)
        try SafeFileTests.write(fixture.entry(1), earlier)
        let changes = try Self.prepare(fixture)
        #expect(try SafeFile.read(fixture.entry(1), limit: 1 << 20) == Self.wrapper().bytes)
        #expect(fixture.leftovers.count == 1 && fixture.leftovers.first?.hasSuffix(".preserved") == true)
        try SafeFileTests.write(fixture.entry(2), earlier)
        try changes.restore()
        #expect(SafeFileTests.text(fixture.entry(1)) == Self.official && SafeFileTests.text(fixture.entry(2)) == Self.official)
        #expect(SafeFileTests.text(fixture.journal) == nil && fixture.leftovers.count == 2)
    }

    /// Recovery acts only on the profile it is given, and finds nothing when the journal's folder does not exist yet.
    @Test func recoversOnlyItsOwnProfile() throws {
        let fixture = try Fixture()
        try SafeFile.ensurePrivateDirectory(fixture.state, create: true)
        #expect(try !DiscordProfileChanges.recover(state: fixture.state, profile: fixture.profile))
        #expect(try !DiscordProfileChanges.hasPendingRecovery(state: fixture.state))
        let wrapper = try Self.wrapper()
        _ = try Self.prepare(fixture, wrapper: wrapper)
        #expect(throws: KitError.profileConflict()) { try DiscordProfileChanges.recover(state: fixture.state, profile: fixture.directory.path + "/other") }
        #expect(throws: KitError.profileConflict()) { try DiscordProfileChanges.recover(state: fixture.state) }
        #expect(try SafeFile.read(fixture.entry(1), limit: 1 << 20) == wrapper.bytes)
        #expect(try DiscordProfileChanges.recover(state: fixture.state, profile: fixture.profile))
    }

    /// Only an https address of Discord's own hosts can be written back, so another previous value is refused first.
    @Test func refusesAPreviousValueItCouldNotWriteBack() throws {
        let fixture = try Fixture(settings: "{\"NEW_UPDATE_ENDPOINT\":\"https://elsewhere.example/\"}")
        let changes = try Self.prepare(fixture)
        #expect(throws: KitError.profileConflict()) { try changes.configure(legacy: Self.legacy, modern: Self.modern) }
        #expect(try fixture.settings()["NEW_UPDATE_ENDPOINT"] as? String == "https://elsewhere.example/")
        try changes.restore()
        #expect(SafeFileTests.text(fixture.journal) == nil)
    }

    @Test func keepsTheProfileAndItsStateApart() throws {
        let fixture = try Fixture()
        #expect(throws: KitError.profileConflict()) {
            try DiscordProfileChanges.prepare(profile: fixture.profile, version: Self.version, state: fixture.profile + "/DiscordAccess", wrapper: Self.wrapper())
        }
        #expect(SafeFileTests.text(fixture.entry(1)) == Self.official)
    }

    @Test func refusesALayoutItDoesNotRecognize() throws {
        let unknown = try Fixture()
        try SafeFileTests.write(unknown.entry(2), "SYNTHETIC_CORE();")
        #expect(throws: KitError.profileUnsupported()) { try Self.prepare(unknown) }
        #expect(SafeFileTests.text(unknown.entry(1)) == Self.official && SafeFileTests.text(unknown.journal) == nil)
        let misnamed = try Fixture()
        try FileManager.default.createDirectory(atPath: misnamed.profile + "/app-" + Self.version + "/modules/discord_desktop_core-01", withIntermediateDirectories: true)
        #expect(throws: KitError.profileUnsupported()) { try Self.prepare(misnamed) }
        let many = try Fixture(modules: Array(1...17))
        #expect(throws: KitError.profileUnsupported()) { try Self.prepare(many) }
        #expect(throws: KitError.profileUnsupported()) { try DiscordProfileChanges.prepare(profile: many.profile, version: "0.0", state: many.state, wrapper: Self.wrapper()) }
        let empty = try Fixture(modules: [])
        #expect(throws: KitError.profileMissingModule()) { try Self.prepare(empty) }
        #expect(throws: KitError.profileMissingModule()) {
            try DiscordProfileChanges.prepare(profile: empty.profile, version: "0.0.417", state: empty.state, wrapper: Self.wrapper())
        }
        let unpacked = try Fixture(modules: [])
        try unpacked.add(1, archive: false)
        #expect(throws: KitError.profileMissingModule()) { try Self.prepare(unpacked) }
        let linked = try Fixture(modules: [])
        try FileManager.default.createDirectory(atPath: linked.directory.path + "/elsewhere/discord_desktop_core", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.profile + "/app-" + Self.version + "/modules/discord_desktop_core-1",
                                                   withDestinationPath: linked.directory.path + "/elsewhere")
        #expect(throws: KitError.profileConflict()) { try Self.prepare(linked) }
    }

    /// Windows: recovery undoes the recorded transaction, in the profile and version its journal names.
    @Test func recoversAnEarlierSessionFromItsJournal() throws {
        let fixture = try Fixture()
        #expect(try !DiscordProfileChanges.recover(state: fixture.state, profile: fixture.profile))
        try Self.prepare(fixture).configure(legacy: Self.legacy, modern: Self.modern)
        #expect(throws: KitError.profileConflict()) { try Self.prepare(fixture) }
        #expect(try DiscordProfileChanges.recover(state: fixture.state, profile: fixture.profile))
        #expect(SafeFileTests.text(fixture.entry(1)) == Self.official && SafeFileTests.text(fixture.entry(2)) == Self.official)
        #expect(try fixture.settings()["UPDATE_ENDPOINT"] as? String == "https://updates.discord.com/" && fixture.settings()["NEW_UPDATE_ENDPOINT"] == nil)
        #expect(try !DiscordProfileChanges.recover(state: fixture.state, profile: fixture.profile) && !DiscordProfileChanges.hasPendingRecovery(state: fixture.state))
    }

    /// Only a well-formed journal is acted on. (A journal naming another valid version reads like an update that removed
    /// the old version: nothing is undone there, and a wrapper left elsewhere is taken back by the next session.)
    @Test func refusesAJournalThatWasTamperedWith() throws {
        for tamper in [{ (journal: inout [String: Any]) in journal["extra"] = 1 },
                       { journal in journal["schema"] = 2 },
                       { journal in journal["version"] = "0.0.416.1" },
                       { journal in journal["profile"] = "relative/discord" },
                       { journal in journal["wrapper"] = "SYNTHETIC" },
                       { journal in journal["configured"] = 1 },
                       { journal in journal["configured"] = true },
                       { journal in journal["entries"] = [] as [Any] },
                       { journal in journal["entries"] = [["module": 1, "original": Data("evil();".utf8).base64EncodedString()]] },
                       { journal in journal["entries"] = [["module": 1, "original": "x"], ["module": 1, "original": "x"]] },
                       { journal in
                           for (key, value) in ["configured": true, "new_legacy": Self.legacy, "new_modern": Self.modern, "had_0": true, "old_0": "https://elsewhere.example/",
                                                "had_1": false] as [String: Any] { journal[key] = value }
                       }] as [(inout [String: Any]) -> Void] {
            let fixture = try Fixture()
            let wrapper = try Self.wrapper()
            _ = try Self.prepare(fixture, wrapper: wrapper)
            var journal = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture.journal))) as? [String: Any])
            tamper(&journal)
            try SafeFileTests.write(fixture.journal, String(decoding: try JSONSerialization.data(withJSONObject: journal), as: UTF8.self), mode: 0o600)
            #expect(throws: KitError.profileConflict()) { try DiscordProfileChanges.recover(state: fixture.state, profile: fixture.profile) }
            #expect(try SafeFile.read(fixture.entry(1), limit: 1 << 20) == wrapper.bytes)
        }
    }

    /// A write that fails midway is undone: no core generation keeps the wrapper and no journal stays.
    @Test func undoesWhatItWroteWhenAWriteFails() throws {
        let fixture = try Fixture()
        let folder = (fixture.entry(2) as NSString).deletingLastPathComponent
        chmod(folder, 0o555)
        defer {
            chmod(folder, 0o755)
            withExtendedLifetime(fixture) {}
        }
        #expect(throws: KitError.profileConflict()) { try Self.prepare(fixture) }
        #expect(SafeFileTests.text(fixture.entry(1)) == Self.official && SafeFileTests.text(fixture.entry(2)) == Self.official)
        #expect(SafeFileTests.text(fixture.journal) == nil && fixture.leftovers.isEmpty)
    }

    @Test func keepsItsJournalInAPrivateFolderOnly() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(atPath: fixture.state, withIntermediateDirectories: false)
        chmod(fixture.state, 0o755)
        #expect(throws: KitError.profileConflict()) { try Self.prepare(fixture) }
        #expect(SafeFileTests.text(fixture.entry(1)) == Self.official)
    }

    @Test func pointsTheUpdateSettingsAtTheBridgeOnly() throws {
        let fixture = try Fixture(settings: nil)
        let changes = try Self.prepare(fixture)
        for (legacy, modern) in [("https://evil.example/legacy", Self.modern), (Self.legacy, "http://127.0.0.2:42000/x/updates/"),
                                 (Self.legacy, "http://127.0.0.1:0/x/"), (Self.legacy, "http://127.0.0.1:42000/a b/"), (Self.legacy, "http://127.0.0.1:42000/")] {
            #expect(throws: KitError.profileConflict(), "\(modern)") { try changes.configure(legacy: legacy, modern: modern) }
        }
        try changes.configure(legacy: Self.legacy, modern: Self.modern)
        #expect(try fixture.settings().keys.sorted() == DiscordProfileChanges.settingKeys.sorted())
        try changes.restore()
        #expect(try fixture.settings().isEmpty)
    }
}
