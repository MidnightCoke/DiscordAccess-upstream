import Foundation

/// Rewrites Discord's addresses so that they lead back through the update bridge (Windows `LocalUrl`,
/// `RewriteLocation` and `RewriteJson`). Only addresses `BridgeRequest.allowedURL` accepts are rewritten.
struct UpdateRewriter: Sendable {
    static let maxJSONBytes = 4 * 1024 * 1024
    /// Nesting levels of a manifest (Windows `JavaScriptSerializer.RecursionLimit`).
    static let maxDepth = 64

    /// `http://127.0.0.1:<port>/<token>`
    let base: String

    /// `<base>/download/<host><path and query>`, with the host in lower case.
    func localURL(_ address: String) throws -> String {
        guard let url = BridgeRequest.allowedURL(address), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else { throw BridgeFailure.invalidData }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return base + "/download/" + host.lowercased() + path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    /// A redirect's `Location`, resolved against the address that answered it, as a bridge address; nil without one. A
    /// destination that is not an allowed Discord address is refused, so the updater can never be sent elsewhere.
    func location(_ value: String?, from source: URL) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.utf8.count <= BridgeRequest.maxAddressLength, value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 92 }),
              let destination = URL(string: value, relativeTo: source)?.absoluteURL else { throw BridgeFailure.invalidData }
        return try localURL(destination.absoluteString)
    }

    /// The manifest with every string that is an allowed Discord address rewritten, at any depth; everything else stays.
    /// It must be UTF-8 (a leading byte order mark is dropped) and JSON, at most 4 MiB before and after, and at most 64
    /// levels deep. Keys keep their values but not their order.
    func rewrite(json data: Data) throws -> Data {
        guard data.count <= Self.maxJSONBytes else { throw BridgeFailure.invalidData }
        guard let text = String(data: data, encoding: .utf8) else { throw BridgeFailure.unexpected }
        let document: Any
        do {
            document = try JSONSerialization.jsonObject(with: Data(String(text.unicodeScalars.drop { $0 == "\u{FEFF}" }).utf8), options: .fragmentsAllowed)
        } catch {
            throw BridgeFailure.unexpected
        }
        let output = try JSONSerialization.data(withJSONObject: rewritten(document, depth: 1), options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard output.count <= Self.maxJSONBytes else { throw BridgeFailure.invalidData }
        return output
    }

    /// `application/json` or a `+json` type, ignoring parameters and case.
    static func isJSON(_ contentType: String?) -> Bool {
        let media = (contentType ?? "").split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        return media == "application/json" || media.hasSuffix("+json")
    }

    private func rewritten(_ value: Any, depth: Int) throws -> Any {
        if let text = value as? String { return BridgeRequest.allowedURL(text) == nil ? text : try localURL(text) }
        if let object = value as? [String: Any] {
            guard depth <= Self.maxDepth else { throw BridgeFailure.unexpected }
            return try object.mapValues { try rewritten($0, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            guard depth <= Self.maxDepth else { throw BridgeFailure.unexpected }
            return try array.map { try rewritten($0, depth: depth + 1) }
        }
        return value
    }
}
