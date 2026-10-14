import Foundation
import Testing
@testable import DiscordAccessKit

@Suite struct DnsProviderTests {
    @Test func providersMatchWindowsDnsOptions() {
        #expect(DnsProvider(.cloudflareIP).address == "1.1.1.1")
        #expect(DnsProvider(.cloudflareIP).serverName == "1.1.1.1")
        #expect(DnsProvider(.cloudflare).address == "1.1.1.1")
        #expect(DnsProvider(.cloudflare).serverName == "cloudflare-dns.com")
        #expect(DnsProvider(.google).address == "8.8.8.8")
        #expect(DnsProvider(.google).serverName == "dns.google")
    }

    @Test func automaticCandidatesKeepWindowsOrderAndFragmentFlag() {
        let candidates = DnsProvider.automaticCandidates(recordFragment: true)
        #expect(candidates.map(\.name) == [.cloudflareIP, .cloudflare, .google])
        #expect(candidates.allSatisfy { $0.recordFragment })
        #expect(DnsProvider.automaticCandidates(recordFragment: false).allSatisfy { !$0.recordFragment })
    }
}

@Suite struct EngineConfigTests {
    static let username = "engine-smoke-fixture-user"
    static let password = "engine-smoke-fixture-password"

    static func generate(_ name: DnsProvider.Name, _ fragment: Bool) throws -> Data {
        try EngineConfig.json(dns: DnsProvider(name, recordFragment: fragment), username: username, password: password, port: 32123)
    }

    static func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// The fixture comes from the independent Aşama 0 generator, whose output the pinned engine accepted.
    @Test(arguments: DnsProvider.Name.allCases, [false, true])
    func matchesIndependentFixture(name: DnsProvider.Name, fragment: Bool) throws {
        let url = try #require(Bundle.module.url(forResource: "engine-configs", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let expected = try #require(fixtures[name.rawValue + (fragment ? "-fragment" : "-plain")] as? NSDictionary)
        let generated = try Self.object(Self.generate(name, fragment))
        #expect(generated == expected)
    }

    @Test func omitsUnsetFieldsAndKeepsValuesVerbatim() throws {
        let plain = String(decoding: try EngineConfig.json(dns: DnsProvider(.cloudflare), username: "u", password: "p/+=", port: 1), as: UTF8.self)
        #expect(!plain.contains("null"))
        #expect(!plain.contains("\"record_fragment\""))
        #expect(plain.contains("\"path\":\"/dns-query\""))
        #expect(plain.contains("\"password\":\"p/+=\""))
        let fragmented = String(decoding: try Self.generate(.google, true), as: UTF8.self)
        #expect(fragmented.contains("\"record_fragment\":true"))
    }

    @Test(.enabled(if: TestEngine.isAvailable), arguments: DnsProvider.Name.allCases, [false, true])
    func pinnedEngineAcceptsGeneratedConfig(name: DnsProvider.Name, fragment: Bool) throws {
        let directory = try TemporaryDirectory()
        let file = URL(fileURLWithPath: directory.path + "/config.json")
        try Self.generate(name, fragment).write(to: file)
        let check = try startChild(TestEngine.path, ["check", "-c", file.path])
        check.waitUntilExit()
        #expect(check.terminationStatus == 0)
    }
}
