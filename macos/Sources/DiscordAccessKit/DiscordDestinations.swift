/// Discord destinations; the same lists as Windows `ProcessGate` (src/Proxy.cs).
public enum DiscordDestinations {
    public static let allowedDomains = ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media",
                                        "discordcdn.com", "discordstatus.com", "discord.gift"]
    /// Discord's web application CSP names this upload bucket explicitly. HTTPS only, never a Google suffix.
    public static let uploadHosts = ["discord-attachments-uploads-prd.storage.googleapis.com"]
    /// hCaptcha uses changing asset subdomains. HTTPS only; no Discord HTTP or media-port rules.
    public static let challengeDomains = ["hcaptcha.com"]
}
