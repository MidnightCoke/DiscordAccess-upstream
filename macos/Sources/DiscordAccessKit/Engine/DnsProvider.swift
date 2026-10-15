/// One resolved DNS-over-HTTPS provider (Windows `DnsOptions` after automatic selection).
public struct DnsProvider: Equatable, Sendable {
    public enum Name: String, CaseIterable, Sendable {
        case cloudflareIP = "cloudflare-ip"
        case cloudflare
        case google
    }

    public let name: Name
    public let recordFragment: Bool

    public init(_ name: Name, recordFragment: Bool = false) {
        self.name = name
        self.recordFragment = recordFragment
    }

    public var address: String { name == .google ? "8.8.8.8" : "1.1.1.1" }

    public var serverName: String {
        switch name {
        case .google: return "dns.google"
        case .cloudflareIP: return "1.1.1.1"
        case .cloudflare: return "cloudflare-dns.com"
        }
    }

    /// Automatic selection order, as Windows `DnsOptions.Candidates`.
    public static func automaticCandidates(recordFragment: Bool) -> [DnsProvider] {
        [DnsProvider(.cloudflareIP, recordFragment: recordFragment),
         DnsProvider(.cloudflare, recordFragment: recordFragment),
         DnsProvider(.google, recordFragment: recordFragment)]
    }
}
