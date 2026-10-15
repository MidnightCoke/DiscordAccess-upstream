/// The options of the `DiscordAccess` command (design 5; Windows `Program.Main`). Without a mode it is the menu bar app.
public struct CommandOptions: Equatable {
    public enum Mode: Equatable {
        /// The menu bar app; `startup` when the login item started it (Windows `--startup`).
        case resident(startup: Bool)
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

    /// `--help` (or `-h`) wins over everything else, as on Windows. `--restore` and `--verify-package` stand alone. The menu
    /// bar app (with `--startup` from the login item) and `--console` take `--discord-path=<Discord.app>` (or
    /// `--discord-path <Discord.app>`) and the DNS options, each at most once. Throws `Invalid`, or DNS-E01 for a DNS
    /// option.
    public static func parse(_ arguments: [String]) throws -> CommandOptions {
        // Launch Services adds `-psn_<number>` when it opens an app on some systems.
        let arguments = arguments.filter { !$0.hasPrefix("-psn_") }
        if arguments.contains(where: { $0 == "--help" || $0 == "-h" }) { return CommandOptions(mode: .help, dns: .automatic) }
        if arguments == ["--restore"] { return CommandOptions(mode: .restore, dns: .automatic) }
        if arguments == ["--verify-package"] { return CommandOptions(mode: .verifyPackage, dns: .automatic) }
        var console = false
        var startup = false
        var discordPath: String?
        var dnsArguments: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--console" && !console {
                console = true
            } else if argument == "--startup" && !startup {
                startup = true
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
        guard !(console && startup) else { throw Invalid(message: "--startup yalnız menü çubuğu uygulamasıyla kullanılır; --console ile birleştirmeyin.") }
        return CommandOptions(mode: console ? .console : .resident(startup: startup), dns: try DnsOptions.parse(dnsArguments), discordPath: discordPath)
    }

    public static let help = [
        "DiscordAccess (macOS) — menü çubuğu ve komut satırı",
        "DiscordAccess                      Menü çubuğunda bağlantıyı hazır tutar.",
        "DiscordAccess --console            Bağlantıyı Terminal'de açar (A / Q / T / D).",
        "DiscordAccess --restore            Discord kapalıyken geçici Discord ayarlarını geri alır.",
        "DiscordAccess --verify-package     Motoru başlatmadan paketi doğrular.",
        "--discord-path=/Applications/Discord.app   Özel Discord.app yolu.",
        "--dns=auto                         Discord erişimiyle otomatik DNS seçimi (varsayılan).",
        "--dns=cloudflare                   Sabit Cloudflare DoH.",
        "--dns=cloudflare-ip                Cloudflare DoH; sertifika 1.1.1.1 adresiyle doğrulanır.",
        "--dns=google                       Sabit Google DoH; yalnız bu sağlayıcı kullanılır.",
        "--dns-record-fragment              Seçilen DoH bağlantısında TLS kayıt parçalamayı açar.",
        "--startup                          Oturum açılışındaki başlatma içindir; elle açılış değildir.",
        "A + Enter: Discord aç. Q + Enter / Ctrl+C: bağlantıyı kapat. T: tanılama. D: dosya indir.",
        "D ile indirilen dosyalar İndirilenler/DiscordAccess altında kaydedilir. Boş Enter bağlantıyı kapatmaz.",
        "Terminal'den açıldığında Discord'un veri klasörü için Tam Disk Erişimi terminal uygulamasına verilmelidir.",
    ]
}
