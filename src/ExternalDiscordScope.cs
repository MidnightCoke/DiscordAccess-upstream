using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace DiscordAccess
{
    // Admission is separate from ownership. An Explorer-started Discord keeps
    // its existing account/profile and is never assigned to a terminating job.
    internal sealed class ExternalDiscordScope : IDisposable
    {
        private const int MaxImages = 16;
        private const int MaxProcesses = 256;
        private const uint QueryAndSynchronize = 0x00101000;
        private readonly object sync = new object();
        private readonly HashSet<string> images = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly List<IDisposable> imageLeases = new List<IDisposable>();
        private readonly Dictionary<int, Record> admitted = new Dictionary<int, Record>();
        private readonly long readyFileTime;
        private readonly string userSid;
        private readonly uint sessionId;
        private bool disposed;

        internal sealed class Identity
        {
            internal int ProcessId;
            internal string ImagePath;
            internal long CreationFileTime;
            internal string UserSid;
            internal uint SessionId;
            internal bool Running;
        }

        private enum Liveness { Gone, Running, Unknown }

        private sealed class Record : IDisposable
        {
            internal SafeFileHandle Handle;
            internal Identity Identity;
            internal Liveness Observe()
            {
                if (Handle == null || Handle.IsClosed || Handle.IsInvalid) return Liveness.Unknown;
                try
                {
                    uint state = NativeMethods.WaitForSingleObject(Handle, 0);
                    return state == 0 ? Liveness.Gone : state == 258 ? Liveness.Running : Liveness.Unknown;
                }
                catch { return Liveness.Unknown; }
            }
            public void Dispose() { if (Handle != null) { Handle.Dispose(); Handle = null; } }
        }

        internal ExternalDiscordScope(IEnumerable<string> approvedImagePaths, DateTime readyUtc)
            : this(approvedImagePaths, readyUtc, VerifyDiscordImage) { }

#if TEST_BUILD
        internal static ExternalDiscordScope CreateFixture(IEnumerable<string> approvedImagePaths, DateTime readyUtc,
            Func<string, IDisposable> verifier)
        { return new ExternalDiscordScope(approvedImagePaths, readyUtc, verifier); }
#endif

        private ExternalDiscordScope(IEnumerable<string> approvedImagePaths, DateTime readyUtc,
            Func<string, IDisposable> verifier)
        {
            if (approvedImagePaths == null || verifier == null) throw new ArgumentNullException();
            if (readyUtc.Kind != DateTimeKind.Utc) throw new ArgumentException("Scope readiness must be UTC.", "readyUtc");
            readyFileTime = readyUtc.ToFileTimeUtc();
            using (var identity = WindowsIdentity.GetCurrent())
            {
                if (identity.User == null) throw new InvalidOperationException("Current user identity unavailable.");
                userSid = identity.User.Value;
            }
            using (var current = Process.GetCurrentProcess())
                if (!ScopeNative.ProcessIdToSessionId((uint)current.Id, out sessionId))
                    throw new InvalidOperationException("Current Windows session unavailable.");
            try
            {
                int considered = 0;
                foreach (string path in approvedImagePaths)
                {
                    if (++considered > MaxImages) throw new InvalidDataException("Too many approved Discord images.");
                    string canonical = DiscordInstallation.CanonicalLocalPath(path);
                    if (images.Contains(canonical)) continue;
                    IDisposable lease = verifier(canonical);
                    if (lease == null) throw new InvalidDataException("Approved image lease unavailable.");
                    imageLeases.Add(lease); images.Add(canonical);
                }
                if (images.Count == 0) throw new InvalidDataException("No approved Discord image.");
            }
            catch { Dispose(); throw; }
        }

        private static IDisposable VerifyDiscordImage(string path)
        { return new TrustedImage(path, true); }

        // PID is a lookup key only. The retained kernel handle pins the actual
        // object and creation time, so an exited PID reused later is read anew.
        internal bool Permits(int pid)
        {
            if (pid < 1) return false;
            lock (sync)
            {
                if (disposed) return false;
                PruneGone();
                Record existing;
                if (admitted.TryGetValue(pid, out existing))
                {
                    ScopeNative.FileTime created, exited, kernel, user;
                    return existing.Observe() == Liveness.Running && ScopeNative.GetProcessId(existing.Handle) == (uint)pid &&
                        ScopeNative.GetProcessTimes(existing.Handle, out created, out exited, out kernel, out user) &&
                        PinnedIdentityAllowed(existing.Identity, pid, created.Value, true, images, readyFileTime, userSid, sessionId) &&
                        existing.Observe() == Liveness.Running;
                }
                if (admitted.Count >= MaxProcesses) return false;
                Record candidate = Observe(pid);
                if (candidate == null) return false;
                if (!IdentityAllowed(candidate.Identity, pid, images, readyFileTime, userSid, sessionId) ||
                    candidate.Observe() != Liveness.Running)
                { candidate.Dispose(); return false; }
                admitted.Add(pid, candidate);
                return true;
            }
        }

        // Only handles that already passed admission are considered. Never
        // enumerate all Discord processes or infer ownership of another client.
        internal bool AnyRunning
        {
            get
            {
                lock (sync)
                {
                    if (disposed) return false;
                    PruneGone();
                    // Unknown after prior admission blocks settings restoration.
                    return admitted.Count != 0;
                }
            }
        }

        private void PruneGone()
        {
            var gone = new List<int>();
            foreach (var pair in admitted) if (pair.Value.Observe() == Liveness.Gone) gone.Add(pair.Key);
            foreach (int pid in gone) { admitted[pid].Dispose(); admitted.Remove(pid); }
        }

        internal static bool IdentityAllowed(Identity identity, int requestedPid, ICollection<string> approvedImages,
            long readyTime, string expectedSid, uint expectedSession)
        {
            if (identity == null || !identity.Running || requestedPid < 1 || identity.ProcessId != requestedPid ||
                identity.CreationFileTime < readyTime || identity.CreationFileTime <= 0 ||
                String.IsNullOrEmpty(expectedSid) || !String.Equals(identity.UserSid, expectedSid, StringComparison.Ordinal) ||
                identity.SessionId != expectedSession || String.IsNullOrEmpty(identity.ImagePath) || approvedImages == null) return false;
            foreach (string image in approvedImages)
                if (String.Equals(identity.ImagePath, image, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        internal static bool PinnedIdentityAllowed(Identity retained, int requestedPid, long kernelCreationTime,
            bool kernelRunning, ICollection<string> approvedImages, long readyTime, string expectedSid, uint expectedSession)
        {
            return retained != null && kernelRunning && retained.CreationFileTime == kernelCreationTime &&
                IdentityAllowed(retained, requestedPid, approvedImages, readyTime, expectedSid, expectedSession);
        }

        private static Record Observe(int pid)
        {
            SafeFileHandle handle = null;
            try
            {
                handle = NativeMethods.OpenProcess(QueryAndSynchronize, false, (uint)pid);
                if (handle == null || handle.IsInvalid || NativeMethods.WaitForSingleObject(handle, 0) != 258 ||
                    ScopeNative.GetProcessId(handle) != (uint)pid) return null;
                var path = new StringBuilder(32768); uint length = (uint)path.Capacity;
                if (!NativeMethods.QueryFullProcessImageNameW(handle, 0, path, ref length) || length == 0 || length >= path.Capacity) return null;
                ScopeNative.FileTime created, exited, kernel, user;
                if (!ScopeNative.GetProcessTimes(handle, out created, out exited, out kernel, out user)) return null;
                long creation = created.Value;
                uint session;
                if (!ScopeNative.ProcessIdToSessionId((uint)pid, out session)) return null;
                string sid = ReadUserSid(handle);
                if (sid == null || NativeMethods.WaitForSingleObject(handle, 0) != 258) return null;
                var record = new Record { Handle = handle, Identity = new Identity { ProcessId = pid, ImagePath = path.ToString(),
                    CreationFileTime = creation, UserSid = sid, SessionId = session, Running = true } };
                handle = null;
                return record;
            }
            catch { return null; }
            finally { if (handle != null) handle.Dispose(); }
        }

        private static string ReadUserSid(SafeFileHandle process)
        {
            SafeFileHandle token;
            if (!ScopeNative.OpenProcessToken(process, 8, out token)) return null;
            using (token)
            {
                if (token == null || token.IsInvalid) return null;
                uint length;
                ScopeNative.GetTokenInformation(token, 1, IntPtr.Zero, 0, out length);
                if (length < IntPtr.Size + 4 || length > 65536) return null;
                IntPtr buffer = Marshal.AllocHGlobal((int)length);
                try
                {
                    uint returned;
                    if (!ScopeNative.GetTokenInformation(token, 1, buffer, length, out returned) ||
                        returned < IntPtr.Size + 4 || returned > length) return null;
                    IntPtr sid = Marshal.ReadIntPtr(buffer);
                    long start = buffer.ToInt64(), actual = sid.ToInt64();
                    if (actual < start || actual > start + returned - 8) return null;
                    return new SecurityIdentifier(sid).Value;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }

        public void Dispose()
        {
            lock (sync)
            {
                if (disposed) return;
                disposed = true;
                foreach (var record in admitted.Values) record.Dispose();
                admitted.Clear();
                foreach (var image in imageLeases) image.Dispose();
                imageLeases.Clear(); images.Clear();
            }
        }

        private static class ScopeNative
        {
            [StructLayout(LayoutKind.Sequential)]
            internal struct FileTime
            {
                internal uint Low, High;
                internal long Value { get { return unchecked((long)(((ulong)High << 32) | Low)); } }
            }
            [DllImport("kernel32.dll", SetLastError = true)]
            internal static extern uint GetProcessId(SafeFileHandle process);
            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool GetProcessTimes(SafeFileHandle process, out FileTime creation, out FileTime exit, out FileTime kernel, out FileTime user);
            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool ProcessIdToSessionId(uint pid, out uint session);
            [DllImport("advapi32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool OpenProcessToken(SafeFileHandle process, uint access, out SafeFileHandle token);
            [DllImport("advapi32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool GetTokenInformation(SafeFileHandle token, int informationClass, IntPtr information, uint length, out uint returned);
        }
    }
}
