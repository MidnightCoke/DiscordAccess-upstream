#if TEST_BUILD
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace DiscordAccess
{
    // Disposable files stand in for signed EXEs. No current-user shortcut,
    // real Discord install, persisted preference or remote endpoint is opened.
    internal static class DiscordDiscoveryChecks
    {
        private sealed class EmptyLease : IDisposable { public void Dispose() { } }

        internal static int Run(string packageRoot)
        {
            string work = Path.Combine(Path.GetFullPath(packageRoot), "work");
            string fixture = Path.Combine(work, "dsc-" + Guid.NewGuid().ToString("N"));
            if (!Safety.Under(fixture, work) || !Safety.NoReparse(fixture)) throw new InvalidOperationException("Unsafe discovery fixture.");
            Directory.CreateDirectory(fixture);
            int checks = 0;
            Action<bool, string> assert = (condition, message) => { checks++; if (!condition) throw new InvalidOperationException(message); };
            Action<Action, string> rejects = (action, message) =>
            {
                bool refused = false;
                try { action(); }
                catch (Exception ex) { if (!(ex is InvalidOperationException) && !(ex is ArgumentException) && !(ex is InvalidDataException) && !(ex is UserActionException)) throw; refused = true; }
                assert(refused, message);
            };
            Func<string, IDisposable> signer = path =>
            {
                if (File.ReadAllText(path) != "SIGNED_DISCORD_FIXTURE") throw new InvalidOperationException("Not signed fixture.");
                return new EmptyLease();
            };
            int scans = 0, saved = 0;
            string savedRoot = null;
            Func<IEnumerable<DiscordShortcutTarget>> noScan = () => { scans++; throw new InvalidOperationException("Unexpected shortcut scan."); };
            Action<string> save = root => { saved++; savedRoot = root; };
            try
            {
                foreach (string bad in new[] { "", "  ", "Discord", "C:Discord", @"\Discord", @"\\server\Discord", @"\\?\C:\Discord",
                    @"C:\Discord:secret", @"C:\Discord\..\Other", @"C:\Discord\.", @"C:\Discord.", @"C:\Discord ", @"C:\Discord\*.exe", "C:\\Dis\u0000cord", @"C:\" })
                    rejects(() => DiscordInstallation.CanonicalLocalPath(bad), "Unsafe path admitted: " + bad);
                assert(DiscordInstallation.CanonicalLocalPath("D:/Program Files/Discord/") == @"D:\Program Files\Discord", "Local slash normalization failed.");
                assert(DiscordInstallation.CanonicalLocalPath(@"D:\Uygulamalar\Dıscord") == @"D:\Uygulamalar\Dıscord", "Unicode path changed.");

                var parsed = DiscordPathOptions.Parse(new[] { "--dns=google", "--discord-path", @"D:\Program Files\Discord\Discord.exe", "--connect" });
                assert(parsed.ExplicitPath == @"D:\Program Files\Discord\Discord.exe", "Separated path option changed.");
                assert(parsed.RemainingArgs.SequenceEqual(new[] { "--dns=google", "--connect" }), "Other arguments changed order or value.");
                parsed = DiscordPathOptions.Parse(new[] { "--discord-path=D:\\Apps\\Discord", "--dns-record-fragment" });
                assert(parsed.ExplicitPath == @"D:\Apps\Discord" && parsed.RemainingArgs.Single() == "--dns-record-fragment", "Equals path option failed.");
                assert(DnsOptions.Parse(parsed.RemainingArgs).RecordFragment, "DNS parse changed after path stripping.");
                assert(DiscordPathOptions.Parse(null).RemainingArgs.Length == 0, "Null args changed.");
                foreach (string[] bad in new[] {
                    new[] { "--discord-path" }, new[] { "--discord-path=" }, new[] { "--discord-path", "--dns=google" },
                    new[] { "--discord-path", "   " }, new[] { "--Discord-Path=X" }, new[] { "--discord-pathX" }, new[] { "--discordpath=X" },
                    new[] { "--discord-path=\"D:\\Apps\\Discord\"" }, new[] { "--discord-path=X\nY" },
                    new[] { "--discord-path=X", "--discord-path=Y" }, new[] { "--discord-path", "X", "--discord-path", "Y" } })
                    rejects(() => DiscordPathOptions.Parse(bad), "Invalid or duplicate path option admitted.");

                string first = Path.Combine(fixture, "custom install"), second = Path.Combine(fixture, "other install");
                string oldImage = CreateInstall(first, "1.0.9", "stable");
                string currentImage = CreateInstall(first, "1.0.10", "stable");
                string secondImage = CreateInstall(second, "1.0.11", "stable");
                WriteSigned(Path.Combine(first, "Discord.exe")); WriteSigned(Path.Combine(first, "Update.exe"));
                assert(DiscordInstallation.VerifyRoot(first, signer).FindImage() == currentImage, "Version selection used lexical order.");
                var selected = DiscordInstallation.ResolveWithPaths(Path.Combine(first, "Discord.exe"), second, second, noScan, signer, save);
                assert(selected.Root == first && savedRoot == first && saved == 1 && scans == 0, "Explicit verified path did not win without discovery.");
                selected = DiscordInstallation.ResolveWithPaths(null, second, first, noScan, signer, save);
                assert(selected.Root == second && scans == 0, "Valid cached path did not win lazily.");
                selected = DiscordInstallation.ResolveWithPaths(null, Path.Combine(fixture, "missing"), first, noScan, signer, save);
                assert(selected.Root == first && scans == 0, "Standard fallback scanned shortcuts.");
                int beforeSave = saved;
                rejects(() => DiscordInstallation.ResolveWithPaths(Path.Combine(fixture, "missing.exe"), first, first, noScan, signer, save), "Invalid explicit input silently fell back.");
                assert(saved == beforeSave && scans == 0, "Invalid explicit input persisted or scanned.");
                foreach (string input in new[] { first, Path.GetDirectoryName(currentImage), currentImage, Path.Combine(first, "Discord.exe"), Path.Combine(first, "Update.exe") })
                    assert(DiscordInstallation.ResolveWithPaths(input, null, null, noScan, signer, null).Root == first, "Supported explicit form failed.");

                var duplicateTargets = new[] { new DiscordShortcutTarget { Path = Path.Combine(first, "Update.exe"), Arguments = "--processStart Discord.exe" },
                    new DiscordShortcutTarget { Path = Path.Combine(first, "Discord.exe"), Arguments = "--processStart \"Discord.exe\"" },
                    new DiscordShortcutTarget { Path = currentImage, Arguments = "--start-minimized" } };
                selected = DiscordInstallation.ResolveWithPaths(null, null, null, () => duplicateTargets, signer, save);
                assert(selected.Root == first, "Duplicate root targets became ambiguous.");
                rejects(() => DiscordInstallation.ResolveWithPaths(null, null, null, () => duplicateTargets.Concat(new[] { new DiscordShortcutTarget { Path = secondImage } }), signer, null), "Two distinct roots silently selected one.");
                foreach (var target in new[] {
                    new DiscordShortcutTarget { Path = Path.Combine(first, "Update.exe"), Arguments = "" },
                    new DiscordShortcutTarget { Path = Path.Combine(first, "Update.exe"), Arguments = "--processStart Discord.exe --process-start-args=--proxy-server=evil" },
                    new DiscordShortcutTarget { Path = currentImage, Arguments = "--user-data-dir=D:\\Other" },
                    new DiscordShortcutTarget { Path = Path.Combine(first, "Discord.exe"), Arguments = "--start-minimized" } })
                    assert(DiscordInstallation.RootFromShortcut(target, signer) == null, "Unrecognized launch arguments admitted.");
                File.WriteAllText(Path.Combine(first, "Discord.exe"), "UNSIGNED_FIXTURE");
                rejects(() => DiscordInstallation.RootFromShortcut(new DiscordShortcutTarget { Path = Path.Combine(first, "Discord.exe") }, signer), "Unsigned shortcut target admitted.");
                WriteSigned(Path.Combine(first, "Discord.exe"));

                string ptb = Path.Combine(fixture, "ptb"); CreateInstall(ptb, "1.0.12", "ptb");
                rejects(() => DiscordInstallation.VerifyRoot(ptb, signer), "PTB metadata admitted.");
                string mismatch = Path.Combine(fixture, "mismatch"); string mismatchImage = CreateInstall(mismatch, "1.0.12", "stable");
                File.WriteAllText(Path.Combine(Path.GetDirectoryName(mismatchImage), "resources", "build_info.json"), "{\"releaseChannel\":\"stable\",\"version\":\"1.0.13\"}");
                rejects(() => DiscordInstallation.VerifyRoot(mismatch, signer), "Mismatched metadata version admitted.");
                string incomplete = Path.Combine(fixture, "incomplete"); string incompleteImage = CreateInstall(incomplete, "1.0.12", "stable");
                File.Delete(Path.Combine(Path.GetDirectoryName(incompleteImage), "resources", "app.asar"));
                rejects(() => DiscordInstallation.VerifyRoot(incomplete, signer), "Missing app.asar admitted.");
                string unsigned = Path.Combine(fixture, "unsigned"); File.WriteAllText(CreateInstall(unsigned, "1.0.12", "stable"), "UNSIGNED_FIXTURE");
                rejects(() => DiscordInstallation.VerifyRoot(unsigned, signer), "Unsigned app image admitted.");
                string upperImage = CreateInstall(first, "1.0.11", "stable");
                File.WriteAllText(upperImage, "UNSIGNED_FIXTURE");
                rejects(() => DiscordInstallation.VerifyRoot(first, signer), "Higher unsigned build silently downgraded.");
                assert(DiscordInstallation.VerifyRecoveryRoot(first, "1.0.10", signer).Root == first, "New unsigned build stranded exact recorded recovery.");
                assert(DiscordInstallation.VerifyRecoveryRoot(first, null, signer).Root == first, "New unsigned build stranded root-only recovery.");
                rejects(() => DiscordInstallation.VerifyRecoveryRoot(first, "1.0.11", signer), "Existing unsigned recorded app borrowed older proof.");
                WriteSigned(upperImage);
                string upperInfo = Path.Combine(Path.GetDirectoryName(upperImage), "resources", "build_info.json");
                File.WriteAllText(upperInfo, "{\"releaseChannel\":\"stable\",\"version\":\"1.0.12\"}");
                rejects(() => DiscordInstallation.VerifyRoot(first, signer), "Higher corrupt build silently downgraded.");
                assert(DiscordInstallation.VerifyRecoveryRoot(first, "1.0.10", signer).Root == first, "New corrupt metadata stranded exact recorded recovery.");
                assert(DiscordInstallation.VerifyRecoveryRoot(first, null, signer).Root == first, "New corrupt metadata stranded root-only recovery.");
                rejects(() => DiscordInstallation.VerifyRecoveryRoot(first, "1.0.11", signer), "Existing corrupt recorded metadata borrowed older proof.");
                File.WriteAllText(upperInfo, "{\"releaseChannel\":\"stable\",\"version\":\"1.0.11\"}");
                File.Delete(Path.Combine(Path.GetDirectoryName(upperImage), "resources", "app.asar"));
                rejects(() => DiscordInstallation.VerifyRoot(first, signer), "Higher incomplete build with EXE silently downgraded.");
                assert(DiscordInstallation.VerifyRecoveryRoot(first, "1.0.10", signer).Root == first, "New incomplete build stranded exact recorded recovery.");
                assert(DiscordInstallation.VerifyRecoveryRoot(first, null, signer).Root == first, "New incomplete build stranded root-only recovery.");
                rejects(() => DiscordInstallation.VerifyRecoveryRoot(first, "1.0.11", signer), "Existing incomplete recorded folder borrowed older proof.");
                Directory.Delete(Path.GetDirectoryName(upperImage), true);
                assert(DiscordInstallation.VerifyRecoveryRoot(first, "1.0.11", signer).Root == first, "Removed recorded version could not use healthy alternate root proof.");
                assert(!Directory.Exists(Path.GetDirectoryName(upperImage)), "Recovery proof recreated removed recorded folder.");
                rejects(() => DiscordInstallation.VerifyRecoveryRoot(unsigned, null, signer), "Unsigned-only recovery root admitted.");
                rejects(() => DiscordInstallation.VerifyRecoveryRoot(unsigned, "1.0.12", signer), "Unsigned recorded recovery root admitted.");
                foreach (string badVersion in new[] { "../other", "", "1", "1.0.10\\other", "1.0.10:stream", "1.0.10\n" })
                    rejects(() => DiscordInstallation.VerifyRecoveryRoot(first, badVersion, signer), "Unsafe recorded version admitted.");
                string emptyApp = Path.Combine(first, "app-1.0.99"); Directory.CreateDirectory(emptyApp);
                assert(DiscordInstallation.VerifyRoot(first, signer).FindImage() == currentImage, "Empty update staging directory blocked existing complete version.");
                Directory.Delete(emptyApp);
                foreach (string name in new[] { "version.dll", "drover.ini" })
                {
                    string addition = Path.Combine(Path.GetDirectoryName(currentImage), name); File.WriteAllText(addition, "UNOWNED_CANARY");
                    rejects(() => DiscordInstallation.VerifyRoot(first, signer), "Suspicious app addition admitted or silently chose older version.");
                    assert(File.ReadAllText(addition) == "UNOWNED_CANARY", "Suspicious addition was changed."); File.Delete(addition);
                    addition = Path.Combine(first, name); File.WriteAllText(addition, "UNOWNED_CANARY");
                    rejects(() => DiscordInstallation.VerifyRoot(first, signer), "Suspicious root addition admitted."); File.Delete(addition);
                }

                var installation = DiscordInstallation.VerifyRoot(first, signer);
                string newImage = CreateInstall(first, "1.0.15", "stable");
                assert(installation.FindImage() == newImage, "Root pinned old version after update.");
                byte[] cache = DiscordInstallation.EncodeSavedRoot(first);
                assert(DiscordInstallation.DecodeSavedRoot(cache) == first, "Persisted root round trip failed.");
                string json = Encoding.UTF8.GetString(cache);
                assert(!json.Contains("app-1") && !json.Contains("Discord.exe") && !json.Contains("profile"), "Persisted preference included a version image or profile.");
                foreach (string invalidJson in new[] { "{}", "{\"schema\":2,\"root\":\"C:\\\\Discord\"}", "{\"schema\":1,\"root\":\"relative\"}",
                    "{\"schema\":1,\"root\":\"C:\\\\Discord\",\"profile\":\"unexpected\"}" })
                    rejects(() => DiscordInstallation.DecodeSavedRoot(Encoding.UTF8.GetBytes(invalidJson)), "Invalid cached preference admitted.");
                rejects(() => DiscordInstallation.VerifyRoot(Safety.StateRoot, signer), "Isolated state root admitted.");
                rejects(() => DiscordInstallation.VerifyRoot(Path.Combine(Safety.StateRoot, "v3", "client"), signer), "Isolated client root admitted.");
                assert(File.Exists(oldImage) && File.Exists(currentImage), "Discovery modified installed fixture files.");
                return checks;
            }
            finally
            {
                if (Safety.Under(fixture, work) && Safety.NoReparse(fixture) && Directory.Exists(fixture)) Directory.Delete(fixture, true);
            }
        }

        private static string CreateInstall(string root, string version, string channel)
        {
            string app = Path.Combine(root, "app-" + version);
            string resources = Path.Combine(app, "resources");
            Directory.CreateDirectory(resources);
            string image = Path.Combine(app, "Discord.exe");
            WriteSigned(image);
            File.WriteAllText(Path.Combine(resources, "app.asar"), "INERT_ASAR_FIXTURE");
            File.WriteAllText(Path.Combine(resources, "build_info.json"), "{\"releaseChannel\":\"" + channel + "\",\"version\":\"" + version + "\"}");
            return image;
        }

        private static void WriteSigned(string image) { File.WriteAllText(image, "SIGNED_DISCORD_FIXTURE"); }
    }
}
#endif
