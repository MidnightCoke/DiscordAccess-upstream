using System;
using System.IO;
using System.Text;

namespace DiscordAccess
{
    internal static class SessionLog
    {
        private static readonly object Sync = new object();
        internal static void Write(string text)
        {
            lock (Sync)
            {
                try
                {
                    Safety.EnsureStateDirectory();
                    string path = Path.Combine(Safety.StateRoot, "v3", "last-session.log");
                    if (!Safety.NoReparse(path)) return;
                    bool append = File.Exists(path) && new FileInfo(path).Length < 256 * 1024;
                    using (var stream = new FileStream(path, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read))
                    using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
                        writer.WriteLine(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + text);
                }
                catch { /* Logging must not prevent cleanup or connection error reporting. */ }
            }
        }
    }
}
