using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace DiscordAccess
{
    // The job is unnamed and its only owner handle is never inherited. Closing the
    // GUI's handle therefore closes the complete session, including descendants.
    internal sealed class NativeSessionJob : IDisposable
    {
        private readonly object syncRoot = new object();
        private SafeFileHandle handle;

        internal NativeSessionJob()
        {
            SafeFileHandle created = NativeMethods.CreateJobObjectW(IntPtr.Zero, null);
            if (created == null || created.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (created != null) created.Dispose();
                throw NativeMethods.Error(error, "The session job could not be created.");
            }
            try
            {
                if (!NativeMethods.SetHandleInformation(created, NativeMethods.HandleFlagInherit, 0))
                    throw NativeMethods.LastError("The session job handle could not be isolated.");
                NativeMethods.JobExtendedLimitInformation limits = new NativeMethods.JobExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = NativeMethods.JobObjectLimitKillOnJobClose;
                // No BREAKAWAY_OK or SILENT_BREAKAWAY_OK is enabled.
                if (!NativeMethods.SetInformationJobObject(created, 9, ref limits,
                    (uint)Marshal.SizeOf(typeof(NativeMethods.JobExtendedLimitInformation))))
                    throw NativeMethods.LastError("The session job limits could not be set.");
                handle = created;
            }
            catch
            {
                created.Dispose();
                throw;
            }
        }

        internal object SyncRoot { get { return syncRoot; } }

        internal SafeFileHandle Handle
        {
            get
            {
                lock (syncRoot)
                {
                    if (handle == null || handle.IsClosed || handle.IsInvalid)
                        throw new ObjectDisposedException("NativeSessionJob");
                    return handle;
                }
            }
        }

        internal bool IsMember(Process process)
        {
            if (process == null) return false;
            lock (syncRoot)
            {
                if (handle == null || handle.IsClosed || handle.IsInvalid) return false;
                try
                {
                    bool member;
                    // Process.Handle pins this process object; a PID alone is not
                    // sufficient evidence of membership or process identity.
                    return NativeMethods.IsProcessInJob(process.Handle, handle, out member) && member;
                }
                catch (InvalidOperationException) { return false; }
                catch (Win32Exception) { return false; }
                catch (ArgumentException) { return false; }
            }
        }

        // Enumerate this job only; unrelated games/processes are not scanned.
        internal int[] ProcessIds()
        {
            lock (syncRoot)
            {
                if (handle == null || handle.IsClosed || handle.IsInvalid) return new int[0];
                for (int capacity = 64; capacity <= 4096; capacity *= 2)
                {
                    int bytes = checked(8 + capacity * IntPtr.Size);
                    IntPtr buffer = Marshal.AllocHGlobal(bytes);
                    try
                    {
                        uint returned;
                        if (!NativeMethods.QueryInformationJobObject(handle, 3, buffer, (uint)bytes, out returned))
                        {
                            if (Marshal.GetLastWin32Error() == 234) continue;
                            throw NativeMethods.LastError("The owned process list could not be queried.");
                        }
                        uint assigned = unchecked((uint)Marshal.ReadInt32(buffer, 0));
                        uint listed = unchecked((uint)Marshal.ReadInt32(buffer, 4));
                        if (listed > capacity || assigned > listed) continue;
                        var ids = new int[listed];
                        for (int index = 0; index < ids.Length; index++)
                        {
                            long id = Marshal.ReadIntPtr(buffer, 8 + index * IntPtr.Size).ToInt64();
                            if (id < 1 || id > Int32.MaxValue) throw new InvalidOperationException("Owned process identity invalid.");
                            ids[index] = (int)id;
                        }
                        return ids;
                    }
                    finally { Marshal.FreeHGlobal(buffer); }
                }
                throw new InvalidOperationException("Owned process list exceeded its bound.");
            }
        }

        internal bool OwnsImage(int processId, string firstImage, string secondImage)
        {
            if (processId < 1) return false;
            // Query rights and a synchronization handle only: no VM read/write,
            // debugging, thread creation or access to process memory.
            using (var process = NativeMethods.OpenProcess(0x00101000, false, (uint)processId))
            {
                if (process.IsInvalid) return false;
                lock (syncRoot)
                {
                    if (handle == null || handle.IsClosed || handle.IsInvalid) return false;
                    bool member;
                    if (!NativeMethods.IsProcessInJob(process.DangerousGetHandle(), handle, out member) || !member ||
                        NativeMethods.WaitForSingleObject(process, 0) != 258) return false;
                    var path = new StringBuilder(32768);
                    uint length = (uint)path.Capacity;
                    if (!NativeMethods.QueryFullProcessImageNameW(process, 0, path, ref length)) return false;
                    string image = path.ToString();
                    return String.Equals(image, firstImage, StringComparison.OrdinalIgnoreCase) ||
                        (secondImage != null && String.Equals(image, secondImage, StringComparison.OrdinalIgnoreCase));
                }
            }
        }

        // Keep the ownership handle alive until Windows reports no job members.
        // Dispose alone requests termination but cannot prove writers have exited.
        internal bool TerminateAndWait(int milliseconds)
        {
            if (milliseconds < 1 || milliseconds > 30000) throw new ArgumentOutOfRangeException("milliseconds");
            var elapsed = Stopwatch.StartNew();
            if (!Monitor.TryEnter(syncRoot, milliseconds)) return false;
            try
            {
                if (handle == null || handle.IsClosed || handle.IsInvalid) return false;
                if (!NativeMethods.TerminateJobObject(handle, 1)) return false;
                while (true)
                {
                    try { if (ProcessIds().Length == 0) return true; }
                    catch { return false; }
                    int remaining = milliseconds - (int)elapsed.ElapsedMilliseconds;
                    if (remaining <= 0) return false;
                    Thread.Sleep(Math.Min(25, remaining));
                }
            }
            finally { Monitor.Exit(syncRoot); }
        }

#if TEST_BUILD
        internal static int RunTerminationChecks()
        {
            int checks = 0;
            Action<bool, string> require = (ok, label) => {
                if (!ok) throw new InvalidOperationException("Native job termination fixture: " + label);
                checks++;
            };
            using (var empty = new NativeSessionJob())
            {
                require(empty.TerminateAndWait(1000) && empty.ProcessIds().Length == 0 && !empty.Handle.IsClosed, "empty job retains ownership handle");
                bool low = false, high = false;
                try { empty.TerminateAndWait(0); } catch (ArgumentOutOfRangeException) { low = true; }
                try { empty.TerminateAndWait(30001); } catch (ArgumentOutOfRangeException) { high = true; }
                using (var entered = new ManualResetEvent(false))
                using (var release = new ManualResetEvent(false))
                {
                    var holder = new Thread(() => { lock (empty.SyncRoot) { entered.Set(); release.WaitOne(); } });
                    holder.IsBackground = true; holder.Start();
                    try
                    {
                        if (!entered.WaitOne(2000)) throw new InvalidOperationException("Termination lock fixture did not start.");
                        var elapsed = Stopwatch.StartNew();
                        bool timedOut = !empty.TerminateAndWait(25);
                        require(low && high && timedOut && elapsed.ElapsedMilliseconds < 1000, "deadline bounds include lock acquisition");
                    }
                    finally { release.Set(); holder.Join(2000); }
                }
                empty.Dispose();
                require(!empty.TerminateAndWait(1000), "closed handle is not proof of exit");
            }
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string image = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
            string missing = Path.Combine(system, "DiscordAccess-Missing-Fixture-" + Guid.NewGuid().ToString("N") + ".exe");
            const string arguments = "-NoProfile -NonInteractive -Command \"[Threading.Thread]::Sleep(15000)\"";
            using (var preserved = new NativeSessionJob())
            using (var other = new NativeSessionJob())
            using (var child = NativeProcess.Start(preserved, image, arguments, system, null, null))
            using (var unrelated = NativeProcess.Start(other, image, arguments, system, null, null))
            {
                bool failed = false;
                try { using (NativeProcess.Start(preserved, missing, "", system, null, null, true)) { } }
                catch (Win32Exception) { failed = true; }
                bool retained = failed && !child.HasExited && preserved.IsMember(child);
                var elapsed = Stopwatch.StartNew();
                bool stopped = preserved.TerminateAndWait(4000);
                require(retained && stopped && preserved.ProcessIds().Length == 0 && child.WaitForExit(1000) &&
                    !unrelated.HasExited && elapsed.ElapsedMilliseconds < 5000, "preserved failed launch drains only its own job");
                other.TerminateAndWait(4000);
            }
            using (var closed = new NativeSessionJob())
            using (var child = NativeProcess.Start(closed, image, arguments, system, null, null))
            {
                bool failed = false;
                try { using (NativeProcess.Start(closed, missing, "", system, null, null)) { } }
                catch (Win32Exception) { failed = true; }
                require(failed && child.WaitForExit(4000) && !closed.TerminateAndWait(1000), "default failed launch still closes job");
            }
            return checks;
        }
#endif

        public void Dispose()
        {
            lock (syncRoot)
            {
                SafeFileHandle previous = handle;
                handle = null;
                if (previous != null) previous.Dispose();
            }
        }
    }

    internal static class NativeProcess
    {
        private const int MaxConfigurationBytes = 128 * 1024;
        private const int ConfigurationWriteTimeoutMilliseconds = 5000;

        internal enum ImageObservation { Gone, Running, Unknown }

        // Process enumeration is a snapshot. Keep a synchronized kernel handle
        // while observing its image, so an exited snapshot PID is distinguishable
        // from a live process whose identity cannot be queried. Unknown remains
        // fail-closed; this grants neither ownership nor termination rights.
        internal static ImageObservation ObserveRunningImage(int processId, out string imagePath)
        {
            imagePath = null;
            if (processId < 1) return ImageObservation.Gone;
            try
            {
                using (var process = NativeMethods.OpenProcess(0x00101000, false, (uint)processId))
                {
                    int openError = Marshal.GetLastWin32Error();
                    if (process == null || process.IsInvalid)
                        return openError == 87 ? ImageObservation.Gone : ImageObservation.Unknown;
                    uint before = NativeMethods.WaitForSingleObject(process, 0);
                    if (before == 0) return ImageObservation.Gone;
                    if (before != 258) return ImageObservation.Unknown;
                    var image = new StringBuilder(32768);
                    uint length = (uint)image.Capacity;
                    bool read = NativeMethods.QueryFullProcessImageNameW(process, 0, image, ref length) &&
                        length > 0 && length < image.Capacity;
                    uint after = NativeMethods.WaitForSingleObject(process, 0);
                    if (after == 0) return ImageObservation.Gone;
                    if (after != 258) return ImageObservation.Unknown;
                    if (read && Path.IsPathRooted(image.ToString())) imagePath = image.ToString();
                    return ImageObservation.Running;
                }
            }
            catch { return ImageObservation.Unknown; }
        }

        // Observation only, not process ownership or permission to terminate it.
        // QUERY_LIMITED_INFORMATION avoids MainModule/VM_READ on unrelated apps.
        internal static string ReadImagePath(int processId)
        {
            if (processId < 1) return null;
            using (var process = NativeMethods.OpenProcess(0x00001000, false, (uint)processId))
            {
                if (process == null || process.IsInvalid) return null;
                var image = new StringBuilder(32768);
                uint length = (uint)image.Capacity;
                if (!NativeMethods.QueryFullProcessImageNameW(process, 0, image, ref length) ||
                    length == 0 || length >= image.Capacity) return null;
                string path = image.ToString();
                return Path.IsPathRooted(path) ? path : null;
            }
        }

        // CreateProcess receives an explicit executable name. Quote implements
        // Windows argv escaping, not shell escaping; no shell is ever invoked.
        internal static string Quote(string value)
        {
            if (value == null) throw new ArgumentNullException("value");
            if (value.IndexOf('\0') >= 0) throw new ArgumentException("An argument contains a NUL character.", "value");
            StringBuilder result = new StringBuilder(value.Length + 2);
            result.Append('"');
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    slashes++;
                }
                else if (character == '"')
                {
                    result.Append('\\', checked(slashes * 2 + 1));
                    result.Append('"');
                    slashes = 0;
                }
                else
                {
                    result.Append('\\', slashes);
                    result.Append(character);
                    slashes = 0;
                }
            }
            result.Append('\\', checked(slashes * 2));
            result.Append('"');
            return result.ToString();
        }

        internal static Process Start(NativeSessionJob job, string path, string arguments,
            string workingDirectory, IDictionary<string, string> environmentOverrides, string stdinConfig,
            bool preserveJobOnFailure = false)
        {
            if (job == null) throw new ArgumentNullException("job");
            // Serializes creation with Dispose. Assignment is still performed by
            // the kernel as part of CreateProcess, never by a later PID lookup.
            lock (job.SyncRoot)
            {
                NativeMethods.ProcessInformation information = new NativeMethods.ProcessInformation();
                SafeFileHandle stdinRead = null;
                SafeFileHandle stdinWrite = null;
                SafeFileHandle nulOutput = null;
                SafeFileHandle jobHandle = null;
                IntPtr attributes = IntPtr.Zero;
                IntPtr jobHandles = IntPtr.Zero;
                IntPtr inheritedHandles = IntPtr.Zero;
                IntPtr environment = IntPtr.Zero;
                byte[] environmentBytes = null;
                byte[] configurationBytes = null;
                bool attributesInitialized = false;
                bool success = false;
                Process process = null;
                StdinPipeWriter writer = null;
                try
                {
                    jobHandle = job.Handle;
                    if (path == null) throw new ArgumentNullException("path");
                    if (!Path.IsPathRooted(path)) throw new ArgumentException("An absolute executable path is required.", "path");
                    path = Path.GetFullPath(path);
                    if (arguments == null) arguments = String.Empty;
                    if (arguments.IndexOf('\0') >= 0)
                        throw new ArgumentException("The arguments contain a NUL character.", "arguments");
                    if (workingDirectory == null) workingDirectory = Path.GetDirectoryName(path);
                    workingDirectory = Path.GetFullPath(workingDirectory);
                    string commandLine = Quote(path) + (arguments.Length == 0 ? String.Empty : " " + arguments);
                    if (commandLine.Length > 32766) throw new ArgumentException("The process command line is too long.", "arguments");

                    NativeMethods.SecurityAttributes security = new NativeMethods.SecurityAttributes();
                    security.Length = Marshal.SizeOf(typeof(NativeMethods.SecurityAttributes));
                    security.InheritHandle = 1;
                    if (stdinConfig != null)
                    {
                        if (stdinConfig.Length > MaxConfigurationBytes)
                            throw new ArgumentException("The engine configuration exceeds its size limit.", "stdinConfig");
                        try { configurationBytes = new UTF8Encoding(false, true).GetBytes(stdinConfig); }
                        catch (EncoderFallbackException)
                        {
                            throw new ArgumentException("The engine configuration is not valid Unicode.", "stdinConfig");
                        }
                        if (configurationBytes.Length > MaxConfigurationBytes)
                            throw new ArgumentException("The engine configuration exceeds its size limit.", "stdinConfig");
                        if (!NativeMethods.CreatePipe(out stdinRead, out stdinWrite, ref security, MaxConfigurationBytes))
                            throw NativeMethods.LastError("The engine input pipe could not be created.");
                        if (!NativeMethods.SetHandleInformation(stdinWrite, NativeMethods.HandleFlagInherit, 0))
                            throw NativeMethods.LastError("The engine input pipe could not be isolated.");
                    }
                    else
                    {
                        stdinRead = NativeMethods.CreateFileW("NUL", 0x80000000, 3, ref security, 3, 0x80, IntPtr.Zero);
                        if (stdinRead == null || stdinRead.IsInvalid)
                            throw NativeMethods.LastError("The child input handle could not be created.");
                    }
                    nulOutput = NativeMethods.CreateFileW("NUL", 0x40000000, 3, ref security, 3, 0x80, IntPtr.Zero);
                    if (nulOutput == null || nulOutput.IsInvalid)
                        throw NativeMethods.LastError("The child output handles could not be created.");

                    int attributeCount = 2;
                    UIntPtr attributeSize = UIntPtr.Zero;
                    NativeMethods.InitializeProcThreadAttributeList(IntPtr.Zero, attributeCount, 0, ref attributeSize);
                    ulong size = attributeSize.ToUInt64();
                    if (size == 0 || size > Int32.MaxValue)
                        throw NativeMethods.LastError("The process attribute list size is invalid.");
                    attributes = Marshal.AllocHGlobal((int)size);
                    if (!NativeMethods.InitializeProcThreadAttributeList(attributes, attributeCount, 0, ref attributeSize))
                        throw NativeMethods.LastError("The process attribute list could not be initialized.");
                    attributesInitialized = true;
                    jobHandles = Marshal.AllocHGlobal(IntPtr.Size);
                    Marshal.WriteIntPtr(jobHandles, jobHandle.DangerousGetHandle());
                    if (!NativeMethods.UpdateProcThreadAttribute(attributes, 0, new UIntPtr(0x0002000d),
                        jobHandles, new UIntPtr((uint)IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                        throw NativeMethods.LastError("Atomic session job assignment is unavailable.");

                    NativeMethods.StartupInfoEx startup = new NativeMethods.StartupInfoEx();
                    startup.StartupInfo.Size = Marshal.SizeOf(typeof(NativeMethods.StartupInfoEx));
                    startup.AttributeList = attributes;
                    {
                        // All children receive explicit standard handles. Only
                        // the input pipe/NUL and output NUL cross the boundary;
                        // launcher console handles and job handles never do.
                        inheritedHandles = Marshal.AllocHGlobal(IntPtr.Size * 2);
                        Marshal.WriteIntPtr(inheritedHandles, 0, stdinRead.DangerousGetHandle());
                        Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size, nulOutput.DangerousGetHandle());
                        if (!NativeMethods.UpdateProcThreadAttribute(attributes, 0, new UIntPtr(0x00020002),
                            inheritedHandles, new UIntPtr((uint)(IntPtr.Size * 2)), IntPtr.Zero, IntPtr.Zero))
                            throw NativeMethods.LastError("The process handle allowlist could not be set.");
                        startup.StartupInfo.Flags = NativeMethods.StartfUseStdHandles;
                        startup.StartupInfo.StandardInput = stdinRead.DangerousGetHandle();
                        startup.StartupInfo.StandardOutput = nulOutput.DangerousGetHandle();
                        startup.StartupInfo.StandardError = nulOutput.DangerousGetHandle();
                    }

                    environmentBytes = BuildEnvironment(environmentOverrides);
                    environment = Marshal.AllocHGlobal(environmentBytes.Length);
                    Marshal.Copy(environmentBytes, 0, environment, environmentBytes.Length);
                    // Windows ignores CREATE_NO_WINDOW for GUI images. Apply it
                    // to every launch so console helpers cannot create a console.
                    uint flags = NativeMethods.CreateSuspended | NativeMethods.CreateUnicodeEnvironment |
                        NativeMethods.ExtendedStartupInfoPresent | NativeMethods.CreateNoWindow;
                    if (!NativeMethods.CreateProcessW(path, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero,
                        true, flags, environment, workingDirectory, ref startup, out information))
                        throw NativeMethods.LastError("The session process could not be created.");

                    // The original CreateProcess handle remains open while the
                    // managed Process opens its handle. Compare kernel objects,
                    // rather than assuming that equal PIDs prove equal identity.
                    process = Process.GetProcessById(checked((int)information.ProcessId));
                    if (!NativeMethods.CompareObjectHandles(information.Process, process.Handle))
                        throw new InvalidOperationException("The created process identity could not be verified.");
                    if (!job.IsMember(process))
                        throw new InvalidOperationException("The created process is outside the session job.");
                    if (stdinRead != null) { stdinRead.Dispose(); stdinRead = null; }
                    uint previousSuspendCount = NativeMethods.ResumeThread(information.Thread);
                    if (previousSuspendCount == UInt32.MaxValue)
                        throw NativeMethods.LastError("The session process could not be resumed.");
                    if (previousSuspendCount != 1)
                        throw new InvalidOperationException("The process suspension state changed unexpectedly.");

                    if (stdinConfig != null)
                    {
                        // Resume first: pipe buffer sizes are hints, and a child
                        // must be able to read while configuration is delivered.
                        writer = new StdinPipeWriter(stdinWrite, configurationBytes);
                        stdinWrite = null;
                        configurationBytes = null;
                        writer.Complete(ConfigurationWriteTimeoutMilliseconds);
                    }
                    success = true;
                    return process;
                }
                catch
                {
                    if (writer != null) writer.Cancel();
                    if (information.Process != IntPtr.Zero)
                        NativeMethods.TerminateProcess(information.Process, 1);
                    // Default callers retain the original kill-on-failure rule.
                    // Installed-app callers keep the job handle to prove all
                    // writers exited via TerminateAndWait before restoring files.
                    if (!preserveJobOnFailure) job.Dispose();
                    throw;
                }
                finally
                {
                    if (writer != null) writer.Dispose();
                    if (!success && process != null) process.Dispose();
                    if (information.Thread != IntPtr.Zero) NativeMethods.CloseHandle(information.Thread);
                    if (information.Process != IntPtr.Zero) NativeMethods.CloseHandle(information.Process);
                    if (attributesInitialized) NativeMethods.DeleteProcThreadAttributeList(attributes);
                    if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                    if (jobHandles != IntPtr.Zero) Marshal.FreeHGlobal(jobHandles);
                    if (inheritedHandles != IntPtr.Zero) Marshal.FreeHGlobal(inheritedHandles);
                    if (stdinRead != null) stdinRead.Dispose();
                    if (stdinWrite != null) stdinWrite.Dispose();
                    if (nulOutput != null) nulOutput.Dispose();
                    if (configurationBytes != null) Array.Clear(configurationBytes, 0, configurationBytes.Length);
                    if (environmentBytes != null)
                    {
                        Array.Clear(environmentBytes, 0, environmentBytes.Length);
                        if (environment != IntPtr.Zero)
                            Marshal.Copy(environmentBytes, 0, environment, environmentBytes.Length);
                    }
                    if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
                    GC.KeepAlive(jobHandle);
                    GC.KeepAlive(job);
                }
            }
        }

        private static byte[] BuildEnvironment(IDictionary<string, string> overrides)
        {
            SortedDictionary<string, string> values = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
            {
                string name = entry.Key as string;
                string value = entry.Value as string;
                if (name == null || value == null || name.IndexOf('\0') >= 0 || value.IndexOf('\0') >= 0)
                    throw new InvalidOperationException("The inherited environment is invalid.");
                values[name] = value;
            }
            if (overrides != null)
            {
                foreach (KeyValuePair<string, string> entry in overrides)
                {
                    if (String.IsNullOrEmpty(entry.Key) || entry.Key.IndexOf('=') >= 0 || entry.Key.IndexOf('\0') >= 0)
                        throw new ArgumentException("An environment override name is invalid.", "overrides");
                    if (entry.Value == null) values.Remove(entry.Key);
                    else
                    {
                        if (entry.Value.IndexOf('\0') >= 0)
                            throw new ArgumentException("An environment override value is invalid.", "overrides");
                        values[entry.Key] = entry.Value;
                    }
                }
            }
            StringBuilder block = new StringBuilder();
            foreach (KeyValuePair<string, string> entry in values)
            {
                block.Append(entry.Key).Append('=').Append(entry.Value).Append('\0');
            }
            if (block.Length == 0) block.Append('\0');
            block.Append('\0');
            return Encoding.Unicode.GetBytes(block.ToString());
        }

        private sealed class StdinPipeWriter : IDisposable
        {
            private readonly SafeFileHandle pipe;
            private readonly byte[] bytes;
            private readonly Thread worker;
            private readonly ManualResetEvent finished = new ManualResetEvent(false);
            private readonly object threadLock = new object();
            private SafeFileHandle threadHandle;
            private volatile bool cancelled;
            private int errorCode;

            internal StdinPipeWriter(SafeFileHandle pipe, byte[] bytes)
            {
                this.pipe = pipe;
                this.bytes = bytes;
                worker = new Thread(Write);
                worker.IsBackground = true;
                worker.Name = "DiscordAccess configuration pipe";
                try { worker.Start(); }
                catch
                {
                    Array.Clear(bytes, 0, bytes.Length);
                    pipe.Dispose();
                    finished.Dispose();
                    throw;
                }
            }

            internal void Complete(int timeoutMilliseconds)
            {
                if (!finished.WaitOne(timeoutMilliseconds))
                    throw new TimeoutException("Engine configuration delivery timed out.");
                if (errorCode != 0)
                    throw NativeMethods.Error(errorCode, "The engine configuration could not be delivered.");
            }

            internal void Cancel()
            {
                cancelled = true;
                lock (threadLock)
                {
                    if (threadHandle != null && !threadHandle.IsInvalid && !threadHandle.IsClosed)
                        NativeMethods.CancelSynchronousIo(threadHandle);
                }
            }

            private void Write()
            {
                GCHandle pinned = new GCHandle();
                try
                {
                    lock (threadLock)
                    {
                        threadHandle = NativeMethods.OpenThread(1, false, NativeMethods.GetCurrentThreadId());
                        if (threadHandle == null || threadHandle.IsInvalid)
                        {
                            errorCode = Marshal.GetLastWin32Error();
                            if (errorCode == 0) errorCode = 31;
                            return;
                        }
                    }
                    if (bytes.Length != 0) pinned = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        if (cancelled) { errorCode = 995; return; }
                        uint written;
                        if (!NativeMethods.WriteFile(pipe, IntPtr.Add(pinned.AddrOfPinnedObject(), offset),
                            (uint)(bytes.Length - offset), out written, IntPtr.Zero))
                        {
                            errorCode = Marshal.GetLastWin32Error();
                            if (errorCode == 0) errorCode = 31;
                            return;
                        }
                        if (written == 0 || written > (uint)(bytes.Length - offset))
                        {
                            errorCode = 29;
                            return;
                        }
                        offset += checked((int)written);
                    }
                    if (cancelled) errorCode = 995;
                }
                catch { errorCode = 31; }
                finally
                {
                    if (pinned.IsAllocated) pinned.Free();
                    Array.Clear(bytes, 0, bytes.Length);
                    pipe.Dispose(); // EOF allows the engine to finish parsing.
                    finished.Set();
                }
            }

            public void Dispose()
            {
                if (!finished.WaitOne(0)) Cancel();
                bool joined = worker.Join(1000);
                lock (threadLock)
                {
                    if (threadHandle != null) { threadHandle.Dispose(); threadHandle = null; }
                }
                // Do not dispose an event the worker could still signal. On the
                // failure path its pipe reader has already been terminated.
                if (joined) finished.Dispose();
            }
        }
    }

    internal static class NativeMethods
    {
        internal const uint HandleFlagInherit = 1;
        internal const uint JobObjectLimitKillOnJobClose = 0x00002000;
        internal const uint StartfUseStdHandles = 0x00000100;
        internal const uint CreateSuspended = 0x00000004;
        internal const uint CreateUnicodeEnvironment = 0x00000400;
        internal const uint ExtendedStartupInfoPresent = 0x00080000;
        internal const uint CreateNoWindow = 0x08000000;

        internal static Win32Exception Error(int error, string operation) { return new Win32Exception(error, operation); }
        internal static Win32Exception LastError(string operation) { return Error(Marshal.GetLastWin32Error(), operation); }

        [StructLayout(LayoutKind.Sequential)]
        internal struct SecurityAttributes
        {
            internal int Length;
            internal IntPtr SecurityDescriptor;
            internal int InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobBasicLimitInformation
        {
            internal long PerProcessUserTimeLimit;
            internal long PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal UIntPtr MinimumWorkingSetSize;
            internal UIntPtr MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal UIntPtr Affinity;
            internal uint PriorityClass;
            internal uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct IoCounters
        {
            internal ulong ReadOperationCount;
            internal ulong WriteOperationCount;
            internal ulong OtherOperationCount;
            internal ulong ReadTransferCount;
            internal ulong WriteTransferCount;
            internal ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobExtendedLimitInformation
        {
            internal JobBasicLimitInformation BasicLimitInformation;
            internal IoCounters IoInfo;
            internal UIntPtr ProcessMemoryLimit;
            internal UIntPtr JobMemoryLimit;
            internal UIntPtr PeakProcessMemoryUsed;
            internal UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct StartupInfo
        {
            internal int Size;
            internal IntPtr Reserved;
            internal IntPtr Desktop;
            internal IntPtr Title;
            internal uint X;
            internal uint Y;
            internal uint XSize;
            internal uint YSize;
            internal uint XCountChars;
            internal uint YCountChars;
            internal uint FillAttribute;
            internal uint Flags;
            internal ushort ShowWindow;
            internal ushort Reserved2Size;
            internal IntPtr Reserved2;
            internal IntPtr StandardInput;
            internal IntPtr StandardOutput;
            internal IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct StartupInfoEx
        {
            internal StartupInfo StartupInfo;
            internal IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct ProcessInformation
        {
            internal IntPtr Process;
            internal IntPtr Thread;
            internal uint ProcessId;
            internal uint ThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        internal static extern SafeFileHandle CreateJobObjectW(IntPtr securityAttributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(SafeFileHandle job, int informationClass,
            ref JobExtendedLimitInformation information, uint informationLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool IsProcessInJob(IntPtr process, SafeFileHandle job,
            [MarshalAs(UnmanagedType.Bool)] out bool result);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool QueryInformationJobObject(SafeFileHandle job, int informationClass,
            IntPtr information, uint informationLength, out uint returnLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern SafeFileHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit,
            uint processId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool QueryFullProcessImageNameW(SafeFileHandle process, uint flags,
            StringBuilder image, ref uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write,
            ref SecurityAttributes securityAttributes, uint size);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        internal static extern SafeFileHandle CreateFileW(string name, uint access, uint shareMode,
            ref SecurityAttributes securityAttributes, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool InitializeProcThreadAttributeList(IntPtr attributes, int count, uint flags,
            ref UIntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool UpdateProcThreadAttribute(IntPtr attributes, uint flags, UIntPtr attribute,
            IntPtr value, UIntPtr size, IntPtr previousValue, IntPtr returnSize);
        [DllImport("kernel32.dll")]
        internal static extern void DeleteProcThreadAttributeList(IntPtr attributes);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateProcessW(string applicationName, StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);
        [DllImport("kernelbase.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CompareObjectHandles(IntPtr first, IntPtr second);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern SafeFileHandle OpenThread(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit,
            uint threadId);
        [DllImport("kernel32.dll")]
        internal static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool WriteFile(SafeFileHandle file, IntPtr buffer, uint count, out uint written,
            IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CancelSynchronousIo(SafeFileHandle thread);
    }
}
