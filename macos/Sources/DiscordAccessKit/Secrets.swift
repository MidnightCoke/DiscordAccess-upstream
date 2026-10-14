import Foundation
import Security

public enum Secrets {
    /// 32 random bytes, base64 encoded (Windows `DnsConnection.RandomSecret`).
    public static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw KitError.randomUnavailable() }
        return Data(bytes).base64EncodedString()
    }
}
