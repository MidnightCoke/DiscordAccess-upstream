import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows `DnsSelection.RunOfflineChecks` and `DnsOptions`.
@Suite struct DnsOptionsTests {
    @Test func selectsAutomaticallyInTheWindowsOrderByDefault() throws {
        let options = try DnsOptions.parse([])
        #expect(options == .automatic && options.isAutomatic && !options.recordFragment)
        #expect(options.candidates.map(\.name) == [.cloudflareIP, .cloudflare, .google])
        #expect(options.candidates.allSatisfy { !$0.recordFragment })
        #expect(options.description == "Automatic DoH selection | DNS TLS record fragmentation: off")
        #expect(try DnsOptions.parse(["--dns=auto"]) == .automatic)
    }

    @Test(arguments: [("cloudflare", DnsProvider.Name.cloudflare, "Cloudflare DoH"), ("cloudflare-ip", .cloudflareIP, "Cloudflare (IP certificate) DoH"),
                      ("google", .google, "Google DoH")])
    func usesOnlyTheProviderNamed(argument: String, name: DnsProvider.Name, label: String) throws {
        let options = try DnsOptions.parse(["--dns=" + argument])
        #expect(!options.isAutomatic && options.provider == name)
        #expect(options.candidates == [DnsProvider(name)])
        #expect(options.description == label + " | DNS TLS record fragmentation: off")
        let fragmented = try DnsOptions.parse(["--dns-record-fragment", "--dns=" + argument])
        #expect(fragmented.candidates == [DnsProvider(name, recordFragment: true)])
        #expect(fragmented.description == label + " | DNS TLS record fragmentation: on")
    }

    @Test func keepsTheFragmentOptionForEveryAutomaticCandidate() throws {
        let options = try DnsOptions.parse(["--dns=auto", "--dns-record-fragment"])
        #expect(options.isAutomatic && options.recordFragment)
        #expect(options.candidates.count == 3 && options.candidates.allSatisfy(\.recordFragment))
        #expect(options.description == "Automatic DoH selection | DNS TLS record fragmentation: on")
    }

    @Test(arguments: [["--dns=auto", "--dns=google"], ["--dns=auto", "--dns=auto"], ["--dns=google", "--dns=cloudflare"],
                      ["--dns-record-fragment", "--dns-record-fragment"], ["--dns=quad9"], ["--DNS=google"], ["--dns"], ["--dnsx"],
                      ["--dns=Google"], ["--dns-record-fragment=1"], ["--Dns-record-fragment"], ["--dns= google"]])
    func refusesAnUnknownOrRepeatedDnsOption(arguments: [String]) {
        #expect(throws: KitError.invalidDnsOption()) { try DnsOptions.parse(arguments) }
    }

    @Test func leavesOtherArgumentsToTheirParsers() throws {
        #expect(try DnsOptions.parse(["--console", "--dns=google", "-x", "dns"]) == DnsOptions(provider: .google))
        for argument in ["--dns=auto", "--dns=cloudflare", "--dns=cloudflare-ip", "--dns=google", "--dns-record-fragment"] {
            #expect(DnsOptions.isArgument(argument))
        }
        for argument in ["--DNS=google", "--dns=quad9", "--dns", "--console", ""] {
            #expect(!DnsOptions.isArgument(argument))
        }
    }

    @Test func namesItsErrorsWithFixedCodes() {
        #expect(KitError.invalidDnsOption().description == "[DNS-E01] The DNS option is invalid or repeated. Choose --dns=auto, --dns=cloudflare, " +
            "--dns=cloudflare-ip or --dns=google; add --dns-record-fragment once if needed.")
        #expect(KitError.dnsSelectionFailed().description ==
            "[DNS-E02] No DNS connection could reach Discord. Check your internet connection and reconnect.")
        #expect(KitError.dnsCandidateNotClosed().description == "[DNS-E03] The DNS connection could not be closed safely; no other candidate was started.")
        #expect(KitError.engineStopped().description == "[ENG-E02] The connection engine stopped.")
    }
}
