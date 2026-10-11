using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace DiscordAccess
{
    internal sealed class AttachmentDownloadException : Exception
    {
        internal AttachmentDownloadException(string message) : base(message) { }
    }

    // Only user-supplied Discord attachment URLs are fetched. No account state,
    // clipboard monitoring, browser settings, or global network settings are used.
    internal static class AttachmentDownloader
    {
        private const int TotalTimeoutMilliseconds = 15 * 60 * 1000;
        private const int IdleTimeoutMilliseconds = 30000;
        private const int MaximumRedirects = 3;

        internal sealed class Response : IDisposable
        {
            internal int Status;
            internal long Length;
            internal string Location;
            internal string RetryAfter;
            internal Stream Body;
            internal IDisposable Owner;
            internal CancellationTokenRegistration Abort;
            public void Dispose()
            {
                try { if (Body != null) Body.Dispose(); }
                finally { try { if (Owner != null) Owner.Dispose(); } finally { Abort.Dispose(); } }
            }
        }

        internal static Uri ValidateLink(string link)
        {
            const string message = "Yalnızca Discord ek dosyasının HTTPS bağlantısı kabul edilir. Discord'da bağlantıyı kopyalayıp yeniden yapıştırın.";
            if (String.IsNullOrEmpty(link) || link.Length > 8192 || link != link.Trim() ||
                Regex.IsMatch(link, @"[\x00-\x20\x7f\\]")) throw new AttachmentDownloadException(message);
            if (!Regex.IsMatch(link, @"\Ahttps://(?:cdn\.discordapp\.com|media\.discordapp\.net)(?::443)?/", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                throw new AttachmentDownloadException(message);
            Uri uri;
            if (!Uri.TryCreate(link, UriKind.Absolute, out uri) || uri.Scheme != Uri.UriSchemeHttps || uri.Port != 443 ||
                !String.IsNullOrEmpty(uri.UserInfo) || !String.IsNullOrEmpty(uri.Fragment) ||
                !(String.Equals(uri.Host, "cdn.discordapp.com", StringComparison.OrdinalIgnoreCase) ||
                  String.Equals(uri.Host, "media.discordapp.net", StringComparison.OrdinalIgnoreCase)))
                throw new AttachmentDownloadException(message);
            // Validate the original escaped path too: Uri normalizes dot segments.
            int authorityEnd = link.IndexOf('/', link.IndexOf("://", StringComparison.Ordinal) + 3);
            if (authorityEnd < 0) throw new AttachmentDownloadException(message);
            int queryStart = link.IndexOf('?', authorityEnd);
            string path = queryStart < 0 ? link.Substring(authorityEnd) : link.Substring(authorityEnd, queryStart - authorityEnd);
            if (!Regex.IsMatch(path, @"\A/(?:attachments|ephemeral-attachments)/[0-9]{1,22}/[0-9]{1,22}/[^/?#]+\z") ||
                Regex.IsMatch(path, @"%(?![0-9a-fA-F]{2})")) throw new AttachmentDownloadException(message);
            string decoded;
            try { decoded = Uri.UnescapeDataString(path.Substring(path.LastIndexOf('/') + 1)); }
            catch { throw new AttachmentDownloadException(message); }
            if (decoded == "." || decoded == ".." || Regex.IsMatch(decoded, @"[\x00-\x1f\x7f/\\]") ||
                Regex.IsMatch(decoded, @"%(?:2f|5c|00|0a|0d)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                throw new AttachmentDownloadException(message);
            return uri;
        }

        internal static string SuggestedName(Uri uri)
        {
            uri = ValidateLink(uri == null ? null : uri.OriginalString);
            string name = Uri.UnescapeDataString(uri.AbsolutePath.Substring(uri.AbsolutePath.LastIndexOf('/') + 1));
            name = Regex.Replace(name, "[<>:\"/\\\\|?*\\x00-\\x1f\\x7f]", "_").Trim().TrimEnd('.', ' ');
            if (name.Length > 160) name = name.Substring(0, 160).TrimEnd('.', ' ');
            if (String.IsNullOrWhiteSpace(name)) name = "Discord-dosyasi";
            if (IsDeviceName(name)) name = "_" + name;
            return name;
        }

        private static bool IsDeviceName(string name)
        {
            return Regex.IsMatch(name, @"\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }

        internal static HttpWebRequest CreateRequest(Uri uri, int proxyPort)
        {
            uri = ValidateLink(uri == null ? null : uri.OriginalString);
            if (proxyPort < 1 || proxyPort > 65535) throw new AttachmentDownloadException("Önce DiscordAccess bağlantısını başlatın.");
            var request = (HttpWebRequest)WebRequest.Create(uri);
            request.Proxy = new WebProxy(new Uri("http://127.0.0.1:" + proxyPort), false);
            request.AllowAutoRedirect = false;
            request.Credentials = null;
            request.UseDefaultCredentials = false;
            request.PreAuthenticate = false;
            request.CookieContainer = null;
            request.Method = "GET";
            request.Timeout = IdleTimeoutMilliseconds;
            request.ReadWriteTimeout = IdleTimeoutMilliseconds;
            request.KeepAlive = false;
            request.AutomaticDecompression = DecompressionMethods.None;
            request.UserAgent = "DiscordAccess/3 (attachment download)";
            return request;
        }

        private static async Task<Response> FetchAsync(Uri uri, int proxyPort, CancellationToken token)
        {
            var request = CreateRequest(uri, proxyPort);
            var registration = token.Register(request.Abort);
            HttpWebResponse response = null;
            try
            {
                try { response = (HttpWebResponse)await request.GetResponseAsync().ConfigureAwait(false); }
                catch (WebException ex) { response = ex.Response as HttpWebResponse; if (response == null) throw; }
                return new Response { Status = (int)response.StatusCode, Length = response.ContentLength,
                    Location = response.Headers[HttpResponseHeader.Location], Body = response.GetResponseStream(),
                    RetryAfter = response.Headers[HttpResponseHeader.RetryAfter],
                    Owner = response, Abort = registration };
            }
            catch { if (response != null) response.Dispose(); registration.Dispose(); throw; }
        }

        internal static Task<long> DownloadAsync(string link, string destination, int proxyPort, CancellationToken token, IProgress<long> progress)
        {
            return DownloadCoreAsync(link, destination, proxyPort, token, progress, FetchAsync, MarkInternetFile);
        }

        internal static int? RetryAfterSeconds(string value, DateTimeOffset now)
        {
            // Interpret only a small, bounded wait estimate. The raw header is
            // never displayed, logged, used as a URL, or used to schedule retries.
            if (String.IsNullOrEmpty(value) || value.Length > 128) return null;
            value = value.Trim(' ', '\t');
            if (Regex.IsMatch(value, @"[\x00-\x1f\x7f]")) return null;
            double seconds;
            if (Regex.IsMatch(value, @"\A[0-9]+(?:\.[0-9]+)?\z"))
            {
                if (!Double.TryParse(value, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out seconds)) return null;
            }
            else
            {
                DateTimeOffset date;
                if (!DateTimeOffset.TryParseExact(value, "r", CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out date)) return null;
                seconds = (date - now).TotalSeconds;
            }
            if (Double.IsNaN(seconds) || Double.IsInfinity(seconds) || seconds <= 0 || seconds > 86400) return null;
            return (int)Math.Ceiling(seconds);
        }

        private static string RateLimitMessage(string retryAfter)
        {
            int? seconds = RetryAfterSeconds(retryAfter, DateTimeOffset.UtcNow);
            return "İndirme sunucusu istek sınırı uyguluyor (HTTP 429). " +
                (seconds.HasValue ? "Yaklaşık " + seconds.Value.ToString(CultureInfo.InvariantCulture) + " saniye bekleyip yeniden deneyin." :
                    "Bir süre bekleyip yeniden deneyin.") + " Otomatik tekrar yapılmadı.";
        }

        // Injectable only within this assembly so tests never contact remote hosts.
        internal static async Task<long> DownloadCoreAsync(string link, string destination, int proxyPort, CancellationToken token,
            IProgress<long> progress, Func<Uri, int, CancellationToken, Task<Response>> fetch, Action<string> markInternetFile)
        {
            string temporary = null;
            bool temporaryOwned = false;
            try
            {
                Uri uri = ValidateLink(link);
                if (proxyPort < 1 || proxyPort > 65535) throw new AttachmentDownloadException("Önce DiscordAccess bağlantısını başlatın.");
                if (String.IsNullOrWhiteSpace(destination)) throw new AttachmentDownloadException("Kaydedilecek dosya konumu seçilmedi.");
                string finalPath = Path.GetFullPath(destination);
                string directory = Path.GetDirectoryName(finalPath);
                if (!Directory.Exists(directory)) throw new AttachmentDownloadException("Seçilen kayıt klasörü bulunamadı.");
                if (File.Exists(finalPath) || Directory.Exists(finalPath)) throw new AttachmentDownloadException("Bu adla bir dosya zaten var. Farklı bir ad seçin.");
                // ADS paths cannot be selected as output files.
                string finalName = Path.GetFileName(finalPath);
                if (finalName.IndexOf(':') >= 0 || IsDeviceName(finalName.TrimEnd('.', ' ')) || finalName != finalName.TrimEnd('.', ' '))
                    throw new AttachmentDownloadException("Geçerli bir dosya adı seçin.");
                token.ThrowIfCancellationRequested();
                using (var total = CancellationTokenSource.CreateLinkedTokenSource(token))
                using (var idle = CancellationTokenSource.CreateLinkedTokenSource(total.Token))
                {
                    total.CancelAfter(TotalTimeoutMilliseconds);
                    Uri current = uri;
                    for (int redirects = 0; ; redirects++)
                    {
                        idle.CancelAfter(IdleTimeoutMilliseconds);
                        using (Response response = await fetch(current, proxyPort, idle.Token).ConfigureAwait(false))
                        {
                            idle.Token.ThrowIfCancellationRequested();
                            if (response == null) throw new AttachmentDownloadException("İndirme sunucusundan yanıt alınamadı.");
                            if (response.Status == 301 || response.Status == 302 || response.Status == 303 || response.Status == 307 || response.Status == 308)
                            {
                                if (redirects >= MaximumRedirects) throw new AttachmentDownloadException("İndirme sunucusu çok fazla yönlendirme döndürdü.");
                                if (String.IsNullOrWhiteSpace(response.Location) || response.Location.Length > 8192 || Regex.IsMatch(response.Location, @"[\x00-\x20\x7f\\]"))
                                    throw new AttachmentDownloadException("Dosya indirme yönlendirmesi doğrulanamadı.");
                                Uri redirect;
                                if (!Uri.TryCreate(current, response.Location, out redirect)) throw new AttachmentDownloadException("Dosya indirme yönlendirmesi doğrulanamadı.");
                                current = ValidateLink(redirect.OriginalString);
                                continue;
                            }
                            if (response.Status == 429) throw new AttachmentDownloadException(RateLimitMessage(response.RetryAfter));
                            if (response.Status != 200) throw new AttachmentDownloadException("Dosya indirilemedi (HTTP " + response.Status + "). Discord'dan yeni dosya bağlantısını kopyalayın.");
                            if (response.Body == null || response.Length < -1) throw new AttachmentDownloadException("İndirme yanıtı doğrulanamadı.");
                            temporary = Path.Combine(directory, ".DiscordAccess-" + Guid.NewGuid().ToString("N") + ".part");
                            long received = 0;
                            var progressClock = Stopwatch.StartNew();
                            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
                            using (idle.Token.Register(response.Body.Dispose))
                            {
                                temporaryOwned = true;
                                byte[] buffer = new byte[65536];
                                while (true)
                                {
                                    idle.CancelAfter(IdleTimeoutMilliseconds);
                                    int count = await response.Body.ReadAsync(buffer, 0, buffer.Length, idle.Token).ConfigureAwait(false);
                                    idle.Token.ThrowIfCancellationRequested();
                                    if (count == 0) break;
                                    if (response.Length >= 0 && received > response.Length - count) throw new AttachmentDownloadException("Dosya boyutu sunucu yanıtıyla eşleşmedi. İndirme tamamlanmadı.");
                                    await output.WriteAsync(buffer, 0, count, idle.Token).ConfigureAwait(false);
                                    received = checked(received + count);
                                    if (progress != null && progressClock.ElapsedMilliseconds >= 250)
                                    { progress.Report(received); progressClock.Restart(); }
                                }
                                if (response.Length >= 0 && received != response.Length) throw new AttachmentDownloadException("Dosya eksik geldi. İndirme tamamlanmadı.");
                                await output.FlushAsync(idle.Token).ConfigureAwait(false);
                            }
                            idle.Token.ThrowIfCancellationRequested();
                            markInternetFile(temporary);
                            idle.Token.ThrowIfCancellationRequested();
                            File.Move(temporary, finalPath);
                            temporary = null;
                            temporaryOwned = false;
                            if (progress != null) { try { progress.Report(received); } catch { } }
                            return received;
                        }
                    }
                }
            }
            catch (AttachmentDownloadException) { throw; }
            catch (Exception)
            {
                if (token.IsCancellationRequested) throw new OperationCanceledException(token);
                throw new AttachmentDownloadException("Dosya indirilemedi. Bağlantı veya disk erişimi kesilmiş ya da süre dolmuş olabilir. Discord'dan yeni bağlantıyı kopyalayıp tekrar deneyin.");
            }
            finally
            {
                if (temporaryOwned && temporary != null) { try { File.Delete(temporary); } catch { } }
            }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string path, uint access, uint sharing,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        internal static FileStream OpenZoneStream(string path, bool write)
        {
            var handle = CreateFile(path + ":Zone.Identifier", write ? 0x40000000U : 0x80000000U, 0, IntPtr.Zero, write ? 2U : 3U, 0, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Internet zone stream unavailable."); }
            try { return new FileStream(handle, write ? FileAccess.Write : FileAccess.Read); }
            catch { handle.Dispose(); throw; }
        }

        internal static void MarkInternetFile(string path)
        {
            // Preserve Windows' downloaded-file security checks. FAT/exFAT do
            // not support alternate data streams; do not invent a sidecar there.
            string format = null;
            try { format = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))).DriveFormat; } catch { }
            if (String.Equals(format, "FAT", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(format, "FAT32", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(format, "exFAT", StringComparison.OrdinalIgnoreCase)) return;
            try
            {
                using (var zone = OpenZoneStream(path, true))
                {
                    byte[] bytes = Encoding.ASCII.GetBytes("[ZoneTransfer]\r\nZoneId=3\r\n");
                    zone.Write(bytes, 0, bytes.Length);
                    zone.Flush();
                }
            }
            catch { throw new AttachmentDownloadException("Dosyanın Windows internet güvenlik işareti kaydedilemedi. Başka bir kayıt klasörü seçin."); }
        }
    }
}
