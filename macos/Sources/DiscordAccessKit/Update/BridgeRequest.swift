import Foundation

/// A request Discord's updater sends to the update bridge: its method and the Discord address its path maps to
/// (Windows `UpdateBridge.ParseRequest` and `MapTarget`).
struct BridgeRequest: Equatable, Sendable {
    static let maxHeaderBytes = 16384
    static let maxAddressLength = 8192
    /// Printable characters a URL may not hold as they are; parsers of different macOS versions treat them differently.
    static let excluded = Set("\\\"<>^`{|}".utf8)

    let method: String
    let target: URL

    /// Parses the header of a request to the bridge on 127.0.0.1:`port`, ending with its empty line. Only GET and HEAD
    /// over HTTP/1.1 or 1.0 are accepted, without a body: header names must be tokens and appear once, `Host` must be
    /// exactly `127.0.0.1:<port>`, and no character may be a control character other than a tab.
    static func parse(_ header: [UInt8], port: UInt16, token: String) throws -> BridgeRequest {
        guard header.count >= 4, header.count <= maxHeaderBytes, header.suffix(4).elementsEqual([13, 10, 13, 10]) else { throw BridgeFailure.invalidData }
        let lines = Self.lines(header.dropLast(4))
        guard lines.allSatisfy({ $0.allSatisfy { ($0 >= 32 && $0 <= 126) || $0 == 9 } }) else { throw BridgeFailure.invalidData }
        let parts = lines[0].split(separator: 32, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD", parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            throw BridgeFailure.invalidData
        }
        var names = Set<String>()
        var host = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: 58), colon > line.startIndex, line[..<colon].allSatisfy(isTokenByte) else { throw BridgeFailure.invalidData }
            let name = String(decoding: line[..<colon], as: UTF8.self).lowercased()
            let value = String(decoding: line[(colon + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard names.insert(name).inserted else { throw BridgeFailure.invalidData }
            switch name {
            case "host":
                guard value == "127.0.0.1:" + String(port) else { throw BridgeFailure.invalidData }
                host = true
            case "transfer-encoding", "expect":
                throw BridgeFailure.invalidData
            case "content-length":
                guard value == "0" else { throw BridgeFailure.invalidData }
            default:
                break
            }
        }
        guard host else { throw BridgeFailure.invalidData }
        return BridgeRequest(method: parts[0], target: try target(path: parts[1], token: token))
    }

    /// The Discord address of a path under `/<token>/` (Windows `MapTarget`):
    /// - `/updates/…` → `https://updates.discord.com/…`, the new updater's manifests;
    /// - `/legacy`, `/legacy/…`, `/legacy?…` → `https://discord.com/api…`, the old updater's feed;
    /// - `/download/<host>/…` → `https://<host>/…` for an allowed Discord host, the downloads the bridge rewrote.
    static func target(path: String, token: String) throws -> URL {
        let prefix = "/" + token
        guard (1...maxAddressLength).contains(path.utf8.count), path.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 92 && $0 != 35 }),
              path.hasPrefix(prefix + "/") else { throw BridgeFailure.invalidData }
        // Printable ASCII only, so characters are bytes here.
        let remainder = path.dropFirst(prefix.count)
        let address: String
        if remainder.hasPrefix("/updates/") {
            address = "https://updates.discord.com/" + remainder.dropFirst(9)
        } else if remainder == "/legacy" || remainder.hasPrefix("/legacy/") || remainder.hasPrefix("/legacy?") {
            address = "https://discord.com/api" + remainder.dropFirst(7)
        } else if remainder.hasPrefix("/download/") {
            let download = remainder.dropFirst(10)
            guard let slash = download.firstIndex(of: "/"), slash > download.startIndex, RequestPolicy.allowedHost(String(download[..<slash])) else {
                throw BridgeFailure.invalidData
            }
            address = "https://" + download
        } else {
            throw BridgeFailure.invalidData
        }
        guard let url = allowedURL(address) else { throw BridgeFailure.invalidData }
        return url
    }

    /// An https address of an allowed Discord host on port 443 (Windows `TryAllowedUri`), with no user information,
    /// fragment or percent-encoded host, and only printable ASCII that a URL may hold as it is (`excluded`), so that
    /// every URL parser reads it alike; nil for anything else.
    static func allowedURL(_ text: String) -> URL? {
        let bytes = Array(text.utf8)
        guard (1...maxAddressLength).contains(bytes.count), bytes.allSatisfy({ $0 >= 33 && $0 <= 126 && !excluded.contains($0) }),
              text.lowercased().hasPrefix("https://"), !bytes.dropFirst(8).prefix(while: { $0 != 47 && $0 != 63 && $0 != 35 }).contains(64),
              let components = URLComponents(string: text), components.scheme?.lowercased() == "https", components.user == nil,
              components.password == nil, components.fragment == nil, components.port == nil || components.port == 443,
              let host = components.host, components.percentEncodedHost == host, RequestPolicy.allowedHost(host), let url = components.url else {
            return nil
        }
        return url
    }

    /// The lines of a header without its empty line, split at CR LF; a lone CR or LF stays in its line.
    private static func lines(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == 13, index + 1 < bytes.endIndex, bytes[index + 1] == 10 {
                lines.append(bytes[start..<index])
                index += 2
                start = index
            } else {
                index += 1
            }
        }
        lines.append(bytes[start..<bytes.endIndex])
        return lines
    }

    /// An HTTP token character (RFC 9110 `tchar`).
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
}
