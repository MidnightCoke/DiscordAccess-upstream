using System;
using System.Collections.Generic;

namespace DiscordAccess
{
    internal sealed class DiscordPathOptions
    {
        internal readonly string ExplicitPath;
        internal readonly string[] RemainingArgs;

        private DiscordPathOptions(string path, string[] remaining)
        { ExplicitPath = path; RemainingArgs = remaining; }

        internal static DiscordPathOptions Parse(string[] args)
        {
            var remaining = new List<string>();
            string path = null;
            args = args ?? new string[0];
            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                if (arg == "--discord-path" || (arg != null && arg.StartsWith("--discord-path=", StringComparison.Ordinal)))
                {
                    if (path != null) throw Invalid();
                    if (arg == "--discord-path")
                    {
                        if (++i == args.Length) throw Invalid();
                        path = args[i];
                    }
                    else path = arg.Substring("--discord-path=".Length);
                    if (String.IsNullOrWhiteSpace(path) || path.StartsWith("--", StringComparison.Ordinal) ||
                        path.IndexOf('"') >= 0 || Array.Exists(path.ToCharArray(), Char.IsControl)) throw Invalid();
                }
                else
                {
                    if (arg != null && (arg.StartsWith("--discord-path", StringComparison.OrdinalIgnoreCase) ||
                        arg.StartsWith("--discordpath", StringComparison.OrdinalIgnoreCase))) throw Invalid();
                    remaining.Add(arg);
                }
            }
            return new DiscordPathOptions(path, remaining.ToArray());
        }

        private static ArgumentException Invalid()
        { return new ArgumentException("Discord yolu seçeneği eksik, geçersiz veya tekrarlanmış. Baslat.cmd --discord-path \"D:\\Programlar\\Discord\\Discord.exe\" biçimini kullanın."); }
    }
}
