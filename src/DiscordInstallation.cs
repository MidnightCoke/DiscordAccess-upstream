using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace DiscordAccess
{
    internal sealed class DiscordShortcutTarget
    {
        internal string Path;
        internal string Arguments;
    }

    // Only the installation root is persisted. Image/version selection happens
    // again for each launch so an official update does not pin an obsolete EXE.
    internal sealed class DiscordInstallation
    {
        internal readonly string Root;
        private readonly Func<string, IDisposable> verifyImage;
        private const int MaxVersions = 64;
        private const int MaxJsonBytes = 8192;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        private static readonly Regex VersionName = new Regex(@"\Aapp-([0-9]+(?:\.[0-9]+){1,3})\z", RegexOptions.CultureInvariant);
        private static readonly Regex ProcessStart = new Regex("\\A--processStart[ \\t]+(?:Discord\\.exe|\"Discord\\.exe\")\\z", RegexOptions.CultureInvariant);

        private DiscordInstallation(string root, Func<string, IDisposable> verifier)
        { Root = root; verifyImage = verifier; }

        internal static DiscordInstallation Resolve(string explicitPath)
        {
            return ResolveWithPaths(explicitPath, ReadSavedRoot(), Safety.DefaultDiscordRoot,
                DiscordShortcuts.DiscoverTargets, VerifyOfficialImage, SaveRoot);
        }

        // Discovery is bounded and lazy. Tests inject disposable fixture paths,
        // signer checks and a save callback; they never access the user's state.
        internal static DiscordInstallation ResolveWithPaths(string explicitPath, string savedRoot, string defaultRoot,
            Func<IEnumerable<DiscordShortcutTarget>> shortcuts, Func<string, IDisposable> verifier, Action<string> saveRoot)
        {
            if (verifier == null || shortcuts == null) throw new ArgumentNullException();
            if (explicitPath != null)
            {
                DiscordInstallation chosen;
                try
                {
                    string root = RootFromExplicit(explicitPath, verifier);
                    chosen = VerifyRoot(root, verifier);
                }
                catch (Exception ex)
                {
                    if (!ExpectedDiscoveryFailure(ex)) throw;
                    throw new UserActionException("Belirtilen Discord yolu doğrulanamadı. Resmi Discord Stable kurulum klasörünü veya Discord.exe yolunu --discord-path ile belirtin.");
                }
                if (saveRoot != null) saveRoot(chosen.Root);
                return chosen;
            }
            foreach (string preferred in new[] { savedRoot, defaultRoot })
            {
                DiscordInstallation chosen = TryVerifyRoot(preferred, verifier);
                if (chosen == null) continue;
                if (saveRoot != null) saveRoot(chosen.Root);
                return chosen;
            }
            var discovered = new Dictionary<string, DiscordInstallation>(StringComparer.OrdinalIgnoreCase);
            IEnumerable<DiscordShortcutTarget> targets = shortcuts() ?? new DiscordShortcutTarget[0];
            int count = 0;
            foreach (DiscordShortcutTarget target in targets)
            {
                if (++count > 64) break;
                try
                {
                    string root = RootFromShortcut(target, verifier);
                    if (root == null || discovered.ContainsKey(root)) continue;
                    DiscordInstallation chosen = VerifyRoot(root, verifier);
                    discovered.Add(chosen.Root, chosen);
                }
                catch (Exception ex) { if (!ExpectedDiscoveryFailure(ex)) throw; }
            }
            if (discovered.Count > 1)
                throw new UserActionException("Birden fazla resmi Discord Stable kurulumu bulundu. Kullanılacak kurulumu DiscordAccess.exe --discord-path \"D:\\Programlar\\Discord\\Discord.exe\" ile belirtin.");
            if (discovered.Count == 0)
                throw new UserActionException("Resmi Discord Stable kurulumu bulunamadı. DiscordAccess.exe --discord-path \"D:\\Programlar\\Discord\\Discord.exe\" ile yol belirtebilirsiniz.");
            DiscordInstallation result = discovered.Values.First();
            if (saveRoot != null) saveRoot(result.Root);
            return result;
        }

        internal static DiscordInstallation VerifyRoot(string root)
        { return VerifyRoot(root, VerifyOfficialImage); }

        internal static DiscordInstallation VerifyRoot(string root, Func<string, IDisposable> verifier)
        {
            var result = VerifyRootPath(root, verifier);
            result.FindImage();
            return result;
        }

        // This proves the recorded installation belongs to Discord for rollback
        // only. It never selects an executable to launch or relaxes FindImage.
        internal static DiscordInstallation VerifyRecoveryRoot(string root, string recordedVersion)
        { return VerifyRecoveryRoot(root, recordedVersion, VerifyOfficialImage); }

        internal static DiscordInstallation VerifyRecoveryRoot(string root, string recordedVersion, Func<string, IDisposable> verifier)
        {
            var result = VerifyRootPath(root, verifier);
            if (recordedVersion != null)
            {
                if (!VersionName.IsMatch("app-" + recordedVersion)) throw Invalid();
                string recordedApp = Path.Combine(result.Root, "app-" + recordedVersion);
                RequireSafePath(recordedApp);
                if (Directory.Exists(recordedApp))
                {
                    // An existing recorded folder must itself remain official.
                    // A corrupt build is never excused by a different good app.
                    RejectAdditions(recordedApp);
                    result.VerifyApp(recordedApp);
                    return result;
                }
                if (File.Exists(recordedApp)) throw Invalid();
                // Official updates may remove the entire old folder. Restore
                // already preserves/removes no payload there; prove this same
                // root with another valid app before retiring the owned journal.
            }
            foreach (var candidate in result.VersionCandidates().OrderByDescending(p => p.Key))
            {
                try { result.VerifyApp(candidate.Value); return result; }
                catch (Exception ex) { if (!ExpectedDiscoveryFailure(ex)) throw; }
            }
            throw Invalid();
        }

        private static DiscordInstallation VerifyRootPath(string root, Func<string, IDisposable> verifier)
        {
            if (verifier == null) throw new ArgumentNullException("verifier");
            root = CanonicalLocalPath(root);
            if (!Directory.Exists(root) || SamePath(root, Safety.StateRoot) || Safety.Under(root, Safety.StateRoot)) throw Invalid();
            RequireSafePath(root);
            RejectAdditions(root);
            return new DiscordInstallation(root, verifier);
        }

        internal string FindImage()
        {
            RequireSafePath(Root);
            if (!Directory.Exists(Root)) throw Invalid();
            RejectAdditions(Root);
            foreach (var candidate in VersionCandidates().OrderByDescending(p => p.Key))
            {
                string image = Path.Combine(candidate.Value, "Discord.exe");
                RequireSafePath(image);
                if (!File.Exists(image)) continue;
                // Once the newest app contains an executable, reject a corrupt
                // or untrusted build. Do not silently downgrade to an older app.
                return VerifyApp(candidate.Value);
            }
            throw Invalid();
        }

        private IEnumerable<KeyValuePair<Version, string>> VersionCandidates()
        {
            var candidates = new List<KeyValuePair<Version, string>>();
            int visited = 0;
            foreach (string folder in Directory.EnumerateDirectories(Root, "app-*", SearchOption.TopDirectoryOnly))
            {
                if (++visited > MaxVersions) throw Invalid();
                Match match = VersionName.Match(Path.GetFileName(folder));
                Version version;
                if (!match.Success || !Version.TryParse(match.Groups[1].Value, out version)) continue;
                RequireSafePath(folder);
                RejectAdditions(folder);
                candidates.Add(new KeyValuePair<Version, string>(version, folder));
            }
            return candidates;
        }

        private string VerifyApp(string app)
        {
            string image = Path.Combine(app, "Discord.exe");
            string resources = Path.Combine(app, "resources");
            string asar = Path.Combine(resources, "app.asar");
            string info = Path.Combine(resources, "build_info.json");
            RequireSafePath(image); RequireSafePath(resources); RequireSafePath(asar); RequireSafePath(info);
            if (!File.Exists(image) || !File.Exists(asar) || !File.Exists(info)) throw Invalid();
            using (var lease = Safety.ReadLease(asar)) if (lease.Length == 0) throw Invalid();
            VerifyBuildInfo(ReadBytes(info), Path.GetFileName(app).Substring(4));
            using (var signedImage = verifyImage(image)) { }
            return image;
        }

        internal static string RootFromExplicit(string path, Func<string, IDisposable> verifier)
        {
            path = CanonicalLocalPath(path);
            if (Directory.Exists(path))
            {
                Match versionFolder = VersionName.Match(Path.GetFileName(path));
                return versionFolder.Success ? CanonicalLocalPath(Path.GetDirectoryName(path)) : path;
            }
            RequireSafePath(path);
            if (!File.Exists(path)) throw Invalid();
            string name = Path.GetFileName(path);
            if (!String.Equals(name, "Discord.exe", StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(name, "Update.exe", StringComparison.OrdinalIgnoreCase)) throw Invalid();
            using (var signedTarget = verifier(path)) { }
            string parent = Path.GetDirectoryName(path);
            if (String.Equals(name, "Discord.exe", StringComparison.OrdinalIgnoreCase) && VersionName.IsMatch(Path.GetFileName(parent)))
                parent = Path.GetDirectoryName(parent);
            return CanonicalLocalPath(parent);
        }

        internal static string RootFromShortcut(DiscordShortcutTarget target, Func<string, IDisposable> verifier)
        {
            if (target == null) return null;
            string path = CanonicalLocalPath(target.Path);
            string arguments = (target.Arguments ?? "").Trim();
            string parent = Path.GetDirectoryName(path);
            string name = Path.GetFileName(path);
            string root = null;
            if (String.Equals(name, "Update.exe", StringComparison.OrdinalIgnoreCase) && ProcessStart.IsMatch(arguments)) root = parent;
            else if (String.Equals(name, "Discord.exe", StringComparison.OrdinalIgnoreCase))
            {
                if (VersionName.IsMatch(Path.GetFileName(parent)))
                {
                    if (arguments.Length == 0 || arguments == "--start-minimized") root = Path.GetDirectoryName(parent);
                }
                else if (arguments.Length == 0 || ProcessStart.IsMatch(arguments)) root = parent;
            }
            if (root == null) return null;
            RequireSafePath(path);
            using (var signedTarget = verifier(path)) { }
            return CanonicalLocalPath(root);
        }

        internal static void VerifyBuildInfo(byte[] bytes, string expectedVersion)
        {
            var info = JsonObject(bytes);
            object channel, version;
            if (!info.TryGetValue("releaseChannel", out channel) || !(channel is string) || (string)channel != "stable" ||
                !info.TryGetValue("version", out version) || !(version is string) || (string)version != expectedVersion) throw Invalid();
        }

        internal static string CanonicalLocalPath(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || path.Length > 4096 || path.Length < 3 ||
                !Char.IsLetter(path[0]) || path[1] != ':' || (path[2] != '\\' && path[2] != '/') ||
                path.IndexOf(':', 2) >= 0 || path.IndexOf('"') >= 0 || Array.Exists(path.ToCharArray(), Char.IsControl)) throw Invalid();
            path = path.Replace('/', '\\');
            foreach (string component in path.Substring(3).Split('\\'))
                if (component == "." || component == ".." || component.EndsWith(".", StringComparison.Ordinal) ||
                    component.EndsWith(" ", StringComparison.Ordinal) || component.IndexOfAny(new[] { '*', '?', '<', '>', '|' }) >= 0) throw Invalid();
            string full = Path.GetFullPath(path).TrimEnd('\\');
            if (full.Length <= 2) throw Invalid();
            return full;
        }

        private static DiscordInstallation TryVerifyRoot(string root, Func<string, IDisposable> verifier)
        {
            if (root == null) return null;
            try { return VerifyRoot(root, verifier); }
            catch (Exception ex) { if (!ExpectedDiscoveryFailure(ex)) throw; return null; }
        }

        private static IDisposable VerifyOfficialImage(string image)
        { return new TrustedImage(image, true); }

        private static bool ExpectedDiscoveryFailure(Exception ex)
        {
            return ex is IOException || ex is InvalidDataException || ex is UnauthorizedAccessException || ex is ArgumentException ||
                ex is InvalidOperationException || ex is System.Security.SecurityException;
        }

        private static void RejectAdditions(string directory)
        {
            foreach (string name in new[] { "version.dll", "drover.ini" })
            {
                string path = Path.Combine(directory, name);
                RequireSafePath(path);
                if (File.Exists(path) || Directory.Exists(path)) throw Invalid();
            }
        }

        private static void RequireSafePath(string path)
        { if (!Safety.NoReparse(path)) throw Invalid(); }

        private static bool SamePath(string left, string right)
        { return String.Equals(Path.GetFullPath(left).TrimEnd('\\'), Path.GetFullPath(right).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase); }

        private static string CachePath { get { return Path.Combine(Safety.StateRoot, "v3", "install-location.json"); } }

        private static string ReadSavedRoot()
        {
            try
            {
                if (!File.Exists(CachePath)) return null;
                Safety.EnsureStateDirectory();
                return DecodeSavedRoot(ReadBytes(CachePath));
            }
            catch (Exception ex) { if (!ExpectedDiscoveryFailure(ex)) throw; return null; }
        }

        private static void SaveRoot(string root)
        {
            Safety.EnsureStateDirectory();
            root = CanonicalLocalPath(root);
            if (String.Equals(ReadSavedRoot(), root, StringComparison.OrdinalIgnoreCase)) return;
            string destination = CachePath;
            RequireSafePath(destination);
            string temporary = Path.Combine(Path.GetDirectoryName(destination), ".install-location-" + Guid.NewGuid().ToString("N") + ".tmp");
            RequireSafePath(temporary);
            byte[] bytes = EncodeSavedRoot(root);
            try
            {
                using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    if (!String.Equals(Path.GetFullPath(temporary), NativeFile.FinalPath(file.SafeFileHandle), StringComparison.OrdinalIgnoreCase)) throw Invalid();
                    file.Write(bytes, 0, bytes.Length); file.Flush(true);
                }
                RequireSafePath(temporary); RequireSafePath(destination);
                if (File.Exists(destination)) File.Replace(temporary, destination, null);
                else File.Move(temporary, destination);
            }
            finally { if (File.Exists(temporary) && Safety.NoReparse(temporary)) File.Delete(temporary); }
        }

        internal static byte[] EncodeSavedRoot(string root)
        { return Utf8.GetBytes(Serializer().Serialize(new Dictionary<string, object> { { "schema", 1 }, { "root", CanonicalLocalPath(root) } })); }

        internal static string DecodeSavedRoot(byte[] bytes)
        {
            var info = JsonObject(bytes);
            object schema, root;
            if (info.Count != 2 || !info.TryGetValue("schema", out schema) || !(schema is int) || (int)schema != 1 ||
                !info.TryGetValue("root", out root) || !(root is string)) throw Invalid();
            return CanonicalLocalPath((string)root);
        }

        private static byte[] ReadBytes(string path)
        {
            RequireSafePath(path);
            using (var file = Safety.ReadLease(path))
            {
                if (file.Length == 0 || file.Length > MaxJsonBytes) throw Invalid();
                byte[] bytes = new byte[(int)file.Length]; int offset = 0;
                while (offset < bytes.Length)
                { int count = file.Read(bytes, offset, bytes.Length - offset); if (count == 0) throw Invalid(); offset += count; }
                return bytes;
            }
        }

        private static Dictionary<string, object> JsonObject(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0 || bytes.Length > MaxJsonBytes) throw Invalid();
            string json = Utf8.GetString(bytes);
            if (json.StartsWith("\uFEFF", StringComparison.Ordinal)) json = json.Substring(1);
            var result = Serializer().DeserializeObject(json) as Dictionary<string, object>;
            if (result == null) throw Invalid();
            return result;
        }

        private static JavaScriptSerializer Serializer()
        { return new JavaScriptSerializer { MaxJsonLength = MaxJsonBytes, RecursionLimit = 8 }; }

        private static InvalidDataException Invalid()
        { return new InvalidDataException("Discord Stable kurulum yolu veya resmi dosyaları doğrulanamadı."); }
    }
}
