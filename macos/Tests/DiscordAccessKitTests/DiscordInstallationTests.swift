import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Finding and verifying Discord.app (Windows `DiscordInstallation`), and the access check of Discord's data folder.
/// Only the installed app's metadata and signature are read; nothing of the user's Discord profile is.
@Suite struct DiscordInstallationTests {
    static let installed = "/Applications/Discord.app"
    static let hasDiscord = FileManager.default.fileExists(atPath: installed)

    /// A bundle that looks like Discord's but is not signed by Discord.
    static func lookalike(in directory: TemporaryDirectory) throws -> String {
        let bundle = directory.path + "/Discord.app"
        try FileManager.default.createDirectory(atPath: bundle + "/Contents/MacOS", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: bundle + "/Contents/Resources", withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.hnc.Discord", "CFBundleExecutable": "Discord"],
                                                      format: .xml, options: 0)
        try info.write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        try SafeFileTests.write(bundle + "/Contents/Resources/build_info.json", "{\"releaseChannel\":\"stable\",\"version\":\"0.0.416\"}")
        try SafeFileTests.write(bundle + "/Contents/MacOS/Discord", "#!/bin/sh\n", mode: 0o755)
        return bundle
    }

    @Test(.enabled(if: DiscordInstallationTests.hasDiscord))
    func verifiesTheInstalledDiscord() throws {
        let installation = try DiscordInstallation.verify(bundle: Self.installed)
        #expect(installation.bundle == Self.installed && DiscordProfileChanges.validVersion(installation.version))
        #expect(installation.approvedExecutables.map(\.path).first == Self.installed + "/Contents/MacOS/Discord" && installation.approvedExecutables.count == 5)
        #expect(try DiscordInstallation.verify(bundle: "/System/Volumes/Data" + Self.installed) == installation)
        #expect(try DiscordInstallation.locate(candidates: [Self.installed, "/nonexistent/Discord.app"]) == installation)
        #expect(throws: KitError.discordAmbiguous()) { try DiscordInstallation.locate(candidates: [Self.installed, Self.installed]) }
    }

    @Test func refusesWhatIsNotTheOfficialDiscord() throws {
        let directory = try TemporaryDirectory()
        let bundle = try Self.lookalike(in: directory)
        #expect(throws: KitError.discordUnverified(bundle)) { try DiscordInstallation.verify(bundle: bundle) }
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/Link.app", withDestinationPath: bundle)
        #expect(throws: KitError.discordUnverified(directory.path + "/Link.app")) { try DiscordInstallation.verify(bundle: directory.path + "/Link.app") }
        #expect(throws: KitError.discordUnverified(directory.path)) { try DiscordInstallation.verify(bundle: directory.path) }
        #expect(throws: KitError.discordUnverified("Discord.app")) { try DiscordInstallation.verify(bundle: "Discord.app") }
        #expect(throws: KitError.discordUnverified(bundle)) { try DiscordInstallation.locate(candidates: [bundle]) }
        #expect(throws: KitError.discordNotFound()) { try DiscordInstallation.locate(candidates: [directory.path + "/Missing.app"]) }
        #expect(try DiscordInstallation(bundle: bundle, version: "0.0.416").runningProcesses().allSatisfy { pid in
            ProcessInspector.record(for: pid)?.path.contains("/Discord.app/Contents/") == true
        })
    }

    @Test func tellsWhetherTheDataFolderCanBeRead() throws {
        let directory = try TemporaryDirectory()
        #expect(DiscordProfile.access(root: directory.path + "/missing") == .missing)
        try SafeFileTests.write(directory.path + "/settings.json", "{}")
        #expect(DiscordProfile.access(root: directory.path) == .granted)
        chmod(directory.path, 0o000)
        defer { chmod(directory.path, 0o755) }
        #expect(DiscordProfile.access(root: directory.path) == .denied)
    }

    @Test func namesItsFolders() {
        #expect(DiscordProfile.standardRoot.hasSuffix("/Library/Application Support/discord") && StateStore.standardRoot.hasSuffix("/Library/Application Support/DiscordAccess"))
        #expect(DiscordProfile.downloadLog(root: "/p") == "/p/DiscordAccess-downloads.log")
        #expect(DiscordProfile.fullDiskAccessSettings.scheme == "x-apple.systempreferences" && DiscordProfile.fullDiskAccessSettings.query == "Privacy_AllFiles")
        #expect(DiscordInstallation.standardLocations.first == "/Applications/Discord.app")
    }
}
