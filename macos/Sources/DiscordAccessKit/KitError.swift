import Foundation

/// A user-facing failure. Codes follow the Windows `PKG-E*` family where the meaning is the same.
public struct KitError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "[" + code + "] " + message }

    static func engineMissing(_ path: String) -> KitError {
        KitError(code: "PKG-E01", message: path + " bulunamadı. Paket eksik; DiscordAccess'i yeniden kurun.")
    }

    static func engineUnreadable(_ path: String) -> KitError {
        KitError(code: "PKG-E02", message: path + " okunamadı. DiscordAccess'i yeniden kurup tekrar deneyin.")
    }

    static func engineIntegrity(_ path: String) -> KitError {
        KitError(code: "PKG-E03", message: path + " bütünlük kontrolünden geçemedi. DiscordAccess'i yeniden kurun.")
    }

    static func engineUnsafePath(_ path: String) -> KitError {
        KitError(code: "PKG-E04", message: path + " dosya yolu güvenli biçimde doğrulanamadı. DiscordAccess'i normal bir yerel klasöre kurun.")
    }

    static func engineStartFailed() -> KitError {
        KitError(code: "ENG-E01", message: "Bağlantı motoru hazır olamadı.")
    }

    static func engineStopped() -> KitError {
        KitError(code: "ENG-E02", message: "Bağlantı motoru durdu.")
    }

    static func invalidDnsOption() -> KitError {
        KitError(code: "DNS-E01", message: "DNS seçeneği geçersiz veya tekrarlanmış. --dns=auto, --dns=cloudflare, --dns=cloudflare-ip ya da " +
            "--dns=google seçin; gerekirse bir kez --dns-record-fragment ekleyin.")
    }

    /// Every candidate failed its check; only this fixed message is shown (Windows `DnsSelectionException`).
    static func dnsSelectionFailed() -> KitError {
        KitError(code: "DNS-E02", message: "Discord'a erişebilen bir DNS bağlantısı bulunamadı. İnternet bağlantısını kontrol edip yeniden bağlanın.")
    }

    static func dnsCandidateNotClosed() -> KitError {
        KitError(code: "DNS-E03", message: "DNS bağlantısı güvenli biçimde kapatılamadı; başka bir aday başlatılmadı.")
    }

    static func randomUnavailable() -> KitError {
        KitError(code: "SYS-E01", message: "Güvenli rastgele değer üretilemedi.")
    }
}
