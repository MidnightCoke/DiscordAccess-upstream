using System;
using System.Collections.Generic;
using System.Threading;

namespace DiscordAccess
{
    internal interface IDnsCandidateConnection : IDisposable
    {
        DnsOptions Options { get; }
        void Verify(CancellationToken token);
    }

    // Only this fixed message crosses the console/log boundary when every
    // candidate fails. Failed responses and framework exception text are not kept.
    internal sealed class DnsSelectionException : InvalidOperationException
    {
        internal DnsSelectionException()
            : base("Discord'a erişebilen bir DNS bağlantısı bulunamadı. İnternet bağlantısını kontrol edip yeniden başlatın.") { }
    }

    internal static class DnsSelection
    {
        internal static IDnsCandidateConnection Select(DnsOptions requested,
            Func<DnsOptions, CancellationToken, IDnsCandidateConnection> open,
            Action<string> log, CancellationToken token)
        {
            if (requested == null) throw new ArgumentNullException("requested");
            if (open == null) throw new ArgumentNullException("open");
            foreach (DnsOptions option in requested.Candidates)
            {
                token.ThrowIfCancellationRequested();
                // Package integrity and process startup failures are fatal. They
                // must not be hidden by trying a different DNS provider.
                IDnsCandidateConnection candidate = open(option, token);
                if (candidate == null) throw new InvalidOperationException("DNS bağlantısı hazırlanamadı.");
                bool retained = false;
                try
                {
                    token.ThrowIfCancellationRequested();
                    if (requested.Automatic)
                    {
                        if (log != null) log("DNS erişim kontrolü: " + option.Description);
                        try { candidate.Verify(token); }
                        catch (ConnectivityFailureException error)
                        {
                            token.ThrowIfCancellationRequested();
                            // Provider selection never attempts to bypass a
                            // Discord rate limit by retrying the same endpoint.
                            if ((error.Reason == ConnectivityFailureReason.Http && error.HttpStatus == 429) ||
                                error.Reason == ConnectivityFailureReason.Canceled) throw;
                            if (log != null) log("DNS erişim kontrolü: " + error.Message);
                            continue;
                        }
                    }
                    token.ThrowIfCancellationRequested();
                    if (log != null) log("DNS bağlantısı seçildi: " + option.Description);
                    retained = true;
                    return candidate;
                }
                finally
                {
                    // A failed candidate is completely closed before the next
                    // is opened. A cleanup failure is fatal rather than ignored.
                    if (!retained) candidate.Dispose();
                }
            }
            throw new DnsSelectionException();
        }

        private sealed class Fixture : IDnsCandidateConnection
        {
            internal readonly List<string> Events;
            internal Action<CancellationToken> OnVerify;
            internal Action OnDispose;
            internal int Verifications, Disposals;
            public DnsOptions Options { get; private set; }
            internal Fixture(DnsOptions option, List<string> events)
            { Options = option; Events = events; }
            public void Verify(CancellationToken token)
            {
                Verifications++; Events.Add("verify:" + Options.Provider);
                if (OnVerify != null) OnVerify(token);
            }
            public void Dispose()
            {
                Disposals++; Events.Add("dispose:" + Options.Provider);
                if (OnDispose != null) OnDispose();
            }
        }

        internal static int RunOfflineChecks()
        {
            int checks = 0;
            Action<bool, string> require = (ok, message) =>
            { if (!ok) throw new InvalidOperationException(message); checks++; };
            var automatic = DnsOptions.Parse(new string[0]);
            require(automatic.Automatic && automatic.Candidates.Length == 3 &&
                automatic.Candidates[0].Provider == "cloudflare-ip" && automatic.Candidates[1].Provider == "cloudflare" &&
                automatic.Candidates[2].Provider == "google", "Automatic DNS candidate order changed.");
            var events = new List<string>();
            var fixtures = new List<Fixture>();
            Func<DnsOptions, CancellationToken, IDnsCandidateConnection> open = (option, token) =>
            {
                events.Add("open:" + option.Provider);
                var fixture = new Fixture(option, events); fixtures.Add(fixture); return fixture;
            };
            IDnsCandidateConnection winner = Select(automatic, open, null, CancellationToken.None);
            require(fixtures.Count == 1 && Object.ReferenceEquals(winner, fixtures[0]) && fixtures[0].Verifications == 1 &&
                fixtures[0].Disposals == 0, "Successful first candidate was retried or disposed.");
            winner.Dispose();
            require(fixtures[0].Disposals == 1, "Selected candidate did not remain owned by the caller.");

            events.Clear(); fixtures.Clear();
            open = (option, token) =>
            {
                events.Add("open:" + option.Provider);
                var fixture = new Fixture(option, events); fixtures.Add(fixture);
                if (fixtures.Count == 1) fixture.OnVerify = ignored => { throw ConnectivityFailureException.Create(ConnectivityEndpoint.Gateway, ConnectivityFailureReason.Connect); };
                return fixture;
            };
            winner = Select(automatic, open, null, CancellationToken.None);
            require(fixtures.Count == 2 && fixtures[0].Disposals == 1 && fixtures[1].Disposals == 0 &&
                winner.Options.Provider == "cloudflare", "Failed candidate did not fall back exactly once.");
            require(events.IndexOf("dispose:cloudflare-ip") < events.IndexOf("open:cloudflare"),
                "Next candidate opened before the previous candidate was closed.");
            winner.Dispose();

            events.Clear(); fixtures.Clear();
            open = (option, token) =>
            {
                var fixture = new Fixture(option, events); fixtures.Add(fixture);
                fixture.OnVerify = ignored => { throw ConnectivityFailureException.Create(ConnectivityEndpoint.Gateway, ConnectivityFailureReason.Timeout); };
                return fixture;
            };
            DnsSelectionException allFailed = null;
            try { Select(automatic, open, null, CancellationToken.None); }
            catch (DnsSelectionException error) { allFailed = error; }
            require(allFailed != null && allFailed.InnerException == null && fixtures.Count == 3,
                "Exhausted DNS selection lost its safe fixed failure.");
            foreach (Fixture fixture in fixtures)
                require(fixture.Disposals == 1 && fixture.Verifications == 1, "Exhausted candidate was not closed exactly once.");

            events.Clear(); fixtures.Clear();
            var explicitGoogle = DnsOptions.Parse(new[] { "--dns=google" });
            open = (option, token) =>
            {
                var fixture = new Fixture(option, events); fixtures.Add(fixture);
                fixture.OnVerify = ignored => { throw new InvalidOperationException("Explicit mode must not preflight."); };
                return fixture;
            };
            winner = Select(explicitGoogle, open, null, CancellationToken.None);
            require(fixtures.Count == 1 && winner.Options.Provider == "google" && fixtures[0].Verifications == 0 &&
                fixtures[0].Disposals == 0, "Explicit DNS selection changed its previous launch behavior.");
            winner.Dispose();

            events.Clear(); fixtures.Clear();
            open = (option, token) =>
            {
                var fixture = new Fixture(option, events); fixtures.Add(fixture);
                fixture.OnVerify = ignored => { throw ConnectivityFailureException.Create(ConnectivityEndpoint.Gateway, ConnectivityFailureReason.Http, 429); };
                return fixture;
            };
            bool limited = false;
            try { Select(automatic, open, null, CancellationToken.None); }
            catch (ConnectivityFailureException error) { limited = error.HttpStatus == 429; }
            require(limited && fixtures.Count == 1 && fixtures[0].Disposals == 1, "Rate limit was retried with another provider.");

            events.Clear(); fixtures.Clear();
            open = (option, token) =>
            {
                var fixture = new Fixture(option, events); fixtures.Add(fixture);
                fixture.OnVerify = ignored => { throw ConnectivityFailureException.Create(ConnectivityEndpoint.Gateway, ConnectivityFailureReason.Canceled); };
                return fixture;
            };
            bool requestCanceled = false;
            try { Select(automatic, open, null, CancellationToken.None); }
            catch (ConnectivityFailureException error) { requestCanceled = error.Reason == ConnectivityFailureReason.Canceled; }
            require(requestCanceled && fixtures.Count == 1 && fixtures[0].Disposals == 1,
                "Canceled connectivity request was retried with another provider.");

            events.Clear(); fixtures.Clear();
            using (var cancellation = new CancellationTokenSource())
            {
                open = (option, token) =>
                {
                    var fixture = new Fixture(option, events); fixtures.Add(fixture);
                    fixture.OnVerify = ignored => { cancellation.Cancel(); token.ThrowIfCancellationRequested(); };
                    return fixture;
                };
                bool canceled = false;
                try { Select(automatic, open, null, cancellation.Token); }
                catch (OperationCanceledException) { canceled = true; }
                require(canceled && fixtures.Count == 1 && fixtures[0].Disposals == 1, "Canceled selection continued or leaked its candidate.");
            }
            events.Clear(); fixtures.Clear();
            using (var cancellation = new CancellationTokenSource())
            {
                cancellation.Cancel(); bool canceled = false;
                try { Select(automatic, open, null, cancellation.Token); }
                catch (OperationCanceledException) { canceled = true; }
                require(canceled && fixtures.Count == 0, "Pre-canceled selection opened a candidate.");
            }

            int opens = 0; bool fatal = false;
            try
            {
                Select(automatic, (option, token) => { opens++; throw new System.Security.SecurityException("SYNTHETIC_SECRET"); }, null, CancellationToken.None);
            }
            catch (System.Security.SecurityException) { fatal = true; }
            require(fatal && opens == 1, "Security failure was hidden by a DNS retry.");
            opens = 0; fatal = false;
            try
            {
                Select(automatic, (option, token) => { opens++; throw ConnectivityFailureException.Create(ConnectivityEndpoint.Gateway, ConnectivityFailureReason.Connect); }, null, CancellationToken.None);
            }
            catch (ConnectivityFailureException) { fatal = true; }
            require(fatal && opens == 1, "Candidate startup failure was hidden by a DNS retry.");

            events.Clear(); fixtures.Clear();
            open = (option, token) =>
            {
                var fixture = new Fixture(option, events); fixtures.Add(fixture);
                fixture.OnVerify = ignored => { throw new System.Security.SecurityException("SYNTHETIC_SECRET"); };
                return fixture;
            };
            fatal = false;
            try { Select(automatic, open, null, CancellationToken.None); }
            catch (System.Security.SecurityException) { fatal = true; }
            require(fatal && fixtures.Count == 1 && fixtures[0].Disposals == 1,
                "Verification security failure was retried or leaked its candidate.");

            events.Clear(); fixtures.Clear();
            using (var cancellation = new CancellationTokenSource())
            {
                open = (option, token) =>
                {
                    var fixture = new Fixture(option, events); fixtures.Add(fixture);
                    fixture.OnVerify = ignored => cancellation.Cancel();
                    return fixture;
                };
                bool canceled = false;
                try { Select(automatic, open, null, cancellation.Token); }
                catch (OperationCanceledException) { canceled = true; }
                require(canceled && fixtures.Count == 1 && fixtures[0].Disposals == 1,
                    "Canceled successful verification retained its candidate.");
            }

            events.Clear(); fixtures.Clear();
            open = (option, token) =>
            {
                var fixture = new Fixture(option, events); fixtures.Add(fixture);
                fixture.OnVerify = ignored => { throw ConnectivityFailureException.Create(ConnectivityEndpoint.Gateway, ConnectivityFailureReason.Connect); };
                fixture.OnDispose = () => { throw new InvalidOperationException("Fixture cleanup failure."); };
                return fixture;
            };
            fatal = false;
            try { Select(automatic, open, null, CancellationToken.None); }
            catch (InvalidOperationException) { fatal = true; }
            require(fatal && fixtures.Count == 1 && fixtures[0].Disposals == 1, "Failed cleanup opened another candidate.");

            var fragments = DnsOptions.Parse(new[] { "--dns=auto", "--dns-record-fragment" });
            foreach (DnsOptions option in fragments.Candidates)
                require(!option.Automatic && option.RecordFragment, "Automatic candidate lost its TLS fragmentation option.");
            foreach (string[] args in new[] { new[] { "--dns=auto", "--dns=google" }, new[] { "--dns=auto", "--dns=auto" } })
            {
                bool rejected = false;
                try { DnsOptions.Parse(args); } catch (ArgumentException) { rejected = true; }
                require(rejected, "Duplicate automatic DNS selection was accepted.");
            }
            return checks;
        }
    }
}
