import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Which locations may start at login (Windows `StartupPathTrust` checks), and the preferences that remember the choice.
/// The registration itself needs an app bundle and is checked in the live run; these tests run outside one.
@Suite struct StartupRegistrationTests {
    /// An app bundle in a new temporary folder, which only this user can change.
    static func bundle(in directory: TemporaryDirectory) throws -> String {
        let bundle = directory.path + "/Apps/DiscordAccess.app"
        try FileManager.default.createDirectory(atPath: bundle + "/Contents/MacOS", withIntermediateDirectories: true)
        try SafeFileTests.write(bundle + "/Contents/Info.plist", "<plist/>")
        try SafeFileTests.write(bundle + "/Contents/MacOS/DiscordAccess", "#!/bin/sh\n", mode: 0o755)
        return bundle
    }

    static func setACL(_ entry: String, on path: String) throws {
        let process = try startChild("/bin/chmod", ["+a", entry, path])
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    static let unsafe = KitError.startupLocationUnsafe()

    @Test func trustsALocationOnlyThisUserCanChange() throws {
        let directory = try TemporaryDirectory()
        let bundle = try Self.bundle(in: directory)
        try StartupRegistration.verifyLocation(bundle)
        // A rule that only takes rights away is fine.
        try Self.setACL("everyone deny delete", on: directory.path + "/Apps")
        try StartupRegistration.verifyLocation(bundle)
    }

    @Test func refusesALocationOthersCanChange() throws {
        let directory = try TemporaryDirectory()
        let bundle = try Self.bundle(in: directory)
        chmod(directory.path + "/Apps", 0o775)
        #expect(throws: Self.unsafe) { try StartupRegistration.verifyLocation(bundle) }
        chmod(directory.path + "/Apps", 0o755)
        chmod(bundle + "/Contents/MacOS/DiscordAccess", 0o757)
        #expect(throws: Self.unsafe) { try StartupRegistration.verifyLocation(bundle) }
        chmod(bundle + "/Contents/MacOS/DiscordAccess", 0o755)
        try StartupRegistration.verifyLocation(bundle)
        try Self.setACL("everyone allow write", on: bundle + "/Contents/Info.plist")
        #expect(throws: Self.unsafe) { try StartupRegistration.verifyLocation(bundle) }
    }

    @Test func refusesLinksAndWhatIsNoAppBundle() throws {
        let directory = try TemporaryDirectory()
        let bundle = try Self.bundle(in: directory)
        try FileManager.default.createSymbolicLink(atPath: bundle + "/Contents/Resources", withDestinationPath: directory.path)
        #expect(throws: Self.unsafe) { try StartupRegistration.verifyLocation(bundle) }
        unlink(bundle + "/Contents/Resources")
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/Linked", withDestinationPath: directory.path + "/Apps")
        #expect(throws: Self.unsafe) { try StartupRegistration.verifyLocation(directory.path + "/Linked/DiscordAccess.app") }
        #expect(throws: Self.unsafe) { try StartupRegistration.verifyLocation(directory.path + "/Apps") }
        #expect(throws: Self.unsafe) { try StartupRegistration.verifyLocation(directory.path + "/AppTranslocation/X/DiscordAccess.app") }
        #expect(throws: Self.unsafe) { try StartupRegistration.verifyLocation(directory.path + "/Missing.app") }
        try StartupRegistration.verifyLocation(bundle)
    }

    @Test func registersOnlyFromAnAppBundle() {
        #expect(!StartupRegistration.isAvailable && StartupRegistration.state == .disabled)
        #expect(throws: KitError.startupRegistrationFailed()) { try StartupRegistration.enable() }
        #expect(throws: Never.self) { try StartupRegistration.disable() }
    }

    @Test func remembersWhetherTheUserChose() throws {
        let directory = try TemporaryDirectory()
        let state = directory.path + "/DiscordAccess"
        #expect(ResidentPreferences.load(state: state).startAtLogin == nil)
        for choice in [true, false] {
            try ResidentPreferences(startAtLogin: choice, openDiscordAtLogin: true).save(state: state)
            #expect(ResidentPreferences.load(state: state) == ResidentPreferences(startAtLogin: choice, openDiscordAtLogin: true))
        }
        try ResidentPreferences().save(state: state)
        #expect(SafeFileTests.text(state + "/preferences.json") == "{\"openDiscordAtLogin\":false}")
    }
}
