using System;
using System.Collections.Generic;
using System.Linq;

namespace DiscordAccess
{
    internal sealed class ResidentOptions
    {
        internal readonly bool Background, Startup;
        internal readonly string[] Arguments;
        private ResidentOptions(bool background, bool startup, string[] arguments)
        { Background = background; Startup = startup; Arguments = arguments; }

        internal static bool ConsoleRequested(string[] arguments)
        {
            return (arguments ?? new string[0]).Any(value => value == "--console" || value == "--help" || value == "-h" ||
                value == "/?" || value == "--restore" || value == "--verify-package" || value == "--self-test");
        }

        internal static ResidentOptions Parse(string[] arguments)
        {
            bool tray = false, console = false, startup = false;
            var remaining = new List<string>();
            foreach (string argument in arguments ?? new string[0])
            {
                if (argument == "--tray") { if (tray) throw Invalid(); tray = true; }
                else if (argument == "--console") { if (console) throw Invalid(); console = true; }
                else if (argument == "--startup") { if (startup) throw Invalid(); startup = true; }
                else remaining.Add(argument);
            }
            if ((console && (tray || startup)) || (startup && ConsoleRequested(remaining.ToArray()))) throw Invalid();
            bool background = !console && !ConsoleRequested(remaining.ToArray());
            return new ResidentOptions(background, startup, remaining.ToArray());
        }

        private static ArgumentException Invalid()
        { return new ArgumentException("Başlatma seçeneği geçersiz: --tray veya --console kullanın. --startup yalnız Windows açılışı içindir."); }

        internal static int RunOfflineChecks()
        {
            int count = 0;
            Action<bool> require = value => { if (!value) throw new InvalidOperationException("Resident options fixture failed."); count++; };
            require(Parse(new string[0]).Background);
            require(Parse(new[] { "--tray" }).Background);
            require(!Parse(new[] { "--console" }).Background);
            require(Parse(new[] { "--startup" }).Background && Parse(new[] { "--startup" }).Startup);
            foreach (string argument in new[] { "--help", "-h", "/?", "--restore", "--verify-package", "--self-test" })
                require(!Parse(new[] { argument }).Background);
            var selected = Parse(new[] { "--tray", "--dns=google", "--dns-record-fragment" });
            require(selected.Arguments.SequenceEqual(new[] { "--dns=google", "--dns-record-fragment" }));
            foreach (string[] invalid in new[] { new[] { "--console", "--tray" }, new[] { "--console", "--startup" },
                new[] { "--tray", "--tray" }, new[] { "--startup", "--restore" }, new[] { "--startup", "--startup" } })
            {
                bool rejected = false; try { Parse(invalid); } catch (ArgumentException) { rejected = true; }
                require(rejected);
            }
            return count;
        }
    }
}
