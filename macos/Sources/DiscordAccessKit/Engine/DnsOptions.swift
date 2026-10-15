/// The DNS choice of a session (Windows `DnsOptions`): automatic selection, or the one provider the user named. The
/// chosen provider stays fixed for the session; the system's DNS settings are never changed.
public struct DnsOptions: Equatable, Sendable, CustomStringConvertible {
    /// The provider the user named; nil selects one automatically.
    public let provider: DnsProvider.Name?
    public let recordFragment: Bool

    public init(provider: DnsProvider.Name? = nil, recordFragment: Bool = false) {
        self.provider = provider
        self.recordFragment = recordFragment
    }

    public static let automatic = DnsOptions()

    public var isAutomatic: Bool { provider == nil }

    /// The providers to try, in order: the automatic order, or the one provider named.
    public var candidates: [DnsProvider] {
        guard let provider else { return DnsProvider.automaticCandidates(recordFragment: recordFragment) }
        return [DnsProvider(provider, recordFragment: recordFragment)]
    }

    /// For logs (Windows `Description`).
    public var description: String {
        guard let provider else { return "Otomatik seçim DoH | DNS TLS kayıt parçalama: " + (recordFragment ? "açık" : "kapalı") }
        return DnsProvider(provider, recordFragment: recordFragment).description
    }

    /// The DNS options among command-line arguments (Windows `Parse`): `--dns=auto`, `--dns=cloudflare`,
    /// `--dns=cloudflare-ip` or `--dns=google` at most once, and `--dns-record-fragment` at most once. Any other argument
    /// that starts with `--dns`, in any letter case, is refused (DNS-E01); other arguments are left to their own parsers.
    public static func parse(_ arguments: [String]) throws -> DnsOptions {
        var provider: DnsProvider.Name?
        var providerSet = false, fragment = false
        for argument in arguments {
            if argument == "--dns=auto" || DnsProvider.Name.allCases.contains(where: { argument == "--dns=" + $0.rawValue }) {
                guard !providerSet else { throw KitError.invalidDnsOption() }
                // "auto" names no provider.
                provider = DnsProvider.Name(rawValue: String(argument.dropFirst("--dns=".count)))
                providerSet = true
            } else if argument == "--dns-record-fragment" {
                guard !fragment else { throw KitError.invalidDnsOption() }
                fragment = true
            } else if argument.lowercased().hasPrefix("--dns") {
                throw KitError.invalidDnsOption()
            }
        }
        return DnsOptions(provider: provider, recordFragment: fragment)
    }

    /// Whether `argument` is one of the DNS options that `parse` accepts (Windows `IsArgument`).
    public static func isArgument(_ argument: String) -> Bool {
        argument == "--dns=auto" || argument == "--dns-record-fragment" || DnsProvider.Name.allCases.contains { argument == "--dns=" + $0.rawValue }
    }
}

extension DnsProvider: CustomStringConvertible {
    /// For logs (Windows `DnsOptions.Description` of a resolved provider).
    public var description: String {
        let label: String
        switch name {
        case .google: label = "Google"
        case .cloudflareIP: label = "Cloudflare (IP sertifikası)"
        case .cloudflare: label = "Cloudflare"
        }
        return label + " DoH | DNS TLS kayıt parçalama: " + (recordFragment ? "açık" : "kapalı")
    }
}
