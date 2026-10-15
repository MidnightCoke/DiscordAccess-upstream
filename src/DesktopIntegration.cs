using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace DiscordAccess
{
    // Add attachment downloads only to the isolated profile, before official
    // core startup. No message observer, debugger or network preload is loaded.
    internal static class DesktopIntegration
    {
        private const string OriginalEntry = "module.exports = require('./core.asar');";
        private const int MaximumEntryBytes = 16384;
        private const int MaximumHookBytes = 65536;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);

        internal static string EnsureOfficialEntry(string stateRoot, string version)
        {
            stateRoot = Path.GetFullPath(stateRoot);
            RequireLocalRoot(stateRoot);
            Version parsed;
            if (!Regex.IsMatch(version ?? "", @"\A[0-9]+(?:\.[0-9]+){1,3}\z") || !Version.TryParse(version, out parsed))
                throw new InvalidDataException("The Discord version information could not be verified.");
            string entry = Path.Combine(stateRoot, "profile", "discord", version, "modules", "discord_desktop_core", "index.js");
            RequireOwned(entry, stateRoot);
            byte[] current;
            using (var stream = Safety.ReadLease(entry)) current = ReadEntry(stream);
            string text;
            try { text = Utf8.GetString(current); }
            catch (DecoderFallbackException) { throw Unsupported(); }
            // Recognize official UTF-8 entries and only our exact older wrappers.
            string originalText = text.StartsWith("\uFEFF", StringComparison.Ordinal) ? text.Substring(1) : text;
            bool original = Regex.IsMatch(originalText.Trim(), @"\Amodule\.exports\s*=\s*require\(\s*(?<quote>['""])\./core\.asar\k<quote>\s*\);?\z");
            if (!original && !IsKnownWrapper(text, stateRoot)) throw Unsupported();
            string bridge = Path.Combine(stateRoot, "integration");
            string download = Path.Combine(bridge, "attachment-download-v42.cjs");
            string log = Path.Combine(stateRoot, "download-events.log");
            RequireOwned(bridge, stateRoot); RequireOwned(download, stateRoot); RequireOwned(log, stateRoot);
            byte[] resource = AttachmentResource();
            Directory.CreateDirectory(bridge); RequireOwned(bridge, stateRoot);
            WriteOwnedHook(download, stateRoot, resource);
            byte[] wrapper = Utf8.GetBytes(ExpectedAttachmentEntry(download, "v4.12"));
            if (!SameBytes(current, wrapper)) ReplaceRecognizedEntry(entry, stateRoot, current, wrapper);
            return log;
        }

        private static bool IsKnownWrapper(string text, string stateRoot)
        {
            string bridge = Path.Combine(stateRoot, "integration");
            string download = Path.Combine(bridge, "attachment-download-v42.cjs");
            if (text == ExpectedAttachmentEntry(download) || text == ExpectedAttachmentEntry(download, "v4.11") ||
                text == ExpectedAttachmentEntry(download, "v4.12") || text == ExpectedLegacyEntry(
                Path.Combine(bridge, "attachment-download.cjs"), Path.Combine(bridge, "node-https-proxy.cjs"))) return true;
            foreach (string version in new[] { "v4.3", "v4.4", "v4.5", "v4.6", "v4.7" })
            {
                string diagnosticName = "message-diagnostics-" + version.Replace(".", "") + ".cjs";
                if (text == ExpectedSessionEntry(download, Path.Combine(bridge, diagnosticName), version)) return true;
            }
            return false;
        }

        // Old session templates are recognized only; no previous integration
        // file or backup is read or evaluated.
        private static string ExpectedSessionEntry(string download, string diagnostics, string version)
        {
            var json = new JavaScriptSerializer();
            return "// DiscordAccess session support " + version + "\n" +
                "if (process.env.DISCORDACCESS_ATTACHMENTS === '1') {\n" +
                "  try { require(" + json.Serialize(download) + "); } catch (_) {}\n" +
                "}\n" +
                "if (process.env.DISCORDACCESS_MESSAGE_DIAGNOSTICS === '1') {\n" +
                "  try { require(" + json.Serialize(diagnostics) + "); } catch (_) {}\n" +
                "}\n" + OriginalEntry + "\n";
        }
        private static string ExpectedAttachmentEntry(string download, string version = "v4.2")
        {
            return "// DiscordAccess attachment clicks " + version + "\n" +
                "if (process.env.DISCORDACCESS_ATTACHMENTS === '1') {\n" +
                "  try { require(" + new JavaScriptSerializer().Serialize(download) + "); } catch (_) {}\n" +
                "}\n" + OriginalEntry + "\n";
        }
        private static string ExpectedLegacyEntry(string download, string nodeProxy)
        {
            var json = new JavaScriptSerializer();
            return "// DiscordAccess scoped integration v4\n" +
                "if (process.env.DISCORDACCESS_DOWNLOADS === '1') {\n" +
                "  require(" + json.Serialize(nodeProxy) + ");\n" +
                "  require(" + json.Serialize(download) + ");\n" +
                "}\n" + OriginalEntry + "\n";
        }

        private static byte[] ReadEntry(FileStream stream)
        {
            return ReadBounded(stream, MaximumEntryBytes);
        }
        private static byte[] ReadBounded(Stream stream, int limit)
        {
            if (stream.Length > limit) throw Unsupported();
            byte[] bytes = new byte[checked((int)stream.Length)];
            int offset = 0;
            while (offset < bytes.Length)
            {
                int read = stream.Read(bytes, offset, bytes.Length - offset);
                if (read == 0) throw Unsupported();
                offset += read;
            }
            return bytes;
        }
        private static byte[] AttachmentResource()
        {
            using (var stream = typeof(DesktopIntegration).Assembly.GetManifestResourceStream("DiscordAccess.AttachmentDownloadHook"))
            {
                if (stream == null || stream.Length == 0 || stream.Length > MaximumHookBytes)
                    throw new InvalidDataException("The Discord file download component is missing from the package or invalid.");
                byte[] bytes = ReadBounded(stream, MaximumHookBytes);
                try { Utf8.GetString(bytes); } catch (DecoderFallbackException) { throw Unsupported(); }
                return bytes;
            }
        }
        private static void WriteOwnedHook(string path, string root, byte[] bytes)
        {
            RequireOwned(path, root);
            using (var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
            {
                RequireOwned(path, root);
                if (!String.Equals(Path.GetFullPath(path), NativeFile.FinalPath(stream.SafeFileHandle), StringComparison.OrdinalIgnoreCase))
                    throw Unsupported();
                if (SameBytes(ReadBounded(stream, MaximumHookBytes), bytes)) return;
                stream.Position = 0; stream.Write(bytes, 0, bytes.Length);
                stream.SetLength(bytes.Length); stream.Flush(true);
            }
        }
        private static void ReplaceRecognizedEntry(string entry, string root, byte[] expected, byte[] replacement)
        {
            RequireOwned(entry, root);
            // Pin the exact file and recheck its bytes with exclusive access.
            // No backup is read, and an intervening edit is never overwritten.
            using (var stream = new FileStream(entry, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                RequireOwned(entry, root);
                if (!String.Equals(Path.GetFullPath(entry), NativeFile.FinalPath(stream.SafeFileHandle), StringComparison.OrdinalIgnoreCase) ||
                    !SameBytes(ReadEntry(stream), expected)) throw Unsupported();
                stream.Position = 0;
                stream.Write(replacement, 0, replacement.Length);
                stream.SetLength(replacement.Length);
                stream.Flush(true);
            }
        }
        private static bool SameBytes(byte[] left, byte[] right)
        {
            if (left.Length != right.Length) return false;
            for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        private static void RequireLocalRoot(string root)
        {
            if (root.StartsWith(@"\\", StringComparison.Ordinal) || !Path.IsPathRooted(root) ||
                root.Length < 3 || root[1] != ':' || root.Substring(2).IndexOf(':') >= 0 || !Safety.NoReparse(root))
                throw new InvalidDataException("The local file boundary of the separate Discord folder could not be verified.");
        }
        private static void RequireOwned(string path, string root)
        {
            if (!Safety.Under(path, root) || !Safety.NoReparse(path))
                throw new InvalidDataException("The folder boundary of the separate Discord module could not be verified.");
        }
        private static InvalidDataException Unsupported()
        {
            return new InvalidDataException("The startup file of the separate Discord module was not recognized; the file was not changed. The separate copy must be prepared again from the current official installation.");
        }

#if TEST_BUILD
        internal static int RunOfflineChecks(string fixtureRoot)
        {
            int checks = 0;
            Action<bool, string> require = (ok, message) =>
            { if (!ok) throw new InvalidOperationException(message); checks++; };
            string workRoot = Path.Combine(Path.GetFullPath(fixtureRoot), "work");
            string root = Path.Combine(workRoot, "integration-" + Guid.NewGuid().ToString("N"));
            RequireLocalRoot(root);
            if (!Safety.Under(root, workRoot)) throw new InvalidOperationException("Integration fixture escaped work.");
            string module = Path.Combine(root, "profile", "discord", "1.2.3", "modules", "discord_desktop_core");
            Directory.CreateDirectory(module);
            string entry = Path.Combine(module, "index.js"), archive = Path.Combine(module, "core.asar");
            byte[] archiveBytes = Utf8.GetBytes("official fixture archive");
            File.WriteAllBytes(archive, archiveBytes);
            try
            {
                var stamp = new DateTime(2020, 1, 2, 3, 4, 5, DateTimeKind.Utc);
                string bridge = Path.Combine(root, "integration"), backup = Path.Combine(module, "index.discordaccess-original.js");
                string download = Path.Combine(bridge, "attachment-download-v42.cjs");
                byte[] expected = Utf8.GetBytes(ExpectedAttachmentEntry(download, "v4.12"));
                byte[] hook = AttachmentResource();
                foreach (string original in new[] { OriginalEntry, " \r\nmodule.exports = require(\"./core.asar\")\r\n", "\uFEFF" + OriginalEntry + "\r\n" })
                {
                    byte[] originalBytes = Utf8.GetBytes(original);
                    File.WriteAllBytes(entry, originalBytes); File.SetLastWriteTimeUtc(entry, stamp);
                    string log = EnsureOfficialEntry(root, "1.2.3");
                    require(SameBytes(File.ReadAllBytes(entry), expected), "Official/v4.10 entry did not receive the attachment-only wrapper.");
                    require(log == Path.Combine(root, "download-events.log") && !File.Exists(log), "Unexpected download log location or eager log creation.");
                    require(SameBytes(File.ReadAllBytes(download), hook), "Embedded attachment resource differs from the installed file.");
                }
                require(!File.Exists(backup) &&
                    !File.Exists(Path.Combine(root, "download-events.log")) && !File.Exists(Path.Combine(root, "message-network.log")),
                    "Preparing an attachment entry created backups or message diagnostic logs.");
                string installed = File.ReadAllText(entry);
                require(!installed.Contains("MESSAGE") && !installed.Contains("node-https") && !installed.Contains("DISCORDACCESS_DOWNLOADS") &&
                    installed.EndsWith(OriginalEntry + "\n"), "A message observer or broad network hook was installed.");

                string inactive = Path.Combine(bridge, "message-diagnostics-v47.cjs");
                File.WriteAllText(inactive, "untrusted inactive fixture, never loaded");
                File.WriteAllText(backup, "untrusted backup fixture, never read");
                var wrappers = new System.Collections.Generic.List<string> { ExpectedLegacyEntry(
                    Path.Combine(bridge, "attachment-download.cjs"), Path.Combine(bridge, "node-https-proxy.cjs")), ExpectedAttachmentEntry(download) };
                foreach (string version in new[] { "v4.3", "v4.4", "v4.5", "v4.6", "v4.7" })
                {
                    string name = "message-diagnostics-" + version.Replace(".", "") + ".cjs";
                    wrappers.Add(ExpectedSessionEntry(download, Path.Combine(bridge, name), version));
                }
                wrappers.Add(ExpectedAttachmentEntry(download, "v4.11"));
                foreach (string wrapper in wrappers)
                {
                    File.WriteAllBytes(entry, Utf8.GetBytes(wrapper));
                    EnsureOfficialEntry(root, "1.2.3");
                    require(SameBytes(File.ReadAllBytes(entry), expected), "Recognized legacy/v4.9 wrapper did not migrate to attachment-only support.");
                    require(SameBytes(File.ReadAllBytes(archive), archiveBytes), "Official archive changed during restoration.");
                }
                require(File.ReadAllText(backup) == "untrusted backup fixture, never read", "Legacy backup was trusted or changed.");
                require(File.ReadAllText(inactive) == "untrusted inactive fixture, never loaded", "Inactive integration file changed.");
                require(SameBytes(File.ReadAllBytes(download), hook) && !File.Exists(Path.Combine(root, "download-events.log")) &&
                    !File.Exists(Path.Combine(root, "message-network.log")), "Migration installed an unexpected file or changed the attachment resource.");
                DateTime timestamp = File.GetLastWriteTimeUtc(entry);
                DateTime hookTimestamp = File.GetLastWriteTimeUtc(download);
                EnsureOfficialEntry(root, "1.2.3");
                require(File.GetLastWriteTimeUtc(entry) == timestamp && File.GetLastWriteTimeUtc(download) == hookTimestamp,
                    "Repeated attachment preparation rewrote unchanged files.");

                foreach (string unknown in new[] {
                    "unrecognized custom fixture", "module.exports = require('./core.asar\");", OriginalEntry + "\nrequire('untrusted-fixture');",
                    wrappers[6] + "\nrequire('untrusted-fixture');", wrappers[6].Replace("\n", "\r\n"),
                    ExpectedSessionEntry(Path.Combine(workRoot, "outside.cjs"), inactive, "v4.7"),
                    "\uFEFF" + wrappers[6] })
                {
                    byte[] before = Utf8.GetBytes(unknown); File.WriteAllBytes(entry, before);
                    bool rejected = false;
                    try { EnsureOfficialEntry(root, "1.2.3"); } catch (InvalidDataException) { rejected = true; }
                    require(rejected && SameBytes(File.ReadAllBytes(entry), before), "Unknown or modified entry was overwritten.");
                }
                byte[] oversized = new byte[MaximumEntryBytes + 1];
                File.WriteAllBytes(entry, oversized); bool oversizedRejected = false;
                try { EnsureOfficialEntry(root, "1.2.3"); } catch (InvalidDataException) { oversizedRejected = true; }
                require(oversizedRejected && SameBytes(File.ReadAllBytes(entry), oversized), "Oversized entry was accepted or changed.");
                byte[] intervening = Utf8.GetBytes("untrusted intervening edit, never loaded");
                File.WriteAllBytes(entry, intervening); bool editRejected = false;
                try { ReplaceRecognizedEntry(entry, root, Utf8.GetBytes(OriginalEntry), expected); }
                catch (InvalidDataException) { editRejected = true; }
                require(editRejected && SameBytes(File.ReadAllBytes(entry), intervening), "Intervening entry edit was overwritten.");
                byte[] invalidUtf8 = new byte[] { 0xff, 0xfe, 0xfd };
                File.WriteAllBytes(entry, invalidUtf8); bool invalidRejected = false;
                try { EnsureOfficialEntry(root, "1.2.3"); } catch (InvalidDataException) { invalidRejected = true; }
                require(invalidRejected && SameBytes(File.ReadAllBytes(entry), invalidUtf8), "Invalid entry encoding was accepted or changed.");
                foreach (string version in new[] { "../outside", @"..\outside", "1.2.3/other", "", "-1.2.3" })
                {
                    bool rejected = false;
                    try { EnsureOfficialEntry(root, version); } catch (InvalidDataException) { rejected = true; }
                    require(rejected && SameBytes(File.ReadAllBytes(entry), invalidUtf8), "Invalid version escaped or changed the isolated module.");
                }
                bool remoteRejected = false;
                try { EnsureOfficialEntry(@"\\server\share\fixture", "1.2.3"); } catch (InvalidDataException) { remoteRejected = true; }
                require(remoteRejected, "Remote integration root was accepted.");
                require(SameBytes(File.ReadAllBytes(archive), archiveBytes), "Official archive bytes changed.");
                require(SameBytes(File.ReadAllBytes(download), hook), "Rejected entry altered the known attachment hook.");
            }
            finally
            {
                string resolvedRoot = Path.GetFullPath(root);
                if (Safety.Under(resolvedRoot, workRoot) && Safety.NoReparse(resolvedRoot)) Directory.Delete(resolvedRoot, true);
            }
            return checks;
        }
#endif
    }
}
