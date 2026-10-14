import Darwin

/// Why the gate refused a request; the raw values are the Windows `ProcessGate.RequestFailure` names used in diagnostics.
public enum RequestFailure: String, Error, Sendable {
    case invalidHeader = "InvalidHeader"
    case invalidRequestLine = "InvalidRequestLine"
    case invalidTarget = "InvalidTarget"
    case unsupportedMethod = "UnsupportedMethod"
    case forbiddenHost = "ForbiddenHost"
    case conflictingHost = "ConflictingHost"
    case invalidFraming = "InvalidFraming"
    case unsupportedUpgrade = "UnsupportedUpgrade"
}

/// The gate's request policy (Windows `ProcessGate.RewriteHeader`): one request header from an admitted Discord process
/// is checked against the Discord destinations, then rewritten to carry this run's engine credential.
public enum RequestPolicy {
    public static let maxHeaderLength = 32768
    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"]

    /// The request line and every header except `Proxy-Authorization`, unchanged and in order, followed by
    /// `Proxy-Authorization: <authorization>` as the last header. Throws `RequestFailure` when the request is refused.
    public static func rewrite(_ header: String, authorization: String) throws -> String {
        let bytes = Array(header.utf8)
        guard !bytes.isEmpty, bytes.count <= maxHeaderLength, bytes.suffix(4).elementsEqual([13, 10, 13, 10]),
              !bytes.contains(where: { $0 == 0 || $0 > 127 }) else { throw RequestFailure.invalidHeader }
        let rawLines = splitLines(Array(bytes.dropLast(4)))
        guard rawLines.allSatisfy({ !$0.contains(13) && !$0.contains(10) }) else { throw RequestFailure.invalidHeader }
        // Plain ASCII without CR or LF from here on, so every Character is one byte.
        let lines = rawLines.map { String(decoding: $0, as: UTF8.self) }
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { throw RequestFailure.invalidRequestLine }
        let connect = request[0] == "CONNECT"
        let host: String, port: Int
        if connect {
            guard let target = connectTarget(request[1]) else { throw RequestFailure.invalidTarget }
            (host, port) = target
        } else {
            guard methods.contains(request[0]) else { throw RequestFailure.unsupportedMethod }
            guard let target = absoluteHTTPHost(request[1]) else { throw RequestFailure.invalidTarget }
            (host, port) = (target, 80)
        }
        // Upload and challenge hosts are HTTPS-only exceptions; they never inherit Discord's HTTP or media-port rules.
        guard allowedHost(host) || (connect && port == 443 && (allowedChallengeHost(host) || uploadHost(host))) else {
            throw RequestFailure.forbiddenHost
        }
        // Discord's media servers use changing stream ports; every other CONNECT destination stays on 443.
        guard !connect || port == 443 || mediaHost(host) else { throw RequestFailure.invalidTarget }
        var output = lines[0] + "\r\n"
        var sawHost = false, sawLength = false, sawTransfer = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, line[..<colon].utf8.allSatisfy(isTokenByte),
                  !line.utf8.contains(where: { ($0 < 32 && $0 != 9) || $0 == 127 }) else { throw RequestFailure.invalidHeader }
            let name = line[..<colon].lowercased()
            let value = trimmed(line[line.index(after: colon)...])
            // A plain HTTP upgrade would hand the engine credential to the remote peer; inside CONNECT it stays opaque.
            if !connect && (name == "upgrade" || ((name == "connection" || name == "proxy-connection") &&
                value.split(separator: ",", omittingEmptySubsequences: false).contains { trimmed($0).lowercased() == "upgrade" })) {
                throw RequestFailure.unsupportedUpgrade
            }
            if name == "host" {
                let written = value.lowercased(), expected = host.lowercased()
                guard !sawHost, written == expected || written == expected + ":" + String(port) else { throw RequestFailure.conflictingHost }
                sawHost = true
            }
            if name == "content-length" {
                guard !sawLength, !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), Int64(value) != nil else {
                    throw RequestFailure.invalidFraming
                }
                sawLength = true
            }
            if name == "transfer-encoding" {
                guard !sawTransfer else { throw RequestFailure.invalidFraming }
                sawTransfer = true
            }
            if name != "proxy-authorization" { output += line + "\r\n" }
        }
        guard !(sawLength && sawTransfer) else { throw RequestFailure.invalidFraming }
        guard connect || sawHost else { throw RequestFailure.conflictingHost }
        return output + "Proxy-Authorization: " + authorization + "\r\n\r\n"
    }

    /// `host:port` with a host of `[A-Za-z0-9.-]` and a port of 1-65535 without sign or leading zero.
    static func connectTarget(_ target: String) -> (host: String, port: Int)? {
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy(isHostByte), let first = parts[1].utf8.first,
              first >= 49, first <= 57, parts[1].utf8.count <= 5, parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = Int(parts[1]), port <= 65535 else { return nil }
        return (String(parts[0]), port)
    }

    /// The host of an absolute `http://` target on port 80, with no user information or fragment. Stricter than the
    /// Windows `Uri` parsing: the host must already be in DNS form, and a written port must be exactly `80`.
    static func absoluteHTTPHost(_ target: String) -> String? {
        guard target.utf8.count > 7, target.prefix(7).lowercased() == "http://", target.utf8.allSatisfy({ $0 > 32 && $0 != 127 }),
              !target.contains("\\"), !target.contains("#") else { return nil }
        let authority = target.dropFirst(7).prefix { $0 != "/" && $0 != "?" }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy(isHostByte), parts.count == 1 || parts[1] == "80" else {
            return nil
        }
        return String(parts[0])
    }

    /// A DNS name of 1-253 characters whose labels have 1-63 letters, digits or inner hyphens; never an IP literal.
    static func validDNSHost(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count), host.utf8.allSatisfy(isHostByte) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ (1...63).contains($0.utf8.count) && $0.utf8.first != 45 && $0.utf8.last != 45 }) else { return false }
        var address = in_addr()
        return inet_aton(host, &address) == 0
    }

    static func allowedHost(_ host: String) -> Bool {
        validDNSHost(host) && matches(host, DiscordDestinations.allowedDomains)
    }

    static func allowedChallengeHost(_ host: String) -> Bool {
        validDNSHost(host) && matches(host, DiscordDestinations.challengeDomains)
    }

    static func uploadHost(_ host: String) -> Bool {
        DiscordDestinations.uploadHosts.contains(host.lowercased())
    }

    static func mediaHost(_ host: String) -> Bool {
        matches(host, ["discord.media"])
    }

    /// The domain itself or any subdomain of it, ignoring case.
    private static func matches(_ host: String, _ domains: [String]) -> Bool {
        let lowered = host.lowercased()
        return domains.contains { lowered == $0 || lowered.hasSuffix("." + $0) }
    }

    private static func isHostByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 46
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    /// Without leading and trailing spaces or tabs; no other whitespace survives the control-character check.
    private static func trimmed(_ text: Substring) -> String {
        var result = text.drop(while: { $0 == " " || $0 == "\t" })
        while let last = result.last, last == " " || last == "\t" { result = result.dropLast() }
        return String(result)
    }

    /// Splits at every CR LF pair, keeping empty pieces (C# `Split("\r\n", None)`).
    private static func splitLines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = [], start = 0, index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 13 && bytes[index + 1] == 10 {
                lines.append(bytes[start..<index])
                index += 2
                start = index
            } else {
                index += 1
            }
        }
        lines.append(bytes[start..<bytes.count])
        return lines
    }
}
