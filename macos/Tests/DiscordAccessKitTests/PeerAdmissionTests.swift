import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// `/usr/bin/nc` stands in for Discord: an Apple-signed client that keeps its connection to the gate open (`-d`).
@Suite struct PeerAdmissionTests {
    static let netcat = ApprovedExecutable(path: "/usr/bin/nc", requirement: "identifier \"com.apple.nc\" and anchor apple")
    static let sleeper = ApprovedExecutable(path: "/bin/sleep", requirement: "identifier \"com.apple.sleep\" and anchor apple")

    /// A netcat child connected to `gate`, the client port the gate saw, and the accepted descriptor (the caller closes it).
    static func connectNetcat(to gate: TCPListener) throws -> (process: Process, clientPort: UInt16, accepted: Int32) {
        let process = try startChild("/usr/bin/nc", ["-d", "127.0.0.1", String(gate.port)])
        do {
            let accepted = try gate.acceptClient()
            return (process, accepted.clientPort, accepted.descriptor)
        } catch {
            stop(process)
            throw error
        }
    }

    static func stop(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }

    static func record(uid: uid_t = getuid(), start: UInt64, path: String = "/usr/bin/nc") -> ProcessInspector.Record {
        ProcessInspector.Record(pid: 4242, parentPid: 1, uid: uid, startSeconds: start / 1_000_000, startMicroseconds: start % 1_000_000, path: path)
    }

    @Test func checksUserStartTimeAndExecutable() throws {
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date(timeIntervalSince1970: 1_800_000_000.25))
        let ready: UInt64 = 1_800_000_000_250_000
        let approved = Result<String, PeerAdmission.Refusal>.success(Self.netcat.requirement)
        #expect(admission.requirement(for: Self.record(start: ready)) == approved)
        #expect(admission.requirement(for: Self.record(start: ready + 1)) == approved)
        #expect(admission.requirement(for: Self.record(start: ready - 1)) == .failure(.startedBeforeReady))
        #expect(admission.requirement(for: Self.record(start: 0)) == .failure(.startedBeforeReady))
        #expect(admission.requirement(for: Self.record(uid: getuid() &+ 1, start: ready)) == .failure(.otherUser))
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/bin/curl")) == .failure(.unapprovedExecutable("curl")))
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/bin/../bin/nc")) == approved)
        // On a case-insensitive volume the process path may differ from the approved one in letter case only.
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/BIN/nc")) ==
            (FileManager.default.fileExists(atPath: "/usr/BIN/nc") ? approved : .failure(.unapprovedExecutable("nc"))))
    }

    @Test func refusesUnsafeConfiguration() throws {
        #expect(throws: PeerAdmission.ConfigurationError.noExecutables) { try PeerAdmission(approved: [], readyTime: Date()) }
        #expect(throws: PeerAdmission.ConfigurationError.tooManyExecutables) {
            try PeerAdmission(approved: Array(repeating: Self.netcat, count: 17), readyTime: Date())
        }
        #expect(throws: Never.self) { try PeerAdmission(approved: Array(repeating: Self.netcat, count: 16), readyTime: Date()) }
        for path in ["usr/bin/nc", "/usr/bin/../bin/nc", "/tmp", "/usr/bin/nc/fixture"] {
            #expect(throws: PeerAdmission.ConfigurationError.unsafePath(path)) {
                try PeerAdmission(approved: [ApprovedExecutable(path: path, requirement: "anchor apple")], readyTime: Date())
            }
        }
        #expect(throws: PeerAdmission.ConfigurationError.missingExecutable("/usr/bin/missing-fixture")) {
            try PeerAdmission(approved: [ApprovedExecutable(path: "/usr/bin/missing-fixture", requirement: "anchor apple")], readyTime: Date())
        }
    }

    @Test func admitsAnApprovedClientUntilItExits() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let client = try Self.connectNetcat(to: gate)
        defer { close(client.accepted) }
        #expect(admission.permits(clientPort: client.clientPort, gatePort: gate.port))
        #expect(admission.permits(clientPort: client.clientPort, gatePort: gate.port))
        #expect(admission.anyAdmittedRunning)
        Self.stop(client.process)
        #expect(admission.refusal(pid: client.process.processIdentifier) == .unknownProcess)
        #expect(!admission.anyAdmittedRunning)
        // Nothing holds the client end any more; an empty set of holders is never admitted.
        #expect(admission.refusal(clientPort: client.clientPort, gatePort: gate.port) == .noHolder)
    }

    /// A process whose parent exits moves to launchd. It is still the same admitted instance and still counts as running.
    @Test func keepsAnAdmittedClientWhoseParentExits() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let launcher = try startChild("/bin/sh", ["-c", "/usr/bin/nc -d 127.0.0.1 \"$0\" & wait", String(gate.port)])
        defer { Self.stop(launcher) }
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        let client = try #require(waitFor {
            ProcessInspector.userProcessIDs().compactMap(ProcessInspector.record(for:)).first { $0.parentPid == launcher.processIdentifier && $0.path == "/usr/bin/nc" }?.pid
        })
        defer { kill(client, SIGKILL) }
        #expect(ProcessInspector.record(for: client)?.parentPid == launcher.processIdentifier)
        #expect(admission.permits(clientPort: accepted.clientPort, gatePort: gate.port))
        kill(launcher.processIdentifier, SIGTERM)
        launcher.waitUntilExit()
        #expect(waitFor { ProcessInspector.record(for: client)?.parentPid == 1 ? true : nil } == true)
        #expect(admission.anyAdmittedRunning)
        #expect(admission.permits(clientPort: accepted.clientPort, gatePort: gate.port))
    }

    @Test func refusesClientsStartedBeforeReadiness() throws {
        let gate = try TCPListener()
        let client = try Self.connectNetcat(to: gate)
        defer {
            close(client.accepted)
            Self.stop(client.process)
        }
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        #expect(admission.refusal(clientPort: client.clientPort, gatePort: gate.port) == .startedBeforeReady)
    }

    @Test func refusesOtherExecutablesAndWrongRequirements() throws {
        let gate = try TCPListener()
        let ready = Date()
        let client = try Self.connectNetcat(to: gate)
        defer {
            close(client.accepted)
            Self.stop(client.process)
        }
        let requirements = [Self.sleeper.requirement, "identifier \"com.hnc.Discord\" and anchor apple generic and certificate leaf[subject.OU] = \"53Q6R32WPB\""]
        // A client that runs no approved executable is not even looked at.
        #expect(try PeerAdmission(approved: [Self.sleeper], readyTime: ready).refusal(clientPort: client.clientPort, gatePort: gate.port) == .noHolder)
        for requirement in requirements {
            let impostor = ApprovedExecutable(path: "/usr/bin/nc", requirement: requirement)
            #expect(try PeerAdmission(approved: [impostor], readyTime: ready).refusal(clientPort: client.clientPort, gatePort: gate.port) ==
                .requirementNotMet)
        }
        #expect((try PeerAdmission(approved: [Self.sleeper, Self.netcat], readyTime: ready)).permits(clientPort: client.clientPort, gatePort: gate.port))
    }

    /// A connection that no candidate holds is refused without retries, so that each connection of another local user
    /// cannot hold a gate slot through three 10 ms pauses. The fastest of five refusals is measured.
    @Test func refusesAConnectionNoCandidateHoldsAtOnce() throws {
        let gate = try TCPListener()
        let client = try Self.connectNetcat(to: gate)
        defer {
            close(client.accepted)
            Self.stop(client.process)
        }
        let admission = try PeerAdmission(approved: [Self.sleeper], readyTime: Date())
        let durations = (0..<5).map { _ -> TimeInterval in
            let started = Date()
            #expect(admission.refusal(clientPort: client.clientPort, gatePort: gate.port) == .noHolder)
            return Date().timeIntervalSince(started)
        }
        let fastest = try #require(durations.min())
        #expect(fastest < 0.025)
    }

    @Test func admitsItselfOnlyWithDiagnosticPermission() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let client = try LoopbackClient(port: gate.port)
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        #expect(admission.refusal(clientPort: client.localPort, gatePort: gate.port) == .diagnosticNotAllowed)
        admission.diagnosticAllowed = true
        #expect(admission.permits(clientPort: client.localPort, gatePort: gate.port))
        admission.diagnosticAllowed = false
        #expect(!admission.permits(clientPort: client.localPort, gatePort: gate.port))
    }

    /// A child running an executable that is not approved and shares the client's socket does not matter (1b refused
    /// every connection such a child also held): this process holds the socket too and is decided by `diagnosticAllowed`.
    /// That such a child is not even inspected shows in `refusesOtherExecutablesAndWrongRequirements`.
    @Test func ignoresAnUnapprovedChildThatSharesTheClientSocket() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let client = try LoopbackClient(port: gate.port)
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        let child = try spawnSharing(client.descriptor, executable: "/bin/sleep", arguments: ["30"])
        defer { reap(child) }
        #expect(admission.refusal(clientPort: client.localPort, gatePort: gate.port) == .diagnosticNotAllowed)
        admission.diagnosticAllowed = true
        #expect(admission.permits(clientPort: client.localPort, gatePort: gate.port))
    }

    @Test func remembersAtMostItsCapacityAndNothingAfterClose() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date(), capacity: 1)
        let first = try Self.connectNetcat(to: gate)
        defer {
            close(first.accepted)
            Self.stop(first.process)
        }
        let second = try Self.connectNetcat(to: gate)
        defer {
            close(second.accepted)
            Self.stop(second.process)
        }
        #expect(admission.permits(clientPort: first.clientPort, gatePort: gate.port))
        #expect(admission.refusal(clientPort: second.clientPort, gatePort: gate.port) == .capacity)
        admission.close()
        #expect(admission.refusal(clientPort: first.clientPort, gatePort: gate.port) == .closed)
        #expect(!admission.anyAdmittedRunning)
        #expect(!admission.permits(pid: 0))
        #expect(!admission.permits(pid: -1))
    }

    @Test func namesRefusalsSafelyForDiagnostics() {
        let names = [PeerAdmission.Refusal.closed, .unreadable, .noHolder, .holdersChanged, .diagnosticNotAllowed, .unknownProcess, .otherUser,
                     .startedBeforeReady, .requirementNotMet, .capacity].map(\.diagnostic)
        #expect(names == ["Closed", "Unreadable", "NoHolder", "HoldersChanged", "DiagnosticNotAllowed", "UnknownProcess", "OtherUser",
                          "StartedBeforeReady", "RequirementNotMet", "Capacity"])
        #expect(PeerAdmission.Refusal.unapprovedExecutable("Discord Helper (Foo)").diagnostic == "UnapprovedExecutable executable=Discord_Helper_(Foo)")
        #expect(PeerAdmission.Refusal.unapprovedExecutable("a\r\nb=c\u{1F600}\u{E9}").diagnostic == "UnapprovedExecutable executable=a__b_c__")
        #expect(PeerAdmission.Refusal.unapprovedExecutable(String(repeating: "x", count: 100)).diagnostic ==
            "UnapprovedExecutable executable=" + String(repeating: "x", count: 64))
    }
}
