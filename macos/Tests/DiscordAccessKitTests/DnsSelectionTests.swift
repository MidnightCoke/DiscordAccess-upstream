import Foundation
import Testing
@testable import DiscordAccessKit

/// Scenarios from the Windows `DnsSelection.RunOfflineChecks`, with stand-in candidates.
@Suite struct DnsSelectionTests {
    typealias Collected = ProxyGateTests.Collected

    final class Fixture: DnsCandidate {
        let provider: DnsProvider
        private let events: Collected<String>
        var onVerify: ((Cancellation) throws -> Void)?
        var onClose: (() throws -> Void)?
        private(set) var verifications = 0
        private(set) var closings = 0

        init(provider: DnsProvider, events: Collected<String>) {
            self.provider = provider
            self.events = events
        }

        func verify(cancel: Cancellation) throws {
            verifications += 1
            events.append("verify:" + provider.name.rawValue)
            try onVerify?(cancel)
        }

        func close() throws {
            closings += 1
            events.append("close:" + provider.name.rawValue)
            try onClose?()
        }
    }

    /// Opens fixtures, letting `prepare` set each one up by its index, and records them and the order of events.
    final class Opener {
        let events = Collected<String>()
        let logs = Collected<String>()
        private(set) var fixtures: [Fixture] = []
        private let prepare: (Fixture, Int) -> Void

        init(_ prepare: @escaping (Fixture, Int) -> Void = { _, _ in }) {
            self.prepare = prepare
        }

        func open(_ provider: DnsProvider, _ cancel: Cancellation) throws -> DnsCandidate {
            events.append("open:" + provider.name.rawValue)
            let fixture = Fixture(provider: provider, events: events)
            prepare(fixture, fixtures.count)
            fixtures.append(fixture)
            return fixture
        }

        func select(_ options: DnsOptions = .automatic, cancel: Cancellation = Cancellation()) throws -> DnsCandidate {
            try DnsSelection.select(options, open: open, log: logs.append, cancel: cancel)
        }
    }

    static let connectFailure = ConnectivityFailure(endpoint: .gateway, reason: .connect)

    @Test func keepsTheFirstCandidateThatWorksForTheCaller() throws {
        let opener = Opener()
        let winner = try opener.select()
        #expect(opener.fixtures.count == 1 && winner === opener.fixtures[0])
        #expect(opener.fixtures[0].verifications == 1 && opener.fixtures[0].closings == 0)
        #expect(opener.logs.all == ["DNS access check: Cloudflare (IP certificate) DoH | DNS TLS record fragmentation: off",
                                    "Selected DNS connection: Cloudflare (IP certificate) DoH | DNS TLS record fragmentation: off"])
    }

    @Test func closesAFailedCandidateBeforeTheNextOneOpens() throws {
        let opener = Opener { fixture, index in
            if index == 0 { fixture.onVerify = { _ in throw Self.connectFailure } }
        }
        let winner = try opener.select()
        #expect(opener.fixtures.count == 2 && winner.provider.name == .cloudflare)
        #expect(opener.fixtures[0].closings == 1 && opener.fixtures[1].closings == 0)
        let events = opener.events.all
        #expect(try #require(events.firstIndex(of: "close:cloudflare-ip")) < #require(events.firstIndex(of: "open:cloudflare")))
        #expect(opener.logs.all.contains("DNS access check: " + Self.connectFailure.message))
    }

    @Test func keepsOnlyAFixedMessageWhenEveryCandidateFails() {
        let opener = Opener { fixture, _ in fixture.onVerify = { _ in throw ConnectivityFailure(endpoint: .gateway, reason: .timeout) } }
        #expect(throws: KitError.dnsSelectionFailed()) { try opener.select() }
        #expect(opener.fixtures.count == 3)
        #expect(opener.fixtures.allSatisfy { $0.verifications == 1 && $0.closings == 1 })
    }

    @Test func opensANamedProviderWithoutCheckingIt() throws {
        let opener = Opener { fixture, _ in fixture.onVerify = { _ in Issue.record("a named provider was checked") } }
        let winner = try opener.select(DnsOptions(provider: .google))
        #expect(opener.fixtures.count == 1 && winner.provider == DnsProvider(.google))
        #expect(opener.fixtures[0].verifications == 0 && opener.fixtures[0].closings == 0)
    }

    /// A rate limit is never retried with another provider, and neither is a canceled check.
    @Test(arguments: [ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 429, responseKind: .html),
                      ConnectivityFailure(endpoint: .gateway, reason: .canceled)])
    func stopsAtARateLimitOrACanceledCheck(failure: ConnectivityFailure) {
        let opener = Opener { fixture, _ in fixture.onVerify = { _ in throw failure } }
        #expect(throws: failure) { try opener.select() }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }

    @Test func stopsAndClosesWhenCanceledDuringTheCheck() {
        let cancel = Cancellation()
        let opener = Opener { fixture, _ in
            fixture.onVerify = { cancel in
                cancel.cancel()
                try cancel.check()
            }
        }
        #expect(throws: CancellationError.self) { try opener.select(cancel: cancel) }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }

    @Test func closesACheckedCandidateWhenCanceledMeanwhile() {
        let cancel = Cancellation()
        let opener = Opener { fixture, _ in fixture.onVerify = { cancel in cancel.cancel() } }
        #expect(throws: CancellationError.self) { try opener.select(cancel: cancel) }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }

    @Test func opensNothingWhenAlreadyCanceled() {
        let cancel = Cancellation()
        cancel.cancel()
        let opener = Opener()
        #expect(throws: CancellationError.self) { try opener.select(cancel: cancel) }
        #expect(opener.fixtures.isEmpty)
    }

    /// Package integrity and engine start failures must not be hidden by trying another provider.
    @Test(arguments: [KitError(code: "PKG-E03", message: "SYNTHETIC_SECRET") as Error, ConnectivityFailure(endpoint: .gateway, reason: .connect)])
    func neverHidesAFailureToOpen(error: Error) {
        var opens = 0
        var thrown: Error?
        do {
            _ = try DnsSelection.select(.automatic, open: { _, _ in
                opens += 1
                throw error
            }, cancel: Cancellation())
        } catch {
            thrown = error
        }
        #expect(opens == 1)
        #expect((thrown as? KitError) == (error as? KitError) && (thrown as? ConnectivityFailure) == (error as? ConnectivityFailure))
        #expect(thrown != nil)
    }

    @Test func neverRetriesAnUnexpectedCheckError() {
        let opener = Opener { fixture, _ in fixture.onVerify = { _ in throw POSIXError(.EPERM) } }
        #expect(throws: POSIXError(.EPERM)) { try opener.select() }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }

    /// Windows `DnsConnection.Dispose`: a candidate that cannot be closed safely stops the selection.
    @Test func stopsWhenACandidateCannotBeClosed() {
        let opener = Opener { fixture, _ in
            fixture.onVerify = { _ in throw Self.connectFailure }
            fixture.onClose = { throw KitError.dnsCandidateNotClosed() }
        }
        #expect(throws: KitError.dnsCandidateNotClosed()) { try opener.select() }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }
}
