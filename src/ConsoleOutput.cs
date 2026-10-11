using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Linq;
using System.Threading;

namespace DiscordAccess
{
    // Producers never write to disk or the console. Each sink has its own
    // bounded queue/thread, so a selected console or slow disk cannot hold up
    // CONNECT forwarding, controller operations, or session cleanup.
    internal sealed class ConsoleOutput : IDisposable
    {
        private readonly Sink files, screen;
        internal ConsoleOutput(Action<string> writeFile, Action<string> writeScreen)
        {
            files = new Sink(writeFile, 512, "DiscordAccess file log");
            screen = new Sink(writeScreen, 32, "DiscordAccess console output");
        }
        internal void File(string message) { files.Enqueue(Clean(message)); }
        internal void Show(string message)
        {
            string clean = Clean(message);
            files.Enqueue(clean); screen.Enqueue(clean);
        }
        internal static string Clean(string text)
        {
            if (String.IsNullOrEmpty(text)) return "";
            string clean = new string(text.Take(1000).Select(character => Char.IsControl(character) ? ' ' : character).ToArray()).Trim();
            return text.Length > 1000 ? clean + "…" : clean;
        }
        public void Dispose()
        {
            // Never join a thread blocked in WriteConsole/WriteFile forever.
            files.Stop(); screen.Stop(); files.Join(150); screen.Join(150);
        }
        private sealed class Sink
        {
            private readonly BlockingCollection<string> queue;
            private readonly Action<string> write;
            private readonly Thread thread;
            private int dropped, stopped;
            internal int Count { get { return queue.Count; } }
            internal Sink(Action<string> writer, int capacity, string name)
            {
                write = writer; queue = new BlockingCollection<string>(capacity);
                thread = new Thread(Drain) { IsBackground = true, Name = name };
                thread.Start();
            }
            internal void Enqueue(string message)
            {
                if (Volatile.Read(ref stopped) != 0 || String.IsNullOrEmpty(message)) return;
                try { if (!queue.TryAdd(message)) Interlocked.Increment(ref dropped); }
                catch (InvalidOperationException) { }
            }
            private void Emit(string text) { try { write(text); } catch { } }
            private void Drain()
            {
                foreach (string item in queue.GetConsumingEnumerable())
                {
                    int skipped = Interlocked.Exchange(ref dropped, 0);
                    if (skipped > 0) Emit("Yoğun kayıt nedeniyle " + skipped + " tanılama satırı atlandı.");
                    Emit(item);
                }
            }
            internal void Stop()
            {
                if (Interlocked.Exchange(ref stopped, 1) == 0) queue.CompleteAdding();
            }
            internal bool Join(int milliseconds) { return thread.Join(milliseconds); }
        }

        internal static int RunOfflineChecks()
        {
            int checks = 0;
            using (var releaseScreen = new ManualResetEvent(false))
            using (var screenEntered = new ManualResetEvent(false))
            using (var fileReached = new ManualResetEvent(false))
            {
                var output = new ConsoleOutput(line => { if (line == "file-progress") fileReached.Set(); },
                    line => { screenEntered.Set(); releaseScreen.WaitOne(); });
                try
                {
                    output.Show("hold console");
                    Require(screenEntered.WaitOne(2000), "Console sink fixture did not start.");
                    var producer = new Thread(() => { for (int i = 0; i < 2000; i++) output.Show("bounded fixture"); output.File("file-progress"); });
                    producer.IsBackground = true; producer.Start();
                    Require(producer.Join(1000), "Blocked console stalled diagnostic producer."); checks++;
                    Require(output.screen.Count <= 32 && output.files.Count <= 512, "Output queues exceeded their bounds."); checks++;
                    // The stress run can fill the file queue too; retry the fixed
                    // marker after the independent file sink catches up.
                    var watch = Stopwatch.StartNew();
                    while (!fileReached.WaitOne(10) && watch.ElapsedMilliseconds < 2000) output.File("file-progress");
                    Require(fileReached.WaitOne(0), "Blocked console stalled the file worker."); checks++;
                    watch.Restart(); output.Dispose();
                    Require(watch.ElapsedMilliseconds < 1500, "Blocked console prevented bounded shutdown."); checks++;
                }
                finally { releaseScreen.Set(); output.Dispose(); output.screen.Join(2000); output.files.Join(2000); }
            }
            using (var releaseFile = new ManualResetEvent(false))
            using (var fileEntered = new ManualResetEvent(false))
            using (var screenReached = new ManualResetEvent(false))
            {
                var output = new ConsoleOutput(line => { fileEntered.Set(); releaseFile.WaitOne(); }, line => screenReached.Set());
                try
                {
                    output.File("hold disk"); Require(fileEntered.WaitOne(2000), "File sink fixture did not start.");
                    var producer = new Thread(() => { for (int i = 0; i < 1000; i++) output.File("network trace"); output.Show("status"); });
                    producer.IsBackground = true; producer.Start();
                    Require(producer.Join(1000) && screenReached.WaitOne(1000), "Blocked file sink stalled producer or screen."); checks++;
                    Require(output.files.Count <= 512, "Blocked file log grew without bound."); checks++;
                }
                finally { releaseFile.Set(); output.Dispose(); output.screen.Join(2000); output.files.Join(2000); }
            }
            using (var received = new ManualResetEvent(false))
            {
                int consoleLines = 0;
                using (var output = new ConsoleOutput(line => received.Set(), line => Interlocked.Increment(ref consoleLines)))
                {
                    output.File("Proxy: fixture trace");
                    Require(received.WaitOne(2000) && Volatile.Read(ref consoleLines) == 0, "Network trace leaked into console output."); checks++;
                }
            }
            Require(!Clean("bad\x1b[31m\r\ntext\0").Any(Char.IsControl), "Console output allowed control characters."); checks++;
            return checks;
        }
        private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    }
}
