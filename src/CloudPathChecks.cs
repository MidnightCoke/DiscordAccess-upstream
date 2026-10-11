#if TEST_BUILD
using System;
using System.Diagnostics;
using System.IO;

namespace DiscordAccess
{
    internal static class CloudPathChecks
    {
        internal static int Run(string packageRoot)
        {
            int checks = 0;
            Action<bool, string> assert = (ok, text) => {
                if (!ok) throw new InvalidOperationException(text); checks++;
            };
            for (uint variant = 0; variant < 16; variant++)
                assert(NativeFile.IsCloudTag(0x9000001au | (variant << 12)), "A Microsoft Cloud variant was rejected.");
            foreach (uint tag in new[] { 0u, 0xa0000003u, 0xa000000cu, 0x80000007u,
                0x80000017u, 0x8000001bu, 0x9000001cu, 0xa0001027u, 0x9001001au, 0xb000001au })
                assert(!NativeFile.IsCloudTag(tag), "A non-Cloud reparse tag was admitted.");

            string work = Path.Combine(Path.GetFullPath(packageRoot), "work");
            string root = Path.Combine(work, "cloud-path-" + Guid.NewGuid().ToString("N"));
            if (!Safety.Under(root, work) || !Safety.NoReparse(root))
                throw new InvalidOperationException("Cloud fixture escaped its local work directory.");
            string target = Path.Combine(root, "target"), junction = Path.Combine(root, "junction");
            string file = Path.Combine(target, "inert.txt");
            try
            {
                Directory.CreateDirectory(target); File.WriteAllText(file, "INERT_PATH_CANARY");
                assert(Safety.NoReparse(file), "An ordinary local file was rejected.");
                assert(!NativeFile.CloudPlaceholder(file), "An ordinary file was identified as a Cloud placeholder.");
                assert(Safety.NoReparse(Path.Combine(target, "missing", "file.txt")), "A normal not-yet-created local path was rejected.");
                using (var lease = Safety.ReadLease(file))
                    assert(lease.Length == new FileInfo(file).Length, "A normal read lease was not retained.");

                // The link and its target are inert, unique fixture directories.
                // No application, account or actual shortcut is read or changed.
                using (var process = Process.Start(new ProcessStartInfo {
                    FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"),
                    Arguments = "/d /c mklink /J \"" + junction + "\" \"" + target + "\"",
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true }))
                {
                    process.StandardOutput.ReadToEnd(); process.StandardError.ReadToEnd();
                    if (!process.WaitForExit(10000) || process.ExitCode != 0)
                        throw new InvalidOperationException("Could not create the local path junction fixture.");
                }
                assert((File.GetAttributes(junction) & FileAttributes.ReparsePoint) != 0, "The junction fixture has no reparse attribute.");
                assert(!NativeFile.CloudPlaceholder(junction), "A junction was identified as Microsoft Cloud.");
                foreach (string path in new[] { junction, Path.Combine(junction, "inert.txt"),
                    Path.Combine(junction, "missing"), Path.Combine(junction, "missing", "file.txt") })
                    assert(!Safety.NoReparse(path), "A junction or a redirected ancestor was admitted.");
                bool rejected = false;
                try { using (var lease = Safety.ReadLease(Path.Combine(junction, "inert.txt"))) { } }
                catch (InvalidDataException) { rejected = true; }
                assert(rejected, "A read lease followed a junction.");
                assert(File.ReadAllText(file) == "INERT_PATH_CANARY", "The junction rejection changed its target.");
                File.Delete(file); Directory.Delete(target, false);
                assert(!NativeFile.CloudPlaceholder(junction), "A dangling junction was identified as Microsoft Cloud.");
                assert(!Safety.NoReparse(junction), "A dangling junction was admitted.");
                assert(!Safety.NoReparse(Path.Combine(junction, "missing", "file.txt")), "A dangling junction ancestor was admitted.");
                assert(!Safety.NoReparse(null), "A missing path argument was admitted.");
            }
            finally
            {
                // Remove the reparse object itself before any recursive cleanup.
                try
                {
                    if ((File.GetAttributes(junction) & FileAttributes.ReparsePoint) != 0)
                        Directory.Delete(junction, false);
                }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
                if (Safety.Under(root, work) && Safety.NoReparse(root)) Directory.Delete(root, true);
            }
            return checks;
        }

        // Optional real-path check: only directory/file attributes and a retained
        // read lease are inspected. No Cloud data is written or executable run.
        internal static int RunReadOnly(string path)
        {
            path = Path.GetFullPath(path);
            bool cloud = false;
            for (string current = path; !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                cloud |= NativeFile.CloudPlaceholder(current);
            if (!cloud) throw new InvalidOperationException("The supplied read-only path has no Microsoft Cloud ancestor.");
            if (!Safety.NoReparse(path)) throw new InvalidOperationException("The Microsoft Cloud path was rejected.");
            int checks = 2;
            if (File.Exists(path))
                using (var lease = Safety.ReadLease(path))
                {
                    if (lease.Length < 0) throw new InvalidOperationException("The Cloud read lease is invalid.");
                    checks++;
                }
            return checks;
        }
    }
}
#endif
