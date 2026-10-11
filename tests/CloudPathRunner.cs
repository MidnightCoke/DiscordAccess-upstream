using System;
using System.IO;
namespace DiscordAccess
{
    internal static class CloudPathRunner
    {
        internal static int Main(string[] args)
        {
            try
            {
                if (args.Length == 2 && args[0] == "--cloud-only")
                {
                    Console.WriteLine("Actual Cloud path: PASS (" + CloudPathChecks.RunReadOnly(args[1]) + " read-only checks)");
                    return 0;
                }
                string package = Path.GetFullPath(args[0]);
                Console.WriteLine("Cloud path safety: PASS (" + CloudPathChecks.Run(package) + " inert checks)");
                if (args.Length > 1)
                    Console.WriteLine("Actual Cloud path: PASS (" + CloudPathChecks.RunReadOnly(args[1]) + " read-only checks)");
                return 0;
            }
            catch (Exception ex) { Console.WriteLine("FAIL " + ex.GetType().Name + ": " + ex.Message); return 1; }
        }
    }
}
