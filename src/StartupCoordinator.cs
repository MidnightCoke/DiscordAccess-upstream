using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace DiscordAccess
{
    // This coordinates only the selected official Stable installation in the
    // current user's Run key. Startup registration outlives a connection session;
    // it never launches a process or changes a shortcut/network setting.
    internal sealed class StartupCoordinator
    {
        internal const string RunName = "DiscordAccess";
        private const int JournalLimit = 32768;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        private static readonly Regex AppFolder = new Regex(@"\Aapp-[0-9]+(?:\.[0-9]+){1,3}\z", RegexOptions.CultureInvariant);
        private static readonly Regex UpdaterArguments = new Regex("\\A--processStart[ \\t]+(?:Discord\\.exe|\"Discord\\.exe\")(?:[ \\t]+--process-start-args[ \\t]+(?:\"--start-minimized\"|--start-minimized))?\\z", RegexOptions.CultureInvariant);

        internal sealed class RunEntry
        {
            internal string Name, Command;
            internal RegistryValueKind Kind = RegistryValueKind.String;
            internal bool Enabled = true;
            internal RunEntry Copy() { return new RunEntry { Name = Name, Command = Command, Kind = Kind, Enabled = Enabled }; }
        }

        internal interface IEnvironment
        {
            IEnumerable<RunEntry> UserRun();
            IEnumerable<RunEntry> OtherStartup();
            byte[] Approval(string name);
            void ReplaceRun(string name, RunEntry expected, RunEntry replacement);
            byte[] ReadJournal();
            void ReplaceJournal(byte[] expected, byte[] replacement);
            void VerifyRoot(string root);
            void VerifyDiscordImage(string image);
            void VerifyHelper(string helper);
        }

        private sealed class Record
        {
            public Record() { }
            public int Schema { get; set; }
            public string Phase { get; set; }
            public string Root { get; set; }
            public string Helper { get; set; }
            public string[] Options { get; set; }
            public string HelperCommand { get; set; }
            public string OriginalName { get; set; }
            public string OriginalCommand { get; set; }
            public int OriginalKind { get; set; }
            public string OriginalApproval { get; set; }
            public bool OriginalEnabled { get; set; }
        }

        private readonly IEnvironment environment;
        private readonly string helper, root;
        private readonly string[] options;
        private readonly Action<string> log;
        private Record record;
        private byte[] saved;
        internal bool HasPreference { get { return record != null; } }
        internal bool Enabled
        {
            get
            {
                if (record == null || record.Phase != "enabled") return false;
                return SameEntry(Find(RunName), HelperEntry(record)) && ApprovalEnabled(environment.Approval(RunName));
            }
        }
        internal bool ShouldLaunchDiscord
        {
            get
            {
                return Enabled && record.OriginalName != null && record.OriginalEnabled &&
                    ApprovalEnabled(environment.Approval(record.OriginalName));
            }
        }
        internal string Status
        {
            get
            {
                if (record == null) return "Windows startup is not set up yet.";
                if (record.Phase == "restoring") return "The startup restore record is kept; try restoring again.";
                if (record.Phase == "prepared") return "Startup preparation was not completed; the recovery record is kept.";
                return Enabled ? (ShouldLaunchDiscord
                    ? "At Windows sign-in, the connection is prepared first, then the official Discord opens."
                    : "At Windows sign-in, the connection is prepared; Discord does not open on its own.")
                    : "Windows startup is off. The user startup preference is kept.";
            }
        }

        private StartupCoordinator(IEnvironment environment, string helper, string root, string[] options, Action<string> log)
        {
            if (environment == null) throw new ArgumentNullException("environment");
            this.environment = environment; this.helper = helper == null ? null : Canonical(helper);
            this.root = root == null ? null : Canonical(root); this.options = ValidateOptions(options); this.log = log;
            Load();
        }

        internal static StartupCoordinator Create(string helperImage, DiscordInstallation installation, string[] helperOptions, Action<string> log)
        {
            if (installation == null) throw new ArgumentNullException("installation");
            return new StartupCoordinator(new WindowsEnvironment(), helperImage, installation.Root, helperOptions, log);
        }
        internal static StartupCoordinator CreateForChecks(IEnvironment environment, string helper, string root, string[] options)
        { return new StartupCoordinator(environment, helper, root, options, null); }

        // The host calls this once only when HasPreference is false. A disabled
        // preference is retained, including after --restore, across later runs.
        internal void EnsureEnabled()
        {
            if (record != null)
            {
                if (record.Phase == "restoring") Disable();
                else if (record.Phase == "prepared") CompleteEnable();
                else if (record.Phase == "enabled") Refresh();
                return;
            }
            EnableNew();
        }
        internal void SetEnabled(bool enabled)
        {
            if (!enabled) { Disable(); return; }
            if (record != null && record.Phase == "prepared") { CompleteEnable(); return; }
            if (record != null && record.Phase == "enabled" && Enabled && SamePath(record.Helper, helper) && SamePath(record.Root, root)) return;
            if (record != null && record.Phase != "disabled") Disable();
            EnableNew();
        }
        internal bool StartupIntent()
        {
            if (record == null || record.Phase == "disabled") return false;
            if (!SamePath(record.Helper, helper) || !SamePath(record.Root, root))
                throw new UserActionException("The startup entry belongs to a different package or Discord installation. Turn startup off and on again from the new package.");
            if (record.Phase == "restoring") { Disable(); return false; }
            if (record.Phase == "prepared") CompleteEnable();
            // Never resurrect a helper disabled/deleted by the user in Windows.
            if (!Enabled) return false;
            RequireUnsupportedAbsent(record.Root);
            if (SelectedEntries(record.Root).Length != 0)
                throw new UserActionException("The Discord startup entry was re-enabled independently of the connection. Fully close Discord and open DiscordAccess manually; the startup order is prepared again. No second Discord was opened in this session.");
            return ShouldLaunchDiscord;
        }
        // A tray timer calls this before the next sign-in to capture Discord's
        // own re-created startup setting. It never launches or kills a client.
        internal void Refresh()
        {
            if (record == null || record.Phase != "enabled" || !Enabled) return;
            if (!SamePath(record.Helper, helper) || !SamePath(record.Root, root)) return;
            RequireUnsupportedAbsent(root);
            RunEntry[] current = SelectedEntries(root);
            if (current.Length == 0) return;
            if (current.Length != 1) throw Conflict();
            RunEntry original = current[0]; string image;
            if (!Recognized(original, root, out image)) throw Unsupported();
            environment.VerifyRoot(root); environment.VerifyDiscordImage(image);
            byte[] approval = environment.Approval(original.Name);
            record.OriginalName = original.Name; record.OriginalCommand = original.Command;
            record.OriginalKind = (int)original.Kind; record.OriginalApproval = approval == null ? null : Convert.ToBase64String(approval);
            record.OriginalEnabled = ApprovalEnabled(approval); record.Phase = "prepared";
            Save(); CompleteEnable();
        }
        internal static void Restore(Action<string> log)
        {
            var coordinator = new StartupCoordinator(new WindowsEnvironment(), null, null, null, log);
            coordinator.Disable();
        }

        private void EnableNew()
        {
            if (helper == null || root == null) throw Conflict();
            environment.VerifyHelper(helper); environment.VerifyRoot(root);
            RequireUnsupportedAbsent(root);
            var entries = Snapshot();
            if (entries.Any(entry => String.Equals(entry.Name, RunName, StringComparison.OrdinalIgnoreCase))) throw Conflict();
            // An independently disabled legacy helper entry is not silently
            // enabled by writing its Run value again.
            if (!ApprovalEnabled(environment.Approval(RunName)))
                throw new UserActionException("DiscordAccess is disabled in the Windows startup settings. To enable it, turn on the Windows startup preference; this preference was not changed.");
            var originals = SelectedEntries(root);
            if (originals.Length > 1)
                throw new UserActionException("The selected Discord has more than one startup entry. Leave a single official Discord entry in the Windows startup settings; the existing entries were not changed.");
            var original = originals.SingleOrDefault();
            if (original != null) { string image; Recognized(original, root, out image); environment.VerifyDiscordImage(image); }
            byte[] approval = original == null ? null : environment.Approval(original.Name);
            bool launch = original != null && ApprovalEnabled(approval);
            record = new Record { Schema = 1, Phase = "prepared", Root = root, Helper = helper, Options = options,
                HelperCommand = Command(helper, root, options), OriginalName = original == null ? null : original.Name,
                OriginalCommand = original == null ? null : original.Command, OriginalKind = original == null ? 0 : (int)original.Kind,
                OriginalApproval = approval == null ? null : Convert.ToBase64String(approval), OriginalEnabled = launch };
            Save(); // Durable evidence precedes the first registry mutation.
            CompleteEnable();
        }

        private void CompleteEnable()
        {
            if (record == null || record.Phase != "prepared") throw Conflict();
            if (!SamePath(record.Helper, helper) || !SamePath(record.Root, root)) throw Conflict();
            environment.VerifyHelper(helper); environment.VerifyRoot(root); RequireUnsupportedAbsent(root);
            RunEntry existing = Find(RunName), wanted = HelperEntry(record);
            if (existing != null && !SameEntry(existing, wanted)) throw Conflict();
            RunEntry original = OriginalEntry(record), current = original == null ? null : Find(original.Name);
            if (current != null && !SameEntry(current, original)) throw Conflict();
            if (current != null)
            {
                string originalImage;
                if (!Recognized(current, root, out originalImage)) throw Conflict();
                environment.VerifyDiscordImage(originalImage);
            }
            // Register the helper first; a crash cannot permanently remove the
            // user's only startup entry. Prepared journals finish on next run.
            try
            {
                if (existing == null) environment.ReplaceRun(RunName, null, wanted);
                if (current != null) environment.ReplaceRun(original.Name, current, null);
                record.Phase = "enabled"; Save();
            }
            catch
            {
                // A normal failed registry/file write is rolled back. A crash
                // still has the previously durable prepared/restoring record.
                try { Disable(); } catch { }
                throw new UserActionException("The Windows startup order could not be completed. A restore was attempted; if an entry could not be resolved, its recovery information was kept.");
            }
            if (log != null) log("The Windows startup order was prepared; only the selected official Discord entry is coordinated.");
        }

        private void Disable()
        {
            if (record == null)
            {
                // Persist opt-out even when no autorun was previously installed.
                if (helper == null || root == null)
                    record = new Record { Schema = 1, Phase = "disabled", Options = new string[0] };
                else
                {
                    environment.VerifyHelper(helper); environment.VerifyRoot(root);
                    record = new Record { Schema = 1, Phase = "disabled", Root = root, Helper = helper,
                        Options = options, HelperCommand = Command(helper, root, options) };
                }
                Save(); return;
            }
            if (record.Phase == "disabled") return;
            record.Phase = "restoring"; Save();
            bool conflict = false;
            RunEntry original = OriginalEntry(record);
            try
            {
                if (original != null)
                {
                    environment.VerifyRoot(record.Root);
                    RunEntry current = Find(original.Name);
                    if (current == null)
                    {
                        string image;
                        if (!Recognized(original, record.Root, out image)) throw Conflict();
                        environment.VerifyDiscordImage(image);
                        environment.ReplaceRun(original.Name, null, original);
                    }
                    else if (!SameEntry(current, original)) conflict = true;
                }
            }
            catch { conflict = true; }
            try
            {
                RunEntry owned = HelperEntry(record), actual = Find(RunName);
                if (SameEntry(actual, owned)) environment.ReplaceRun(RunName, actual, null);
                else if (actual != null) conflict = true;
            }
            catch { conflict = true; }
            if (conflict) throw Conflict();
            // StartupApproved was never written. Any independently changed
            // enable/disable preference therefore remains exactly as it is.
            record.Phase = "disabled"; Save();
            if (log != null) log("DiscordAccess Windows startup was turned off; the original startup entry of the official Discord was restored.");
        }

        private void RequireUnsupportedAbsent(string selectedRoot)
        {
            int count = 0;
            foreach (RunEntry entry in environment.OtherStartup() ?? new RunEntry[0])
            {
                if (++count > 512) throw Unsupported();
                if (entry == null || !entry.Enabled) continue;
                string image;
                if (Recognized(entry, selectedRoot, out image) || MentionsRoot(entry.Command, selectedRoot)) throw Unsupported();
            }
        }
        private RunEntry[] Snapshot()
        {
            var entries = (environment.UserRun() ?? new RunEntry[0]).Take(129).ToArray();
            if (entries.Length > 128 || entries.Any(entry => entry == null || !ValidName(entry.Name)) ||
                entries.Select(entry => entry.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != entries.Length) throw Conflict();
            return entries;
        }
        private RunEntry Find(string name) { return Snapshot().SingleOrDefault(entry => String.Equals(entry.Name, name, StringComparison.OrdinalIgnoreCase)); }
        private RunEntry[] SelectedEntries(string selectedRoot)
        {
            var result = new List<RunEntry>();
            foreach (var entry in Snapshot())
            {
                if (String.Equals(entry.Name, RunName, StringComparison.OrdinalIgnoreCase)) continue;
                string image;
                if (Recognized(entry, selectedRoot, out image)) result.Add(entry);
                else if (MentionsRoot(entry.Command, selectedRoot)) throw Unsupported();
            }
            return result.ToArray();
        }
        private void Load()
        {
            saved = environment.ReadJournal();
            if (saved == null) return;
            try
            {
                if (saved.Length < 2 || saved.Length > JournalLimit) throw Conflict();
                string json = Utf8.GetString(saved);
                var parsed = Serializer().DeserializeObject(json) as Dictionary<string, object>;
                string[] keys = { "Schema", "Phase", "Root", "Helper", "Options", "HelperCommand", "OriginalName", "OriginalCommand", "OriginalKind", "OriginalApproval", "OriginalEnabled" };
                if (parsed == null || parsed.Count != keys.Length || keys.Any(key => !parsed.ContainsKey(key))) throw Conflict();
                record = Serializer().Deserialize<Record>(json);
                if (record == null || record.Schema != 1 || !(new[] { "prepared", "enabled", "restoring", "disabled" }).Contains(record.Phase)) throw Conflict();
                if (record.Phase == "disabled" && record.Root == null && record.Helper == null && record.HelperCommand == null)
                {
                    if (record.OriginalName != null || record.OriginalCommand != null || record.OriginalKind != 0 || record.OriginalApproval != null ||
                        record.OriginalEnabled || record.Options == null || record.Options.Length != 0) throw Conflict();
                    return;
                }
                record.Root = Canonical(record.Root); record.Helper = Canonical(record.Helper); record.Options = ValidateOptions(record.Options);
                if (!String.Equals(Path.GetFileName(record.Helper), "DiscordAccess.exe", StringComparison.OrdinalIgnoreCase) ||
                    record.HelperCommand != Command(record.Helper, record.Root, record.Options)) throw Conflict();
                RunEntry original = OriginalEntry(record);
                if (original == null)
                {
                    if (record.OriginalCommand != null || record.OriginalKind != 0 || record.OriginalApproval != null || record.OriginalEnabled) throw Conflict();
                }
                else
                {
                    string image;
                    if (!ValidName(original.Name) || String.Equals(original.Name, RunName, StringComparison.OrdinalIgnoreCase) ||
                        !Recognized(original, record.Root, out image)) throw Conflict();
                    byte[] approval = record.OriginalApproval == null ? null : Convert.FromBase64String(record.OriginalApproval);
                    if (record.OriginalEnabled != ApprovalEnabled(approval)) throw Conflict();
                }
            }
            catch (UserActionException) { throw; }
            catch { throw Conflict(); }
        }
        private void Save()
        {
            byte[] replacement = Utf8.GetBytes(Serializer().Serialize(record));
            if (replacement.Length > JournalLimit) throw Conflict();
            environment.ReplaceJournal(saved, replacement); saved = replacement;
        }
        private static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = JournalLimit, RecursionLimit = 8 }; }
        private static RunEntry HelperEntry(Record value) { return new RunEntry { Name = RunName, Command = value.HelperCommand }; }
        private static RunEntry OriginalEntry(Record value)
        { return value.OriginalName == null ? null : new RunEntry { Name = value.OriginalName, Command = value.OriginalCommand, Kind = (RegistryValueKind)value.OriginalKind }; }
        internal static bool SameEntry(RunEntry first, RunEntry second)
        {
            return first == null || second == null ? first == second : first.Kind == second.Kind &&
                String.Equals(first.Name, second.Name, StringComparison.OrdinalIgnoreCase) && first.Command == second.Command;
        }
        internal static bool SameBytes(byte[] first, byte[] second)
        { return first == null || second == null ? first == second : first.SequenceEqual(second); }
        private static bool ValidName(string value)
        { return !String.IsNullOrWhiteSpace(value) && value.Length <= 256 && !value.Any(Char.IsControl); }
        private static bool SamePath(string first, string second)
        { return first != null && second != null && String.Equals(first.TrimEnd('\\'), second.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase); }
        private static string Canonical(string value)
        {
            try { return DiscordInstallation.CanonicalLocalPath(value); }
            catch { throw Conflict(); }
        }
        private static string[] ValidateOptions(string[] values)
        {
            values = values ?? new string[0];
            if (values.Length > 2 || values.Any(value => !DnsOptions.IsArgument(value))) throw Conflict();
            DnsOptions.Parse(values); return values.ToArray();
        }
        private static string Command(string helper, string selectedRoot, string[] values)
        {
            string command = NativeProcess.Quote(helper) + " --startup --discord-path " + NativeProcess.Quote(selectedRoot) + (values.Length == 0 ? "" : " " + String.Join(" ", values));
            if (command.Length > 260)
                throw new UserActionException("The Windows startup command exceeds the 260-character limit. Move the package to a shorter, permanent local folder and enable startup again; the existing startup entries were not changed.");
            return command;
        }
        private static bool MentionsRoot(string command, string selectedRoot)
        {
            return command != null && (command.IndexOf(selectedRoot, StringComparison.OrdinalIgnoreCase) >= 0 ||
                Environment.ExpandEnvironmentVariables(command).IndexOf(selectedRoot, StringComparison.OrdinalIgnoreCase) >= 0);
        }
        private static bool Recognized(RunEntry entry, string selectedRoot, out string image)
        {
            image = null;
            if (entry == null || entry.Command == null || entry.Command.Length < 1 || entry.Command.Length > 4096 ||
                entry.Command.Any(Char.IsControl) || (entry.Kind != RegistryValueKind.String && entry.Kind != RegistryValueKind.ExpandString)) return false;
            string command = entry.Kind == RegistryValueKind.ExpandString ? Environment.ExpandEnvironmentVariables(entry.Command) : entry.Command;
            string path, arguments;
            if (command.StartsWith("\"", StringComparison.Ordinal))
            {
                int end = command.IndexOf('"', 1);
                if (end < 1 || (command.Length > end + 1 && command[end + 1] != ' ' && command[end + 1] != '\t')) return false;
                path = command.Substring(1, end - 1); arguments = command.Substring(end + 1).Trim();
            }
            else
            {
                int end = command.IndexOfAny(new[] { ' ', '\t' });
                path = end < 0 ? command : command.Substring(0, end); arguments = end < 0 ? "" : command.Substring(end + 1).Trim();
            }
            try
            {
                path = Canonical(path);
                string name = Path.GetFileName(path), parent = Path.GetDirectoryName(path), candidate = parent;
                bool update = String.Equals(name, "Update.exe", StringComparison.OrdinalIgnoreCase);
                if (!update && !String.Equals(name, "Discord.exe", StringComparison.OrdinalIgnoreCase)) return false;
                if (!update && AppFolder.IsMatch(Path.GetFileName(parent))) candidate = Path.GetDirectoryName(parent);
                if (!SamePath(candidate, selectedRoot)) return false;
                bool args = update ? UpdaterArguments.IsMatch(arguments) : arguments.Length == 0 || arguments == "--start-minimized" || UpdaterArguments.IsMatch(arguments);
                if (!args) return false;
                image = path; return true;
            }
            catch { return false; }
        }
        internal static bool ApprovalEnabled(byte[] value)
        {
            if (value == null) return true;
            if (value.Length != 12 || value[1] != 0 || value[2] != 0 || value[3] != 0) throw Conflict();
            if (value[0] == 2 || value[0] == 6) return true;
            if (value[0] == 3 || value[0] == 7) return false;
            throw new UserActionException("The format of the Windows startup approval was not recognized. The startup entries were not changed.");
        }
        private static UserActionException Conflict()
        { return new UserActionException("The Windows startup entry changed or could not be verified. The user change was not overwritten; the recovery record was kept."); }
        private static UserActionException Unsupported()
        { return new UserActionException("The active startup entry of this Discord is in HKLM, the Startup folder or an unrecognized command. To guarantee the order, turn this entry off in the Windows startup settings; the program did not change this entry."); }

        // Filesystem persistence is separable from the Windows registry backend
        // so its exact call chain can be checked with an inert work journal.
        internal sealed class FileJournal
        {
            private readonly string path;
            private readonly Action prepare;
            private readonly Action<string> validate;
            internal FileJournal(string path, Action prepare, Action<string> validate)
            { this.path = path; this.prepare = prepare; this.validate = validate; }
            internal void Replace(byte[] expected, byte[] replacement)
            {
                prepare();
                try { FileTransaction.ReplaceExpected(path, expected, replacement, JournalLimit, validate); }
                catch (InvalidDataException) { throw Conflict(); }
            }
        }

        private sealed class WindowsEnvironment : IEnvironment
        {
            private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
            private const string ApprovalKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\";
            private readonly string session = Path.Combine(Safety.StateRoot, "v3", "startup-session");
            private string Journal { get { return Path.Combine(session, "journal.json"); } }
            public IEnumerable<RunEntry> UserRun() { return ReadRun(RegistryHive.CurrentUser, RegistryView.Registry64, "Run"); }
            public IEnumerable<RunEntry> OtherStartup()
            {
                var result = new List<RunEntry>();
                result.AddRange(ReadRun(RegistryHive.LocalMachine, RegistryView.Registry64, "Run"));
                result.AddRange(ReadRun(RegistryHive.LocalMachine, RegistryView.Registry32, "Run32"));
                // HKCU Run32 may share the native values. Only distinct entries
                // can constitute a second, independently launched client.
                var native = UserRun().ToArray();
                result.AddRange(ReadRun(RegistryHive.CurrentUser, RegistryView.Registry32, "Run32")
                    .Where(entry => !native.Any(value => SameEntry(value, entry))));
                result.AddRange(ReadLinks(Environment.GetFolderPath(Environment.SpecialFolder.Startup), false));
                result.AddRange(ReadLinks(Environment.GetFolderPath(Environment.SpecialFolder.CommonStartup), true));
                return result;
            }
            public byte[] Approval(string name)
            { return ReadApproval(RegistryHive.CurrentUser, "Run", name); }
            private static byte[] ReadApproval(RegistryHive hive, string area, string name)
            {
                using (var basis = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64))
                using (var key = basis.OpenSubKey(ApprovalKey + area, false))
                {
                    if (key == null || !key.GetValueNames().Contains(name, StringComparer.OrdinalIgnoreCase)) return null;
                    if (key.GetValueKind(name) != RegistryValueKind.Binary) throw Conflict();
                    byte[] bytes = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as byte[];
                    if (bytes == null || bytes.Length > 64) throw Conflict(); return bytes;
                }
            }
            private static IEnumerable<RunEntry> ReadRun(RegistryHive hive, RegistryView view, string approvalArea)
            {
                var result = new List<RunEntry>();
                using (var basis = RegistryKey.OpenBaseKey(hive, view))
                using (var key = basis.OpenSubKey(RunKey, false))
                {
                    if (key == null) return result;
                    var names = key.GetValueNames(); if (names.Length > 128) throw Conflict();
                    foreach (string name in names)
                    {
                        RegistryValueKind kind = key.GetValueKind(name);
                        string command = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                        bool enabled = true;
                        // Do not inspect unrelated applications' private status
                        // formats. Their commands are not candidates to mutate.
                        if (name.IndexOf("Discord", StringComparison.OrdinalIgnoreCase) >= 0)
                            enabled = ApprovalEnabled(ReadApproval(hive, approvalArea, name));
                        result.Add(new RunEntry { Name = name, Command = command, Kind = kind, Enabled = enabled });
                    }
                }
                return result;
            }
            private static IEnumerable<RunEntry> ReadLinks(string folder, bool common)
            {
                var result = new List<RunEntry>();
                if (String.IsNullOrEmpty(folder) || !Directory.Exists(folder)) return result;
                if (!Safety.NoReparse(folder)) throw Unsupported();
                string[] paths = Directory.GetFiles(folder, "*.lnk", SearchOption.TopDirectoryOnly);
                if (paths.Length > 128) throw Unsupported();
                object shell = null;
                try
                {
                    shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true));
                    foreach (string path in paths)
                    {
                        if (!Safety.NoReparse(path)) throw Unsupported();
                        object link = null;
                        try
                        {
                            link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
                            string target = link.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, link, null) as string;
                            string args = link.GetType().InvokeMember("Arguments", BindingFlags.GetProperty, null, link, null) as string;
                            string name = Path.GetFileName(path);
                            result.Add(new RunEntry { Name = name, Command = NativeProcess.Quote(target ?? "") + " " + (args ?? ""),
                                Enabled = ApprovalEnabled(ReadApproval(common ? RegistryHive.LocalMachine : RegistryHive.CurrentUser, "StartupFolder", name)) });
                        }
                        finally { if (link != null && Marshal.IsComObject(link)) Marshal.FinalReleaseComObject(link); }
                    }
                }
                finally { if (shell != null && Marshal.IsComObject(shell)) Marshal.FinalReleaseComObject(shell); }
                return result;
            }
            public void ReplaceRun(string name, RunEntry expected, RunEntry replacement)
            {
                using (var basis = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64))
                using (var key = basis.CreateSubKey(RunKey))
                {
                    RunEntry current = null;
                    if (key.GetValueNames().Contains(name, StringComparer.OrdinalIgnoreCase))
                        current = new RunEntry { Name = name, Command = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string, Kind = key.GetValueKind(name) };
                    if (!SameEntry(current, expected)) throw Conflict();
                    if (replacement == null) key.DeleteValue(name, false);
                    else key.SetValue(name, replacement.Command, replacement.Kind);
                    key.Flush();
                }
            }
            public void VerifyRoot(string root) { DiscordInstallation.VerifyRecoveryRoot(root, null); }
            public void VerifyDiscordImage(string image) { using (new TrustedImage(image, true)) { } }
            public void VerifyHelper(string helper)
            {
                if (!SamePath(helper, Canonical(Assembly.GetExecutingAssembly().Location)) ||
                    !String.Equals(Path.GetFileName(helper), "DiscordAccess.exe", StringComparison.OrdinalIgnoreCase) || !Safety.NoReparse(helper)) throw Conflict();
                using (Safety.ReadLease(helper)) { }
                StartupPathTrust.Verify(helper);
            }
            public byte[] ReadJournal()
            {
                if (!Safety.NoReparse(session) || !Safety.NoReparse(Journal)) throw Conflict();
                if (!File.Exists(Journal)) return null;
                Prepare(false);
                using (var stream = Safety.ReadLease(Journal)) return Read(stream);
            }
            public void ReplaceJournal(byte[] expected, byte[] replacement)
            {
                new FileJournal(Journal, () => Prepare(true), RequireFilePath).Replace(expected, replacement);
            }
            private void Prepare(bool create)
            {
                if (!Safety.NoReparse(session) || !Safety.NoReparse(Journal)) throw Conflict();
                var allowed = new[] { WindowsIdentity.GetCurrent().User, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                    new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) };
                if (!Directory.Exists(session))
                {
                    if (!create) throw Conflict();
                    Safety.EnsureStateDirectory();
                    var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
                    foreach (var sid in allowed) security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                        InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                    Directory.CreateDirectory(session, security);
                }
                if (!Safety.NoReparse(session)) throw Conflict();
                var actual = Directory.GetAccessControl(session);
                var names = allowed.Select(sid => sid.Value).ToArray();
                if (!actual.AreAccessRulesProtected || !names.Contains(((SecurityIdentifier)actual.GetOwner(typeof(SecurityIdentifier))).Value) ||
                    actual.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().Any(rule =>
                        rule.AccessControlType == AccessControlType.Allow && !names.Contains(rule.IdentityReference.Value))) throw Conflict();
                if (File.Exists(Journal))
                {
                    var fileSecurity = File.GetAccessControl(Journal);
                    if (!names.Contains(((SecurityIdentifier)fileSecurity.GetOwner(typeof(SecurityIdentifier))).Value) ||
                        fileSecurity.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().Any(rule =>
                            rule.AccessControlType == AccessControlType.Allow && !names.Contains(rule.IdentityReference.Value))) throw Conflict();
                }
            }
            private static byte[] Read(Stream stream)
            {
                if (stream.Length < 2 || stream.Length > JournalLimit) throw Conflict();
                byte[] value = new byte[(int)stream.Length]; int offset = 0;
                while (offset < value.Length) { int n = stream.Read(value, offset, value.Length - offset); if (n == 0) throw Conflict(); offset += n; }
                return value;
            }
            private static void RequireFilePath(string path)
            { if (!Safety.NoReparse(path)) throw Conflict(); }
        }
    }
}
