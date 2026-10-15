import Foundation
import Testing
@testable import DiscordAccessKit

/// Rewriting Discord's addresses to the bridge (Windows `UpdateBridge.RunOfflineTests`, manifest and redirect vectors).
@Suite struct UpdateRewriterTests {
    static let base = "http://127.0.0.1:41000/" + String(repeating: "5a", count: 24)
    let rewriter = UpdateRewriter(base: base)

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func pointsAnAllowedAddressAtTheBridge() throws {
        #expect(try rewriter.localURL("https://cdn.discordapp.com/a.zip?signature=fixture") == Self.base + "/download/cdn.discordapp.com/a.zip?signature=fixture")
        #expect(try rewriter.localURL("https://Stable.DL2.discordapp.net/apps/osx/Discord.zip") == Self.base + "/download/stable.dl2.discordapp.net/apps/osx/Discord.zip")
        #expect(try rewriter.localURL("https://discord.com") == Self.base + "/download/discord.com/")
        #expect(throws: BridgeFailure.invalidData) { try rewriter.localURL("https://evil.test/a") }
    }

    /// The shape of Discord's update manifest (stage 0): every download address is rewritten, nothing else changes.
    @Test func rewritesEveryDiscordAddressOfAManifest() throws {
        let manifest = """
        {"full":{"host_version":[0,0,416],"package_sha256":"ff46","url":"https://stable.dl2.discordapp.net/distro/app/stable/osx/universal/0.0.416/full.distro"},\
        "deltas":[{"url":"https:\\/\\/stable.dl2.discordapp.net\\/distro\\/delta.distro?signature=fixture"}],\
        "modules":{"discord_voice":{"full":{"module_version":42,"url":"https://stable.dl2.discordapp.net/distro/voice.distro"}}},\
        "required_update":true,"metadata_version":null,"homepage":"https://example.org/","plain":"http://discord.com/a","text":"normal"}
        """
        let document = try Self.object(try rewriter.rewrite(json: Data(manifest.utf8)))
        let full = try #require(document["full"] as? [String: Any])
        #expect(full["url"] as? String == Self.base + "/download/stable.dl2.discordapp.net/distro/app/stable/osx/universal/0.0.416/full.distro")
        #expect(full["host_version"] as? [Int] == [0, 0, 416] && full["package_sha256"] as? String == "ff46")
        let delta = try #require((document["deltas"] as? [[String: Any]])?.first)
        #expect(delta["url"] as? String == Self.base + "/download/stable.dl2.discordapp.net/distro/delta.distro?signature=fixture")
        let voice = try #require(((document["modules"] as? [String: Any])?["discord_voice"] as? [String: Any])?["full"] as? [String: Any])
        #expect(voice["url"] as? String == Self.base + "/download/stable.dl2.discordapp.net/distro/voice.distro" && voice["module_version"] as? Int == 42)
        #expect(document["required_update"] as? Bool == true && document["metadata_version"] is NSNull)
        #expect(document["homepage"] as? String == "https://example.org/" && document["plain"] as? String == "http://discord.com/a")
        #expect(document["text"] as? String == "normal")
    }

    @Test func acceptsAByteOrderMarkAndATopLevelValue() throws {
        let marked = Data([0xEF, 0xBB, 0xBF]) + Data("{\"url\":\"https://cdn.discordapp.com/a\"}".utf8)
        #expect(try Self.object(try rewriter.rewrite(json: marked))["url"] as? String == Self.base + "/download/cdn.discordapp.com/a")
        let text = try rewriter.rewrite(json: Data("\"https://cdn.discordapp.com/a\"".utf8))
        #expect(try JSONSerialization.jsonObject(with: text, options: .fragmentsAllowed) as? String == Self.base + "/download/cdn.discordapp.com/a")
    }

    @Test func refusesWhatIsNotAUTF8JSONManifest() {
        #expect(throws: BridgeFailure.unexpected) { try rewriter.rewrite(json: Data([0x7B, 0xFF, 0x7D])) }
        #expect(throws: BridgeFailure.unexpected) { try rewriter.rewrite(json: Data("not json".utf8)) }
        #expect(throws: BridgeFailure.unexpected) { try rewriter.rewrite(json: Data()) }
    }

    @Test func refusesAManifestOverSixtyFourLevels() throws {
        let deep = { (levels: Int) in Data((String(repeating: "[", count: levels) + String(repeating: "]", count: levels)).utf8) }
        _ = try rewriter.rewrite(json: deep(64))
        #expect(throws: BridgeFailure.unexpected) { try rewriter.rewrite(json: deep(65)) }
    }

    /// 4 MiB before and after rewriting (Windows "manifest memory limit").
    @Test func refusesAManifestOverFourMebibytes() throws {
        #expect(throws: BridgeFailure.invalidData) { try rewriter.rewrite(json: Data(count: UpdateRewriter.maxJSONBytes + 1)) }
        let address = "\"https://cdn.discordapp.com/a\""
        let count = (UpdateRewriter.maxJSONBytes - 2) / (address.utf8.count + 1)
        let addresses = Data(("[" + Array(repeating: address, count: count).joined(separator: ",") + "]").utf8)
        #expect(addresses.count <= UpdateRewriter.maxJSONBytes)
        #expect(throws: BridgeFailure.invalidData) { try rewriter.rewrite(json: addresses) }
    }

    @Test func pointsARedirectAtTheBridge() throws {
        let source = URL(string: "https://updates.discord.com/a/manifest")!
        #expect(try rewriter.location("../download.zip", from: source) == Self.base + "/download/updates.discord.com/download.zip")
        #expect(try rewriter.location("https://cdn.discordapp.com/b?x=1", from: source) == Self.base + "/download/cdn.discordapp.com/b?x=1")
        #expect(try rewriter.location(nil, from: source) == nil && rewriter.location("", from: source) == nil)
        for target in ["https://evil.test/a", "http://discord.com/a", "https://user@discord.com/a", "https://@discord.com/a",
                       "https://discord.com:8443/a", "https://discord.com/a\r\nX: evil", "//evil.test/a", "https://discord.com/a\\b"] {
            #expect(throws: BridgeFailure.invalidData, "\(target)") { try rewriter.location(target, from: source) }
        }
    }

    @Test func recognizesJSONByItsMediaType() {
        for type in ["application/json", "Application/JSON; charset=utf-8", " application/json ;x=1", "application/vnd.discord+json"] {
            #expect(UpdateRewriter.isJSON(type), "\(type)")
        }
        for type in [nil, "", "text/html", "application/jsonx", "application/octet-stream", "text/json"] {
            #expect(!UpdateRewriter.isJSON(type), "\(type ?? "nil")")
        }
    }
}
