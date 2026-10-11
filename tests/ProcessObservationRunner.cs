using System;
namespace DiscordAccess
{
    internal static class ProcessObservationRunner
    {
        internal static int Main()
        {
            try { Console.WriteLine("Process snapshot liveness: PASS (" + ProcessObservationChecks.Run() + " inert checks)"); return 0; }
            catch (Exception ex) { Console.WriteLine("FAIL " + ex.GetType().Name + ": " + ex.Message); return 1; }
        }
    }
}
