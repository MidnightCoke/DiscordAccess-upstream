using System;
using System.Diagnostics;
using System.Threading;

namespace DiscordAccess
{
    // Installed immediately after the resident mutex is won. Startup requests
    // arriving during recovery/discovery retain only one pending bit, never a
    // command, path, process identity or credential. The host still validates
    // its startup preference before opening the official client.
    internal sealed class ResidentStartupRequests : IDisposable
    {
        private readonly object sync = new object();
        private IDisposable signal;
        private Action handler;
        private bool pending, dispatching, disposed;

        internal ResidentStartupRequests() : this(ManualLaunchSignal.ListenStartup) { }

        private ResidentStartupRequests(Func<Action, IDisposable> register)
        {
            if (register == null) throw new ArgumentNullException("register");
            signal = register(Receive);
            if (signal == null) throw new InvalidOperationException("Otomatik başlatma dinleyicisi oluşturulamadı.");
        }

        internal void Listen(Action callback)
        {
            if (callback == null) throw new ArgumentNullException("callback");
            lock (sync)
            {
                if (disposed) throw new ObjectDisposedException("ResidentStartupRequests");
                if (handler != null) throw new InvalidOperationException("Otomatik başlatma işleyicisi zaten kurulu.");
                handler = callback;
                ScheduleLocked();
            }
        }

        private void Receive()
        {
            lock (sync)
            {
                if (disposed) return;
                pending = true;
                ScheduleLocked();
            }
        }

        private void ScheduleLocked()
        {
            if (disposed || dispatching || !pending || handler == null) return;
            dispatching = true;
            if (!ThreadPool.QueueUserWorkItem(Dispatch)) dispatching = false;
        }

        private void Dispatch(object ignored)
        {
            Action callback;
            lock (sync)
            {
                if (disposed || !pending || handler == null)
                { dispatching = false; return; }
                pending = false;
                callback = handler;
            }
            // The registered event callback only sets a bit. It never waits for
            // this handler or for a controller/network operation. A host handler
            // posts its work to its own event loop and returns immediately.
            try { callback(); } catch { }
            finally
            {
                lock (sync)
                {
                    dispatching = false;
                    ScheduleLocked();
                }
            }
        }

        public void Dispose()
        {
            IDisposable listener;
            lock (sync)
            {
                if (disposed) return;
                disposed = true; pending = false; handler = null;
                listener = signal; signal = null;
            }
            // Do not wait on queued/running host callbacks: during Windows
            // shutdown the UI loop may already have ended. Stale dispatches see
            // disposed before invoking any new callback.
            if (listener != null) listener.Dispose();
        }

#if TEST_BUILD
        internal static int RunOfflineChecks()
        {
            int checks = 0;
            Action<bool, string> require = (ok, message) =>
            { if (!ok) throw new InvalidOperationException("Resident startup queue: " + message); checks++; };
            string fixture = Guid.NewGuid().ToString("N"), response;
            require(!ManualLaunchSignal.RequestStartupFixture(fixture, out response), "absent fixture signal was accepted");
            using (var delivered = new AutoResetEvent(false))
            using (var requests = new ResidentStartupRequests(callback => ManualLaunchSignal.ListenStartupFixture(fixture, callback)))
            {
                require(ManualLaunchSignal.RequestStartupFixture(fixture, out response), "fixture event was not signaled");
                require(SpinWait.SpinUntil(() => { lock (requests.sync) return requests.pending; }, 2000),
                    "early startup request was lost before a handler existed");
                // Test the queue itself deterministically after the real event
                // delivered once. A bounded pending bit coalesces any burst.
                for (int i = 0; i < 500; i++) requests.Receive();
                int callbacks = 0;
                requests.Listen(() => { Interlocked.Increment(ref callbacks); delivered.Set(); });
                require(delivered.WaitOne(2000) && Volatile.Read(ref callbacks) == 1,
                    "early burst was not delivered once after Listen");
                require(!delivered.WaitOne(100), "early burst created additional queued callbacks");
                bool duplicate = false;
                try { requests.Listen(() => { }); } catch (InvalidOperationException) { duplicate = true; }
                require(duplicate, "handler could be replaced after installation");
                require(ManualLaunchSignal.RequestStartupFixture(fixture, out response) && delivered.WaitOne(2000) &&
                    Volatile.Read(ref callbacks) == 2, "later startup event was not delivered");
            }
            require(!ManualLaunchSignal.RequestStartupFixture(fixture, out response), "disposed event remained available");

            fixture = Guid.NewGuid().ToString("N");
            using (var entered = new ManualResetEvent(false))
            using (var release = new ManualResetEvent(false))
            using (var second = new ManualResetEvent(false))
            using (var requests = new ResidentStartupRequests(callback => ManualLaunchSignal.ListenStartupFixture(fixture, callback)))
            {
                int callbacks = 0;
                requests.Listen(() => {
                    if (Interlocked.Increment(ref callbacks) == 1) { entered.Set(); release.WaitOne(); }
                    else second.Set();
                });
                requests.Receive();
                require(entered.WaitOne(2000), "blocking fixture callback did not begin");
                var elapsed = Stopwatch.StartNew();
                for (int i = 0; i < 500; i++) requests.Receive();
                require(elapsed.ElapsedMilliseconds < 1000 && Volatile.Read(ref callbacks) == 1,
                    "receipt waited on the handler or dispatched a parallel callback");
                release.Set();
                require(second.WaitOne(2000) && Volatile.Read(ref callbacks) == 2,
                    "in-flight burst was not coalesced into one pending callback");
            }

            fixture = Guid.NewGuid().ToString("N");
            int afterDisposal = 0;
            var disposedQueue = new ResidentStartupRequests(callback => ManualLaunchSignal.ListenStartupFixture(fixture, callback));
            disposedQueue.Receive(); disposedQueue.Dispose(); disposedQueue.Dispose();
            disposedQueue.Receive();
            bool refused = false;
            try { disposedQueue.Listen(() => Interlocked.Increment(ref afterDisposal)); }
            catch (ObjectDisposedException) { refused = true; }
            require(refused && afterDisposal == 0, "disposed queue delivered a retained request");

            fixture = Guid.NewGuid().ToString("N");
            using (var entered = new ManualResetEvent(false))
            using (var release = new ManualResetEvent(false))
            using (var finished = new ManualResetEvent(false))
            {
                int callbacks = 0;
                var requests = new ResidentStartupRequests(callback => ManualLaunchSignal.ListenStartupFixture(fixture, callback));
                requests.Listen(() => {
                    Interlocked.Increment(ref callbacks); entered.Set(); release.WaitOne(); finished.Set();
                });
                try
                {
                    requests.Receive();
                    require(entered.WaitOne(2000), "dispose fixture callback did not begin");
                    requests.Receive();
                    var elapsed = Stopwatch.StartNew(); requests.Dispose();
                    require(elapsed.ElapsedMilliseconds < 1000, "Dispose waited on a host callback");
                    release.Set();
                    require(finished.WaitOne(2000) && Volatile.Read(ref callbacks) == 1,
                        "pending callback ran after disposal");
                }
                finally { release.Set(); requests.Dispose(); }
            }
            return checks;
        }
#endif
    }
}
