#if TEST_BUILD
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace DiscordAccess
{
    // Registry, approval values, journals and image verification are all
    // synthetic. Filesystem races use disposable work fixtures only; these
    // checks never instantiate the Windows backend or mutate real startup.
    internal static class StartupCoordinatorChecks
    {
        private const string Root = @"C:\StartupFixture\Discord Stable";
        private const string Helper = @"C:\StartupFixture\Türkçe paket\DiscordAccess.exe";
        private const string MovedHelper = @"D:\Taşınan paket\DiscordAccess.exe";

        private sealed class Environment : StartupCoordinator.IEnvironment
        {
            internal readonly Dictionary<string, StartupCoordinator.RunEntry> Runs = new Dictionary<string, StartupCoordinator.RunEntry>(StringComparer.OrdinalIgnoreCase);
            internal readonly Dictionary<string, byte[]> Approvals = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            internal readonly List<StartupCoordinator.RunEntry> Others = new List<StartupCoordinator.RunEntry>();
            internal readonly List<string> Events = new List<string>();
            internal byte[] Journal;
            internal int RegistryWrites, JournalWrites;
            internal string FailRunName;
            internal string ExtraHelper;
            internal bool FailEveryJournalAfterFirst, FailNextJournal, RejectRoot, RejectImage, RejectHelper;
            public IEnumerable<StartupCoordinator.RunEntry> UserRun() { return Runs.Values.Select(value => value.Copy()).ToArray(); }
            public IEnumerable<StartupCoordinator.RunEntry> OtherStartup() { return Others.Select(value => value.Copy()).ToArray(); }
            public byte[] Approval(string name) { byte[] value; return Approvals.TryGetValue(name, out value) ? value.ToArray() : null; }
            public void ReplaceRun(string name, StartupCoordinator.RunEntry expected, StartupCoordinator.RunEntry replacement)
            {
                StartupCoordinator.RunEntry value; Runs.TryGetValue(name, out value);
                if (!StartupCoordinator.SameEntry(value, expected)) throw new UserActionException("Fixture registry conflict");
                if (FailRunName == name) throw new InvalidOperationException("Synthetic interrupted registry write");
                if (Journal == null) throw new InvalidOperationException("Registry changed before durable journal");
                RegistryWrites++; Events.Add(replacement == null ? "remove:" + name : "write:" + name);
                if (replacement == null) Runs.Remove(name); else Runs[name] = replacement.Copy();
            }
            public byte[] ReadJournal() { return Journal == null ? null : Journal.ToArray(); }
            public void ReplaceJournal(byte[] expected, byte[] replacement)
            {
                if (!StartupCoordinator.SameBytes(Journal, expected)) throw new UserActionException("Fixture journal conflict");
                if (FailNextJournal || (FailEveryJournalAfterFirst && JournalWrites >= 1))
                { FailNextJournal = false; throw new InvalidOperationException("Synthetic interrupted journal write"); }
                JournalWrites++; Events.Add("journal"); Journal = replacement.ToArray();
            }
            public void VerifyRoot(string root) { if (RejectRoot || root != Root) throw new UserActionException("Synthetic unverified installation"); }
            public void VerifyDiscordImage(string image)
            {
                if (RejectImage || !(image == Root + @"\Update.exe" || image == Root + @"\Discord.exe" || image == Root + @"\app-1.0.10\Discord.exe"))
                    throw new UserActionException("Synthetic unverified image");
            }
            public void VerifyHelper(string path) { if (RejectHelper || !(path == Helper || path == MovedHelper || path == ExtraHelper)) throw new UserActionException("Synthetic helper mismatch"); }
        }
        private static StartupCoordinator.RunEntry Discord(string command = null)
        { return new StartupCoordinator.RunEntry { Name = "Discord", Command = command ?? "\"" + Root + "\\Update.exe\" --processStart Discord.exe" }; }
        private static Environment Fresh(bool discord)
        {
            var result = new Environment();
            result.Runs["Unrelated application"] = new StartupCoordinator.RunEntry { Name = "Unrelated application", Command = @"C:\Other\thing.exe --PRIVATE_TOKEN_CANARY" };
            if (discord) result.Runs["Discord"] = Discord();
            return result;
        }
        private static StartupCoordinator Open(Environment environment, string helper = Helper, string[] options = null)
        { return StartupCoordinator.CreateForChecks(environment, helper, Root, options); }
        private static byte[] Approval(byte state) { var value = new byte[12]; value[0] = state; value[8] = 42; return value; }
        private static void ChangeJournal(Environment environment, Action<Dictionary<string, object>> edit)
        {
            var serializer = new JavaScriptSerializer();
            var value = (Dictionary<string, object>)serializer.DeserializeObject(Encoding.UTF8.GetString(environment.Journal));
            edit(value); environment.Journal = Encoding.UTF8.GetBytes(serializer.Serialize(value));
        }

        internal static int Run(string packageRoot)
        {
            int checks = 0;
            Action<bool, string> assert = (condition, message) => { checks++; if (!condition) throw new InvalidOperationException(message); };
            Action<Action, string> reject = (action, message) =>
            {
                bool refused = false; try { action(); } catch (UserActionException) { refused = true; } catch (ArgumentException) { refused = true; }
                assert(refused, message);
            };

            var env = Fresh(true); var access = Open(env, Helper, new[] { "--dns=google", "--dns-record-fragment" });
            assert(!access.HasPreference && !access.Enabled && !access.ShouldLaunchDiscord, "Initial startup preference was invented.");
            StartupCoordinator.RunEntry original = env.Runs["Discord"].Copy(); byte[] approval = Approval(2); env.Approvals["Discord"] = approval.ToArray();
            access.EnsureEnabled();
            assert(access.HasPreference && access.Enabled && access.ShouldLaunchDiscord, "Enabled official startup was not coordinated.");
            assert(!env.Runs.ContainsKey("Discord") && env.Runs.ContainsKey(StartupCoordinator.RunName), "Original startup and helper startup were left active together.");
            assert(env.Events.First() == "journal" && env.Events.IndexOf("write:DiscordAccess") < env.Events.IndexOf("remove:Discord"), "Startup registration order lacks durable evidence.");
            assert(env.Runs[StartupCoordinator.RunName].Command.Contains("--startup --discord-path") && env.Runs[StartupCoordinator.RunName].Command.Contains("--dns=google --dns-record-fragment"), "Startup omitted installation/DNS choices.");
            assert(!Encoding.UTF8.GetString(env.Journal).Contains("PRIVATE_TOKEN_CANARY"), "Journal captured unrelated startup arguments.");
            assert(StartupCoordinator.SameBytes(env.Approvals["Discord"], approval), "Original StartupApproved bytes changed.");
            int writes = env.RegistryWrites; access.EnsureEnabled(); access.SetEnabled(true);
            assert(env.RegistryWrites == writes && access.StartupIntent(), "Repeated enable caused redundant startup writes or lost launch intent.");
            access.SetEnabled(false);
            assert(!access.Enabled && access.HasPreference && StartupCoordinator.SameEntry(env.Runs["Discord"], original) && !env.Runs.ContainsKey(StartupCoordinator.RunName), "Disable did not restore original registration.");
            access = Open(env); writes = env.RegistryWrites; access.EnsureEnabled();
            assert(!access.Enabled && !access.StartupIntent() && env.RegistryWrites == writes, "A later tray run ignored persistent opt-out.");
            access.SetEnabled(true);
            assert(access.Enabled && access.ShouldLaunchDiscord, "Explicit re-enable failed after opt-out.");
            access.SetEnabled(false); access.SetEnabled(false);
            assert(StartupCoordinator.SameEntry(env.Runs["Discord"], original), "Idempotent disable changed the restored original command.");

            env = Fresh(false); access = Open(env); access.SetEnabled(false); access = Open(env); access.EnsureEnabled();
            assert(access.HasPreference && !access.Enabled && env.RegistryWrites == 0, "First-use disable was not persistent.");
            access.SetEnabled(true);
            assert(access.Enabled && !access.ShouldLaunchDiscord && !access.StartupIntent(), "Helper-only startup launched a Discord without original autostart.");
            assert(env.Runs.Count == 2, "Helper-only startup added unexpected registrations.");
            env = Fresh(false); access = StartupCoordinator.CreateForChecks(env, null, null, null); access.SetEnabled(false);
            access = Open(env); access.EnsureEnabled();
            assert(access.HasPreference && !access.Enabled && env.RegistryWrites == 0, "Restore without an existing startup record failed to persist opt-out.");
            access.SetEnabled(true); assert(access.Enabled, "Global opt-out could not be explicitly enabled for a verified installation.");

            foreach (byte state in new byte[] { 3, 7 })
            {
                env = Fresh(true); env.Approvals["Discord"] = Approval(state); access = Open(env); access.EnsureEnabled();
                assert(access.Enabled && !access.ShouldLaunchDiscord && !access.StartupIntent(), "Disabled original startup was launched.");
                access.SetEnabled(false);
                assert(env.Approvals["Discord"][0] == state && env.Runs.ContainsKey("Discord"), "Disabled approval was overwritten during restore.");
            }
            foreach (byte state in new byte[] { 2, 6 })
                assert(StartupCoordinator.ApprovalEnabled(Approval(state)), "Recognized enabled approval rejected.");
            foreach (byte[] value in new[] { new byte[0], new byte[11], new byte[13], Approval(9) })
                reject(() => StartupCoordinator.ApprovalEnabled(value), "Unrecognized approval guessed enabled.");

            env = Fresh(true); access = Open(env); access.EnsureEnabled(); env.Approvals["Discord"] = Approval(3);
            assert(!access.ShouldLaunchDiscord && !access.StartupIntent(), "A later original startup disable was ignored.");
            access.SetEnabled(false); assert(env.Approvals["Discord"][0] == 3, "A later user startup approval was lost.");
            env = Fresh(true); access = Open(env); access.EnsureEnabled(); env.Approvals[StartupCoordinator.RunName] = Approval(3);
            assert(!access.Enabled && !access.StartupIntent(), "Windows disable of helper was overridden.");
            writes = env.RegistryWrites; access.EnsureEnabled(); assert(env.RegistryWrites == writes, "Disabled helper silently resurrected.");

            env = Fresh(true); env.FailRunName = "Discord"; access = Open(env);
            reject(access.EnsureEnabled, "Interrupted original removal was reported successful.");
            assert(!env.Runs.ContainsKey(StartupCoordinator.RunName) && env.Runs.ContainsKey("Discord"), "Failed removal leaked a helper startup registration.");
            env.FailRunName = null; access = Open(env); access.SetEnabled(true); assert(access.Enabled, "Failed preparation could not be explicitly retried.");

            env = Fresh(true); env.FailEveryJournalAfterFirst = true; access = Open(env);
            reject(access.EnsureEnabled, "Interrupted activation journal was reported successful.");
            assert(env.Journal != null, "Interrupted activation lost original startup evidence.");
            env.FailEveryJournalAfterFirst = false; access = Open(env); access.EnsureEnabled();
            assert(access.Enabled && access.StartupIntent() && !env.Runs.ContainsKey("Discord"), "Prepared journal did not finish safely after interruption.");
            access.SetEnabled(false); assert(env.Runs.ContainsKey("Discord"), "Recovered startup could not restore original.");

            env = Fresh(true); access = Open(env); access.EnsureEnabled();
            env.Runs["Discord"] = Discord("\"" + Root + "\\Discord.exe\" --start-minimized");
            string changed = env.Runs["Discord"].Command;
            reject(() => access.StartupIntent(), "Concurrent official startup entry was allowed to duplicate launches.");
            reject(() => access.SetEnabled(false), "Changed original startup entry was silently replaced.");
            assert(env.Runs["Discord"].Command == changed && !env.Runs.ContainsKey(StartupCoordinator.RunName), "Conflict handling lost user changes or retained helper startup.");
            env.Runs["Discord"] = original.Copy(); access = Open(env); access.EnsureEnabled();
            assert(!access.Enabled, "Restoring journal did not finish after conflict resolved.");

            env = Fresh(true); access = Open(env); access.EnsureEnabled();
            env.Runs[StartupCoordinator.RunName] = new StartupCoordinator.RunEntry { Name = StartupCoordinator.RunName, Command = @"C:\Different\user-tool.exe" };
            reject(() => access.SetEnabled(false), "Changed helper registration was silently removed.");
            assert(env.Runs[StartupCoordinator.RunName].Command == @"C:\Different\user-tool.exe" && env.Runs.ContainsKey("Discord"), "Changed helper registration or original startup was lost.");

            env = Fresh(true); access = Open(env); access.EnsureEnabled(); access = Open(env, MovedHelper);
            reject(() => access.StartupIntent(), "Moved package silently hijacked old startup registration.");
            access.SetEnabled(true);
            assert(access.Enabled && env.Runs[StartupCoordinator.RunName].Command.Contains(MovedHelper), "Explicit package move did not safely replace its own registration.");
            assert(!env.Runs.ContainsKey("Discord"), "Package move left duplicate official startup.");

            foreach (string command in new[] { "\"" + Root + "\\Update.exe\" --processStart Discord.exe --proxy-server=evil",
                "\"" + Root + "\\Unknown.exe\"", "\"" + Root + "\\Discord.exe\" --user-data-dir=Other", "cmd.exe /c \"" + Root + "\\Discord.exe\"",
                "\"" + Root + "\\app-1.0.10\\Discord.exe\" --unsupported" })
            {
                env = Fresh(false); env.Runs["Discord"] = Discord(command); access = Open(env);
                reject(access.EnsureEnabled, "Unsupported selected installation startup command was accepted.");
                assert(env.RegistryWrites == 0 && env.Journal == null, "Unsupported startup mutated registrations.");
            }
            foreach (string command in new[] { "\"" + Root + "\\Discord.exe\"", "\"" + Root + "\\app-1.0.10\\Discord.exe\" --start-minimized",
                "\"" + Root + "\\Update.exe\" --processStart \"Discord.exe\" --process-start-args \"--start-minimized\"" })
            {
                env = Fresh(false); env.Runs["Discord"] = Discord(command); access = Open(env); access.EnsureEnabled();
                assert(access.ShouldLaunchDiscord, "Supported official startup layout was refused.");
                access.SetEnabled(false); assert(env.Runs["Discord"].Command == command, "Supported command was not restored byte-for-byte.");
            }
            env = Fresh(true); env.Others.Add(Discord()); access = Open(env);
            reject(access.EnsureEnabled, "Enabled machine/startup-folder Discord launch was ignored.");
            assert(env.RegistryWrites == 0 && env.Journal == null, "Unsupported startup source mutated current-user startup.");
            env.Others[0].Enabled = false; access.EnsureEnabled(); assert(access.Enabled, "Disabled unsupported startup prevented valid current-user coordination.");
            env = Fresh(true); env.Runs["Discord second"] = new StartupCoordinator.RunEntry { Name = "Discord second", Command = original.Command }; access = Open(env);
            reject(access.EnsureEnabled, "Multiple official current-user launch entries were accepted.");
            assert(env.RegistryWrites == 0, "Ambiguous startup changed registry.");
            env = Fresh(true); env.Runs[StartupCoordinator.RunName] = new StartupCoordinator.RunEntry { Name = StartupCoordinator.RunName, Command = @"C:\Foreign\DiscordAccess.exe" }; access = Open(env);
            reject(access.EnsureEnabled, "Foreign helper startup was overwritten.");
            assert(env.RegistryWrites == 0 && env.Runs.ContainsKey("Discord"), "Foreign helper conflict changed original startup.");

            // Discord can recreate Run after the user enables autostart in its
            // own settings; the tray refresh captures the new official intent.
            env = Fresh(false); access = Open(env); access.EnsureEnabled(); env.Runs["Discord"] = Discord();
            reject(() => access.StartupIntent(), "New official Run entry at sign-in was allowed to race the helper.");
            access.Refresh();
            assert(access.ShouldLaunchDiscord && !env.Runs.ContainsKey("Discord") && access.StartupIntent(), "New official autostart was not re-captured before the next sign-in.");
            access.SetEnabled(false); assert(env.Runs["Discord"].Command == original.Command, "Re-captured official Run was not restored.");
            env = Fresh(true); access = Open(env); access.EnsureEnabled(); env.Runs["Discord"] = Discord("\"" + Root + "\\Discord.exe\" --start-minimized");
            string recreated = env.Runs["Discord"].Command; access.EnsureEnabled();
            assert(!env.Runs.ContainsKey("Discord") && access.ShouldLaunchDiscord, "Re-created original startup was not coordinated.");
            access.SetEnabled(false); assert(env.Runs["Discord"].Command == recreated, "Latest official startup command was discarded during restore.");
            env = Fresh(false); access = Open(env); access.EnsureEnabled(); env.Runs["Discord"] = Discord(); env.Approvals["Discord"] = Approval(3); access.Refresh();
            assert(!access.ShouldLaunchDiscord && !env.Runs.ContainsKey("Discord"), "Disabled re-created startup intent was enabled.");
            env = Fresh(true); access = Open(env); access.EnsureEnabled(); env.Runs["Discord"] = Discord("cmd.exe /c \"" + Root + "\\Discord.exe\"");
            writes = env.RegistryWrites; reject(access.Refresh, "Unrecognized re-created command was overwritten.");
            assert(env.RegistryWrites == writes && env.Runs["Discord"].Command.StartsWith("cmd.exe", StringComparison.Ordinal), "Refresh changed an unrecognized command.");
            env = Fresh(false); access = Open(env); access.EnsureEnabled(); env.Runs["Discord"] = Discord(); env.Runs["Discord other"] = new StartupCoordinator.RunEntry { Name="Discord other",Command=original.Command };
            writes = env.RegistryWrites; reject(access.Refresh, "Refresh accepted multiple selected official startup entries.");
            assert(env.RegistryWrites == writes, "Ambiguous refresh changed startup.");

            env = Fresh(true); string longHelper = @"C:\StartupFixture\" + new string('a', 165) + @"\DiscordAccess.exe"; env.ExtraHelper = longHelper;
            access = Open(env, longHelper, new[] { "--dns=google", "--dns-record-fragment" });
            reject(access.EnsureEnabled, "Windows Run command exceeding 260 characters was registered.");
            assert(env.RegistryWrites == 0 && env.Journal == null, "Overlong Run command changed startup before refusing.");

            foreach (int failure in new[] { 0, 1, 2 })
            {
                env = Fresh(true); env.RejectRoot = failure == 0; env.RejectImage = failure == 1; env.RejectHelper = failure == 2; access = Open(env);
                reject(access.EnsureEnabled, "Unverified image/root/helper was accepted.");
                assert(env.RegistryWrites == 0 && env.Journal == null, "Failed trust verification mutated startup.");
            }
            foreach (string[] bad in new[] { new[] { "--restore" }, new[] { "--dns=evil" }, new[] { "--dns=google", "--dns=cloudflare" }, new[] { "--dns-record-fragment", "--dns-record-fragment" } })
                reject(() => Open(Fresh(true), Helper, bad), "Unsafe startup options accepted.");

            env = Fresh(true); access = Open(env); access.EnsureEnabled(); byte[] good = env.Journal.ToArray();
            foreach (Action<Dictionary<string, object>> edit in new Action<Dictionary<string, object>>[] {
                value => value["Schema"] = 2, value => value["Phase"] = "unexpected", value => value["Root"] = @"\\server\Discord",
                value => value["HelperCommand"] = "cmd.exe /c injected", value => value["OriginalCommand"] = "cmd.exe /c injected",
                value => value["OriginalEnabled"] = false, value => value["OriginalName"] = StartupCoordinator.RunName,
                value => value["UnrelatedKey"] = "PRIVATE_TOKEN_CANARY", value => value["Options"] = new[] { "--restore" } })
            {
                env.Journal = good.ToArray(); ChangeJournal(env, edit); writes = env.RegistryWrites;
                reject(() => Open(env), "Malformed startup journal accepted.");
                assert(env.RegistryWrites == writes, "Malformed journal touched startup.");
            }
            env.Journal = good.ToArray(); access = Open(env); env.Journal = Encoding.UTF8.GetBytes("{}");
            reject(() => access.SetEnabled(false), "Journal external edit was overwritten.");
            assert(env.Runs.ContainsKey(StartupCoordinator.RunName), "Registry mutated despite journal compare failure.");
            assert(env.Runs["Unrelated application"].Command.Contains("PRIVATE_TOKEN_CANARY"), "Unrelated startup entry changed.");
            return checks + FileTransaction.RunOfflineChecks(packageRoot) + FileJournalChecks(packageRoot);
        }

        private static int FileJournalChecks(string packageRoot)
        {
            string work = Path.Combine(Path.GetFullPath(packageRoot), "work");
            string root = Path.Combine(work, "startup-journal-" + Guid.NewGuid().ToString("N"));
            if (!Safety.Under(root, work) || !Safety.NoReparse(root)) throw new InvalidOperationException("Startup journal fixture escaped work.");
            Directory.CreateDirectory(root);
            int checks = 0, prepared = 0; bool rejectPrepare = false;
            Action<bool, string> assert = (ok, detail) => { if (!ok) throw new InvalidOperationException(detail); checks++; };
            Action<Action, string> reject = (action, detail) => {
                bool rejected = false; try { action(); } catch (UserActionException) { rejected = true; }
                assert(rejected, detail);
            };
            string journal = Path.Combine(root, "journal.json");
            byte[] first = Encoding.UTF8.GetBytes("{\"step\":1}"), next = Encoding.UTF8.GetBytes("{\"step\":2}"),
                third = Encoding.UTF8.GetBytes("{\"step\":3}"), foreign = Encoding.UTF8.GetBytes("{\"FOREIGN_STARTUP_JOURNAL_CANARY\":true}");
            var storage = new StartupCoordinator.FileJournal(journal, () => {
                prepared++;
                if (rejectPrepare || !Safety.Under(root, work) || !Safety.NoReparse(root)) throw new UserActionException("Fixture preparation rejected.");
            }, path => { if (!Safety.Under(path, root) || !Safety.NoReparse(path)) throw new UserActionException("Fixture path rejected."); });
            var prior = FileTransaction.InterleaveForChecks;
            try
            {
                storage.Replace(null, first);
                assert(StartupCoordinator.SameBytes(File.ReadAllBytes(journal), first) && prepared == 1, "Startup FileJournal did not prepare then create.");
                storage.Replace(first, next);
                assert(StartupCoordinator.SameBytes(File.ReadAllBytes(journal), next) && prepared == 2, "Startup FileJournal did not use expected replacement.");
                FileTransaction.InterleaveForChecks = (phase, path) => {
                    if (phase != "replace" || path != journal) return;
                    string incoming = Path.Combine(root, "incoming-" + Guid.NewGuid().ToString("N"));
                    File.WriteAllBytes(incoming, foreign); File.Replace(incoming, journal, null);
                };
                reject(() => storage.Replace(next, third), "Startup FileJournal accepted an atomic replacement race.");
                FileTransaction.InterleaveForChecks = prior;
                assert(StartupCoordinator.SameBytes(File.ReadAllBytes(journal), foreign) && Directory.GetFiles(root, "*.preserved")
                    .Any(path => StartupCoordinator.SameBytes(File.ReadAllBytes(path), foreign)), "Startup FileJournal lost concurrent journal evidence.");
                assert(prepared == 3, "Startup FileJournal bypassed its preparation callback during a conflict.");
                storage.Replace(foreign, third);
                assert(StartupCoordinator.SameBytes(File.ReadAllBytes(journal), third) && Directory.GetFiles(root, "*.preserved")
                    .Any(path => StartupCoordinator.SameBytes(File.ReadAllBytes(path), foreign)), "Later startup journal write removed prior foreign evidence.");
                rejectPrepare = true;
                reject(() => storage.Replace(third, first), "Startup FileJournal ignored failed path/permission preparation.");
                assert(StartupCoordinator.SameBytes(File.ReadAllBytes(journal), third), "Failed startup preparation mutated its journal.");
            }
            finally
            {
                FileTransaction.InterleaveForChecks = prior;
                if (Safety.Under(root, work) && Safety.NoReparse(root)) Directory.Delete(root, true);
            }
            return checks;
        }
    }
}
#endif
