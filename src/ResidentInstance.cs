using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;

namespace DiscordAccess
{
    // Acquire and Dispose on the same main thread: Windows mutex ownership is
    // thread-bound. Existence alone is not proof of a live primary instance.
    internal sealed class ResidentInstance : IDisposable
    {
        private Mutex mutex;
        private PrivateNamespace namespaceLease;
        private bool owns;
        internal bool CreatedNew { get; private set; }
        internal bool IsPrimary { get; private set; }

        private ResidentInstance(string name, SecurityIdentifier user)
        {
            try
            {
                namespaceLease = PrivateNamespace.Acquire(name, user);
                bool created;
                mutex = new Mutex(true, name + "\\Owner", out created, Security(user));
                CreatedNew = created; owns = created;
                if (!Trusted(mutex.GetAccessControl(), user)) throw Rejected();
                if (!owns)
                {
                    try { owns = mutex.WaitOne(0); }
                    catch (AbandonedMutexException) { owns = true; }
                }
                IsPrimary = owns;
            }
            catch
            {
                Dispose(); throw Rejected();
            }
        }

        internal static ResidentInstance Acquire()
        {
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
                return new ResidentInstance(Name(user, process.SessionId, null), user);
        }

        private static SecurityIdentifier CurrentUser()
        {
            using (var identity = WindowsIdentity.GetCurrent())
            {
                if (identity.User == null) throw Rejected();
                return identity.User;
            }
        }

        private static string Name(SecurityIdentifier user, int session, string fixture)
        {
            if (user == null || session < 0) throw Rejected();
            if (fixture != null)
            {
                Guid parsed;
                if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            }
            return "DiscordAccess.Resident.V2." + user.Value + "." + session.ToString(CultureInfo.InvariantCulture) +
                (fixture == null ? "" : ".Test." + fixture);
        }

        private static MutexSecurity Security(SecurityIdentifier user)
        {
            var security = new MutexSecurity();
            security.SetAccessRuleProtection(true, false); security.SetOwner(user);
            security.AddAccessRule(new MutexAccessRule(user, MutexRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new MutexAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                MutexRights.FullControl, AccessControlType.Allow));
            return security;
        }

        private static bool Trusted(MutexSecurity security, SecurityIdentifier user)
        {
            if (security == null || user == null) return false;
            var raw = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            if (raw.Owner == null || !user.Equals(raw.Owner) ||
                (raw.ControlFlags & (ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclProtected)) !=
                    (ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclProtected) || raw.DiscretionaryAcl == null) return false;
            bool userAccess = false, systemAccess = false;
            foreach (GenericAce entry in raw.DiscretionaryAcl)
            {
                var rule = entry as CommonAce;
                if (rule == null || rule.IsCallback || rule.AceQualifier != AceQualifier.AccessAllowed || rule.AceFlags != AceFlags.None ||
                    rule.SecurityIdentifier == null || rule.AccessMask != (int)MutexRights.FullControl) return false;
                string sid = rule.SecurityIdentifier.Value;
                if (sid == user.Value) userAccess = true;
                else if (sid != "S-1-5-18") return false;
                if (sid == "S-1-5-18") systemAccess = true;
            }
            return userAccess && systemAccess;
        }

        private static UserActionException Rejected()
        {
            return new UserActionException("DiscordAccess'in oturum kilidi güvenli doğrulanamadı. Açık DiscordAccess'i kapatıp yeniden deneyin.");
        }

        public void Dispose()
        {
            var handle = mutex; mutex = null;
            try { if (handle != null && owns) handle.ReleaseMutex(); }
            finally
            {
                owns = false; IsPrimary = false;
                try { if (handle != null) handle.Dispose(); }
                finally
                {
                    var lease = namespaceLease; namespaceLease = null;
                    if (lease != null) lease.Dispose();
                }
            }
        }

        // Win32 aliases are process-local. Multiple fixture/instance leases in
        // one process must share an alias registration, rather than attempting
        // OpenPrivateNamespace again (which reports ERROR_DUP_NAME).
        private sealed class PrivateNamespace : IDisposable
        {
            private sealed class Entry { internal IntPtr Handle; internal int References; }
            private static readonly object Gate = new object();
            private static readonly Dictionary<string, Entry> Entries = new Dictionary<string, Entry>(StringComparer.Ordinal);
            private string name;
            private Entry entry;

            private PrivateNamespace(string name, Entry entry) { this.name = name; this.entry = entry; }

            internal static PrivateNamespace Acquire(string name, SecurityIdentifier user)
            {
                lock (Gate)
                {
                    Entry found;
                    if (!Entries.TryGetValue(name, out found))
                    {
                        found = new Entry { Handle = CreateOrOpen(name, user), References = 0 };
                        Entries.Add(name, found);
                    }
                    found.References++;
                    return new PrivateNamespace(name, found);
                }
            }

            private static IntPtr CreateOrOpen(string name, SecurityIdentifier user)
            {
                IntPtr boundary = CreateBoundary(name, user);
                try
                {
                    // A creator must belong to the SID boundary. Opening need
                    // not enforce membership, so the namespace DACL is also
                    // protected and grants access only to this user and SYSTEM.
                    // The pseudo-handle is retained until the last local lease.
                    for (int attempt = 0; attempt < 4; attempt++)
                    {
                        int createError;
                        IntPtr handle = CreateNamespace(name, boundary, user, out createError);
                        if (handle != IntPtr.Zero) return handle;
                        if (createError != 183) throw Rejected(); // ERROR_ALREADY_EXISTS
                        handle = NamespaceNative.OpenPrivateNamespace(boundary, name);
                        if (handle != IntPtr.Zero) return handle;
                        int error = Marshal.GetLastWin32Error();
                        if (error != 2 && error != 3) throw Rejected(); // Owner may have just closed.
                    }
                    throw Rejected();
                }
                finally { NamespaceNative.DeleteBoundaryDescriptor(boundary); }
            }

            private static IntPtr CreateBoundary(string name, SecurityIdentifier user)
            {
                IntPtr boundary = NamespaceNative.CreateBoundaryDescriptor(name, 0);
                if (boundary == IntPtr.Zero) throw Rejected();
                try
                {
                    var sid = new byte[user.BinaryLength]; user.GetBinaryForm(sid, 0);
                    if (!NamespaceNative.AddSIDToBoundaryDescriptor(ref boundary, sid)) throw Rejected();
                    return boundary;
                }
                catch { NamespaceNative.DeleteBoundaryDescriptor(boundary); throw; }
            }

            private static IntPtr CreateNamespace(string name, IntPtr boundary, SecurityIdentifier user, out int error)
            {
                var descriptor = new RawSecurityDescriptor("O:" + user.Value + "D:P(A;;GA;;;" + user.Value + ")(A;;GA;;;SY)");
                var bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
                var pinned = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                try
                {
                    var security = new NamespaceNative.SecurityAttributes {
                        Length = Marshal.SizeOf(typeof(NamespaceNative.SecurityAttributes)),
                        Descriptor = pinned.AddrOfPinnedObject(), InheritHandle = false };
                    IntPtr handle = NamespaceNative.CreatePrivateNamespace(ref security, boundary, name);
                    error = handle == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;
                    return handle;
                }
                finally { pinned.Free(); }
            }

            public void Dispose()
            {
                lock (Gate)
                {
                    if (entry == null) return;
                    Entry owned = entry; entry = null;
                    if (--owned.References != 0) return;
                    Entries.Remove(name); name = null;
                    // DESTROY would invalidate lookup while another process
                    // could still own a mutex in this namespace. Close only our
                    // alias handle; the kernel owns cross-process lifetime.
                    NamespaceNative.ClosePrivateNamespace(owned.Handle, 0);
                    owned.Handle = IntPtr.Zero;
                }
            }

#if TEST_BUILD
            internal static int ForeignBoundaryError(string name, SecurityIdentifier user, SecurityIdentifier foreign)
            {
                IntPtr boundary = CreateBoundary(name, foreign);
                try
                {
                    int error;
                    IntPtr handle = CreateNamespace(name, boundary, user, out error);
                    if (handle != IntPtr.Zero) NamespaceNative.ClosePrivateNamespace(handle, 0);
                    return error;
                }
                finally { NamespaceNative.DeleteBoundaryDescriptor(boundary); }
            }
#endif
        }

        private static class NamespaceNative
        {
            [StructLayout(LayoutKind.Sequential)]
            internal struct SecurityAttributes
            {
                internal int Length;
                internal IntPtr Descriptor;
                [MarshalAs(UnmanagedType.Bool)] internal bool InheritHandle;
            }
            [DllImport("kernel32.dll", EntryPoint = "CreateBoundaryDescriptorW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
            internal static extern IntPtr CreateBoundaryDescriptor(string name, uint flags);
            [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool AddSIDToBoundaryDescriptor(ref IntPtr boundary, byte[] sid);
            [DllImport("kernel32.dll", ExactSpelling = true)]
            internal static extern void DeleteBoundaryDescriptor(IntPtr boundary);
            [DllImport("kernel32.dll", EntryPoint = "CreatePrivateNamespaceW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
            internal static extern IntPtr CreatePrivateNamespace(ref SecurityAttributes security, IntPtr boundary, string alias);
            [DllImport("kernel32.dll", EntryPoint = "OpenPrivateNamespaceW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
            internal static extern IntPtr OpenPrivateNamespace(IntPtr boundary, string alias);
            [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
            [return: MarshalAs(UnmanagedType.U1)]
            internal static extern bool ClosePrivateNamespace(IntPtr handle, uint flags);
        }

#if TEST_BUILD
        internal static ResidentInstance AcquireForChecks(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
                return new ResidentInstance(Name(user, process.SessionId, fixture), user);
        }
        internal static string NameForChecks(SecurityIdentifier user, int session, string fixture)
        { return Name(user, session, fixture) + "\\Owner"; }
        internal static string NamespaceNameForChecks(SecurityIdentifier user, int session, string fixture)
        { return Name(user, session, fixture); }
        internal static IDisposable NamespaceForChecks(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess()) return PrivateNamespace.Acquire(Name(user, process.SessionId, fixture), user);
        }
        internal static int ForeignBoundaryErrorForChecks(string fixture, SecurityIdentifier foreign)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
                return PrivateNamespace.ForeignBoundaryError(Name(user, process.SessionId, fixture), user, foreign);
        }
        internal static MutexSecurity SecurityForChecks(SecurityIdentifier user) { return Security(user); }
        internal static bool TrustedForChecks(MutexSecurity security, SecurityIdentifier user) { return Trusted(security, user); }
#endif
    }
}
