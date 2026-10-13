using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace DiscordAccess
{
    // A protected parent does not repair an existing child's owner or DACL.
    // Check the opened object before reading it, and keep this lease while
    // executable data is active so writes and pathname replacement are blocked.
    internal static class PrivateFileTrust
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct AttributeTag { internal uint Attributes, ReparseTag; }
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass,
            out AttributeTag information, uint size);
        [DllImport("advapi32.dll", ExactSpelling = true)]
        private static extern uint GetSecurityInfo(SafeFileHandle handle, int objectType, uint information,
            out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
        [DllImport("advapi32.dll", ExactSpelling = true)]
        private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern IntPtr LocalFree(IntPtr allocation);

        internal static FileStream ReadLease(string path)
        {
            FileStream lease = null;
            try
            {
                path = Path.GetFullPath(path);
                if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.Length < 3 || path[1] != ':' ||
                    path.IndexOf(':', 2) >= 0) throw Rejected();
                lease = Safety.ReadLease(path);
                AttributeTag information;
                if (!GetFileInformationByHandleEx(lease.SafeFileHandle, 9, out information, (uint)Marshal.SizeOf(typeof(AttributeTag))) ||
                    (information.Attributes & (uint)FileAttributes.Directory) != 0 ||
                    ((information.Attributes & (uint)FileAttributes.ReparsePoint) != 0 && !NativeFile.IsCloudTag(information.ReparseTag))) throw Rejected();
                using (var identity = WindowsIdentity.GetCurrent())
                    if (!StartupPathTrust.DescriptorTrustedFile(ReadDescriptor(lease.SafeFileHandle), identity.User)) throw Rejected();
                return lease;
            }
            catch
            {
                if (lease != null) lease.Dispose();
                throw Rejected();
            }
        }

        private static RawSecurityDescriptor ReadDescriptor(SafeFileHandle handle)
        {
            IntPtr owner, group, dacl, sacl, descriptor = IntPtr.Zero;
            try
            {
                // READ_CONTROL is included in the lease's GENERIC_READ access.
                // GetSecurityInfo binds owner and DACL to that exact open object.
                if (GetSecurityInfo(handle, 1, 5, out owner, out group, out dacl, out sacl, out descriptor) != 0 ||
                    descriptor == IntPtr.Zero) throw Rejected();
                uint length = GetSecurityDescriptorLength(descriptor);
                if (length == 0 || length > 1024 * 1024) throw Rejected();
                byte[] bytes = new byte[(int)length]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
                return new RawSecurityDescriptor(bytes, 0);
            }
            finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
        }

        private static InvalidDataException Rejected()
        { return new InvalidDataException("Özel destek dosyasının sahibi veya erişim izinleri güvenli doğrulanamadı. Mevcut erişim izinleri otomatik değiştirilmedi."); }
    }
}
