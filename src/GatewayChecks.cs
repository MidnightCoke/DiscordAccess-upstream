using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace DiscordAccess
{
    internal sealed class GatewayProbeException : InvalidOperationException
    {
        internal GatewayProbeException(bool hello, string reason)
            : base("[WS-" + (hello ? "HELLO" : "CONNECT") + "-" + SafeReason(reason) +
                "] The Gateway WebSocket check could not be completed. HTTP API success does not confirm the live message connection.") { }
        private static string SafeReason(string reason)
        {
            return Array.IndexOf(new[] { "TIMEOUT", "RESPONSE", "WEBSOCKET", "TRANSPORT", "CANCELLED", "FAILED" }, reason) >= 0
                ? reason : "FAILED";
        }
    }

    // Public HELLO only: never IDENTIFY, read account data or send a user token.
    // A fixed proxy is mandatory; there is no system proxy or direct fallback.
    internal static class GatewayChecks
    {
        private const int MaxHelloBytes = 16384;
        private static readonly Uri Gateway = new Uri("wss://gateway.discord.gg/?v=10&encoding=json");

        internal static string Check(int proxyPort)
        {
            return CheckAsync(proxyPort).GetAwaiter().GetResult();
        }

        private static ClientWebSocket Create(int proxyPort)
        {
            if (proxyPort < 1 || proxyPort > 65535) throw new ArgumentOutOfRangeException("proxyPort");
            var socket = new ClientWebSocket();
            socket.Options.Proxy = new WebProxy(new Uri("http://127.0.0.1:" + proxyPort), false);
            socket.Options.KeepAliveInterval = TimeSpan.Zero;
            return socket;
        }

        private static async Task<string> CheckAsync(int proxyPort)
        {
            string stage = "CONNECT";
            using (var socket = Create(proxyPort))
            using (var deadline = new CancellationTokenSource(10000))
            using (deadline.Token.Register(socket.Abort))
            {
                try
                {
                    await socket.ConnectAsync(Gateway, deadline.Token).ConfigureAwait(false);
                    stage = "HELLO";
                    using (var bytes = new MemoryStream())
                    {
                        byte[] buffer = new byte[2048];
                        WebSocketReceiveResult received;
                        do
                        {
                            received = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), deadline.Token).ConfigureAwait(false);
                            if (received.MessageType != WebSocketMessageType.Text || bytes.Length + received.Count > MaxHelloBytes)
                                throw new InvalidDataException();
                            bytes.Write(buffer, 0, received.Count);
                        } while (!received.EndOfMessage);
                        ValidateHello(new UTF8Encoding(false, true).GetString(bytes.ToArray()));
                    }
                    // A completed diagnostic should not reset its tunnel and
                    // look like a failed user Gateway connection in the log.
                    try
                    {
                        using (var closing = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token))
                        {
                            closing.CancelAfter(1000);
                            await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "diagnostic complete", closing.Token).ConfigureAwait(false);
                        }
                    }
                    catch { /* HELLO succeeded; bounded close is best effort. */ }
                    return "[WS-OK] The Gateway WebSocket connection and HELLO response were verified through the proxy. This check does not confirm the account session, message sending or voice/screen sharing.";
                }
                catch (Exception ex)
                {
                    // Exception messages/inner exceptions can contain remote data.
                    string reason = deadline.IsCancellationRequested ? "TIMEOUT" : FailureCategory(ex);
                    throw new GatewayProbeException(stage == "HELLO", reason);
                }
                finally { socket.Abort(); }
            }
        }

        private static string FailureCategory(Exception ex)
        {
            if (ex is InvalidDataException || ex is DecoderFallbackException || ex is ArgumentException) return "RESPONSE";
            if (ex is WebSocketException) return "WEBSOCKET";
            if (ex is IOException || ex is SocketException || ex is WebException) return "TRANSPORT";
            if (ex is OperationCanceledException) return "CANCELLED";
            return "FAILED";
        }

        private static void ValidateHello(string json)
        {
            try
            {
                if (json == null || json.Length > MaxHelloBytes) throw new InvalidDataException();
                var payload = new JavaScriptSerializer { MaxJsonLength = MaxHelloBytes, RecursionLimit = 8 }
                    .Deserialize<Dictionary<string, object>>(json);
                object opcode, data, interval;
                if (payload == null || !payload.TryGetValue("op", out opcode) || !(opcode is int) || (int)opcode != 10 ||
                    !payload.TryGetValue("d", out data)) throw new InvalidDataException();
                var hello = data as Dictionary<string, object>;
                if (hello == null || !hello.TryGetValue("heartbeat_interval", out interval) || !(interval is int) ||
                    (int)interval < 1 || (int)interval > 300000) throw new InvalidDataException();
            }
            catch { throw new InvalidDataException(); }
        }

        internal static void RunOfflineChecks()
        {
            ValidateHello("{\"op\":10,\"d\":{\"heartbeat_interval\":41250}}");
            foreach (string json in new[] { "null", "[]", "{}", "SYNTHETIC_SECRET", "{\"op\":0,\"d\":{\"heartbeat_interval\":41250}}",
                "{\"op\":10,\"d\":{}}", "{\"op\":10,\"d\":{\"heartbeat_interval\":0}}", "{\"op\":10,\"d\":{\"heartbeat_interval\":\"45000\"}}" })
            {
                bool failed = false;
                try { ValidateHello(json); } catch (InvalidDataException ex) { failed = !ex.ToString().Contains("SYNTHETIC_SECRET"); }
                if (!failed) throw new InvalidOperationException("Invalid Gateway HELLO accepted or exposed.");
            }
            using (var reserved = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
            {
                reserved.ExclusiveAddressUse = true;
                reserved.Bind(new IPEndPoint(IPAddress.Loopback, 0));
                int port = ((IPEndPoint)reserved.LocalEndPoint).Port;
                using (var socket = Create(port))
                {
                    IWebProxy proxy = socket.Options.Proxy;
                    if (proxy == null || proxy.IsBypassed(Gateway) || proxy.GetProxy(Gateway).Host != "127.0.0.1" || proxy.GetProxy(Gateway).Port != port)
                        throw new InvalidOperationException("Gateway check can bypass the loopback proxy.");
                }
                bool refused = false;
                try { Check(port); }
                catch (GatewayProbeException ex) { refused = ex.Message.StartsWith("[WS-CONNECT-", StringComparison.Ordinal) && ex.InnerException == null && ConsoleHost.SafeError(ex) == ex.Message; }
                if (!refused) throw new InvalidOperationException("Gateway check did not fail on a refused proxy.");
            }
            var unknown = new GatewayProbeException(true, "SYNTHETIC_SECRET\r\nprivate");
            if (!unknown.Message.StartsWith("[WS-HELLO-FAILED]", StringComparison.Ordinal) || unknown.ToString().Contains("SYNTHETIC_SECRET"))
                throw new InvalidOperationException("Gateway diagnosis reflected an unrecognized reason.");
        }
    }
}
