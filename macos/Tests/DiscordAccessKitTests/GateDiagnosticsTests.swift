import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows `ProxyDiagnosticsChecks.cs`. Every line keeps to the stage, a validated host and port and a
/// fixed category, so `PRIVATE_FIXTURE` must never appear.
@Suite struct GateDiagnosticsTests {
    @Test func namesTheTargetOfAChromiumConnect() throws {
        let chromium = "CONNECT gateway.discord.gg:443 HTTP/1.1\r\nHost: gateway.discord.gg:443\r\nProxy-Connection: keep-alive\r\n" +
            "User-Agent: Mozilla/5.0 Chrome/138.0.0.0 Electron/37.0.0\r\n\r\n"
        #expect(try RequestPolicy.rewrite(chromium, authorization: "Basic fixture-only").hasPrefix("CONNECT gateway.discord.gg:443 HTTP/1.1\r\n"))
        #expect(GateDiagnostics.safeTarget(chromium) == "gateway.discord.gg:443")
    }

    @Test(arguments: [
        ("CONNECT telemetry.example.invalid:443 HTTP/1.1\r\nHost: telemetry.example.invalid:443\r\nAuthorization: Bearer PRIVATE_FIXTURE\r\n\r\n",
         RequestFailure.forbiddenHost, "telemetry.example.invalid:443"),
        ("CONNECT discord.com:444 HTTP/1.1\r\nHost: discord.com:444\r\n\r\n", .invalidTarget, "discord.com:444"),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: conflict.example.invalid\r\n\r\n", .conflictingHost, "discord.com:443"),
        ("GET http://discord.com/PRIVATE_FIXTURE?token=PRIVATE_FIXTURE HTTP/1.1\r\nHost: discord.com\r\nBad(Name): PRIVATE_FIXTURE\r\n\r\n",
         .invalidHeader, "discord.com:80"),
        ("GET http://PRIVATE_FIXTURE@discord.com/private HTTP/1.1\r\nHost: discord.com\r\n\r\n", .invalidTarget, "unknown"),
        ("CONNECT discord.com:443/PRIVATE_FIXTURE HTTP/1.1\r\n\r\n", .invalidTarget, "unknown"),
        ("GET /PRIVATE_FIXTURE?token=PRIVATE_FIXTURE HTTP/1.1\r\nHost: discord.com\r\n\r\n", .invalidTarget, "unknown"),
    ])
    func logsARefusalWithItsCategoryAndASafeTarget(request: String, refusal: RequestFailure, target: String) {
        #expect(throws: refusal) { try RequestPolicy.rewrite(request, authorization: "Basic fixture-only") }
        #expect(GateDiagnostics.safeTarget(request) == target)
        let line = GateDiagnostics.failure(stage: .requestPolicy, target: GateDiagnostics.safeTarget(request), error: .refused(refusal))
        #expect(line == "Failure stage=RequestPolicy target=" + target + " category=" + refusal.rawValue)
    }

    @Test(arguments: [
        "CONNECT discord.com:443\r\nPRIVATE_FIXTURE HTTP/1.1\r\n\r\n", "CONNECT 127.0.0.1:443 HTTP/1.1\r\n\r\n",
        "CONNECT bad..discord.com:443 HTTP/1.1\r\n\r\n", "", "CONNECT discord.com:443 HTTP/1.1", "GET http://[::1]/ HTTP/1.1\r\n\r\n",
        "GET http://discord.com\\@example.com/ HTTP/1.1\r\n\r\n", "GET https://discord.com/ HTTP/1.1\r\n\r\n",
        "CONNECT discord.com:0 HTTP/1.1\r\n\r\n", "CONNECT discord.com:65536 HTTP/1.1\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\n" + String(repeating: "a", count: 32_768) + "\r\n\r\n",
        // Not in the Windows vectors: a backslash in the path (Windows refuses any backslash too), an encoded or non-ASCII host.
        "GET http://discord.com/a\\b HTTP/1.1\r\n\r\n", "GET http://discord%2Ecom/ HTTP/1.1\r\n\r\n", "CONNECT disc\u{F6}rd.com:443 HTTP/1.1\r\n\r\n",
    ])
    func hidesTargetsThatAreNotAPlainHostAndPort(header: String) {
        #expect(GateDiagnostics.safeTarget(header) == "unknown")
    }

    @Test func keepsHostsInLowerCaseWithTheDefaultOrGivenPort() {
        #expect(GateDiagnostics.safeTarget("GET HTTP://Discord.COM HTTP/1.1\r\n\r\n") == "discord.com:80")
        #expect(GateDiagnostics.safeTarget("GET http://cdn.discordapp.com:8080/a?b#c HTTP/1.1\r\n\r\n") == "cdn.discordapp.com:8080")
        #expect(GateDiagnostics.safeTarget("CONNECT C-WAW04.Discord.Media:02087 HTTP/1.1\r\n\r\n") == "c-waw04.discord.media:2087")
    }

    @Test func namesOnlyTheCategoryAndAKnownSocketError() {
        #expect(GateDiagnostics.failure(stage: .backendConnect, target: "discord.com:443", error: .io(nil)) ==
            "Failure stage=BackendConnect target=discord.com:443 category=IO")
        #expect(GateDiagnostics.failure(stage: .relay, target: "discord.com:443\r\nPRIVATE_FIXTURE", error: .unexpected) ==
            "Failure stage=Relay target=unknown category=Unexpected")
        #expect(GateDiagnostics.failure(stage: .backendConnect, target: "discord.com:443", error: .socket(ECONNREFUSED)) ==
            "Failure stage=BackendConnect target=discord.com:443 category=Socket socket=ConnectionRefused")
        #expect(GateDiagnostics.failure(stage: .relay, target: "discord.com:443", error: .io(ECONNRESET)) ==
            "Failure stage=Relay target=discord.com:443 category=IO socket=ConnectionReset")
        #expect(GateDiagnostics.failure(stage: .headerRead, target: "unknown", error: .timeout) ==
            "Failure stage=HeaderRead target=unknown category=Timeout")
        #expect(GateDiagnostics.failure(stage: .backendIdentity, target: "discord.com:443", error: .invalidData) ==
            "Failure stage=BackendIdentity target=discord.com:443 category=InvalidData")
        // An error Windows has no name for is never written as a number.
        #expect(GateDiagnostics.failure(stage: .relay, target: "discord.com:443", error: .io(ENOENT)) ==
            "Failure stage=Relay target=discord.com:443 category=IO")
        #expect(!GateDiagnostics.failure(stage: .backendConnect, target: "discord.com:443", error: .socket(Int32.max)).contains(" socket="))
        #expect(GateDiagnostics.unownedClient(reason: "NoHolder") == "Failure stage=Ownership target=unknown category=UnownedClient reason=NoHolder")
        #expect(GateDiagnostics.unownedClient(reason: PeerAdmission.Refusal.unapprovedExecutable("Discord Helper (GPU)").diagnostic) ==
            "Failure stage=Ownership target=unknown category=UnownedClient reason=UnapprovedExecutable executable=Discord_Helper_(GPU)")
        // A reason can never start another line, whoever passes it.
        let hostile = "NoHolder\r\nFailure stage=Relay \u{E9}" + String(repeating: "x", count: 200)
        #expect(GateDiagnostics.unownedClient(reason: hostile) ==
            "Failure stage=Ownership target=unknown category=UnownedClient reason=NoHolder__Failure stage=Relay _" + String(repeating: "x", count: 65))
        #expect(GateDiagnostics.capacityFailure == "Failure stage=Admission target=unknown category=Capacity")
    }

    @Test func addsTheFailedDirectionAndAClampedDurationToRelayFailures() {
        for direction in [RelayDirection.clientToEngine, .engineToClient] {
            #expect(GateDiagnostics.relayFailure(target: "discord.com:443", error: .io(ECONNRESET), direction: direction, elapsedMilliseconds: 24) ==
                "Failure stage=Relay target=discord.com:443 category=IO socket=ConnectionReset direction=" + direction.rawValue + " elapsed_ms=24")
        }
        #expect(GateDiagnostics.relayFailure(target: "discord.com:443/PRIVATE_FIXTURE", error: .io(nil), direction: nil, elapsedMilliseconds: -1) ==
            "Failure stage=Relay target=unknown category=IO direction=unknown elapsed_ms=0")
        #expect(GateDiagnostics.relayFailure(target: "discord.com:443", error: .timeout, direction: nil, elapsedMilliseconds: .max)
            .hasSuffix("direction=unknown elapsed_ms=86400000"))
        #expect(GateDiagnostics.relayFailure(target: "discord.com:443", error: .timeout, direction: nil, elapsedMilliseconds: .min)
            .hasSuffix("direction=unknown elapsed_ms=0"))
    }

    @Test func boundsSuccessAndFailureLinesSeparatelyPerMinute() {
        let budget = TraceBudget()
        let instant = Date(timeIntervalSince1970: 1_767_225_600)
        #expect((0..<100).filter { _ in budget.admit(failure: false, now: instant) }.count == TraceBudget.successLimit)
        #expect((0..<100).filter { _ in budget.admit(failure: true, now: instant) }.count == TraceBudget.failureLimit)
        #expect(!budget.admit(failure: true, now: instant.addingTimeInterval(59)))
        #expect(budget.admit(failure: true, now: instant.addingTimeInterval(60)))
        #expect(budget.admit(failure: false, now: instant.addingTimeInterval(60)))
        // Failures do not use up the success budget either.
        let other = TraceBudget()
        #expect((0..<100).filter { _ in other.admit(failure: true, now: instant) }.count == TraceBudget.failureLimit)
        #expect(other.admit(failure: false, now: instant))
        // A clock set back starts a new window instead of keeping a spent one.
        #expect((0..<100).filter { _ in budget.admit(failure: true, now: instant.addingTimeInterval(60)) }.count == TraceBudget.failureLimit - 1)
        #expect(budget.admit(failure: true, now: instant.addingTimeInterval(-60)))
    }
}
