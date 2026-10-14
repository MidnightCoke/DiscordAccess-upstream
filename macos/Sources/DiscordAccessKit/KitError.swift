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

    static func randomUnavailable() -> KitError {
        KitError(code: "SYS-E01", message: "Güvenli rastgele değer üretilemedi.")
    }
}
