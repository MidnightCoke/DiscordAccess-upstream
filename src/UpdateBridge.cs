using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace DiscordAccess
{
    // Discord's native updater does not consistently use Chromium/HTTP_PROXY.
    // Only the isolated profile points at this process-owned loopback endpoint.
    // Every remote request still passes through ProcessGate and its WARP proxy.
    internal sealed class UpdateBridge : IDisposable
    {
        private const int MaxConnections = 16;
        private const int MaxHeaderBytes = 16384;
        private const int MaxJsonBytes = 4 * 1024 * 1024;
        private const int RequestMilliseconds = 180000;
        private readonly TcpListener listener;
        private readonly int proxyPort;
        private readonly string token;
        private readonly Func<TcpClient, int, Task<bool>> authorize;
        private readonly Action<string> log;
        private readonly object sync = new object();
        private readonly HashSet<TcpClient> clients = new HashSet<TcpClient>();
        private readonly HashSet<HttpWebRequest> requests = new HashSet<HttpWebRequest>();
        private readonly SemaphoreSlim capacity = new SemaphoreSlim(MaxConnections, MaxConnections);
        private readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        private int port, started, disposed;
        private readonly ProcessGate.TraceBudget failureBudget = new ProcessGate.TraceBudget();

        internal Action Faulted;
        internal int Port { get { return port; } }
        internal string BaseUrl
        {
            get
            {
                if (Port == 0 || Volatile.Read(ref disposed) != 0) throw new InvalidOperationException("The update bridge is not open.");
                return "http://127.0.0.1:" + Port.ToString(CultureInfo.InvariantCulture) + "/" + token;
            }
        }
        internal string NewEndpoint { get { return BaseUrl + "/updates/"; } }
        internal string LegacyEndpoint { get { return BaseUrl + "/legacy"; } }
        internal int TrackedClients { get { lock (sync) return clients.Count; } }
        internal int TrackedRequests { get { lock (sync) return requests.Count; } }

        internal UpdateBridge(int proxyPort, Func<TcpClient, int, Task<bool>> authorize, Action<string> log)
        {
            if (proxyPort < 1 || proxyPort > 65535) throw new ArgumentOutOfRangeException("proxyPort");
            if (authorize == null) throw new ArgumentNullException("authorize");
            this.proxyPort = proxyPort; this.authorize = authorize; this.log = log;
            byte[] secret = new byte[24];
            using (var random = RandomNumberGenerator.Create()) random.GetBytes(secret);
            token = BitConverter.ToString(secret).Replace("-", "").ToLowerInvariant();
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Server.ExclusiveAddressUse = true;
            NoInheritance(listener.Server);
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
        private static void NoInheritance(Socket socket)
        {
            if (!SetHandleInformation(socket.Handle, 1, 0)) throw new IOException("The update socket could not be set up safely.");
        }

        internal void Start()
        {
            if (Volatile.Read(ref disposed) != 0 || Interlocked.Exchange(ref started, 1) != 0) throw new InvalidOperationException();
            // This only changes this process's TLS options, never Windows settings.
            TlsPolicy.UseSystemDefaults();
            listener.Start(MaxConnections);
            port = ((IPEndPoint)listener.LocalEndpoint).Port;
            AcceptLoop();
        }

        private async void AcceptLoop()
        {
            try
            {
                while (!cancellation.IsCancellationRequested)
                {
                    TcpClient client = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
                    if (!capacity.Wait(0)) { client.Close(); continue; }
                    try
                    {
                        NoInheritance(client.Client);
                        lock (sync)
                        {
                            if (cancellation.IsCancellationRequested) { client.Close(); capacity.Release(); return; }
                            clients.Add(client);
                        }
                    }
                    catch { client.Close(); capacity.Release(); throw; }
                    Handle(client);
                }
            }
            catch
            {
                bool unexpected = !cancellation.IsCancellationRequested;
                Dispose();
                if (unexpected && Faulted != null) { try { Faulted(); } catch { } }
            }
        }

        private sealed class BridgeRequest
        {
            internal string Method;
            internal Uri Target;
        }

        private enum RequestStage
        {
            ClientOwnership, ClientHeader, ClientRequest, UpstreamResponse,
            UpstreamHeaders, UpstreamBody, ManifestRewrite, ClientResponseHeader, ClientResponseBody
        }

        private static string DescribeFailure(RequestStage stage, Exception failure, int? status)
        {
            // All fields come from fixed categories or numeric protocol values.
            // Exception messages/URLs/headers/body content are never included.
            string category = failure is TimeoutException ? "timeout" :
                failure is InvalidDataException ? "invalid-data" :
                failure is WebException ? "upstream-network" :
                failure is IOException ? "io" :
                failure is OperationCanceledException ? "cancelled" :
                failure is SocketException ? "socket" : "unexpected";
            string detail = "stage=" + stage + "; category=" + category;
            if (status.HasValue) detail += "; HTTP=" + status.Value.ToString(CultureInfo.InvariantCulture);
            var web = failure as WebException;
            if (web != null) detail += "; web-status=" + ((int)web.Status).ToString(CultureInfo.InvariantCulture);
            Exception current = failure;
            for (int i = 0; current != null && i < 4; i++, current = current.InnerException)
            {
                var socket = current as SocketException;
                if (socket == null) continue;
                detail += "; socket-code=" + socket.ErrorCode.ToString(CultureInfo.InvariantCulture);
                break;
            }
            return detail;
        }

        private async Task<string> ReadHeader(TcpClient client, CancellationToken token)
        {
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
            using (var memory = new MemoryStream())
            {
                deadline.CancelAfter(10000);
                using (deadline.Token.Register(client.Close))
                {
                    byte[] buffer = new byte[1024]; int scan = 0;
                    try
                    {
                        while (memory.Length < MaxHeaderBytes)
                        {
                            int count = await client.GetStream().ReadAsync(buffer, 0, Math.Min(buffer.Length, MaxHeaderBytes - (int)memory.Length), deadline.Token).ConfigureAwait(false);
                            deadline.Token.ThrowIfCancellationRequested();
                            // Chromium can open and close an unused preconnection.
                            // No HTTP request has failed when no bytes arrived.
                            if (count == 0)
                            {
                                if (memory.Length == 0) return null;
                                throw new EndOfStreamException();
                            }
                            memory.Write(buffer, 0, count);
                            byte[] bytes = memory.GetBuffer();
                            for (; scan + 3 < memory.Length; scan++)
                            {
                                if (bytes[scan] != 13 || bytes[scan + 1] != 10 || bytes[scan + 2] != 13 || bytes[scan + 3] != 10) continue;
                                if (scan + 4 != memory.Length) throw new InvalidDataException("Request bodies and pipelining are unsupported.");
                                for (int i = 0; i < memory.Length; i++) if (bytes[i] > 127) throw new InvalidDataException();
                                return Encoding.ASCII.GetString(bytes, 0, (int)memory.Length);
                            }
                        }
                    }
                    catch
                    {
                        if (deadline.IsCancellationRequested && !token.IsCancellationRequested) throw new TimeoutException();
                        throw;
                    }
                }
            }
            throw new InvalidDataException("Header limit exceeded.");
        }

        private BridgeRequest ParseRequest(string header)
        {
            if (String.IsNullOrEmpty(header) || header.Length > MaxHeaderBytes || !header.EndsWith("\r\n\r\n", StringComparison.Ordinal)) throw new InvalidDataException();
            string[] lines = header.Substring(0, header.Length - 4).Split(new[] { "\r\n" }, StringSplitOptions.None);
            if (lines.Any(line => line.Any(c => c > 126 || c < 32 && c != '\t'))) throw new InvalidDataException();
            string[] parts = lines[0].Split(' ');
            if (parts.Length != 3 || (parts[0] != "GET" && parts[0] != "HEAD") || (parts[2] != "HTTP/1.1" && parts[2] != "HTTP/1.0")) throw new InvalidDataException();
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            bool host = false;
            for (int i = 1; i < lines.Length; i++)
            {
                int colon = lines[i].IndexOf(':');
                if (colon < 1 || !Regex.IsMatch(lines[i].Substring(0, colon), @"\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z")) throw new InvalidDataException();
                string name = lines[i].Substring(0, colon), value = lines[i].Substring(colon + 1).Trim();
                if (!names.Add(name)) throw new InvalidDataException();
                if (name.Equals("Host", StringComparison.OrdinalIgnoreCase))
                {
                    host = value == "127.0.0.1:" + Port.ToString(CultureInfo.InvariantCulture);
                    if (!host) throw new InvalidDataException();
                }
                if (name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("Expect", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase) && value != "0") throw new InvalidDataException();
            }
            if (!host) throw new InvalidDataException();
            return new BridgeRequest { Method = parts[0], Target = MapTarget(parts[1]) };
        }

        private Uri MapTarget(string path)
        {
            string prefix = "/" + token;
            if (String.IsNullOrEmpty(path) || path.Length > 8192 || path.Any(c => c < 33 || c > 126 || c == '\\' || c == '#') || !path.StartsWith(prefix + "/", StringComparison.Ordinal)) throw new InvalidDataException();
            string remainder = path.Substring(prefix.Length), target;
            if (remainder.StartsWith("/updates/", StringComparison.Ordinal)) target = "https://updates.discord.com/" + remainder.Substring(9);
            else if (remainder == "/legacy" || remainder.StartsWith("/legacy/", StringComparison.Ordinal) || remainder.StartsWith("/legacy?", StringComparison.Ordinal)) target = "https://discord.com/api" + remainder.Substring(7);
            else if (remainder.StartsWith("/download/", StringComparison.Ordinal))
            {
                string download = remainder.Substring(10);
                int slash = download.IndexOf('/');
                if (slash < 1) throw new InvalidDataException();
                string host = download.Substring(0, slash);
                if (!AllowedHost(host)) throw new InvalidDataException();
                target = "https://" + host + download.Substring(slash);
            }
            else throw new InvalidDataException();
            Uri uri;
            if (!TryAllowedUri(target, out uri)) throw new InvalidDataException();
            return uri;
        }

        private static bool AllowedHost(string host)
        {
            if (String.IsNullOrEmpty(host) || host.Length > 253 || !Regex.IsMatch(host, @"\A[A-Za-z0-9.-]+\z")) return false;
            if (host.Split('.').Any(label => label.Length < 1 || label.Length > 63 || !Regex.IsMatch(label, @"\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z"))) return false;
            IPAddress address;
            if (IPAddress.TryParse(host, out address)) return false;
            return ProcessGate.AllowedDomains.Any(domain => host.Equals(domain, StringComparison.OrdinalIgnoreCase) || host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase));
        }

        private static bool TryAllowedUri(string value, out Uri uri)
        {
            uri = null;
            if (String.IsNullOrEmpty(value) || value.Length > 8192 || !value.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return false;
            int authorityEnd = value.IndexOfAny(new[] { '/', '?', '#' }, 8);
            string authority = value.Substring(8, (authorityEnd < 0 ? value.Length : authorityEnd) - 8);
            if (authority.IndexOf('@') >= 0) return false;
            return !value.Any(c => c < 33 || c > 126 || c == '\\') && Uri.TryCreate(value, UriKind.Absolute, out uri) &&
                uri.Scheme == Uri.UriSchemeHttps && uri.Port == 443 && String.IsNullOrEmpty(uri.UserInfo) && String.IsNullOrEmpty(uri.Fragment) && AllowedHost(uri.DnsSafeHost);
        }

        private string LocalUrl(Uri target)
        {
            Uri allowed;
            if (!TryAllowedUri(target.AbsoluteUri, out allowed)) throw new InvalidDataException("Unsupported update destination.");
            return BaseUrl + "/download/" + allowed.DnsSafeHost.ToLowerInvariant() + allowed.PathAndQuery;
        }

        private string RewriteLocation(Uri source, string location)
        {
            if (String.IsNullOrEmpty(location)) return null;
            if (location.Length > 8192 || location.Any(c => c < 33 || c > 126 || c == '\\')) throw new InvalidDataException();
            Uri destination;
            if (!Uri.TryCreate(source, location, out destination)) throw new InvalidDataException();
            return LocalUrl(destination);
        }

        private object RewriteJsonValue(object value)
        {
            string text = value as string;
            if (text != null)
            {
                Uri target;
                return TryAllowedUri(text, out target) ? LocalUrl(target) : text;
            }
            var dictionary = value as IDictionary<string, object>;
            if (dictionary != null)
            {
                foreach (string key in dictionary.Keys.ToArray()) dictionary[key] = RewriteJsonValue(dictionary[key]);
                return dictionary;
            }
            var list = value as IList;
            if (list != null) for (int i = 0; i < list.Count; i++) list[i] = RewriteJsonValue(list[i]);
            return value;
        }

        private byte[] RewriteJson(byte[] original)
        {
            if (original.Length > MaxJsonBytes) throw new InvalidDataException("Update manifest limit exceeded.");
            string json = new UTF8Encoding(false, true).GetString(original).TrimStart('\uFEFF');
            var serializer = new JavaScriptSerializer { MaxJsonLength = MaxJsonBytes, RecursionLimit = 64 };
            object document = serializer.DeserializeObject(json);
            byte[] output = Encoding.UTF8.GetBytes(serializer.Serialize(RewriteJsonValue(document)));
            if (output.Length > MaxJsonBytes) throw new InvalidDataException("Rewritten update manifest limit exceeded.");
            return output;
        }

        private HttpWebRequest CreateRequest(BridgeRequest input)
        {
            var request = (HttpWebRequest)WebRequest.Create(input.Target);
            request.Proxy = new WebProxy(new Uri("http://127.0.0.1:" + proxyPort.ToString(CultureInfo.InvariantCulture)), false);
            request.AllowAutoRedirect = false;
            request.Method = input.Method;
            request.Timeout = RequestMilliseconds;
            request.ReadWriteTimeout = 30000;
            request.KeepAlive = false;
            request.UserAgent = "DiscordAccess/3";
            request.Accept = "application/json, */*";
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            request.UseDefaultCredentials = false;
            request.Credentials = null;
            request.CookieContainer = null;
            request.PreAuthenticate = false;
            // Require the framework's hostname, validity and chain checks to pass.
            request.ServerCertificateValidationCallback = delegate(object sender, System.Security.Cryptography.X509Certificates.X509Certificate certificate,
                System.Security.Cryptography.X509Certificates.X509Chain chain, SslPolicyErrors errors) { return errors == SslPolicyErrors.None; };
            return request;
        }

        private static bool IsJson(string contentType)
        {
            string media = (contentType ?? "").Split(';')[0].Trim();
            return media.Equals("application/json", StringComparison.OrdinalIgnoreCase) || media.EndsWith("+json", StringComparison.OrdinalIgnoreCase);
        }

        private static async Task<byte[]> ReadJson(Stream stream, CancellationToken token)
        {
            using (var output = new MemoryStream())
            {
                byte[] buffer = new byte[16384];
                while (true)
                {
                    int count = await stream.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false);
                    if (count == 0) return output.ToArray();
                    if (output.Length + count > MaxJsonBytes) throw new InvalidDataException("Update manifest limit exceeded.");
                    output.Write(buffer, 0, count);
                }
            }
        }

        private static async Task WriteHeader(Stream stream, int status, string contentType, long? length, string location, CancellationToken token)
        {
            if (status < 200 || status > 599) throw new InvalidDataException();
            if (String.IsNullOrWhiteSpace(contentType)) contentType = "application/octet-stream";
            if (contentType.Length > 256 || contentType.Any(c => c < 32 || c > 126)) throw new InvalidDataException();
            if (location != null && (location.Length > 16384 || location.Any(c => c < 33 || c > 126))) throw new InvalidDataException();
            var header = new StringBuilder("HTTP/1.1 " + status.ToString(CultureInfo.InvariantCulture) + " Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: " + contentType + "\r\n");
            if (length.HasValue)
            {
                if (length.Value < 0) throw new InvalidDataException();
                header.Append("Content-Length: ").Append(length.Value.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
            }
            if (location != null) header.Append("Location: ").Append(location).Append("\r\n");
            header.Append("\r\n");
            byte[] bytes = Encoding.ASCII.GetBytes(header.ToString());
            await stream.WriteAsync(bytes, 0, bytes.Length, token).ConfigureAwait(false);
        }

        private async void Handle(TcpClient client)
        {
            bool responseStarted = false;
            HttpWebRequest request = null;
            RequestStage stage = RequestStage.ClientOwnership;
            int? responseStatus = null;
            try
            {
                Exception failure = null;
                try
                {
                client.NoDelay = true;
                var peer = client.Client.RemoteEndPoint as IPEndPoint;
                using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token))
                using (deadline.Token.Register(client.Close))
                {
                    deadline.CancelAfter(RequestMilliseconds);
                    Task<bool> approval = peer != null && peer.Address.Equals(IPAddress.Loopback) ? authorize(client, Port) : Task.FromResult(false);
                    if (await Task.WhenAny(approval, Task.Delay(3000, deadline.Token)).ConfigureAwait(false) != approval || !await approval.ConfigureAwait(false))
                    {
                        responseStarted = true;
                        await WriteHeader(client.GetStream(), 403, "text/plain", 0, null, deadline.Token).ConfigureAwait(false);
                        return;
                    }
                    stage = RequestStage.ClientHeader;
                    string header = await ReadHeader(client, deadline.Token).ConfigureAwait(false);
                    if (header == null) return;
                    stage = RequestStage.ClientRequest;
                    BridgeRequest input = ParseRequest(header);
                    request = CreateRequest(input);
                    lock (sync)
                    {
                        if (cancellation.IsCancellationRequested) throw new OperationCanceledException();
                        requests.Add(request);
                    }
                    using (deadline.Token.Register(request.Abort))
                    {
                        stage = RequestStage.UpstreamResponse;
                        HttpWebResponse response;
                        try { response = (HttpWebResponse)await request.GetResponseAsync().ConfigureAwait(false); }
                        catch (WebException ex)
                        {
                            response = ex.Response as HttpWebResponse;
                            if (response == null) throw;
                        }
                        using (response)
                        {
                            int status = (int)response.StatusCode;
                            responseStatus = status;
                            stage = RequestStage.UpstreamHeaders;
                            string location = RewriteLocation(input.Target, response.Headers[HttpResponseHeader.Location]);
                            bool noBody = input.Method == "HEAD" || status == 204 || status == 304;
                            bool json = IsJson(response.ContentType);
                            byte[] rewritten = null;
                            if (!noBody && json)
                            {
                                if (response.ContentLength > MaxJsonBytes) throw new InvalidDataException("Update manifest limit exceeded.");
                                stage = RequestStage.UpstreamBody;
                                byte[] original;
                                using (Stream source = response.GetResponseStream()) original = await ReadJson(source, deadline.Token).ConfigureAwait(false);
                                stage = RequestStage.ManifestRewrite;
                                rewritten = RewriteJson(original);
                            }
                            long? length = null;
                            if (rewritten != null) length = rewritten.Length;
                            else if (!json && response.ContentLength >= 0 && String.IsNullOrEmpty(response.ContentEncoding)) length = response.ContentLength;
                            if (status == 204 || status == 304) length = null;
                            responseStarted = true;
                            NetworkStream destination = client.GetStream();
                            stage = RequestStage.ClientResponseHeader;
                            await WriteHeader(destination, status, json ? "application/json; charset=utf-8" : response.ContentType, length, location, deadline.Token).ConfigureAwait(false);
                            if (noBody) return;
                            if (rewritten != null)
                            {
                                stage = RequestStage.ClientResponseBody;
                                await destination.WriteAsync(rewritten, 0, rewritten.Length, deadline.Token).ConfigureAwait(false);
                            }
                            else using (Stream source = response.GetResponseStream())
                            {
                                byte[] buffer = new byte[32768];
                                while (true)
                                {
                                    stage = RequestStage.UpstreamBody;
                                    int count = await source.ReadAsync(buffer, 0, buffer.Length, deadline.Token).ConfigureAwait(false);
                                    if (count == 0) break;
                                    stage = RequestStage.ClientResponseBody;
                                    await destination.WriteAsync(buffer, 0, count, deadline.Token).ConfigureAwait(false);
                                }
                            }
                        }
                    }
                }
                }
                catch (Exception ex) { failure = ex; }
                if (failure != null)
                {
                if (!cancellation.IsCancellationRequested && log != null && failureBudget.Admit(true, DateTime.UtcNow))
                {
                    // URLs/tokens and response bodies may contain sensitive data.
                    try { log("The update bridge request could not be completed: " + DescribeFailure(stage, failure, responseStatus)); } catch { }
                }
                if (!responseStarted && !cancellation.IsCancellationRequested)
                {
                    try
                    {
                        using (var deadline = new CancellationTokenSource(2000))
                        using (deadline.Token.Register(client.Close))
                            await WriteHeader(client.GetStream(), failure is InvalidDataException ? 400 : 502, "text/plain", 0, null, deadline.Token).ConfigureAwait(false);
                    }
                    catch { }
                }
                }
            }
            finally
            {
                if (request != null) { try { request.Abort(); } catch { } }
                client.Close();
                lock (sync) { clients.Remove(client); if (request != null) requests.Remove(request); }
                capacity.Release();
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            try { cancellation.Cancel(); } catch { }
            try { listener.Stop(); } catch { }
            TcpClient[] activeClients; HttpWebRequest[] activeRequests;
            lock (sync)
            {
                activeClients = clients.ToArray(); activeRequests = requests.ToArray();
                clients.Clear(); requests.Clear();
            }
            foreach (HttpWebRequest request in activeRequests) { try { request.Abort(); } catch { } }
            foreach (TcpClient client in activeClients) { try { client.Close(); } catch { } }
        }

        // Offline fixture coverage. No Discord, WARP, DNS or remote TLS calls.
        // Returns passed fixture groups; failed assertions throw to the caller.
        internal static int RunOfflineTests()
        {
            int passed = 0;
            using (var bridge = new UpdateBridge(9, delegate(TcpClient client, int port) { return Task.FromResult(true); }, null))
            {
                bridge.Start();
                string prefix = "/" + bridge.token;
                Action<bool, string> require = delegate(bool condition, string message) { if (!condition) throw new InvalidOperationException("UpdateBridge: " + message); passed++; };
                Func<string, string> header = delegate(string path) { return "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" + bridge.Port + "\r\n\r\n"; };
                require(bridge.NewEndpoint.EndsWith("/updates/", StringComparison.Ordinal) && bridge.LegacyEndpoint.EndsWith("/legacy", StringComparison.Ordinal), "endpoint formats");
                require(bridge.ParseRequest(header(prefix + "/updates/distributions/app/manifests/latest?platform=win&channel=stable")).Target.AbsoluteUri == "https://updates.discord.com/distributions/app/manifests/latest?platform=win&channel=stable", "new endpoint mapping");
                require(bridge.MapTarget(prefix + "/legacy/modules/stable/versions.json").AbsoluteUri == "https://discord.com/api/modules/stable/versions.json", "legacy endpoint mapping");
                require(bridge.MapTarget(prefix + "/download/cdn.discordapp.com/assets/module.zip?x=1").AbsoluteUri == "https://cdn.discordapp.com/assets/module.zip?x=1", "download mapping");
                string[] badPaths = { "/wrong/updates/", prefix + "/updates", prefix + "/download/discord.com.evil.test/a", prefix + "/download/127.0.0.1/a", prefix + "/download/discord.com:444/a", prefix + "/download/a@discord.com/a", prefix + "/download/discord.com\\evil/a", prefix + "/updates/a#fragment", prefix + "/other/a" };
                foreach (string path in badPaths)
                {
                    bool rejected = false; try { bridge.MapTarget(path); } catch (InvalidDataException) { rejected = true; }
                    require(rejected, "blocked target " + path.Substring(prefix.Length < path.Length ? prefix.Length : 0));
                }
                string valid = header(prefix + "/updates/");
                string[] badHeaders = {
                    valid.Replace("GET ", "POST "), valid.Replace("HTTP/1.1", "HTTP/2.0"), valid.Replace("127.0.0.1:", "localhost:"),
                    valid.Replace("\r\n\r\n", "\r\nContent-Length: 1\r\n\r\n"), valid.Replace("\r\n\r\n", "\r\nTransfer-Encoding: chunked\r\n\r\n"),
                    valid.Replace("\r\n\r\n", "\r\nHost: discord.com\r\n\r\n"), valid.Replace("\r\n\r\n", "\r\n Folded: bad\r\n\r\n"),
                    valid.Replace("GET /", "GET http://evil.test/"), valid.Replace("\r\n\r\n", "\r\nX-Test: a\nb\r\n\r\n")
                };
                foreach (string input in badHeaders)
                {
                    bool rejected = false; try { bridge.ParseRequest(input); } catch (InvalidDataException) { rejected = true; }
                    require(rejected, "blocked malformed request");
                }
                require(bridge.ParseRequest(valid.Replace("GET ", "HEAD ")).Method == "HEAD", "HEAD support");
                string manifest = "{\"modules\":[{\"url\":\"https:\\/\\/cdn.discordapp.com\\/a.zip?signature=fixture\",\"version\":42}],\"homepage\":\"https://example.org/\",\"text\":\"normal\"}";
                var document = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(bridge.RewriteJson(Encoding.UTF8.GetBytes(manifest))));
                var module = (Dictionary<string, object>)((IList)document["modules"])[0];
                require((string)module["url"] == bridge.BaseUrl + "/download/cdn.discordapp.com/a.zip?signature=fixture" && (int)module["version"] == 42 && (string)document["homepage"] == "https://example.org/", "nested JSON rewrite");
                require(bridge.RewriteLocation(new Uri("https://updates.discord.com/a/manifest"), "../download.zip") == bridge.BaseUrl + "/download/updates.discord.com/download.zip", "relative redirect rewrite");
                foreach (string target in new[] { "https://evil.test/a", "http://discord.com/a", "https://user@discord.com/a", "https://@discord.com/a", "https://discord.com:8443/a", "https://discord.com/a\r\nX: evil" })
                {
                    bool rejected = false; try { bridge.RewriteLocation(new Uri("https://updates.discord.com/"), target); } catch (InvalidDataException) { rejected = true; }
                    require(rejected, "blocked redirect");
                }
                bool oversized = false; try { bridge.RewriteJson(new byte[MaxJsonBytes + 1]); } catch (InvalidDataException) { oversized = true; }
                require(oversized, "manifest memory limit");
                var request = bridge.CreateRequest(bridge.ParseRequest(valid));
                require(request.Proxy.GetProxy(request.RequestUri).AbsoluteUri == "http://127.0.0.1:9/" && !request.Proxy.IsBypassed(request.RequestUri) && !request.AllowAutoRedirect && request.CookieContainer == null && request.Credentials == null && request.UserAgent == "DiscordAccess/3", "fixed proxy/no credentials/no auto redirects");
                require(request.ServerCertificateValidationCallback(null, null, null, SslPolicyErrors.None) &&
                    !request.ServerCertificateValidationCallback(null, null, null, SslPolicyErrors.RemoteCertificateNameMismatch) &&
                    !request.ServerCertificateValidationCallback(null, null, null, SslPolicyErrors.RemoteCertificateChainErrors), "TLS validation is mandatory");
                request.Abort();
                using (var response = new MemoryStream())
                {
                    WriteHeader(response, 200, "application/json", 25, null, CancellationToken.None).GetAwaiter().GetResult();
                    string text = Encoding.ASCII.GetString(response.ToArray());
                    require(text.Contains("Content-Length: 25\r\n") && text.Contains("Connection: close\r\n"), "response length and closure");
                }
                require(OfflineRequest(bridge.Port, valid.Replace("GET ", "POST ")).StartsWith("HTTP/1.1 400 ", StringComparison.Ordinal), "live malformed request rejection");
                require(bridge.TrackedRequests == 0, "invalid request never contacted upstream");
            }
            using (var denied = new UpdateBridge(9, delegate(TcpClient client, int port) { return Task.FromResult(false); }, null))
            {
                denied.Start();
                if (!OfflineRequest(denied.Port, "").StartsWith("HTTP/1.1 403 ", StringComparison.Ordinal) || denied.TrackedRequests != 0) throw new InvalidOperationException("UpdateBridge: ownership denied before body read.");
                passed++;
            }
            var failures = new List<string>();
            using (var bridge = new UpdateBridge(9, delegate(TcpClient client, int port) { return Task.FromResult(true); },
                delegate(string detail) { lock (failures) failures.Add(detail); }))
            {
                bridge.Start();
                string unused = OfflineRequest(bridge.Port, "", true);
                if (!SpinWait.SpinUntil(delegate { return bridge.TrackedClients == 0; }, 5000)) throw new InvalidOperationException("UpdateBridge: unused connection cleanup.");
                lock (failures)
                    if (unused.Length != 0 || failures.Count != 0 || bridge.TrackedRequests != 0) throw new InvalidOperationException("UpdateBridge: unused preconnection is not a failed request.");
                passed++;

                string partial = OfflineRequest(bridge.Port, "GET /incomplete HTTP/1.1\r\n", true);
                lock (failures)
                    if (!partial.StartsWith("HTTP/1.1 502 ", StringComparison.Ordinal) || failures.Count != 1 ||
                        !failures[0].Contains("stage=ClientHeader; category=io") || bridge.TrackedRequests != 0)
                        throw new InvalidOperationException("UpdateBridge: incomplete header remains a client-header failure.");
                passed++;

                // The production ten-second header deadline must remain visible.
                OfflineRequest(bridge.Port, "", false, 15000);
                if (!SpinWait.SpinUntil(delegate { lock (failures) return failures.Count >= 2; }, 5000)) throw new InvalidOperationException("UpdateBridge: header timeout diagnostic missing.");
                lock (failures)
                    if (failures.Count != 2 || !failures[1].Contains("stage=ClientHeader; category=timeout") || bridge.TrackedRequests != 0)
                        throw new InvalidOperationException("UpdateBridge: idle header timeout is not suppressed.");
                passed++;
            }
            string sensitive = "https://discord.com/private?token=fixture-secret Authorization: fixture-body";
            string safe = DescribeFailure(RequestStage.ClientResponseBody,
                new IOException(sensitive, new SocketException((int)SocketError.ConnectionReset)), 200);
            if (safe != "stage=ClientResponseBody; category=io; HTTP=200; socket-code=" + ((int)SocketError.ConnectionReset).ToString(CultureInfo.InvariantCulture))
                throw new InvalidOperationException("UpdateBridge: fixed stage/status/socket diagnostics only.");
            passed++;
            safe = DescribeFailure(RequestStage.UpstreamResponse, new WebException(sensitive, WebExceptionStatus.ConnectFailure), null);
            if (safe != "stage=UpstreamResponse; category=upstream-network; web-status=" + ((int)WebExceptionStatus.ConnectFailure).ToString(CultureInfo.InvariantCulture))
                throw new InvalidOperationException("UpdateBridge: upstream diagnostics do not include exception text.");
            passed++;
            return passed;
        }

        private static string OfflineRequest(int port, string request, bool finishRequest = false, int receiveTimeout = 5000)
        {
            using (var client = new TcpClient())
            {
                client.ReceiveTimeout = receiveTimeout; client.SendTimeout = 5000;
                client.Connect(IPAddress.Loopback, port);
                NetworkStream stream = client.GetStream();
                byte[] bytes = Encoding.ASCII.GetBytes(request);
                if (bytes.Length > 0) stream.Write(bytes, 0, bytes.Length);
                if (finishRequest) client.Client.Shutdown(SocketShutdown.Send);
                using (var memory = new MemoryStream())
                {
                    byte[] buffer = new byte[1024]; int count;
                    while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        memory.Write(buffer, 0, count);
                        if (memory.Length > MaxHeaderBytes) throw new InvalidDataException();
                    }
                    return Encoding.ASCII.GetString(memory.ToArray());
                }
            }
        }
    }
}
