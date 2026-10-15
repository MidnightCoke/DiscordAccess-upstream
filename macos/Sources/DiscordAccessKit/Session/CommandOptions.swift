/// The options of the `DiscordAccess` command (design 4; Windows `Program.Main`). Until the menu bar app (stage 2), the
/// command without a mode opens the terminal session too.
public struct CommandOptions: Equatable {
    public enum Mode: Equatable {
        case console
        case restore
        case verifyPackage
        case help
    }

    /// A command line that cannot be used; `message` is shown as it is.
    public struct Invalid: Error, Equatable {
        public let message: String
    }

    public static let unknownOption = "Tanınmayan seçenek. Kullanım için --help yazın."

    public var mode: Mode
    public var dns: DnsOptions
    public var discordPath: String?

    /// `--help` (or `-h`) wins over everything else, as on Windows. `--restore` and `--verify-package` stand alone;
    /// `--console` takes `--discord-path=<Discord.app>` (or `--discord-path <Discord.app>`) and the DNS options, each at most
    /// once. Throws `Invalid`, or DNS-E01 for a DNS option.
    public static func parse(_ arguments: [String]) throws -> CommandOptions {
        if arguments.contains(where: { $0 == "--help" || $0 == "-h" }) { return CommandOptions(mode: .help, dns: .automatic) }
        if arguments == ["--restore"] { return CommandOptions(mode: .restore, dns: .automatic) }
        if arguments == ["--verify-package"] { return CommandOptions(mode: .verifyPackage, dns: .automatic) }
        var console = false
        var discordPath: String?
        var dnsArguments: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--console" && !console {
                console = true
            } else if argument == "--discord-path" || argument.hasPrefix("--discord-path=") {
                let value: String
                if argument == "--discord-path" {
                    guard index < arguments.count else { throw Invalid(message: "--discord-path için Discord.app yolunu belirtin.") }
                    value = arguments[index]
                    index += 1
                } else {
                    value = String(argument.dropFirst("--discord-path=".count))
                }
                guard discordPath == nil, value.hasPrefix("/") else {
                    throw Invalid(message: "--discord-path bir kez ve Discord.app'in tam yoluyla (/ ile başlayan) verilmelidir.")
                }
                discordPath = value
            } else if argument.lowercased().hasPrefix("--dns") {
                dnsArguments.append(argument)
            } else if argument == "--restore" || argument == "--verify-package" {
                throw Invalid(message: argument + " tek başına kullanılmalıdır; başka seçenekle birleştirmeyin.")
            } else {
                throw Invalid(message: unknownOption)
            }
        }
        return CommandOptions(mode: .console, dns: try DnsOptions.parse(dnsArguments), discordPath: discordPath)
    }

    public static let help = [
        "DiscordAccess (macOS) — Terminal modu",
        "DiscordAccess [--console]          Bağlantıyı açar; menü çubuğu modu gelene kadar varsayılan budur.",
        "DiscordAccess --restore            Discord kapalıyken geçici Discord ayarlarını geri alır.",
        "DiscordAccess --verify-package     Motoru başlatmadan paketi doğrular.",
        "--discord-path=/Applications/Discord.app   Özel Discord.app yolu.",
        "--dns=auto                         Discord erişimiyle otomatik DNS seçimi (varsayılan).",
        "--dns=cloudflare                   Sabit Cloudflare DoH.",
        "--dns=cloudflare-ip                Cloudflare DoH; sertifika 1.1.1.1 adresiyle doğrulanır.",
        "--dns=google                       Sabit Google DoH; yalnız bu sağlayıcı kullanılır.",
        "--dns-record-fragment              Seçilen DoH bağlantısında TLS kayıt parçalamayı açar.",
        "A + Enter: Discord aç. Q + Enter / Ctrl+C: bağlantıyı kapat. T: tanılama. D: dosya indir.",
        "D ile indirilen dosyalar İndirilenler/DiscordAccess altında kaydedilir. Boş Enter bağlantıyı kapatmaz.",
        "Terminal'den açıldığında Discord'un veri klasörü için Tam Disk Erişimi terminal uygulamasına verilmelidir.",
    ]
}
