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

    public static let unknownOption = "Unknown option. Run with --help for usage."

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
                    guard index < arguments.count else { throw Invalid(message: "Give the path of Discord.app after --discord-path.") }
                    value = arguments[index]
                    index += 1
                } else {
                    value = String(argument.dropFirst("--discord-path=".count))
                }
                guard discordPath == nil, value.hasPrefix("/") else {
                    throw Invalid(message: "--discord-path must be given once, with the full path of Discord.app (starting with /).")
                }
                discordPath = value
            } else if argument.lowercased().hasPrefix("--dns") {
                dnsArguments.append(argument)
            } else if argument == "--restore" || argument == "--verify-package" {
                throw Invalid(message: argument + " must be used on its own; do not combine it with other options.")
            } else {
                throw Invalid(message: unknownOption)
            }
        }
        guard !(console && startup) else { throw Invalid(message: "--startup is only for the menu bar app; do not combine it with --console.") }
        return CommandOptions(mode: console ? .console : .resident(startup: startup), dns: try DnsOptions.parse(dnsArguments), discordPath: discordPath)
    }

    public static let help = [
        "DiscordAccess (macOS) — menu bar and command line",
        "DiscordAccess                      Keeps the connection ready in the menu bar.",
        "DiscordAccess --console            Opens the connection in Terminal (A / Q / T / D).",
        "DiscordAccess --restore            Undoes the temporary Discord settings while Discord is closed.",
        "DiscordAccess --verify-package     Verifies the package without starting the engine.",
        "--discord-path=/Applications/Discord.app   A custom Discord.app path.",
        "--dns=auto                         Automatic DNS selection tested against Discord (default).",
        "--dns=cloudflare                   Fixed Cloudflare DoH.",
        "--dns=cloudflare-ip                Cloudflare DoH; the certificate is verified with the address 1.1.1.1.",
        "--dns=google                       Fixed Google DoH; only this provider is used.",
        "--dns-record-fragment              Turns on TLS record fragmentation for the selected DoH connection.",
        "--startup                          For the launch at login; not for manual launches.",
        "A + Enter: open Discord. Q + Enter / Ctrl+C: close the connection. T: diagnostics. D: download a file.",
        "Files downloaded with D are saved under Downloads/DiscordAccess. An empty Enter does not close the connection.",
        "When run from Terminal, the terminal app needs Full Disk Access for Discord's data folder.",
    ]
}
