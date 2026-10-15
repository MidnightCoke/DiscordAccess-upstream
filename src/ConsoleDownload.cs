using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace DiscordAccess
{
    internal static class ConsoleDownload
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHGetKnownFolderPath(ref Guid folder, uint flags, IntPtr token, out IntPtr path);

        private static string DownloadsDirectory()
        {
            Guid downloads = new Guid("374DE290-123F-4565-9164-39C4925E467B");
            IntPtr path = IntPtr.Zero;
            try
            {
                if (SHGetKnownFolderPath(ref downloads, 0, IntPtr.Zero, out path) == 0 && path != IntPtr.Zero)
                    return Marshal.PtrToStringUni(path);
            }
            finally { if (path != IntPtr.Zero) Marshal.FreeCoTaskMem(path); }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        }

        internal static async Task<string> DownloadAsync(Controller controller, string link)
        {
            // Validate before touching directories. The signed URL is never
            // returned to output or added to a command line/file log.
            Uri uri = AttachmentDownloader.ValidateLink(link);
            string root = Path.GetFullPath(Path.Combine(DownloadsDirectory(), "DiscordAccess"));
            string destination = PrepareDestination(root, uri);
            await controller.DownloadFileAsync(link, destination, CancellationToken.None, null).ConfigureAwait(false);
            return destination;
        }

        internal static string PrepareDestination(string root, Uri uri)
        {
            root = Path.GetFullPath(root);
            string name = AttachmentDownloader.SuggestedName(uri);
            if (!Safety.NoReparse(root)) throw new AttachmentDownloadException("A redirected file path cannot be used in the download folder.");
            Directory.CreateDirectory(root);
            string unique = Path.Combine(root, DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N"));
            if (!Safety.Under(unique, root) || !Safety.NoReparse(unique)) throw new AttachmentDownloadException("The download folder could not be verified.");
            // Keep room for the downloader's fixed temporary filename and the
            // Windows Internet zone stream on this legacy .NET runtime.
            int maximumName = Math.Min(160, 230 - unique.Length - 1);
            if (maximumName < 16 || unique.Length > 200)
                throw new AttachmentDownloadException("The Downloads folder path is too long; a shorter Downloads location is needed.");
            if (name.Length > maximumName)
            {
                string extension = Path.GetExtension(name);
                if (extension.Length > 20) extension = "";
                name = "_" + name.Substring(0, maximumName - extension.Length - 1).TrimEnd('.', ' ') + extension;
            }
            Directory.CreateDirectory(unique);
            string destination = Path.Combine(unique, name);
            if (!Safety.Under(destination, unique) || !Safety.NoReparse(destination)) throw new AttachmentDownloadException("The download file could not be verified.");
            return destination;
        }

        internal static int RunOfflineChecks(string fixtureRoot)
        {
            string root = Path.Combine(Path.GetFullPath(fixtureRoot), "work", "cmd-download-" + Guid.NewGuid().ToString("N"));
            try
            {
                Uri uri = AttachmentDownloader.ValidateLink("https://cdn.discordapp.com/attachments/123/456/sample.txt?hm=FIXTURE_SECRET");
                string first = PrepareDestination(root, uri), second = PrepareDestination(root, uri);
                if (first == second || Path.GetFileName(first) != "sample.txt" || !Safety.Under(first, root) ||
                    first.Contains("FIXTURE_SECRET") || File.Exists(first) || !Directory.Exists(Path.GetDirectoryName(first)))
                    throw new InvalidOperationException("Console download paths were not unique, confined or query-free.");
                Uri longName = AttachmentDownloader.ValidateLink("https://cdn.discordapp.com/attachments/123/456/" + new string('a', 220) + ".txt");
                string compact = PrepareDestination(root, longName);
                if (compact.Length > 230 || !Safety.Under(compact, root) || Path.GetFileName(compact).Length < 1)
                    throw new InvalidOperationException("Console download filename exceeded legacy path capacity.");
                return 2;
            }
            finally { if (Directory.Exists(root) && Safety.Under(root, Path.Combine(Path.GetFullPath(fixtureRoot), "work")) && Safety.NoReparse(root)) Directory.Delete(root, true); }
        }
    }
}
