using System;
using System.Diagnostics;
using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;

namespace DiscordAccess
{
    // These signals carry only intent bits, never paths, URLs or credentials.
    // They do not authorize proxy traffic; the existing job/PID checks do that.
    internal sealed class ManualLaunchSignal : IDisposable
    {
        private readonly object sync = new object();
        private EventWaitHandle signal;
        private ResidentInstance.NamespaceLease namespaceLease;
        private RegisteredWaitHandle registration;
        private Action open;
        private bool disposed;

        private const string OpenChannel = "OpenDiscord", StatusChannel = "ShowResident", StartupChannel = "StartupResident";

        private ManualLaunchSignal(string channel, string fixture, Action callback)
        {
            if (callback == null) throw new ArgumentNullException("callback");
            try
            {
#if TEST_BUILD
                namespaceLease = fixture == null ? ResidentInstance.AcquireNamespace() : ResidentInstance.NamespaceForChecks(fixture);
#else
                namespaceLease = ResidentInstance.AcquireNamespace();
#endif
                SecurityIdentifier user = namespaceLease.User;
                bool created;
                signal = new EventWaitHandle(false, EventResetMode.AutoReset, namespaceLease.ObjectName(channel), out created, Security(user));
                if (!created || !Owned(signal, user)) throw new InvalidOperationException("Discord açma dinleyicisi zaten var veya doğrulanamadı.");
                open = callback;
                registration = ThreadPool.RegisterWaitForSingleObject(signal, OnSignal, null, Timeout.Infinite, false);
            }
            catch { Dispose(); throw; }
        }

        private static EventWaitHandleSecurity Security(SecurityIdentifier user)
        {
            var security = new EventWaitHandleSecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(user);
            security.AddAccessRule(new EventWaitHandleAccessRule(user, EventWaitHandleRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new EventWaitHandleAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                EventWaitHandleRights.FullControl, AccessControlType.Allow));
            return security;
        }

        internal static IDisposable Listen(Action callback) { return new ManualLaunchSignal(OpenChannel, null, callback); }

        internal static bool RequestOpen(out string message) { return Request(OpenChannel, null, out message); }

        internal static IDisposable ListenStatus(Action callback)
        { return new ManualLaunchSignal(StatusChannel, null, callback); }

        internal static bool RequestStatus(out string message) { return Request(StatusChannel, null, out message); }

        internal static IDisposable ListenStartup(Action callback)
        { return new ManualLaunchSignal(StartupChannel, null, callback); }

        internal static bool RequestStartup(out string message)
        { return Request(StartupChannel, null, out message); }

#if TEST_BUILD
        internal static IDisposable ListenStartupFixture(string fixture, Action callback)
        { return ListenFixture(fixture, "startup", callback); }
        internal static bool RequestStartupFixture(string fixture, out string message)
        { return RequestFixture(fixture, "startup", out message); }
        internal static IDisposable ListenFixture(string fixture, string channel, Action callback)
        { RequireFixture(fixture); return new ManualLaunchSignal(FixtureChannel(channel), fixture, callback); }
        internal static bool RequestFixture(string fixture, string channel, out string message)
        { RequireFixture(fixture); return Request(FixtureChannel(channel), fixture, out message); }
        internal static string NameForChecks(string fixture, string channel)
        {
            RequireFixture(fixture);
            using (var identity = WindowsIdentity.GetCurrent())
            using (var process = Process.GetCurrentProcess())
                return ResidentInstance.NamespaceNameForChecks(identity.User, process.SessionId, fixture) + "\\" + FixtureChannel(channel);
        }
        private static string FixtureChannel(string channel)
        {
            if (channel == "open") return OpenChannel;
            if (channel == "status") return StatusChannel;
            if (channel == "startup") return StartupChannel;
            throw new ArgumentException("Resident signal channel");
        }
        private static void RequireFixture(string fixture)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident signal fixture identifier");
        }
#endif

        private static bool Request(string channel, string fixture, out string message)
        {
            message = "Açık bağlantı oturumu bulunamadı. Önce DiscordAccess.exe'yi açın.";
            try
            {
#if TEST_BUILD
                using (var lease = fixture == null ? ResidentInstance.OpenNamespace() : ResidentInstance.OpenNamespaceForChecks(fixture))
#else
                using (var lease = ResidentInstance.OpenNamespace())
#endif
                {
                    if (lease == null) return false;
                    using (var existing = EventWaitHandle.OpenExisting(lease.ObjectName(channel), EventWaitHandleRights.Modify | EventWaitHandleRights.ReadPermissions))
                    {
                        if (!Owned(existing, lease.User)) return false;
                        if (!existing.Set()) return false;
                        message = "Discord açma isteği bağlantı oturumuna iletildi.";
                        return true;
                    }
                }
            }
            catch (WaitHandleCannotBeOpenedException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (System.Security.SecurityException) { return false; }
            catch (System.IO.IOException) { return false; }
            catch (UserActionException) { return false; }
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
            ResidentInstance.NamespaceLease lease;
            lock (sync)
            {
                if (disposed) return;
                disposed = true; open = null;
                waiting = registration; registration = null;
                handle = signal; signal = null;
                lease = namespaceLease; namespaceLease = null;
            }
            // Callbacks already queued must pass the disposed check under sync.
            // Unregister never waits for a network operation or the controller.
            try { if (waiting != null) waiting.Unregister(null); }
            finally
            {
                try { if (handle != null) handle.Dispose(); }
                finally { if (lease != null) lease.Dispose(); }
            }
        }

#if TEST_BUILD
        // Legacy public names exist only in these adversarial fixtures. No
        // production listener or request falls back to a public event name.
        private static string LegacyNameForChecks(string fixture, string channel, SecurityIdentifier user)
        {
            RequireFixture(fixture); FixtureChannel(channel);
            string leaf = channel == "open" ? "OpenDiscord.V416." :
                channel == "status" ? "ShowResident.V417." : "StartupResident.V417.";
            using (var process = Process.GetCurrentProcess())
                return @"Local\DiscordAccess." + leaf + user.Value + "." +
                    process.SessionId.ToString(CultureInfo.InvariantCulture) + ".Test." + fixture;
        }

        internal static int RunOfflineChecks()
        {
            int checks = 0;
            Action<bool, string> require = (ok, message) => {
                if (!ok) throw new InvalidOperationException("Resident signal fixture: " + message);
                checks++;
            };
            SecurityIdentifier user;
            using (var identity = WindowsIdentity.GetCurrent()) user = identity.User;
            var world = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
            string response;
            foreach (string channel in new[] { "open", "status", "startup" })
            {
                string fixture = Guid.NewGuid().ToString("N");
                bool created;
                var weak = Security(user);
                weak.AddAccessRule(new EventWaitHandleAccessRule(world, EventWaitHandleRights.Modify, AccessControlType.Allow));
                // Squat the old public name before any private listener exists.
                using (var publicSquat = new EventWaitHandle(false, EventResetMode.AutoReset,
                    LegacyNameForChecks(fixture, channel, user), out created, weak))
                {
                    require(created && !RequestFixture(fixture, channel, out response) && !publicSquat.WaitOne(0),
                        channel + " request reached a legacy public event");
                    using (var absent = ResidentInstance.OpenNamespaceForChecks(fixture))
                        require(absent == null && ResidentInstance.NamespaceReferencesForChecks(fixture) == 0,
                            channel + " absent request created a namespace");
                    using (var primary = ResidentInstance.AcquireForChecks(fixture))
                    using (var received = new AutoResetEvent(false))
                    {
                        int count = 0;
                        var listener = ListenFixture(fixture, channel, () => { Interlocked.Increment(ref count); received.Set(); });
                        try
                        {
                            require(primary.IsPrimary && ResidentInstance.NamespaceReferencesForChecks(fixture) == 2,
                                channel + " listener did not share the primary alias");
                            publicSquat.Set();
                            require(!received.WaitOne(100) && Volatile.Read(ref count) == 0 && publicSquat.WaitOne(0),
                                channel + " public squatting affected private delivery");
                            require(RequestFixture(fixture, channel, out response) && received.WaitOne(2000) && Volatile.Read(ref count) == 1,
                                channel + " same-user private event did not deliver");
                            require(ResidentInstanceChecks.RunSignalChildForChecks(fixture, channel) == "sent" &&
                                received.WaitOne(2000) && Volatile.Read(ref count) == 2,
                                channel + " request-only child could not open the existing namespace");
                            require(ResidentInstanceChecks.RunSignalChildForChecks(fixture, channel) == "sent" &&
                                received.WaitOne(2000) && Volatile.Read(ref count) == 3,
                                channel + " request-only child disposal destroyed the primary namespace");
                            require(ResidentInstanceChecks.RunNamespaceChildForChecks(fixture) == "secondary" && primary.IsPrimary &&
                                ResidentInstance.NamespaceReferencesForChecks(fixture) == 2,
                                channel + " request-only alias closing changed primary ownership/refcounts");
                            bool rejected = false;
                            try { using (ListenFixture(fixture, channel, () => { })) { } }
                            catch (InvalidOperationException) { rejected = true; }
                            require(rejected && ResidentInstance.NamespaceReferencesForChecks(fixture) == 2,
                                channel + " duplicate listener was accepted or leaked an alias");
                            using (var held = EventWaitHandle.OpenExisting(NameForChecks(fixture, channel),
                                EventWaitHandleRights.Modify | EventWaitHandleRights.Synchronize | EventWaitHandleRights.ReadPermissions))
                            {
                                require(Owned(held, user) && !Owned(held, world), channel + " event ownership validation failed");
                                listener.Dispose(); listener.Dispose();
                                held.Set();
                                require(!received.WaitOne(100) && Volatile.Read(ref count) == 3 &&
                                    ResidentInstance.NamespaceReferencesForChecks(fixture) == 1,
                                    channel + " disposed listener delivered or closed the primary alias");
                            }
                            // Unregister(null) returns before queued native wait
                            // cleanup; the fixture allows that handle to close.
                            require(SpinWait.SpinUntil(() => !RequestFixture(fixture, channel, out response), 2000),
                                channel + " disposed listener event remained available");
                        }
                        finally { listener.Dispose(); }
                    }
                }
                require(ResidentInstance.NamespaceReferencesForChecks(fixture) == 0, channel + " final alias lease was retained");

                // An existing event created by this user with the expected ACL
                // can receive intent without creating/acquiring an Owner mutex.
                fixture = Guid.NewGuid().ToString("N");
                using (var lease = ResidentInstance.NamespaceForChecks(fixture))
                using (var legitimate = new EventWaitHandle(false, EventResetMode.AutoReset,
                    NameForChecks(fixture, channel), out created, Security(user)))
                {
                    require(created && RequestFixture(fixture, channel, out response) && legitimate.WaitOne(0),
                        channel + " same-user existing legitimate event was rejected");
                    require(ResidentInstanceChecks.RunSignalChildForChecks(fixture, channel, true) == "sent" && legitimate.WaitOne(0),
                        channel + " request-only child acquired/created a resident mutex");
                    require(RequestFixture(fixture, channel, out response) && legitimate.WaitOne(0) &&
                        ResidentInstance.NamespaceReferencesForChecks(fixture) == 1,
                        channel + " request-only close invalidated a retained namespace");
                }

                fixture = Guid.NewGuid().ToString("N");
                using (var lease = ResidentInstance.NamespaceForChecks(fixture))
                using (var untrusted = new EventWaitHandle(false, EventResetMode.AutoReset,
                    NameForChecks(fixture, channel), out created, weak))
                    require(created && !RequestFixture(fixture, channel, out response) && !untrusted.WaitOne(0) && !Owned(untrusted, user),
                        channel + " untrusted private event was signaled or its ACL rewritten");

                fixture = Guid.NewGuid().ToString("N");
                using (var lease = ResidentInstance.NamespaceForChecks(fixture))
                using (var incompatible = new Mutex(false, NameForChecks(fixture, channel), out created, ResidentInstance.SecurityForChecks(user)))
                    require(created && !RequestFixture(fixture, channel, out response), channel + " different object type was signaled");
            }
            return checks;
        }
#endif
    }
}
