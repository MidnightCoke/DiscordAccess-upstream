#if TEST_BUILD
using System;
using System.Diagnostics;
using System.IO;
namespace DiscordAccess
{
    internal static class ProcessObservationChecks
    {
        internal static int Run()
        {
            int checks = 0;
            Action<bool, string> require = (ok, label) => {
                if (!ok) throw new InvalidOperationException("Process liveness fixture: " + label); checks++;
            };
            string observedImage;
            using (var current = Process.GetCurrentProcess())
            {
                var currentState = NativeProcess.ObserveRunningImage(current.Id, out observedImage);
                require(currentState == NativeProcess.ImageObservation.Running && !String.IsNullOrEmpty(observedImage), "live current process identity");
            }
            require(NativeProcess.ObserveRunningImage(Int32.MaxValue, out observedImage) == NativeProcess.ImageObservation.Gone &&
                observedImage == null, "nonexistent PID is gone rather than unreadable live");
            require(Controller.InstalledObservationBlocksCleanup(NativeProcess.ImageObservation.Unknown, null), "unknown liveness blocks profile edits");
            require(Controller.InstalledObservationBlocksCleanup(NativeProcess.ImageObservation.Running, null), "live unreadable image blocks profile edits");
            require(Controller.InstalledObservationBlocksCleanup(NativeProcess.ImageObservation.Running,
                Path.Combine(Safety.DiscordRoot, "app-1.2.3", "Discord.exe")), "live installed image blocks profile edits");
            require(!Controller.InstalledObservationBlocksCleanup(NativeProcess.ImageObservation.Gone,
                Path.Combine(Safety.DiscordRoot, "app-1.2.3", "Discord.exe")), "an exited installed image does not block recovery");

            int probes = 0;
            require(Controller.WaitForInstalledClientExit(() => { probes++; return false; }, 250) && probes == 1,
                "an already quiet profile requires no unnecessary wait");
            probes = 0;
            var elapsed = Stopwatch.StartNew();
            require(Controller.WaitForInstalledClientExit(() => ++probes <= 3, 1000) && probes == 4 &&
                elapsed.ElapsedMilliseconds < 1000, "transient running snapshots retire before the deadline");
            probes = 0; elapsed.Restart();
            require(!Controller.WaitForInstalledClientExit(() => { probes++; return
                Controller.InstalledObservationBlocksCleanup(NativeProcess.ImageObservation.Unknown, null); }, 125) &&
                probes > 1 && elapsed.ElapsedMilliseconds >= 125 && elapsed.ElapsedMilliseconds < 1000,
                "permanently unknown liveness refuses restore at its bounded deadline");
            elapsed.Restart();
            require(!Controller.WaitForInstalledClientExit(() =>
                Controller.InstalledObservationBlocksCleanup(NativeProcess.ImageObservation.Running,
                    Path.Combine(Safety.DiscordRoot, "app-1.2.3", "Discord.exe")), 125) &&
                elapsed.ElapsedMilliseconds >= 125 && elapsed.ElapsedMilliseconds < 1000,
                "a different persistently live installed client is never killed or ignored");
            elapsed.Restart();
            require(!Controller.WaitForInstalledClientExit(() => { throw new InvalidOperationException("inert query failure"); }, 75) &&
                elapsed.ElapsedMilliseconds >= 75 && elapsed.ElapsedMilliseconds < 1000,
                "query failures stay fail-closed and bounded");

            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string image = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
            using (var job = new NativeSessionJob())
            using (var child = NativeProcess.Start(job, image,
                "-NoProfile -NonInteractive -Command \"[Threading.Thread]::Sleep(15000)\"", system, null, null))
            {
                int id = child.Id;
                // The retained managed handle reproduces enumeration callers
                // still holding a Process object after its actual process exits.
                var pinned = child.Handle;
                var state = NativeProcess.ObserveRunningImage(id, out observedImage);
                require(state == NativeProcess.ImageObservation.Running &&
                    String.Equals(observedImage, image, StringComparison.OrdinalIgnoreCase), "inert live child image");
                require(!Controller.InstalledObservationBlocksCleanup(state, observedImage), "a different live image does not block the installed profile");
                require(job.TerminateAndWait(4000) && child.WaitForExit(1000), "only inert owned child terminated");
                state = NativeProcess.ObserveRunningImage(id, out observedImage);
                require(state == NativeProcess.ImageObservation.Gone && observedImage == null &&
                    !Controller.InstalledObservationBlocksCleanup(state, observedImage), "terminated snapshot PID and retained handle do not cause false recovery conflict");
            }
            return checks;
        }
    }
}
#endif
