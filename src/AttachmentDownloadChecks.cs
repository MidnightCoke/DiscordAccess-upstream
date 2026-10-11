using System;
using System.IO;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DiscordAccess
{
    internal static class AttachmentDownloadChecks
    {
        private const string Link = "https://cdn.discordapp.com/attachments/123/456/fixture%20name.txt?ex=synthetic&is=test&hm=a%2Bb%2Fc";
        private static void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }
        private static void Rejected(string link)
        {
            try { AttachmentDownloader.ValidateLink(link); }
            catch (AttachmentDownloadException ex) { Require(String.IsNullOrEmpty(link) || !ex.Message.Contains(link), "URL leaked in validation error."); return; }
            throw new InvalidOperationException("Invalid attachment URL accepted.");
        }
        private static AttachmentDownloader.Response Body(string text, long length)
        {
            return new AttachmentDownloader.Response { Status = 200, Length = length, Body = new MemoryStream(Encoding.UTF8.GetBytes(text)) };
        }
        private static long Download(string link, string file, CancellationToken token,
            Func<Uri, int, CancellationToken, Task<AttachmentDownloader.Response>> fetch, Action<string> mark)
        {
            return AttachmentDownloader.DownloadCoreAsync(link, file, 43210, token, null, fetch, mark).GetAwaiter().GetResult();
        }
        private static void MustFail(Action action, string destination, string fixture)
        {
            bool failed = false;
            try { action(); }
            catch (AttachmentDownloadException ex)
            {
                failed = true;
                Require(!ex.ToString().Contains("synthetic") && !ex.ToString().Contains("sensitive-fixture"), "Response URL or raw exception leaked.");
            }
            Require(failed, "Faulty download was accepted.");
            Require(!File.Exists(destination), "Faulty download produced final file.");
            Require(!Directory.GetFiles(fixture, ".DiscordAccess-*.part").Any(), "Faulty download left partial file.");
        }
        private sealed class CancelingStream : MemoryStream
        {
            private readonly CancellationTokenSource cancellation;
            internal CancelingStream(CancellationTokenSource cancellation) : base(Encoding.ASCII.GetBytes("fixture")) { this.cancellation = cancellation; }
            public override Task<int> ReadAsync(byte[] bytes, int offset, int count, CancellationToken token)
            {
                int received = Read(bytes, offset, count);
                cancellation.Cancel();
                return Task.FromResult(received);
            }
        }

        private static void FixedProxyFixture(string destination)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            using (var cancellation = new CancellationTokenSource(5000))
            {
                Task<long> download = null;
                try
                {
                    listener.Start();
                    Task<TcpClient> accepting = listener.AcceptTcpClientAsync();
                    download = AttachmentDownloader.DownloadAsync(Link, destination, ((IPEndPoint)listener.LocalEndpoint).Port, cancellation.Token, null);
                    Require(accepting.Wait(4000), "Download did not connect to its explicit local proxy.");
                    using (TcpClient peer = accepting.GetAwaiter().GetResult())
                    {
                        NetworkStream stream = peer.GetStream();
                        var header = new StringBuilder();
                        byte[] bytes = new byte[1024];
                        while (header.ToString().IndexOf("\r\n\r\n", StringComparison.Ordinal) < 0 && header.Length < 16384)
                        {
                            Task<int> reading = stream.ReadAsync(bytes, 0, bytes.Length);
                            Require(reading.Wait(4000), "Attachment proxy CONNECT header stalled.");
                            int read = reading.GetAwaiter().GetResult();
                            Require(read > 0, "Attachment proxy CONNECT header was empty.");
                            header.Append(Encoding.ASCII.GetString(bytes, 0, read));
                        }
                        string request = header.ToString();
                        Require(request.StartsWith("CONNECT cdn.discordapp.com:443 HTTP/", StringComparison.Ordinal) &&
                            request.IndexOf("Authorization:", StringComparison.OrdinalIgnoreCase) < 0 &&
                            request.IndexOf("Cookie:", StringComparison.OrdinalIgnoreCase) < 0 &&
                            !request.Contains("synthetic"), "Attachment CONNECT leaked credentials or URL query.");
                        byte[] refused = Encoding.ASCII.GetBytes("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                        stream.Write(refused, 0, refused.Length);
                    }
                    bool failed = false;
                    try { download.GetAwaiter().GetResult(); }
                    catch (AttachmentDownloadException) { failed = true; }
                    Require(failed && !File.Exists(destination), "Proxy refusal was ignored or saved as a file.");
                    Require(!listener.Pending(), "Attachment downloader retried a refused proxy unexpectedly.");
                }
                finally
                {
                    cancellation.Cancel(); listener.Stop();
                    if (download != null) { try { download.GetAwaiter().GetResult(); } catch { } }
                }
            }
        }

        internal static int Run(string fixtureRoot)
        {
            int checks = 0;
            foreach (string good in new[] { Link, "https://media.discordapp.net/attachments/1/2/file.png?format=webp", "HTTPS://CDN.DISCORDAPP.COM:443/attachments/1/2/f",
                "https://cdn.discordapp.com/ephemeral-attachments/1/2/f?hm=fixture", "https://media.discordapp.net/ephemeral-attachments/1/2/f" })
            { Require(AttachmentDownloader.ValidateLink(good).OriginalString == good, "Attachment URL was changed."); checks++; }
            foreach (string bad in new[] {
                "", null, "http://cdn.discordapp.com/attachments/1/2/f", "https://cdn.discordapp.com:8443/attachments/1/2/f",
                "https://cdn.discordapp.com.evil.example/attachments/1/2/f", "https://a.cdn.discordapp.com/attachments/1/2/f",
                "https://user@cdn.discordapp.com/attachments/1/2/f", "https://cdn.discordapp.com/attachments/1/2/f#x",
                "https://cdn.discordapp.com/attachments/1/2/../f", "https://cdn.discordapp.com/attachments/1/2/%2e%2e",
                "https://cdn.discordapp.com/attachments/1/2/%2fsecret", "https://cdn.discordapp.com/attachments/1/2/%5csecret",
                "https://cdn.discordapp.com/attachments/1/2/%252fsecret", "https://cdn.discordapp.com/attachments/1/2/%0dsecret",
                "https://cdn.discordapp.com/attachments/a/2/f", "https://cdn.discordapp.com/attachments/1/2/",
                "https://cdn.discordapp.com/not-attachments/1/2/f", "https://cdn.discordapp.com/attachments/1/2/f\\evil",
                "https://cdn.discordapp.com?x=/attachments/1/2/f", "https://cdn.discordapp.com/attachments/1/2/%broken",
                Link + "\r\nHeader: value", Link + new string('x', 8193) })
            { Rejected(bad); checks++; }
            Require(AttachmentDownloader.SuggestedName(new Uri(Link)) == "fixture name.txt", "Filename percent decode failed."); checks++;
            Require(AttachmentDownloader.SuggestedName(new Uri("https://cdn.discordapp.com/attachments/1/2/CON.txt")) == "_CON.txt", "Device filename accepted."); checks++;
            Require(AttachmentDownloader.SuggestedName(new Uri("https://cdn.discordapp.com/attachments/1/2/file%3Astream.txt")) == "file_stream.txt", "ADS filename accepted."); checks++;
            var request = AttachmentDownloader.CreateRequest(new Uri(Link), 43210);
            var proxy = request.Proxy as WebProxy;
            Require(proxy != null && proxy.Address.AbsoluteUri == "http://127.0.0.1:43210/" && !proxy.BypassProxyOnLocal &&
                !proxy.IsBypassed(new Uri(Link)) && proxy.Credentials == null, "Download did not force fixed uncredentialed proxy."); checks++;
            Require(!request.AllowAutoRedirect && !request.UseDefaultCredentials && request.Credentials == null &&
                request.CookieContainer == null && !request.PreAuthenticate && request.Method == "GET", "Download request includes account/default state."); checks++;
            Require(request.RequestUri.Query == new Uri(Link).Query && request.RequestUri.OriginalString == Link, "Signed query modified."); checks++;
            request.Abort();

            DateTimeOffset rateLimitNow = new DateTimeOffset(2026, 10, 10, 12, 0, 0, TimeSpan.Zero);
            foreach (var value in new[] { new { Header = "5", Seconds = 5 }, new { Header = "0.1", Seconds = 1 },
                new { Header = " 12.25 ", Seconds = 13 }, new { Header = "86400", Seconds = 86400 } })
            { Require(AttachmentDownloader.RetryAfterSeconds(value.Header, rateLimitNow) == value.Seconds, "Retry-After numeric estimate failed."); checks++; }
            Require(AttachmentDownloader.RetryAfterSeconds(rateLimitNow.AddSeconds(45).ToString("r", CultureInfo.InvariantCulture), rateLimitNow) == 45,
                "Retry-After HTTP date estimate failed."); checks++;
            foreach (string bad in new[] { null, "", "0", "-1", "+5", "NaN", "Infinity", "1e6", "86401", "1,5", "1\r\nsecret", "sensitive-fixture",
                new string('9', 129), rateLimitNow.AddSeconds(-1).ToString("r", CultureInfo.InvariantCulture), rateLimitNow.AddDays(2).ToString("r", CultureInfo.InvariantCulture) })
            { Require(!AttachmentDownloader.RetryAfterSeconds(bad, rateLimitNow).HasValue, "Malformed or unbounded Retry-After accepted."); checks++; }

            string fixture = Path.Combine(Path.GetFullPath(fixtureRoot), "download-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(fixture);
            try
            {
                string destination = Path.Combine(fixture, "saved.txt");
                int calls = 0, marks = 0;
                long size = Download(Link, destination, CancellationToken.None, delegate(Uri uri, int port, CancellationToken token)
                {
                    calls++; Require(uri.OriginalString == Link && port == 43210, "Fetch changed signed URL or proxy.");
                    return Task.FromResult(Body("hello", 5));
                }, delegate(string partial) { marks++; Require(File.Exists(partial) && !File.Exists(destination), "Zone mark occurred after publication."); });
                Require(size == 5 && File.ReadAllText(destination) == "hello" && calls == 1 && marks == 1, "Successful streaming download failed."); checks++;
                bool existingRejected = false;
                try { Download(Link, destination, CancellationToken.None, delegate { throw new InvalidOperationException("should not fetch"); }, delegate { }); }
                catch (AttachmentDownloadException) { existingRejected = true; }
                Require(existingRejected && File.ReadAllText(destination) == "hello", "Existing destination overwritten."); checks++;

                string redirectDestination = Path.Combine(fixture, "redirect.txt");
                calls = 0;
                string redirected = "https://media.discordapp.net/attachments/1/2/f?hm=preserve%2Bthis";
                Download(Link, redirectDestination, CancellationToken.None, delegate(Uri uri, int port, CancellationToken token)
                {
                    calls++;
                    if (calls == 1) return Task.FromResult(new AttachmentDownloader.Response { Status = 302, Location = redirected });
                    Require(uri.OriginalString == redirected, "Redirect query changed.");
                    return Task.FromResult(Body("ok", -1));
                }, delegate { });
                Require(calls == 2 && File.ReadAllText(redirectDestination) == "ok", "Allowed redirect or unknown-length stream failed."); checks++;

                string badDestination = Path.Combine(fixture, "bad.txt");
                FixedProxyFixture(badDestination); checks++;
                calls = 0;
                MustFail(delegate { Download(Link, badDestination, CancellationToken.None, delegate
                { calls++; return Task.FromResult(new AttachmentDownloader.Response { Status = 302, Location = "https://example.com/attachments/1/2/f?token=sensitive-fixture" }); }, delegate { }); }, badDestination, fixture);
                Require(calls == 1, "Forbidden redirect was fetched."); checks++;
                calls = 0;
                MustFail(delegate { Download(Link, badDestination, CancellationToken.None, delegate
                { calls++; return Task.FromResult(new AttachmentDownloader.Response { Status = 307, Location = Link }); }, delegate { }); }, badDestination, fixture);
                Require(calls == 4, "Redirect limit failed."); checks++;
                MustFail(delegate { Download(Link, badDestination, CancellationToken.None, delegate
                { return Task.FromResult(new AttachmentDownloader.Response { Status = 403, Body = new MemoryStream(Encoding.ASCII.GetBytes("sensitive-fixture")) }); }, delegate { }); }, badDestination, fixture); checks++;
                foreach (string retryAfter in new[] { "12.25", null, "sensitive-fixture", DateTimeOffset.UtcNow.AddMinutes(2).ToString("r", CultureInfo.InvariantCulture) })
                {
                    calls = 0; string rateLimitMessage = null;
                    MustFail(delegate
                    {
                        try { Download(Link, badDestination, CancellationToken.None, delegate
                            { calls++; return Task.FromResult(new AttachmentDownloader.Response { Status = 429, RetryAfter = retryAfter,
                                Body = new MemoryStream(Encoding.ASCII.GetBytes("sensitive-fixture")) }); }, delegate { }); }
                        catch (AttachmentDownloadException error) { rateLimitMessage = error.Message; throw; }
                    }, badDestination, fixture);
                    Require(calls == 1 && rateLimitMessage != null && rateLimitMessage.Contains("HTTP 429") && rateLimitMessage.Contains("bekleyip yeniden deneyin") &&
                        !rateLimitMessage.Contains("yeni dosya bağlantısı") && !rateLimitMessage.Contains("sensitive-fixture"),
                        "Rate limit retried, exposed data, or was misreported as an expired attachment.");
                    if (retryAfter == "12.25") Require(rateLimitMessage.Contains("13 saniye"), "Rate-limit wait was not rounded up.");
                    if (retryAfter == null || retryAfter == "sensitive-fixture") Require(!rateLimitMessage.Contains("saniye"), "Unknown wait received a fabricated estimate.");
                    checks++;
                }
                using (var cancellation = new CancellationTokenSource())
                {
                    calls = 0; bool canceled = false;
                    try { Download(Link, badDestination, cancellation.Token, delegate
                        { calls++; cancellation.Cancel(); return Task.FromResult(new AttachmentDownloader.Response { Status = 429, RetryAfter = "30" }); }, delegate { }); }
                    catch (OperationCanceledException) { canceled = true; }
                    Require(canceled && calls == 1 && !File.Exists(badDestination) && !Directory.GetFiles(fixture, ".DiscordAccess-*.part").Any(),
                        "Cancellation was masked by a rate-limit response or caused another fetch."); checks++;
                }
                MustFail(delegate { Download(Link, badDestination, CancellationToken.None, delegate { return Task.FromResult(Body("short", 8)); }, delegate { }); }, badDestination, fixture); checks++;
                MustFail(delegate { Download(Link, badDestination, CancellationToken.None, delegate { return Task.FromResult(Body("too-long", 2)); }, delegate { }); }, badDestination, fixture); checks++;
                MustFail(delegate { Download(Link, badDestination, CancellationToken.None, delegate { throw new IOException("sensitive-fixture"); }, delegate { }); }, badDestination, fixture); checks++;
                MustFail(delegate { Download(Link, badDestination, CancellationToken.None, delegate { return Task.FromResult(Body("test", 4)); }, delegate { throw new IOException("sensitive-fixture"); }); }, badDestination, fixture); checks++;

                using (var cancellation = new CancellationTokenSource())
                {
                    bool canceled = false;
                    try { Download(Link, badDestination, cancellation.Token, delegate
                        { return Task.FromResult(new AttachmentDownloader.Response { Status = 200, Length = 7, Body = new CancelingStream(cancellation) }); }, delegate { }); }
                    catch (OperationCanceledException) { canceled = true; }
                    Require(canceled && !File.Exists(badDestination) && !Directory.GetFiles(fixture, ".DiscordAccess-*.part").Any(), "Cancellation left output or was not reported."); checks++;
                }
                using (var cancellation = new CancellationTokenSource())
                {
                    cancellation.Cancel(); bool canceled = false; calls = 0;
                    try { Download(Link, badDestination, cancellation.Token, delegate { calls++; return Task.FromResult(Body("test", 4)); }, delegate { }); }
                    catch (OperationCanceledException) { canceled = true; }
                    Require(canceled && calls == 0, "Pre-cancellation still fetched data."); checks++;
                }
                // Exercise real Zone.Identifier persistence on the host fixture disk.
                string format = new DriveInfo(Path.GetPathRoot(fixture)).DriveFormat;
                if (String.Equals(format, "NTFS", StringComparison.OrdinalIgnoreCase))
                {
                    AttachmentDownloader.MarkInternetFile(destination);
                    using (var zone = AttachmentDownloader.OpenZoneStream(destination, false))
                    using (var reader = new StreamReader(zone))
                        Require(reader.ReadToEnd().Contains("ZoneId=3"), "Downloaded-file security zone was not persisted."); checks++;
                }
            }
            finally
            {
                // Only our named, direct fixture files are removed; no recursion.
                foreach (string file in Directory.GetFiles(fixture)) File.Delete(file);
                Directory.Delete(fixture);
            }
            return checks;
        }
    }
}
