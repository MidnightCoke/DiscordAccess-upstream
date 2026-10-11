using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace DiscordAccess
{
    internal static class LifetimeChecks
    {
        private static void Require(bool condition, string message)
        { if (!condition) throw new InvalidOperationException("Owned lifetime: " + message); }

        private static Process StartHelper(NativeSessionJob job, string image, string directory)
        {
            return NativeProcess.Start(job, image,
                "-NoProfile -NonInteractive -Command " + NativeProcess.Quote("[Threading.Thread]::Sleep(30000)"),
                directory, null, null);
        }

        private static void StopOwnedHelper(Process helper, NativeSessionJob job)
        {
            if (helper == null) return;
            // Never enumerate/kill by name: only the process instance created by
            // this fixture, still in its own test job, may be stopped.
            if (!helper.HasExited)
            {
                Require(job.IsMember(helper), "fixture helper left its test job");
                helper.Kill();
            }
            Require(helper.WaitForExit(4000), "fixture helper did not stop");
        }

        internal static void Run()
        {
            const int grace = 600, poll = 30;
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string image = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
            // The unrelated helper has the exact same trusted executable path,
            // but a distinct job. No Discord or connectivity engine is launched.
            using (var ownedJob = new NativeSessionJob())
            using (var unrelatedJob = new NativeSessionJob())
            using (var original = StartHelper(ownedJob, image, system))
            using (var unrelated = StartHelper(unrelatedJob, image, system))
            using (var ended = new ManualResetEvent(false))
            {
                Process replacement = null;
                int notifications = 0;
                using (var lifetime = new OwnedDiscordLifetime(ownedJob, image,
                    delegate { Interlocked.Increment(ref notifications); ended.Set(); }, grace, poll))
                {
                    try
                    {
                        Require(ownedJob.IsMember(original) && !ownedJob.IsMember(unrelated), "test jobs are not isolated");
                        int[] ownedIds = ownedJob.ProcessIds();
                        Require(Array.IndexOf(ownedIds, original.Id) >= 0 && Array.IndexOf(ownedIds, unrelated.Id) < 0,
                            "owned job enumeration included an unrelated process");
                        Require(ownedJob.OwnsImage(original.Id, image, null) && !ownedJob.OwnsImage(unrelated.Id, image, null),
                            "limited query accepted an unrelated process with the same image");
                        Require(!ownedJob.OwnsImage(original.Id, "wrong-image", null) && ownedJob.OwnsImage(original.Id, "wrong-image", image),
                            "limited query image allowlist or updater alternative failed");
                        Require(!ended.WaitOne(grace + 300), "original owned helper did not keep the session alive");
                        replacement = StartHelper(ownedJob, image, system);
                        Require(ownedJob.IsMember(replacement) && !replacement.HasExited, "replacement is not owned");
                        StopOwnedHelper(original, ownedJob);
                        Require(!ownedJob.OwnsImage(original.Id, image, null), "exited process passed limited query");
                        Require(!ended.WaitOne(grace + 300), "original exit ended a session with an owned replacement");
                        StopOwnedHelper(replacement, ownedJob);
                        Require(!unrelated.HasExited, "unrelated helper exited before the ownership assertion");
                        Require(ended.WaitOne(4000), "same-name unrelated helper incorrectly kept the session alive");
                        Require(!unrelated.HasExited && unrelatedJob.IsMember(unrelated), "lifetime monitor touched unrelated helper");
                        Thread.Sleep(poll * 3);
                        Require(Volatile.Read(ref notifications) == 1, "session-ended notification was duplicated");
                    }
                    finally
                    {
                        lifetime.Dispose();
                        if (replacement != null) { StopOwnedHelper(replacement, ownedJob); replacement.Dispose(); }
                        StopOwnedHelper(original, ownedJob);
                        StopOwnedHelper(unrelated, unrelatedJob);
                    }
                }
            }
            // A canceled monitor with no owned processes must stay silent even
            // after its full grace period has elapsed.
            using (var emptyJob = new NativeSessionJob())
            {
                int callbacks = 0;
                var disposed = new OwnedDiscordLifetime(emptyJob, image, delegate { Interlocked.Increment(ref callbacks); }, grace, poll);
                disposed.Dispose();
                Thread.Sleep(grace + poll * 3);
                Require(Volatile.Read(ref callbacks) == 0, "disposed monitor reported session death");
            }
        }
    }
}
