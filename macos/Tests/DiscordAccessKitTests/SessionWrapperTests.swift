import Foundation
import Testing
@testable import DiscordAccessKit

/// The session wrapper over Discord's core entry (design 7.2) and Discord's own entry (Windows `Original` vectors).
@Suite struct SessionWrapperTests {
    /// The hook both platforms share, from the repository (`bridge/attachment-download.cjs`).
    static func hook() throws -> [UInt8] {
        [UInt8](try Data(contentsOf: TestEngine.packageRoot.deletingLastPathComponent().appendingPathComponent("bridge/attachment-download.cjs")))
    }

    static let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test func pinsTheSharedHook() throws {
        #expect(SafeFile.sha256(try Self.hook()) == SessionWrapper.hookSHA256)
        #expect(throws: KitError.hookIntegrity()) { try SessionWrapper(proxy: "http://127.0.0.1:1", hook: try Self.hook() + [10], downloadLog: "/a.log") }
    }

    @Test func endsWithDiscordsOwnEntryAfterTheEmbeddedHook() throws {
        let wrapper = try SessionWrapper(proxy: "http://127.0.0.1:41000", hook: try Self.hook(), downloadLog: "/Users/x/Library/Application Support/discord/a \"b\".log")
        let text = String(decoding: wrapper.bytes, as: UTF8.self)
        let hook = String(decoding: try Self.hook(), as: UTF8.self)
        #expect(text.hasPrefix(SessionWrapper.marker) && text.hasSuffix("\nmodule.exports = require('./core.asar');\n"))
        #expect(text.contains("const proxy = \"http://127.0.0.1:41000\";") && text.contains(hook))
        #expect(text.contains("DISCORDACCESS_DOWNLOAD_LOG: \"/Users/x/Library/Application Support/discord/a \\\"b\\\".log\""))
        #expect(SessionWrapper.isWrapper(wrapper.bytes) && !SessionWrapper.isOfficial(wrapper.bytes) && wrapper.bytes.count <= DiscordProfileChanges.entryLimit)
    }

    @Test func recognizesDiscordsOwnEntryOnly() {
        for entry in ["module.exports = require('./core.asar');", "module.exports=require(\"./core.asar\")", "\u{FEFF}module.exports = require( './core.asar' );\n",
                      "  module.exports = require('./core.asar');\r\n"] {
            #expect(SessionWrapper.isOfficial(Array(entry.utf8)), "\(entry)")
        }
        for entry in ["module.exports = require('./core.asar'); evil();", "module.exports = require('./other.asar');", "require('./core.asar');",
                      "module.exports = require('./core.asar\");", "", "module.exports = require('./core.asar');\nmodule.exports = 1;"] {
            #expect(!SessionWrapper.isOfficial(Array(entry.utf8)), "\(entry)")
        }
        #expect(!SessionWrapper.isOfficial(Array(repeating: 32, count: 16_385)) && !SessionWrapper.isOfficial([0xFF]))
        #expect(!SessionWrapper.isWrapper(Array("module.exports = require('./core.asar');\n".utf8)))
        #expect(!SessionWrapper.isWrapper(Array((SessionWrapper.marker + "evil();\n").utf8)))
    }

    @Test func acceptsOnlyTheGateAsTheProxy() {
        #expect(SessionWrapper.validProxy("http://127.0.0.1:41000") && SessionWrapper.validProxy("http://127.0.0.1:1"))
        for proxy in ["http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:041000", "https://127.0.0.1:41000", "http://localhost:41000",
                      "http://127.0.0.1:41000/", "http://127.0.0.1"] {
            #expect(!SessionWrapper.validProxy(proxy), "\(proxy)")
        }
    }

    /// `Tests/wrapper.test.cjs` runs the generated wrapper with a stand-in Electron.
    @Test(.enabled(if: SessionWrapperTests.node != nil))
    func runsInNodeWithAStandInElectron() throws {
        let directory = try TemporaryDirectory()
        let log = directory.path + "/downloads.log"
        let wrapper = try SessionWrapper(proxy: "http://127.0.0.1:41000", hook: try Self.hook(), downloadLog: log)
        try Data(wrapper.bytes).write(to: URL(fileURLWithPath: directory.path + "/wrapper.cjs"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.node))
        process.arguments = [TestEngine.packageRoot.appendingPathComponent("Tests/wrapper.test.cjs").path, directory.path + "/wrapper.cjs",
                             "http://127.0.0.1:41000", log]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0 && text.contains("macOS session wrapper: PASS"), "\(text)")
    }
}
