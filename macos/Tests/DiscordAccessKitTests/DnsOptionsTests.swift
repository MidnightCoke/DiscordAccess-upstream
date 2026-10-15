import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows `DnsSelection.RunOfflineChecks` and `DnsOptions`.
@Suite struct DnsOptionsTests {
    @Test func selectsAutomaticallyInTheWindowsOrderByDefault() throws {
        let options = try DnsOptions.parse([])
        #expect(options == .automatic && options.isAutomatic && !options.recordFragment)
        #expect(options.candidates.map(\.name) == [.cloudflareIP, .cloudflare, .google])
        #expect(options.candidates.allSatisfy { !$0.recordFragment })
        #expect(options.description == "Otomatik seçim DoH | DNS TLS kayıt parçalama: kapalı")
        #expect(try DnsOptions.parse(["--dns=auto"]) == .automatic)
    }

    @Test(arguments: [("cloudflare", DnsProvider.Name.cloudflare, "Cloudflare DoH"), ("cloudflare-ip", .cloudflareIP, "Cloudflare (IP sertifikası) DoH"),
                      ("google", .google, "Google DoH")])
    func usesOnlyTheProviderNamed(argument: String, name: DnsProvider.Name, label: String) throws {
        let options = try DnsOptions.parse(["--dns=" + argument])
        #expect(!options.isAutomatic && options.provider == name)
        #expect(options.candidates == [DnsProvider(name)])
        #expect(options.description == label + " | DNS TLS kayıt parçalama: kapalı")
        let fragmented = try DnsOptions.parse(["--dns-record-fragment", "--dns=" + argument])
        #expect(fragmented.candidates == [DnsProvider(name, recordFragment: true)])
        #expect(fragmented.description == label + " | DNS TLS kayıt parçalama: açık")
    }

    @Test func keepsTheFragmentOptionForEveryAutomaticCandidate() throws {
        let options = try DnsOptions.parse(["--dns=auto", "--dns-record-fragment"])
        #expect(options.isAutomatic && options.recordFragment)
        #expect(options.candidates.count == 3 && options.candidates.allSatisfy(\.recordFragment))
        #expect(options.description == "Otomatik seçim DoH | DNS TLS kayıt parçalama: açık")
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
        #expect(KitError.invalidDnsOption().description == "[DNS-E01] DNS seçeneği geçersiz veya tekrarlanmış. --dns=auto, --dns=cloudflare, " +
            "--dns=cloudflare-ip ya da --dns=google seçin; gerekirse bir kez --dns-record-fragment ekleyin.")
        #expect(KitError.dnsSelectionFailed().description ==
            "[DNS-E02] Discord'a erişebilen bir DNS bağlantısı bulunamadı. İnternet bağlantısını kontrol edip yeniden bağlanın.")
        #expect(KitError.dnsCandidateNotClosed().description == "[DNS-E03] DNS bağlantısı güvenli biçimde kapatılamadı; başka bir aday başlatılmadı.")
        #expect(KitError.engineStopped().description == "[ENG-E02] Bağlantı motoru durdu.")
    }
}
