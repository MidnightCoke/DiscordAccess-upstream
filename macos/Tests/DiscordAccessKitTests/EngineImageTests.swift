import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import DiscordAccessKit

@Suite struct EngineImageTests {
    static let content = Data("fixture-engine-bytes".utf8)
    static let identity = pin(for: content)

    static func pin(for data: Data) -> EngineIdentity {
        EngineIdentity(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), cdhash: String(repeating: "0", count: 40))
    }

    static func code(_ body: () throws -> EngineImage) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as KitError {
            return error.code
        } catch {
            return "unexpected"
        }
    }

    @Test func acceptsExactPinnedBytes() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        try Self.content.write(to: URL(fileURLWithPath: path))
        let image = try EngineImage.verify(path: path, expected: Self.identity)
        #expect(image.path == path)
        #expect(image.identity == Self.identity)
    }

    /// 2.5 MiB: two full read chunks and a partial one.
    @Test func hashesFilesLargerThanOneChunk() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        let original = Data((0..<(5 << 19)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try original.write(to: URL(fileURLWithPath: path))
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.pin(for: original)) } == nil)
        var changed = original
        changed[changed.count - 1] ^= 1
        try changed.write(to: URL(fileURLWithPath: path))
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.pin(for: original)) } == "PKG-E03")
    }

    @Test func rejectsChangedBytesAsIntegrityFailure() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: path))
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.identity) } == "PKG-E03")
    }

    @Test func rejectsMissingFileAndMissingFolder() throws {
        let directory = try TemporaryDirectory()
        let file = directory.path + "/file"
        try Self.content.write(to: URL(fileURLWithPath: file))
        #expect(Self.code { try EngineImage.verify(path: directory.path + "/missing", expected: Self.identity) } == "PKG-E01")
        #expect(Self.code { try EngineImage.verify(path: file + "/sing-box", expected: Self.identity) } == "PKG-E01")
    }

    @Test(.enabled(if: geteuid() != 0)) func rejectsUnreadableFile() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        try Self.content.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.identity) } == "PKG-E02")
    }

    @Test func rejectsLinkedFileParentAndDirectory() throws {
        let directory = try TemporaryDirectory()
        let real = directory.path + "/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try Self.content.write(to: URL(fileURLWithPath: real + "/sing-box"))
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/file-link", withDestinationPath: real + "/sing-box")
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/folder-link", withDestinationPath: real)
        #expect(Self.code { try EngineImage.verify(path: directory.path + "/file-link", expected: Self.identity) } == "PKG-E04")
        #expect(Self.code { try EngineImage.verify(path: directory.path + "/folder-link/sing-box", expected: Self.identity) } == "PKG-E04")
        #expect(Self.code { try EngineImage.verify(path: real, expected: Self.identity) } == "PKG-E04")
    }

    @Test func rejectsFIFOWithoutBlocking() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        #expect(mkfifo(path, 0o600) == 0)
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.identity) } == "PKG-E04")
    }

    @Test func rejectsNonCanonicalSpellings() throws {
        let directory = try TemporaryDirectory()
        try Self.content.write(to: URL(fileURLWithPath: directory.path + "/sing-box"))
        #expect(Self.code { try EngineImage.verify(path: directory.path + "//sing-box", expected: Self.identity) } == "PKG-E04")
        #expect(Self.code { try EngineImage.verify(path: directory.path + "/./sing-box", expected: Self.identity) } == "PKG-E04")
    }

    /// Both pinned values describe the built engine: the bytes through `verify`, the signature through Security.framework.
    @Test(.enabled(if: TestEngine.isAvailable)) func builtEngineMatchesThePin() throws {
        #expect(try EngineImage.verify(path: TestEngine.path).identity == .pinned)
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: TestEngine.path) as CFURL, [], &code) == errSecSuccess)
        let staticCode = try #require(code)
        var information: CFDictionary?
        #expect(SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess)
        let cdhash = try #require((information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
        #expect(cdhash.map { String(format: "%02x", $0) }.joined() == EngineIdentity.pinned.cdhash)
    }
}
