#if TEST_BUILD
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace DiscordAccess
{
    // Separate CI entry point: do not enter Program.Main, discover Discord,
    // start a controller/process, read a profile or edit Windows settings.
    internal static class EngineConfigExport
    {
        private const int FixturePort = 32123;
        private const string FixtureUser = "engine-smoke-fixture-user";
        private const string FixturePassword = "engine-smoke-fixture-password";

        internal static int Main(string[] args)
        {
            try
            {
                if (!String.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase) ||
                    Environment.OSVersion.Platform != PlatformID.Win32NT || !Environment.Is64BitProcess)
                    throw new InvalidOperationException("This fixture is restricted to GitHub Actions Windows x64.");
                if (args == null || args.Length != 2) throw new ArgumentException("Expected repository and fixture directory.");
                string repository = Path.GetFullPath(args[0]), output = Path.GetFullPath(args[1]);
                string work = Path.Combine(repository, "work");
                if (!Directory.Exists(repository) || !Safety.Under(output, work) || !Safety.NoReparse(repository) || !Safety.NoReparse(output))
                    throw new InvalidOperationException("Fixture output must remain inside the repository work directory.");
                if (Directory.Exists(output)) throw new InvalidOperationException("Fixture output must be a new directory.");
                Program.PackageDirectory = repository;
                Directory.CreateDirectory(output);
                var emitted = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (bool fragment in new[] { false, true })
                {
                    var automatic = DnsOptions.Parse(fragment ? new[] { "--dns=auto", "--dns-record-fragment" } : new[] { "--dns=auto" });
                    DnsOptions[] candidates = automatic.Candidates;
                    if (candidates.Length != 3 || candidates.Any(value => value.Automatic) ||
                        candidates.Select(value => value.Provider).Distinct(StringComparer.Ordinal).Count() != 3)
                        throw new InvalidOperationException("Automatic DNS candidates changed; update this fixture's coverage.");
                    foreach (string provider in new[] { "cloudflare", "cloudflare-ip", "google" })
                    {
                        string key = provider + (fragment ? "-fragment" : "-plain");
                        var fixedOption = DnsOptions.Parse(fragment ? new[] { "--dns=" + provider, "--dns-record-fragment" } : new[] { "--dns=" + provider });
                        DnsOptions selected = candidates.Single(value => value.Provider == provider);
                        string fixedConfig, automaticConfig;
                        // Load keeps the hash-verified engine image leased. No
                        // sing-box command is executed by this exporter.
                        using (var package = Package.Load(fixedOption)) fixedConfig = package.Config(FixtureUser, FixturePassword, FixturePort);
                        using (var package = Package.Load(selected)) automaticConfig = package.Config(FixtureUser, FixturePassword, FixturePort);
                        if (!String.Equals(fixedConfig, automaticConfig, StringComparison.Ordinal))
                            throw new InvalidOperationException("Automatic and explicit resolved DNS configurations differ.");
                        emitted.Add(key, fixedConfig);
                        using (var file = new FileStream(Path.Combine(output, key + ".json"), FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        {
                            byte[] bytes = new UTF8Encoding(false, true).GetBytes(fixedConfig);
                            file.Write(bytes, 0, bytes.Length); file.Flush(true);
                        }
                    }
                }
                if (emitted.Count != 6) throw new InvalidOperationException("Incomplete engine configuration coverage.");
                Console.WriteLine("Exported 6 generated engine configurations; automatic candidates match explicit providers; credentials are synthetic.");
                return 0;
            }
            catch (Exception error)
            {
                // Never print a configuration or a path/credential supplied by
                // the calling environment, even on package verification errors.
                Console.Error.WriteLine("Engine configuration export failed: " + error.GetType().Name + ".");
                return 1;
            }
        }
    }
}
#endif
