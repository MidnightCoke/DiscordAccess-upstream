using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace DiscordAccess
{
    internal enum ConnectivityEndpoint { Unknown, Gateway, Manifest, Updates }
    internal enum ConnectivityFailureReason { Http, Dns, Tls, Connect, Timeout, InvalidResponse, ResponseTooLarge, IncompleteResponse, Canceled, Other }
    internal enum ConnectivityResponseKind { None, Json, Html, Other }

    internal sealed class ConnectivityFailureException : InvalidOperationException
    {
        internal readonly ConnectivityEndpoint Endpoint;
        internal readonly ConnectivityFailureReason Reason;
        internal readonly int HttpStatus;
        internal readonly ConnectivityResponseKind ResponseKind;

        private ConnectivityFailureException(ConnectivityEndpoint endpoint, ConnectivityFailureReason reason, int status, ConnectivityResponseKind kind)
            : base(MessageFor(endpoint, reason, status, kind))
        { Endpoint = endpoint; Reason = reason; HttpStatus = status; ResponseKind = kind; }

        internal static ConnectivityFailureException Create(ConnectivityEndpoint endpoint, ConnectivityFailureReason reason,
            int httpStatus = 0, ConnectivityResponseKind responseKind = ConnectivityResponseKind.None)
        {
            if (!Enum.IsDefined(typeof(ConnectivityEndpoint), endpoint)) endpoint = ConnectivityEndpoint.Unknown;
            if (!Enum.IsDefined(typeof(ConnectivityFailureReason), reason)) reason = ConnectivityFailureReason.Other;
            if (!Enum.IsDefined(typeof(ConnectivityResponseKind), responseKind)) responseKind = ConnectivityResponseKind.None;
            if (reason != ConnectivityFailureReason.Http || httpStatus < 100 || httpStatus > 599) httpStatus = 0;
            return new ConnectivityFailureException(endpoint, reason, httpStatus, responseKind);
        }

        internal static ConnectivityFailureException From(ConnectivityEndpoint endpoint, Exception error, bool expired = false)
        {
            if (expired) return Create(endpoint, ConnectivityFailureReason.Timeout);
            Exception current = error;
            for (int depth = 0; current != null && depth < 8; depth++)
            {
                var known = current as ConnectivityFailureException;
                if (known != null) return known;
                var aggregate = current as AggregateException;
                if (aggregate != null)
                {
                    if (aggregate.InnerExceptions.Count != 1) break;
                    current = aggregate.InnerExceptions[0]; continue;
                }
                var web = current as WebException;
                if (web != null)
                {
                    var response = web.Response as HttpWebResponse;
                    if (response != null) return Create(endpoint, ConnectivityFailureReason.Http, (int)response.StatusCode, ContentKind(response.ContentType));
                    switch (web.Status)
                    {
                        case WebExceptionStatus.Timeout: return Create(endpoint, ConnectivityFailureReason.Timeout);
                        case WebExceptionStatus.NameResolutionFailure:
                        case WebExceptionStatus.ProxyNameResolutionFailure: return Create(endpoint, ConnectivityFailureReason.Dns);
                        case WebExceptionStatus.TrustFailure:
                        case WebExceptionStatus.SecureChannelFailure: return Create(endpoint, ConnectivityFailureReason.Tls);
                        case WebExceptionStatus.ConnectFailure:
                        case WebExceptionStatus.ConnectionClosed:
                        case WebExceptionStatus.KeepAliveFailure: return Create(endpoint, ConnectivityFailureReason.Connect);
                        case WebExceptionStatus.SendFailure:
                        case WebExceptionStatus.ReceiveFailure: return Create(endpoint, ConnectivityFailureReason.IncompleteResponse);
                        case WebExceptionStatus.RequestCanceled: return Create(endpoint, ConnectivityFailureReason.Canceled);
                        case WebExceptionStatus.ProtocolError: return Create(endpoint, ConnectivityFailureReason.Http);
                    }
                }
                if (current is TimeoutException) return Create(endpoint, ConnectivityFailureReason.Timeout);
                if (current is OperationCanceledException) return Create(endpoint, ConnectivityFailureReason.Canceled);
                if (current is AuthenticationException) return Create(endpoint, ConnectivityFailureReason.Tls);
                var socket = current as SocketException;
                if (socket != null)
                {
                    if (socket.SocketErrorCode == SocketError.TimedOut) return Create(endpoint, ConnectivityFailureReason.Timeout);
                    if (socket.SocketErrorCode == SocketError.HostNotFound || socket.SocketErrorCode == SocketError.NoData ||
                        socket.SocketErrorCode == SocketError.TryAgain || socket.SocketErrorCode == SocketError.NoRecovery)
                        return Create(endpoint, ConnectivityFailureReason.Dns);
                    return Create(endpoint, ConnectivityFailureReason.Connect);
                }
                if (current is InvalidDataException || current is DecoderFallbackException)
                    return Create(endpoint, ConnectivityFailureReason.InvalidResponse);
                // A TLS error may be nested inside an IOException, so classify
                // the inner chain first and use I/O only as a final fallback.
                current = current.InnerException;
            }
            return Create(endpoint, error is IOException ? ConnectivityFailureReason.IncompleteResponse : ConnectivityFailureReason.Other);
        }

        internal static ConnectivityResponseKind ContentKind(string contentType)
        {
            if (String.IsNullOrWhiteSpace(contentType)) return ConnectivityResponseKind.None;
            if (contentType.Length > 256) return ConnectivityResponseKind.Other;
            int separator = contentType.IndexOf(';');
            string kind = (separator < 0 ? contentType : contentType.Substring(0, separator)).Trim();
            if (String.Equals(kind, "application/json", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(kind, "text/json", StringComparison.OrdinalIgnoreCase)) return ConnectivityResponseKind.Json;
            if (String.Equals(kind, "text/html", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(kind, "application/xhtml+xml", StringComparison.OrdinalIgnoreCase)) return ConnectivityResponseKind.Html;
            return ConnectivityResponseKind.Other;
        }

        private static string MessageFor(ConnectivityEndpoint endpoint, ConnectivityFailureReason reason, int status, ConnectivityResponseKind kind)
        {
            string label;
            switch (endpoint)
            {
                case ConnectivityEndpoint.Gateway: label = "Discord Gateway API"; break;
                case ConnectivityEndpoint.Manifest: label = "Discord module list"; break;
                case ConnectivityEndpoint.Updates: label = "Discord update server"; break;
                default: label = "Connection"; break;
            }
            string detail;
            switch (reason)
            {
                case ConnectivityFailureReason.Http: detail = status == 0 ? "HTTP error response" : "HTTP " + status.ToString(System.Globalization.CultureInfo.InvariantCulture); break;
                case ConnectivityFailureReason.Dns: detail = "DNS resolution failed"; break;
                case ConnectivityFailureReason.Tls: detail = "TLS connection or certificate verification failed"; break;
                case ConnectivityFailureReason.Connect: detail = "could not connect to the network or the local proxy"; break;
                case ConnectivityFailureReason.Timeout: detail = "timed out"; break;
                case ConnectivityFailureReason.InvalidResponse: detail = "the expected response format could not be verified"; break;
                case ConnectivityFailureReason.ResponseTooLarge: detail = "the response exceeds the size limit"; break;
                case ConnectivityFailureReason.IncompleteResponse: detail = "the response transfer could not be completed"; break;
                case ConnectivityFailureReason.Canceled: detail = "the operation was canceled"; break;
                default: detail = "access could not be verified"; break;
            }
            if (kind != ConnectivityResponseKind.None) detail += "; response type " +
                (kind == ConnectivityResponseKind.Json ? "JSON" : kind == ConnectivityResponseKind.Html ? "HTML" : "other");
            return label + " check failed (" + detail + ").";
        }
    }

    // The caller temporarily admits its own PID through ProcessGate while checking.
    // No system proxy, DNS, certificate policy, account or Discord settings change.
    internal static class ConnectivityChecks
    {
        private const int DeadlineMilliseconds = 10000;
        private const int MaxResponseCharacters = 16384;
        private static readonly Uri Gateway = new Uri("https://discord.com/api/v10/gateway");
        private static readonly Uri Updates = new Uri("https://updates.discord.com/");

        internal static string CheckLaunch(int proxyPort, string version)
        {
            if (proxyPort < 1 || proxyPort > 65535) throw new ArgumentOutOfRangeException("proxyPort");
            Version parsed;
            if (!Version.TryParse(version, out parsed) || parsed.Build < 0 || parsed.Revision >= 0)
                throw new ArgumentException("The Discord version must contain three numeric components.", "version");
            TlsPolicy.UseSystemDefaults();
            CheckGateway(proxyPort);
            // Match module47924 in the installed official app: platform is added
            // to remoteQuery and x64 module names carry the .x64 suffix.
            var manifest = new Uri("https://discord.com/api/modules/stable/versions.json?host_version=" +
                Uri.EscapeDataString(version) + "&platform=win");
            int moduleCount = -1;
            Probe(manifest, "GET", proxyPort, ConnectivityEndpoint.Manifest, delegate(HttpWebResponse response)
            {
                moduleCount = InspectManifestResponse(response);
            });
            if (moduleCount == 0)
                return "Discord API access was verified through the proxy. The server returned an empty module list; the installed modules copied to the separate test copy will be used. Account sign-in and voice chat must be checked separately.";
            return "Access to the Discord API and desktop module updates was verified through the proxy. Account sign-in and voice chat must be checked separately.";
        }

        internal static string Check(int proxyPort)
        {
            if (proxyPort < 1 || proxyPort > 65535) throw new ArgumentOutOfRangeException("proxyPort");
            TlsPolicy.UseSystemDefaults();
            CheckGateway(proxyPort);
            Probe(Updates, "HEAD", proxyPort, ConnectivityEndpoint.Updates, delegate(HttpWebResponse response)
            {
                // The root is not a documented manifest endpoint: 404/405 proves
                // authenticated HTTPS reachability, not a completed desktop update.
                if (!AcceptsUpdateStatus(response.StatusCode))
                    throw StatusFailure(ConnectivityEndpoint.Updates, response);
            });
            return "HTTPS access to the Discord API and the update server was verified through the proxy. The desktop update, account sign-in and voice chat must be checked separately.";
        }

        internal static void CheckDnsCandidate(int proxyPort, CancellationToken token)
        {
            if (proxyPort < 1 || proxyPort > 65535) throw new ArgumentOutOfRangeException("proxyPort");
            token.ThrowIfCancellationRequested();
            TlsPolicy.UseSystemDefaults();
            Probe(Gateway, "GET", proxyPort, ConnectivityEndpoint.Gateway, InspectGatewayResponse, token);
        }

        private static void CheckGateway(int proxyPort)
        {
            Probe(Gateway, "GET", proxyPort, ConnectivityEndpoint.Gateway, InspectGatewayResponse);
        }

        private static void InspectGatewayResponse(HttpWebResponse response)
        {
            if (response.StatusCode != HttpStatusCode.OK)
                throw StatusFailure(ConnectivityEndpoint.Gateway, response);
            ValidateGateway(ReadSmallResponse(response, ConnectivityEndpoint.Gateway));
        }

        private static int InspectManifestResponse(HttpWebResponse response)
        {
            if (response.StatusCode != HttpStatusCode.OK)
                throw StatusFailure(ConnectivityEndpoint.Manifest, response);
            return ValidateModuleManifest(ReadSmallResponse(response, ConnectivityEndpoint.Manifest));
        }

        private static HttpWebRequest CreateRequest(Uri target, string method, int proxyPort)
        {
            var request = (HttpWebRequest)WebRequest.Create(target);
            // An explicit fixed proxy has no PAC/WPAD or DIRECT fallback.
            request.Proxy = new WebProxy(new Uri("http://127.0.0.1:" + proxyPort), false);
            request.AllowAutoRedirect = false;
            request.Method = method;
            request.Timeout = DeadlineMilliseconds;
            request.ReadWriteTimeout = DeadlineMilliseconds;
            request.KeepAlive = false;
            request.UserAgent = "DiscordAccess/3 (connectivity check)";
            request.Accept = "application/json";
            return request;
        }

        private static void Probe(Uri target, string method, int proxyPort, ConnectivityEndpoint endpoint, Action<HttpWebResponse> inspect,
            CancellationToken token = default(CancellationToken))
        {
            token.ThrowIfCancellationRequested();
            var request = CreateRequest(target, method, proxyPort);
            int expired = 0;
            // HttpWebRequest.ReadWriteTimeout alone is per operation; this also
            // bounds the whole response against a peer that sends bytes slowly.
            using (var canceled = token.Register(() => { try { request.Abort(); } catch { } }))
            using (var deadline = new Timer(delegate
            {
                Interlocked.Exchange(ref expired, 1);
                try { request.Abort(); } catch { }
            }, null, DeadlineMilliseconds, Timeout.Infinite))
            {
                try
                {
                    HttpWebResponse response;
                    try { response = (HttpWebResponse)request.GetResponse(); }
                    catch (WebException ex)
                    {
                        response = ex.Response as HttpWebResponse;
                        if (response == null) throw;
                    }
                    using (response) inspect(response);
                    token.ThrowIfCancellationRequested();
                    if (Volatile.Read(ref expired) != 0) throw new TimeoutException();
                }
                catch (Exception ex)
                {
                    token.ThrowIfCancellationRequested();
                    throw ConnectivityFailureException.From(endpoint, ex, Volatile.Read(ref expired) != 0);
                }
                finally { request.Abort(); }
            }
        }

        private static ConnectivityFailureException StatusFailure(ConnectivityEndpoint endpoint, HttpWebResponse response)
        {
            return ConnectivityFailureException.Create(endpoint, ConnectivityFailureReason.Http, (int)response.StatusCode,
                ConnectivityFailureException.ContentKind(response.ContentType));
        }

        private static bool AcceptsUpdateStatus(HttpStatusCode status)
        {
            int code = (int)status;
            return code >= 200 && code <= 299 || status == HttpStatusCode.NotFound || status == HttpStatusCode.MethodNotAllowed;
        }

        private static string ReadSmallResponse(HttpWebResponse response, ConnectivityEndpoint endpoint)
        {
            if (response.ContentLength > MaxResponseCharacters) throw ConnectivityFailureException.Create(endpoint, ConnectivityFailureReason.ResponseTooLarge);
            using (var reader = new StreamReader(response.GetResponseStream(), new UTF8Encoding(false, true)))
            {
                var result = new StringBuilder();
                char[] buffer = new char[1024];
                int read;
                while ((read = reader.Read(buffer, 0, buffer.Length)) != 0)
                {
                    if (result.Length + read > MaxResponseCharacters) throw ConnectivityFailureException.Create(endpoint, ConnectivityFailureReason.ResponseTooLarge);
                    result.Append(buffer, 0, read);
                }
                return result.ToString();
            }
        }

        private static void ValidateGateway(string body)
        {
            try
            {
                var payload = new JavaScriptSerializer { MaxJsonLength = MaxResponseCharacters, RecursionLimit = 8 }
                    .Deserialize<Dictionary<string, object>>(body);
                object value; Uri gateway;
                if (payload == null || !payload.TryGetValue("url", out value) || !(value is string) ||
                    !Uri.TryCreate((string)value, UriKind.Absolute, out gateway) || gateway.Scheme != "wss" ||
                    !String.Equals(gateway.DnsSafeHost, "gateway.discord.gg", StringComparison.OrdinalIgnoreCase) ||
                    gateway.Port != 443 || gateway.UserInfo.Length != 0 || gateway.Fragment.Length != 0)
                    throw new InvalidDataException();
            }
            catch (Exception ex)
            {
                if (!(ex is ArgumentException) && !(ex is InvalidOperationException) && !(ex is InvalidDataException)) throw;
                throw ConnectivityFailureException.Create(ConnectivityEndpoint.Gateway, ConnectivityFailureReason.InvalidResponse);
            }
        }

        private static int ValidateModuleManifest(string body)
        {
            try
            {
                var payload = new JavaScriptSerializer { MaxJsonLength = MaxResponseCharacters, RecursionLimit = 8 }
                    .Deserialize<Dictionary<string, object>>(body);
                // The official endpoint returns {} for some current Windows
                // hosts (verified with 1.0.9261). Discord's bundled legacy
                // updater accepts that as no offered updates: its missing
                // remote version and missing pending update both default to 0.
                // Prepare has already validated and copied the installed core.
                if (payload != null && payload.Count == 0) return 0;
                if (payload == null ||
                    !(payload.ContainsKey("discord_desktop_core") || payload.ContainsKey("discord_desktop_core.x64")))
                    throw new InvalidDataException();
                foreach (var entry in payload)
                {
                    if (entry.Key.Length < 1 || entry.Key.Length > 128 ||
                        !Regex.IsMatch(entry.Key, @"\Adiscord_[a-z0-9_]+(?:\.x64)?\z", RegexOptions.CultureInvariant) ||
                        !(entry.Value is int || entry.Value is long || entry.Value is decimal || entry.Value is double))
                        throw new InvalidDataException();
                    decimal number = Convert.ToDecimal(entry.Value);
                    if (number < 0 || number > Int32.MaxValue || number != Decimal.Truncate(number))
                        throw new InvalidDataException();
                }
                return payload.Count;
            }
            catch (Exception ex)
            {
                if (!(ex is ArgumentException) && !(ex is InvalidOperationException) &&
                    !(ex is InvalidDataException) && !(ex is OverflowException)) throw;
                throw ConnectivityFailureException.Create(ConnectivityEndpoint.Manifest, ConnectivityFailureReason.InvalidResponse);
            }
        }

        internal static void RunOfflineChecks()
        {
            ValidateGateway("{\"url\":\"wss://gateway.discord.gg/\"}");
            foreach (string body in new[] { "{}", "[]", "null", "not json", "{\"url\":7}",
                "{\"url\":\"ws://gateway.discord.gg/\"}", "{\"url\":\"wss://gateway.discord.gg.attacker.invalid/\"}",
                "{\"url\":\"wss://gateway.discord.gg:444/\"}", "{\"url\":\"wss://user@gateway.discord.gg/\"}",
                "{\"url\":\"wss://gateway.discord.gg/#fragment\"}" })
            {
                bool failed = false;
                try { ValidateGateway(body); } catch (InvalidOperationException) { failed = true; }
                if (!failed) throw new InvalidOperationException("Malformed gateway response was accepted.");
            }
            foreach (int code in new[] { 200, 204, 404, 405 })
                if (!AcceptsUpdateStatus((HttpStatusCode)code)) throw new InvalidOperationException("Expected updates-host status rejected.");
            foreach (int code in new[] { 301, 302, 401, 403, 407, 429, 500, 502, 503 })
                if (AcceptsUpdateStatus((HttpStatusCode)code)) throw new InvalidOperationException("Failed updates-host status accepted.");
            if (ValidateModuleManifest("{}") != 0 || ValidateModuleManifest(" { } ") != 0)
                throw new InvalidOperationException("Official empty module manifest was rejected.");
            if (ValidateModuleManifest("{\"discord_desktop_core\":1,\"discord_voice\":0}") != 2 ||
                ValidateModuleManifest("{\"discord_desktop_core.x64\":123,\"discord_voice.x64\":456}") != 2)
                throw new InvalidOperationException("Module manifest count is incorrect.");
            foreach (string body in new[] { "[]", "null", "not json", "<html>blocked</html>", "{\"error\":1}",
                "{\"discord_desktop_core\":-1}", "{\"discord_desktop_core\":1.5}", "{\"discord_desktop_core\":true}",
                "{\"discord_desktop_core\":\"1\"}", "{\"discord_desktop_core\":null}",
                "{\"discord_desktop_core\":2147483648}", "{\"discord_desktop_core\":{\"version\":1}}",
                "{\"discord_desktop_core\":1,\"error\":0}", "{\"discord_desktop_core\":1,\"error\":\"private-token\"}" })
            {
                bool failed = false;
                try { ValidateModuleManifest(body); } catch (InvalidOperationException) { failed = true; }
                if (!failed) throw new InvalidOperationException("Malformed module manifest was accepted.");
            }
            RunFailureChecks();
            FixtureResponse(429, "text/html", "<html>SYNTHETIC_SECRET</html>", ConnectivityEndpoint.Gateway, ConnectivityFailureReason.Http);
            FixtureResponse(503, "application/json", "{\"secret\":\"SYNTHETIC_SECRET\"}", ConnectivityEndpoint.Manifest, ConnectivityFailureReason.Http);
            FixtureResponse(200, "application/json", "{\"url\":\"wss://SYNTHETIC_SECRET.invalid/\"}", ConnectivityEndpoint.Gateway, ConnectivityFailureReason.InvalidResponse);
            FixtureResponse(200, "text/html", "<html>SYNTHETIC_SECRET</html>", ConnectivityEndpoint.Manifest, ConnectivityFailureReason.InvalidResponse);
            FixtureResponse(200, "application/json", new string('x', MaxResponseCharacters + 1), ConnectivityEndpoint.Gateway, ConnectivityFailureReason.ResponseTooLarge);
            FixtureResponse(200, "application/json", "{\"url\":\"wss://gateway.discord.gg/\"}", ConnectivityEndpoint.Gateway, null);
            FixtureResponse(200, "application/json", "{}", ConnectivityEndpoint.Manifest, null);
            FixtureCancellation();

            // Hold the port without listening so another process cannot take it.
            // The only attempted socket is loopback: a refused fixed proxy must
            // fail immediately rather than trying the external destination.
            using (var reserved = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
            {
                reserved.ExclusiveAddressUse = true;
                reserved.Bind(new IPEndPoint(IPAddress.Loopback, 0));
                int port = ((IPEndPoint)reserved.LocalEndPoint).Port;
                var request = CreateRequest(Gateway, "GET", port);
                if (request.Proxy.IsBypassed(Gateway) || request.Proxy.GetProxy(Gateway).Host != "127.0.0.1" ||
                    request.Proxy.GetProxy(Gateway).Port != port || request.AllowAutoRedirect)
                    throw new InvalidOperationException("Connectivity check can bypass its local proxy.");
                request.Abort();
                bool refused = false;
                try { Check(port); }
                catch (ConnectivityFailureException ex)
                {
                    refused = ex.Endpoint == ConnectivityEndpoint.Gateway && ex.Reason == ConnectivityFailureReason.Connect && ex.InnerException == null;
                }
                if (!refused) throw new InvalidOperationException("Refused loopback proxy did not fail closed.");
            }
        }

        internal static int RunFailureChecks()
        {
            int checks = 0;
            Action<bool, string> require = (ok, name) => { if (!ok) throw new InvalidOperationException(name); checks++; };
            const string secret = "SYNTHETIC_SECRET https://private.invalid/?token=PRIVATE C:\\PRIVATE\\config.json\u001b";
            var cases = new Dictionary<WebExceptionStatus, ConnectivityFailureReason> {
                { WebExceptionStatus.Timeout, ConnectivityFailureReason.Timeout },
                { WebExceptionStatus.NameResolutionFailure, ConnectivityFailureReason.Dns },
                { WebExceptionStatus.ProxyNameResolutionFailure, ConnectivityFailureReason.Dns },
                { WebExceptionStatus.TrustFailure, ConnectivityFailureReason.Tls },
                { WebExceptionStatus.SecureChannelFailure, ConnectivityFailureReason.Tls },
                { WebExceptionStatus.ConnectFailure, ConnectivityFailureReason.Connect },
                { WebExceptionStatus.ReceiveFailure, ConnectivityFailureReason.IncompleteResponse },
                { WebExceptionStatus.RequestCanceled, ConnectivityFailureReason.Canceled },
                { WebExceptionStatus.ProtocolError, ConnectivityFailureReason.Http }
            };
            foreach (var item in cases)
            {
                var error = ConnectivityFailureException.From(ConnectivityEndpoint.Gateway,
                    new InvalidOperationException(secret, new WebException(secret, item.Key)));
                require(error.Endpoint == ConnectivityEndpoint.Gateway && error.Reason == item.Value && error.InnerException == null &&
                    !error.ToString().Contains("PRIVATE") && !ConsoleHost.SafeError(error).Contains("SYNTHETIC_SECRET"), "Nested web failure was misclassified or exposed private data.");
                require(ConsoleHost.SafeError(error) == error.Message, "Console suppressed a typed connectivity failure.");
            }
            require(ConnectivityFailureException.From(ConnectivityEndpoint.Manifest, new IOException(secret, new AuthenticationException(secret))).Reason == ConnectivityFailureReason.Tls,
                "Nested TLS failure was reduced to a generic I/O failure.");
            require(ConnectivityFailureException.From(ConnectivityEndpoint.Gateway, new WebException(secret, WebExceptionStatus.RequestCanceled), true).Reason == ConnectivityFailureReason.Timeout,
                "Deadline abort was reported as user cancellation.");
            require(ConnectivityFailureException.From(ConnectivityEndpoint.Updates, new SocketException((int)SocketError.HostNotFound)).Reason == ConnectivityFailureReason.Dns,
                "Socket DNS failure was not classified.");
            require(ConnectivityFailureException.From(ConnectivityEndpoint.Gateway, new DecoderFallbackException(secret)).Reason == ConnectivityFailureReason.InvalidResponse,
                "Invalid UTF-8 response was not classified.");
            require(ConnectivityFailureException.ContentKind("Application/JSON; charset=utf-8") == ConnectivityResponseKind.Json &&
                ConnectivityFailureException.ContentKind("text/html; PRIVATE") == ConnectivityResponseKind.Html &&
                ConnectivityFailureException.ContentKind(secret) == ConnectivityResponseKind.Other &&
                ConnectivityFailureException.ContentKind(null) == ConnectivityResponseKind.None, "Content type classification reflected private metadata.");
            foreach (int code in new[] { -1, 0, 99, 600, Int32.MaxValue })
            {
                var failure = ConnectivityFailureException.Create(ConnectivityEndpoint.Manifest, ConnectivityFailureReason.Http, code);
                require(failure.HttpStatus == 0 && failure.Message.Contains("HTTP error response"), "Out-of-range HTTP status was accepted.");
            }
            var unknown = ConnectivityFailureException.Create((ConnectivityEndpoint)555, (ConnectivityFailureReason)666, 429, (ConnectivityResponseKind)777);
            require(unknown.Endpoint == ConnectivityEndpoint.Unknown && unknown.Reason == ConnectivityFailureReason.Other &&
                unknown.HttpStatus == 0 && !unknown.Message.Contains("555") && !unknown.Message.Contains("666") && !unknown.Message.Contains("777"),
                "Unknown enum values were reflected into diagnostics.");
            foreach (Action<string> validate in new Action<string>[] { ValidateGateway, body => ValidateModuleManifest(body) })
            {
                ConnectivityFailureException failure = null;
                try { validate("{\"SYNTHETIC_SECRET\":\"PRIVATE\"}"); }
                catch (ConnectivityFailureException error) { failure = error; }
                require(failure != null && failure.Reason == ConnectivityFailureReason.InvalidResponse && failure.InnerException == null &&
                    !failure.ToString().Contains("PRIVATE") && !failure.Message.Contains("SYNTHETIC_SECRET"), "Malformed payload retained or exposed parser input.");
            }
            return checks;
        }

        // Exercise the actual HttpWebRequest status path and response validators.
        // Every request uses a fixed loopback HTTP proxy; this fixture creates no
        // DNS query or external connection and does not alter production targets.
        private static void FixtureCancellation()
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.ExclusiveAddressUse = true; listener.Start(1);
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            using (var cancellation = new CancellationTokenSource())
            {
                Task server = Task.Run(() => {
                    using (var client = listener.AcceptTcpClient())
                    using (var stream = client.GetStream())
                    {
                        stream.ReadTimeout = 3000;
                        int matched = 0;
                        byte[] ending = new byte[] { 13, 10, 13, 10 };
                        for (int read = 0; read < 16384 && matched != 4; read++)
                        {
                            int value = stream.ReadByte();
                            if (value < 0) throw new IOException("Cancellation fixture request incomplete.");
                            matched = value == ending[matched] ? matched + 1 : (value == 13 ? 1 : 0);
                        }
                        if (matched != 4) throw new IOException("Cancellation fixture request too large.");
                        cancellation.Cancel();
                        // This peer sends no response. Token cancellation must
                        // abort the real request rather than wait for its timeout.
                        try { if (stream.ReadByte() != -1) throw new InvalidOperationException("Canceled request remained open."); }
                        catch (IOException) { }
                    }
                });
                var elapsed = System.Diagnostics.Stopwatch.StartNew();
                bool canceled = false;
                try
                {
                    Probe(new Uri("http://discord.com/fixture"), "GET", port, ConnectivityEndpoint.Gateway,
                        InspectGatewayResponse, cancellation.Token);
                }
                catch (OperationCanceledException) { canceled = true; }
                finally
                {
                    listener.Stop();
                    if (!server.Wait(4000)) throw new InvalidOperationException("Cancellation fixture exceeded its deadline.");
                }
                if (!canceled || elapsed.ElapsedMilliseconds >= 4000)
                    throw new InvalidOperationException("In-flight DNS selection request did not cancel promptly.");
            }
        }

        private static void FixtureResponse(int status, string contentType, string body, ConnectivityEndpoint endpoint, ConnectivityFailureReason? expected)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.ExclusiveAddressUse = true; listener.Start(1);
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Task server = Task.Run(() => {
                using (var client = listener.AcceptTcpClient())
                using (var stream = client.GetStream())
                {
                    stream.ReadTimeout = 3000; stream.WriteTimeout = 3000;
                    int matched = 0;
                    byte[] ending = new byte[] { 13, 10, 13, 10 };
                    for (int read = 0; read < 16384 && matched != 4; read++)
                    {
                        int value = stream.ReadByte(); if (value < 0) throw new IOException("Fixture request incomplete.");
                        matched = value == ending[matched] ? matched + 1 : (value == 13 ? 1 : 0);
                    }
                    if (matched != 4) throw new IOException("Fixture request too large.");
                    byte[] payload = Encoding.UTF8.GetBytes(body);
                    byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + " Fixture\r\nContent-Type: " + contentType +
                        "\r\nContent-Length: " + payload.Length + "\r\nConnection: close\r\n\r\n");
                    stream.Write(header, 0, header.Length); stream.Write(payload, 0, payload.Length); stream.Flush();
                }
            });
            try
            {
                ConnectivityFailureException failure = null;
                try
                {
                    Probe(new Uri("http://discord.com/fixture"), "GET", port, endpoint,
                        response => { if (endpoint == ConnectivityEndpoint.Gateway) InspectGatewayResponse(response); else InspectManifestResponse(response); });
                }
                catch (ConnectivityFailureException error) { failure = error; }
                if (!server.Wait(4000)) throw new InvalidOperationException("Loopback HTTP fixture exceeded its deadline.");
                if (!expected.HasValue)
                { if (failure != null) throw new InvalidOperationException("Valid loopback response was rejected."); return; }
                if (failure == null || failure.Endpoint != endpoint || failure.Reason != expected.Value || failure.InnerException != null ||
                    failure.ToString().Contains("SYNTHETIC_SECRET") || failure.ToString().Contains("PRIVATE") || failure.Message.Contains("http://"))
                    throw new InvalidOperationException("Loopback response classification leaked data or lost endpoint/reason.");
                if (expected == ConnectivityFailureReason.Http && (failure.HttpStatus != status ||
                    failure.ResponseKind != ConnectivityFailureException.ContentKind(contentType)))
                    throw new InvalidOperationException("HTTP failure lost its status or safe response type.");
            }
            finally
            {
                listener.Stop();
                try { server.Wait(4000); } catch { }
            }
        }
    }
}
