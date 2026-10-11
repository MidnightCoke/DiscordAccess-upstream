using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

internal static class LauncherChecks
{
    private const string ReleaseUrl = "https://github.com/alpertknn/DiscordAccess/releases/latest";
    private static int checks;

    private static void Assert(bool condition, string detail)
    {
        if (!condition) throw new InvalidOperationException(detail);
        checks++;
    }

    private static string Hex(string value)
    { return BitConverter.ToString(Encoding.UTF8.GetBytes(value)).Replace("-", ""); }

    private static string Capture(StringBuilder output, StringBuilder errors, object sync)
    {
        lock (sync) return " Captured stdout: [" + output.ToString().Trim() + "]; stderr: [" + errors.ToString().Trim() + "]";
    }

    private static string Run(string root, string launcher, string fixtureImage, string name, bool executable,
        bool engine, int fixtureExit, int expectedExit, bool pause, string arguments, string[] expectedArgs)
    {
        string directory = Path.Combine(root, "Türkçe Çalışma (1) " + name);
        Directory.CreateDirectory(directory);
        string batch = Path.Combine(directory, "Baslat.cmd");
        File.Copy(launcher, batch);
        if (executable) File.Copy(fixtureImage, Path.Combine(directory, "DiscordAccess.exe"));
        if (engine)
        {
            Directory.CreateDirectory(Path.Combine(directory, "engine"));
            File.WriteAllText(Path.Combine(directory, "engine", "sing-box.exe"), "inert data; never executed");
        }
        var output = new StringBuilder();
        var errors = new StringBuilder();
        object sync = new object();
        bool launchFailed = false;
        using (var process = new Process())
        {
            process.StartInfo = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"),
                Arguments = "/d /s /c \"\"" + batch + "\"" + (String.IsNullOrEmpty(arguments) ? "" : " " + arguments) + "\"",
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            process.StartInfo.EnvironmentVariables["DISCORDACCESS_LAUNCHER_FIXTURE_EXIT"] = fixtureExit.ToString();
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs data) {
                if (data.Data != null) lock (sync) output.AppendLine(data.Data);
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs data) {
                if (data.Data != null) lock (sync) { errors.AppendLine(data.Data); launchFailed = true; }
            };
            bool started = false;
            try
            {
                process.Start(); started = true;
                process.BeginOutputReadLine(); process.BeginErrorReadLine();
                if (pause)
                {
                    // Wait until guidance is emitted, then prove the batch remains
                    // alive for the user to read it until input arrives.
                    bool guidance = false;
                    var watch = Stopwatch.StartNew();
                    while (watch.ElapsedMilliseconds < 5000 && !process.HasExited)
                    {
                        lock (sync) guidance = output.ToString().Contains(ReleaseUrl) || output.ToString().Contains("baslatilamadi");
                        if (guidance) break;
                        Thread.Sleep(20);
                    }
                    Assert(guidance, name + ": expected error/source guidance was not emitted." + Capture(output, errors, sync));
                    Assert(!process.WaitForExit(150), name + ": error guidance did not pause." + Capture(output, errors, sync));
                    process.StandardInput.WriteLine(); process.StandardInput.Flush();
                }
                if (!process.WaitForExit(5000))
                    throw new InvalidOperationException(name + ": launcher unexpectedly waited or timed out." + Capture(output, errors, sync));
                process.WaitForExit();
                Assert(process.ExitCode == expectedExit, name + ": exit code was not preserved." + Capture(output, errors, sync));
            }
            finally
            {
                // Also clean up on an assertion failure while PAUSE is waiting.
                // This Process object is only the CMD launched for this inert
                // fixture; real application processes are never touched.
                if (started && !process.HasExited) { process.Kill(); process.WaitForExit(); }
            }
        }
        string text, errorText;
        lock (sync) { text = output.ToString(); errorText = errors.ToString(); }
        Assert(!launchFailed, name + ": native fixture launch failed (possibly Application Control); " + errorText);
        if (executable)
        {
            Assert(text.Contains("INERT_LAUNCHER_FIXTURE"), name + ": inert fixture did not run.");
            for (int index = 0; index < expectedArgs.Length; index++)
                Assert(text.Contains("ARG_" + index + "=" + Hex(expectedArgs[index])), name + ": argument " + index + " changed.");
            Assert(!text.Contains("ARG_" + expectedArgs.Length + "="), name + ": unexpected argument added.");
        }
        else
            Assert(!text.Contains("INERT_LAUNCHER_FIXTURE"), name + ": missing executable unexpectedly ran.");
        return text;
    }

    private static int Main(string[] args)
    {
        string repo = Path.GetFullPath(args[0]);
        string work = Path.Combine(repo, "work");
        string root = Path.Combine(work, "launcher-fixtures-" + Guid.NewGuid().ToString("N"));
        string fixtureImage = Path.Combine(work, "launcher", "FixtureApplication.exe");
        string launcher = Path.Combine(repo, "Baslat.cmd");
        string[] none = new string[0];
        try
        {
            Directory.CreateDirectory(root);
            string text = Run(root, launcher, fixtureImage, "missing EXE", false, false, 0, 2, true, "", none);
            Assert(text.Contains(ReleaseUrl) && text.Contains("kaynak kodudur"), "Missing EXE did not explain the source ZIP.");
            Assert(text.Contains("powershell -NoProfile -File scripts\\Fetch-Engine.ps1") && text.Contains("Build.cmd"), "Missing EXE did not give explicit developer preparation steps.");
            Assert(!text.Contains("not recognized"), "Missing EXE produced the old unknown-command error.");
            text = Run(root, launcher, fixtureImage, "normal success", true, true, 0, 0, false, "", none);
            Assert(!text.Contains(ReleaseUrl) && !text.Contains("baslatilamadi"), "Successful runtime gained extra guidance.");
            string selected = @"D:\Oyunlar\Türkçe Discord\Discord.exe";
            text = Run(root, launcher, fixtureImage, "quoted arguments", true, true, 0, 0, false,
                "--discord-path \"" + selected + "\" --dns=cloudflare", new[] { "--discord-path", selected, "--dns=cloudflare" });
            Assert(!text.Contains(ReleaseUrl), "Successful custom path gained extra guidance.");
            foreach (string option in new[] { "--help", "-h", "/?", "--restore" })
            {
                text = Run(root, launcher, fixtureImage, "no engine " + option.Replace('/', '_').Replace('?', '_'), true, false, 0, 0, false, option, new[] { option });
                Assert(!text.Contains("Motor dosyasi") && !text.Contains(ReleaseUrl), "Successful help/restore required the engine.");
            }
            text = Run(root, launcher, fixtureImage, "help after option", true, false, 0, 0, false,
                "--discord-path \"" + selected + "\" --help", new[] { "--discord-path", selected, "--help" });
            Assert(!text.Contains("Motor dosyasi"), "Any-position help gained missing-engine noise.");
            text = Run(root, launcher, fixtureImage, "failure missing engine", true, false, 1, 1, true, "", none);
            Assert(text.Contains("Motor dosyasi engine\\sing-box.exe bulunamadi.") && text.Contains(ReleaseUrl), "Failure did not identify the missing engine and ready ZIP.");
            Assert(text.Contains("powershell -NoProfile -File scripts\\Fetch-Engine.ps1") && text.Contains("Build.cmd"), "Missing engine omitted preparation steps.");
            text = Run(root, launcher, fixtureImage, "invalid arguments", true, false, 64, 64, true, "--bad-option", new[] { "--bad-option" });
            Assert(!text.Contains("Motor dosyasi") && !text.Contains(ReleaseUrl), "Invalid arguments were misleadingly described as missing engine.");
            text = Run(root, launcher, fixtureImage, "failure with engine", true, true, 1, 1, true, "", none);
            Assert(!text.Contains("Motor dosyasi") && !text.Contains(ReleaseUrl), "Existing engine gained incorrect dependency guidance.");
            text = Run(root, launcher, fixtureImage, "cancel", true, false, 130, 130, false, "", none);
            Assert(!text.Contains("Motor dosyasi") && !text.Contains("baslatilamadi") && !text.Contains(ReleaseUrl), "Exit130 paused or gained error guidance.");
            Console.WriteLine("Launcher fixtures: PASS (" + checks + " checks; inert console only, no Discord/profile/network)");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Launcher fixtures: FAIL " + error.Message);
            return 1;
        }
        finally
        {
            string absoluteRoot = Path.GetFullPath(root);
            if (!absoluteRoot.StartsWith(Path.GetFullPath(work).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Fixture cleanup escaped repository work.");
            if (Directory.Exists(absoluteRoot) && (File.GetAttributes(absoluteRoot) & FileAttributes.ReparsePoint) == 0)
                Directory.Delete(absoluteRoot, true);
        }
    }
}
