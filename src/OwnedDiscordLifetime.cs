using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace DiscordAccess
{
    // A module update may replace the original process. Only signed-image-path
    // processes within this session's kernel job keep the connection alive.
    internal sealed class OwnedDiscordLifetime : IDisposable
    {
        private readonly NativeSessionJob job;
        private readonly string image;
        private readonly Action ended;
        private readonly int graceMilliseconds;
        private readonly Stopwatch elapsed = Stopwatch.StartNew();
        private readonly Timer timer;
        private long lastSeen;
        private int polling, disposed;
        internal OwnedDiscordLifetime(NativeSessionJob job, string image, Action ended, int graceMilliseconds = 10000, int pollMilliseconds = 1000)
        {
            if (job == null) throw new ArgumentNullException("job");
            if (String.IsNullOrEmpty(image)) throw new ArgumentNullException("image");
            if (ended == null) throw new ArgumentNullException("ended");
            if (graceMilliseconds < 1 || pollMilliseconds < 1) throw new ArgumentOutOfRangeException("graceMilliseconds");
            this.job = job; this.image = image; this.ended = ended;
            this.graceMilliseconds = graceMilliseconds;
            timer = new Timer(Poll, null, Timeout.Infinite, Timeout.Infinite);
            timer.Change(pollMilliseconds, pollMilliseconds);
        }
        private void Poll(object unused)
        {
            if (Volatile.Read(ref disposed) != 0 || Interlocked.Exchange(ref polling, 1) != 0) return;
            try
            {
                bool found = false;
                foreach (int processId in job.ProcessIds())
                {
                    if (job.OwnsImage(processId, image, null)) { found = true; break; }
                }
                if (found) lastSeen = elapsed.ElapsedMilliseconds;
                else if (elapsed.ElapsedMilliseconds - lastSeen >= graceMilliseconds &&
                    Interlocked.CompareExchange(ref disposed, 1, 0) == 0)
                {
                    // External disposal suppresses a queued poll's callback.
                    // The winner of this transition owns the single notification.
                    timer.Dispose();
                    ended();
                }
            }
            catch { /* A transient enumeration failure must not close unrelated work. */ }
            finally { Volatile.Write(ref polling, 0); }
        }
        internal static bool ShouldEnd(long now, long lastOwnedProcess)
        { return now - lastOwnedProcess >= 10000; }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) == 0) timer.Dispose();
        }
    }
}
