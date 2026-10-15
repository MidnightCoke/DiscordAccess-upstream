import Foundation
import Security

public enum Secrets {
    /// 32 random bytes, base64 encoded (Windows `DnsConnection.RandomSecret`).
    public static func randomToken() throws -> String {
        Data(try randomBytes(32)).base64EncodedString()
    }

    /// 24 random bytes as 48 lower-case hex digits, for a path (Windows `UpdateBridge` token).
    public static func randomPathToken() throws -> String {
        try randomBytes(24).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw KitError.randomUnavailable() }
        return bytes
    }
}
