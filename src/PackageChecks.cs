using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace DiscordAccess
{
    internal static class PackageChecks
    {
        private const string SecretMarker = "SYNTHETIC_PRIVATE_KEY_DO_NOT_LOG";
        private const string TestPassword = "fixture-\"password\\with\ncharacters";
        // Captured from the original v4.7 production EXE's Config method with
        // fixture-user/TestPassword/17890. This pins every default JSON byte.
        private const string V47ConfigSha256 = "b3087f544430c085354f8691377a03b6f2bfdda38400bba4142c9c5e004adad7";
        internal static int Run(string packageRoot)
        {
            string workRoot = Path.GetFullPath(Path.Combine(packageRoot, "work"));
            string fixture = Path.Combine(workRoot, "pkg-" + Guid.NewGuid().ToString("N"));
            string engineDirectory = Path.Combine(fixture, "engine");
            string engine = Path.Combine(engineDirectory, "sing-box.exe");
            string config = Path.Combine(engineDirectory, "config.json");
            int checks = 0;
            Directory.CreateDirectory(fixture);
            try
            {
                ExpectFailure(fixture, "PKG-E01"); checks++;
                Directory.CreateDirectory(engineDirectory);
                ExpectFailure(fixture, "PKG-E01"); checks++;
                File.WriteAllText(engine, "not the pinned engine");
                ExpectFailure(fixture, "PKG-E03"); checks++;
                // Deletion also proves that failed validation releases its lease.
                File.Delete(engine);
                File.Copy(Path.Combine(packageRoot, "engine", "sing-box.exe"), engine);
                using (var locked = new FileStream(engine, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                    ExpectFailure(fixture, "PKG-E02");
                checks++;
                using (var valid = Package.LoadFrom(fixture))
                {
                    // No registration/config.json is required in direct mode.
                    checks += ValidateGeneratedRoute(valid.Config("fixture-user", TestPassword, 17890));
                    ExpectImageLocked(engine); checks++;
                }
                using (var released = new FileStream(engine, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
                checks++;
                checks += ValidateDnsModes(fixture);
                checks += ValidateDnsArguments();

                // A stale legacy registration cannot supply credentials, routes,
                // TLS policy or executable options, and is never opened.
                File.WriteAllText(config, "{\"private_key\":\"" + SecretMarker + "\", BROKEN JSON");
                ExpectLegacyIgnored(fixture); checks++;
                File.WriteAllText(config, SecretMarker + new string('x', 128 * 1024), Encoding.UTF8);
                ExpectLegacyIgnored(fixture); checks++;
                File.WriteAllText(config, "{\"route\":{\"final\":\"evil\"},\"inbounds\":[{\"type\":\"tun\"}],\"private_key\":\"" + SecretMarker + "\"}");
                using (var locked = new FileStream(config, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                    ExpectLegacyIgnored(fixture);
                checks++;
                File.Delete(config);
                Directory.CreateDirectory(config);
                ExpectLegacyIgnored(fixture); checks++;
                return checks;
            }
            finally
            {
                if (Safety.Under(fixture, workRoot) && Safety.NoReparse(fixture)) Directory.Delete(fixture, true);
            }
        }
        private static int ValidateGeneratedRoute(string text, string provider = "cloudflare", bool recordFragment = false)
        {
            var root = Object(new JavaScriptSerializer().DeserializeObject(text));
            Require(Keys(root, "log", "dns", "inbounds", "outbounds", "route") &&
                !text.Contains(SecretMarker) && !text.Contains("wireguard") && !text.Contains("discord-warp") &&
                !text.Contains("private_key"), "Registration or unexpected top-level network configuration survived.");
            var log = Object(root["log"]);
            Require(Keys(log, "disabled") && (bool)log["disabled"], "Engine logging unexpectedly enabled.");
            var inbounds = (IList)root["inbounds"];
            Require(inbounds.Count == 1, "Unexpected extra inbound.");
            var inbound = Object(inbounds[0]);
            Require(Keys(inbound, "type", "tag", "listen", "listen_port", "users") &&
                (string)inbound["type"] == "http" && (string)inbound["tag"] == "private-backend" &&
                (string)inbound["listen"] == "127.0.0.1" && (int)inbound["listen_port"] == 17890,
                "Inbound must remain an application-owned loopback HTTP proxy.");
            var users = (IList)inbound["users"];
            Require(users.Count == 1 && Keys(Object(users[0]), "username", "password") &&
                (string)Object(users[0])["username"] == "fixture-user" &&
                (string)Object(users[0])["password"] == TestPassword, "Backend authentication did not round-trip.");
            var dns = Object(root["dns"]);
            Require(Keys(dns, "servers", "final", "strategy") && (string)dns["final"] == "discord-dns" &&
                (string)dns["strategy"] == "ipv4_only" && ((IList)dns["servers"]).Count == 1, "DNS routing changed.");
            var server = Object(((IList)dns["servers"])[0]);
            Require(Keys(server, "type", "tag", "server", "server_port", "path", "tls") &&
                (string)server["type"] == "https" && (string)server["tag"] == "discord-dns" &&
                (string)server["server"] == (provider == "google" ? "8.8.8.8" : "1.1.1.1") && (int)server["server_port"] == 443 &&
                (string)server["path"] == "/dns-query", "DoH bootstrap must use the fixed IP without an outbound detour.");
            var tls = Object(server["tls"]);
            Require(Keys(tls, recordFragment ? new[] { "enabled", "server_name", "record_fragment" } : new[] { "enabled", "server_name" }) &&
                (bool)tls["enabled"] && (string)tls["server_name"] ==
                    (provider == "google" ? "dns.google" : (provider == "cloudflare-ip" ? "1.1.1.1" : "cloudflare-dns.com")) &&
                (!recordFragment || tls["record_fragment"] is bool && (bool)tls["record_fragment"]),
                "DoH certificate validation, fixed peer identity or opt-in fragmentation changed.");
            var outbounds = (IList)root["outbounds"];
            Require(outbounds.Count == 1, "Unexpected extra outbound.");
            var outbound = Object(outbounds[0]);
            Require(Keys(outbound, "type", "tag", "domain_resolver") && (string)outbound["type"] == "direct" &&
                (string)outbound["tag"] == "discord-direct", "Outbound is not the fixed direct transport.");
            var resolver = Object(outbound["domain_resolver"]);
            Require(Keys(resolver, "server", "strategy") && (string)resolver["server"] == "discord-dns" &&
                (string)resolver["strategy"] == "ipv4_only", "Direct outbound DNS resolver changed.");
            var route = Object(root["route"]);
            var rules = (IList)route["rules"];
            Require(Keys(route, "rules", "default_domain_resolver") && (string)route["default_domain_resolver"] == "discord-dns" &&
                rules.Count == 6, "Unexpected routing/default-interface policy.");
            var secure = Object(rules[0]);
            Require(RouteKeys(secure, "domain_suffix", "port", "tls_record_fragment") &&
                Strings(secure["domain_suffix"], ProcessGate.AllowedDomains) && (int)secure["port"] == 443 &&
                secure["tls_record_fragment"] is bool && (bool)secure["tls_record_fragment"],
                "TLS record fragmentation must be restricted to Discord HTTPS without TCP fragmentation or fallback delay.");
            var media = Object(rules[1]);
            Require(RouteKeys(media, "domain_suffix", "port_range") && Strings(media["domain_suffix"], "discord.media") &&
                Strings(media["port_range"], "1:65535"), "Dynamic Discord media ports were narrowed or granted to other domains.");
            var plain = Object(rules[2]);
            Require(RouteKeys(plain, "domain_suffix", "port") && Strings(plain["domain_suffix"], ProcessGate.AllowedDomains) &&
                (int)plain["port"] == 80, "Plain HTTP policy changed or acquired TLS fragmentation.");
            var upload = Object(rules[3]);
            Require(RouteKeys(upload, "domain", "port") &&
                Strings(upload["domain"], "discord-attachments-uploads-prd.storage.googleapis.com") &&
                (int)upload["port"] == 443, "Upload route must remain exact-host HTTPS without fragmentation.");
            var challenge = Object(rules[4]);
            Require(RouteKeys(challenge, "domain_suffix", "port") &&
                Strings(challenge["domain_suffix"], ProcessGate.ChallengeDomains) &&
                Strings(challenge["domain_suffix"], "hcaptcha.com") && (int)challenge["port"] == 443,
                "Login challenge route must remain HTTPS-only without fragmentation.");
            var reject = Object(rules[5]);
            Require(Keys(reject, "action") && (string)reject["action"] == "reject", "Unknown targets must be rejected.");
            // Only the selected DoH endpoint/identity and its optional TLS field
            // may differ. Entire remaining config is pinned to the v4.7 fixture.
            server["server"] = "1.1.1.1"; tls["server_name"] = "cloudflare-dns.com"; tls.Remove("record_fragment");
            Require(Safety.HashBytes(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(root))) == V47ConfigSha256,
                "DNS mode changed configuration outside the intended DoH fields.");
            if (provider == "cloudflare" && !recordFragment)
                Require(Safety.HashBytes(Encoding.UTF8.GetBytes(text)) == V47ConfigSha256, "Default JSON differs from v4.7.");
            return provider == "cloudflare" && !recordFragment ? 20 : 19;
        }
        private static int ValidateDnsModes(string fixture)
        {
            int checks = 0;
            using (var original = Package.LoadFrom(fixture))
            {
                string baseline = original.Config("fixture-user", TestPassword, 17890);
                foreach (string provider in new[] { "cloudflare", "cloudflare-ip", "google" })
                    foreach (bool fragment in new[] { false, true })
                    {
                        var args = new List<string> { "--dns=" + provider };
                        if (fragment) args.Add("--dns-record-fragment");
                        var options = DnsOptions.Parse(args.ToArray());
                        using (var selected = Package.LoadFrom(fixture, options))
                        {
                            string text = selected.Config("fixture-user", TestPassword, 17890);
                            checks += ValidateGeneratedRoute(text, provider, fragment);
                            DnsOptions.Parse(new[] { "--dns=google", "--dns-record-fragment" });
                            Require(selected.Config("fixture-user", TestPassword, 17890) == text,
                                "A later argument parse mutated an existing package's DNS mode."); checks++;
                        }
                    }
                Require(original.Config("fixture-user", TestPassword, 17890) == baseline,
                    "Other packages changed the existing default package."); checks++;
            }
            return checks;
        }
        private static int ValidateDnsArguments()
        {
            int checks = 0;
            foreach (string[] args in new[] { new string[0], null, new[] { "--start", "--connect" }, new[] { "--dns=auto" } })
            {
                var options = DnsOptions.Parse(args);
                Require(options.Automatic && !options.RecordFragment, "Default DNS options are not automatic."); checks++;
            }
            var fixedDefault = DnsOptions.Parse(new[] { "--dns=cloudflare" });
            Require(fixedDefault.Provider == "cloudflare" && !fixedDefault.Automatic && !fixedDefault.RecordFragment,
                "Explicit Cloudflare override changed."); checks++;
            var fragmentOnly = DnsOptions.Parse(new[] { "--dns-record-fragment" });
            Require(fragmentOnly.Automatic && fragmentOnly.RecordFragment, "Fragment-only option disabled automatic selection."); checks++;
            var reversed = DnsOptions.Parse(new[] { "--dns-record-fragment", "--connect", "--dns=google" });
            Require(reversed.Provider == "google" && reversed.RecordFragment, "DNS option ordering changed the result."); checks++;
            foreach (string[] args in new[] {
                new[] { "--dns" }, new[] { "--dns=" }, new[] { "--dns=system" }, new[] { "--dns=1.1.1.1" },
                new[] { "--dns=google " }, new[] { "--dns", "google" }, new[] { "--DNS=google" }, new[] { "--dns=GOOGLE" },
                new[] { "--dns-record-fragment=false" }, new[] { "--dns-record-fragment=true" }, new[] { "--dns-fragment" },
                new[] { "--dns-record-fragment", "--dns-record-fragment" },
                new[] { "--dns=cloudflare", "--dns=google" }, new[] { "--dns=google", "--dns=google" },
                new[] { "--dns=cloudflare-ip", "--dns=cloudflare" }, new[] { "--self-test", "--dns=invalid" },
                new[] { "--dns=auto", "--dns=google" }, new[] { "--dns=auto", "--dns=auto" },
                new[] { "--verify-package", "--dns=invalid" }, new[] { "--help", "--dns=invalid" } })
            {
                bool rejected = false;
                try { DnsOptions.Parse(args); } catch (ArgumentException) { rejected = true; }
                Require(rejected, "Invalid or duplicate DNS options accepted."); checks++;
            }
            return checks;
        }
        private static bool RouteKeys(Dictionary<string, object> rule, params string[] extra)
        {
            return Keys(rule, new[] { "inbound", "network", "action", "outbound" }.Concat(extra).ToArray()) &&
                Strings(rule["inbound"], "private-backend") && (string)rule["network"] == "tcp" &&
                (string)rule["action"] == "route" && (string)rule["outbound"] == "discord-direct";
        }
        private static bool Strings(object value, params string[] expected)
        {
            var values = value as IList;
            return values != null && values.Cast<object>().SequenceEqual(expected.Cast<object>());
        }
        private static Dictionary<string, object> Object(object value) { return (Dictionary<string, object>)value; }
        private static bool Keys(Dictionary<string, object> value, params string[] expected)
        {
            return value.Count == expected.Length && expected.All(value.ContainsKey);
        }
        private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        private static void ExpectLegacyIgnored(string fixture)
        {
            using (var valid = Package.LoadFrom(fixture)) ValidateGeneratedRoute(valid.Config("fixture-user", TestPassword, 17890));
        }
        private static void ExpectImageLocked(string engine)
        {
            try { using (new FileStream(engine, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { } }
            catch (IOException) { return; }
            throw new InvalidOperationException("Validated engine image was not held against modification.");
        }
        private static void ExpectFailure(string fixture, string code)
        {
            try { using (Package.LoadFrom(fixture)) { } }
            catch (PackageLoadException ex)
            {
                if (ex.Code != code || ex.InnerException != null || ex.ToString().Contains(SecretMarker) || ex.Message.Contains(fixture))
                    throw new InvalidOperationException("Package diagnostics did not preserve the expected safe error category: " + code + " (received " + ex.Code + ")");
                return;
            }
            throw new InvalidOperationException("Package validation unexpectedly accepted fixture: " + code);
        }
    }
}
