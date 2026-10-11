using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DiscordAccess
{
    // Exercises the actual process-owned gate with an inert, owned child backend.
    // All traffic is synthetic loopback data; no engine, Discord or account opens.
    internal static class ProxyTransportChecks
    {
        private static readonly byte[] Payload = Encoding.ASCII.GetBytes("transport-fixture-payload");
        private const int ReplySize = 256 * 1024;
        private static void Require(bool condition, string message)
        { if (!condition) throw new InvalidOperationException("Proxy transport: " + message); }

        private static void ReadHeader(NetworkStream stream)
        {
            int state = 0, total = 0;
            while (state < 4 && total++ < 16384)
            {
                int next = stream.ReadByte(); if (next < 0) throw new IOException("Fixture header ended.");
                if ((state == 0 || state == 2) && next == 13 || (state == 1 || state == 3) && next == 10) state++;
                else state = next == 13 ? 1 : 0;
            }
            if (state != 4) throw new IOException("Fixture header too large.");
        }
        private static bool ReadPayload(NetworkStream stream)
        {
            var bytes = new byte[Payload.Length]; int count = 0;
            while (count < bytes.Length) { int n = stream.Read(bytes, count, bytes.Length - count); if (n == 0) return false; count += n; }
            for (int i = 0; i < bytes.Length; i++) if (bytes[i] != Payload[i]) return false;
            return true;
        }

        // Invoked by reflection in a fresh Windows PowerShell child assigned to
        // the fixture job. Loading this assembly does not call its entry point.
        private static void Serve(int port, string fixture)
        {
            var listener = new TcpListener(IPAddress.Loopback, port); listener.Start();
            while (true)
            {
                TcpClient client = listener.AcceptTcpClient();
                ThreadPool.QueueUserWorkItem(delegate
                {
                    using (client)
                    {
                        try
                        {
                            var stream = client.GetStream(); ReadHeader(stream);
                            byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection Established\r\n\r\n");
                            stream.Write(header, 0, header.Length);
                            int mode = stream.ReadByte();
                            if (mode == 'S')
                            {
                                stream.Write(new byte[1024], 0, 1024);
                                client.Client.Shutdown(SocketShutdown.Send);
                                if (ReadPayload(stream)) File.WriteAllText(Path.Combine(fixture, "server-half.received"), "received");
                                return;
                            }
                            if (!ReadPayload(stream)) return;
                            if (mode == 'F')
                            {
                                // Close the socket before TcpClient/NetworkStream
                                // disposal can perform a graceful shutdown.
                                client.Client.LingerState = new LingerOption(true, 0);
                                client.Client.Close(0);
                                return;
                            }
                            if (mode == 'C' || mode == 'H')
                            {
                                if (stream.ReadByte() != -1) return;
                            }
                            if (mode == 'H' || mode == 'K') { Thread.Sleep(10000); return; }
                            Thread.Sleep(50);
                            byte[] body = new byte[ReplySize];
                            for (int i = 0; i < body.Length; i++) body[i] = (byte)(i % 251);
                            stream.Write(body, 0, body.Length);
                        }
                        catch { }
                    }
                });
            }
        }

        private static async Task<TcpClient> Open(int port, char mode)
        {
            var client = new TcpClient();
            try
            {
                client.ReceiveTimeout = 5000; client.SendTimeout = 5000;
                await client.ConnectAsync(IPAddress.Loopback, port).ConfigureAwait(false);
                var stream = client.GetStream();
                byte[] header = Encoding.ASCII.GetBytes("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\n\r\n");
                await stream.WriteAsync(header, 0, header.Length).ConfigureAwait(false);
                ReadHeader(stream);
                stream.WriteByte((byte)mode);
                if (mode != 'S') await stream.WriteAsync(Payload, 0, Payload.Length).ConfigureAwait(false);
                return client;
            }
            catch { client.Close(); throw; }
        }
        private static async Task<int> ReadReply(NetworkStream stream, bool verify)
        {
            int total = 0; var bytes = new byte[32768];
            while (true)
            {
                int read;
                try
                {
                    Task<int> reading = stream.ReadAsync(bytes, 0, bytes.Length);
                    Require(await Task.WhenAny(reading, Task.Delay(5000)).ConfigureAwait(false) == reading, "fixture response stalled");
                    read = await reading.ConfigureAwait(false);
                }
                catch (IOException) { return total; }
                if (read == 0) return total;
                if (verify) for (int i = 0; i < read; i++) Require(bytes[i] == (byte)((total + i) % 251), "response bytes changed");
                total += read;
            }
        }
        private static async Task<int> Request(int port, char mode)
        {
            using (TcpClient client = await Open(port, mode).ConfigureAwait(false))
            {
                NetworkStream stream = client.GetStream();
                if (mode == 'C' || mode == 'H') client.Client.Shutdown(SocketShutdown.Send);
                return await ReadReply(stream, true).ConfigureAwait(false);
            }
        }
        private static void Until(Func<bool> condition, string error)
        {
            var elapsed = Stopwatch.StartNew();
            while (!condition()) { Require(elapsed.ElapsedMilliseconds < 5000, error); Thread.Sleep(10); }
        }
        private static string PsLiteral(string value) { return "'" + value.Replace("'", "''") + "'"; }

        internal static int Run(string packageRoot)
        {
            int checks = 0;
            string work = Path.Combine(Path.GetFullPath(packageRoot), "work");
            string fixture = Path.Combine(work, "proxy-transport-" + Guid.NewGuid().ToString("N"));
            Require(Safety.Under(fixture, work) && Safety.NoReparse(fixture), "fixture directory boundary invalid");
            Directory.CreateDirectory(fixture);
            try
            {
                string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                string image = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
                int port = TcpOwner.ReserveEphemeralPort();
                string script = "$assembly=[Reflection.Assembly]::LoadFrom(" + PsLiteral(typeof(ProxyTransportChecks).Assembly.Location) + ");" +
                    "$type=$assembly.GetType('DiscordAccess.ProxyTransportChecks');" +
                    "$method=$type.GetMethod('Serve',[Reflection.BindingFlags]'NonPublic,Static');" +
                    "$method.Invoke($null,[object[]]@([int]" + port + ",[string]" + PsLiteral(fixture) + "))";
                using (var job = new NativeSessionJob())
                using (var backend = NativeProcess.Start(job, image, "-NoProfile -NonInteractive -Command " + NativeProcess.Quote(script), system, null, null))
                {
                    Until(() => TcpOwner.OwnsListener(backend, port), "owned backend did not listen");
                    var diagnostics = new ConcurrentQueue<string>();
                    using (var gate = new ProcessGate(backend, job, image, null, port, "fixture-user", "fixture-password", 0, 500))
                    {
                        gate.DiagnosticAllowed = true; gate.DiagnosticTrace = diagnostics.Enqueue; gate.Start();
                        Require(Request(gate.Port, 'N').GetAwaiter().GetResult() == ReplySize, "normal response truncated"); checks++;
                        Require(Request(gate.Port, 'C').GetAwaiter().GetResult() == ReplySize, "client half-close truncated response"); checks++;
                        var parallel = new Task<int>[16];
                        for (int i = 0; i < parallel.Length; i++) parallel[i] = Request(gate.Port, 'N');
                        Require(Task.WhenAll(parallel).Wait(5000), "parallel responses stalled");
                        foreach (Task<int> task in parallel) Require(task.Result == ReplySize, "parallel response truncated"); checks++;
                        using (TcpClient client = Open(gate.Port, 'S').GetAwaiter().GetResult())
                        {
                            NetworkStream stream = client.GetStream();
                            Require(ReadReply(stream, false).GetAwaiter().GetResult() == 1024, "server half-close response changed");
                            stream.Write(Payload, 0, Payload.Length);
                            client.Client.Shutdown(SocketShutdown.Send);
                            Until(() => File.Exists(Path.Combine(fixture, "server-half.received")), "server half-close discarded remaining client data"); checks++;
                        }
                        var timer = Stopwatch.StartNew();
                        Require(Request(gate.Port, 'H').GetAwaiter().GetResult() == 0 && timer.ElapsedMilliseconds < 3000, "half-close drain was unbounded");
                        Until(() => gate.TrackedClients == 0, "drain timeout retained sockets");
                        Require(Array.Exists(diagnostics.ToArray(), line => line.Contains("stage=Relay") && line.Contains("category=Timeout")), "drain timeout missing diagnostic"); checks++;
                        Require(Array.Exists(diagnostics.ToArray(), line => line.Contains("category=Timeout") && line.Contains("direction=engine_to_client elapsed_ms=")),
                            "drain timeout direction or elapsed diagnostic missing"); checks++;
                        Require(Request(gate.Port, 'F').GetAwaiter().GetResult() == 0, "reset fixture produced response");
                        Until(() => gate.TrackedClients == 0, "reset retained sockets"); checks++;
                        Require(Array.Exists(diagnostics.ToArray(), line => line.Contains("stage=Relay") && line.Contains("socket=ConnectionReset") &&
                            line.Contains("direction=engine_to_client elapsed_ms=")), "real backend reset lost socket code or first failed direction"); checks++;
                        using (TcpClient client = Open(gate.Port, 'K').GetAwaiter().GetResult())
                        {
                            NetworkStream stream = client.GetStream();
                            timer.Restart(); gate.Dispose();
                            Require(ReadReply(stream, false).GetAwaiter().GetResult() == 0 && timer.ElapsedMilliseconds < 1500, "session cancellation did not stop both pumps");
                            Until(() => gate.TrackedClients == 0, "cancellation retained sockets"); checks++;
                        }
                        Require(Array.TrueForAll(diagnostics.ToArray(), line => !line.Contains("fixture-password") && !line.Contains("fixture-payload")), "transport diagnostics leaked data"); checks++;
                    }
                    job.Dispose(); Require(backend.WaitForExit(4000), "owned backend survived cleanup"); checks++;
                }
            }
            finally
            {
                if (Safety.Under(fixture, work) && Safety.NoReparse(fixture)) Directory.Delete(fixture, true);
            }
            return checks;
        }
    }
}
