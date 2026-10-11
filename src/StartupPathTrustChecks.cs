#if TEST_BUILD
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace DiscordAccess
{
    // All paths and descriptors are synthetic. No file, directory, ACL,
    // registry entry or Discord installation is read or modified.
    internal static class StartupPathTrustChecks
    {
        private static readonly SecurityIdentifier User = new SecurityIdentifier("S-1-5-21-111111111-222222222-333333333-1001");
        private static readonly SecurityIdentifier Foreign = new SecurityIdentifier("S-1-5-21-111111111-222222222-333333333-1002");
        private static readonly SecurityIdentifier Everyone = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
        private static readonly SecurityIdentifier System = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        private static readonly SecurityIdentifier Administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        private static readonly SecurityIdentifier Installer = new SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464");
        private const string Executable = @"C:\Users\Fixture\Documents\DiscordAccess\DiscordAccess.exe";
        private const int Full = 0x001f01ff, Read = 0x001200a9;

        private static CommonAce Allow(SecurityIdentifier sid, int mask, AceFlags flags = AceFlags.None)
        { return new CommonAce(flags, AceQualifier.AccessAllowed, mask, sid, false, null); }
        private static CommonAce Deny(SecurityIdentifier sid, int mask, bool callback = false)
        { return new CommonAce(AceFlags.None, AceQualifier.AccessDenied, mask, sid, callback, null); }
        private static RawSecurityDescriptor Descriptor(SecurityIdentifier owner, params GenericAce[] entries)
        {
            var acl = new RawAcl(GenericAcl.AclRevisionDS, entries.Length);
            for (int index = 0; index < entries.Length; index++) acl.InsertAce(index, entries[index]);
            return new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent, owner, null, null, acl);
        }
        private static bool Trusted(RawSecurityDescriptor descriptor, bool directory = false)
        { return StartupPathTrust.DescriptorTrustedForChecks(descriptor, directory, User); }

        internal static int Run(string packageRoot)
        {
            int checks = 0;
            Action<bool, string> assert = (ok, message) => { checks++; if (!ok) throw new InvalidOperationException("Startup path trust: " + message); };
            Action<Action, string> reject = (action, message) =>
            {
                bool refused = false; try { action(); } catch (UserActionException) { refused = true; }
                assert(refused, message);
            };
            foreach (SecurityIdentifier owner in new[] { User, System, Administrators, Installer })
                assert(Trusted(Descriptor(owner, Allow(User, Full), Allow(System, Full), Allow(Administrators, Full), Allow(Installer, Full))),
                    "Trusted owner or writer was rejected.");
            assert(Trusted(Descriptor(User, Allow(Everyone, Read))), "Read-only foreign access was rejected.");
            foreach (int right in new[] { 2, 4, 16, 256, 0x10000, 0x40000, 0x80000, 0x10000000, 0x40000000 })
                assert(!Trusted(Descriptor(User, Allow(Foreign, right))), "Foreign file mutation was trusted.");
            foreach (int right in new[] { 16, 64, 256, 0x10000, 0x40000, 0x80000, 0x10000000, 0x40000000 })
                assert(!Trusted(Descriptor(User, Allow(Foreign, right)), true), "Foreign directory mutation was trusted.");
            foreach (int right in new[] { 2, 4, 2 | 4 })
                assert(Trusted(Descriptor(Administrators, Allow(Everyone, Read | right)), true),
                    "Sibling creation was mistaken for replacement of an existing component.");
            assert(!Trusted(Descriptor(Foreign, Allow(User, Full))), "A foreign owner with implicit DACL write was trusted.");
            assert(!Trusted(Descriptor(null, Allow(User, Full))), "Missing owner was trusted.");
            assert(!Trusted(null), "Missing descriptor was trusted.");
            assert(!Trusted(new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent, User, null, null, null)), "Null DACL was trusted.");
            assert(!Trusted(new RawSecurityDescriptor(ControlFlags.None, User, null, null, null)), "Absent DACL was trusted.");
            assert(Trusted(Descriptor(User)), "Empty DACL with a trusted owner was rejected.");
            assert(Trusted(Descriptor(User, Allow(Everyone, Full, AceFlags.ContainerInherit | AceFlags.ObjectInherit | AceFlags.InheritOnly))),
                "Inheritance-only template was applied to its present object.");
            assert(!Trusted(Descriptor(User, Allow(Foreign, Full, AceFlags.Inherited))), "Inherited effective mutation was skipped.");
            var creatorOwner = new SecurityIdentifier(WellKnownSidType.CreatorOwnerSid, null);
            assert(Trusted(Descriptor(User, Allow(creatorOwner, Full, AceFlags.ContainerInherit | AceFlags.ObjectInherit | AceFlags.InheritOnly))),
                "Creator-owner inheritance template was applied to its parent.");
            assert(!Trusted(Descriptor(User, Allow(creatorOwner, Full))), "Unresolved effective creator-owner mutation was trusted.");
            var ownerRights = new SecurityIdentifier("S-1-3-4");
            assert(Trusted(Descriptor(User, Allow(ownerRights, Full))), "Owner-rights grant was not bound to its trusted owner.");
            assert(!Trusted(Descriptor(Foreign, Allow(ownerRights, Read))), "Owner-rights ACE concealed an untrusted owner.");
            assert(Trusted(Descriptor(User, Deny(Foreign, 2), Allow(Foreign, 2))), "Preceding same-trustee deny was ignored.");
            assert(Trusted(Descriptor(User, Deny(Everyone, 2), Allow(Foreign, 2))), "Preceding unconditional Everyone deny was ignored.");
            assert(!Trusted(Descriptor(User, Allow(Foreign, 2), Deny(Foreign, 2))), "Later noncanonical deny incorrectly cancelled an earlier allow.");
            assert(!Trusted(Descriptor(User, Deny(Foreign, 2), Allow(Foreign, 2 | 4))), "Partial deny cancelled an unblocked mutation.");
            assert(!Trusted(Descriptor(User, Deny(Administrators, Full), Allow(Foreign, 2))), "Unproven group overlap was used as a deny.");
            assert(!Trusted(Descriptor(User, Deny(Everyone, Full, true), Allow(Foreign, 2))), "Conditional deny was treated as unconditional.");
            assert(Trusted(Descriptor(User, Allow(Everyone, unchecked((int)0x80000000)))), "Generic read was treated as a write.");
            var objectGrant = new ObjectAce(AceFlags.None, AceQualifier.AccessAllowed, 2, Foreign,
                ObjectAceFlags.None, Guid.Empty, Guid.Empty, false, null);
            assert(!Trusted(Descriptor(User, objectGrant)), "Foreign object-specific allow was skipped.");

            var chain = new Dictionary<string, RawSecurityDescriptor>(StringComparer.OrdinalIgnoreCase);
            for (string path = Executable; !String.IsNullOrEmpty(path); path = Path.GetDirectoryName(path))
                chain.Add(path, Descriptor(User, Allow(User, Full), Allow(System, Full), Allow(Everyone, Read)));
            chain[@"C:\Users"] = Descriptor(Administrators, Allow(User, Full), Allow(Everyone, Read | 4),
                Allow(creatorOwner, Full, AceFlags.ContainerInherit | AceFlags.ObjectInherit | AceFlags.InheritOnly));
            chain[@"C:\"] = Descriptor(Installer, Allow(System, Full), Allow(Administrators, Full), Allow(Everyone, Read | 2 | 4));
            var visited = new List<string>();
            StartupPathTrust.VerifyChainForChecks(Executable, User, (path, directory) =>
            {
                assert(directory == !String.Equals(path, Executable, StringComparison.OrdinalIgnoreCase), "Wrong file/directory semantics in chain.");
                visited.Add(path); return chain[path];
            }, path => true);
            assert(visited.Count == 6 && visited[0] == Executable && visited[5] == @"C:\", "Path verification stopped before the root.");
            string parent = Path.GetDirectoryName(Executable);
            RawSecurityDescriptor original = chain[parent];
            chain[Executable] = Descriptor(User, Deny(Foreign, 0x10000), Allow(User, Full));
            chain[parent] = Descriptor(User, Allow(Foreign, 64));
            reject(() => StartupPathTrust.VerifyChainForChecks(Executable, User, (path, directory) => chain[path], path => true),
                "Parent DELETE_CHILD bypassed a protected executable's delete deny.");
            chain[parent] = original;
            chain[@"C:\Users"] = Descriptor(Foreign, Allow(User, Full));
            reject(() => StartupPathTrust.VerifyChainForChecks(Executable, User, (path, directory) => chain[path], path => true),
                "An untrusted ancestor owner was skipped.");
            chain[@"C:\Users"] = Descriptor(Administrators, Allow(User, Full), Allow(Everyone, Read | 4));
            reject(() => StartupPathTrust.VerifyChainForChecks(Executable, User, (path, directory) => chain[path], path => path != parent),
                "Reparse/unverified component was accepted.");
            int reads = 0;
            foreach (string invalid in new[] { "relative\\DiscordAccess.exe", @"\\server\share\DiscordAccess.exe", @"C:\DiscordAccess.exe:stream", "C:/DiscordAccess.exe", "C:\\DiscordAccess.exe\n", @"C:\" })
                reject(() => StartupPathTrust.VerifyChainForChecks(invalid, User, (path, directory) => { reads++; return chain[path]; }, path => true),
                    "Unsupported executable path reached the ACL boundary.");
            assert(reads == 0, "Unsupported paths performed descriptor reads.");
            return checks;
        }
    }
}
#endif
