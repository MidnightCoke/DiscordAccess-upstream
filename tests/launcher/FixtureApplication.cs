using System;
using System.Text;

internal static class FixtureApplication
{
    private static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.WriteLine("INERT_LAUNCHER_FIXTURE");
        for (int index = 0; index < args.Length; index++)
            Console.WriteLine("ARG_" + index + "=" + BitConverter.ToString(Encoding.UTF8.GetBytes(args[index])).Replace("-", ""));
        int code;
        return Int32.TryParse(Environment.GetEnvironmentVariable("DISCORDACCESS_LAUNCHER_FIXTURE_EXIT"), out code) ? code : 0;
    }
}
