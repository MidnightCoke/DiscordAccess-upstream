import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Careful file operations (Windows `FileTransaction` vectors): no links, compare-and-swap, unknown bytes kept.
@Suite struct SafeFileTests {
    static func write(_ path: String, _ text: String, mode: mode_t = 0o644) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, mode)
    }

    static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Files a transaction left beside its target.
    static func leftovers(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasPrefix(".discordaccess-fs-") }.sorted()
    }

    @Test func readsARegularFileOfThisUserWithinItsLimit() throws {
        let directory = try TemporaryDirectory()
        let file = directory.path + "/settings.json"
        #expect(try SafeFile.read(file, limit: 100) == nil)
        try Self.write(file, "{}")
        #expect(try SafeFile.read(file, limit: 100) == Array("{}".utf8))
        #expect(throws: KitError.profileConflict()) { try SafeFile.read(file, limit: 1) }
        #expect(throws: KitError.profileConflict()) { try SafeFile.read(directory.path, limit: 100) }
        #expect(throws: KitError.profileConflict()) { try SafeFile.read("relative/settings.json", limit: 100) }
        #expect(throws: KitError.profileConflict()) { try SafeFile.read(directory.path + "/../settings.json", limit: 100) }
    }

    /// A link anywhere in the path is refused, whether it is the file or a folder above it.
    @Test func refusesLinks() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.createDirectory(atPath: directory.path + "/real", withIntermediateDirectories: false)
        try Self.write(directory.path + "/real/settings.json", "{}")
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/linked", withDestinationPath: directory.path + "/real")
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/real/link.json", withDestinationPath: directory.path + "/real/settings.json")
        #expect(throws: KitError.profileConflict()) { try SafeFile.read(directory.path + "/linked/settings.json", limit: 100) }
        #expect(throws: KitError.profileConflict()) { try SafeFile.read(directory.path + "/real/link.json", limit: 100) }
        #expect(throws: KitError.profileConflict()) {
            try SafeFile.replace(directory.path + "/linked/settings.json", expected: Array("{}".utf8), with: Array("[]".utf8), limit: 100, mode: 0o644)
        }
        #expect(Self.text(directory.path + "/real/settings.json") == "{}")
    }

    @Test func createsReplacesAndDeletesOnlyWhatItExpects() throws {
        let directory = try TemporaryDirectory()
        let file = directory.path + "/settings.json"
        try SafeFile.replace(file, expected: nil, with: Array("one".utf8), limit: 100, mode: 0o600)
        #expect(Self.text(file) == "one")
        var status = stat()
        #expect(lstat(file, &status) == 0 && status.st_mode & 0o777 == 0o600)
        #expect(throws: KitError.profileConflict()) { try SafeFile.replace(file, expected: nil, with: Array("two".utf8), limit: 100, mode: 0o600) }
        #expect(throws: KitError.profileConflict()) { try SafeFile.replace(file, expected: Array("other".utf8), with: Array("two".utf8), limit: 100, mode: 0o600) }
        chmod(file, 0o640)
        try SafeFile.replace(file, expected: Array("one".utf8), with: Array("two".utf8), limit: 100, mode: 0o600)
        #expect(Self.text(file) == "two" && lstat(file, &status) == 0 && status.st_mode & 0o777 == 0o640)
        #expect(throws: KitError.profileConflict()) { try SafeFile.delete(file, expected: Array("one".utf8), limit: 100) }
        #expect(Self.text(file) == "two")
        try SafeFile.delete(file, expected: Array("two".utf8), limit: 100)
        #expect(Self.text(file) == nil && Self.leftovers(directory.path).isEmpty)
    }

    /// Another writer between the comparison and the swap: its bytes go back in place and are also kept beside the file.
    @Test func putsBackWhatAnotherWriterWroteMeanwhile() throws {
        let directory = try TemporaryDirectory()
        let file = directory.path + "/index.js"
        try Self.write(file, "official")
        #expect(throws: KitError.profileConflict()) {
            try SafeFile.replace(file, expected: Array("official".utf8), with: Array("wrapper".utf8), limit: 100, mode: 0o644) {
                try? Self.write(file, "update")
            }
        }
        #expect(Self.text(file) == "update")
        let kept = Self.leftovers(directory.path)
        #expect(kept.count == 1 && kept.first?.hasSuffix(".preserved") == true && Self.text(directory.path + "/" + kept[0]) == "update")
    }

    /// A file that appears while a new one is being created is never overwritten.
    @Test func neverOverwritesAFileThatAppearsMeanwhile() throws {
        let directory = try TemporaryDirectory()
        let file = directory.path + "/settings.json"
        #expect(throws: KitError.profileConflict()) {
            try SafeFile.replace(file, expected: nil, with: Array("ours".utf8), limit: 100, mode: 0o644) { try? Self.write(file, "theirs") }
        }
        #expect(Self.text(file) == "theirs" && Self.leftovers(directory.path).isEmpty)
    }

    @Test func makesAndChecksAPrivateFolder() throws {
        let directory = try TemporaryDirectory()
        let state = directory.path + "/state"
        #expect(throws: KitError.profileConflict()) { try SafeFile.ensurePrivateDirectory(state, create: false) }
        try SafeFile.ensurePrivateDirectory(state, create: true)
        var status = stat()
        #expect(lstat(state, &status) == 0 && status.st_mode & 0o777 == 0o700)
        try SafeFile.ensurePrivateDirectory(state, create: false)
        chmod(state, 0o750)
        #expect(throws: KitError.profileConflict()) { try SafeFile.ensurePrivateDirectory(state, create: false) }
        chmod(state, 0o700)
        let entries = try #require(acl_from_text("!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000:everyone:0:allow:read\n"))
        defer { acl_free(UnsafeMutableRawPointer(entries)) }
        #expect(acl_set_link_np(state, ACL_TYPE_EXTENDED, entries) == 0)
        #expect(throws: KitError.profileConflict()) { try SafeFile.ensurePrivateDirectory(state, create: false) }
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/linked", withDestinationPath: state)
        #expect(throws: KitError.profileConflict()) { try SafeFile.ensurePrivateDirectory(directory.path + "/linked", create: false) }
    }
}
