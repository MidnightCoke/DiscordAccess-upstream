using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Net;
using System.Security;

namespace DiscordAccess
{
    internal enum StartupStage
    {
        Source, Package, Copy, Engine, Proxy, Preflight, UpdateBridge, Configure, DiscordLaunch, Lifetime
    }

    // This is an output boundary: original exceptions can contain account URLs,
    // configuration, command lines and private paths. They are never retained.
    internal sealed class StartupFailureException : InvalidOperationException
    {
        internal readonly StartupStage Stage;
        private StartupFailureException(StartupStage stage, Exception error) : base(BuildMessage(stage, error))
        { Stage = stage; }

        internal static StartupFailureException From(StartupStage stage, Exception error)
        {
            var previous = error as StartupFailureException;
            return previous ?? new StartupFailureException(stage, error);
        }

        private static string StageText(StartupStage stage)
        {
            switch (stage)
            {
                case StartupStage.Source: return "[START-SOURCE] Kurulu Discord'u bulma";
                case StartupStage.Package: return "[START-PACKAGE] Motor paketini doğrulama";
                case StartupStage.Copy: return "[START-COPY] Ayrı Discord kopyasını hazırlama";
                case StartupStage.Engine: return "[START-ENGINE] Bağlantı motorunu başlatma";
                case StartupStage.Proxy: return "[START-PROXY] Uygulamaya özel proxy'yi hazırlama";
                case StartupStage.Preflight: return "[START-PREFLIGHT] Discord erişimini kontrol etme";
                case StartupStage.UpdateBridge: return "[START-UPDATE] Güncelleme köprüsünü hazırlama";
                case StartupStage.Configure: return "[START-CONFIGURE] Ayrı Discord bağlantısını ayarlama";
                case StartupStage.DiscordLaunch: return "[START-DISCORD] Ayrı Discord'u başlatma";
                case StartupStage.Lifetime: return "[START-LIFETIME] Ayrı Discord oturumunu izleme";
                default: return "[START-UNKNOWN] Başlangıç işlemi";
            }
        }

        private static string BuildMessage(StartupStage stage, Exception error)
        {
            string reason = "Beklenen işlem tamamlanamadı.";
            // Bound traversal even for deeply nested framework/task failures.
            // Only sealed types with fixed-vocabulary constructors are trusted.
            Exception current = error;
            for (int depth = 0; current != null && depth < 8; depth++)
            {
                if (current is ConnectivityFailureException)
                    return StageText(stage) + ": " + current.Message;
                if (current is DnsSelectionException)
                    return StageText(stage) + ": " + current.Message;
                var aggregate = current as AggregateException;
                if (aggregate != null)
                {
                    if (aggregate.InnerExceptions.Count != 1) break;
                    current = aggregate.InnerExceptions[0]; continue;
                }
                if (current is OperationCanceledException) reason = "İşlem iptal edildi.";
                else if (current is TimeoutException) reason = "İşlem zaman aşımına uğradı.";
                else if (current is UnauthorizedAccessException || current is SecurityException) reason = "Gerekli dosya veya süreç erişimine izin verilmedi.";
                else if (current is FileNotFoundException || current is DirectoryNotFoundException) reason = "Gerekli dosya veya klasör bulunamadı.";
                else if (current is InvalidDataException) reason = "Gerekli dosya veya yanıt doğrulanamadı.";
                else if (current is IOException) reason = ((current.HResult & 0xffff) == 32 || (current.HResult & 0xffff) == 33)
                    ? "Gerekli dosya başka bir işlem tarafından kullanılıyor." : "Dosya veya veri erişimi tamamlanamadı.";
                else if (current is Win32Exception) reason = "Windows süreç işlemi tamamlanamadı.";
                else if (current is WebException) reason = "Ağ erişimi doğrulanamadı.";
                else if (current is NotSupportedException) reason = "Gerekli işlem bu ortamda desteklenmiyor.";
                else if (current is PackageLoadException) reason = "Motor paketi doğrulanamadı; tam paketi yeni bir klasöre çıkarın.";
                current = current.InnerException;
            }
            return StageText(stage) + ": " + reason;
        }

        internal static int RunOfflineChecks()
        {
            int checks = 0;
            Action<bool, string> require = (ok, name) => { if (!ok) throw new InvalidOperationException(name); checks++; };
            const string secret = "SYNTHETIC_SECRET https://private.invalid/?token=PRIVATE C:\\PRIVATE\\config.json\u001b";
            foreach (StartupStage stage in Enum.GetValues(typeof(StartupStage)))
            {
                var failure = From(stage, new InvalidOperationException(secret, new IOException(secret)));
                require(failure.Stage == stage && failure.Message.StartsWith("[START-", StringComparison.Ordinal) &&
                    failure.InnerException == null && !failure.ToString().Contains("PRIVATE") && !failure.Message.Any(Char.IsControl),
                    "Startup diagnostics exposed an original exception or lost its stage.");
                require(ConsoleHost.SafeError(failure) == failure.Message, "Console suppressed a typed startup diagnostic.");
            }
            require(From((StartupStage)9876, new Exception(secret)).Message.StartsWith("[START-UNKNOWN]", StringComparison.Ordinal), "Unknown stage was reflected into output.");
            require(From(StartupStage.Copy, new FileNotFoundException(secret, secret)).Message.Contains("bulunamadı"), "Missing-file reason was lost.");
            require(From(StartupStage.Copy, new UnauthorizedAccessException(secret)).Message.Contains("izin verilmedi"), "Access-denied reason was lost.");
            require(From(StartupStage.Engine, new TimeoutException(secret)).Message.Contains("zaman aşımına"), "Timeout reason was lost.");
            require(From(StartupStage.Engine, new OperationCanceledException(secret)).Message.Contains("iptal edildi"), "Cancellation reason was lost.");
            require(From(StartupStage.Engine, new Win32Exception(5, secret)).InnerException == null &&
                !From(StartupStage.Engine, new Win32Exception(5, secret)).ToString().Contains("PRIVATE"), "Native error message leaked.");
            var typed = ConnectivityFailureException.Create(ConnectivityEndpoint.Manifest, ConnectivityFailureReason.Http, 429, ConnectivityResponseKind.Html);
            var wrapped = From(StartupStage.Preflight, new AggregateException(new InvalidOperationException(secret, typed)));
            require(wrapped.Message.Contains("HTTP 429") && wrapped.Message.Contains("HTML") && wrapped.Message.Contains("START-PREFLIGHT") &&
                !wrapped.ToString().Contains("PRIVATE") && wrapped.InnerException == null, "Safe nested HTTP evidence was lost or leaked context.");
            require(Object.ReferenceEquals(wrapped, From(StartupStage.Lifetime, wrapped)), "Already classified startup failure changed its original stage.");
            require(!From(StartupStage.Preflight, new AggregateException(new Exception(secret), typed)).Message.Contains("HTTP 429"), "Multi-failure aggregate was ambiguously attributed.");
            Exception deep = new Exception(secret);
            for (int i = 0; i < 40; i++) deep = new Exception(secret, deep);
            require(From(StartupStage.Source, deep).InnerException == null && !From(StartupStage.Source, deep).ToString().Contains("PRIVATE"), "Deep exceptions were retained or reflected.");
            require(!ConsoleHost.SafeError(new InvalidOperationException(secret)).Contains("PRIVATE"), "Untyped exception text became console output.");
            return checks;
        }
    }
}
