using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace DiscordAccess
{
    // Owns only the application/profile beneath DiscordAccess's separate v3 state.
    // The installed application is a read-only source; its account data is never read.
    internal sealed class IsolatedDiscord
    {
        internal string Image { get; private set; }
        internal string ProfileRoot { get; private set; }
        internal string ProfilePath { get; private set; }
        internal string Version { get; private set; }
        internal string DownloadLogPath { get; private set; }
        private string stateRoot;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        private const string CopyMarker = ".discordaccess-copy-v3";

        internal static IsolatedDiscord Prepare(string sourceImage, Action<string> log)
        {
            Safety.EnsureStateDirectory();
            return Prepare(sourceImage, Path.Combine(Safety.StateRoot, "v3"), log);
        }

        internal void Configure(string updateEndpoint, string newUpdateEndpoint)
        { WriteSettings(ProfilePath, stateRoot, updateEndpoint, newUpdateEndpoint); }

        private static IsolatedDiscord Prepare(string sourceImage, string stateRoot,
            string updateEndpoint, string newUpdateEndpoint, Action<string> log)
        {
            var result = Prepare(sourceImage, stateRoot, log);
            result.Configure(updateEndpoint, newUpdateEndpoint);
            return result;
        }

        private static IsolatedDiscord Prepare(string sourceImage, string stateRoot, Action<string> log)
        {
            sourceImage = Path.GetFullPath(sourceImage);
            stateRoot = Path.GetFullPath(stateRoot);
            RequirePlain(sourceImage); RequirePlain(stateRoot);
            if (!File.Exists(sourceImage) || !String.Equals(Path.GetFileName(sourceImage), "Discord.exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Resmi Discord uygulama dosyası bulunamadı.");
            string source = Path.GetDirectoryName(sourceImage);
            string appName = Path.GetFileName(source);
            System.Version parsed;
            if (!appName.StartsWith("app-", StringComparison.Ordinal) || !System.Version.TryParse(appName.Substring(4), out parsed))
                throw new InvalidDataException("Discord sürüm klasörü tanınmadı.");
            string version = appName.Substring(4);
            if (Safety.Under(source, stateRoot) || Safety.Under(stateRoot, source))
                throw new InvalidDataException("Kaynak Discord ve ayrı test klasörü çakışıyor.");
            if (File.Exists(Path.Combine(source, "version.dll")) || File.Exists(Path.Combine(source, "drover.ini")))
                throw new InvalidDataException("Kaynak Discord klasöründe önceki üçüncü taraf ekleri var.");
            var build = ReadObject(Path.Combine(source, "resources", "build_info.json"));
            object channel, buildVersion;
            if (!build.TryGetValue("releaseChannel", out channel) || !String.Equals(channel as string, "stable", StringComparison.Ordinal) ||
                !build.TryGetValue("version", out buildVersion) || !String.Equals(buildVersion as string, version, StringComparison.Ordinal))
                throw new InvalidDataException("Bu sürümde yalnızca standart Discord Stable kurulumu destekleniyor.");

            var result = new IsolatedDiscord { Version = version, stateRoot = stateRoot, ProfileRoot = Path.Combine(stateRoot, "profile") };
            result.ProfilePath = Path.Combine(result.ProfileRoot, "discord");
            string clientRoot = Path.Combine(stateRoot, "client"), destination = Path.Combine(clientRoot, appName);
            EnsureDirectory(clientRoot, stateRoot);
            EnsureDirectory(result.ProfilePath, stateRoot);
            string marker = Path.Combine(destination, CopyMarker);
            if (!Directory.Exists(destination))
            {
                string staging = Path.Combine(clientRoot, appName + ".preparing-" + Guid.NewGuid().ToString("N"));
                EnsureDirectory(staging, stateRoot);
                if (log != null) log("Discord uygulamasının ayrı test kopyası hazırlanıyor. İlk hazırlık birkaç dakika sürebilir.");
                // Omitting this native updater selects Discord's bundled legacy
                // updater. Only that updater honors SKIP_HOST_UPDATE; the native
                // one may rewrite the normal installation's shortcuts/Run key.
                CopyTree(source, staging, stateRoot, delegate(string file, bool directory)
                {
                    return (directory && String.Equals(file, "modules", StringComparison.OrdinalIgnoreCase)) ||
                        (!directory && String.Equals(file, "updater.node", StringComparison.OrdinalIgnoreCase));
                });
                WriteObject(Path.Combine(staging, CopyMarker), new Dictionary<string, object> {
                    { "version", version }, { "mode", "legacy-module-updater" } }, stateRoot);
                RequireOwned(staging, stateRoot); RequireOwned(destination, stateRoot);
                RequirePlain(staging); RequirePlain(clientRoot); RequirePlain(destination);
                Directory.Move(staging, destination);
            }
            else
            {
                RequirePlain(destination);
                if (!File.Exists(marker)) throw new InvalidDataException("Ayrı Discord kopyası tamamlanmamış. v3/client içindeki bu sürüm klasörünü yeniden hazırlayın.");
                var metadata = ReadObject(marker);
                object mode, savedVersion;
                if (!metadata.TryGetValue("mode", out mode) || !String.Equals(mode as string, "legacy-module-updater", StringComparison.Ordinal) ||
                    !metadata.TryGetValue("version", out savedVersion) || !String.Equals(savedVersion as string, version, StringComparison.Ordinal))
                    throw new InvalidDataException("Ayrı Discord kopyasının bilgileri doğrulanamadı.");
            }
            RequireCachedFile(Path.Combine(destination, "Discord.exe"), destination);
            RequireCachedFile(Path.Combine(destination, "resources", "app.asar"), destination);
            RequireCachedFile(Path.Combine(destination, "resources", "build_info.json"), destination);
            // Never silently retain a native updater from an earlier test copy.
            string nativeUpdater = Path.Combine(destination, "updater.node");
            if (File.Exists(nativeUpdater))
            {
                RequireOwned(nativeUpdater, stateRoot); RequirePlain(nativeUpdater);
                File.Delete(nativeUpdater);
            }
            string versionedProfile = Path.Combine(result.ProfilePath, version);
            EnsureDirectory(versionedProfile, stateRoot);
            SeedModules(source, Path.Combine(versionedProfile, "modules"), stateRoot);
            result.DownloadLogPath = DesktopIntegration.EnsureOfficialEntry(stateRoot, version);
            if (log != null) log("Discord ek dosyalarının ayrı uygulama içinde indirilmesi hazırlandı.");
            WriteText(Path.Combine(versionedProfile, ".first-run"), "true", stateRoot);
            result.Image = Path.Combine(destination, "Discord.exe");
            return result;
        }

        private static void SeedModules(string source, string moduleRoot, string stateRoot)
        {
            EnsureDirectory(moduleRoot, stateRoot);
            string installedPath = Path.Combine(moduleRoot, "installed.json");
            if (File.Exists(installedPath))
            {
                RequirePlain(installedPath);
                var cached = ReadObject(installedPath);
                if (!cached.ContainsKey("discord_desktop_core")) throw MissingCache(installedPath, moduleRoot);
                ValidateCorePayload(source, moduleRoot);
                return;
            }
            string modernRoot = Path.Combine(source, "modules");
            var installed = new Dictionary<string, object>(StringComparer.Ordinal);
            if (Directory.Exists(modernRoot))
            {
                RequirePlain(modernRoot);
                var selected = new Dictionary<string, KeyValuePair<int, string>>(StringComparer.Ordinal);
                foreach (string module in Directory.GetDirectories(modernRoot))
                {
                    RequirePlain(module);
                    Match match = Regex.Match(Path.GetFileName(module), @"^(discord_[a-z0-9_]+)-([0-9]+)$", RegexOptions.CultureInvariant);
                    int moduleVersion;
                    if (!match.Success || !Int32.TryParse(match.Groups[2].Value, out moduleVersion) || moduleVersion < 1) continue;
                    string name = match.Groups[1].Value, payload = Path.Combine(module, name);
                    if (!Directory.Exists(payload)) continue;
                    RequirePlain(payload);
                    KeyValuePair<int, string> previous;
                    if (!selected.TryGetValue(name, out previous) || previous.Key < moduleVersion)
                        selected[name] = new KeyValuePair<int, string>(moduleVersion, payload);
                }
                foreach (var entry in selected)
                {
                    string destination = Path.Combine(moduleRoot, entry.Key);
                    EnsureDirectory(destination, stateRoot);
                    CopyTree(entry.Value.Value, destination, stateRoot, null);
                    installed[entry.Key] = new Dictionary<string, object> { { "installedVersion", entry.Value.Key } };
                }
            }
            // Recent builds contain a zero-version bootstrap manifest without
            // zip payloads. Their already installed application modules must be
            // seeded, otherwise legacy startup loops on missing bootstrap zips.
            if (!installed.ContainsKey("discord_desktop_core"))
                throw new InvalidDataException("Discord uygulama modülleri bulunamadı. Resmi Discord kurulumunu tamamlayıp yeniden deneyin.");
            ValidateCorePayload(source, moduleRoot);
            WriteObject(installedPath, installed, stateRoot);
        }

        private static void ValidateCorePayload(string source, string moduleRoot)
        {
            string cachedCore = Path.Combine(moduleRoot, "discord_desktop_core");
            RequireCachedFile(Path.Combine(cachedCore, "index.js"), moduleRoot);
            // Check presence, not equality: this isolated module may legitimately
            // have received a newer official payload since it was first seeded.
            string sourceModules = Path.Combine(source, "modules");
            if (!Directory.Exists(sourceModules)) return;
            RequirePlain(sourceModules);
            foreach (string directory in Directory.GetDirectories(sourceModules, "discord_desktop_core-*"))
            {
                RequirePlain(directory);
                string archive = Path.Combine(directory, "discord_desktop_core", "core.asar");
                if (File.Exists(archive))
                {
                    RequirePlain(archive);
                    RequireCachedFile(Path.Combine(cachedCore, "core.asar"), moduleRoot);
                    break;
                }
            }
        }

        private static void RequireCachedFile(string path, string repairRoot)
        {
            RequirePlain(path);
            if (!File.Exists(path)) throw MissingCache(path, repairRoot);
        }

        private static InvalidDataException MissingCache(string path, string repairRoot)
        {
            return new InvalidDataException("Ayrı Discord önbelleğinde gerekli dosya eksik: " + path +
                ". Discord Erişim kapalıyken yalnızca şu önbellek klasörünü yeniden adlandırıp tekrar Bağlan'a basın: " + repairRoot +
                ". Normal Discord kurulumu veya hesap profili üzerinde işlem yapmayın.");
        }

        private static void WriteSettings(string profile, string stateRoot, string legacyEndpoint, string nativeEndpoint)
        {
            ValidateLoopbackEndpoint(legacyEndpoint); ValidateLoopbackEndpoint(nativeEndpoint);
            string path = Path.Combine(profile, "settings.json");
            var settings = File.Exists(path) ? ReadObject(path) : new Dictionary<string, object>();
            settings["UPDATE_ENDPOINT"] = legacyEndpoint.TrimEnd('/');
            settings["NEW_UPDATE_ENDPOINT"] = nativeEndpoint.TrimEnd('/') + "/";
            settings["SKIP_HOST_UPDATE"] = true;
            settings["SKIP_MODULE_UPDATE"] = false;
            settings["USE_PINNED_UPDATE_MANIFEST"] = false;
            WriteObject(path, settings, stateRoot);
        }

        private static void ValidateLoopbackEndpoint(string value)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri) || uri.Scheme != "http" || uri.Host != "127.0.0.1" ||
                uri.Port < 1 || !String.IsNullOrEmpty(uri.UserInfo) || !String.IsNullOrEmpty(uri.Fragment) || !String.IsNullOrEmpty(uri.Query))
                throw new ArgumentException("Güncelleme köprüsü yalnızca yerel 127.0.0.1 adresini kullanabilir.");
        }

        private static Dictionary<string, object> ReadObject(string path)
        {
            using (var stream = Safety.ReadLease(path))
            {
                if (stream.Length > 1024 * 1024) throw new InvalidDataException("Discord ayar dosyası beklenenden büyük.");
                using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    var result = new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()) as Dictionary<string, object>;
                    if (result == null) throw new InvalidDataException("Discord ayar dosyası JSON nesnesi olmalı.");
                    return result;
                }
            }
        }

        private static void CopyTree(string source, string destination, string stateRoot, Func<string, bool, bool> skipRoot)
        {
            RequirePlain(source); EnsureDirectory(destination, stateRoot);
            foreach (string file in Directory.GetFiles(source))
            {
                // A running installed Discord can hold these transient files
                // exclusively. They are not application payloads and must be
                // filtered before inspecting/opening their filesystem entries.
                string name = Path.GetFileName(file);
                if (IsRuntimeOutput(name) || (skipRoot != null && skipRoot(name, false))) continue;
                RequirePlain(file);
                string target = Path.Combine(destination, name);
                RequireOwned(target, stateRoot); RequirePlain(target);
                using (var input = Safety.ReadLease(file))
                using (var output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None)) input.CopyTo(output);
            }
            foreach (string directory in Directory.GetDirectories(source))
            {
                if (skipRoot != null && skipRoot(Path.GetFileName(directory), true)) continue;
                RequirePlain(directory);
                CopyTree(directory, Path.Combine(destination, Path.GetFileName(directory)), stateRoot, null);
            }
        }

        private static bool IsRuntimeOutput(string name)
        {
            // Match whole suffixes: a required asset such as diagnostics.log.node
            // is still copied using the same strict lease as every other payload.
            string extension = Path.GetExtension(name);
            return String.Equals(extension, ".dmp", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(extension, ".mdmp", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(extension, ".hdmp", StringComparison.OrdinalIgnoreCase) ||
                Regex.IsMatch(name, @"\.log(?:\.(?:[0-9]+|old|bak))?(?:\.gz)?$",
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }

        private static void WriteObject(string path, object value, string stateRoot)
        { WriteText(path, new JavaScriptSerializer().Serialize(value), stateRoot); }

        private static void WriteText(string path, string value, string stateRoot)
        {
            RequireOwned(path, stateRoot); RequirePlain(path);
            string temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                byte[] bytes = Utf8.GetBytes(value);
                stream.Write(bytes, 0, bytes.Length); stream.Flush(true);
            }
            RequirePlain(path);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }

        private static void EnsureDirectory(string path, string stateRoot)
        { RequireOwned(path, stateRoot); RequirePlain(path); Directory.CreateDirectory(path); RequirePlain(path); }
        private static void RequireOwned(string path, string stateRoot)
        { if (!Safety.Under(path, stateRoot)) throw new InvalidDataException("Ayrı test klasörünün dışına yazma engellendi."); }
        private static void RequirePlain(string path)
        { if (!Safety.NoReparse(path)) throw new InvalidDataException("Discord kopyasında bağlantı/reparse yolu kabul edilmiyor."); }

        // Pure local fixture: no real Discord executable, profile or network use.
        internal static void FixtureCheck(string fixtureRoot)
        {
            string root = Path.Combine(Path.GetFullPath(fixtureRoot), "isolation-" + Guid.NewGuid().ToString("N"));
            string source = Path.Combine(root, "installed", "app-1.2.3"), state = Path.Combine(root, "v3");
            Directory.CreateDirectory(Path.Combine(source, "resources"));
            Directory.CreateDirectory(Path.Combine(source, "modules", "discord_desktop_core-7", "discord_desktop_core"));
            File.WriteAllText(Path.Combine(source, "Discord.exe"), "fixture executable, never run");
            File.WriteAllText(Path.Combine(source, "updater.node"), "fixture native updater, never loaded");
            File.WriteAllText(Path.Combine(source, "resources", "app.asar"), "fixture archive, never loaded");
            File.WriteAllText(Path.Combine(source, "resources", "build_info.json"), "{\"version\":\"1.2.3\",\"releaseChannel\":\"stable\"}");
            File.WriteAllText(Path.Combine(source, "modules", "discord_desktop_core-7", "discord_desktop_core", "index.js"), "module.exports = require('./core.asar');");
            File.WriteAllText(Path.Combine(source, "modules", "discord_desktop_core-7", "discord_desktop_core", "core.asar"), "fixture core archive");
            string dispatch = Path.Combine(source, "modules", "discord_dispatch-1", "discord_dispatch");
            Directory.CreateDirectory(dispatch);
            string requiredPayload = Path.Combine(dispatch, "dispatch.node");
            File.WriteAllText(requiredPayload, "fixture required native module");
            File.WriteAllText(Path.Combine(dispatch, "diagnostics.log.node"), "fixture required payload with log in its name");
            string[] runtimeOutputs = {
                Path.Combine(dispatch, "dispatch.log"),
                Path.Combine(dispatch, "dispatch.log.1"),
                Path.Combine(dispatch, "dispatch.LOG.2.gz"),
                Path.Combine(dispatch, "crash.dmp"),
                Path.Combine(source, "discord.log")
            };
            foreach (string runtimeOutput in runtimeOutputs) File.WriteAllText(runtimeOutput, "fixture transient output");
            string seededModules = Path.Combine(state, "profile", "discord", "1.2.3", "modules");
            string seededDispatch = Path.Combine(seededModules, "discord_dispatch");
            Directory.CreateDirectory(seededDispatch);
            File.WriteAllText(Path.Combine(seededDispatch, "dispatch.node"), "partial old seed");
            IsolatedDiscord copy;
            var runtimeLocks = new List<FileStream>();
            try
            {
                foreach (string runtimeOutput in runtimeOutputs)
                    runtimeLocks.Add(new FileStream(runtimeOutput, FileMode.Open, FileAccess.ReadWrite, FileShare.None));
                bool lockedPayloadRejected = false;
                using (var lockedPayload = new FileStream(requiredPayload, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                {
                    try { Prepare(Path.Combine(source, "Discord.exe"), state, null); }
                    catch (IOException) { lockedPayloadRejected = true; }
                }
                if (!lockedPayloadRejected || File.Exists(Path.Combine(seededModules, "installed.json")))
                    throw new InvalidOperationException("Locked required payload was accepted or partial module seed was marked complete.");
                // The completed application copy and incomplete module seed from
                // the first attempt are reused while the logs remain locked.
                copy = Prepare(Path.Combine(source, "Discord.exe"), state, "http://127.0.0.1:4567/api", "http://127.0.0.1:4567/updates", null);
            }
            finally { foreach (var runtimeLock in runtimeLocks) runtimeLock.Dispose(); }
            if (File.ReadAllText(Path.Combine(seededDispatch, "dispatch.node")) != "fixture required native module" ||
                !File.Exists(Path.Combine(seededDispatch, "diagnostics.log.node")) ||
                !File.Exists(Path.Combine(seededModules, "installed.json")))
                throw new InvalidOperationException("Partial module seed did not resume with its required payloads.");
            foreach (string runtimeOutput in runtimeOutputs)
            {
                string targetRoot = String.Equals(Path.GetDirectoryName(runtimeOutput), source, StringComparison.OrdinalIgnoreCase)
                    ? Path.GetDirectoryName(copy.Image) : seededDispatch;
                if (File.Exists(Path.Combine(targetRoot, Path.GetFileName(runtimeOutput))) ||
                    File.ReadAllText(runtimeOutput) != "fixture transient output")
                    throw new InvalidOperationException("Runtime output was copied or its installed source was changed.");
            }
            if (!File.Exists(copy.Image) || File.Exists(Path.Combine(Path.GetDirectoryName(copy.Image), "updater.node")) ||
                !File.Exists(Path.Combine(source, "updater.node")) || !File.Exists(Path.Combine(copy.ProfilePath, "1.2.3", "modules", "discord_desktop_core", "index.js")))
                throw new InvalidOperationException("Isolated application/module copy invariant failed.");
            string sourceCore = Path.Combine(source, "modules", "discord_desktop_core-7", "discord_desktop_core");
            string preparedCore = Path.Combine(copy.ProfilePath, "1.2.3", "modules", "discord_desktop_core");
            string preparedEntry = File.ReadAllText(Path.Combine(preparedCore, "index.js"));
            if (!preparedEntry.StartsWith("// DiscordAccess attachment clicks v4.12\n", StringComparison.Ordinal) ||
                !preparedEntry.EndsWith("module.exports = require('./core.asar');\n", StringComparison.Ordinal) ||
                preparedEntry.Contains("MESSAGE") || preparedEntry.Contains("node-https") ||
                Safety.HashBytes(File.ReadAllBytes(Path.Combine(preparedCore, "core.asar"))) !=
                    Safety.HashBytes(File.ReadAllBytes(Path.Combine(sourceCore, "core.asar"))) ||
                File.ReadAllText(Path.Combine(Path.GetDirectoryName(copy.Image), "resources", "app.asar")) != "fixture archive, never loaded" ||
                !File.Exists(Path.Combine(state, "integration", "attachment-download-v42.cjs")) || File.Exists(Path.Combine(state, "message-network.log")) ||
                copy.DownloadLogPath != Path.Combine(state, "download-events.log") ||
                File.Exists(Path.Combine(state, "download-events.log")))
                throw new InvalidOperationException("Official archive preservation or attachment-only preparation invariant failed.");
            string settingsPath = Path.Combine(copy.ProfilePath, "settings.json");
            var settings = ReadObject(settingsPath); settings["fixturePreference"] = "keep-me"; WriteObject(settingsPath, settings, state);
            Prepare(Path.Combine(source, "Discord.exe"), state, "http://127.0.0.1:4568/api", "http://127.0.0.1:4568/updates", null);
            settings = ReadObject(settingsPath);
            if (!Equals(settings["fixturePreference"], "keep-me") || !Equals(settings["UPDATE_ENDPOINT"], "http://127.0.0.1:4568/api") || !Equals(settings["SKIP_HOST_UPDATE"], true))
                throw new InvalidOperationException("Isolated settings preservation invariant failed.");
            bool rejected = false;
            try { ValidateLoopbackEndpoint("http://example.com/api"); } catch (ArgumentException) { rejected = true; }
            if (!rejected) throw new InvalidOperationException("Non-loopback updater endpoint was accepted.");
            // A readable marker/installed.json must not hide a partially removed
            // cached runtime. Restore fixture files after each rejection check.
            string cachedApp = Path.Combine(Path.GetDirectoryName(copy.Image), "resources", "app.asar");
            string cachedCore = Path.Combine(copy.ProfilePath, "1.2.3", "modules", "discord_desktop_core");
            foreach (string missing in new[] { cachedApp, Path.Combine(cachedCore, "index.js"), Path.Combine(cachedCore, "core.asar") })
            {
                string original = File.ReadAllText(missing);
                RequireOwned(missing, state); RequirePlain(missing); File.Delete(missing);
                bool cacheRejected = false;
                try { Prepare(Path.Combine(source, "Discord.exe"), state, "http://127.0.0.1:4568/api", "http://127.0.0.1:4568/updates", null); }
                catch (InvalidDataException error)
                { cacheRejected = error.Message.Contains("yeniden adlandırıp") && error.Message.Contains(missing); }
                finally { File.WriteAllText(missing, original); }
                if (!cacheRejected) throw new InvalidOperationException("Missing cached payload was accepted: " + Path.GetFileName(missing));
            }
            File.WriteAllText(Path.Combine(cachedCore, "core.asar"), "newer official fixture payload");
            Prepare(Path.Combine(source, "Discord.exe"), state, "http://127.0.0.1:4568/api", "http://127.0.0.1:4568/updates", null);
        }
    }
}
