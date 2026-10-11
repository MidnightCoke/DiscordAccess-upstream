using System;
using System.Diagnostics;
using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;

namespace DiscordAccess
{
    // This signal carries only an open request, never a path, URL or credential.
    // It does not authorize any proxy traffic; the existing job/PID checks do that.
    internal sealed class ManualLaunchSignal : IDisposable
    {
        private readonly object sync = new object();
        private EventWaitHandle signal;
        private RegisteredWaitHandle registration;
        private Action open;
        private bool disposed;

        private ManualLaunchSignal(string name, Action callback)
        {
            if (callback == null) throw new ArgumentNullException("callback");
            SecurityIdentifier user = CurrentUser();
            var security = new EventWaitHandleSecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(user);
            security.AddAccessRule(new EventWaitHandleAccessRule(user, EventWaitHandleRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new EventWaitHandleAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                EventWaitHandleRights.FullControl, AccessControlType.Allow));
            bool created;
            signal = new EventWaitHandle(false, EventResetMode.AutoReset, name, out created, security);
            try
            {
                if (!created || !Owned(signal, user)) throw new InvalidOperationException("Discord açma dinleyicisi zaten var veya doğrulanamadı.");
                open = callback;
                registration = ThreadPool.RegisterWaitForSingleObject(signal, OnSignal, null, Timeout.Infinite, false);
            }
            catch { signal.Dispose(); signal = null; throw; }
        }

        internal static IDisposable Listen(Action callback) { return new ManualLaunchSignal(Name(null), callback); }

        internal static bool RequestOpen(out string message) { return Request(Name(null), out message); }

        internal static IDisposable ListenStatus(Action callback)
        { return new ManualLaunchSignal(StatusName(), callback); }

        internal static bool RequestStatus(out string message) { return Request(StatusName(), out message); }

        private static string StatusName()
        { return Name(null).Replace("OpenDiscord.V416.", "ShowResident.V417."); }

        internal static IDisposable ListenStartup(Action callback)
        { return new ManualLaunchSignal(StartupName(null), callback); }

        internal static bool RequestStartup(out string message)
        { return Request(StartupName(null), out message); }

        private static string StartupName(string fixture)
        { return Name(fixture).Replace("OpenDiscord.V416.", "StartupResident.V417."); }

#if TEST_BUILD
        internal static IDisposable ListenStartupFixture(string fixture, Action callback)
        { RequireFixture(fixture); return new ManualLaunchSignal(StartupName(fixture), callback); }
        internal static bool RequestStartupFixture(string fixture, out string message)
        { RequireFixture(fixture); return Request(StartupName(fixture), out message); }
        private static void RequireFixture(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Startup fixture identifier");
        }
#endif

        private static bool Request(string name, out string message)
        {
            message = "Açık bağlantı oturumu bulunamadı. Önce DiscordAccess.exe'yi açın.";
            try
            {
                using (var existing = EventWaitHandle.OpenExisting(name, EventWaitHandleRights.Modify | EventWaitHandleRights.ReadPermissions))
                {
                    if (!Owned(existing, CurrentUser())) return false;
                    if (!existing.Set()) return false;
                    message = "Discord açma isteği bağlantı oturumuna iletildi.";
                    return true;
                }
            }
            catch (WaitHandleCannotBeOpenedException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (System.Security.SecurityException) { return false; }
            catch (System.IO.IOException) { return false; }
        }

        private static SecurityIdentifier CurrentUser()
        {
            using (var identity = WindowsIdentity.GetCurrent())
            {
                if (identity.User == null) throw new InvalidOperationException("Windows kullanıcı kimliği alınamadı.");
                return identity.User;
            }
        }

        private static string Name(string fixture)
        {
            using (var process = Process.GetCurrentProcess())
                return @"Local\DiscordAccess.OpenDiscord.V416." + CurrentUser().Value + "." +
                    process.SessionId.ToString(CultureInfo.InvariantCulture) + (fixture == null ? "" : ".Test." + fixture);
        }

        private static bool Owned(EventWaitHandle handle, SecurityIdentifier user)
        {
            var security = handle.GetAccessControl();
            if (!security.AreAccessRulesProtected || !user.Equals(security.GetOwner(typeof(SecurityIdentifier)))) return false;
            bool userAccess = false;
            foreach (EventWaitHandleAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Allow) return false;
                string sid = rule.IdentityReference.Value;
                if (sid != user.Value && sid != "S-1-5-18") return false;
                if (sid == user.Value && (rule.EventWaitHandleRights & EventWaitHandleRights.FullControl) == EventWaitHandleRights.FullControl)
                    userAccess = true;
            }
            return userAccess;
        }

        private void OnSignal(object state, bool timedOut)
        {
            lock (sync)
            {
                if (disposed || timedOut) return;
                // The host callback only enqueues A; it never launches or waits.
                try { open(); } catch { }
            }
        }

        public void Dispose()
        {
            RegisteredWaitHandle waiting;
            EventWaitHandle handle;
            lock (sync)
            {
                if (disposed) return;
                disposed = true; open = null;
                waiting = registration; registration = null;
                handle = signal; signal = null;
            }
            // Callbacks already queued must pass the disposed check under sync.
            // Unregister never waits for a network operation or the controller.
            if (waiting != null) waiting.Unregister(null);
            if (handle != null) handle.Dispose();
        }

        internal static int RunOfflineChecks()
        {
            int checks = 0;
            Action<bool> require = ok => { if (!ok) throw new InvalidOperationException("Manual launch signal fixture failed at check " + checks.ToString(CultureInfo.InvariantCulture) + "."); };
            string name = Name(Guid.NewGuid().ToString("N"));
            string message;
            require(!Request(name, out message)); checks++;
            using (var received = new AutoResetEvent(false))
            {
                int count = 0;
                var listener = new ManualLaunchSignal(name, () => { Interlocked.Increment(ref count); received.Set(); });
                try
                {
                    require(Request(name, out message)); checks++;
                    require(received.WaitOne(2000) && Volatile.Read(ref count) == 1); checks++;
                    bool rejected = false;
                    try { using (new ManualLaunchSignal(name, () => { })) { } }
                    catch (InvalidOperationException) { rejected = true; }
                    require(rejected); checks++;
                    require(Request(name, out message) && received.WaitOne(2000) && Volatile.Read(ref count) == 2); checks++;
                    using (var held = EventWaitHandle.OpenExisting(name,
                        EventWaitHandleRights.Modify | EventWaitHandleRights.Synchronize | EventWaitHandleRights.ReadPermissions))
                    {
                        require(Owned(held, CurrentUser())); checks++;
                        require(!Owned(held, new SecurityIdentifier(WellKnownSidType.WorldSid, null))); checks++;
                        listener.Dispose(); listener.Dispose();
                        held.Set();
                        require(!received.WaitOne(100) && Volatile.Read(ref count) == 2); checks++;
                    }
                }
                finally { listener.Dispose(); }
            }
            // A pre-existing event allowing another principal is never signaled.
            string foreignName = Name(Guid.NewGuid().ToString("N"));
            var weak = new EventWaitHandleSecurity();
            weak.SetAccessRuleProtection(true, false);
            weak.SetOwner(CurrentUser());
            weak.AddAccessRule(new EventWaitHandleAccessRule(CurrentUser(), EventWaitHandleRights.FullControl, AccessControlType.Allow));
            weak.AddAccessRule(new EventWaitHandleAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
                EventWaitHandleRights.Modify, AccessControlType.Allow));
            bool created;
            using (var foreign = new EventWaitHandle(false, EventResetMode.AutoReset, foreignName, out created, weak))
            {
                require(created && !Request(foreignName, out message) && !foreign.WaitOne(0)); checks++;
            }
            return checks;
        }
    }
}
