using System;
using System.Collections.Generic;
using System.Globalization;
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
                            throw new IOException("The console redirection could not be reattached.");
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
                throw new IOException("The console redirection could not be preserved.");
            }
            return duplicate;
        }
    }
    // Shortcut journals are per-user, even across two Windows logon sessions.
    // This lifetime file lease is authoritative across private namespace
    // generations and Windows sessions. Trust errors never mean "busy".
    internal static class ResidentStateLease
    {
        private const string PublicationVersion = "DiscordAccess.Resident.V3";
        private const int MaximumPublicationBytes = 512;
        internal sealed class Lease : IDisposable
        {
            private FileStream stream;
            private bool published;
            internal Lease(FileStream stream) { this.stream = stream; }
            internal void Publish(SecurityIdentifier user, int session, string generation)
            {
                Guid parsed;
                if (stream == null || user == null || session < 0 || !Guid.TryParseExact(generation, "N", out parsed) ||
                    parsed == Guid.Empty || generation != parsed.ToString("N")) throw new InvalidDataException("State publication fields");
                byte[] bytes = Encoding.ASCII.GetBytes(PublicationVersion + "\n" + user.Value + "\n" +
                    session.ToString(CultureInfo.InvariantCulture) + "\n" + generation + "\n");
                if (bytes.Length > MaximumPublicationBytes) throw new InvalidDataException("State publication size");
                published = true;
                stream.Position = 0; stream.SetLength(0); stream.Write(bytes, 0, bytes.Length); stream.Flush(true);
            }
            internal void ClearPublication()
            {
                if (stream == null || !published) return;
                stream.Position = 0; stream.SetLength(0); stream.Flush(true); published = false;
            }
            public void Dispose()
            {
                var owned = stream;
                try { ClearPublication(); }
                finally { stream = null; if (owned != null) owned.Dispose(); }
            }
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct AttributeTag { internal uint Attributes, ReparseTag; }
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation
        {
            internal uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            internal uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass,
            out AttributeTag information, uint size);
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
        internal static IDisposable Acquire()
        {
            var lease = TryAcquire();
            if (lease == null) throw Busy();
            return lease;
        }
        internal static Lease TryAcquire()
        {
            Safety.EnsureStateDirectory();
            return Open(Path.Combine(Safety.StateRoot, "v3", "resident.lock"));
        }
        private static UserActionException Busy()
        { return new UserActionException("Another DiscordAccess session is open for this user. Close that session first."); }
        private static Lease Open(string path)
        {
            path = Path.GetFullPath(path);
            if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.Length < 3 || path[1] != ':' || path.IndexOf(':', 2) >= 0)
                throw new InvalidDataException("State lease local path");
            if (!Safety.NoReparse(path)) throw new InvalidDataException("State lease path");
            if (File.Exists(path) && !Trusted(File.GetAccessControl(path))) throw new InvalidDataException("State lease access");
            FileStream lease = null;
            try
            {
                // Read-only request handles are allowed; a second writer and
                // rename/delete remain excluded for this controller lifetime.
                lease = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
                VerifyHandle(path, lease);
                return new Lease(lease);
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
        private static void VerifyHandle(string path, FileStream stream)
        {
            AttributeTag information;
            FileInformation file;
            if (!Safety.NoReparse(path) || !String.Equals(Path.GetFullPath(path), NativeFile.FinalPath(stream.SafeFileHandle), StringComparison.OrdinalIgnoreCase) ||
                !GetFileInformationByHandleEx(stream.SafeFileHandle, 9, out information, (uint)Marshal.SizeOf(typeof(AttributeTag))) ||
                (information.Attributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 ||
                !GetFileInformationByHandle(stream.SafeFileHandle, out file) || file.Links != 1 ||
                !Trusted(stream.GetAccessControl())) throw new InvalidDataException("State lease changed");
        }
        internal static string ReadGeneration(SecurityIdentifier user, int session)
        { return ReadGenerationFrom(Path.Combine(Safety.StateRoot, "v3", "resident.lock"), user, session); }
        private static string ReadGenerationFrom(string path, SecurityIdentifier user, int session)
        {
            // Requests never create a file/directory, open a writer lease, or
            // change ACLs. Invalid/missing/partial records mean unavailable.
            path = Path.GetFullPath(path);
            if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.Length < 3 || path[1] != ':' || path.IndexOf(':', 2) >= 0 ||
                !Safety.NoReparse(path)) throw new InvalidDataException("State publication path");
            string directory = Path.GetDirectoryName(path);
            if (!Directory.Exists(directory)) return null;
            var security = Directory.GetAccessControl(directory);
            if (!security.AreAccessRulesProtected || !Trusted(security)) throw new InvalidDataException("State publication directory access");
            try
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    VerifyHandle(path, stream);
                    long length = stream.Length;
                    if (length == 0 || length > MaximumPublicationBytes) return null;
                    byte[] bytes = new byte[MaximumPublicationBytes + 1]; int count = 0, got;
                    while (count < bytes.Length && (got = stream.Read(bytes, count, bytes.Length - count)) != 0) count += got;
                    if (count != length || count > MaximumPublicationBytes || stream.Length != length) return null;
                    for (int index = 0; index < count; index++)
                        if ((bytes[index] < 32 && bytes[index] != 10) || bytes[index] > 126) return null;
                    string[] fields = Encoding.ASCII.GetString(bytes, 0, count).Split('\n');
                    Guid generation;
                    if (fields.Length != 5 || fields[0] != PublicationVersion || user == null || fields[1] != user.Value ||
                        fields[2] != session.ToString(CultureInfo.InvariantCulture) || fields[4] != "" ||
                        !Guid.TryParseExact(fields[3], "N", out generation) || generation == Guid.Empty ||
                        fields[3] != generation.ToString("N")) return null;
                    return fields[3];
                }
            }
            catch (FileNotFoundException) { return null; }
            catch (DirectoryNotFoundException) { return null; }
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
        internal static Lease TryAcquireForChecks(string fixture)
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
        internal static string ReadGenerationForChecks(string fixture, SecurityIdentifier user, int session)
        { return ReadGenerationFrom(PathForChecks(fixture), user, session); }
        internal static bool PublicationExistsForChecks(string fixture)
        {
            string path = PathForChecks(fixture);
            if (!Safety.NoReparse(path)) throw new InvalidDataException("State publication fixture path");
            return File.Exists(path);
        }
#endif
    }
}
