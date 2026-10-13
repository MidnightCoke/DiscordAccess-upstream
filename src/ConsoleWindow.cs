using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace DiscordAccess
{
    internal static class ConsoleWindow
    {
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AllocConsole();
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GetStdHandle(int kind);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetStdHandle(int kind, IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint GetFileType(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetConsoleMode(IntPtr handle, out uint mode);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DuplicateHandle(IntPtr sourceProcess,
            IntPtr source, IntPtr targetProcess, out SafeFileHandle duplicate, uint access, bool inherit, uint options);
        private static readonly object sync = new object();
        // Console.OpenStandard* wraps these handles without owning them. Keep
        // private duplicates alive until this process exits; do
        // not close inherited handles or handles belonging to the parent CMD.
        private static readonly List<SafeFileHandle> redirectedHandles = new List<SafeFileHandle>(3);
        private static bool ready;
        internal static void Ensure()
        {
            lock (sync)
            {
                if (ready) return;
                int[] kinds = { -10, -11, -12 };
                var saved = new SafeFileHandle[3];
                bool transferred = false;
                try
                {
                    for (int index = 0; index < kinds.Length; index++) saved[index] = PreserveRedirection(kinds[index]);
                    if (!AttachConsole(UInt32.MaxValue) && Marshal.GetLastWin32Error() != 5 && !AllocConsole()) return;
                    foreach (var handle in saved) if (handle != null) redirectedHandles.Add(handle);
                    transferred = true;
                    for (int index = 0; index < kinds.Length; index++)
                        if (saved[index] != null && !SetStdHandle(kinds[index], saved[index].DangerousGetHandle()))
                            throw new IOException("Konsol yönlendirmesi geri bağlanamadı.");
                    Console.InputEncoding = new UTF8Encoding(false);
                    Console.OutputEncoding = new UTF8Encoding(false);
                    Console.SetIn(new StreamReader(Console.OpenStandardInput(), Console.InputEncoding));
                    Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), Console.OutputEncoding) { AutoFlush = true });
                    Console.SetError(new StreamWriter(Console.OpenStandardError(), Console.OutputEncoding) { AutoFlush = true });
                    ready = true;
                }
                finally
                {
                    if (!transferred) foreach (var handle in saved) if (handle != null) handle.Dispose();
                }
            }
        }
        private static SafeFileHandle PreserveRedirection(int kind)
        {
            IntPtr original = GetStdHandle(kind);
            if (original == IntPtr.Zero || original == new IntPtr(-1)) return null;
            uint type = GetFileType(original) & 0x7fff, mode;
            // Preserve disk/pipe redirects and explicit NUL/device handles.
            // Actual console handles must be obtained from Attach/AllocConsole.
            if (type != 1 && type != 3 && !(type == 2 && !GetConsoleMode(original, out mode))) return null;
            SafeFileHandle duplicate;
            IntPtr current = GetCurrentProcess();
            if (!DuplicateHandle(current, original, current, out duplicate, 0, false, 2))
            {
                if (duplicate != null) duplicate.Dispose();
                throw new IOException("Konsol yönlendirmesi korunamadı.");
            }
            return duplicate;
        }
    }
    // Shortcut journals are per-user, even across two Windows logon sessions.
    // This lifetime file lease is authoritative across private namespace
    // generations and Windows sessions. Trust errors never mean "busy".
    internal static class ResidentStateLease
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct AttributeTag { internal uint Attributes, ReparseTag; }
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass,
            out AttributeTag information, uint size);
        internal static IDisposable Acquire()
        {
            var lease = TryAcquire();
            if (lease == null) throw Busy();
            return lease;
        }
        internal static IDisposable TryAcquire()
        {
            Safety.EnsureStateDirectory();
            return Open(Path.Combine(Safety.StateRoot, "v3", "resident.lock"));
        }
        private static UserActionException Busy()
        { return new UserActionException("Bu kullanıcı için başka bir DiscordAccess oturumu açık. Önce o oturumu kapatın."); }
        private static IDisposable Open(string path)
        {
            path = Path.GetFullPath(path);
            if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.Length < 3 || path[1] != ':' || path.IndexOf(':', 2) >= 0)
                throw new InvalidDataException("State lease local path");
            if (!Safety.NoReparse(path)) throw new InvalidDataException("State lease path");
            if (File.Exists(path) && !Trusted(File.GetAccessControl(path))) throw new InvalidDataException("State lease access");
            FileStream lease = null;
            try
            {
                lease = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                AttributeTag information;
                if (!Safety.NoReparse(path) || !String.Equals(Path.GetFullPath(path), NativeFile.FinalPath(lease.SafeFileHandle), StringComparison.OrdinalIgnoreCase) ||
                    !GetFileInformationByHandleEx(lease.SafeFileHandle, 9, out information, (uint)Marshal.SizeOf(typeof(AttributeTag))) ||
                    (information.Attributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 ||
                    !Trusted(lease.GetAccessControl()))
                    throw new InvalidDataException("State lease changed");
                return lease;
            }
            catch (IOException error)
            {
                bool openFailed = lease == null;
                if (lease != null) lease.Dispose();
                int code = error.HResult & 0xffff;
                if (openFailed && (code == 32 || code == 33)) return null; // exclusive-open sharing/lock violation only
                throw;
            }
            catch { if (lease != null) lease.Dispose(); throw; }
        }
        private static bool Trusted(FileSystemSecurity security)
        {
            if (security == null) return false;
            SecurityIdentifier user;
            using (var identity = WindowsIdentity.GetCurrent()) user = identity.User;
            if (user == null) return false;
            var raw = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            if (raw.Owner == null || (raw.Owner.Value != user.Value && raw.Owner.Value != "S-1-5-18" && raw.Owner.Value != "S-1-5-32-544") ||
                (raw.ControlFlags & ControlFlags.DiscretionaryAclPresent) == 0 || raw.DiscretionaryAcl == null) return false;
            bool userAccess = false, systemAccess = false;
            foreach (GenericAce item in raw.DiscretionaryAcl)
            {
                var rule = item as CommonAce;
                if (rule == null || rule.IsCallback || rule.AceQualifier != AceQualifier.AccessAllowed || rule.SecurityIdentifier == null ||
                    rule.AccessMask != (int)FileSystemRights.FullControl ||
                    (rule.AceFlags & ~(AceFlags.ObjectInherit | AceFlags.ContainerInherit | AceFlags.Inherited)) != 0) return false;
                string sid = rule.SecurityIdentifier.Value;
                if (sid != user.Value && sid != "S-1-5-18" && sid != "S-1-5-32-544") return false;
                if (sid == user.Value) userAccess = true;
                if (sid == "S-1-5-18") systemAccess = true;
            }
            // Files may inherit the already-verified protected state directory
            // descriptor. Do not rewrite existing file or directory ACLs.
            return userAccess && systemAccess;
        }
#if TEST_BUILD
        internal static string PathForChecks(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident state fixture identifier");
            return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "work", "resident-instance-fixtures", fixture + ".lock");
        }
        internal static IDisposable TryAcquireForChecks(string fixture)
        {
            string path = PathForChecks(fixture), directory = Path.GetDirectoryName(path);
            if (!Safety.NoReparse(directory)) throw new InvalidDataException("State fixture directory");
            if (!Directory.Exists(directory))
            {
                var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
                using (var identity = WindowsIdentity.GetCurrent())
                {
                    if (identity.User == null) throw new InvalidDataException("State fixture user");
                    security.SetOwner(identity.User);
                    foreach (var sid in new[] { identity.User, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
                        security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                }
                Directory.CreateDirectory(directory, security);
            }
            if (!Safety.NoReparse(directory) || !Directory.GetAccessControl(directory).AreAccessRulesProtected ||
                !Trusted(Directory.GetAccessControl(directory))) throw new InvalidDataException("State fixture directory access");
            return Open(path);
        }
#endif
    }
}
