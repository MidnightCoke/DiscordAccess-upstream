using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace DiscordAccess
{
    // Host-independent lifecycle: no window, registry, process enumeration or
    // network operation is performed here. The controller supplies the same
    // operations used by the console host and owns the engine exclusively.
    internal sealed class BackgroundLifecycle
    {
        internal sealed class Operations
        {
            internal Func<Task> Connect, Disconnect;
            internal Func<Task<string>> OpenDiscord;
            internal Action Dispose;
            internal Func<bool> Ready, Running;
        }

        private readonly object sync = new object();
        private readonly Operations operations;
        private readonly Action<bool, string> changed;
        private TaskCompletionSource<object> prepared, connected;
        private TaskCompletionSource<string> opening;
        private TaskCompletionSource<bool> shutdown;
        private bool ready, stopping, startupRequested, startupConsumed;
        private int disposeStarted;

        internal BackgroundLifecycle(Operations operations, Action<bool, string> changed = null)
        {
            if (operations == null || operations.Connect == null || operations.Disconnect == null ||
                operations.OpenDiscord == null || operations.Dispose == null || operations.Ready == null || operations.Running == null)
                throw new ArgumentException("Arka plan oturumunun işlemleri eksik.", "operations");
            this.operations = operations; this.changed = changed;
        }

        internal bool Ready
        {
            get
            {
                lock (sync)
                {
                    if (!ready || stopping) return false;
                    try { return operations.Ready(); } catch { return false; }
                }
            }
        }
        internal bool Stopping { get { lock (sync) return stopping; } }

        // Concurrent requests share preparation. An autorun request that joins
        // manual preparation is retained, but ordinary preparation never opens
        // Discord. The startup request is consumed at most once.
        internal Task ConnectAsync(bool startupLaunch)
        {
            bool start, lateStartup;
            Task result;
            lock (sync)
            {
                if (stopping) return Canceled<object>();
                if (startupLaunch) startupRequested = true;
                start = PrepareLocked();
                result = connected.Task;
                lateStartup = !start && ready && connected.Task.Status == TaskStatus.RanToCompletion &&
                    startupRequested && !startupConsumed;
            }
            if (start) StartPreparation();
            if (lateStartup) return Observe(Task.Run((Func<Task>)LaunchStartupAsync));
            return result;
        }

        // Icon clicks while connecting or opening share one request. This does
        // not launch a second copy simply because another callback arrived.
        internal Task<string> OpenAsync()
        {
            bool start;
            TaskCompletionSource<string> request;
            Task preparation;
            lock (sync)
            {
                if (stopping) return Canceled<string>();
                if (opening != null) return opening.Task;
                start = PrepareLocked();
                request = opening = new TaskCompletionSource<string>();
                Observe(request.Task);
                preparation = prepared.Task;
            }
            if (start) StartPreparation();
            Observe(Task.Run(() => OpenCoreAsync(request, preparation)));
            return request.Task;
        }

        private bool PrepareLocked()
        {
            if (connected != null) return false;
            prepared = new TaskCompletionSource<object>();
            connected = new TaskCompletionSource<object>();
            Observe(prepared.Task); Observe(connected.Task);
            return true;
        }

        private void StartPreparation() { Observe(Task.Run((Func<Task>)ConnectCoreAsync)); }

        private async Task ConnectCoreAsync()
        {
            try
            {
                Publish(false, "Bağlanıyor...");
                Task operation;
                lock (sync)
                {
                    if (stopping) throw new OperationCanceledException();
                    operation = operations.Connect();
                    if (operation == null) throw new InvalidOperationException("Bağlantı işlemi alınamadı.");
                }
                await operation.ConfigureAwait(false);
                lock (sync)
                {
                    if (stopping) throw new OperationCanceledException();
                    if (!operations.Ready()) throw new InvalidOperationException("Bağlantı hazır duruma gelemedi.");
                    ready = true;
                }
                prepared.TrySetResult(null);
                Publish(true, "Bağlantı hazır.");
                await LaunchStartupAsync().ConfigureAwait(false);
                connected.TrySetResult(null);
            }
            catch (Exception error)
            {
                prepared.TrySetException(error);
                bool active;
                lock (sync) active = ready && !stopping;
                Publish(active, active ? "Bağlantı hazır; Discord açılamadı." : "Bağlantı kurulamadı.");
                connected.TrySetException(error);
            }
        }

        private async Task LaunchStartupAsync()
        {
            lock (sync)
            {
                if (stopping || !ready || !startupRequested || startupConsumed) return;
                startupConsumed = true;
                // An unknown or failed process observation must not grant a
                // launch. A real observation is supplied by the controller.
                if (operations.Running()) return;
            }
            await OpenAsync().ConfigureAwait(false);
        }

        private async Task OpenCoreAsync(TaskCompletionSource<string> request, Task preparation)
        {
            string result = null;
            Exception failure = null;
            try
            {
                await preparation.ConfigureAwait(false);
                Task<string> operation = null;
                lock (sync)
                {
                    if (stopping) throw new OperationCanceledException();
                    if (!ready || !operations.Ready()) throw new UserActionException("Bağlantı hazır değil.");
                    // A manual click joining startup preparation satisfies the
                    // same launch intent. Even a very fast open must not leave
                    // a second startup launch after its coalescing slot clears.
                    if (startupRequested) startupConsumed = true;
                    if (operations.Running()) result = "Discord zaten açık.";
                    else
                    {
                        operation = operations.OpenDiscord();
                        if (operation == null) throw new InvalidOperationException("Discord açılış işlemi alınamadı.");
                    }
                }
                if (operation != null) result = await operation.ConfigureAwait(false);
            }
            catch (Exception error) { failure = error; }
            finally
            {
                // Complete the public task before clearing the coalescing
                // slot, so there is no interval admitting a parallel opener.
                lock (sync)
                {
                    if (failure == null) request.TrySetResult(result ?? "Discord açılış isteği gönderildi.");
                    else request.TrySetException(failure);
                    if (opening == request) opening = null;
                }
            }
        }

        // Disconnect is deliberately allowed to run concurrently with Connect:
        // Controller.DisconnectAsync cancels its connection token before waiting
        // on the controller semaphore. Dispose is deferred until those writers
        // finish, and all waits share this single, bounded budget.
        internal Task<bool> ShutdownAsync(int timeoutMilliseconds = 15000)
        {
            if (timeoutMilliseconds < 1 || timeoutMilliseconds > 15000)
                throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            Task connect, open;
            TaskCompletionSource<bool> completion;
            var elapsed = Stopwatch.StartNew();
            lock (sync)
            {
                if (shutdown != null) return shutdown.Task;
                stopping = true; ready = false;
                completion = shutdown = new TaskCompletionSource<bool>();
                connect = connected == null ? null : connected.Task;
                open = opening == null ? null : opening.Task;
            }
            Observe(Task.Run(() => ShutdownCoreAsync(completion, connect, open, elapsed, timeoutMilliseconds)));
            return completion.Task;
        }

        private async Task ShutdownCoreAsync(TaskCompletionSource<bool> completion, Task connect, Task open, Stopwatch elapsed, int budget)
        {
            try
            {
                Task disconnect = Task.Run(() => operations.Disconnect());
                Observe(disconnect);
                if (!await WithinAsync(disconnect, elapsed, budget).ConfigureAwait(false))
                { completion.TrySetResult(false); return; }
                Exception cleanupFailure = null;
                try { await disconnect.ConfigureAwait(false); } catch (Exception error) { cleanupFailure = error; }
                foreach (Task operation in new[] { connect, open })
                {
                    if (operation == null) continue;
                    if (!await WithinAsync(operation, elapsed, budget).ConfigureAwait(false))
                    { completion.TrySetResult(false); return; }
                    // An operation canceled by disconnect, or the original
                    // connection failure, does not prevent safe disposal.
                    try { await operation.ConfigureAwait(false); } catch { }
                }
                if (Interlocked.Exchange(ref disposeStarted, 1) == 0)
                {
                    Task disposing = Task.Run(operations.Dispose);
                    Observe(disposing);
                    if (!await WithinAsync(disposing, elapsed, budget).ConfigureAwait(false))
                    { completion.TrySetResult(false); return; }
                    try { await disposing.ConfigureAwait(false); }
                    catch (Exception error) { if (cleanupFailure == null) cleanupFailure = error; }
                }
                Publish(false, cleanupFailure == null ? "Bağlantı kapatıldı." : "Kurtarma kaydı korundu; Discord ayarları tamamen geri alınamadı.");
                if (cleanupFailure != null) completion.TrySetException(cleanupFailure);
                else completion.TrySetResult(true);
            }
            catch (Exception error) { completion.TrySetException(error); }
        }

        private static async Task<bool> WithinAsync(Task operation, Stopwatch elapsed, int budget)
        {
            if (operation.IsCompleted) return true;
            int remaining = (int)Math.Max(0L, (long)budget - elapsed.ElapsedMilliseconds);
            if (remaining == 0) return false;
            Task winner = await Task.WhenAny(operation, Task.Delay(remaining)).ConfigureAwait(false);
            return winner == operation || operation.IsCompleted;
        }

        private void Publish(bool active, string message)
        { if (changed != null) try { changed(active, message); } catch { } }
        private static Task<T> Canceled<T>()
        { var result = new TaskCompletionSource<T>(); result.SetCanceled(); return result.Task; }
        private static Task Observe(Task task)
        {
            task.ContinueWith(failed => { var ignored = failed.Exception; }, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
            return task;
        }

#if TEST_BUILD
        internal static int RunOfflineChecks()
        {
            int checks = 0;
            Action<bool, string> require = (ok, message) =>
            { if (!ok) throw new InvalidOperationException("Background lifecycle: " + message); checks++; };
            Func<Task> complete = () => Task.FromResult(0);

            int opens = 0, disconnects = 0, disposes = 0;
            bool active = false;
            var manual = new BackgroundLifecycle(new Operations {
                Connect = () => { active = true; return complete(); },
                Disconnect = () => { active = false; disconnects++; return complete(); },
                OpenDiscord = () => { opens++; return Task.FromResult("opened"); },
                Ready = () => active, Running = () => false, Dispose = () => disposes++ });
            manual.ConnectAsync(false).GetAwaiter().GetResult();
            require(manual.Ready && opens == 0, "manual preparation launched Discord");
            require(manual.ShutdownAsync().GetAwaiter().GetResult() && disconnects == 1 && disposes == 1 && !manual.Ready,
                "manual shutdown was not complete");
            require(manual.ShutdownAsync().GetAwaiter().GetResult() && disconnects == 1 && disposes == 1,
                "duplicate shutdown repeated cleanup");
            require(manual.OpenAsync().IsCanceled && manual.ConnectAsync(true).IsCanceled,
                "stopped session accepted a new operation");

            var preparation = new TaskCompletionSource<object>();
            var openingOperation = new TaskCompletionSource<string>();
            using (var entered = new ManualResetEvent(false))
            {
                active = false; opens = 0;
                var deferred = new BackgroundLifecycle(new Operations {
                    Connect = () => { entered.Set(); return preparation.Task; },
                    Disconnect = () => { active = false; return complete(); },
                    OpenDiscord = () => { Interlocked.Increment(ref opens); return openingOperation.Task; },
                    Ready = () => active, Running = () => false, Dispose = () => { } });
                Task connection = deferred.ConnectAsync(false);
                require(entered.WaitOne(2000), "fixture connect did not start");
                Task<string> first = deferred.OpenAsync(), second = deferred.OpenAsync();
                require(Object.ReferenceEquals(first, second) && opens == 0, "preparation clicks were not coalesced");
                active = true; preparation.SetResult(null);
                require(SpinWait.SpinUntil(() => Volatile.Read(ref opens) == 1, 2000), "deferred open did not follow preparation");
                require(Object.ReferenceEquals(first, deferred.OpenAsync()) && opens == 1, "in-flight launch was duplicated");
                openingOperation.SetResult("opened");
                require(first.GetAwaiter().GetResult() == "opened", "deferred open result was lost");
                connection.GetAwaiter().GetResult();
                require(deferred.ShutdownAsync().GetAwaiter().GetResult(), "deferred fixture cleanup failed");
            }

            active = false; opens = 0;
            var startup = new BackgroundLifecycle(new Operations {
                Connect = () => { active = true; return complete(); }, Disconnect = complete,
                OpenDiscord = () => { require(active, "startup opened before readiness"); opens++; return Task.FromResult("opened"); },
                Ready = () => active, Running = () => false, Dispose = () => { } });
            startup.ConnectAsync(true).GetAwaiter().GetResult();
            startup.ConnectAsync(true).GetAwaiter().GetResult();
            require(opens == 1, "startup request launched more than once");
            require(startup.ShutdownAsync().GetAwaiter().GetResult(), "startup fixture cleanup failed");

            preparation = new TaskCompletionSource<object>();
            using (var entered = new ManualResetEvent(false))
            {
                active = false; opens = 0;
                var merged = new BackgroundLifecycle(new Operations {
                    Connect = () => { entered.Set(); return preparation.Task; }, Disconnect = complete,
                    OpenDiscord = () => { opens++; return Task.FromResult("opened"); },
                    Ready = () => active, Running = () => false, Dispose = () => { } });
                Task first = merged.ConnectAsync(false);
                require(entered.WaitOne(2000), "merged startup fixture did not begin preparation");
                Task joining = merged.ConnectAsync(true);
                Task<string> click = merged.OpenAsync();
                require(Object.ReferenceEquals(first, joining) && opens == 0, "startup did not join existing preparation");
                active = true; preparation.SetResult(null);
                joining.GetAwaiter().GetResult();
                click.GetAwaiter().GetResult();
                require(opens == 1, "joined startup and icon request was duplicated or lost");
                require(merged.ShutdownAsync().GetAwaiter().GetResult(), "merged fixture cleanup failed");
            }

            active = false; opens = 0;
            var late = new BackgroundLifecycle(new Operations {
                Connect = () => { active = true; return complete(); }, Disconnect = complete,
                OpenDiscord = () => { opens++; return Task.FromResult("opened"); },
                Ready = () => active, Running = () => false, Dispose = () => { } });
            late.ConnectAsync(false).GetAwaiter().GetResult();
            late.ConnectAsync(true).GetAwaiter().GetResult();
            late.ConnectAsync(true).GetAwaiter().GetResult();
            require(opens == 1, "late startup request was duplicated or lost");
            require(late.ShutdownAsync().GetAwaiter().GetResult(), "late fixture cleanup failed");

            active = false; opens = 0;
            var existing = new BackgroundLifecycle(new Operations {
                Connect = () => { active = true; return complete(); }, Disconnect = complete,
                OpenDiscord = () => { opens++; return Task.FromResult("unexpected"); },
                Ready = () => active, Running = () => true, Dispose = () => { } });
            existing.ConnectAsync(true).GetAwaiter().GetResult();
            require(existing.OpenAsync().GetAwaiter().GetResult() == "Discord zaten açık." && opens == 0,
                "existing official Discord was launched again");
            require(existing.ShutdownAsync().GetAwaiter().GetResult(), "existing fixture cleanup failed");

            opens = 0; disposes = 0;
            var failure = new TaskCompletionSource<object>(); failure.SetException(new IOException("fixture"));
            var failed = new BackgroundLifecycle(new Operations {
                Connect = () => failure.Task, Disconnect = complete,
                OpenDiscord = () => { opens++; return Task.FromResult("unexpected"); },
                Ready = () => false, Running = () => false, Dispose = () => disposes++ });
            bool rejected = false;
            try { failed.ConnectAsync(true).GetAwaiter().GetResult(); } catch (IOException) { rejected = true; }
            require(rejected && opens == 0 && !failed.Ready, "failed connect triggered startup launch");
            require(failed.ShutdownAsync().GetAwaiter().GetResult() && disposes == 1, "failed preparation skipped disposal");

            preparation = new TaskCompletionSource<object>();
            using (var entered = new ManualResetEvent(false))
            {
                int connecting = 0; disconnects = 0; disposes = 0; opens = 0;
                var canceled = new BackgroundLifecycle(new Operations {
                    Connect = () => { Interlocked.Exchange(ref connecting, 1); entered.Set(); return preparation.Task; },
                    Disconnect = () => { disconnects++; Interlocked.Exchange(ref connecting, 0); preparation.SetCanceled(); return complete(); },
                    OpenDiscord = () => { opens++; return Task.FromResult("unexpected"); },
                    Ready = () => true, Running = () => false,
                    Dispose = () => { require(Volatile.Read(ref connecting) == 0, "Dispose entered while connect owned its lock"); disposes++; } });
                Task connection = canceled.ConnectAsync(true);
                require(entered.WaitOne(2000), "cancel fixture did not begin preparation");
                Task<string> queued = canceled.OpenAsync();
                require(canceled.ShutdownAsync().GetAwaiter().GetResult() && disconnects == 1 && disposes == 1 && opens == 0,
                    "shutdown did not cancel concurrent preparation before disposal");
                require(connection.IsCompleted && queued.IsCompleted, "canceled operations were left pending");
            }

            openingOperation = new TaskCompletionSource<string>();
            using (var enteredOpen = new ManualResetEvent(false))
            {
                active = true; disposes = 0;
                var closingOpen = new BackgroundLifecycle(new Operations {
                    Connect = complete,
                    Disconnect = () => { openingOperation.SetCanceled(); return complete(); },
                    OpenDiscord = () => { enteredOpen.Set(); return openingOperation.Task; },
                    Ready = () => active, Running = () => false,
                    Dispose = () => { require(openingOperation.Task.IsCompleted, "Dispose overtook a pending open"); disposes++; } });
                closingOpen.ConnectAsync(false).GetAwaiter().GetResult();
                Task<string> inFlight = closingOpen.OpenAsync();
                require(enteredOpen.WaitOne(2000), "pending-open fixture did not enter its operation");
                require(closingOpen.ShutdownAsync().GetAwaiter().GetResult() && disposes == 1 && inFlight.IsCompleted,
                    "shutdown left an open operation pending");
            }

            disposes = 0;
            var cleanupError = new TaskCompletionSource<object>(); cleanupError.SetException(new IOException("cleanup fixture"));
            var conflicted = new BackgroundLifecycle(new Operations {
                Connect = complete, Disconnect = () => cleanupError.Task, OpenDiscord = () => Task.FromResult("unused"),
                Ready = () => true, Running = () => false, Dispose = () => disposes++ });
            conflicted.ConnectAsync(false).GetAwaiter().GetResult();
            bool cleanupRejected = false;
            try { conflicted.ShutdownAsync().GetAwaiter().GetResult(); } catch (IOException) { cleanupRejected = true; }
            require(cleanupRejected && disposes == 1 && conflicted.Stopping,
                "cleanup conflict was hidden or safe disposal was skipped");

            var hung = new TaskCompletionSource<object>();
            disposes = 0;
            var bounded = new BackgroundLifecycle(new Operations {
                Connect = complete, Disconnect = () => hung.Task, OpenDiscord = () => Task.FromResult("unused"),
                Ready = () => true, Running = () => false, Dispose = () => disposes++ });
            bounded.ConnectAsync(false).GetAwaiter().GetResult();
            var timer = Stopwatch.StartNew();
            require(!bounded.ShutdownAsync(30).GetAwaiter().GetResult() && timer.ElapsedMilliseconds < 2000 && disposes == 0,
                "unresponsive disconnect exceeded its budget or entered Dispose");
            hung.SetResult(null);

            using (var enteredDispose = new ManualResetEvent(false))
            using (var releaseDispose = new ManualResetEvent(false))
            {
                var slowDispose = new BackgroundLifecycle(new Operations {
                    Connect = complete, Disconnect = complete, OpenDiscord = () => Task.FromResult("unused"),
                    Ready = () => true, Running = () => false,
                    Dispose = () => { enteredDispose.Set(); releaseDispose.WaitOne(); } });
                slowDispose.ConnectAsync(false).GetAwaiter().GetResult();
                timer.Restart();
                try
                {
                    require(!slowDispose.ShutdownAsync(100).GetAwaiter().GetResult() && enteredDispose.WaitOne(100) && timer.ElapsedMilliseconds < 2000,
                        "Dispose used an unbounded separate cleanup budget");
                }
                finally { releaseDispose.Set(); }
            }
            return checks;
        }
#endif
    }
}
