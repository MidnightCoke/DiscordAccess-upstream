using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace DiscordAccess
{
    internal static class MessageReport
    {
        private const int MaximumBytes = 256 * 1024;
        private const string Prefix = " [DiscordAccessMessages v4.7] ";
        private const string Heading = "Mesaj tanısı v4.7 — yalnızca yerel kayıt; M komutu ağ isteği göndermez.";
        private static readonly HashSet<string> NetworkCodes = new HashSet<string>(new[] {
            "ERR_ABORTED", "ERR_TIMED_OUT", "ERR_CONNECTION_TIMED_OUT", "ERR_CONNECTION_CLOSED",
            "ERR_CONNECTION_RESET", "ERR_CONNECTION_REFUSED", "ERR_CONNECTION_ABORTED", "ERR_CONNECTION_FAILED",
            "ERR_NAME_NOT_RESOLVED", "ERR_NAME_RESOLUTION_FAILED", "ERR_INTERNET_DISCONNECTED", "ERR_NETWORK_CHANGED",
            "ERR_ADDRESS_UNREACHABLE", "ERR_PROXY_CONNECTION_FAILED", "ERR_TUNNEL_CONNECTION_FAILED",
            "ERR_PROXY_AUTH_REQUESTED", "ERR_NO_SUPPORTED_PROXIES", "ERR_SSL_PROTOCOL_ERROR",
            "ERR_CERT_AUTHORITY_INVALID", "ERR_CERT_DATE_INVALID", "ERR_CERT_COMMON_NAME_INVALID",
            "ERR_HTTP2_PROTOCOL_ERROR", "ERR_HTTP2_PING_FAILED", "ERR_QUIC_PROTOCOL_ERROR", "ERR_EMPTY_RESPONSE",
            "ERR_FAILED", "ERR_BLOCKED_BY_CLIENT", "ERR_BLOCKED_BY_RESPONSE", "ERR_INSUFFICIENT_RESOURCES", "ERR_OTHER"
        }, StringComparer.Ordinal);

        private sealed class Entry
        {
            internal DateTimeOffset Time;
            internal string Event, Code, Scope, Global, ContentType;
            internal int Status, RetryAfter = -1, Elapsed = -1;
            internal bool Canceled, Challenge;
        }

        // stateRoot is Safety.StateRoot, not an arbitrary log filename. The only
        // file opened is v3/message-network.log. No account or engine data is read.
        internal static string Read(string stateRoot)
        {
            try
            {
                if (String.IsNullOrWhiteSpace(stateRoot)) return Unavailable();
                string root = Path.GetFullPath(stateRoot);
                // Do not let a diagnostic command initiate a UNC/network read,
                // use an alternate data stream, or follow a reparse point.
                if (root.Length < 3 || !Char.IsLetter(root[0]) || root[1] != ':' || root[2] != '\\' ||
                    root.IndexOf(':', 2) >= 0 || !Safety.NoReparse(root)) return Unavailable();
                string path = Path.GetFullPath(Path.Combine(root, "v3", "message-network.log"));
                if (!Safety.Under(path, root) || !Safety.NoReparse(path)) return Unavailable();
                if (!File.Exists(path)) return Heading + Environment.NewLine +
                    "Mesaj tanı kaydı henüz yok. v4.7 ile Discord'u açın, sorunlu sohbeti seçin ve M komutunu yeniden çalıştırın.";
                byte[] data;
                bool tail;
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan))
                {
                    if (!Safety.NoReparse(path) || !String.Equals(path, NativeFile.FinalPath(stream.SafeFileHandle), StringComparison.OrdinalIgnoreCase))
                        return Unavailable();
                    long length = stream.Length;
                    int wanted = (int)Math.Min(length, MaximumBytes);
                    tail = length > wanted;
                    stream.Position = length - wanted;
                    data = new byte[wanted];
                    int read = 0;
                    while (read < wanted)
                    {
                        int count = stream.Read(data, read, wanted - read);
                        if (count == 0) break;
                        read += count;
                    }
                    if (read != wanted) Array.Resize(ref data, read);
                }
                int start = 0, end = data.Length;
                if (tail)
                {
                    while (start < end && data[start] != 10) start++;
                    if (start < end) start++;
                }
                // A concurrent writer may have appended only part of its last
                // line. Never interpret or display that incomplete record.
                while (end > start && data[end - 1] != 10) end--;
                string text = new UTF8Encoding(false, true).GetString(data, start, end - start);
                return Summarize(text.TrimStart('\uFEFF'), tail);
            }
            catch { return Unavailable(); }
        }

        private static string Unavailable()
        {
            return Heading + Environment.NewLine + "Mesaj tanı kaydı güvenli biçimde okunamadı. Ağ veya hesap bilgisi sorgulanmadı.";
        }

        private static bool Number(string value, int maximum, out int number)
        {
            number = 0;
            return !String.IsNullOrEmpty(value) && value.Length <= 10 && value.All(c => c >= '0' && c <= '9') &&
                Int32.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out number) && number <= maximum;
        }

        private static bool Parse(string line, out Entry entry)
        {
            entry = null;
            if (line == null || line.Length > 512 || line.Any(Char.IsControl)) return false;
            int split = line.IndexOf(Prefix, StringComparison.Ordinal);
            if (split < 20 || split > 28) return false;
            DateTimeOffset time;
            string timestamp = line.Substring(0, split);
            if (!DateTimeOffset.TryParseExact(timestamp,
                new[] { "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'" },
                CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out time)) return false;
            string[] tokens = line.Substring(split + Prefix.Length).Split(' ');
            if (tokens.Length == 0 || tokens.Any(String.IsNullOrEmpty)) return false;
            var parsed = new Entry { Time = time, Event = tokens[0] };
            if (new[] { "SESSION", "READY", "DETACHED", "SKIPPED", "UNAVAILABLE" }.Contains(parsed.Event))
            { if (tokens.Length != 1) return false; entry = parsed; return true; }
            if (parsed.Event != "MSG_HTTP" && parsed.Event != "MSG_NETWORK" && parsed.Event != "MSG_COMPLETE" && parsed.Event != "MSG_PENDING") return false;
            var fields = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int i = 1; i < tokens.Length; i++)
            {
                int equals = tokens[i].IndexOf('=');
                if (equals < 1 || equals == tokens[i].Length - 1 || tokens[i].IndexOf('=', equals + 1) >= 0) return false;
                string key = tokens[i].Substring(0, equals);
                if (fields.ContainsKey(key)) return false;
                fields.Add(key, tokens[i].Substring(equals + 1));
            }
            string value;
            if (!fields.TryGetValue("elapsed_ms", out value) || !Number(value, 60000, out parsed.Elapsed)) return false;
            if (parsed.Event == "MSG_COMPLETE")
            { if (fields.Count != 1) return false; entry = parsed; return true; }
            if (parsed.Event == "MSG_PENDING")
            { if (fields.Count != 1 || parsed.Elapsed != 60000) return false; entry = parsed; return true; }
            if (parsed.Event == "MSG_HTTP")
            {
                if (!fields.TryGetValue("status", out value) || !Number(value, 599, out parsed.Status) || parsed.Status < 100) return false;
                if (fields.TryGetValue("retry_after_s", out value) && !Number(value, 86400, out parsed.RetryAfter)) return false;
                if (fields.TryGetValue("scope", out value)) { if (!new[] { "user", "global", "shared", "unknown" }.Contains(value)) return false; parsed.Scope = value; }
                if (fields.TryGetValue("global", out value)) { if (!new[] { "true", "false", "unknown" }.Contains(value)) return false; parsed.Global = value; }
                if (fields.TryGetValue("content_type", out value)) { if (!new[] { "json", "html", "other" }.Contains(value)) return false; parsed.ContentType = value; }
                if (fields.TryGetValue("challenge", out value)) { if (value != "true") return false; parsed.Challenge = true; }
                if (fields.Keys.Any(key => key != "status" && key != "retry_after_s" && key != "elapsed_ms" && key != "scope" && key != "global" && key != "content_type" && key != "challenge")) return false;
            }
            else
            {
                if (fields.Count != 3 || !fields.TryGetValue("code", out value) || !NetworkCodes.Contains(value)) return false;
                parsed.Code = value;
                if (!fields.TryGetValue("canceled", out value) || (value != "true" && value != "false")) return false;
                parsed.Canceled = value == "true";
            }
            entry = parsed; return true;
        }

        private static string Summarize(string text, bool tail)
        {
            var recent = new Queue<Entry>();
            DateTimeOffset? sessionTime = null;
            string lifecycle = null;
            bool supportedSession = false;
            int responses = 0, failures = 0, htmlLimited = 0, jsonLimited = 0, unknownLimited = 0, network = 0, challenges = 0;
            bool hadSuccess = false;
            foreach (string source in text.Split('\n'))
            {
                string line = source.TrimEnd('\r');
                DateTimeOffset boundaryTime;
                bool boundarySupported;
                if (SessionBoundary(line, out boundaryTime, out boundarySupported))
                {
                    sessionTime = boundaryTime; supportedSession = boundarySupported; lifecycle = null; recent.Clear();
                    responses = failures = htmlLimited = jsonLimited = unknownLimited = network = challenges = 0; hadSuccess = false;
                    continue;
                }
                Entry entry;
                // Unanchored tails and records from another version/session do
                // not establish results for this application's latest session.
                if (!supportedSession || !Parse(line, out entry) || entry.Time < sessionTime.Value) continue;
                if (entry.Event == "READY" || entry.Event == "DETACHED" || entry.Event == "SKIPPED" || entry.Event == "UNAVAILABLE")
                { lifecycle = entry.Event; continue; }
                if (entry.Event == "MSG_COMPLETE") continue;
                if (recent.Count == 3) recent.Dequeue();
                recent.Enqueue(entry); responses++;
                if (entry.Event == "MSG_HTTP")
                {
                    if (entry.Status >= 200 && entry.Status < 300) hadSuccess = true;
                    if (entry.Status >= 400) failures++;
                    if (entry.Status == 429)
                    {
                        if (entry.ContentType == "html") htmlLimited++;
                        else if (entry.ContentType == "json") jsonLimited++;
                        else unknownLimited++;
                    }
                    if (entry.Challenge) challenges++;
                }
                else if (entry.Event == "MSG_NETWORK" && !entry.Canceled) { failures++; network++; }
            }
            var report = new List<string> { Heading };
            if (supportedSession) report.Add("Son oturum başlangıcı: " + LocalTime(sessionTime.Value) + " (yerel saat).");
            else if (sessionTime.HasValue) report.Add("Son oturum başka bir tanı sürümüne ait; eski kayıtlar güncel sonuç olarak kullanılmadı. v4.7 ile Discord'u açın.");
            else report.Add("Oturum başlangıcı bu kayıt kesitinde yok; kayıtların güncel oturuma ait olduğu doğrulanamadı ve sonuçlar özete alınmadı.");
            if (tail) report.Add("Dosyanın yalnızca son 256 KB bölümü incelendi.");
            if (responses == 0)
            {
                if (lifecycle == "READY") report.Add("Gözlemci hazır; henüz mesaj isteği sonucu yok. Mesajların yüklenmesi doğrulanamadı.");
                else if (lifecycle == "DETACHED") report.Add("Gözlemci ayrılmış; mesaj isteği sonucu yok. Yükleme sorunu bu kayıttan belirlenemedi.");
                else if (lifecycle == "SKIPPED" || lifecycle == "UNAVAILABLE") report.Add("Mesaj gözlemcisi kullanılamadı; yükleme sorunu bu kayıttan belirlenemedi.");
                else report.Add("Geçerli mesaj isteği sonucu yok. Sorunlu sohbeti açıp M komutunu yeniden çalıştırın.");
            }
            else
            {
                report.Add("Son " + recent.Count.ToString(CultureInfo.InvariantCulture) + " mesaj GET kaydı:");
                foreach (Entry entry in recent)
                {
                    string detail = entry.Event == "MSG_HTTP" ? "HTTP " + entry.Status.ToString(CultureInfo.InvariantCulture) :
                        entry.Event == "MSG_PENDING" ? "60 saniye içinde tamamlanma sonucu gözlenmedi; istek iptal edilmedi" :
                        entry.Code + (entry.Canceled ? " (iptal edildi)" : " (ağ hatası)");
                    if (entry.RetryAfter >= 0) detail += "; Retry-After başlığı " + entry.RetryAfter.ToString(CultureInfo.InvariantCulture) + " sn";
                    if (entry.RetryAfter == 0) detail += " (hemen tekrar deneme izni değildir)";
                    if (entry.Scope != null) detail += "; kapsam=" + entry.Scope;
                    if (entry.Global != null) detail += "; genel=" + entry.Global;
                    if (entry.ContentType != null) detail += "; yanıt=" + entry.ContentType;
                    if (entry.Challenge) detail += "; ek doğrulama işareti var";
                    if (entry.Event != "MSG_PENDING") detail += "; süre " + entry.Elapsed.ToString(CultureInfo.InvariantCulture) + " ms";
                    report.Add(LocalTime(entry.Time) + " — " + detail + ".");
                }
                bool limited = htmlLimited + jsonLimited + unknownLimited > 0;
                if (htmlLimited > 0) report.Add("HTML biçiminde HTTP 429 görüldü; sunucu veya uç ağ katmanındaki bir kısıtlama yanıtıyla uyumlu. Olağan JSON API istek sınırı olduğu doğrulanmadı; kesin neden veya belirli bir IP yasağı bu kayıttan belirlenemez.");
                if (jsonLimited > 0) report.Add("JSON biçiminde HTTP 429 görüldü; olağan API istek sınırı yanıtıyla uyumlu. Sınırı hangi koşulun tetiklediği bu özetten belirlenemez.");
                if (unknownLimited > 0) report.Add("HTTP 429 görüldü; yanıt türü olağan API istek sınırını ayırt etmeye yetmiyor. Kesin neden bu kayıttan belirlenemez.");
                if (challenges > 0) report.Add("Sunucu ek doğrulama işareti bildirdi; doğrulamanın türü veya sonucu bu kayıttan belirlenemez.");
                if (network > 0) report.Add("Ağ hatası kaydedildi; kesin neden yalnızca bu özetle belirlenemez.");
                else if (limited || challenges > 0) { }
                else if (failures > 0) report.Add("HTTP hata yanıtı kaydedildi; kesin neden yalnızca bu özetle belirlenemez.");
                else if (hadSuccess) report.Add("Başarılı HTTP yanıtı var; bu, mesajların ekranda gösterildiğini doğrulamaz.");
                else report.Add("Bu kayıtlar mesajların ekranda gösterildiğini doğrulamaz.");
                if (lifecycle == "DETACHED" || lifecycle == "SKIPPED" || lifecycle == "UNAVAILABLE")
                    report.Add("Gözlemci sonrasında kullanılamaz duruma geçmiş olabilir; sonraki istekler kayıtta bulunmayabilir.");
            }
            report.Add("DiscordAccess'in ek otomatik yeniden denemesi devre dışı; M komutu yeniden deneme yapmaz.");
            return String.Join(Environment.NewLine, report);
        }

        private static bool SessionBoundary(string line, out DateTimeOffset time, out bool supported)
        {
            time = default(DateTimeOffset); supported = false;
            if (line == null || line.Length > 100 || line.Any(Char.IsControl)) return false;
            const string marker = " [DiscordAccessMessages v";
            int split = line.IndexOf(marker, StringComparison.Ordinal);
            if (split < 20 || split > 28 || !line.EndsWith("] SESSION", StringComparison.Ordinal)) return false;
            string version = line.Substring(split + marker.Length, line.Length - split - marker.Length - "] SESSION".Length);
            string[] parts = version.Split('.');
            int number;
            if (parts.Length != 2 || parts.Any(part => part.Length > 2 || !Number(part, 99, out number))) return false;
            if (!DateTimeOffset.TryParseExact(line.Substring(0, split),
                new[] { "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'" },
                CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out time)) return false;
            supported = version == "4.7";
            return true;
        }

        private static string LocalTime(DateTimeOffset time)
        { return time.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture); }

        internal static int RunOfflineChecks(string packageRoot)
        {
            string work = Path.GetFullPath(Path.Combine(packageRoot, "work"));
            string root = Path.Combine(work, "message-report-" + Guid.NewGuid().ToString("N"));
            int checks = 0;
            Action<bool, string> require = (condition, name) => { if (!condition) throw new InvalidOperationException(name); checks++; };
            Func<string, string> line = body => "2026-10-10T19:40:01.123Z" + Prefix + body + "\n";
            try
            {
                Directory.CreateDirectory(Path.Combine(root, "v3"));
                string path = Path.Combine(root, "v3", "message-network.log");
                Action<string> write = body => File.WriteAllText(path, body, new UTF8Encoding(false));
                require(Read(root).Contains("henüz yok"), "Missing message log was not explained.");
                require(!Read(root).Contains(root), "Missing log exposed its private directory.");
                write(line("SESSION") + line("READY"));
                require(Read(root).Contains("henüz mesaj isteği sonucu yok") && Read(root).Contains("doğrulanamadı"), "READY was treated as message success.");
                write(line("SESSION") + line("MSG_HTTP status=200 elapsed_ms=10"));
                require(Read(root).Contains("HTTP 200") && Read(root).Contains("ekranda gösterildiğini doğrulamaz"), "HTTP 200 was treated as visible messages.");
                write(line("SESSION") + line("MSG_HTTP status=429 retry_after_s=10 elapsed_ms=50"));
                string report = Read(root);
                require(report.Contains("HTTP 429") && report.Contains("10 sn") && report.Contains("50 ms"), "Rate-limit metadata was lost.");
                require(report.Contains("yeniden deneme yapmaz"), "Report implied a retry action.");
                write(line("SESSION") + line("MSG_HTTP status=429 retry_after_s=0 scope=shared global=false content_type=json elapsed_ms=24"));
                report = Read(root);
                require(report.Contains("hemen tekrar deneme izni değildir") && report.Contains("kapsam=shared") && report.Contains("yanıt=json") && report.Contains("JSON biçiminde HTTP 429"), "Zero header or JSON response was misreported.");
                require(report.Contains("ek otomatik yeniden denemesi devre dışı") && !report.Contains("429 kurtarma"), "Report implied an active recovery hook.");
                write(line("SESSION") + line("MSG_HTTP status=429 retry_after_s=0 content_type=html elapsed_ms=20"));
                report = Read(root);
                require(report.Contains("HTML biçiminde HTTP 429") && report.Contains("Olağan JSON API istek sınırı olduğu doğrulanmadı") && report.Contains("IP yasağı bu kayıttan belirlenemez") && !report.Contains("Discord istek sınırı yanıtı verdi"), "HTML response was attributed to an established API rate limit or IP ban.");
                write(line("SESSION") + line("MSG_HTTP status=429 content_type=other elapsed_ms=20"));
                require(Read(root).Contains("yanıt türü olağan API istek sınırını ayırt etmeye yetmiyor"), "Unknown response format claimed a normal API limit.");
                write(line("SESSION") + line("MSG_HTTP status=403 content_type=html elapsed_ms=20 challenge=true"));
                report = Read(root);
                require(report.Contains("ek doğrulama işareti var") && report.Contains("türü veya sonucu bu kayıttan belirlenemez") && !report.Contains("HTTP 429"), "Exact challenge metadata was lost or reclassified as a rate limit.");
                write(line("SESSION") + line("MSG_HTTP status=429 content_type=html elapsed_ms=20") + line("MSG_HTTP status=429 content_type=json elapsed_ms=30"));
                require(Read(root).Contains("HTML biçiminde HTTP 429") && Read(root).Contains("JSON biçiminde HTTP 429"), "Mixed response types were conflated.");
                foreach (string recovery in new[] { "MSG_RECOVERY_READY", "MSG_RECOVERY_WAIT wait_ms=30000 attempt=1", "MSG_RECOVERY_RETRY attempt=1", "MSG_RECOVERY_SUCCESS attempt=1", "MSG_RECOVERY_GIVEUP", "MSG_RECOVERY_UNAVAILABLE", "MSG_RECOVERY_CANCELLED" })
                {
                    write(line("SESSION") + line(recovery)); report = Read(root);
                    require(!report.Contains("429 kurtarma") && !report.Contains("planlanan bekleme") && report.Contains("Geçerli mesaj isteği sonucu yok"), "Retired recovery event was interpreted as active behavior.");
                }
                write(line("SESSION") + line("MSG_NETWORK code=ERR_CONNECTION_RESET canceled=false elapsed_ms=80"));
                require(Read(root).Contains("ERR_CONNECTION_RESET") && Read(root).Contains("Ağ hatası kaydedildi"), "Known network error missing.");
                write(line("SESSION") + line("MSG_NETWORK code=ERR_ABORTED canceled=true elapsed_ms=1"));
                require(Read(root).Contains("iptal edildi") && !Read(root).Contains("Ağ hatası kaydedildi"), "Cancellation was called a network failure.");
                write(line("SESSION") + line("MSG_HTTP status=429 retry_after_s=50 elapsed_ms=50") + line("SESSION") + line("READY"));
                require(!Read(root).Contains("HTTP 429") && Read(root).Contains("henüz mesaj isteği sonucu yok"), "Earlier-session failure leaked into latest session.");
                write(line("SESSION") + line("MSG_HTTP status=503 elapsed_ms=1") + line("READY"));
                require(Read(root).Contains("HTTP 503"), "Another window READY erased current-session evidence.");
                write(line("MSG_HTTP status=502 elapsed_ms=1"));
                require(Read(root).Contains("güncel oturuma ait olduğu doğrulanamadı") && !Read(root).Contains("HTTP 502"), "Unanchored tail was interpreted as current results.");
                Func<string, string> oldLine = body => line(body).Replace("[DiscordAccessMessages v4.7]", "[DiscordAccessMessages v4.3]");
                write(oldLine("SESSION") + oldLine("MSG_HTTP status=429 content_type=html elapsed_ms=20") + line("SESSION") + line("MSG_HTTP status=200 elapsed_ms=10") + oldLine("MSG_HTTP status=503 elapsed_ms=2"));
                report = Read(root);
                require(report.Contains("HTTP 200") && !report.Contains("HTTP 429") && !report.Contains("HTTP 503"), "Historical version records polluted current results.");
                write(line("SESSION") + line("MSG_HTTP status=429 content_type=html elapsed_ms=20") + oldLine("SESSION") + oldLine("READY") + line("MSG_HTTP status=200 elapsed_ms=1"));
                report = Read(root);
                require(report.Contains("başka bir tanı sürümüne ait") && !report.Contains("HTTP 429") && !report.Contains("HTTP 200"), "A newer legacy session left a previous v4.7 result active.");
                write(oldLine("SESSION") + oldLine("MSG_HTTP status=429 elapsed_ms=20"));
                require(!Read(root).Contains("HTTP 429") && Read(root).Contains("başka bir tanı sürümüne ait"), "Legacy-only log was presented as current evidence.");
                write(line("SESSION") + line("MSG_HTTP status=429 elapsed_ms=20").Replace("19:40:01", "19:39:59"));
                require(!Read(root).Contains("HTTP 429"), "An outcome older than the current session was accepted.");
                write(line("SESSION") + String.Concat(Enumerable.Range(200, 4).Select(status => line("MSG_HTTP status=" + status + " elapsed_ms=1"))));
                require(!Read(root).Contains("HTTP 200") && Read(root).Contains("HTTP 201") && Read(root).Contains("HTTP 203"), "Summary did not bound recent outcomes to three.");
                foreach (string lifecycle in new[] { "SKIPPED", "UNAVAILABLE", "DETACHED" })
                {
                    write(line("SESSION") + line(lifecycle));
                    require(!Read(root).Contains("Başarılı") && Read(root).Contains("belirlenemedi"), "Unavailable diagnostic claimed message success.");
                }
                write(line("SESSION") + line("MSG_COMPLETE elapsed_ms=100"));
                require(!Read(root).Contains("Başarılı") && Read(root).Contains("Geçerli mesaj isteği sonucu yok"), "Completion without HTTP status claimed success.");
                write(line("SESSION") + line("MSG_PENDING elapsed_ms=60000")); report = Read(root);
                require(report.Contains("60 saniye içinde tamamlanma sonucu gözlenmedi; istek iptal edilmedi") &&
                    !report.Contains("HTTP hata") && !report.Contains("Ağ hatası") && !report.Contains("zaman aşımı"),
                    "Observation deadline was confused with a cancelled request, timeout or network failure.");
                string[] bad = {
                    "MSG_HTTP status=429 retry_after_s=999999 elapsed_ms=1", "MSG_HTTP status=429 elapsed_ms=60001",
                    "MSG_HTTP status=429 elapsed_ms=1 url=https://private.example/SECRET", "MSG_HTTP status=429 elapsed_ms=1 status=200",
                    "MSG_HTTP status=99 elapsed_ms=1", "MSG_HTTP status=600 elapsed_ms=1", "MSG_HTTP status=429 elapsed_ms=-1",
                    "MSG_HTTP status=429 retry_after_s=NaN elapsed_ms=1", "MSG_NETWORK code=ERR_SECRET_TOKEN canceled=false elapsed_ms=1",
                    "MSG_NETWORK code=ERR_CONNECTION_RESET canceled=SECRET elapsed_ms=1", "SESSION SECRET", "UNKNOWN SECRET",
                    "MSG_HTTP status=429 elapsed_ms=1 scope=SECRET", "MSG_HTTP status=429 elapsed_ms=1 global=SECRET",
                    "MSG_HTTP status=429 elapsed_ms=1 content_type=SECRET", "MSG_RECOVERY_WAIT wait_ms=300001 attempt=1",
                    "MSG_RECOVERY_RETRY attempt=3", "MSG_RECOVERY_WAIT wait_ms=30 url=https://SECRET", "MSG_RECOVERY_SECRET",
                    "MSG_HTTP status=429 elapsed_ms=1 challenge=false", "MSG_HTTP status=429 elapsed_ms=1 challenge=unknown",
                    "MSG_HTTP status=429 elapsed_ms=1 challenge=SECRET", "MSG_HTTP status=429 elapsed_ms=1 challenge=True",
                    "MSG_HTTP status=429 elapsed_ms=1 challenge=true challenge=true", "MSG_HTTP status=429 elapsed_ms=1 cf-mitigated=challenge",
                    "MSG_HTTP status=429 elapsed_ms=1 content_type=html\tSECRET", "MSG_HTTP status=429 elapsed_ms=1\u001bSECRET"
                };
                foreach (string badLine in bad)
                {
                    write(line("SESSION") + line(badLine)); report = Read(root);
                    require(!report.Contains("SECRET") && !report.Contains("https://") && !report.Contains("HTTP 429"), "Untrusted message record was displayed.");
                }
                write(line("SESSION") + line("MSG_HTTP status=429 elapsed_ms=1").TrimEnd('\n'));
                require(!Read(root).Contains("HTTP 429"), "Partial concurrent-write record was interpreted.");
                write(line("SESSION") + new string('x', MaximumBytes + 4096) + "\n" + line("MSG_HTTP status=200 elapsed_ms=1"));
                report = Read(root);
                require(report.Contains("son 256 KB") && report.Contains("güncel oturuma ait olduğu doğrulanamadı") && !report.Contains("HTTP 200"), "Large log tail was unbounded or misidentified.");
                write(new string('x', MaximumBytes + 4096) + "\n" + line("SESSION") + line("MSG_HTTP status=503 elapsed_ms=2"));
                require(Read(root).Contains("Son oturum başlangıcı") && Read(root).Contains("HTTP 503"), "SESSION within bounded tail was not used.");
                write(line("SESSION") + line("MSG_HTTP status=200 elapsed_ms=1"));
                using (var writer = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                    require(Read(root).Contains("HTTP 200"), "Live shared log writer blocked report reading.");
                File.WriteAllBytes(path, new byte[] { 255, 254, 10 });
                require(Read(root).Contains("okunamadı"), "Invalid UTF-8 was accepted.");
                require(Read(@"\\server\share\SECRET").Contains("okunamadı"), "UNC diagnostic root was accepted.");
                require(Read(null).Contains("okunamadı"), "Null diagnostic root was accepted.");
                require(Read(root + ":SECRET").Contains("okunamadı"), "ADS diagnostic root was accepted.");
                return checks;
            }
            finally
            {
                if (Directory.Exists(root) && Safety.Under(root, work) && Safety.NoReparse(root)) Directory.Delete(root, true);
            }
        }
    }
}
