import Foundation
import Testing
@testable import DiscordAccessKit

@Suite struct SupportTests {
    @Test func tokensAreRandom32ByteBase64() throws {
        let first = try Secrets.randomToken()
        let second = try Secrets.randomToken()
        #expect(Data(base64Encoded: first)?.count == 32)
        #expect(first != second)
        #expect(!first.contains(":"))
    }

    @Test func errorsCarryWindowsCodes() {
        #expect(KitError.engineMissing("x").code == "PKG-E01")
        #expect(KitError.engineUnreadable("x").code == "PKG-E02")
        #expect(KitError.engineIntegrity("x").description.hasPrefix("[PKG-E03] x "))
        #expect(KitError.engineUnsafePath("x").code == "PKG-E04")
        #expect(KitError.engineStartFailed().code == "ENG-E01")
        #expect(KitError.randomUnavailable().code == "SYS-E01")
    }

    @Test func destinationsMatchWindowsProcessGate() {
        #expect(DiscordDestinations.allowedDomains == ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media",
                                                       "discordcdn.com", "discordstatus.com", "discord.gift"])
        #expect(DiscordDestinations.uploadHosts == ["discord-attachments-uploads-prd.storage.googleapis.com"])
        #expect(DiscordDestinations.challengeDomains == ["hcaptcha.com"])
    }
}
