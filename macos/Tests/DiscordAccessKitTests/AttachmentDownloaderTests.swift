import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Downloading an attachment from the terminal (Windows `AttachmentDownloadChecks`). Discord's servers are stood in for
/// inside URLSession (`FixtureUpstream`); nothing goes to the network, and files go to a temporary folder.
@Suite struct AttachmentDownloaderTests {
    typealias Upstream = UpdateBridgeTests.FixtureUpstream
    static let link = "https://cdn.discordapp.com/attachments/123/456/fixture%20name.txt?ex=synthetic&is=test&hm=a%2Bb%2Fc"
    /// The message of a download that broke off, timed out or could not connect.
    static let interrupted = AttachmentDownloadFailure(message: "The file could not be downloaded. The connection or disk access may have been lost, or the " +
        "time ran out. Copy a new link from Discord and try again.")

    /// A link whose file name selects `script`.
    static func link(_ script: Upstream.Script, host: String = "cdn.discordapp.com") -> String {
        "https://" + host + "/attachments/111/222/" + (Upstream.path(script) as NSString).lastPathComponent + "?hm=signed"
    }

    static func download(_ link: String, root: String, cancel: Cancellation = Cancellation()) throws -> String {
        try AttachmentDownloader.download(link, root: root, proxyPort: 1, cancel: cancel, now: Date(), protocolClasses: [Upstream.self])
    }

    /// Nothing of a failed download stays: no file, no partial file and no folder.
    static func expectNothingLeft(_ root: String) {
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).isEmpty)
    }

    @Test(arguments: [link, "https://media.discordapp.net/attachments/1/2/file.png?format=webp", "HTTPS://CDN.DISCORDAPP.COM:443/attachments/1/2/f",
                      "https://cdn.discordapp.com/ephemeral-attachments/1/2/f?hm=fixture", "https://media.discordapp.net/ephemeral-attachments/1/2/f"])
    func acceptsDiscordAttachmentLinksUnchanged(_ good: String) throws {
        #expect(try AttachmentDownloader.validate(good).absoluteString == good)
    }

    @Test(arguments: [
        "", "http://cdn.discordapp.com/attachments/1/2/f", "https://cdn.discordapp.com:8443/attachments/1/2/f",
        "https://cdn.discordapp.com.evil.example/attachments/1/2/f", "https://a.cdn.discordapp.com/attachments/1/2/f",
        "https://user@cdn.discordapp.com/attachments/1/2/f", "https://cdn.discordapp.com/attachments/1/2/f#x",
        "https://cdn.discordapp.com/attachments/1/2/../f", "https://cdn.discordapp.com/attachments/1/2/%2e%2e",
        "https://cdn.discordapp.com/attachments/1/2/%2fsecret", "https://cdn.discordapp.com/attachments/1/2/%5csecret",
        "https://cdn.discordapp.com/attachments/1/2/%252fsecret", "https://cdn.discordapp.com/attachments/1/2/%0dsecret",
        "https://cdn.discordapp.com/attachments/a/2/f", "https://cdn.discordapp.com/attachments/1/2/",
        "https://cdn.discordapp.com/not-attachments/1/2/f", "https://cdn.discordapp.com/attachments/1/2/f\\evil",
        "https://cdn.discordapp.com?x=/attachments/1/2/f", "https://cdn.discordapp.com/attachments/1/2/%broken",
        link + "\r\nHeader: value", link + String(repeating: "x", count: 8193), "https://cdn.discordapp.com/attachments/12345678901234567890123/2/f",
        "https://cdn.discordapp.com/attachments/1/2/f g",
    ])
    func refusesEverythingElseWithoutShowingIt(_ bad: String) {
        #expect(throws: AttachmentDownloadFailure(message: AttachmentDownloader.invalidLink)) { try AttachmentDownloader.validate(bad) }
    }

    @Test func namesTheFileSafely() throws {
        func name(_ link: String) throws -> String { AttachmentDownloader.suggestedName(try AttachmentDownloader.validate(link)) }
        #expect(try name(Self.link) == "fixture name.txt")
        #expect(try name("https://cdn.discordapp.com/attachments/1/2/file%3Astream.txt") == "file_stream.txt")
        #expect(try name("https://cdn.discordapp.com/attachments/1/2/a%7Cb%3Fc%2Ad.txt") == "a_b_c_d.txt")
        #expect(try name("https://cdn.discordapp.com/attachments/1/2/.hidden") == "_hidden")
        #expect(try name("https://cdn.discordapp.com/attachments/1/2/name.%20.") == "name")
        #expect(try name("https://cdn.discordapp.com/attachments/1/2/%20") == "Discord-file")
        #expect(try name("https://cdn.discordapp.com/attachments/1/2/" + String(repeating: "a", count: 200) + ".txt") == String(repeating: "a", count: 160))
    }

    /// macOS allows 255 bytes for a file name: a longer one keeps its extension and is marked as shortened.
    @Test func keepsNamesWithinTheByteLimit() throws {
        func name(_ encoded: String) throws -> String {
            AttachmentDownloader.suggestedName(try AttachmentDownloader.validate("https://cdn.discordapp.com/attachments/1/2/" + encoded))
        }
        let wide = String(repeating: "%E6%96%87", count: 160) + ".txt"
        #expect(try name(wide) == "_" + String(repeating: "文", count: 84))
        #expect(try name(String(repeating: "%E6%96%87", count: 100) + ".pdf") == "_" + String(repeating: "文", count: 83) + ".pdf")
        #expect(try name("a" + String(repeating: "%CC%81", count: 300) + ".txt") == "Discord-file.txt")
        #expect(try name(String(repeating: "%E6%96%87", count: 85)) == String(repeating: "文", count: 85))
        let directory = try TemporaryDirectory()
        for encoded in [wide, String(repeating: "%E6%96%87", count: 100) + ".pdf", String(repeating: "%C3%A9", count: 160)] {
            let destination = try AttachmentDownloader.prepareDestination(for: try AttachmentDownloader.validate("https://cdn.discordapp.com/attachments/1/2/" + encoded),
                                                                          root: directory.path, now: Date())
            #expect((destination as NSString).lastPathComponent.utf8.count <= 255 && FileManager.default.createFile(atPath: destination, contents: Data()))
        }
    }

    @Test func givesEachDownloadANewFolderWithoutTheLink() throws {
        let directory = try TemporaryDirectory()
        let url = try AttachmentDownloader.validate(Self.link)
        let first = try AttachmentDownloader.prepareDestination(for: url, root: directory.path + "/DiscordAccess", now: Date())
        let second = try AttachmentDownloader.prepareDestination(for: url, root: directory.path + "/DiscordAccess", now: Date())
        #expect(first != second && (first as NSString).lastPathComponent == "fixture name.txt" && !first.contains("synthetic"))
        let folder = ((first as NSString).deletingLastPathComponent as NSString).lastPathComponent
        #expect(folder.range(of: #"\A[0-9]{8}-[0-9]{6}-[0-9a-f]{32}\z"#, options: .regularExpression) != nil)
        #expect(FileManager.default.fileExists(atPath: (first as NSString).deletingLastPathComponent) && !FileManager.default.fileExists(atPath: first))
    }

    @Test func savesTheFileMarkedAsDownloaded() throws {
        let directory = try TemporaryDirectory()
        let link = Self.link(Upstream.Script(headers: ["Content-Length": "11"], chunks: [Array("hello ".utf8), Array("world".utf8)]))
        let saved = try Self.download(link, root: directory.path)
        #expect(SafeFileTests.text(saved) == "hello world" && saved.hasPrefix(directory.path + "/"))
        var value = [UInt8](repeating: 0, count: 256)
        let length = getxattr(saved, "com.apple.quarantine", &value, value.count, 0, XATTR_NOFOLLOW)
        let quarantine = String(decoding: value.prefix(max(0, length)), as: UTF8.self)
        #expect(quarantine.hasPrefix("0081;") && quarantine.hasSuffix(";DiscordAccess;"))
        let folder = (saved as NSString).deletingLastPathComponent
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == [(saved as NSString).lastPathComponent])
        let request = try #require(Upstream.requests((link as NSString).lastPathComponent.components(separatedBy: "?")[0]).first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "DiscordAccess/3 (attachment download)")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity" && request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.url?.absoluteString == link)
    }

    @Test func followsAtMostThreeRedirectsWithinDiscord() throws {
        let directory = try TemporaryDirectory()
        let target = Self.link(Upstream.Script(chunks: [Array("moved".utf8)]), host: "media.discordapp.net")
        let saved = try Self.download(Self.link(Upstream.Script(status: 302, headers: ["Location": target])), root: directory.path)
        #expect(SafeFileTests.text(saved) == "moved")

        var next = Self.link(Upstream.Script(chunks: [Array("far".utf8)]))
        for _ in 0..<4 { next = Self.link(Upstream.Script(status: 307, headers: ["Location": next])) }
        let other = try TemporaryDirectory()
        #expect(throws: AttachmentDownloadFailure(message: "The download server returned too many redirects.")) { try Self.download(next, root: other.path) }
        Self.expectNothingLeft(other.path)

        let outside = Self.link(Upstream.Script(status: 302, headers: ["Location": "https://evil.example/attachments/1/2/f"]))
        #expect(throws: AttachmentDownloadFailure(message: AttachmentDownloader.invalidLink)) { try Self.download(outside, root: other.path) }
        let missing = Self.link(Upstream.Script(status: 301))
        #expect(throws: AttachmentDownloadFailure(message: "The download redirect could not be verified.")) { try Self.download(missing, root: other.path) }
        Self.expectNothingLeft(other.path)
    }

    @Test func reportsRefusalsWithFixedMessages() throws {
        let directory = try TemporaryDirectory()
        let limited = Self.link(Upstream.Script(status: 429, headers: ["Retry-After": "7"]))
        #expect(throws: AttachmentDownloadFailure(message: "The download server is rate limiting requests (HTTP 429). Wait about 7 seconds and try again. " +
            "No automatic retry was made.")) { try Self.download(limited, root: directory.path) }
        #expect(throws: AttachmentDownloadFailure(message: "The file could not be downloaded (HTTP 403). Copy a new file link from Discord.")) {
            try Self.download(Self.link(Upstream.Script(status: 403)), root: directory.path)
        }
        #expect(throws: Self.interrupted) { try Self.download(Self.link(Upstream.Script(refusal: .cannotConnectToHost)), root: directory.path) }
        Self.expectNothingLeft(directory.path)
    }

    @Test func refusesAFileOfAnotherSize() throws {
        let directory = try TemporaryDirectory()
        let short = Self.link(Upstream.Script(headers: ["Content-Length": "10"], chunks: [Array("12345".utf8)]))
        #expect(throws: AttachmentDownloadFailure(message: "The file arrived incomplete. The download did not finish.")) { try Self.download(short, root: directory.path) }
        let long = Self.link(Upstream.Script(headers: ["Content-Length": "3"], chunks: [Array("12345".utf8)]))
        #expect(throws: AttachmentDownloadFailure(message: "The file size did not match the server's response. The download did not finish.")) {
            try Self.download(long, root: directory.path)
        }
        let broken = Self.link(Upstream.Script(chunks: [Array("part".utf8)], failure: .networkConnectionLost))
        #expect(throws: Self.interrupted) { try Self.download(broken, root: directory.path) }
        Self.expectNothingLeft(directory.path)
    }

    @Test func cancelingRemovesThePartialFile() throws {
        let directory = try TemporaryDirectory()
        let cancel = Cancellation()
        let link = Self.link(Upstream.Script(chunks: [Array("partial".utf8)], hangs: true))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancel.cancel() }
        #expect(throws: CancellationError.self) { try Self.download(link, root: directory.path, cancel: cancel) }
        Self.expectNothingLeft(directory.path)
        #expect(throws: CancellationError.self) { try Self.download(link, root: directory.path, cancel: cancel) }
        Self.expectNothingLeft(directory.path)
    }

    @Test func estimatesRetryAfterAsWindowsDoes() {
        let now = Date(timeIntervalSince1970: 1_791_633_600)
        for (header, seconds) in [("5", 5), ("0.1", 1), (" 12.25 ", 13), ("86400", 86400)] {
            #expect(AttachmentDownloader.retryAfterSeconds(header, now: now) == seconds)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(AttachmentDownloader.retryAfterSeconds(format.string(from: now.addingTimeInterval(45)), now: now) == 45)
        for bad in [nil, "", "0", "-1", "+5", "NaN", "Infinity", "1e6", "86401", "1,5", "1\r\nsecret", "sensitive-fixture", String(repeating: "9", count: 129),
                    format.string(from: now.addingTimeInterval(-1)), format.string(from: now.addingTimeInterval(2 * 86400))] {
            #expect(AttachmentDownloader.retryAfterSeconds(bad, now: now) == nil)
        }
    }
}
