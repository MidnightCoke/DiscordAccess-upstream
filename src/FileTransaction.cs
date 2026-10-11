using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace DiscordAccess
{
    // A held read handle does not make pathname replacement a compare-and-swap:
    // delete sharing allows an updater to rename another file into that path.
    // ReplaceFile therefore keeps the object it actually displaced, and only
    // removes that evidence after its bytes match the expected object. Unknown
    // data remains beside the target for recovery. Deletion uses the verified
    // object handle, never a second pathname lookup.
    internal static class FileTransaction
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct Disposition { internal byte DeleteFile; }
        [StructLayout(LayoutKind.Sequential)]
        private struct AttributeTag { internal uint Attributes, ReparseTag; }
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern SafeFileHandle Open(string path, uint access, uint share, IntPtr security,
            uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass,
            ref Disposition information, uint size);
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass,
            out AttributeTag information, uint size);

        internal static void ReplaceExpected(string path, byte[] expected, byte[] replacement, int limit, Action<string> validate)
        {
            Arguments(path, expected, replacement, limit, validate);
            validate(path);
            if (Same(expected, replacement)) return;
            string stamp = Path.Combine(Path.GetDirectoryName(path), ".discordaccess-fs-" + Guid.NewGuid().ToString("N"));
            string temporary = stamp + ".pending", backup = stamp + ".preserved";
            try
            {
                WriteNew(temporary, replacement, validate);
                if (expected == null)
                {
                    Interleave("create", path);
                    validate(path); validate(temporary);
                    File.Move(temporary, path); // no overwrite, even after a concurrent create
                    return;
                }
                using (var current = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
                {
                    Check(path, current, validate);
                    if (!Same(Read(current, limit), expected)) throw Conflict();
                    Interleave("replace", path);
                    validate(path); validate(temporary); validate(backup);
                    if (Present(backup)) throw Conflict();
                    File.Replace(temporary, path, backup);
                }
                byte[] displaced = ReadPath(backup, limit, validate);
                if (!Same(displaced, expected))
                {
                    // Preserve the original evidence even if undo races another
                    // updater. The second replacement has its own backup.
                    TryUndo(path, replacement, displaced, stamp, limit, validate);
                    throw Conflict();
                }
                RemoveOwned(backup, expected, limit, validate);
            }
            catch (InvalidDataException) { throw; }
            catch (IOException) { throw Conflict(); }
            catch (UnauthorizedAccessException) { throw Conflict(); }
            finally { RemoveOwned(temporary, replacement, limit, validate); }
        }

        internal static void DeleteExpected(string path, byte[] expected, int limit, Action<string> validate)
        {
            Arguments(path, expected, expected, limit, validate);
            if (expected == null) throw new ArgumentException("Expected file bytes are required.");
            try { DeleteObject(path, expected, limit, validate, true); }
            catch (InvalidDataException) { throw; }
            catch (IOException) { throw Conflict(); }
            catch (UnauthorizedAccessException) { throw Conflict(); }
        }

        private static void TryUndo(string path, byte[] replacement, byte[] displaced, string stamp, int limit, Action<string> validate)
        {
            string temporary = stamp + ".restore", backup = stamp + ".rollback-preserved";
            try
            {
                WriteNew(temporary, displaced, validate);
                using (var current = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
                {
                    Check(path, current, validate);
                    if (!Same(Read(current, limit), replacement)) return;
                    Interleave("rollback", path);
                    validate(path); validate(temporary); validate(backup);
                    if (Present(backup)) return;
                    File.Replace(temporary, path, backup);
                }
                // A new writer's data is retained if it entered the pathname
                // between the comparison and undo. Never delete unknown bytes.
                RemoveOwned(backup, replacement, limit, validate);
            }
            catch (InvalidDataException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (UserActionException) { }
            finally { RemoveOwned(temporary, displaced, limit, validate); }
        }

        private static void DeleteObject(string path, byte[] expected, int limit, Action<string> validate, bool interleave)
        {
            validate(path);
            using (var handle = Open(path, 0x80010000, 5, IntPtr.Zero, 3, 0x80, IntPtr.Zero)) // READ | DELETE; READ | DELETE sharing
            {
                if (handle.IsInvalid) throw Conflict();
                using (var stream = new FileStream(handle, FileAccess.Read))
                {
                    Check(path, stream, validate);
                    if (!Same(Read(stream, limit), expected)) throw Conflict();
                    if (interleave) Interleave("delete", path);
                    var disposition = new Disposition { DeleteFile = 1 };
                    if (!SetFileInformationByHandle(handle, 4, ref disposition, 1)) throw Conflict();
                }
            }
            // A renamed-in file is deliberately left in place. Report the
            // conflict so callers retain their recovery journal/in-memory state.
            if (Present(path)) throw Conflict();
        }

        private static void RemoveOwned(string path, byte[] expected, int limit, Action<string> validate)
        {
            // Cleanup is best effort and only operates on a byte-proven handle.
            // Failure leaves a recoverable sibling, never a pathname deletion.
            try { if (Present(path)) DeleteObject(path, expected, limit, validate, false); }
            catch (InvalidDataException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (UserActionException) { }
        }

        private static void WriteNew(string path, byte[] bytes, Action<string> validate)
        {
            validate(path);
            using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            { Check(path, stream, validate); stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
        }
        private static byte[] ReadPath(string path, int limit, Action<string> validate)
        {
            validate(path);
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            { Check(path, stream, validate); return Read(stream, limit); }
        }
        private static byte[] Read(Stream stream, int limit)
        {
            if (stream.Length < 0 || stream.Length > limit) throw Conflict();
            byte[] bytes = new byte[(int)stream.Length]; int offset = 0;
            while (offset < bytes.Length)
            { int count = stream.Read(bytes, offset, bytes.Length - offset); if (count == 0) throw Conflict(); offset += count; }
            return bytes;
        }
        private static void Check(string path, FileStream stream, Action<string> validate)
        {
            validate(path);
            AttributeTag information;
            if (!String.Equals(Path.GetFullPath(path), NativeFile.FinalPath(stream.SafeFileHandle), StringComparison.OrdinalIgnoreCase) ||
                !GetFileInformationByHandleEx(stream.SafeFileHandle, 9, out information, (uint)Marshal.SizeOf(typeof(AttributeTag))) ||
                (information.Attributes & (uint)FileAttributes.Directory) != 0 ||
                ((information.Attributes & (uint)FileAttributes.ReparsePoint) != 0 && !NativeFile.IsCloudTag(information.ReparseTag))) throw Conflict();
        }
        private static bool Present(string path)
        {
            try { File.GetAttributes(path); return true; }
            catch (FileNotFoundException) { return false; }
            catch (DirectoryNotFoundException) { return false; }
        }
        private static bool Same(byte[] left, byte[] right)
        {
            if (left == null || right == null) return left == right;
            if (left.Length != right.Length) return false;
            for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        private static void Arguments(string path, byte[] expected, byte[] replacement, int limit, Action<string> validate)
        {
            if (path == null || validate == null || replacement == null || limit < 0 || replacement.Length > limit ||
                (expected != null && expected.Length > limit)) throw new ArgumentException("Invalid file transaction arguments.");
        }
        private static InvalidDataException Conflict()
        { return new InvalidDataException("Dosya işlem sırasında değişti veya doğrulanamadı. Bilinmeyen dosya ve varsa kurtarma yedeği korundu."); }
        private static void Interleave(string phase, string path)
        {
#if TEST_BUILD
            var callback = InterleaveForChecks; if (callback != null) callback(phase, path);
#endif
        }

#if TEST_BUILD
        [ThreadStatic] internal static Action<string, string> InterleaveForChecks;

        internal static int RunOfflineChecks(string packageRoot)
        {
            string work = Path.Combine(Path.GetFullPath(packageRoot), "work");
            string root = Path.Combine(work, "file-transactions-" + Guid.NewGuid().ToString("N"));
            if (!Safety.Under(root, work) || !Safety.NoReparse(root)) throw new InvalidOperationException("Transaction fixture escaped work.");
            Directory.CreateDirectory(root);
            int checks = 0;
            Action<bool, string> assert = (ok, detail) => { if (!ok) throw new InvalidOperationException(detail); checks++; };
            Action<string> validate = path => {
                if (!Safety.Under(path, root) || !Safety.NoReparse(path)) throw Conflict();
            };
            Action<Action, string> rejects = (action, detail) => {
                bool rejected = false; try { action(); } catch (InvalidDataException) { rejected = true; }
                assert(rejected, detail);
            };
            var prior = InterleaveForChecks;
            byte[] original = Encoding.UTF8.GetBytes("original inert fixture"), replacement = Encoding.UTF8.GetBytes("owned replacement"),
                foreign = Encoding.UTF8.GetBytes("FOREIGN_FIRST_CANARY"), second = Encoding.UTF8.GetBytes("FOREIGN_SECOND_CANARY");
            string target = Path.Combine(root, "settings.json");
            Action<byte[]> put = bytes => {
                string incoming = Path.Combine(root, "incoming-" + Guid.NewGuid().ToString("N"));
                File.WriteAllBytes(incoming, bytes);
                if (File.Exists(target)) File.Replace(incoming, target, null); else File.Move(incoming, target);
            };
            Func<byte[], bool> retained = bytes => Directory.GetFiles(root).Any(path => Same(File.ReadAllBytes(path), bytes));
            try
            {
                File.WriteAllBytes(target, original);
                ReplaceExpected(target, original, replacement, 32768, validate);
                assert(Same(File.ReadAllBytes(target), replacement), "Expected replacement was not installed.");
                assert(Directory.GetFiles(root).Length == 1, "Successful replace left an owned temporary or backup.");
                ReplaceExpected(target, replacement, replacement, 32768, validate);
                assert(Same(File.ReadAllBytes(target), replacement), "Idempotent replacement changed bytes.");
                rejects(() => ReplaceExpected(target, original, second, 32768, validate), "Initial mismatch was accepted.");
                assert(Same(File.ReadAllBytes(target), replacement), "Initial mismatch replaced a foreign target.");

                put(original);
                InterleaveForChecks = (phase, path) => { if (phase == "replace" && path == target) put(foreign); };
                rejects(() => ReplaceExpected(target, original, replacement, 32768, validate), "Atomic replacement race was not detected.");
                assert(Same(File.ReadAllBytes(target), foreign), "First foreign replacement was not restored.");
                assert(Directory.GetFiles(root, "*.preserved").Any(path => Same(File.ReadAllBytes(path), foreign)), "Actual displaced foreign file was not backed up.");

                put(original);
                InterleaveForChecks = (phase, path) => {
                    if (path != target) return;
                    if (phase == "replace") put(foreign); else if (phase == "rollback") put(second);
                };
                rejects(() => ReplaceExpected(target, original, replacement, 32768, validate), "Rollback replacement race was accepted.");
                assert(retained(foreign) && retained(second), "Undo lost one of two competing writers' payloads.");
                assert(Directory.GetFiles(root, "*.rollback-preserved").Any(path => Same(File.ReadAllBytes(path), second)), "Second actual displaced file was not kept.");

                put(original);
                InterleaveForChecks = (phase, path) => { if (phase == "delete" && path == target) put(foreign); };
                rejects(() => DeleteExpected(target, original, 32768, validate), "Delete replacement race was not reported.");
                assert(Same(File.ReadAllBytes(target), foreign), "Handle deletion removed the renamed-in foreign file.");
                InterleaveForChecks = null;
                rejects(() => DeleteExpected(target, original, 32768, validate), "Delete accepted different bytes.");
                assert(Same(File.ReadAllBytes(target), foreign), "Rejected delete removed a foreign file.");
                DeleteExpected(target, foreign, 32768, validate);
                assert(!File.Exists(target), "Handle deletion failed for the expected file.");

                InterleaveForChecks = (phase, path) => { if (phase == "create" && path == target) put(foreign); };
                rejects(() => ReplaceExpected(target, null, replacement, 32768, validate), "Concurrent new-file create was accepted.");
                assert(Same(File.ReadAllBytes(target), foreign), "Concurrent new-file create was overwritten.");
                put(original);
                byte[] oversized = new byte[32769]; oversized[0] = 73;
                InterleaveForChecks = (phase, path) => { if (phase == "replace" && path == target) put(oversized); };
                rejects(() => ReplaceExpected(target, original, replacement, 32768, validate), "Oversized foreign replacement was accepted.");
                assert(retained(oversized), "Bounded reading lost oversized displaced data.");
                assert(Directory.GetFiles(root, "*.pending").Length == 0 && Directory.GetFiles(root, "*.restore").Length == 0,
                    "Owned source temporary remained after conflict cleanup.");
            }
            finally
            {
                InterleaveForChecks = prior;
                if (Safety.Under(root, work) && Safety.NoReparse(root)) Directory.Delete(root, true);
            }
            return checks;
        }
#endif
    }
}
