using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace DiscordAccess
{
    // Changes are journaled before touching the two settings or the recognized
    // entry. No account store, application archive or native module is read.
    internal sealed class InstalledDiscord : IDisposable
    {
        private const string OfficialEntry = "module.exports = require('./core.asar');";
        private const int SettingsLimit = 1024 * 1024;
        private const int EntryLimit = 16384;
        private const int HookLimit = 65536;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        private static readonly string[] SettingKeys = { "UPDATE_ENDPOINT", "NEW_UPDATE_ENDPOINT" };
        private string sessionRoot, journalPath, hookPath, settingsPath, installationRoot, legacyRoot, externalProxy;
        private Dictionary<string, object> journal;
        private FileStream hookLease;
        internal string Image { get; private set; }
        internal string Version { get; private set; }
        internal string ProfilePath { get; private set; }
        internal string DownloadLogPath { get; private set; }
        internal static bool HasPendingRecovery
        { get { return Pending(Path.Combine(Safety.StateRoot, "v3", "installed-session")); } }
        internal static string PendingRecoveryRoot
        {
            get
            {
                return PendingRecoveryRootCore(Safety.DefaultDiscordRoot,
                    Path.Combine(Safety.StateRoot, "v3", "installed-session"));
            }
        }

        private static string PendingRecoveryRootCore(string legacyRoot, string session)
        {
            Require(session); string path = Path.Combine(session, "journal.json"); Require(path);
            if (!File.Exists(path)) return null;
            EnsurePrivateDirectory(session, false);
            byte[] bytes = ReadPrivate(path, SettingsLimit);
            var saved = Object(bytes);
            string version = JournalVersion(saved);
            saved = ValidateJournal(bytes, version, null, legacyRoot);
            string root = JournalRoot(saved, legacyRoot);
            VerifyRecoveryRoot(root, version);
            return root;
        }

        private static bool Pending(string session)
        {
            Require(session); string path = Path.Combine(session, "journal.json"); Require(path);
            return File.Exists(path);
        }

        internal static InstalledDiscord Prepare(string image, Action<string> log)
        {
            Safety.EnsureStateDirectory();
            using (var verified = new TrustedImage(image, true)) { }
            return PrepareCore(image, Safety.DiscordRoot,
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "discord"),
                Path.Combine(Safety.StateRoot, "v3", "installed-session"), log, Safety.DefaultDiscordRoot);
        }

        internal static InstalledDiscord PrepareExternal(string image, string proxyUrl, Action<string> log)
        {
            ValidateProxy(proxyUrl);
            Safety.EnsureStateDirectory();
            using (var verified = new TrustedImage(image, true)) { }
            return PrepareCore(image, Safety.DiscordRoot,
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "discord"),
                Path.Combine(Safety.StateRoot, "v3", "installed-session"), log, Safety.DefaultDiscordRoot, proxyUrl);
        }

        // The installed layout must be selected from official bootstrap evidence.
        // Do not silently fall back to a different profile or create a module.
        private static InstalledDiscord PrepareCore(string image, string installedRoot, string profile,
            string session, Action<string> log, string legacyRoot = null, string externalProxy = null)
        {
            if (externalProxy != null) ValidateProxy(externalProxy);
            var result = Create(image, installedRoot, profile, session, legacyRoot ?? Safety.DefaultDiscordRoot);
            result.externalProxy = externalProxy;
            if (File.Exists(result.journalPath)) throw Conflict();
            var build = Object(Read(Path.Combine(Path.GetDirectoryName(result.Image), "resources", "build_info.json"), SettingsLimit));
            object channel, version;
            if (!build.TryGetValue("releaseChannel", out channel) || !Equals(channel, "stable") ||
                !build.TryGetValue("version", out version) || !Equals(version, result.Version)) throw Unsupported();
            string app = Path.GetDirectoryName(result.Image);
            if (!File.Exists(result.Image) || !File.Exists(Path.Combine(app, "resources", "app.asar")) ||
                File.Exists(Path.Combine(app, "version.dll")) || File.Exists(Path.Combine(app, "drover.ini"))) throw Unsupported();
            Require(Path.Combine(app, "resources", "app.asar"));
            if (!Directory.Exists(result.ProfilePath)) throw MissingModule();
            string modules = Path.Combine(app, "modules"); Require(modules);
            if (!Directory.Exists(modules)) throw MissingModule();
            var entries = new List<object>();
            var expected = new Dictionary<int, byte[]>();
            foreach (string directory in Directory.GetDirectories(modules, "discord_desktop_core-*"))
            {
                Require(directory);
                Match match = Regex.Match(Path.GetFileName(directory), @"\Adiscord_desktop_core-([1-9][0-9]{0,9})\z");
                int module;
                if (!match.Success || !Int32.TryParse(match.Groups[1].Value, out module) || module < 1) throw Unsupported();
                string entryPath = result.EntryPath(module);
                if (!File.Exists(entryPath) || !File.Exists(Path.Combine(Path.GetDirectoryName(entryPath), "core.asar"))) throw MissingModule();
                Require(Path.Combine(Path.GetDirectoryName(entryPath), "core.asar"));
                byte[] entry = Read(entryPath, EntryLimit);
                if (!Original(entry) && !Same(entry, result.Wrapper()) && !Same(entry, result.LegacyWrapper())) throw Unsupported();
                byte[] original = Original(entry) ? entry : Utf8.GetBytes(OfficialEntry + "\n");
                entries.Add(new Dictionary<string, object> { { "module", module }, { "original", Convert.ToBase64String(original) } });
                expected.Add(module, entry);
                if (entries.Count > 16) throw Unsupported();
            }
            if (entries.Count == 0) throw MissingModule();
            byte[] hook = HookResource();
            EnsurePrivateDirectory(result.sessionRoot);
            // A protected session directory does not prove an existing child
            // private. Check before reading, including same-byte hook reuse.
            byte[] previousHook = File.Exists(result.hookPath) ? ReadPrivate(result.hookPath, HookLimit) : null;
            result.journal = new Dictionary<string, object> {
                { "schema", externalProxy == null ? 2 : 3 }, { "root", result.installationRoot }, { "version", result.Version },
                { "entries", entries.ToArray() }, { "configured", false }
            };
            if (externalProxy != null)
            {
                result.journal["mode"] = "external";
                result.journal["proxy_url"] = externalProxy;
            }
            result.SaveJournal(null);
            try
            {
                Replace(result.hookPath, previousHook, hook);
                result.hookLease = PrivateFileTrust.ReadLease(result.hookPath);
                if (!Same(ReadStream(result.hookLease, HookLimit), hook)) throw Conflict();
                foreach (var entry in expected) Replace(result.EntryPath(entry.Key), entry.Value, result.Wrapper());
            }
            catch
            {
                try { result.Restore(); } catch { }
                finally { result.Dispose(); }
                throw;
            }
            if (log != null) log("Kurulu Discord için geçici bağlantı desteği hazırlandı.");
            return result;
        }

        private static InstalledDiscord Create(string image, string installedRoot, string profile, string session, string legacyRoot)
        {
            image = Path.GetFullPath(image); installedRoot = NormalizeRoot(Path.GetFullPath(installedRoot).TrimEnd('\\'));
            profile = Path.GetFullPath(profile); session = Path.GetFullPath(session);
            Require(image); Require(installedRoot); Require(profile); Require(session);
            string app = Path.GetDirectoryName(image), appName = Path.GetFileName(app);
            string version = appName != null && appName.StartsWith("app-", StringComparison.Ordinal) ? appName.Substring(4) : "";
            System.Version parsed;
            if (!Regex.IsMatch(version, @"\A[0-9]+(?:\.[0-9]+){1,3}\z") || !System.Version.TryParse(version, out parsed) ||
                !String.Equals(image, Path.Combine(installedRoot, "app-" + version, "Discord.exe"), StringComparison.OrdinalIgnoreCase) ||
                Safety.Under(profile, installedRoot) || Safety.Under(session, profile) || Safety.Under(profile, session)) throw Unsupported();
            var result = new InstalledDiscord { Image = image, Version = version, ProfilePath = profile, sessionRoot = session,
                installationRoot = installedRoot, legacyRoot = NormalizeRoot(Path.GetFullPath(legacyRoot).TrimEnd('\\')) };
            result.journalPath = Path.Combine(session, "journal.json");
            result.settingsPath = Path.Combine(profile, "settings.json");
            result.hookPath = Path.Combine(session, "attachment-download.cjs");
            result.DownloadLogPath = Path.Combine(Path.GetDirectoryName(session), "normal-download-events.log");
            foreach (string path in new[] { result.journalPath, result.settingsPath, result.hookPath, result.DownloadLogPath }) Require(path);
            return result;
        }

        private string EntryPath(int module)
        {
            if (module < 1) throw Conflict();
            string path = Path.Combine(Path.GetDirectoryName(Image), "modules", "discord_desktop_core-" +
                module.ToString(System.Globalization.CultureInfo.InvariantCulture), "discord_desktop_core", "index.js");
            Require(path); return path;
        }

        internal void Configure(string legacy, string modern)
        {
            ValidateEndpoint(legacy); ValidateEndpoint(modern);
            legacy = legacy.TrimEnd('/'); modern = modern.TrimEnd('/') + "/";
            if (journal == null) throw Conflict();
            if ((bool)journal["configured"])
            {
                if (Equals(journal["new_legacy"], legacy) && Equals(journal["new_modern"], modern)) return;
                throw Conflict();
            }
            byte[] current = File.Exists(settingsPath) ? Read(settingsPath, SettingsLimit) : null;
            var settings = current == null ? new Dictionary<string, object>() : Object(current);
            journal["configured"] = true;
            journal["new_legacy"] = legacy; journal["new_modern"] = modern;
            for (int i = 0; i < SettingKeys.Length; i++)
            {
                object old;
                bool exists = settings.TryGetValue(SettingKeys[i], out old);
                journal["had_" + i] = exists;
                if (exists) journal["old_" + i] = old;
            }
            SaveJournal(ReadPrivate(journalPath, SettingsLimit));
            settings[SettingKeys[0]] = legacy; settings[SettingKeys[1]] = modern;
            Replace(settingsPath, current, Json(settings));
        }

        internal void Restore()
        {
            if (!File.Exists(journalPath)) { journal = null; Dispose(); return; }
            EnsurePrivateDirectory(sessionRoot, false);
            byte[] saved = ReadPrivate(journalPath, SettingsLimit);
            journal = ValidateJournal(saved, Version, installationRoot, legacyRoot);
            if (!String.Equals(JournalProxy(journal), externalProxy, StringComparison.Ordinal)) throw Conflict();
            VerifyRecoveryRoot(installationRoot, Version);
            bool conflict = false;
            // Restore each owned setting independently. An unrelated preference
            // or a changed owned value is never replaced by the old whole file.
            if ((bool)journal["configured"])
            {
                byte[] current = File.Exists(settingsPath) ? Read(settingsPath, SettingsLimit) : null;
                var settings = current == null ? new Dictionary<string, object>() : Object(current);
                bool changed = false;
                for (int i = 0; i < SettingKeys.Length; i++)
                {
                    object value, old = null;
                    bool exists = settings.TryGetValue(SettingKeys[i], out value), had = (bool)journal["had_" + i];
                    if (had) old = journal["old_" + i];
                    if (exists == had && (!had || JsonEqual(value, old))) continue;
                    if (!exists || !Equals(value, journal[i == 0 ? "new_legacy" : "new_modern"])) { conflict = true; continue; }
                    if (had) settings[SettingKeys[i]] = old; else settings.Remove(SettingKeys[i]);
                    changed = true;
                }
                if (changed) Replace(settingsPath, current, Json(settings));
            }
            foreach (Dictionary<string, object> record in (object[])journal["entries"])
            {
                string entryPath = EntryPath((int)record["module"]);
                byte[] original = Convert.FromBase64String((string)record["original"]);
                byte[] entry = File.Exists(entryPath) ? Read(entryPath, EntryLimit) : null;
                if (Same(entry, Wrapper())) Replace(entryPath, entry, original);
                // Official updates may replace the entry or remove an old
                // module directory. Never replace that new official payload.
                else if (entry != null && !Original(entry)) conflict = true;
            }
            if (conflict) throw Conflict();
            using (PrivateFileTrust.ReadLease(journalPath)) { }
            DeleteExpected(journalPath, saved);
            journal = null;
            Dispose();
        }

        // Ending support releases only the lease. The journal and installed
        // files remain available for an ordinary deferred recovery.
        public void Dispose()
        {
            if (hookLease != null) { hookLease.Dispose(); hookLease = null; }
        }

        internal static void Recover(Action<string> log)
        {
            Safety.EnsureStateDirectory();
            // Recover the recorded installation before choosing a new one. A
            // saved custom preference must never redirect an older transaction.
            RecoverCore(Safety.DefaultDiscordRoot,
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "discord"),
                Path.Combine(Safety.StateRoot, "v3", "installed-session"), log);
        }

        private static void RecoverCore(string legacyRoot, string profile, string session, Action<string> log)
        {
            Require(session);
            string path = Path.Combine(session, "journal.json"); Require(path);
            if (!File.Exists(path)) return;
            EnsurePrivateDirectory(session, false);
            byte[] bytes = ReadPrivate(path, SettingsLimit);
            string version = JournalVersion(Object(bytes));
            var saved = ValidateJournal(bytes, version, null, legacyRoot);
            string installedRoot = JournalRoot(saved, legacyRoot);
            VerifyRecoveryRoot(installedRoot, version);
            var recovered = Create(Path.Combine(installedRoot, "app-" + version, "Discord.exe"), installedRoot, profile, session, legacyRoot);
            recovered.externalProxy = JournalProxy(saved);
            recovered.Restore();
            if (log != null) log("Önceki oturumun geçici Discord ayarları geri alındı.");
        }

        private static Dictionary<string, object> ValidateJournal(byte[] bytes, string version, string expectedRoot, string legacyRoot)
        {
            var result = Object(bytes);
            object schema, savedVersion, entries, configured;
            if (!result.TryGetValue("schema", out schema) || !(schema is int) || ((int)schema != 1 && (int)schema != 2 && (int)schema != 3) ||
                !result.TryGetValue("version", out savedVersion) || !Equals(savedVersion, version) ||
                !result.TryGetValue("entries", out entries) || !(entries is object[]) ||
                !result.TryGetValue("configured", out configured) || !(configured is bool)) throw Conflict();
            var records = (object[])entries; var modules = new HashSet<int>();
            if (records.Length == 0 || records.Length > 16) throw Conflict();
            foreach (object item in records)
            {
                var record = item as Dictionary<string, object>;
                object module, original;
                if (record == null || record.Count != 2 || !record.TryGetValue("module", out module) || !(module is int) ||
                    (int)module < 1 || !modules.Add((int)module) || !record.TryGetValue("original", out original) || !(original is string)) throw Conflict();
                byte[] entry;
                try { entry = Convert.FromBase64String((string)original); } catch (FormatException) { throw Conflict(); }
                if (entry.Length > EntryLimit || !Original(entry)) throw Conflict();
            }
            var allowed = new HashSet<string>(new[] { "schema", "version", "entries", "configured" }, StringComparer.Ordinal);
            if ((int)schema >= 2) allowed.Add("root");
            if ((int)schema == 3)
            {
                JournalProxy(result);
                allowed.Add("mode"); allowed.Add("proxy_url");
            }
            if ((bool)configured)
            {
                foreach (string key in new[] { "new_legacy", "new_modern" })
                {
                    object value;
                    if (!result.TryGetValue(key, out value) || !(value is string)) throw Conflict();
                    ValidateEndpoint((string)value); allowed.Add(key);
                }
                for (int i = 0; i < SettingKeys.Length; i++)
                {
                    object had;
                    if (!result.TryGetValue("had_" + i, out had) || !(had is bool)) throw Conflict();
                    allowed.Add("had_" + i);
                    if ((bool)had) { if (!result.ContainsKey("old_" + i)) throw Conflict(); allowed.Add("old_" + i); }
                }
            }
            if (result.Keys.Any(key => !allowed.Contains(key))) throw Conflict();
            string root = JournalRoot(result, legacyRoot);
            if (expectedRoot != null && !String.Equals(root, expectedRoot, StringComparison.OrdinalIgnoreCase)) throw Conflict();
            return result;
        }

        private static string JournalVersion(Dictionary<string, object> saved)
        {
            object version; System.Version parsed;
            if (!saved.TryGetValue("version", out version) || !(version is string) ||
                !Regex.IsMatch((string)version, @"\A[0-9]+(?:\.[0-9]+){1,3}\z") ||
                !System.Version.TryParse((string)version, out parsed)) throw Conflict();
            return (string)version;
        }

        private static string JournalRoot(Dictionary<string, object> saved, string legacyRoot)
        {
            if ((int)saved["schema"] == 1) return NormalizeRoot(legacyRoot);
            object root;
            if (!saved.TryGetValue("root", out root) || !(root is string)) throw Conflict();
            return NormalizeRoot((string)root);
        }

        private static string JournalProxy(Dictionary<string, object> saved)
        {
            if ((int)saved["schema"] < 3) return null;
            object mode, proxy;
            if (!saved.TryGetValue("mode", out mode) || !Equals(mode, "external") ||
                !saved.TryGetValue("proxy_url", out proxy) || !(proxy is string)) throw Conflict();
            ValidateProxy((string)proxy);
            return (string)proxy;
        }

        private static string NormalizeRoot(string root)
        {
            if (String.IsNullOrEmpty(root) || root.Length > 32760 || root.Length <= 3 ||
                root.Any(c => Char.IsControl(c) || c == '/' || c == '"' || c == '*' || c == '?' || c == '<' || c == '>' || c == '|') ||
                !Regex.IsMatch(root, @"\A[A-Za-z]:\\") || root.IndexOf(':', 2) >= 0) throw Conflict();
            string canonical;
            try { canonical = Path.GetFullPath(root).TrimEnd('\\'); }
            catch (ArgumentException) { throw Conflict(); }
            catch (NotSupportedException) { throw Conflict(); }
            catch (PathTooLongException) { throw Conflict(); }
            if (!String.Equals(canonical, root, StringComparison.OrdinalIgnoreCase)) throw Conflict();
            Require(canonical);
            return canonical;
        }

        private static void VerifyRecoveryRoot(string root, string version)
        {
#if TEST_BUILD
            // Only this inert transaction fixture can admit synthetic images.
            // This branch and its private allowlist do not exist in production.
            if (fixtureRoots != null && fixtureRoots.Contains(root))
            {
                var fixture = DiscordInstallation.VerifyRecoveryRoot(root, version, VerifyFixtureImage);
                if (!String.Equals(fixture.Root, root, StringComparison.OrdinalIgnoreCase)) throw Conflict();
                return;
            }
#endif
            var verified = DiscordInstallation.VerifyRecoveryRoot(root, version);
            if (!String.Equals(verified.Root, root, StringComparison.OrdinalIgnoreCase)) throw Conflict();
        }

        private byte[] Wrapper()
        {
            if (externalProxy == null) return LegacyWrapper();
            return Utf8.GetBytes("// DiscordAccess installed attachment clicks v4.16\n" +
                "if (process.type === 'browser') {\n" +
                "  try {\n" +
                "    const electron = require('electron');\n" +
                "    const proxy = electron.app.commandLine.getSwitchValue('proxy-server');\n" +
                "    if (proxy === " + Serializer().Serialize(externalProxy) + ") {\n" +
                "      require(" + Serializer().Serialize(hookPath) + ").install(electron, { env: {\n" +
                "        DISCORDACCESS_ATTACHMENTS: '1',\n" +
                "        DISCORDACCESS_DOWNLOAD_LOG: " + Serializer().Serialize(DownloadLogPath) + "\n" +
                "      } });\n" +
                "    }\n" +
                "  } catch (_) {}\n" +
                "}\n" + OfficialEntry + "\n");
        }

        private byte[] LegacyWrapper()
        {
            return Utf8.GetBytes("// DiscordAccess installed attachment clicks v4.13\n" +
                "if (process.env.DISCORDACCESS_ATTACHMENTS === '1') {\n" +
                "  try { require(" + Serializer().Serialize(hookPath) + "); } catch (_) {}\n" +
                "}\n" + OfficialEntry + "\n");
        }
        private void SaveJournal(byte[] expected)
        {
            EnsurePrivateDirectory(sessionRoot, false);
            if (File.Exists(journalPath)) using (PrivateFileTrust.ReadLease(journalPath)) { }
            Replace(journalPath, expected, Json(journal));
            using (PrivateFileTrust.ReadLease(journalPath)) { }
        }
        private static bool Original(byte[] bytes)
        {
            if (bytes == null || bytes.Length > EntryLimit) return false;
            try
            {
                string text = Utf8.GetString(bytes);
                if (text.StartsWith("\uFEFF", StringComparison.Ordinal)) text = text.Substring(1);
                return Regex.IsMatch(text.Trim(), @"\Amodule\.exports\s*=\s*require\(\s*(?<quote>['""])\./core\.asar\k<quote>\s*\);?\z");
            }
            catch (DecoderFallbackException) { return false; }
        }
        private static byte[] HookResource()
        {
            using (Stream stream = typeof(InstalledDiscord).Assembly.GetManifestResourceStream("DiscordAccess.AttachmentDownloadHook"))
            {
                if (stream == null || stream.Length == 0) throw Unsupported();
                byte[] bytes = ReadStream(stream, HookLimit); Utf8.GetString(bytes); return bytes;
            }
        }
        private static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = SettingsLimit, RecursionLimit = 32 }; }
        private static byte[] Json(object value)
        {
            try
            {
                byte[] bytes = Utf8.GetBytes(Serializer().Serialize(value));
                if (bytes.Length > SettingsLimit) throw Conflict(); return bytes;
            }
            catch (ArgumentException) { throw Conflict(); }
            catch (InvalidOperationException) { throw Conflict(); }
        }
        private static bool JsonEqual(object left, object right) { return Same(Json(left), Json(right)); }
        private static Dictionary<string, object> Object(byte[] bytes)
        {
            try
            {
                string text = Utf8.GetString(bytes); if (text.StartsWith("\uFEFF", StringComparison.Ordinal)) text = text.Substring(1);
                var result = Serializer().DeserializeObject(text) as Dictionary<string, object>;
                if (result == null) throw Conflict(); return result;
            }
            catch (ArgumentException) { throw Conflict(); }
            catch (InvalidOperationException) { throw Conflict(); }
        }
        private static byte[] Read(string path, int limit)
        { Require(path); using (FileStream stream = Safety.ReadLease(path)) return ReadStream(stream, limit); }
        private static byte[] ReadPrivate(string path, int limit)
        { Require(path); using (FileStream stream = PrivateFileTrust.ReadLease(path)) return ReadStream(stream, limit); }
        private static byte[] ReadStream(Stream stream, int limit)
        {
            if (stream.Length < 0 || stream.Length > limit) throw Conflict();
            byte[] bytes = new byte[(int)stream.Length]; int offset = 0;
            while (offset < bytes.Length) { int count = stream.Read(bytes, offset, bytes.Length - offset); if (count == 0) throw Conflict(); offset += count; }
            return bytes;
        }
        private static bool Same(byte[] left, byte[] right)
        {
            if (left == null || right == null) return left == right;
            if (left.Length != right.Length) return false;
            for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        private static void Replace(string path, byte[] expected, byte[] replacement)
        {
            FileTransaction.ReplaceExpected(path, expected, replacement, SettingsLimit, Require);
        }
        private static void DeleteExpected(string path, byte[] expected)
        {
            FileTransaction.DeleteExpected(path, expected, SettingsLimit, Require);
        }
        private static void Require(string path)
        {
            path = Path.GetFullPath(path);
            if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.Length < 3 || path[1] != ':' ||
                path.IndexOf(':', 2) >= 0 || !Safety.NoReparse(path)) throw Conflict();
            // File.Exists is false for a dangling link. Check attributes without
            // that shortcut as well, including each existing parent component.
            for (string current = path; !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            {
                try { if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0 && !NativeFile.CloudPlaceholder(current)) throw Conflict(); }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
            }
        }
        private static void EnsurePrivateDirectory(string path, bool create = true)
        {
            Require(path);
            var allowed = new[] { WindowsIdentity.GetCurrent().User, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) };
            if (!Directory.Exists(path))
            {
                if (!create) throw Conflict();
                var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
                foreach (var sid in allowed) security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                Directory.CreateDirectory(path, security);
            }
            Require(path); var actual = Directory.GetAccessControl(path);
            string owner = ((SecurityIdentifier)actual.GetOwner(typeof(SecurityIdentifier))).Value;
            var names = new HashSet<string>(allowed.Select(sid => sid.Value), StringComparer.Ordinal);
            if (!actual.AreAccessRulesProtected || !names.Contains(owner) || actual.GetAccessRules(true, true, typeof(SecurityIdentifier))
                .Cast<FileSystemAccessRule>().Any(rule => rule.AccessControlType == AccessControlType.Allow && !names.Contains(rule.IdentityReference.Value))) throw Conflict();
        }
        private static void ValidateEndpoint(string value)
        {
            Uri uri;
            if (value == null || value.Length > 512 || value.Any(c => Char.IsControl(c) || Char.IsWhiteSpace(c) || c == '\\') ||
                !Regex.IsMatch(value, @"\Ahttp://127\.0\.0\.1:[0-9]{1,5}/[a-zA-Z0-9/_-]+\z") ||
                !Uri.TryCreate(value, UriKind.Absolute, out uri) || uri.Port < 1 || uri.Port > 65535 ||
                uri.Host != "127.0.0.1" || uri.Scheme != "http" || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0) throw Conflict();
        }
        private static void ValidateProxy(string value)
        {
            Uri uri;
            if (value == null || value.Length > 64 || !Regex.IsMatch(value, @"\Ahttp://127\.0\.0\.1:[1-9][0-9]{0,4}\z") ||
                !Uri.TryCreate(value, UriKind.Absolute, out uri) || uri.Port < 1 || uri.Port > 65535 ||
                uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
                value != "http://127.0.0.1:" + uri.Port.ToString(System.Globalization.CultureInfo.InvariantCulture)) throw Conflict();
        }
        private static InvalidDataException Conflict()
        { return new InvalidDataException("Kurulu Discord'un geçici ayarları güvenli biçimde doğrulanamadı. Değişmiş dosya veya tercihin üzerine yazılmadı."); }
        private static InvalidDataException Unsupported()
        { return new InvalidDataException("Kurulu Discord'un resmi sürümü veya başlangıç modülü tanınmadı; uygulama dosyaları değiştirilmedi."); }
        private static InvalidDataException MissingModule()
        { return new InvalidDataException("Kurulu Discord'un beklenen başlangıç modülü bulunamadı; indirme desteği etkinleştirilmedi."); }

#if TEST_BUILD
        private static HashSet<string> fixtureRoots;
        private static IDisposable VerifyFixtureImage(string image)
        {
            string root = Path.GetDirectoryName(Path.GetDirectoryName(image));
            if (fixtureRoots == null || !fixtureRoots.Contains(root) || Path.GetFileName(image) != "Discord.exe") throw Conflict();
            return Safety.ReadLease(image);
        }

        internal static int RunOfflineChecks(string packageRoot)
        {
            string work = Path.Combine(Path.GetFullPath(packageRoot), "work");
            string root = Path.Combine(work, "installed-" + Guid.NewGuid().ToString("N"));
            Require(root);
            if (!Safety.Under(root, work)) throw new InvalidOperationException("Installed fixture escaped work.");
            int checks = 0;
            Action<bool, string> assert = (ok, detail) => { if (!ok) throw new InvalidOperationException(detail); checks++; };
            string installed = Path.Combine(root, "installed"), app = Path.Combine(installed, "app-1.2.3");
            string profile = Path.Combine(root, "roaming", "discord"), session = Path.Combine(root, "state", "installed-session");
            string image = Path.Combine(app, "Discord.exe"), resources = Path.Combine(app, "resources");
            string settingsPath = Path.Combine(profile, "settings.json"), journalPath = Path.Combine(session, "journal.json");
            string moduleRoot = Path.Combine(app, "modules"), junction = Path.Combine(root, "junction");
            var log = new List<string>();
            var priorInterleave = FileTransaction.InterleaveForChecks;
            string legacy = "http://127.0.0.1:32101/fixture/legacy", modern = "http://127.0.0.1:32101/fixture/updates/";
            string[] entryPaths = Enumerable.Range(1, 2).Select(i => Path.Combine(moduleRoot,
                "discord_desktop_core-" + i, "discord_desktop_core", "index.js")).ToArray();
            byte[][] originals = { Utf8.GetBytes(OfficialEntry), Utf8.GetBytes("\uFEFF  module.exports = require(\"./core.asar\")\r\n") };
            byte[] native = Utf8.GetBytes("inert fixture native module; never loaded"), archive = Utf8.GetBytes("inert archive; never loaded");
            Directory.CreateDirectory(resources); Directory.CreateDirectory(profile);
            File.WriteAllText(image, "inert fixture image; never executed");
            File.WriteAllBytes(Path.Combine(app, "updater.node"), native);
            File.WriteAllBytes(Path.Combine(resources, "app.asar"), archive);
            File.WriteAllBytes(Path.Combine(resources, "build_info.json"), Json(new Dictionary<string, object> {
                { "releaseChannel", "stable" }, { "version", "1.2.3" } }));
            for (int i = 0; i < entryPaths.Length; i++)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(entryPaths[i]));
                File.WriteAllBytes(entryPaths[i], originals[i]);
                File.WriteAllBytes(Path.Combine(Path.GetDirectoryName(entryPaths[i]), "core.asar"), archive);
            }
            string oldProfileEntry = Path.Combine(profile, "1.2.3", "modules", "discord_desktop_core", "index.js");
            Directory.CreateDirectory(Path.GetDirectoryName(oldProfileEntry)); File.WriteAllText(oldProfileEntry, "unrelated legacy module fixture");
            var initial = new Dictionary<string, object> {
                { "theme", "initial" }, { "UPDATE_ENDPOINT", "https://fixture.invalid/original" },
                { "SKIP_HOST_UPDATE", false }, { "unrelated", new Dictionary<string, object> { { "sentinel", "PRIVATE_PREFERENCE_CANARY" } } }
            };
            File.WriteAllBytes(settingsPath, Json(initial));
            fixtureRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { installed };
            var prepared = new List<InstalledDiscord>();
            Func<InstalledDiscord> prepare = () => {
                var value = PrepareCore(image, installed, profile, session, log.Add); prepared.Add(value); return value;
            };
            string externalProxyUrl = "http://127.0.0.1:32109";
            Func<InstalledDiscord> prepareExternal = () => {
                var value = PrepareCore(image, installed, profile, session, log.Add, null, externalProxyUrl); prepared.Add(value); return value;
            };
            Action<Action, string> rejects = (action, detail) => {
                bool rejected = false; try { action(); } catch (InvalidDataException) { rejected = true; }
                assert(rejected, detail);
            };
            try
            {
                assert(!Pending(session), "A missing session was reported as pending recovery.");
                byte[] beforeSettings = File.ReadAllBytes(settingsPath);
                var instance = prepare();
                assert(instance.Image == image && instance.ProfilePath == profile && instance.Version == "1.2.3", "Installed identity or normal profile changed.");
                assert(instance.DownloadLogPath == Path.Combine(root, "state", "normal-download-events.log"), "Download log escaped the owned state.");
                assert(Same(beforeSettings, File.ReadAllBytes(settingsPath)), "Prepare modified settings before Configure.");
                assert(File.Exists(journalPath), "Prepare did not persist its recovery journal.");
                var firstJournal = Object(File.ReadAllBytes(journalPath));
                assert(Equals(firstJournal["schema"], 2) && Equals(firstJournal["root"], installed), "New journal did not record the actual custom installation root.");
                assert(PendingRecoveryRootCore(installed, session) == installed, "Pending recovery omitted the recorded custom root.");
                assert(Pending(session), "A prepared session was not reported as pending recovery.");
                assert(entryPaths.All(path => Same(File.ReadAllBytes(path), instance.Wrapper())), "An installed core entry lacks its attachment wrapper.");
                assert(Same(File.ReadAllBytes(instance.hookPath), HookResource()), "Installed hook differs from the embedded resource.");
                assert(!Utf8.GetString(instance.Wrapper()).Contains("MESSAGE") && !Utf8.GetString(instance.Wrapper()).Contains("node-https"), "A broad hook was installed.");
                assert(!File.Exists(instance.DownloadLogPath), "Preparation eagerly created a diagnostic log.");
                rejects(() => prepare(), "A second Prepare silently replaced an outstanding journal.");
                instance.Configure(legacy, modern);
                var configured = Object(File.ReadAllBytes(settingsPath));
                assert(Equals(configured["UPDATE_ENDPOINT"], legacy) && Equals(configured["NEW_UPDATE_ENDPOINT"], modern), "Both native/legacy endpoints were not configured.");
                assert(configured.Count == initial.Count + 1 && Equals(configured["theme"], "initial") && Equals(configured["SKIP_HOST_UPDATE"], false), "Configure changed an unrelated setting.");
                assert(!File.ReadAllText(journalPath).Contains("PRIVATE_PREFERENCE_CANARY"), "Journal copied unrelated preferences.");
                DateTime modified = File.GetLastWriteTimeUtc(settingsPath);
                instance.Configure(legacy, modern);
                assert(File.GetLastWriteTimeUtc(settingsPath) == modified, "Repeated Configure rewrote settings.");
                rejects(() => instance.Configure(legacy.Replace("32101", "32102"), modern), "Configure replaced the session endpoint after activation.");
                configured["theme"] = "changed while open"; configured["newPreference"] = 7;
                File.WriteAllBytes(settingsPath, Json(configured));
                instance.Restore();
                var restored = Object(File.ReadAllBytes(settingsPath));
                assert(Equals(restored["UPDATE_ENDPOINT"], initial["UPDATE_ENDPOINT"]) && !restored.ContainsKey("NEW_UPDATE_ENDPOINT"), "Restore did not undo only the owned keys.");
                assert(Equals(restored["theme"], "changed while open") && Equals(restored["newPreference"], 7), "Restore discarded current preferences.");
                assert(entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "Exact original entry bytes were not restored.");
                assert(!File.Exists(journalPath), "Successful restore retained its journal.");
                assert(!Pending(session), "Restored session was reported as pending recovery.");
                assert(PendingRecoveryRootCore(installed, session) == null, "Completed recovery retained an installation root.");
                instance.Restore(); assert(!File.Exists(journalPath), "Repeated Restore was not idempotent.");

                string hookPath = Path.Combine(session, "attachment-download.cjs");
                // Real child ACLs under the already protected session parent.
                // Both replacement and the transaction's same-byte shortcut
                // must fail before a journal or executable wrapper is changed.
                foreach (byte[] existingHook in new[] { Utf8.GetBytes("inert old hook fixture"), HookResource() })
                {
                    File.WriteAllBytes(hookPath, existingHook);
                    File.SetAccessControl(hookPath, PrivateFileTrustChecks.Security(FileSystemRights.WriteData));
                    string weakAcl = File.GetAccessControl(hookPath).GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access);
                    beforeSettings = File.ReadAllBytes(settingsPath);
                    rejects(() => prepareExternal(), "Unsafe existing hook was reused or replaced.");
                    assert(Same(File.ReadAllBytes(hookPath), existingHook) && weakAcl ==
                        File.GetAccessControl(hookPath).GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access),
                        "Unsafe-hook rejection modified its bytes or ACL.");
                    assert(!File.Exists(journalPath) && Same(File.ReadAllBytes(settingsPath), beforeSettings) &&
                        entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(value => value),
                        "Unsafe-hook rejection activated a wrapper or created recovery state.");
                    File.SetAccessControl(hookPath, PrivateFileTrustChecks.Security());
                }

                // A freshly published hook is verified before the first module
                // wrapper, even if its source's inherited ACL changes in flight.
                File.Delete(hookPath);
                try
                {
                    FileTransaction.InterleaveForChecks = (phase, path) => {
                        if (phase == "create" && path == hookPath)
                        {
                            string source = Directory.GetFiles(session, ".discordaccess-fs-*.pending").Single();
                            File.SetAccessControl(source, PrivateFileTrustChecks.Security(FileSystemRights.WriteData));
                        }
                    };
                    rejects(() => prepareExternal(), "Newly installed unsafe hook activated an entry wrapper.");
                }
                finally { FileTransaction.InterleaveForChecks = priorInterleave; }
                assert(!File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(value => value),
                    "Installed-hook verification failure did not roll back preparation.");
                rejects(() => { using (PrivateFileTrust.ReadLease(hookPath)) { } }, "Installed-hook rejection silently repaired its unsafe ACL.");
                File.SetAccessControl(hookPath, PrivateFileTrustChecks.Security());
                File.Delete(hookPath);

                instance = prepareExternal(); instance.Configure(legacy, modern);
                assert(instance.hookLease != null, "Active installed support did not retain its verified hook lease.");
                bool hookWriteBlocked = false, hookReplaceBlocked = false;
                try { using (new FileStream(hookPath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) { } }
                catch (IOException) { hookWriteBlocked = true; }
                string movedHook = Path.Combine(session, "fixture-moved-hook.cjs");
                try { File.Move(hookPath, movedHook); } catch (IOException) { hookReplaceBlocked = true; }
                assert(hookWriteBlocked && hookReplaceBlocked, "Active support allowed hook content writes or pathname replacement.");
                instance.Restore();
                assert(instance.hookLease == null && !File.Exists(journalPath), "Ordinary restore leaked the hook lease or journal.");
                File.Move(hookPath, movedHook); File.Move(movedHook, hookPath);
                assert(true, "Completed support retained a hook replacement lock.");

                instance = prepareExternal();
                byte[] privateJournal = File.ReadAllBytes(journalPath), privateSettings = File.ReadAllBytes(settingsPath);
                File.SetAccessControl(journalPath, PrivateFileTrustChecks.Security(FileSystemRights.WriteData));
                string weakJournalAcl = File.GetAccessControl(journalPath).GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access);
                rejects(() => PendingRecoveryRootCore(installed, session), "Pending recovery trusted a writable child journal.");
                rejects(() => RecoverCore(installed, profile, session, log.Add), "Recovery trusted a writable child journal.");
                rejects(instance.Restore, "Restore trusted a writable child journal.");
                rejects(() => instance.Configure(legacy, modern), "Configure trusted a writable child journal.");
                assert(Same(File.ReadAllBytes(journalPath), privateJournal) && Same(File.ReadAllBytes(settingsPath), privateSettings) &&
                    weakJournalAcl == File.GetAccessControl(journalPath).GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access) &&
                    entryPaths.All(path => Same(File.ReadAllBytes(path), instance.Wrapper())),
                    "Untrusted journal rejection changed transaction data or repaired its ACL.");
                instance.Dispose();
                assert(instance.hookLease == null && File.Exists(journalPath), "Deferred cleanup discarded recovery evidence or retained its lease.");
                File.SetAccessControl(journalPath, PrivateFileTrustChecks.Security());
                RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(value => value),
                    "A resolved journal ACL fixture did not recover through the ordinary path.");

                instance = prepare(); instance.Configure(legacy, modern);
                RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "Crash recovery did not undo the installed entries.");
                assert(!Object(File.ReadAllBytes(settingsPath)).ContainsKey("NEW_UPDATE_ENDPOINT"), "Crash recovery left a stale native update endpoint.");

                // Recovery has journaled identity evidence for the old signed
                // version. An interrupted newer update must not block undoing
                // that transaction, or permit selecting the corrupt new app.
                string incompleteApp = Path.Combine(installed, "app-1.2.4");
                string incompleteResources = Path.Combine(incompleteApp, "resources");
                Directory.CreateDirectory(incompleteResources);
                string incompleteImage = Path.Combine(incompleteApp, "Discord.exe");
                string incompleteInfo = Path.Combine(incompleteResources, "build_info.json");
                string incompleteArchive = Path.Combine(incompleteResources, "app.asar");
                byte[] incompleteImageBytes = Utf8.GetBytes("INCOMPLETE_IMAGE_CANARY: never executed");
                byte[] incompleteInfoBytes = Utf8.GetBytes("{ corrupt newer metadata; never executed");
                byte[] incompleteArchiveBytes = Utf8.GetBytes("FOREIGN_NEWER_ARCHIVE_CANARY: never loaded");
                File.WriteAllBytes(incompleteImage, incompleteImageBytes);
                File.WriteAllBytes(incompleteInfo, incompleteInfoBytes);
                File.WriteAllBytes(incompleteArchive, incompleteArchiveBytes);
                instance = prepare(); instance.Configure(legacy, modern);
                bool corruptSelectionRejected = false;
                try { DiscordInstallation.VerifyRoot(installed, VerifyFixtureImage); }
                catch (InvalidDataException) { corruptSelectionRejected = true; }
                catch (ArgumentException) { corruptSelectionRejected = true; }
                assert(corruptSelectionRejected, "New selection accepted a corrupt newer installed version.");
                assert(PendingRecoveryRootCore(installed, session) == installed, "Corrupt newer update blocked locating the recorded recovery root.");
                RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "Corrupt newer update blocked the known prior version's crash recovery.");
                assert(!Object(File.ReadAllBytes(settingsPath)).ContainsKey("NEW_UPDATE_ENDPOINT"), "Known-version recovery left an endpoint after a corrupt newer update.");
                assert(Same(File.ReadAllBytes(incompleteImage), incompleteImageBytes) && Same(File.ReadAllBytes(incompleteInfo), incompleteInfoBytes) &&
                    Same(File.ReadAllBytes(incompleteArchive), incompleteArchiveBytes), "Known-version recovery changed a newer partial installation's foreign files.");
                // Each removal targets only the three fixture files just made.
                File.Delete(incompleteImage); File.Delete(incompleteInfo); File.Delete(incompleteArchive);
                Directory.Delete(incompleteResources, false); Directory.Delete(incompleteApp, false);

                // Root selection can change between a crash and the next run.
                // Schema 2 must recover its own installation, rather than the
                // newly preferred one or the standard-path fallback.
                string differentRoot = Path.Combine(root, "different-installation");
                string differentEntry = Path.Combine(differentRoot, "app-1.2.3", "modules", "discord_desktop_core-1", "discord_desktop_core", "index.js");
                Directory.CreateDirectory(Path.GetDirectoryName(differentEntry));
                byte[] unrelatedEntry = Utf8.GetBytes("UNRELATED_INSTALLATION_CANARY: never execute");
                File.WriteAllBytes(differentEntry, unrelatedEntry);
                instance = prepare(); instance.Configure(legacy, modern);
                assert(PendingRecoveryRootCore(differentRoot, session) == installed, "Pending recovery followed a new selection instead of its recorded root.");
                RecoverCore(differentRoot, profile, session, log.Add);
                assert(!File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "Custom crash recovery followed a different selected installation.");
                assert(Same(File.ReadAllBytes(differentEntry), unrelatedEntry), "Recovery changed a different installation.");

                // Before custom roots were supported, schema 1 could only refer
                // to the fixed normal installation. The test supplies its inert
                // equivalent; production always supplies DefaultDiscordRoot.
                instance = prepare(); instance.Configure(legacy, modern);
                var legacyJournal = Object(File.ReadAllBytes(journalPath));
                legacyJournal["schema"] = 1; legacyJournal.Remove("root");
                File.WriteAllBytes(journalPath, Json(legacyJournal));
                assert(PendingRecoveryRootCore(installed, session) == installed, "Legacy pending recovery did not use its fixed default root.");
                RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "Schema 1 backward-compatible recovery failed.");

                instance = prepare(); instance.Configure(legacy, modern);
                byte[] intactJournal = File.ReadAllBytes(journalPath), intactSettings = File.ReadAllBytes(settingsPath);
                var forgedJournal = Object(intactJournal); forgedJournal["root"] = differentRoot;
                File.WriteAllBytes(journalPath, Json(forgedJournal));
                rejects(instance.Restore, "An instance restored a journal for a different root.");
                bool forgedRejected = false;
                try { RecoverCore(installed, profile, session, log.Add); }
                catch (InvalidDataException) { forgedRejected = true; }
                catch (InvalidOperationException) { forgedRejected = true; }
                catch (FileNotFoundException) { forgedRejected = true; }
                assert(forgedRejected, "Recovery accepted an unsigned or non-Discord forged root.");
                assert(Same(File.ReadAllBytes(settingsPath), intactSettings) && entryPaths.All(path => Same(File.ReadAllBytes(path), instance.Wrapper())) &&
                    Same(File.ReadAllBytes(differentEntry), unrelatedEntry) && File.Exists(journalPath), "Rejected forged-root recovery mutated an installation or lost recovery state.");
                foreach (string unsafeRoot in new[] { @"\\server\share\Discord", Path.Combine(installed, "..", "different-installation"),
                    installed + "\\", installed + ":alternate", "~\\AppData\\Local\\Discord" })
                {
                    forgedJournal = Object(intactJournal); forgedJournal["root"] = unsafeRoot;
                    File.WriteAllBytes(journalPath, Json(forgedJournal));
                    rejects(() => PendingRecoveryRootCore(installed, session), "Unsafe recorded installation root was accepted.");
                    assert(Same(File.ReadAllBytes(settingsPath), intactSettings), "Unsafe-root validation modified profile settings.");
                }
                forgedJournal = Object(intactJournal); forgedJournal["schema"] = 1;
                File.WriteAllBytes(journalPath, Json(forgedJournal));
                rejects(() => RecoverCore(installed, profile, session, log.Add), "Legacy journal accepted an unexpected custom-root field.");
                File.WriteAllBytes(journalPath, intactJournal); instance.Restore();
                int logs = log.Count; RecoverCore(installed, profile, session, log.Add);
                assert(log.Count == logs, "Repeated recovery reported a nonexistent session.");
                instance = prepare(); beforeSettings = File.ReadAllBytes(settingsPath);
                RecoverCore(installed, profile, session, log.Add);
                assert(Same(beforeSettings, File.ReadAllBytes(settingsPath)), "Recovery before Configure changed settings.");

                instance = prepare(); instance.Configure(legacy, modern);
                File.WriteAllBytes(entryPaths[0], originals[0]);
                configured = Object(File.ReadAllBytes(settingsPath)); configured["UPDATE_ENDPOINT"] = initial["UPDATE_ENDPOINT"];
                File.WriteAllBytes(settingsPath, Json(configured)); RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath) && Same(File.ReadAllBytes(entryPaths[1]), originals[1]), "Recovery after a partial rollback did not converge.");

                instance = prepare(); instance.Configure(legacy, modern);
                byte[] refreshed = Utf8.GetBytes("\r\nmodule.exports = require('./core.asar');\r\n");
                File.WriteAllBytes(entryPaths[0], refreshed); File.Delete(entryPaths[1]); instance.Restore();
                assert(Same(File.ReadAllBytes(entryPaths[0]), refreshed), "Restore overwrote a refreshed official entry.");
                assert(!File.Exists(entryPaths[1]) && !File.Exists(journalPath), "Restore recreated an obsolete module entry.");
                for (int i = 0; i < entryPaths.Length; i++) File.WriteAllBytes(entryPaths[i], originals[i]);

                instance = prepare(); instance.Configure(legacy, modern);
                byte[] foreign = Utf8.GetBytes("FOREIGN_ENTRY_CANARY: never execute"); File.WriteAllBytes(entryPaths[0], foreign);
                rejects(instance.Restore, "Restore accepted a foreign custom entry.");
                assert(Same(File.ReadAllBytes(entryPaths[0]), foreign) && File.Exists(journalPath), "Restore overwrote foreign entry bytes or lost recovery state.");
                assert(!Object(File.ReadAllBytes(settingsPath)).ContainsKey("NEW_UPDATE_ENDPOINT"), "Entry conflict prevented independent endpoint cleanup.");
                File.WriteAllBytes(entryPaths[0], originals[0]); RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath), "Recovery failed after a foreign entry conflict was resolved.");

                instance = prepare(); instance.Configure(legacy, modern);
                configured = Object(File.ReadAllBytes(settingsPath)); configured["UPDATE_ENDPOINT"] = "https://fixture.invalid/FOREIGN_VALUE_CANARY";
                File.WriteAllBytes(settingsPath, Json(configured)); rejects(instance.Restore, "Restore accepted a foreign endpoint edit.");
                restored = Object(File.ReadAllBytes(settingsPath));
                assert(Equals(restored["UPDATE_ENDPOINT"], configured["UPDATE_ENDPOINT"]) && !restored.ContainsKey("NEW_UPDATE_ENDPOINT"), "Restore overwrote a foreign setting or skipped the other owned setting.");
                assert(File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "Settings conflict lost the journal or prevented entry cleanup.");
                restored["UPDATE_ENDPOINT"] = initial["UPDATE_ENDPOINT"]; File.WriteAllBytes(settingsPath, Json(restored));
                RecoverCore(installed, profile, session, log.Add); assert(!File.Exists(journalPath), "Resolved setting conflict did not recover.");

                foreach (byte[] unknown in new[] { foreign, Utf8.GetBytes(OfficialEntry + "\nrequire('foreign');"), new byte[] { 0xff, 0xfe }, new byte[EntryLimit + 1] })
                {
                    File.WriteAllBytes(entryPaths[1], unknown); beforeSettings = File.ReadAllBytes(settingsPath);
                    rejects(() => prepare(), "Unrecognized entry was accepted during Prepare.");
                    assert(Same(File.ReadAllBytes(entryPaths[1]), unknown) && Same(File.ReadAllBytes(entryPaths[0]), originals[0]) &&
                        Same(File.ReadAllBytes(settingsPath), beforeSettings) && !File.Exists(journalPath), "Entry preflight failure mutated another file.");
                }
                File.WriteAllBytes(entryPaths[1], originals[1]);
                instance = prepare();
                foreach (string endpoint in new[] { "https://127.0.0.1:32101/test", "http://localhost:32101/test", "http://127.0.0.1:0/test",
                    "http://127.0.0.1:99999/test", "http://127.0.0.1:32101/test?secret", "http://127.0.0.1:32101/test#fragment",
                    "http://user@127.0.0.1:32101/test", "http://127.0.0.1:32101/../test", "http://127.0.0.1:32101/test\\bad", "http://127.0.0.1:32101/test\n" })
                    rejects(() => instance.Configure(endpoint, modern), "Invalid endpoint was accepted.");
                assert(!(bool)Object(File.ReadAllBytes(journalPath))["configured"], "Invalid endpoint changed journal activation state.");
                instance.Restore();

                beforeSettings = File.ReadAllBytes(settingsPath);
                foreach (string invalidProxy in new[] { "http://127.0.0.1:0", "http://127.0.0.1:99999", "http://127.0.0.1:032109",
                    "https://127.0.0.1:32109", "http://localhost:32109", "http://127.0.0.1:32109/", "http://127.0.0.1:32109?secret",
                    "http://user@127.0.0.1:32109", "http://127.0.0.1:32109\n" })
                {
                    rejects(() => PrepareCore(image, installed, profile, session, log.Add, null, invalidProxy), "Invalid external-launch proxy was accepted.");
                    assert(!File.Exists(journalPath) && Same(File.ReadAllBytes(settingsPath), beforeSettings) &&
                        entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "Invalid external-launch proxy modified the installed client.");
                }
                instance = prepareExternal();
                var externalJournal = Object(File.ReadAllBytes(journalPath));
                assert(Equals(externalJournal["schema"], 3) && Equals(externalJournal["mode"], "external") &&
                    Equals(externalJournal["proxy_url"], externalProxyUrl), "External mode did not record its activation identity.");
                string externalWrapper = Utf8.GetString(instance.Wrapper());
                assert(externalWrapper.Contains("process.type === 'browser'") && externalWrapper.Contains("getSwitchValue('proxy-server')") &&
                    externalWrapper.Contains(Serializer().Serialize(externalProxyUrl)), "External attachment activation lacks its browser/proxy guards.");
                assert(externalWrapper.Contains(".install(electron, { env: {") && externalWrapper.Contains("DISCORDACCESS_ATTACHMENTS: '1'") &&
                    externalWrapper.Contains(Serializer().Serialize(instance.DownloadLogPath)) && !externalWrapper.Contains("process.env.") &&
                    !externalWrapper.Contains("user-data-dir"), "External attachment activation changed global environment or profile selection.");
                assert(Same(File.ReadAllBytes(instance.hookPath), HookResource()), "External mode changed the reviewed attachment hook.");
                assert(entryPaths.All(path => Same(File.ReadAllBytes(path), instance.Wrapper())) &&
                    !Same(instance.Wrapper(), instance.LegacyWrapper()), "External mode retained the inherited-environment-only wrapper.");
                assert(Same(File.ReadAllBytes(settingsPath), beforeSettings), "External preparation configured settings prematurely.");
                // Node's fixture runner can evaluate these exact generated
                // bytes with stub Electron/require; no real Discord is launched.
                File.WriteAllBytes(Path.Combine(work, "external-wrapper-fixture.cjs"), instance.Wrapper());
                File.WriteAllBytes(Path.Combine(work, "external-wrapper-fixture.json"), Json(new Dictionary<string, object> {
                    { "proxy", externalProxyUrl }, { "hook", instance.hookPath }, { "downloadLog", instance.DownloadLogPath } }));
                instance.Configure(legacy, modern);
                configured = Object(File.ReadAllBytes(settingsPath)); configured["externalPreference"] = "kept";
                File.WriteAllBytes(settingsPath, Json(configured));
                instance.Restore();
                restored = Object(File.ReadAllBytes(settingsPath));
                assert(!File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "External preparation did not restore its exact original entries.");
                assert(Equals(restored["externalPreference"], "kept") && !restored.ContainsKey("NEW_UPDATE_ENDPOINT"), "External restore replaced unrelated user preferences or left an endpoint.");

                instance = prepareExternal(); instance.Configure(legacy, modern);
                assert(PendingRecoveryRootCore(installed, session) == installed, "External crash journal omitted its actual installation root.");
                RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath) && entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(x => x), "External crash recovery did not recognize its recorded wrapper.");
                assert(!Object(File.ReadAllBytes(settingsPath)).ContainsKey("NEW_UPDATE_ENDPOINT"), "External crash recovery retained the update endpoint.");

                instance = prepareExternal(); instance.Configure(legacy, modern);
                byte[] intactExternalJournal = File.ReadAllBytes(journalPath), intactExternalSettings = File.ReadAllBytes(settingsPath);
                externalJournal = Object(intactExternalJournal); externalJournal["proxy_url"] = "http://127.0.0.1:32110";
                File.WriteAllBytes(journalPath, Json(externalJournal));
                rejects(instance.Restore, "Active external mode accepted a different journal proxy.");
                assert(Same(File.ReadAllBytes(settingsPath), intactExternalSettings) && entryPaths.All(path => Same(File.ReadAllBytes(path), instance.Wrapper())),
                    "An external journal identity conflict changed user settings or entries.");
                externalJournal = Object(intactExternalJournal); externalJournal["mode"] = "unexpected";
                File.WriteAllBytes(journalPath, Json(externalJournal));
                rejects(() => PendingRecoveryRootCore(installed, session), "Unknown external activation mode was accepted.");
                File.WriteAllBytes(journalPath, intactExternalJournal);
                byte[] foreignExternal = Utf8.GetBytes(Utf8.GetString(instance.Wrapper()).Replace("'browser'", "'renderer'"));
                File.WriteAllBytes(entryPaths[0], foreignExternal);
                rejects(instance.Restore, "External rollback accepted a modified activation wrapper.");
                assert(Same(File.ReadAllBytes(entryPaths[0]), foreignExternal) && File.Exists(journalPath), "External rollback overwrote a foreign wrapper or lost its journal.");
                File.WriteAllBytes(entryPaths[0], originals[0]); RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath), "Resolved external wrapper conflict did not recover.");

                instance = prepare();
                var tampered = Object(File.ReadAllBytes(journalPath)); tampered["version"] = "../outside";
                byte[] savedJournal = File.ReadAllBytes(journalPath); File.WriteAllBytes(journalPath, Json(tampered));
                rejects(() => RecoverCore(installed, profile, session, log.Add), "Journal traversal was accepted.");
                assert(entryPaths.All(path => Same(File.ReadAllBytes(path), instance.Wrapper())), "Rejected journal mutated an entry.");
                File.WriteAllBytes(journalPath, savedJournal);
                tampered = Object(savedJournal); ((Dictionary<string, object>)((object[])tampered["entries"])[0])["original"] = Convert.ToBase64String(foreign);
                File.WriteAllBytes(journalPath, Json(tampered)); rejects(instance.Restore, "Journal was allowed to restore executable foreign entry bytes.");
                File.WriteAllBytes(journalPath, savedJournal); instance.Restore();

                rejects(() => PrepareCore(Path.Combine(root, "outside", "app-1.2.3", "Discord.exe"), installed, profile, session, log.Add), "Nonstandard installed image was accepted.");
                rejects(() => PrepareCore(image, installed, profile, @"\\server\share\fixture", log.Add), "Remote journal root was accepted.");
                string missing = entryPaths[1] + ".fixture-missing"; File.Move(entryPaths[1], missing);
                rejects(() => prepare(), "Missing installed core entry was silently ignored.");
                assert(!File.Exists(journalPath), "Missing entry created recovery state."); File.Move(missing, entryPaths[1]);

                // Real settings, module and recovery-journal call chains use
                // the same bounded filesystem transaction as startup journals.
                // The competing writer always swaps a regular inert file in
                // after the helper compares the old object's bytes.
                Action<string, byte[]> atomicIncoming = (path, bytes) => {
                    string incoming = Path.Combine(Path.GetDirectoryName(path), "fixture-incoming-" + Guid.NewGuid().ToString("N"));
                    File.WriteAllBytes(incoming, bytes); File.Replace(incoming, path, null);
                };
                Func<string, byte[], bool> backedUp = (path, bytes) => Directory.GetFiles(Path.GetDirectoryName(path), ".discordaccess-fs-*.preserved")
                    .Any(candidate => Same(File.ReadAllBytes(candidate), bytes));
                instance = prepare();
                var incomingSettings = Object(File.ReadAllBytes(settingsPath)); incomingSettings["concurrentPreference"] = "SETTINGS_RACE_CANARY";
                byte[] incomingSettingsBytes = Json(incomingSettings);
                try
                {
                    FileTransaction.InterleaveForChecks = (phase, path) => {
                        if (phase == "replace" && path == settingsPath) atomicIncoming(path, incomingSettingsBytes);
                    };
                    rejects(() => instance.Configure(legacy, modern), "Configure accepted a replaced settings object.");
                }
                finally { FileTransaction.InterleaveForChecks = priorInterleave; }
                assert(Same(File.ReadAllBytes(settingsPath), incomingSettingsBytes) && backedUp(settingsPath, incomingSettingsBytes),
                    "Configure discarded a concurrent preference file or its actual displaced backup.");
                assert(File.Exists(journalPath), "Settings conflict lost the recovery journal.");
                instance.Restore();
                assert(!File.Exists(journalPath) && Same(File.ReadAllBytes(settingsPath), incomingSettingsBytes), "Settings race recovery discarded foreign preferences.");

                byte[] incomingEntry = Utf8.GetBytes("CONCURRENT_OFFICIAL_UPDATER_CANARY: inert; never execute");
                try
                {
                    FileTransaction.InterleaveForChecks = (phase, path) => {
                        if (phase == "replace" && path == entryPaths[0]) atomicIncoming(path, incomingEntry);
                    };
                    rejects(() => prepare(), "Prepare accepted a replaced module entry object.");
                }
                finally { FileTransaction.InterleaveForChecks = priorInterleave; }
                assert(Same(File.ReadAllBytes(entryPaths[0]), incomingEntry) && backedUp(entryPaths[0], incomingEntry),
                    "Prepare discarded a concurrent module entry or its actual displaced backup.");
                assert(File.Exists(journalPath) && Same(File.ReadAllBytes(entryPaths[1]), originals[1]), "Module race rollback lost evidence or modified another entry.");
                File.WriteAllBytes(entryPaths[0], originals[0]); RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath), "Resolved module race did not recover.");

                instance = prepare(); byte[] beforeJournalRace = File.ReadAllBytes(journalPath);
                var incomingJournal = Object(beforeJournalRace); incomingJournal["FOREIGN_JOURNAL_CANARY"] = true;
                byte[] incomingJournalBytes = Json(incomingJournal);
                try
                {
                    FileTransaction.InterleaveForChecks = (phase, path) => {
                        if (phase == "replace" && path == journalPath) atomicIncoming(path, incomingJournalBytes);
                    };
                    rejects(() => instance.Configure(legacy, modern), "SaveJournal accepted a replaced journal object.");
                }
                finally { FileTransaction.InterleaveForChecks = priorInterleave; }
                assert(Same(File.ReadAllBytes(journalPath), incomingJournalBytes) && backedUp(journalPath, incomingJournalBytes),
                    "SaveJournal discarded the concurrent recovery evidence.");
                File.WriteAllBytes(journalPath, beforeJournalRace); instance.Restore();
                assert(!File.Exists(journalPath), "Resolved journal replacement race did not recover.");

                instance = prepare(); beforeJournalRace = File.ReadAllBytes(journalPath);
                incomingJournal = Object(beforeJournalRace); incomingJournal["FOREIGN_DELETE_CANARY"] = true;
                incomingJournalBytes = Json(incomingJournal);
                try
                {
                    FileTransaction.InterleaveForChecks = (phase, path) => {
                        if (phase == "delete" && path == journalPath) atomicIncoming(path, incomingJournalBytes);
                    };
                    rejects(instance.Restore, "Restore accepted a replaced journal during deletion.");
                }
                finally { FileTransaction.InterleaveForChecks = priorInterleave; }
                assert(Same(File.ReadAllBytes(journalPath), incomingJournalBytes), "Restore deleted renamed-in foreign recovery evidence.");
                assert(entryPaths.Select((path, i) => Same(File.ReadAllBytes(path), originals[i])).All(value => value), "Journal delete conflict skipped independent module cleanup.");
                File.WriteAllBytes(journalPath, beforeJournalRace); RecoverCore(installed, profile, session, log.Add);
                assert(!File.Exists(journalPath), "Resolved journal deletion race did not recover.");

                // A junction is a directory-only fixture; it is never followed
                // for writes and is removed nonrecursively before cleanup.
                using (var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo {
                    FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"),
                    Arguments = "/d /c mklink /J \"" + junction + "\" \"" + profile + "\"",
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }))
                {
                    process.StandardOutput.ReadToEnd(); process.StandardError.ReadToEnd();
                    if (!process.WaitForExit(10000) || process.ExitCode != 0) throw new InvalidOperationException("Could not create the local junction fixture.");
                }
                rejects(() => PrepareCore(image, installed, junction, session, log.Add), "A redirected normal profile was accepted.");
                rejects(() => PrepareCore(image, installed, profile, Path.Combine(junction, "session"), log.Add), "A redirected journal ancestor was accepted.");
                assert(!File.Exists(journalPath) && !Directory.Exists(Path.Combine(profile, "session")), "Reparse rejection changed its target.");
                Directory.Delete(junction, false);
                assert(File.ReadAllText(oldProfileEntry) == "unrelated legacy module fixture", "Native integration modified the legacy profile module.");
                assert(Same(File.ReadAllBytes(Path.Combine(app, "updater.node")), native) && Same(File.ReadAllBytes(Path.Combine(resources, "app.asar")), archive), "Integration modified native updater or application archive.");
                assert(entryPaths.All(path => Same(File.ReadAllBytes(Path.Combine(Path.GetDirectoryName(path), "core.asar")), archive)), "Integration modified a desktop archive.");
                assert(log.All(line => !line.Contains("CANARY") && !line.Contains("http") && !line.Contains(root)), "Recovery log leaked private fixture values or paths.");
            }
            finally
            {
                FileTransaction.InterleaveForChecks = priorInterleave;
                foreach (var value in prepared) value.Dispose();
                fixtureRoots = null;
                if (Directory.Exists(junction) && (File.GetAttributes(junction) & FileAttributes.ReparsePoint) != 0) Directory.Delete(junction, false);
                if (Safety.Under(root, work) && Safety.NoReparse(root) && !Directory.Exists(junction)) Directory.Delete(root, true);
            }
            return checks;
        }
#endif
    }
}
