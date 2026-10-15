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
        private Mutex initialMutex;
        private NamespaceLease namespaceLease;
        private ResidentStateLease.Lease stateLease;
        private bool owns, ownsInitial;
        private string baseName;
        internal bool CreatedNew { get; private set; }
        internal bool IsPrimary { get; private set; }

        private ResidentInstance(string name, SecurityIdentifier user, string fixture)
        {
            BeginAcquisitionTrace();
            baseName = name;
            try
            {
                // An old namespace can outlive its creator as unreachable
                // objects. The file lease, not that object generation, decides
                // whether this user already has an active controller.
                AcquisitionStage("state-lease-open");
#if TEST_BUILD
                stateLease = fixture == null ? ResidentStateLease.TryAcquire() : ResidentStateLease.TryAcquireForChecks(fixture);
#else
                stateLease = ResidentStateLease.TryAcquire();
#endif
                if (stateLease == null) return;
                AcquisitionStage("initial-namespace-acquire");
                bool created;
                using (var initialNamespace = NamespaceLease.Acquire(name, user, true, true))
                {
                    // Reachable old Owner objects still receive exact trust,
                    // type and abandoned-owner checks. A retired namespace can
                    // be unreachable while another opener retains it; only the
                    // verified writer lease permits moving past that case.
                    if (initialNamespace != null)
                    {
                        AcquisitionStage("initial-owner-create");
                        initialMutex = new Mutex(true, name + "\\Owner", out created, Security(user));
                        CreatedNew = created; ownsInitial = created;
                        AcquisitionStage("initial-owner-trust");
                        if (!Trusted(initialMutex.GetAccessControl(), user)) throw Rejected();
                        if (!ownsInitial)
                        {
                            AcquisitionStage("initial-owner-wait");
                            try { ownsInitial = initialMutex.WaitOne(0); }
                            catch (AbandonedMutexException) { ownsInitial = true; }
                        }
                        if (!ownsInitial) { Dispose(); return; }
                    }
                    else AcquisitionStage("initial-namespace-retired");
                }
                // Keep the initial mutex handle, whose operations remain valid
                // after alias closure. Give the controller a fresh private
                // boundary whose creator lifetime is this primary's lifetime.
                string generation;
                AcquisitionStage("generation-namespace-create");
                namespaceLease = NamespaceLease.CreateGeneration(name, user, out generation);
                AcquisitionStage("generation-owner-create");
                mutex = new Mutex(true, namespaceLease.ObjectName("Owner"), out created, Security(user));
                owns = created;
                AcquisitionStage("generation-owner-trust", created ? 0 : 183);
                if (!created || !Trusted(mutex.GetAccessControl(), user)) throw Rejected();
                AcquisitionStage("generation-publication");
                using (var process = Process.GetCurrentProcess()) stateLease.Publish(user, process.SessionId, generation);
                namespaceLease.PublishLocal(name);
                IsPrimary = true;
            }
            catch (Exception error)
            {
                AcquisitionFailure(error);
                Dispose(); throw Rejected();
            }
        }

        [Conditional("TEST_BUILD")]
        private static void BeginAcquisitionTrace()
        {
#if TEST_BUILD
            acquisitionTrace = new List<string>(); acquisitionFailure = null;
#endif
        }
        [Conditional("TEST_BUILD")]
        private static void AcquisitionStage(string stage, int error = 0)
        {
#if TEST_BUILD
            if (acquisitionTrace == null) acquisitionTrace = new List<string>();
            if (acquisitionTrace.Count < 32) acquisitionTrace.Add(stage + "(win32=" + error.ToString(CultureInfo.InvariantCulture) + ")");
#endif
        }
        [Conditional("TEST_BUILD")]
        private static void AcquisitionFailure(Exception error)
        {
#if TEST_BUILD
            acquisitionFailure = error.GetType().Name + " HRESULT=0x" + error.HResult.ToString("x8", CultureInfo.InvariantCulture) +
                "; last=" + (acquisitionTrace == null || acquisitionTrace.Count == 0 ? "none" : acquisitionTrace[acquisitionTrace.Count - 1]) +
                "; " + String.Join(" -> ", acquisitionTrace ?? new List<string>());
#endif
        }

        internal static ResidentInstance Acquire()
        {
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
                return new ResidentInstance(Name(user, process.SessionId, null), user, null);
        }

        // A signal listener/request needs an alias lease, not mutex ownership.
        // Requests only open a namespace established by an existing resident.
        internal static NamespaceLease AcquireNamespace() { return Namespace(null, true); }
        internal static NamespaceLease OpenNamespace() { return Namespace(null, false); }

        private static NamespaceLease Namespace(string fixture, bool create)
        {
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
            {
                string name = Name(user, process.SessionId, fixture);
                if (create)
                {
                    string local = NamespaceLease.LocalGeneration(name);
                    if (local != null) return NamespaceLease.Acquire(local, user, false);
#if TEST_BUILD
                    if (fixture != null) return NamespaceLease.Acquire(name, user, true);
#endif
                    throw Rejected(); // Listeners require this process's primary.
                }
                string generation;
#if TEST_BUILD
                generation = fixture == null ? ResidentStateLease.ReadGeneration(user, process.SessionId) :
                    ResidentStateLease.ReadGenerationForChecks(fixture, user, process.SessionId);
#else
                generation = ResidentStateLease.ReadGeneration(user, process.SessionId);
#endif
                if (generation != null) return NamespaceLease.Acquire(GenerationName(name, generation), user, false);
#if TEST_BUILD
                // Raw private fixture events deliberately need no Owner. Never
                // use this test-only route for stale/malformed existing files.
                if (fixture != null && !ResidentStateLease.PublicationExistsForChecks(fixture))
                    return NamespaceLease.Acquire(name, user, false);
#endif
                return null;
            }
        }
        private static string GenerationName(string name, string generation)
        { return name + ".Generation." + generation; }

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
            return new UserActionException("The DiscordAccess session lock could not be verified as safe. Close the open DiscordAccess and try again.");
        }

        public void Dispose()
        {
            // Main disposes listeners first. Invalidate publication and local
            // lookup before releasing either Owner/alias, and the writer last.
            if (namespaceLease != null) namespaceLease.UnpublishLocal(baseName);
            try { if (stateLease != null) stateLease.ClearPublication(); }
            finally
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
                        try { if (lease != null) lease.Dispose(); }
                        finally
                        {
                            var initial = initialMutex; initialMutex = null;
                            try { if (initial != null && ownsInitial) initial.ReleaseMutex(); }
                            finally
                            {
                                ownsInitial = false;
                                try { if (initial != null) initial.Dispose(); }
                                finally
                                {
                                    var state = stateLease; stateLease = null;
                                    if (state != null) state.Dispose();
                                }
                            }
                        }
                    }
                }
            }
        }

        // Win32 aliases are process-local. Multiple fixture/instance leases in
        // one process must share an alias registration, rather than attempting
        // OpenPrivateNamespace again (which reports ERROR_DUP_NAME).
        internal sealed class NamespaceLease : IDisposable
        {
            private sealed class Entry { internal IntPtr Handle; internal int References; }
            private static readonly object Gate = new object();
            private static readonly Dictionary<string, Entry> Entries = new Dictionary<string, Entry>(StringComparer.Ordinal);
            private static readonly Dictionary<string, string> LocalGenerations = new Dictionary<string, string>(StringComparer.Ordinal);
            private string name;
            private Entry entry;
            internal readonly SecurityIdentifier User;

            private NamespaceLease(string name, SecurityIdentifier user, Entry entry)
            { this.name = name; User = user; this.entry = entry; }

            internal string ObjectName(string leaf)
            {
                if (String.IsNullOrEmpty(leaf) || leaf.IndexOf('\\') >= 0) throw new ArgumentException("Resident object name");
                lock (Gate)
                {
                    if (entry == null) throw new ObjectDisposedException("NamespaceLease");
                    if (entry.Handle == IntPtr.Zero) throw Rejected();
                    return name + "\\" + leaf;
                }
            }

            internal static NamespaceLease Acquire(string name, SecurityIdentifier user, bool create, bool allowRetired = false)
            {
                lock (Gate)
                {
                    Entry found;
                    if (!Entries.TryGetValue(name, out found))
                    {
                        IntPtr handle = create ? CreateOrOpen(name, user, allowRetired) : Open(name, user);
                        if (handle == IntPtr.Zero) return null;
                        found = new Entry { Handle = handle, References = 0 };
                        Entries.Add(name, found);
                    }
                    if (found.Handle == IntPtr.Zero) throw Rejected();
                    found.References++;
                    return new NamespaceLease(name, user, found);
                }
            }

            private static IntPtr Open(string name, SecurityIdentifier user)
            {
                IntPtr boundary = CreateBoundary(name, user);
                try
                {
                    // Never create an empty namespace on a request-only path.
                    // A missing/denied namespace is an unavailable resident.
                    return NamespaceNative.OpenPrivateNamespace(boundary, name);
                }
                finally { NamespaceNative.DeleteBoundaryDescriptor(boundary); }
            }

            private static IntPtr CreateOrOpen(string name, SecurityIdentifier user, bool allowRetired)
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
                        AcquisitionStage("namespace-create", createError);
                        if (handle != IntPtr.Zero) return handle;
                        if (createError != 183) throw Rejected(); // ERROR_ALREADY_EXISTS
                        handle = NamespaceNative.OpenPrivateNamespace(boundary, name);
                        int openError = handle == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;
                        AcquisitionStage("namespace-open-existing", openError);
                        if (handle != IntPtr.Zero) return handle;
                        int error = openError;
                        if (error != 2 && error != 3) throw Rejected(); // Owner may have just closed.
                    }
                    if (allowRetired) return IntPtr.Zero;
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

            internal static NamespaceLease CreateGeneration(string baseName, SecurityIdentifier user, out string generation)
            {
                lock (Gate)
                {
                    generation = Guid.NewGuid().ToString("N");
                    string name = GenerationName(baseName, generation);
                    IntPtr boundary = CreateBoundary(name, user);
                    try
                    {
                        int error;
                        IntPtr handle = CreateNamespace(name, boundary, user, out error);
                        AcquisitionStage("generation-namespace-created", error);
                        if (handle == IntPtr.Zero) throw Rejected();
                        var entry = new Entry { Handle = handle, References = 1 };
                        Entries.Add(name, entry);
                        return new NamespaceLease(name, user, entry);
                    }
                    finally { NamespaceNative.DeleteBoundaryDescriptor(boundary); }
                }
            }
            internal void PublishLocal(string baseName)
            {
                lock (Gate)
                {
                    if (entry == null || entry.Handle == IntPtr.Zero || LocalGenerations.ContainsKey(baseName)) throw Rejected();
                    LocalGenerations.Add(baseName, name);
                }
            }
            internal void UnpublishLocal(string baseName)
            {
                lock (Gate)
                {
                    string current;
                    if (entry != null && LocalGenerations.TryGetValue(baseName, out current) && current == name)
                        LocalGenerations.Remove(baseName);
                }
            }
            internal static string LocalGeneration(string baseName)
            {
                lock (Gate) { string name; return LocalGenerations.TryGetValue(baseName, out name) ? name : null; }
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
                    Entry owned = entry; string alias = name; entry = null; name = null;
                    if (--owned.References != 0) return;
                    Entries.Remove(alias);
                    // A primary has its own published generation. Requests and
                    // secondary leases never destroy an existing publication.
                    if (owned.Handle != IntPtr.Zero) NamespaceNative.ClosePrivateNamespace(owned.Handle, 0);
                    owned.Handle = IntPtr.Zero;
                }
            }

#if TEST_BUILD
            internal static int ReferencesForChecks(string name)
            {
                lock (Gate)
                {
                    int count = 0;
                    foreach (var item in Entries)
                        if (item.Key == name || item.Key.StartsWith(name + ".Generation.", StringComparison.Ordinal)) count += item.Value.References;
                    return count;
                }
            }

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
        [ThreadStatic] private static List<string> acquisitionTrace;
        [ThreadStatic] private static string acquisitionFailure;
        internal static string FailureForChecks()
        { return acquisitionFailure ?? String.Join(" -> ", acquisitionTrace ?? new List<string>()); }
        internal static ResidentInstance AcquireForChecks(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
                return new ResidentInstance(Name(user, process.SessionId, fixture), user, fixture);
        }
        internal static string NameForChecks(SecurityIdentifier user, int session, string fixture)
        { return Name(user, session, fixture) + "\\Owner"; }
        internal static string NamespaceNameForChecks(SecurityIdentifier user, int session, string fixture)
        { string name = Name(user, session, fixture); return NamespaceLease.LocalGeneration(name) ?? name; }
        internal static NamespaceLease NamespaceForChecks(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            return Namespace(fixture, true);
        }
        internal static NamespaceLease OpenNamespaceForChecks(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            return Namespace(fixture, false);
        }
        internal static NamespaceLease OpenStaticNamespaceForChecks(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident static fixture identifier");
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
                return NamespaceLease.Acquire(Name(user, process.SessionId, fixture), user, false);
        }
        internal static int NamespaceReferencesForChecks(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
                return NamespaceLease.ReferencesForChecks(Name(user, process.SessionId, fixture));
        }
        internal static int ForeignBoundaryErrorForChecks(string fixture, SecurityIdentifier foreign)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident fixture identifier");
            SecurityIdentifier user = CurrentUser();
            using (var process = Process.GetCurrentProcess())
                return NamespaceLease.ForeignBoundaryError(Name(user, process.SessionId, fixture), user, foreign);
        }
        internal static MutexSecurity SecurityForChecks(SecurityIdentifier user) { return Security(user); }
        internal static bool TrustedForChecks(MutexSecurity security, SecurityIdentifier user) { return Trusted(security, user); }
#endif
    }
}
