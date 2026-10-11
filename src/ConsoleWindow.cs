using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace DiscordAccess
{
    internal static class ConsoleWindow
    {
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AllocConsole();
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GetStdHandle(int kind);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetStdHandle(int kind, IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint GetFileType(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetConsoleMode(IntPtr handle, out uint mode);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DuplicateHandle(IntPtr sourceProcess,
            IntPtr source, IntPtr targetProcess, out SafeFileHandle duplicate, uint access, bool inherit, uint options);
        private static readonly object sync = new object();
        // Console.OpenStandard* wraps these handles without owning them. Keep
        // private duplicates alive until this process exits; do
        // not close inherited handles or handles belonging to the parent CMD.
        private static readonly List<SafeFileHandle> redirectedHandles = new List<SafeFileHandle>(3);
        private static bool ready;
        internal static void Ensure()
        {
            lock (sync)
            {
                if (ready) return;
                int[] kinds = { -10, -11, -12 };
                var saved = new SafeFileHandle[3];
                bool transferred = false;
                try
                {
                    for (int index = 0; index < kinds.Length; index++) saved[index] = PreserveRedirection(kinds[index]);
                    if (!AttachConsole(UInt32.MaxValue) && Marshal.GetLastWin32Error() != 5 && !AllocConsole()) return;
                    foreach (var handle in saved) if (handle != null) redirectedHandles.Add(handle);
                    transferred = true;
                    for (int index = 0; index < kinds.Length; index++)
                        if (saved[index] != null && !SetStdHandle(kinds[index], saved[index].DangerousGetHandle()))
                            throw new IOException("Konsol yönlendirmesi geri bağlanamadı.");
                    Console.InputEncoding = new UTF8Encoding(false);
                    Console.OutputEncoding = new UTF8Encoding(false);
                    Console.SetIn(new StreamReader(Console.OpenStandardInput(), Console.InputEncoding));
                    Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), Console.OutputEncoding) { AutoFlush = true });
                    Console.SetError(new StreamWriter(Console.OpenStandardError(), Console.OutputEncoding) { AutoFlush = true });
                    ready = true;
                }
                finally
                {
                    if (!transferred) foreach (var handle in saved) if (handle != null) handle.Dispose();
                }
            }
        }
        private static SafeFileHandle PreserveRedirection(int kind)
        {
            IntPtr original = GetStdHandle(kind);
            if (original == IntPtr.Zero || original == new IntPtr(-1)) return null;
            uint type = GetFileType(original) & 0x7fff, mode;
            // Preserve disk/pipe redirects and explicit NUL/device handles.
            // Actual console handles must be obtained from Attach/AllocConsole.
            if (type != 1 && type != 3 && !(type == 2 && !GetConsoleMode(original, out mode))) return null;
            SafeFileHandle duplicate;
            IntPtr current = GetCurrentProcess();
            if (!DuplicateHandle(current, original, current, out duplicate, 0, false, 2))
            {
                if (duplicate != null) duplicate.Dispose();
                throw new IOException("Konsol yönlendirmesi korunamadı.");
            }
            return duplicate;
        }
    }
    // Shortcut journals are per-user, even across two Windows logon sessions.
    // A lifetime file lease supplements the Local mutex and fails closed.
    internal static class ResidentStateLease
    {
        internal static IDisposable Acquire()
        {
            Safety.EnsureStateDirectory();
            string path = Path.Combine(Safety.StateRoot, "v3", "resident.lock");
            if (!Safety.NoReparse(path)) throw new InvalidDataException("State lease path");
            FileStream lease = null;
            try
            {
                lease = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                if (!Safety.NoReparse(path) || !String.Equals(Path.GetFullPath(path), NativeFile.FinalPath(lease.SafeFileHandle), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("State lease changed");
                return lease;
            }
            catch (IOException)
            {
                if (lease != null) lease.Dispose();
                throw new UserActionException("Bu kullanıcı için başka bir DiscordAccess oturumu açık. Önce o oturumu kapatın.");
            }
            catch { if (lease != null) lease.Dispose(); throw; }
        }
    }
}
