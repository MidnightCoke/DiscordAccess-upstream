using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace DiscordAccess
{
    // Synthetic requests and loopback only. No Discord/account or engine access.
    internal static class MediaPolicyChecks
    {
        private const string Authorization = "Basic bWVkaWEtZml4dHVyZTpub3QtYS1zZWNyZXQ=";

        private static void Require(bool value, string message)
        {
            if (!value) throw new InvalidOperationException(message);
        }

        private static string Request(string authority, string host)
        {
            return "CONNECT " + authority + " HTTP/1.1\r\nHost: " + host +
                "\r\nProxy-Authorization: Basic obsolete-fixture\r\n\r\n";
        }

        private static void Accepted(string authority)
        {
            ProcessGate.RequestFailure failure;
            string result = ProcessGate.RewriteHeader(Request(authority, authority), Authorization, out failure);
            Require(failure == ProcessGate.RequestFailure.None, "Accepted media request retained a failure.");
            Require(result.StartsWith("CONNECT " + authority + " HTTP/1.1\r\n", StringComparison.Ordinal),
                "CONNECT destination or port changed.");
            string[] credentials = result.Split(new[] { "\r\n" }, StringSplitOptions.None)
                .Where(line => line.StartsWith("Proxy-Authorization:", StringComparison.OrdinalIgnoreCase)).ToArray();
            Require(credentials.Length == 1 && credentials[0] == "Proxy-Authorization: " + Authorization,
                "Media request did not replace proxy credentials exactly once.");
            Require(!result.Contains("obsolete-fixture"), "Incoming proxy credential survived.");
        }

        private static void Rejected(string request)
        {
            bool rejected = false;
            try { ProcessGate.RewriteHeader(request, Authorization); }
            catch (InvalidDataException) { rejected = true; }
            Require(rejected, "Out-of-policy media request was accepted.");
        }

        // Pass the real asynchronous gate's process admission, parsing and backend
        // connect using the diagnostic test PID. Its untrusted loopback backend
        // must receive zero bytes: the port exception must not bypass identity.
        private static void AdmissionFixture(int mediaPort)
        {
            var backend = new TcpListener(IPAddress.Loopback, 0);
            try
            {
                backend.Start();
                Task<TcpClient> accepted = backend.AcceptTcpClientAsync();
                using (var current = Process.GetCurrentProcess())
                using (var gate = new ProcessGate(current, null, "fixture-unused", null,
                    ((IPEndPoint)backend.LocalEndpoint).Port, "fixture-user", "fixture-password"))
                using (var client = new TcpClient())
                {
                    gate.DiagnosticAllowed = true; gate.Start();
                    Task connection = client.ConnectAsync(IPAddress.Loopback, gate.Port);
                    Require(connection.Wait(4000), "Media gate fixture connect timed out.");
                    connection.GetAwaiter().GetResult();
                    string authority = "c-waw04-9501efbe.discord.media:" + mediaPort;
                    byte[] header = Encoding.ASCII.GetBytes(Request(authority, authority));
                    client.GetStream().Write(header, 0, header.Length);
                    Require(accepted.Wait(4000), "Media request did not reach backend connection after policy.");
                    using (var peer = accepted.GetAwaiter().GetResult())
                    {
                        byte[] one = new byte[1];
                        Task<int> read = peer.GetStream().ReadAsync(one, 0, 1);
                        Require(Task.WhenAny(read, Task.Delay(4000)).GetAwaiter().GetResult() == read,
                            "Untrusted media backend was not closed.");
                        int count;
                        try { count = read.GetAwaiter().GetResult(); }
                        catch (IOException) { count = 0; }
                        Require(count == 0, "Media request or credentials reached an untrusted backend.");
                    }
                }
            }
            finally { backend.Stop(); }
        }

        internal static int Run()
        {
            int checks = 0;
            foreach (string authority in new[] {
                "c-waw04-9501efbe.discord.media:2087", "c-fra07-7cbb2779.discord.media:2087",
                "discord.media:2087", "C-WAW04-9501EFBE.DISCORD.MEDIA:2087", "a.b.discord.media:2087",
                "c-waw05-eaef8be4.discord.media:443", "discord.com:443", "cdn.discordapp.com:443",
                "c-waw04-9501efbe.discord.media:2083", "c-fra07-7cbb2779.discord.media:2096",
                "c-waw04-9501efbe.discord.media:8443", "discord.media:1", "discord.media:80",
                "discord.media:2088", "discord.media:4430", "a.b.discord.media:50000", "discord.media:65535" })
            { Accepted(authority); checks++; }

            foreach (string authority in new[] {
                "discord.com:2087", "cdn.discordapp.com:2087", "gateway.discord.gg:2087", "example.com:2087",
                "discord.media.evil.example:2087", "evildiscord.media:2087", "discord-media:2087",
                ".discord.media:2087", "bad..discord.media:2087", "-bad.discord.media:2087", "bad-.discord.media:2087",
                "discord.media.:2087", new string('a', 64) + ".discord.media:2087",
                "127.0.0.1:2087", "2130706433:2087", "0x7f000001:2087", "[::1]:2087", "[::ffff:127.0.0.1]:2087",
                "user@discord.media:2087", "user:pass@discord.media:2087", "discord.media%2eexample.com:2087",
                "discord.media\\@example.com:2087", "discord.media:2087/path", "discord.media:2087?secret",
                "discord.media:2087#fragment", "discord.media:2087:443", "discord.media:02087", "discord.media:+2087",
                "discord.media:-2087", "discord.media:2.087", "discord.media:0x827",
                "discord.media:0", "discord.media:65536", "discord.media:0443",
                "discord.media:0001", "discord.media:00000", "discord.media:655350", "discord.media:2147483647",
                "discord.media:", "discord.media: 2083", "discord.media:2096\n" })
            { Rejected(Request(authority, authority)); checks++; }

            foreach (string host in ProcessGate.AllowedDomains.Where(value => value != "discord.media"))
                foreach (int port in new[] { 2083, 2096, 8443, 65535 })
                { string authority = host + ":" + port; Rejected(Request(authority, authority)); checks++; }

            Rejected(Request("c-waw04-9501efbe.discord.media:2087", "c-waw04-9501efbe.discord.media:443")); checks++;
            Rejected(Request("c-waw04-9501efbe.discord.media:2087", "evil.example:2087")); checks++;
            Rejected("GET http://discord.media:2087/ HTTP/1.1\r\nHost: discord.media:2087\r\n\r\n"); checks++;
            Rejected("CONNECT discord.media:2087 HTTP/1.1\r\nHost: discord.media:2087\r\nHost: discord.media:2087\r\n\r\n"); checks++;
            string http = ProcessGate.RewriteHeader("GET http://discord.media/ HTTP/1.1\r\nHost: discord.media\r\n\r\n", Authorization);
            Require(http.StartsWith("GET http://discord.media/ HTTP/1.1\r\n", StringComparison.Ordinal), "Existing port 80 policy changed."); checks++;
            const string upload = "discord-attachments-uploads-prd.storage.googleapis.com";
            Accepted(upload + ":443"); checks++;
            Accepted(upload.ToUpperInvariant() + ":443"); checks++;
            foreach (string authority in new[] {
                upload + ":2087", upload + ":80", upload + ":2083", upload + ":2096", upload + ":8443", upload + ":65535",
                "sub." + upload + ":443", upload + ".evil.example:443",
                "evil" + upload + ":443", "storage.googleapis.com:443", "other-bucket.storage.googleapis.com:443",
                "discord-attachments-uploads-prd.storage.googleapis.com.evil:443",
                "discord-attachments-uploads-prd.storage.googleapis.com.:443", "user@" + upload + ":443" })
            { Rejected(Request(authority, authority)); checks++; }
            Rejected("PUT http://" + upload + "/file HTTP/1.1\r\nHost: " + upload + "\r\n\r\n"); checks++;
            Rejected("PUT http://" + upload + ":443/file HTTP/1.1\r\nHost: " + upload + ":443\r\n\r\n"); checks++;
            Rejected(Request(upload + ":443", "other-bucket.storage.googleapis.com:443")); checks++;
            foreach (string authority in new[] { "hcaptcha.com:443", "js.hcaptcha.com:443", "newassets.hcaptcha.com:443",
                "a.b.hcaptcha.com:443", "JS.HCAPTCHA.COM:443" })
            { Accepted(authority); checks++; }
            foreach (string authority in new[] {
                "hcaptcha.com:80", "js.hcaptcha.com:80", "js.hcaptcha.com:2083", "js.hcaptcha.com:2087",
                "js.hcaptcha.com:2096", "js.hcaptcha.com:8443", "js.hcaptcha.com:65535", "js.hcaptcha.com:0443",
                "hcaptcha.com.evil.example:443", "evilhcaptcha.com:443", "hcaptcha-com:443", "captcha.com:443",
                "hcaptcha.com.:443", ".hcaptcha.com:443", "bad..hcaptcha.com:443", "-bad.hcaptcha.com:443",
                "bad-.hcaptcha.com:443", new string('a', 64) + ".hcaptcha.com:443", "user@hcaptcha.com:443",
                "hcaptcha.com%2eevil.example:443", "hcaptcha.com\\@evil.example:443", "hcaptcha.com:443/path" })
            { Rejected(Request(authority, authority)); checks++; }
            foreach (string host in new[] { "hcaptcha.com", "js.hcaptcha.com" })
            {
                Rejected("GET http://" + host + "/ HTTP/1.1\r\nHost: " + host + "\r\n\r\n"); checks++;
                Rejected("GET http://" + host + ":443/ HTTP/1.1\r\nHost: " + host + ":443\r\n\r\n"); checks++;
            }
            Rejected(Request("js.hcaptcha.com:443", "hcaptcha.com:443")); checks++;
            Rejected(Request("js.hcaptcha.com:443", "js.hcaptcha.com:80")); checks++;
            Rejected(Request("js.hcaptcha.com:443", "evil.example:443")); checks++;
            foreach (int port in new[] { 2083, 2087, 2096, 8443 })
            { AdmissionFixture(port); checks++; }
            return checks;
        }
    }
}
