#if TEST_BUILD
using System;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace DiscordAccess
{
    // Only uniquely named inert files under this run's fixture root are used.
    internal static class PrivateFileTrustChecks
    {
        internal static readonly SecurityIdentifier Foreign = new SecurityIdentifier("S-1-5-21-111111111-222222222-333333333-1002");

        internal static FileSecurity Security(FileSystemRights? foreign = null)
        {
            var security = new FileSecurity(); security.SetAccessRuleProtection(true, false);
            using (var identity = WindowsIdentity.GetCurrent())
            {
                security.SetOwner(identity.User);
                security.AddAccessRule(new FileSystemAccessRule(identity.User, FileSystemRights.FullControl, AccessControlType.Allow));
            }
            foreach (var sid in new[] { new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
            if (foreign.HasValue) security.AddAccessRule(new FileSystemAccessRule(Foreign, foreign.Value, AccessControlType.Allow));
            return security;
        }

        internal static int Run(string packageRoot)
        {
            string work = Path.Combine(Path.GetFullPath(packageRoot), "work");
            string root = Path.Combine(work, "private-file-" + Guid.NewGuid().ToString("N"));
            if (!Safety.Under(root, work) || !Safety.NoReparse(root)) throw new InvalidOperationException("Private-file fixture escaped work.");
            var directory = new DirectorySecurity(); directory.SetAccessRuleProtection(true, false);
            using (var identity = WindowsIdentity.GetCurrent())
            {
                directory.SetOwner(identity.User);
                directory.AddAccessRule(new FileSystemAccessRule(identity.User, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            }
            Directory.CreateDirectory(root, directory);
            string target = Path.Combine(root, "hook.cjs"), incoming = Path.Combine(root, "reviewed.pending");
            int checks = 0;
            Action<bool, string> assert = (ok, message) => { if (!ok) throw new InvalidOperationException("Private file trust: " + message); checks++; };
            Action<Action, string> rejects = (action, message) => {
                bool rejected = false; try { action(); } catch (InvalidDataException) { rejected = true; }
                assert(rejected, message);
            };
            byte[] reviewed = Encoding.UTF8.GetBytes("reviewed inert fixture; never executed");
            try
            {
                // A foreign-owner descriptor is synthetic because assigning a
                // different account as a real file owner requires privileges.
                // The real fixtures below need no elevation or account lookup.
                using (var identity = WindowsIdentity.GetCurrent())
                {
                    assert(!StartupPathTrust.DescriptorTrustedFile(new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent,
                        Foreign, null, null, new RawAcl(GenericAcl.AclRevision, 0)), identity.User), "Foreign child owner was trusted.");
                    assert(!StartupPathTrust.DescriptorTrustedFile(new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent,
                        identity.User, null, null, null), identity.User), "Null child DACL was trusted.");
                }
                File.WriteAllBytes(target, reviewed);
                using (var lease = PrivateFileTrust.ReadLease(target))
                {
                    assert(lease.Length == reviewed.Length, "Clean child creation was rejected.");
                    bool writeBlocked = false, deleteBlocked = false;
                    try { using (new FileStream(target, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) { } }
                    catch (IOException) { writeBlocked = true; }
                    try { File.Move(target, incoming); } catch (IOException) { deleteBlocked = true; }
                    assert(writeBlocked && deleteBlocked && File.Exists(target), "A held verified lease allowed content writes or replacement.");
                }
                File.SetAccessControl(target, Security(FileSystemRights.ReadAndExecute));
                using (PrivateFileTrust.ReadLease(target)) { }
                assert(true, "Read-only foreign access was rejected.");

                foreach (FileSystemRights rights in new[] { FileSystemRights.WriteData, FileSystemRights.AppendData,
                    FileSystemRights.WriteExtendedAttributes, FileSystemRights.WriteAttributes, FileSystemRights.Delete,
                    FileSystemRights.ChangePermissions, FileSystemRights.TakeOwnership })
                {
                    File.SetAccessControl(target, Security(rights));
                    string before = File.GetAccessControl(target).GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access);
                    rejects(() => { using (PrivateFileTrust.ReadLease(target)) { } }, "Foreign child mutation was accepted: " + rights);
                    assert(File.ReadAllBytes(target).SequenceEqual(reviewed) && before ==
                        File.GetAccessControl(target).GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access),
                        "Rejection modified existing child bytes or permissions.");
                }

                // ReplaceFile preserves the existing target DACL even when a
                // reviewed replacement inherits the private parent's ACL.
                File.SetAccessControl(target, Security(FileSystemRights.WriteData));
                File.WriteAllBytes(incoming, reviewed);
                using (PrivateFileTrust.ReadLease(incoming)) { }
                File.Replace(incoming, target, null);
                assert(File.ReadAllBytes(target).SequenceEqual(reviewed), "Real File.Replace did not install reviewed fixture bytes.");
                assert(File.GetAccessControl(target).GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
                    .Any(rule => rule.IdentityReference.Value == Foreign.Value && rule.AccessControlType == AccessControlType.Allow &&
                        (rule.FileSystemRights & FileSystemRights.WriteData) != 0), "File.Replace fixture did not preserve the unsafe target DACL.");
                rejects(() => { using (PrivateFileTrust.ReadLease(target)) { } }, "Reviewed bytes concealed a preserved unsafe DACL.");
                File.SetAccessControl(target, Security());
                using (PrivateFileTrust.ReadLease(target)) { }
                assert(true, "Ordinary safe child could not be reused after fixture reset.");
            }
            finally
            {
                // Exact known files only, with no recursive or computed cleanup.
                if (File.Exists(target)) File.Delete(target);
                if (File.Exists(incoming)) File.Delete(incoming);
                Directory.Delete(root);
            }
            return checks;
        }
    }
}
#endif
