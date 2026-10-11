#if TEST_BUILD
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace DiscordAccess
{
    internal static class ExternalDiscordScopeChecks
    {
        private const string FixtureSid = "S-1-5-21-100-200-300-1001";

        internal static int Run()
        {
            int checks = 0;
            Action<bool, string> require = (condition, label) =>
            { checks++; if (!condition) throw new InvalidOperationException("External Discord admission fixture: " + label); };
            string image = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            var approved = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { image };
            long ready = DateTime.UtcNow.ToFileTimeUtc();
            Func<ExternalDiscordScope.Identity> valid = () => new ExternalDiscordScope.Identity { ProcessId = 42, ImagePath = image,
                CreationFileTime = ready + 1, UserSid = FixtureSid, SessionId = 2, Running = true };
            Func<ExternalDiscordScope.Identity, bool> admits = identity => ExternalDiscordScope.IdentityAllowed(identity, 42, approved, ready, FixtureSid, 2);
            require(admits(valid()), "valid exact identity");
            var caseIdentity = valid(); caseIdentity.ImagePath = image.ToUpperInvariant();
            require(admits(caseIdentity), "canonical image comparison is case-insensitive");
            var candidate = valid(); candidate.CreationFileTime = ready;
            require(admits(candidate), "ready instant included");
            candidate = valid(); candidate.CreationFileTime = ready - 1;
            require(!admits(candidate), "preexisting client excluded");
            candidate = valid(); candidate.CreationFileTime = 0;
            require(!admits(candidate), "missing kernel creation time refused");
            candidate = valid(); candidate.UserSid = "S-1-5-18";
            require(!admits(candidate), "other account refused");
            candidate = valid(); candidate.SessionId = 3;
            require(!admits(candidate), "same account other Windows session refused");
            candidate = valid(); candidate.ProcessId = 43;
            require(!admits(candidate), "different pinned process object refused");
            candidate = valid(); candidate.Running = false;
            require(!admits(candidate), "gone process refused");
            candidate = valid(); candidate.ImagePath = Path.Combine(Path.GetDirectoryName(image), "other.exe");
            require(!admits(candidate), "different image in same directory refused");
            candidate = valid(); candidate.ImagePath = null;
            require(!admits(candidate), "unreadable image refused");
            require(!admits(null), "missing identity refused");
            require(!ExternalDiscordScope.IdentityAllowed(valid(), 0, approved, ready, FixtureSid, 2), "invalid PID refused");
            require(!ExternalDiscordScope.IdentityAllowed(valid(), 42, null, ready, FixtureSid, 2), "missing approved images refused");
            require(!ExternalDiscordScope.IdentityAllowed(valid(), 42, approved, ready, null, 2), "missing expected SID refused");
            // A stale snapshot of PID 42 remains tied to its old creation time.
            candidate = valid(); candidate.CreationFileTime = ready - 100;
            require(!admits(candidate), "reused PID cannot reuse old identity proof");
            candidate = valid(); candidate.ProcessId = 42; candidate.Running = false;
            require(!admits(candidate), "dead retained PID cannot grant access to replacement");
            require(ExternalDiscordScope.PinnedIdentityAllowed(valid(), 42, ready + 1, true, approved, ready, FixtureSid, 2), "live pinned kernel creation time matches");
            require(!ExternalDiscordScope.PinnedIdentityAllowed(valid(), 42, ready + 2, true, approved, ready, FixtureSid, 2), "same reused PID with new kernel creation time cannot reuse cached proof");
            require(!ExternalDiscordScope.PinnedIdentityAllowed(valid(), 42, ready + 1, false, approved, ready, FixtureSid, 2), "dead pinned kernel object cannot reuse cached proof");

            Func<string, IDisposable> verifier = path =>
            {
                if (!String.Equals(path, image, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Not registered system fixture.");
                // Windows PowerShell is catalog-signed on this Windows build;
                // CreateFromSignedFile only sees embedded signatures. Ask the
                // existing system verifier for this exact protected system EXE.
                VerifySystemSignature(image);
                return Safety.ReadLease(path);
            };
            using (var existing = StartInert(image, 10000))
            {
                Thread.Sleep(25);
                DateTime readyUtc = DateTime.UtcNow;
                using (var scope = ExternalDiscordScope.CreateFixture(new[] { image }, readyUtc, verifier))
                {
                    require(!scope.AnyRunning, "scope does not enumerate or claim preexisting system children");
                    require(!scope.Permits(existing.Id) && !scope.AnyRunning, "actual earlier process refused and not retained");
                    require(!scope.Permits(0) && !scope.Permits(Int32.MaxValue), "invalid and nonexistent actual PIDs refused");
                    using (var child = StartInert(image, 1500))
                    {
                        require(scope.Permits(child.Id), "new current-user/session exact system fixture admitted");
                        require(scope.Permits(child.Id) && scope.AnyRunning, "cached live pinned identity remains admitted");
                        require(child.WaitForExit(5000), "inert admitted fixture exits naturally");
                        require(!scope.Permits(child.Id) && !scope.AnyRunning, "dead retained handle pruned even while managed Process handle remains");
                    }
                    using (var untouched = StartInert(image, 700))
                    {
                        require(scope.Permits(untouched.Id) && scope.AnyRunning, "second independent process admitted");
                        scope.Dispose();
                        require(!scope.Permits(untouched.Id) && !scope.AnyRunning, "disposed scope grants nothing");
                        require(!untouched.HasExited, "disposing admission scope never terminates external process");
                        require(untouched.WaitForExit(5000), "external process exits naturally after scope disposal");
                    }
                    require(!existing.HasExited, "admission never changed old process lifetime");
                }
                require(existing.WaitForExit(14000), "preexisting inert process exits naturally");
            }
            bool failed = false;
            try { using (ExternalDiscordScope.CreateFixture(new[] { image }, DateTime.Now, verifier)) { } }
            catch (ArgumentException) { failed = true; }
            require(failed, "non-UTC readiness refused");
            failed = false;
            try { using (ExternalDiscordScope.CreateFixture(new string[0], DateTime.UtcNow, verifier)) { } }
            catch (InvalidDataException) { failed = true; }
            require(failed, "empty approved image set refused");
            failed = false;
            try { using (ExternalDiscordScope.CreateFixture(new[] { image }, DateTime.UtcNow, ignored => { throw new InvalidDataException("Rejected fixture image."); })) { } }
            catch (InvalidDataException) { failed = true; }
            require(failed, "image verification failure refuses scope");
            return checks;
        }

        private static Process StartInert(string image, int delay)
        {
            return Process.Start(new ProcessStartInfo(image, "-NoProfile -NonInteractive -Command \"[Threading.Thread]::Sleep(" + delay + ")\"")
            { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(image) });
        }

        private static void VerifySystemSignature(string image)
        {
            const string command = "-NoProfile -NonInteractive -Command \"Import-Module -Name (Join-Path $PSHOME 'Modules\\Microsoft.PowerShell.Security\\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop; " +
                "$s=Get-AuthenticodeSignature -LiteralPath (Join-Path $PSHOME 'powershell.exe'); " +
                "if($s.Status -eq 'Valid' -and $s.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -eq 'Microsoft Windows'){exit 0}else{exit 1}\"";
            using (var verifier = Process.Start(new ProcessStartInfo(image, command) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(image) }))
            {
                if (!verifier.WaitForExit(10000))
                    throw new InvalidDataException("The registered system fixture's Microsoft signature verification timed out.");
                if (verifier.ExitCode != 0)
                    throw new InvalidDataException("The registered system fixture's Microsoft signature could not be verified (exit=" + verifier.ExitCode + "): " + verifier.StandardError.ReadToEnd());
            }
        }
    }
}
#endif
