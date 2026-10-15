import Foundation

/// Builds the engine policy in memory, like Windows `Package.Config`. Nothing is read from or written to disk.
public enum EngineConfig {
    static let inboundTag = "private-backend"
    static let outboundTag = "discord-direct"
    static let resolverTag = "discord-dns"

    public static func json(dns: DnsProvider, username: String, password: String, port: UInt16) throws -> Data {
        let inbound = [inboundTag]
        let allowed = DiscordDestinations.allowedDomains
        let tls = TLS(enabled: true, serverName: dns.serverName, recordFragment: dns.recordFragment ? true : nil)
        let document = Document(
            log: Log(disabled: true),
            dns: DNS(servers: [Server(type: "https", tag: resolverTag, server: dns.address, serverPort: 443, path: "/dns-query", tls: tls)],
                     final: resolverTag, strategy: "ipv4_only"),
            inbounds: [Inbound(type: "http", tag: inboundTag, listen: "127.0.0.1", listenPort: Int(port),
                               users: [User(username: username, password: password)])],
            outbounds: [Outbound(type: "direct", tag: outboundTag, domainResolver: Resolver(server: resolverTag, strategy: "ipv4_only"))],
            route: Route(rules: [
                Rule(inbound: inbound, network: "tcp", domainSuffix: allowed, port: 443, action: "route", outbound: outboundTag,
                     tlsRecordFragment: true),
                // Discord media keeps its dynamic WSS ports; fragmentation stays limited to the HTTPS rule above.
                Rule(inbound: inbound, network: "tcp", domainSuffix: ["discord.media"], portRange: ["1:65535"], action: "route",
                     outbound: outboundTag),
                Rule(inbound: inbound, network: "tcp", domainSuffix: allowed, port: 80, action: "route", outbound: outboundTag),
                Rule(inbound: inbound, network: "tcp", domain: DiscordDestinations.uploadHosts, port: 443, action: "route",
                     outbound: outboundTag),
                Rule(inbound: inbound, network: "tcp", domainSuffix: DiscordDestinations.challengeDomains, port: 443, action: "route",
                     outbound: outboundTag),
                Rule(action: "reject"),
            ], defaultDomainResolver: resolverTag))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}

private struct Document: Encodable {
    let log: Log
    let dns: DNS
    let inbounds: [Inbound]
    let outbounds: [Outbound]
    let route: Route
}

private struct Log: Encodable {
    let disabled: Bool
}

private struct TLS: Encodable {
    let enabled: Bool
    let serverName: String
    let recordFragment: Bool?
}

private struct Server: Encodable {
    let type: String
    let tag: String
    let server: String
    let serverPort: Int
    let path: String
    let tls: TLS
}

private struct DNS: Encodable {
    let servers: [Server]
    let `final`: String
    let strategy: String
}

private struct User: Encodable {
    let username: String
    let password: String
}

private struct Inbound: Encodable {
    let type: String
    let tag: String
    let listen: String
    let listenPort: Int
    let users: [User]
}

private struct Resolver: Encodable {
    let server: String
    let strategy: String
}

private struct Outbound: Encodable {
    let type: String
    let tag: String
    let domainResolver: Resolver
}

private struct Rule: Encodable {
    var inbound: [String]? = nil
    var network: String? = nil
    var domainSuffix: [String]? = nil
    var domain: [String]? = nil
    var port: Int? = nil
    var portRange: [String]? = nil
    var action: String
    var outbound: String? = nil
    var tlsRecordFragment: Bool? = nil
}

private struct Route: Encodable {
    let rules: [Rule]
    let defaultDomainResolver: String
}
