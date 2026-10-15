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
        private const string Heading = "Message diagnostics v4.7 — local record only; the M command sends no network request.";
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
                    "No message diagnostic record yet. Open Discord with v4.7, select the affected chat and run the M command again.";
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
            return Heading + Environment.NewLine + "The message diagnostic record could not be read safely. No network or account information was queried.";
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
            if (supportedSession) report.Add("Latest session start: " + LocalTime(sessionTime.Value) + " (local time).");
            else if (sessionTime.HasValue) report.Add("The latest session belongs to another diagnostic version; old records were not used as current results. Open Discord with v4.7.");
            else report.Add("The session start is not in this record excerpt; the records could not be verified as belonging to the current session, and the results were left out of the summary.");
            if (tail) report.Add("Only the last 256 KB of the file was examined.");
            if (responses == 0)
            {
                if (lifecycle == "READY") report.Add("The observer is ready; no message request result yet. Message loading could not be verified.");
                else if (lifecycle == "DETACHED") report.Add("The observer is detached; no message request result. The loading problem could not be determined from this record.");
                else if (lifecycle == "SKIPPED" || lifecycle == "UNAVAILABLE") report.Add("The message observer was unavailable; the loading problem could not be determined from this record.");
                else report.Add("No valid message request result. Open the affected chat and run the M command again.");
            }
            else
            {
                report.Add("Last " + recent.Count.ToString(CultureInfo.InvariantCulture) + " message GET records:");
                foreach (Entry entry in recent)
                {
                    string detail = entry.Event == "MSG_HTTP" ? "HTTP " + entry.Status.ToString(CultureInfo.InvariantCulture) :
                        entry.Event == "MSG_PENDING" ? "no completion result observed within 60 seconds; the request was not canceled" :
                        entry.Code + (entry.Canceled ? " (canceled)" : " (network error)");
                    if (entry.RetryAfter >= 0) detail += "; Retry-After header " + entry.RetryAfter.ToString(CultureInfo.InvariantCulture) + " s";
                    if (entry.RetryAfter == 0) detail += " (not permission to retry immediately)";
                    if (entry.Scope != null) detail += "; scope=" + entry.Scope;
                    if (entry.Global != null) detail += "; global=" + entry.Global;
                    if (entry.ContentType != null) detail += "; response=" + entry.ContentType;
                    if (entry.Challenge) detail += "; extra verification flag present";
                    if (entry.Event != "MSG_PENDING") detail += "; duration " + entry.Elapsed.ToString(CultureInfo.InvariantCulture) + " ms";
                    report.Add(LocalTime(entry.Time) + " — " + detail + ".");
                }
                bool limited = htmlLimited + jsonLimited + unknownLimited > 0;
                if (htmlLimited > 0) report.Add("HTTP 429 seen in HTML format; consistent with a restriction response from a server or edge network layer. It was not verified to be a normal JSON API rate limit; the exact cause or a specific IP ban cannot be determined from this record.");
                if (jsonLimited > 0) report.Add("HTTP 429 seen in JSON format; consistent with a normal API rate-limit response. Which condition triggered the limit cannot be determined from this summary.");
                if (unknownLimited > 0) report.Add("HTTP 429 seen; the response type is not enough to identify a normal API rate limit. The exact cause cannot be determined from this record.");
                if (challenges > 0) report.Add("The server reported an extra verification flag; the type or result of the verification cannot be determined from this record.");
                if (network > 0) report.Add("Network error recorded; the exact cause cannot be determined from this summary alone.");
                else if (limited || challenges > 0) { }
                else if (failures > 0) report.Add("HTTP error response recorded; the exact cause cannot be determined from this summary alone.");
                else if (hadSuccess) report.Add("A successful HTTP response exists; this does not confirm that the messages were shown on screen.");
                else report.Add("These records do not confirm that the messages were shown on screen.");
                if (lifecycle == "DETACHED" || lifecycle == "SKIPPED" || lifecycle == "UNAVAILABLE")
                    report.Add("The observer may have become unavailable afterwards; later requests may be missing from the record.");
            }
            report.Add("DiscordAccess's extra automatic retry is disabled; the M command does not retry.");
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
                require(Read(root).Contains("No message diagnostic record yet"), "Missing message log was not explained.");
                require(!Read(root).Contains(root), "Missing log exposed its private directory.");
                write(line("SESSION") + line("READY"));
                require(Read(root).Contains("no message request result yet") && Read(root).Contains("could not be verified"), "READY was treated as message success.");
                write(line("SESSION") + line("MSG_HTTP status=200 elapsed_ms=10"));
                require(Read(root).Contains("HTTP 200") && Read(root).Contains("not confirm that the messages were shown on screen"), "HTTP 200 was treated as visible messages.");
                write(line("SESSION") + line("MSG_HTTP status=429 retry_after_s=10 elapsed_ms=50"));
                string report = Read(root);
                require(report.Contains("HTTP 429") && report.Contains("10 s;") && report.Contains("50 ms"), "Rate-limit metadata was lost.");
                require(report.Contains("the M command does not retry"), "Report implied a retry action.");
                write(line("SESSION") + line("MSG_HTTP status=429 retry_after_s=0 scope=shared global=false content_type=json elapsed_ms=24"));
                report = Read(root);
                require(report.Contains("not permission to retry immediately") && report.Contains("scope=shared") && report.Contains("response=json") && report.Contains("HTTP 429 seen in JSON format"), "Zero header or JSON response was misreported.");
                require(report.Contains("extra automatic retry is disabled") && !report.Contains("429 recovery"), "Report implied an active recovery hook.");
                write(line("SESSION") + line("MSG_HTTP status=429 retry_after_s=0 content_type=html elapsed_ms=20"));
                report = Read(root);
                require(report.Contains("HTTP 429 seen in HTML format") && report.Contains("It was not verified to be a normal JSON API rate limit") && report.Contains("IP ban cannot be determined from this record") && !report.Contains("Discord returned a rate-limit response"), "HTML response was attributed to an established API rate limit or IP ban.");
                write(line("SESSION") + line("MSG_HTTP status=429 content_type=other elapsed_ms=20"));
                require(Read(root).Contains("the response type is not enough to identify a normal API rate limit"), "Unknown response format claimed a normal API limit.");
                write(line("SESSION") + line("MSG_HTTP status=403 content_type=html elapsed_ms=20 challenge=true"));
                report = Read(root);
                require(report.Contains("extra verification flag present") && report.Contains("type or result of the verification cannot be determined from this record") && !report.Contains("HTTP 429"), "Exact challenge metadata was lost or reclassified as a rate limit.");
                write(line("SESSION") + line("MSG_HTTP status=429 content_type=html elapsed_ms=20") + line("MSG_HTTP status=429 content_type=json elapsed_ms=30"));
                require(Read(root).Contains("HTTP 429 seen in HTML format") && Read(root).Contains("HTTP 429 seen in JSON format"), "Mixed response types were conflated.");
                foreach (string recovery in new[] { "MSG_RECOVERY_READY", "MSG_RECOVERY_WAIT wait_ms=30000 attempt=1", "MSG_RECOVERY_RETRY attempt=1", "MSG_RECOVERY_SUCCESS attempt=1", "MSG_RECOVERY_GIVEUP", "MSG_RECOVERY_UNAVAILABLE", "MSG_RECOVERY_CANCELLED" })
                {
                    write(line("SESSION") + line(recovery)); report = Read(root);
                    require(!report.Contains("429 recovery") && !report.Contains("scheduled wait") && report.Contains("No valid message request result"), "Retired recovery event was interpreted as active behavior.");
                }
                write(line("SESSION") + line("MSG_NETWORK code=ERR_CONNECTION_RESET canceled=false elapsed_ms=80"));
                require(Read(root).Contains("ERR_CONNECTION_RESET") && Read(root).Contains("Network error recorded"), "Known network error missing.");
                write(line("SESSION") + line("MSG_NETWORK code=ERR_ABORTED canceled=true elapsed_ms=1"));
                require(Read(root).Contains("(canceled)") && !Read(root).Contains("Network error recorded"), "Cancellation was called a network failure.");
                write(line("SESSION") + line("MSG_HTTP status=429 retry_after_s=50 elapsed_ms=50") + line("SESSION") + line("READY"));
                require(!Read(root).Contains("HTTP 429") && Read(root).Contains("no message request result yet"), "Earlier-session failure leaked into latest session.");
                write(line("SESSION") + line("MSG_HTTP status=503 elapsed_ms=1") + line("READY"));
                require(Read(root).Contains("HTTP 503"), "Another window READY erased current-session evidence.");
                write(line("MSG_HTTP status=502 elapsed_ms=1"));
                require(Read(root).Contains("could not be verified as belonging to the current session") && !Read(root).Contains("HTTP 502"), "Unanchored tail was interpreted as current results.");
                Func<string, string> oldLine = body => line(body).Replace("[DiscordAccessMessages v4.7]", "[DiscordAccessMessages v4.3]");
                write(oldLine("SESSION") + oldLine("MSG_HTTP status=429 content_type=html elapsed_ms=20") + line("SESSION") + line("MSG_HTTP status=200 elapsed_ms=10") + oldLine("MSG_HTTP status=503 elapsed_ms=2"));
                report = Read(root);
                require(report.Contains("HTTP 200") && !report.Contains("HTTP 429") && !report.Contains("HTTP 503"), "Historical version records polluted current results.");
                write(line("SESSION") + line("MSG_HTTP status=429 content_type=html elapsed_ms=20") + oldLine("SESSION") + oldLine("READY") + line("MSG_HTTP status=200 elapsed_ms=1"));
                report = Read(root);
                require(report.Contains("belongs to another diagnostic version") && !report.Contains("HTTP 429") && !report.Contains("HTTP 200"), "A newer legacy session left a previous v4.7 result active.");
                write(oldLine("SESSION") + oldLine("MSG_HTTP status=429 elapsed_ms=20"));
                require(!Read(root).Contains("HTTP 429") && Read(root).Contains("belongs to another diagnostic version"), "Legacy-only log was presented as current evidence.");
                write(line("SESSION") + line("MSG_HTTP status=429 elapsed_ms=20").Replace("19:40:01", "19:39:59"));
                require(!Read(root).Contains("HTTP 429"), "An outcome older than the current session was accepted.");
                write(line("SESSION") + String.Concat(Enumerable.Range(200, 4).Select(status => line("MSG_HTTP status=" + status + " elapsed_ms=1"))));
                require(!Read(root).Contains("HTTP 200") && Read(root).Contains("HTTP 201") && Read(root).Contains("HTTP 203"), "Summary did not bound recent outcomes to three.");
                foreach (string lifecycle in new[] { "SKIPPED", "UNAVAILABLE", "DETACHED" })
                {
                    write(line("SESSION") + line(lifecycle));
                    require(!Read(root).Contains("successful") && Read(root).Contains("could not be determined"), "Unavailable diagnostic claimed message success.");
                }
                write(line("SESSION") + line("MSG_COMPLETE elapsed_ms=100"));
                require(!Read(root).Contains("successful") && Read(root).Contains("No valid message request result"), "Completion without HTTP status claimed success.");
                write(line("SESSION") + line("MSG_PENDING elapsed_ms=60000")); report = Read(root);
                require(report.Contains("no completion result observed within 60 seconds; the request was not canceled") &&
                    !report.Contains("HTTP error") && !report.Contains("network error") && !report.Contains("timed out"),
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
                require(report.Contains("last 256 KB") && report.Contains("could not be verified as belonging to the current session") && !report.Contains("HTTP 200"), "Large log tail was unbounded or misidentified.");
                write(new string('x', MaximumBytes + 4096) + "\n" + line("SESSION") + line("MSG_HTTP status=503 elapsed_ms=2"));
                require(Read(root).Contains("Latest session start") && Read(root).Contains("HTTP 503"), "SESSION within bounded tail was not used.");
                write(line("SESSION") + line("MSG_HTTP status=200 elapsed_ms=1"));
                using (var writer = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                    require(Read(root).Contains("HTTP 200"), "Live shared log writer blocked report reading.");
                File.WriteAllBytes(path, new byte[] { 255, 254, 10 });
                require(Read(root).Contains("could not be read"), "Invalid UTF-8 was accepted.");
                require(Read(@"\\server\share\SECRET").Contains("could not be read"), "UNC diagnostic root was accepted.");
                require(Read(null).Contains("could not be read"), "Null diagnostic root was accepted.");
                require(Read(root + ":SECRET").Contains("could not be read"), "ADS diagnostic root was accepted.");
                return checks;
            }
            finally
            {
                if (Directory.Exists(root) && Safety.Under(root, work) && Safety.NoReparse(root)) Directory.Delete(root, true);
            }
        }
    }
}
