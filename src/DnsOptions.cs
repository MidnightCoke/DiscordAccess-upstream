using System;

namespace DiscordAccess
{
    // Automatic selection happens once at startup. The selected provider then
    // stays fixed for this isolated session; OS DNS settings are never edited.
    internal sealed class DnsOptions
    {
        internal static readonly DnsOptions Default = new DnsOptions("auto", false);
        internal static readonly DnsOptions FixedDefault = new DnsOptions("cloudflare", false);
        internal readonly string Provider;
        internal readonly bool RecordFragment;
        private DnsOptions(string provider, bool recordFragment)
        {
            Provider = provider; RecordFragment = recordFragment;
        }
        internal bool Automatic { get { return Provider == "auto"; } }
        internal DnsOptions[] Candidates
        {
            get { return Automatic ? new[] { new DnsOptions("cloudflare-ip", RecordFragment),
                new DnsOptions("cloudflare", RecordFragment), new DnsOptions("google", RecordFragment) } : new[] { this }; }
        }
        private void RequireResolved()
        { if (Automatic) throw new InvalidOperationException("Otomatik DNS seçimi henüz tamamlanmadı."); }
        internal string Address { get { RequireResolved(); return Provider == "google" ? "8.8.8.8" : "1.1.1.1"; } }
        internal string ServerName { get { RequireResolved(); return Provider == "google" ? "dns.google" : (Provider == "cloudflare-ip" ? "1.1.1.1" : "cloudflare-dns.com"); } }
        internal string Description
        {
            get { return (Automatic ? "Otomatik seçim" : (Provider == "google" ? "Google" : (Provider == "cloudflare-ip" ? "Cloudflare (IP sertifikası)" : "Cloudflare"))) + " DoH | DNS TLS kayıt parçalama: " + (RecordFragment ? "açık" : "kapalı"); }
        }
        internal static DnsOptions Parse(string[] args)
        {
            string provider = "auto"; bool fragment = false, providerSet = false;
            foreach (string arg in args ?? new string[0])
            {
                if (arg == "--dns=auto" || arg == "--dns=cloudflare" || arg == "--dns=google" || arg == "--dns=cloudflare-ip")
                {
                    if (providerSet) throw Invalid();
                    provider = arg.Substring("--dns=".Length); providerSet = true;
                }
                else if (arg == "--dns-record-fragment")
                {
                    if (fragment) throw Invalid();
                    fragment = true;
                }
                else if (arg != null && arg.StartsWith("--dns", StringComparison.OrdinalIgnoreCase)) throw Invalid();
            }
            return new DnsOptions(provider, fragment);
        }
        internal static bool IsArgument(string arg)
        {
            return arg == "--dns=auto" || arg == "--dns=cloudflare" || arg == "--dns=google" || arg == "--dns=cloudflare-ip" || arg == "--dns-record-fragment";
        }
        private static ArgumentException Invalid()
        {
            return new ArgumentException("DNS seçeneği geçersiz veya tekrarlanmış. --dns=auto, --dns=cloudflare, --dns=cloudflare-ip ya da --dns=google seçin; gerekirse bir kez --dns-record-fragment ekleyin.");
        }
    }
}
