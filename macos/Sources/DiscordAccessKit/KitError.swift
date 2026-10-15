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

    static func hookIntegrity() -> KitError {
        KitError(code: "PKG-E05", message: "Ek dosyası kancası bütünlük kontrolünden geçemedi. DiscordAccess'i yeniden kurun.")
    }

    static func discordNotFound() -> KitError {
        KitError(code: "DSC-E01", message: "Resmi Discord (Stable) kurulumu bulunamadı. Discord'u Uygulamalar klasörüne kurun ya da yolunu " +
            "--discord-path ile belirtin.")
    }

    static func discordUnverified(_ path: String) -> KitError {
        KitError(code: "DSC-E02", message: path + " resmi Discord (Stable) uygulaması olarak doğrulanamadı: imza, paket kimliği, sürüm " +
            "kanalı ya da yol uygun değil.")
    }

    /// The process list could not be read completely, so Discord may be running.
    static func discordStateUnknown() -> KitError {
        KitError(code: "DSC-E04", message: "Discord'un açık olup olmadığı denetlenemedi. Discord'u tamamen kapatıp yeniden deneyin.")
    }

    static func discordAmbiguous() -> KitError {
        KitError(code: "DSC-E03", message: "Birden fazla resmi Discord kurulumu bulundu. Kullanılacak kurulumu --discord-path ile belirtin.")
    }

    static func discordRunning() -> KitError {
        KitError(code: "DSC-E05", message: "Önce Discord'u tamamen kapatın (Discord > Discord'dan Çık ya da Cmd+Q); ardından DiscordAccess'i yeniden " +
            "açın. Açık Discord değiştirilmedi.")
    }

    static func discordOpenedDuringPreparation() -> KitError {
        KitError(code: "DSC-E06", message: "Hazırlık sırasında Discord açıldı. Discord'u tamamen kapatıp DiscordAccess'i yeniden açın; ayarlar " +
            "değiştirilmedi.")
    }

    /// `--restore` changes nothing while Discord runs.
    static func discordRunningDuringRestore() -> KitError {
        KitError(code: "DSC-E07", message: "Önce Discord'u tamamen kapatın (Discord > Discord'dan Çık ya da Cmd+Q); ardından DiscordAccess --restore " +
            "çalıştırın. Bekleyen geri alma kaydı korunuyor.")
    }

    static func discordLaunchFailed() -> KitError {
        KitError(code: "DSC-E08", message: "Discord açılış isteği gönderilemedi. Discord'u Dock, Launchpad ya da Spotlight'tan açabilirsiniz; " +
            "bağlantı açık kalır.")
    }

    /// Discord was open when the session ended, or undoing failed: the journal is kept for the next start or `--restore`.
    static func sessionRestoreDeferred() -> KitError {
        KitError(code: "SES-E01", message: "Bağlantı kapandı. Discord'u tamamen kapatıp DiscordAccess --restore çalıştırın ya da DiscordAccess'i " +
            "yeniden açın. Geçici ayarların kurtarma kaydı korundu.")
    }

    static func sessionNotReady() -> KitError {
        KitError(code: "SES-E02", message: "Bağlantı hazır değil.")
    }

    static func discordChanged() -> KitError {
        KitError(code: "SES-E03", message: "Discord değişti. Discord'u tamamen kapatıp Q ile çıkın; DiscordAccess'i yeniden açın.")
    }

    /// `--restore` while another DiscordAccess holds the session (Windows `ResidentInstance`).
    static func sessionStillOpen() -> KitError {
        KitError(code: "SES-E04", message: "DiscordAccess hâlâ açık. Önce mevcut bağlantıyı kapatın.")
    }

    /// Windows `Safety.RejectElevation`: root would own the files it writes in the user's folders.
    static func runningAsRoot() -> KitError {
        KitError(code: "SYS-E02", message: "DiscordAccess yönetici (root) olarak çalıştırılmaz. sudo kullanmadan, kendi kullanıcı hesabınızla açın.")
    }

    /// Windows `InstalledDiscord.Conflict`: nothing that changed since is overwritten.
    static func profileConflict() -> KitError {
        KitError(code: "PRF-E01", message: "Discord'un geçici ayarları güvenli biçimde doğrulanamadı. Değişmiş dosya veya tercihin üzerine yazılmadı.")
    }

    static func profileUnsupported() -> KitError {
        KitError(code: "PRF-E02", message: "Discord'un resmi sürümü veya başlangıç modülü tanınmadı; Discord dosyaları değiştirilmedi.")
    }

    static func profileMissingModule() -> KitError {
        KitError(code: "PRF-E03", message: "Discord'un beklenen başlangıç modülü bulunamadı. Discord'u bir kez normal açıp kapatın, sonra " +
            "yeniden deneyin.")
    }

    /// Run from a terminal, macOS asks Full Disk Access of the terminal app, not of DiscordAccess.
    static func profileAccessDeniedInTerminal() -> KitError {
        KitError(code: "PRF-E04", message: "Discord'un veri klasörüne erişim izni yok. Terminal'den açıldığında bu izin terminal uygulamasına " +
            "verilir: Sistem Ayarları > Gizlilik ve Güvenlik > Tam Disk Erişimi'nde Terminal'i (ya da kullandığınız terminal uygulamasını) açın, " +
            "uygulamayı kapatıp yeniden açın ve DiscordAccess'i tekrar çalıştırın. İzin verilmeden Discord ayarları değiştirilmez.")
    }

    /// macOS keeps Discord's data folder from other apps without asking (TCC); only Full Disk Access opens it.
    static func profileAccessDenied() -> KitError {
        KitError(code: "PRF-E04", message: "Discord'un veri klasörüne erişim izni yok. Sistem Ayarları > Gizlilik ve Güvenlik > Tam Disk " +
            "Erişimi'nde DiscordAccess'i açın. İzin verilmeden Discord ayarları değiştirilmez.")
    }
}
