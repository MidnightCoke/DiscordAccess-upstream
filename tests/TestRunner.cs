using System;
namespace DiscordAccess
{
    internal static class TestRunner
    {
        internal static int Main(string[] args)
        {
            Program.PackageDirectory = System.IO.Path.GetFullPath(System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
            if (args.Length == 1 && args[0] == "--resident-only")
            {
                try
                {
                    Console.WriteLine("Resident launch modes: PASS (" + ResidentOptions.RunOfflineChecks() + " checks)");
                    Console.WriteLine("Resident startup intent queue: PASS (" + ResidentStartupRequests.RunOfflineChecks() + " checks)");
                    Console.WriteLine("Background lifecycle: PASS (" + BackgroundLifecycle.RunOfflineChecks() + " checks)");
                    Console.WriteLine("Ordered Windows startup: PASS (" + StartupCoordinatorChecks.Run(Program.PackageDirectory) + " checks; synthetic registry only)");
                    Console.WriteLine("Console lifecycle: PASS (" + ConsoleHost.RunOfflineChecks() + " checks)");
                    return 0;
                }
                catch (Exception ex)
                { Console.WriteLine("FAIL " + ex.GetType().Name + ": " + ex.Message); return 1; }
            }
            if (args.Length == 2 && args[0] == "--probe-install")
            {
                // Read-only signer/layout verification; no cache, journals,
                // profile reads, process creation or shortcut mutations.
                try
                {
                    var installation = DiscordInstallation.VerifyRoot(args[1]);
                    string image = installation.FindImage();
                    Console.WriteLine("Signed Stable installation probe: PASS");
                    Console.WriteLine("Root: " + installation.Root);
                    Console.WriteLine("Image: " + image);
                    return 0;
                }
                catch (Exception ex)
                {
                    Console.WriteLine("Signed Stable installation probe: FAIL " + ex.GetType().Name + ": " + ex.Message);
                    return 1;
                }
            }
            if (args.Length == 1 && args[0] == "--after-native-output")
            {
                // Execute the independent remaining groups when the operating
                // system refuses a generated NativeOutputChecks child image.
                // This is partial evidence, never a full regression pass.
                try
                {
                    string root = Program.PackageDirectory;
                    Console.WriteLine("Partial regression: independent groups after NativeOutputChecks.");
                    Console.WriteLine("Proxy transport and half-close: PASS (" + ProxyTransportChecks.Run(root) + " checks; loopback fixtures only)");
                    Console.WriteLine("Private message diagnostics report: PASS (" + MessageReport.RunOfflineChecks(root) + " checks; synthetic log only)");
                    Console.WriteLine("Update bridge checks: PASS (" + UpdateBridge.RunOfflineTests() + " checks)");
                    IsolatedDiscord.FixtureCheck(System.IO.Path.Combine(root, "work", "f"));
                    Console.WriteLine("Isolated Discord checks: PASS (synthetic application/profile only)");
                    using (var process = System.Diagnostics.Process.GetCurrentProcess())
                    using (var job = new NativeSessionJob())
                    using (var first = new ProcessGate(process, job, "fixture", null, 1, "fixture", "fixture"))
                    using (var second = new ProcessGate(process, job, "fixture", null, 1, "fixture", "fixture"))
                    {
                        first.Start(); second.Start();
                        if (first.Port == second.Port || first.Port == 0 || second.Port == 0)
                            throw new InvalidOperationException("Concurrent gate port allocation failed.");
                    }
                    Console.WriteLine("Independent dynamic proxy ports: PASS");
                    LifetimeChecks.Run();
                    Console.WriteLine("Owned process relaunch and unrelated-process isolation: PASS");
                    Console.WriteLine("Package diagnostics: PASS (" + PackageChecks.Run(root) + " checks; engine not started)");
                    using (Package.Load()) { }
                    Console.WriteLine("Package engine hash/direct policy validation: PASS (engine not started)");
                    return 0;
                }
                catch (Exception ex)
                {
                    Console.WriteLine("FAIL " + ex.GetType().Name + ": " + ex.Message);
                    var native = ex as System.ComponentModel.Win32Exception;
                    if (native != null) Console.WriteLine("Native error code: " + native.NativeErrorCode);
                    return 1;
                }
            }
            return RegressionChecks.Run(Program.PackageDirectory);
        }
    }
}
