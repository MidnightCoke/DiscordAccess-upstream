#if DISCORDACCESS_LIVE
import Foundation
import Testing
@testable import DiscordAccessKit

/// Live checks on this Mac's own network, built only with `-Xswiftc -DDISCORDACCESS_LIVE` so that ordinary runs never
/// leave the machine. They reach Discord's public endpoints through the real engine, as a session does: automatic
/// selection followed by the HTTPS and Gateway HELLO checks through the selected gate, then each provider on its own.
/// Nothing is sent but anonymous requests; results are printed with a `LIVE` prefix for the live report.
@Suite(.serialized) struct LiveConnectivityTests {
    static func admission() throws -> PeerAdmission {
        try PeerAdmission(approved: [ProxyGateTests.netcat], readyTime: Date())
    }

    /// The gate's own lines show that the checks went through it.
    @Test func selectsAProviderAndReachesDiscordThroughIt() throws {
        let image = try EngineImage.verify(path: TestEngine.path)
        let admission = try Self.admission()
        let lines = ProxyGateTests.Collected<String>()
        let selected = try DnsSelection.select(.automatic, open: { provider, cancel in
            try DnsConnection.open(provider: provider, image: image, admission: admission, trace: lines.append, cancel: cancel)
        }, log: { print("LIVE " + $0) }, cancel: Cancellation())
        defer { try? selected.close() }
        let connection = try #require(selected as? DnsConnection)
        print("LIVE " + (try ConnectivityProbe.check(proxyPort: connection.gate.port)))
        print("LIVE " + (try GatewayHello.check(proxyPort: connection.gate.port)))
        for target in ["discord.com:443", "updates.discord.com:443", "gateway.discord.gg:443"] {
            #expect(waitFor { lines.all.contains("Proxy: Owned request " + target) ? true : nil } == true)
        }
    }

    /// Which providers work on this network: recorded, not required.
    @Test(arguments: DnsProvider.Name.allCases)
    func recordsWhetherEachProviderReachesDiscord(name: DnsProvider.Name) throws {
        let provider = DnsProvider(name)
        let connection = try DnsConnection.open(provider: provider, image: EngineImage.verify(path: TestEngine.path), admission: Self.admission(),
                                                cancel: Cancellation())
        defer { try? connection.close() }
        do {
            try connection.verify(cancel: Cancellation())
            print("LIVE " + provider.description + ": Gateway API erişildi")
        } catch {
            print("LIVE " + provider.description + ": " + String(describing: error))
        }
    }
}
#endif
