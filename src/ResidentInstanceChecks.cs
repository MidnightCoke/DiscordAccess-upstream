#if TEST_BUILD
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Text;

namespace DiscordAccess
{
    // Kernel objects and private namespaces use fresh GUID fixture names only.
    // These checks never acquire the production resident name or change ACLs
    // outside fresh fixture files, namespaces and kernel objects.
    internal static class ResidentInstanceChecks
    {
        private static string Fixture() { return Guid.NewGuid().ToString("N"); }
        private static string Name(string fixture, SecurityIdentifier user)
        {
            using (var process = Process.GetCurrentProcess())
                return ResidentInstance.NameForChecks(user, process.SessionId, fixture);
        }

        internal static int Run()
        {
            int checks = 0;
            Action<bool, string> assert = (ok, message) => { checks++; if (!ok) throw new InvalidOperationException("Resident instance: " + message); };
            Action<Action, string> reject = (action, message) =>
            {
                bool refused = false; try { action(); } catch (UserActionException) { refused = true; } catch (ArgumentException) { refused = true; }
                assert(refused, message);
            };
            SecurityIdentifier user;
            using (var identity = WindowsIdentity.GetCurrent()) user = identity.User;
            assert(user != null, "Windows fixture user was unavailable.");
            CheckReleaseFrames(assert);
            var world = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
            var foreign = new SecurityIdentifier("S-1-5-21-111111111-222222222-333333333-1002");
            var security = ResidentInstance.SecurityForChecks(user);
            assert(ResidentInstance.TrustedForChecks(security, user), "New private descriptor was not trusted.");
            assert(!ResidentInstance.TrustedForChecks(security, foreign), "Descriptor was accepted for another user.");
            assert(!ResidentInstance.TrustedForChecks(null, user), "Missing descriptor was trusted.");
            var changed = ResidentInstance.SecurityForChecks(user); changed.SetOwner(foreign);
            assert(!ResidentInstance.TrustedForChecks(changed, user), "Foreign owner was trusted.");
            changed = ResidentInstance.SecurityForChecks(user); changed.SetAccessRuleProtection(false, true);
            assert(!ResidentInstance.TrustedForChecks(changed, user), "Unprotected descriptor was trusted.");
            changed = new MutexSecurity(); changed.SetOwner(user); changed.SetAccessRuleProtection(true, false);
            changed.AddAccessRule(new MutexAccessRule(user, MutexRights.FullControl, AccessControlType.Allow));
            assert(!ResidentInstance.TrustedForChecks(changed, user), "Missing SYSTEM access was trusted.");
            foreach (MutexRights rights in new[] { MutexRights.ReadPermissions, MutexRights.Modify, MutexRights.FullControl })
            {
                changed = ResidentInstance.SecurityForChecks(user);
                changed.AddAccessRule(new MutexAccessRule(world, rights, AccessControlType.Allow));
                assert(!ResidentInstance.TrustedForChecks(changed, user), "Additional untrusted access was accepted.");
            }
            changed = ResidentInstance.SecurityForChecks(user);
            changed.AddAccessRule(new MutexAccessRule(world, MutexRights.Modify, AccessControlType.Deny));
            assert(!ResidentInstance.TrustedForChecks(changed, user), "Foreign deny descriptor was accepted as our exact descriptor.");
            changed = ResidentInstance.SecurityForChecks(user);
            var nullDacl = new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclProtected,
                user, null, null, null);
            var nullBytes = new byte[nullDacl.BinaryLength]; nullDacl.GetBinaryForm(nullBytes, 0);
            changed.SetSecurityDescriptorBinaryForm(nullBytes);
            assert(!ResidentInstance.TrustedForChecks(changed, user), "Null DACL was trusted.");

            string fixture = Fixture();
            string currentName = Name(fixture, user);
            assert(currentName.StartsWith("DiscordAccess.Resident.V2." + user.Value + ".", StringComparison.Ordinal) &&
                currentName.EndsWith(".Test." + fixture + "\\Owner", StringComparison.Ordinal), "Fixture name lost its private user/session boundary.");
            assert(ResidentInstance.NameForChecks(user, 1, fixture) != ResidentInstance.NameForChecks(user, 2, fixture), "Sessions share a resident name.");
            assert(ResidentInstance.NameForChecks(user, 1, fixture) != ResidentInstance.NameForChecks(foreign, 1, fixture), "Users share a resident name.");
            reject(() => { using (ResidentInstance.AcquireForChecks(null)) { } }, "Null fixture could address the production mutex.");
            reject(() => { using (ResidentInstance.AcquireForChecks("invalid")) { } }, "Unvalidated fixture could address another object.");
            reject(() => { using (ResidentInstance.NamespaceForChecks(null)) { } }, "Null fixture could address the production namespace.");
            reject(() => { using (ResidentInstance.NamespaceForChecks("invalid")) { } }, "Unvalidated fixture could address another namespace.");
            reject(() => { using (ResidentInstance.OpenNamespaceForChecks(null)) { } }, "Null request fixture could address the production namespace.");
            reject(() => { using (ResidentInstance.OpenNamespaceForChecks("invalid")) { } }, "Unvalidated request fixture could address another namespace.");
            assert(ResidentInstance.ForeignBoundaryErrorForChecks(Fixture(), foreign) == 5,
                "A caller outside the required user SID boundary created a namespace.");

            fixture = Fixture();
            using (var stateOwner = ResidentStateLease.TryAcquireForChecks(fixture))
            {
                assert(stateOwner != null, "Fresh authoritative fixture lease was not acquired.");
                using (var busy = ResidentInstance.AcquireForChecks(fixture))
                    assert(!busy.IsPrimary && !busy.CreatedNew && ResidentInstance.NamespaceReferencesForChecks(fixture) == 0,
                        "A busy authoritative lease created a private namespace or Owner.");
                assert(RunChild(fixture, context: "busy-state-without-namespace") == "secondary", "A child bypassed the authoritative lease without a namespace.");
            }
            using (var nextStateOwner = ResidentInstance.AcquireForChecks(fixture))
                assert(nextStateOwner.IsPrimary, "Releasing the authoritative fixture lease prevented a successor.");

            // Only a fresh fixture file is changed, never a production state
            // file. Untrusted ACLs must fail even when no owner holds the file.
            fixture = Fixture();
            using (var trustedState = ResidentStateLease.TryAcquireForChecks(fixture))
                assert(trustedState != null, "State ACL fixture was not prepared.");
            string fixtureState = ResidentStateLease.PathForChecks(fixture);
            var stateSecurity = File.GetAccessControl(fixtureState);
            stateSecurity.AddAccessRule(new FileSystemAccessRule(world, FileSystemRights.ReadData, AccessControlType.Allow));
            File.SetAccessControl(fixtureState, stateSecurity);
            reject(() => { using (ResidentInstance.AcquireForChecks(fixture)) { } }, "An untrusted state lease was treated as busy or accepted.");
            bool worldRetained = false;
            foreach (FileSystemAccessRule rule in File.GetAccessControl(fixtureState).GetAccessRules(true, true, typeof(SecurityIdentifier)))
                if (rule.IdentityReference.Value == world.Value && rule.AccessControlType == AccessControlType.Allow) worldRetained = true;
            assert(worldRetained && ResidentInstance.NamespaceReferencesForChecks(fixture) == 0,
                "Rejected state ACL was rewritten or a namespace was created.");
            CheckPublicationRecords(user, assert);

            fixture = Fixture();
            using (var missing = ResidentInstance.OpenNamespaceForChecks(fixture))
                assert(missing == null && ResidentInstance.NamespaceReferencesForChecks(fixture) == 0,
                    "A request-only lease created an absent namespace.");
            using (var retainedAlias = ResidentInstance.NamespaceForChecks(fixture))
            {
                assert(ResidentInstance.NamespaceReferencesForChecks(fixture) == 1, "A retained alias has an incorrect reference count.");
                reject(() => retainedAlias.ObjectName(@"Local\foreign"), "An object leaf escaped its private alias.");
                var requestAlias = ResidentInstance.OpenNamespaceForChecks(fixture);
                assert(requestAlias != null && ResidentInstance.NamespaceReferencesForChecks(fixture) == 2 &&
                    requestAlias.ObjectName("Owner") == Name(fixture, user), "A request alias did not share the existing registration.");
                requestAlias.Dispose(); requestAlias.Dispose();
                assert(ResidentInstance.NamespaceReferencesForChecks(fixture) == 1, "Request alias disposal closed or leaked the retained registration.");
                using (var primary = ResidentInstance.AcquireForChecks(fixture))
                {
                    using (var request = ResidentInstance.OpenNamespaceForChecks(fixture))
                        assert(request != null && primary.IsPrimary && ResidentInstance.NamespaceReferencesForChecks(fixture) == 3,
                            "Request namespace leasing affected main-thread mutex ownership.");
                    assert(primary.IsPrimary && ResidentInstance.NamespaceReferencesForChecks(fixture) == 2,
                        "Request alias closing affected the live primary lease.");
                }
                assert(ResidentInstance.NamespaceReferencesForChecks(fixture) == 1, "Primary disposal closed a retained request namespace.");
            }
            assert(ResidentInstance.NamespaceReferencesForChecks(fixture) == 0, "Final request namespace lease was not removed.");

            // Ordinary-session object squatting cannot reserve the process-local
            // alias of a private namespace with the same visible prefix.
            fixture = Fixture(); string prefix;
            using (var process = Process.GetCurrentProcess())
                prefix = ResidentInstance.NamespaceNameForChecks(user, process.SessionId, fixture);
            bool publicCreated;
            using (var publicSquat = new Mutex(false, @"Local\" + prefix, out publicCreated, security))
            {
                assert(publicCreated, "Fresh public-prefix fixture collided.");
                using (var isolated = ResidentInstance.AcquireForChecks(fixture))
                    assert(isolated.CreatedNew && isolated.IsPrimary, "An ordinary named object reserved a private namespace alias.");
            }
            using (var firstIsolated = ResidentInstance.AcquireForChecks(Fixture()))
            using (var secondIsolated = ResidentInstance.AcquireForChecks(Fixture()))
                assert(firstIsolated.IsPrimary && secondIsolated.IsPrimary, "Different private boundaries share a mutex.");

            // A separate process must open the existing namespace, not create a
            // parallel mutex. Closing that secondary alias must leave our owner
            // and namespace intact. Only this already compiled fixture runner
            // is started; the child validates the fresh GUID before acquisition.
            fixture = Fixture();
            using (ResidentInstance.NamespaceForChecks(fixture))
            {
                using (var crossProcessPrimary = ResidentInstance.AcquireForChecks(fixture))
                {
                    assert(RunChild(fixture, context: "retained-alias-live-owner") == "secondary", "Another process created a second primary namespace/mutex.");
                    assert(crossProcessPrimary.IsPrimary, "Child disposal removed our ownership.");
                    assert(RunChild(fixture, context: "retained-alias-live-owner-repeat") == "secondary", "Secondary disposal destroyed the shared namespace.");
                }
                assert(RunChild(fixture, context: "retained-creator-child-takeover") == "primary", "A child could not acquire after primary disposal.");
                using (var afterChild = ResidentInstance.AcquireForChecks(fixture))
                    assert(afterChild.IsPrimary, "Child shutdown prevented an acquisition through the retained alias.");
            }

            // The original namespace creator may close after another process
            // has taken ownership. Its close must not split that live owner
            // from later processes that create/open the same SID boundary.
            string handoverFixture = Fixture();
            for (int takeover = 0; takeover < 3; takeover++) CheckCreatorHandover(handoverFixture, assert);
            CheckRetainedStaticOpener(Fixture(), assert);

            fixture = Fixture();
            using (var primary = ResidentInstance.AcquireForChecks(fixture))
            {
                assert(primary.CreatedNew && primary.IsPrimary, "First fixture did not acquire ownership.");
                bool duplicatePrimary = true, duplicateCreated = true; Exception failed = null;
                var duplicate = new Thread(() =>
                {
                    try
                    {
                        using (var second = ResidentInstance.AcquireForChecks(fixture))
                        { duplicatePrimary = second.IsPrimary; duplicateCreated = second.CreatedNew; }
                    }
                    catch (Exception error) { failed = error; }
                });
                duplicate.IsBackground = true; duplicate.Start();
                assert(duplicate.Join(5000) && failed == null && !duplicatePrimary && !duplicateCreated,
                    "Another thread started a duplicate or failed trusted existing-object validation.");
                assert(primary.IsPrimary, "Secondary disposal changed primary ownership.");
                primary.Dispose(); primary.Dispose();
                assert(!primary.IsPrimary, "Disposed instance retained primary state.");
            }
            using (var next = ResidentInstance.AcquireForChecks(fixture))
                assert(next.IsPrimary, "Disposed primary prevented a later connection.");

            fixture = Fixture(); bool created;
            using (ResidentInstance.NamespaceForChecks(fixture))
            using (var unowned = new Mutex(false, Name(fixture, user), out created, ResidentInstance.SecurityForChecks(user)))
            {
                assert(created, "Unowned fixture collided with another object.");
                using (var reclaimed = ResidentInstance.AcquireForChecks(fixture))
                    assert(!reclaimed.CreatedNew && reclaimed.IsPrimary, "Existing unowned mutex was mistaken for a running instance.");
                using (var reclaimedAgain = ResidentInstance.AcquireForChecks(fixture))
                    assert(!reclaimedAgain.CreatedNew && reclaimedAgain.IsPrimary, "Acquired existing mutex was not released on disposal.");
            }

            fixture = Fixture(); Mutex abandoned = null; Exception abandonError = null; bool abandonCreated = false;
            string abandonedName = Name(fixture, user);
            var abandonThread = new Thread(() =>
            {
                try { abandoned = new Mutex(true, abandonedName, out abandonCreated, ResidentInstance.SecurityForChecks(user)); }
                catch (Exception error) { abandonError = error; }
                // The thread exits while owning the fixture; retained handle
                // keeps the kernel object present for abandoned-owner recovery.
            });
            abandonThread.IsBackground = true;
            using (ResidentInstance.NamespaceForChecks(fixture))
            {
                abandonThread.Start();
                try
                {
                    assert(abandonThread.Join(5000) && abandonError == null && abandonCreated && abandoned != null,
                        "Abandoned mutex fixture was not prepared.");
                    using (var recovered = ResidentInstance.AcquireForChecks(fixture))
                        assert(!recovered.CreatedNew && recovered.IsPrimary, "Abandoned trusted mutex prevented recovery.");
                    using (var recoveredAgain = ResidentInstance.AcquireForChecks(fixture))
                        assert(recoveredAgain.IsPrimary, "Abandoned recovery did not release its acquired ownership.");
                }
                finally { if (abandoned != null) abandoned.Dispose(); }
            }

            fixture = Fixture(); changed = ResidentInstance.SecurityForChecks(user);
            changed.AddAccessRule(new MutexAccessRule(world, MutexRights.Modify, AccessControlType.Allow));
            using (ResidentInstance.NamespaceForChecks(fixture))
            using (var weak = new Mutex(false, Name(fixture, user), out created, changed))
            {
                assert(created, "Untrusted fixture collided with another object.");
                reject(() => { using (ResidentInstance.AcquireForChecks(fixture)) { } }, "Existing weak mutex was trusted or overwritten.");
                assert(!ResidentInstance.TrustedForChecks(weak.GetAccessControl(), user), "Rejected existing mutex ACL was rewritten.");
            }
            fixture = Fixture();
            var eventSecurity = new EventWaitHandleSecurity(); eventSecurity.SetOwner(user); eventSecurity.SetAccessRuleProtection(true, false);
            eventSecurity.AddAccessRule(new EventWaitHandleAccessRule(user, EventWaitHandleRights.FullControl, AccessControlType.Allow));
            using (ResidentInstance.NamespaceForChecks(fixture))
            using (var incompatible = new EventWaitHandle(false, EventResetMode.AutoReset, Name(fixture, user), out created, eventSecurity))
            {
                assert(created, "Incompatible fixture collided with another object.");
                reject(() => { using (ResidentInstance.AcquireForChecks(fixture)) { } }, "Existing different kernel-object type was accepted.");
                assert(!incompatible.WaitOne(0), "Rejected different object was signaled.");
            }
            // Retaining a namespace alias while an instance is disposed must
            // preserve the namespace and allow a later clean mutex acquisition.
            fixture = Fixture();
            using (var retained = ResidentInstance.NamespaceForChecks(fixture))
            {
                using (var disposed = ResidentInstance.AcquireForChecks(fixture)) assert(disposed.IsPrimary, "Retained namespace could not acquire.");
                using (var successor = ResidentInstance.AcquireForChecks(fixture)) assert(successor.IsPrimary, "Instance disposal destroyed a retained namespace.");
            }
            using (var recreated = ResidentInstance.AcquireForChecks(fixture))
                assert(recreated.IsPrimary, "Closing the final namespace lease prevented a later acquisition.");
            return checks;
        }

        internal static int RunNamespaceChild(string fixture)
        {
            // Exact GUID validation also resides in AcquireForChecks, so this
            // dispatch cannot address a production namespace or named object.
            try
            {
                using (var instance = ResidentInstance.AcquireForChecks(fixture))
                    Console.WriteLine(instance.IsPrimary ? "primary" : "secondary");
                return 0;
            }
            catch (Exception error)
            { Console.Error.WriteLine("Namespace fixture failed: " + error.GetType().Name + "; " + ResidentInstance.FailureForChecks()); return 1; }
        }

        internal static int RunSignalChild(string fixture, string channel, bool requireNoOwner)
        {
            try
            {
                string response;
                bool sent = ManualLaunchSignal.RequestFixture(fixture, channel, out response);
                if (ResidentInstance.NamespaceReferencesForChecks(fixture) != 0)
                    throw new InvalidOperationException("Request-only fixture retained its alias registration.");
                if (requireNoOwner)
                {
                    using (var alias = ResidentInstance.OpenNamespaceForChecks(fixture))
                    {
                        if (alias == null) throw new InvalidOperationException("Request-only fixture destroyed the existing namespace.");
                        bool ownerPresent = false;
                        try { using (Mutex.OpenExisting(alias.ObjectName("Owner"))) ownerPresent = true; }
                        catch (WaitHandleCannotBeOpenedException) { }
                        if (ownerPresent) throw new InvalidOperationException("Request-only fixture created a resident mutex.");
                    }
                }
                Console.WriteLine(sent ? "sent" : "missing");
                return 0;
            }
            catch (Exception error)
            { Console.Error.WriteLine("Signal fixture failed: " + error.GetType().Name); return 1; }
        }

        internal static int RunHoldingNamespaceChild(string fixture)
        {
            try
            {
                using (var instance = ResidentInstance.AcquireForChecks(fixture))
                {
                    if (!instance.IsPrimary) throw new InvalidOperationException("Holding fixture was not primary.");
                    using (var status = ManualLaunchSignal.ListenFixture(fixture, "status", () => {
                        Console.WriteLine("status"); Console.Out.Flush(); }))
                    {
                        Console.WriteLine(instance.IsPrimary ? "primary" : "secondary");
                        Console.Out.Flush();
                        // Use an exact byte frame rather than Console/StreamWriter
                        // encodings, which can add a BOM on redirected Windows IO.
                        ReadReleaseFrame(Console.OpenStandardInput());
                        return 0;
                    }
                }
            }
            catch (Exception error)
            { Console.Error.WriteLine("Holding namespace fixture failed: " + error.GetType().Name + "; " + frameFailure + "; " + ResidentInstance.FailureForChecks()); return 1; }
        }

        internal static int RunHoldingStaticNamespaceChild(string fixture)
        {
            try
            {
                using (var lease = ResidentInstance.OpenStaticNamespaceForChecks(fixture))
                {
                    if (lease == null) throw new InvalidOperationException("Static fixture namespace was absent.");
                    Console.WriteLine("opened"); Console.Out.Flush();
                    ReadReleaseFrame(Console.OpenStandardInput());
                    return 0;
                }
            }
            catch (Exception error)
            { Console.Error.WriteLine("Static namespace fixture failed: " + error.GetType().Name + "; " + frameFailure + "; " + ResidentInstance.FailureForChecks()); return 1; }
        }

        [ThreadStatic] private static string frameFailure;
        private static void CheckReleaseFrames(Action<bool, string> assert)
        {
            foreach (byte[] bytes in new[] { Encoding.ASCII.GetBytes("release\n"),
                new byte[] { 0xef, 0xbb, 0xbf, 0x72, 0x65, 0x6c, 0x65, 0x61, 0x73, 0x65, 0x0a } })
            {
                using (var input = new MemoryStream(bytes)) ReadReleaseFrame(input);
                assert(true, "Exact control frame or .NET UTF8 preamble was rejected.");
            }
            foreach (byte[] bytes in new[] { new byte[0], Encoding.ASCII.GetBytes("release"), Encoding.ASCII.GetBytes("stop\n"),
                new byte[] { 0xef, 0xbb }, new byte[] { 0xef, 0xbb, 0x00 }, new byte[] { 0xff, 0xfe, 0x72, 0x00 },
                new byte[] { 0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf, 0x72 } })
            {
                bool rejected = false;
                try { using (var input = new MemoryStream(bytes)) ReadReleaseFrame(input); }
                catch (InvalidOperationException) { rejected = true; }
                assert(rejected, "An invalid, truncated, repeated-BOM or alternate-encoding control frame was accepted.");
            }
        }
        private static void ReadReleaseFrame(Stream input)
        {
            // .NET Framework's Process.StandardInput StreamWriter can emit its
            // UTF-8 preamble when Start enables AutoFlush, before our parent
            // ever writes the raw release frame. Accept only that exact optional
            // preamble, then block for the same eight-byte ASCII control frame.
            frameFailure = null;
            byte[] expected = Encoding.ASCII.GetBytes("release\n");
            int first = input.ReadByte();
            if (first == 0xef)
            {
                CheckFrameByte(input.ReadByte(), 0xbb, "UTF8-BOM[1]");
                CheckFrameByte(input.ReadByte(), 0xbf, "UTF8-BOM[2]");
                first = input.ReadByte();
            }
            CheckFrameByte(first, expected[0], "release[0]");
            for (int index = 1; index < expected.Length; index++)
                CheckFrameByte(input.ReadByte(), expected[index], "release[" + index.ToString(CultureInfo.InvariantCulture) + "]");
        }
        private static void CheckFrameByte(int actual, int expected, string position)
        {
            if (actual == expected) return;
            frameFailure = "control=" + position + ", expected=0x" + expected.ToString("x2", CultureInfo.InvariantCulture) +
                ", actual=" + (actual < 0 ? "EOF" : "0x" + actual.ToString("x2", CultureInfo.InvariantCulture));
            throw new InvalidOperationException("Holding fixture control frame differed.");
        }
        private static void CheckHolderAlive(Process holder, Task<string> errors, string stage, Action<bool, string> assert)
        {
            bool alive = !holder.HasExited;
            string detail = alive ? "" : "exit=" + holder.ExitCode.ToString(CultureInfo.InvariantCulture) +
                ", stderr=" + (errors.Wait(2000) ? Limit(errors.Result) : "unavailable");
            assert(alive, "Holding fixture exited before " + stage + " (" + detail + ").");
        }

        private static void CheckPublicationRecords(SecurityIdentifier user, Action<bool, string> assert)
        {
            int session;
            using (var process = Process.GetCurrentProcess()) session = process.SessionId;
            string fixture = Fixture(), generation = "abcdef0123456789abcdef0123456789";
            assert(ResidentStateLease.ReadGenerationForChecks(fixture, user, session) == null &&
                !ResidentStateLease.PublicationExistsForChecks(fixture), "An absent publication read created a file.");
            using (var writer = ResidentStateLease.TryAcquireForChecks(fixture))
            {
                writer.Publish(user, session, generation);
                assert(ResidentStateLease.ReadGenerationForChecks(fixture, user, session) == generation,
                    "Read-only discovery could not read a live writer publication.");
                using (var second = ResidentStateLease.TryAcquireForChecks(fixture))
                    assert(second == null, "Publication sharing admitted a second writer.");
                using (var reader = new FileStream(ResidentStateLease.PathForChecks(fixture), FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    writer.Dispose();
                    using (var successor = ResidentStateLease.TryAcquireForChecks(fixture))
                        assert(successor != null, "A retained read-only handle prevented a successor writer.");
                }
            }
            assert(new FileInfo(ResidentStateLease.PathForChecks(fixture)).Length == 0,
                "Closing a writer did not invalidate its publication.");

            fixture = Fixture(); bool created;
            using (var raw = ResidentInstance.NamespaceForChecks(fixture))
            using (var legacy = new EventWaitHandle(false, EventResetMode.AutoReset, ManualLaunchSignal.NameForChecks(fixture, "status"),
                out created, ManualLaunchSignal.SecurityForChecks(user)))
            {
                assert(created, "Malformed publication fallback fixture collided.");
                using (var seed = ResidentStateLease.TryAcquireForChecks(fixture)) { }
                string record = "DiscordAccess.Resident.V3\n" + user.Value + "\n" + session.ToString(CultureInfo.InvariantCulture) + "\n" + generation + "\n";
                byte[][] invalid = {
                    new byte[0], Encoding.ASCII.GetBytes(record.Substring(0, record.Length - 1)),
                    Encoding.ASCII.GetBytes(record + "extra\n"), Encoding.ASCII.GetBytes(new string('x', 513)),
                    Encoding.ASCII.GetBytes(record.Replace("V3", "V2")),
                    Encoding.ASCII.GetBytes(record.Replace(user.Value, "S-1-5-21-1-2-3-1002")),
                    Encoding.ASCII.GetBytes(record.Replace("\n" + session.ToString(CultureInfo.InvariantCulture) + "\n", "\n" + (session + 1).ToString(CultureInfo.InvariantCulture) + "\n")),
                    Encoding.ASCII.GetBytes(record.Replace(generation, generation.ToUpperInvariant())),
                    Encoding.ASCII.GetBytes(record.Replace(generation, Guid.Empty.ToString("N"))),
                    Encoding.ASCII.GetBytes(record.Replace(generation, "../../other")),
                    Encoding.ASCII.GetBytes(record.Replace("V3", "V3\0")), new byte[] { 0xff, 0xfe, 0x41 },
                };
                foreach (byte[] bytes in invalid)
                {
                    File.WriteAllBytes(ResidentStateLease.PathForChecks(fixture), bytes);
                    string response;
                    assert(ResidentStateLease.ReadGenerationForChecks(fixture, user, session) == null &&
                        !ManualLaunchSignal.RequestFixture(fixture, "status", out response) && !legacy.WaitOne(0) &&
                        ResidentInstance.NamespaceReferencesForChecks(fixture) == 1,
                        "A malformed publication used a raw fixture fallback or created a generation.");
                }
                File.WriteAllBytes(ResidentStateLease.PathForChecks(fixture), Encoding.ASCII.GetBytes(record));
                string staleResponse;
                assert(!ManualLaunchSignal.RequestFixture(fixture, "status", out staleResponse) && !legacy.WaitOne(0) &&
                    ResidentInstance.NamespaceReferencesForChecks(fixture) == 1,
                    "A stale valid publication used a raw namespace fallback.");
            }
        }

        private static void CheckRetainedStaticOpener(string fixture, Action<bool, string> assert)
        {
            Process opener = null;
            var creator = ResidentInstance.NamespaceForChecks(fixture);
            try
            {
                opener = Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,
                    "--resident-static-alias-hold-child " + fixture) {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                    RedirectStandardOutput = true, RedirectStandardError = true });
                if (opener == null) throw new InvalidOperationException("Static opener fixture was not created.");
                Task<string> output = opener.StandardOutput.ReadLineAsync(), errors = opener.StandardError.ReadToEndAsync();
                assert(output.Wait(5000) && output.Result == "opened", "Static opener fixture was not ready.");
                using (var first = ResidentInstance.AcquireForChecks(fixture))
                using (var received = new AutoResetEvent(false))
                using (var listener = ManualLaunchSignal.ListenFixture(fixture, "status", () => received.Set()))
                {
                    assert(first.IsPrimary, "First retained-static-opener primary did not acquire.");
                    creator.Dispose();
                    assert(RunSignalChildForChecks(fixture, "status") == "sent" && received.WaitOne(2000),
                        "Closing the static creator orphaned the first generation.");
                }
                // The old STATIC opener remains alive across both creator and
                // first-primary closure. A successor must still be discoverable.
                using (var successor = ResidentInstance.AcquireForChecks(fixture))
                using (var received = new AutoResetEvent(false))
                using (var listener = ManualLaunchSignal.ListenFixture(fixture, "status", () => received.Set()))
                {
                    assert(successor.IsPrimary && RunSignalChildForChecks(fixture, "status") == "sent" && received.WaitOne(2000),
                        "A retained retired static opener prevented successor generation delivery.");
                    byte[] release = Encoding.ASCII.GetBytes("release\n");
                    opener.StandardInput.BaseStream.Write(release, 0, release.Length); opener.StandardInput.BaseStream.Flush();
                    Task<string> remainder = opener.StandardOutput.ReadToEndAsync();
                    assert(opener.WaitForExit(5000) && Task.WaitAll(new Task[] { errors, remainder }, 2000) && opener.ExitCode == 0 &&
                        String.IsNullOrWhiteSpace(errors.Result) && String.IsNullOrWhiteSpace(remainder.Result), "Static opener did not close cleanly.");
                    assert(RunSignalChildForChecks(fixture, "status") == "sent" && received.WaitOne(2000),
                        "Closing the retired static opener affected the successor generation.");
                }
                assert(ResidentInstance.NamespaceReferencesForChecks(fixture) == 0, "Retired static opener fixture leaked an alias.");
            }
            finally
            {
                creator.Dispose();
                if (opener != null)
                {
                    try { if (!opener.HasExited) { opener.Kill(); opener.WaitForExit(2000); } }
                    finally { opener.Dispose(); }
                }
            }
        }

        private static void CheckCreatorHandover(string fixture, Action<bool, string> assert)
        {
            Process holder = null;
            var creator = ResidentInstance.NamespaceForChecks(fixture);
            try
            {
                holder = Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,
                    "--resident-namespace-hold-child " + fixture) {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true });
                if (holder == null) throw new InvalidOperationException("Holding namespace fixture child was not created.");
                Task<string> errors = holder.StandardError.ReadToEndAsync();
                Task<string> ready = holder.StandardOutput.ReadLineAsync();
                assert(ready.Wait(5000) && ready.Result == "primary", "Namespace opener child did not retain primary ownership.");
                CheckHolderAlive(holder, errors, "creator close", assert);
                using (var identity = WindowsIdentity.GetCurrent())
                using (var process = Process.GetCurrentProcess())
                    assert(ResidentStateLease.ReadGenerationForChecks(fixture, identity.User, process.SessionId) != null,
                        "Holding fixture publication was not readable through the parent's exact fixture path.");
                creator.Dispose();
                assert(ResidentInstance.NamespaceReferencesForChecks(fixture) == 0, "Original creator kept a hidden namespace lease.");
                CheckHolderAlive(holder, errors, "third ownership probe", assert);
                string third = RunChild(fixture, context: "creator-closed-live-opener");
                CheckHolderAlive(holder, errors, "ownership probe completion", assert);
                assert(third == "secondary", "Creator alias closing split a live primary from a third process (observed=" + third + ").");
                Task<string> delivered = holder.StandardOutput.ReadLineAsync();
                assert(RunSignalChildForChecks(fixture, "status") == "sent" && delivered.Wait(5000) && delivered.Result == "status",
                    "Creator alias closing orphaned the live primary's private signal listener.");
                byte[] release = System.Text.Encoding.ASCII.GetBytes("release\n");
                holder.StandardInput.BaseStream.Write(release, 0, release.Length);
                holder.StandardInput.BaseStream.Flush();
                Task<string> output = holder.StandardOutput.ReadToEndAsync();
                bool exited = holder.WaitForExit(5000);
                bool read = exited && Task.WaitAll(new Task[] { output, errors }, 2000);
                assert(read && holder.ExitCode == 0 && String.IsNullOrWhiteSpace(errors.Result) && String.IsNullOrWhiteSpace(output.Result),
                    "Namespace opener child did not release ownership cleanly (exit=" + (exited ? holder.ExitCode.ToString() : "timeout") +
                    ", fixture stderr=" + (read ? errors.Result.Trim() : "unavailable") + ").");
                using (var successor = ResidentInstance.AcquireForChecks(fixture))
                    assert(successor.IsPrimary, "Creator/opener shutdown prevented a successor primary.");
                assert(ResidentInstance.NamespaceReferencesForChecks(fixture) == 0, "Takeover retained a private namespace lease after shutdown.");
            }
            finally
            {
                creator.Dispose();
                if (holder != null)
                {
                    try { if (!holder.HasExited) { holder.Kill(); holder.WaitForExit(2000); } }
                    finally { holder.Dispose(); }
                }
            }
        }

        internal static string RunNamespaceChildForChecks(string fixture) { return RunChild(fixture, context: "signal-fixture-live-owner"); }
        internal static string RunSignalChildForChecks(string fixture, string channel, bool requireNoOwner = false)
        { return RunChild(fixture, channel, requireNoOwner); }

        private static string RunChild(string fixture, string channel = null, bool requireNoOwner = false, string context = null)
        {
            Guid parsed;
            if (!Guid.TryParseExact(fixture, "N", out parsed)) throw new ArgumentException("Resident child fixture identifier");
            if (channel != null) ManualLaunchSignal.NameForChecks(fixture, channel);
            string label = context ?? (channel == null ? "ownership" : "signal-" + channel + (requireNoOwner ? "-no-owner" : ""));
            string arguments = channel == null ? "--resident-namespace-child " + fixture :
                "--resident-signal-child " + fixture + " " + channel + (requireNoOwner ? " --no-owner" : "");
            Process child = null;
            Task<string> output = null, errors = null;
            try
            {
                child = Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,
                    arguments) {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true });
                if (child == null) throw new InvalidOperationException("Resident namespace fixture child was not created [" + label + "].");
                output = child.StandardOutput.ReadToEndAsync(); errors = child.StandardError.ReadToEndAsync();
                if (!child.WaitForExit(5000)) throw new InvalidOperationException("Resident namespace fixture child timed out [" + label + "].");
                if (!Task.WaitAll(new Task[] { output, errors }, 2000))
                    throw new InvalidOperationException("Resident namespace fixture child output timed out [" + label + "].");
                if (child.ExitCode != 0 || !String.IsNullOrWhiteSpace(errors.Result))
                    throw new InvalidOperationException("Resident namespace fixture child failed [" + label + "] (exit " + child.ExitCode + "): " + Limit(errors.Result));
                return output.Result.Trim();
            }
            finally
            {
                if (child != null)
                {
                    try { if (!child.HasExited) { child.Kill(); child.WaitForExit(2000); } }
                    finally { child.Dispose(); }
                }
            }
        }

        private static string Limit(string text)
        { return text == null ? "" : text.Substring(0, Math.Min(text.Length, 1024)); }
    }
}
#endif
