import Testing
@testable import DiscordAccessKit

/// The command line of `DiscordAccess` (Windows `Program.Main` option handling).
@Suite struct CommandOptionsTests {
    @Test func readsTheModes() throws {
        #expect(try CommandOptions.parse([]) == CommandOptions(mode: .console, dns: .automatic))
        #expect(try CommandOptions.parse(["--console"]) == CommandOptions(mode: .console, dns: .automatic))
        #expect(try CommandOptions.parse(["--restore"]).mode == .restore)
        #expect(try CommandOptions.parse(["--verify-package"]).mode == .verifyPackage)
        #expect(try CommandOptions.parse(["--bogus", "--help"]).mode == .help)
        #expect(try CommandOptions.parse(["-h"]).mode == .help)
    }

    @Test func readsTheConsoleOptions() throws {
        let options = try CommandOptions.parse(["--dns=google", "--console", "--discord-path=/Applications/Discord.app", "--dns-record-fragment"])
        #expect(options == CommandOptions(mode: .console, dns: DnsOptions(provider: .google, recordFragment: true), discordPath: "/Applications/Discord.app"))
        #expect(try CommandOptions.parse(["--discord-path", "/Users/a/Applications/Discord.app"]).discordPath == "/Users/a/Applications/Discord.app")
    }

    @Test func refusesWhatItCannotUse() {
        #expect(throws: CommandOptions.Invalid(message: CommandOptions.unknownOption)) { try CommandOptions.parse(["--bogus"]) }
        #expect(throws: CommandOptions.Invalid(message: CommandOptions.unknownOption)) { try CommandOptions.parse(["--console", "--console"]) }
        #expect(throws: CommandOptions.Invalid(message: CommandOptions.unknownOption)) { try CommandOptions.parse(["console"]) }
        #expect(throws: CommandOptions.Invalid(message: "--restore tek başına kullanılmalıdır; başka seçenekle birleştirmeyin.")) {
            try CommandOptions.parse(["--restore", "--discord-path=/Applications/Discord.app"])
        }
        #expect(throws: CommandOptions.Invalid(message: "--verify-package tek başına kullanılmalıdır; başka seçenekle birleştirmeyin.")) {
            try CommandOptions.parse(["--console", "--verify-package"])
        }
        let path = CommandOptions.Invalid(message: "--discord-path bir kez ve Discord.app'in tam yoluyla (/ ile başlayan) verilmelidir.")
        #expect(throws: path) { try CommandOptions.parse(["--discord-path=Discord.app"]) }
        #expect(throws: path) { try CommandOptions.parse(["--discord-path=/a/Discord.app", "--discord-path=/b/Discord.app"]) }
        #expect(throws: CommandOptions.Invalid(message: "--discord-path için Discord.app yolunu belirtin.")) { try CommandOptions.parse(["--discord-path"]) }
        #expect(throws: KitError.invalidDnsOption()) { try CommandOptions.parse(["--dns=quad9"]) }
        #expect(throws: KitError.invalidDnsOption()) { try CommandOptions.parse(["--DNS=google"]) }
        #expect(throws: KitError.invalidDnsOption()) { try CommandOptions.parse(["--dns=google", "--dns=cloudflare"]) }
    }
}
