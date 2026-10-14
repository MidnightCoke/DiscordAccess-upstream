import Darwin
import Testing
@testable import DiscordAccessKit

@Suite struct ProcessInspectorTests {
    @Test func describesTheCurrentProcess() throws {
        let record = try #require(ProcessInspector.record(for: getpid()))
        #expect(record.uid == getuid())
        #expect(record.parentPid > 0)
        #expect(record.path.hasPrefix("/"))
        #expect(ProcessInspector.userProcessIDs().contains(getpid()))
        #expect(ProcessInspector.record(for: 0) == nil)
        #expect(ProcessInspector.record(for: -1) == nil)
    }

    /// The child starts before the listener exists, so it cannot inherit the socket. Unlike launchd (pid 1), whose
    /// descriptors cannot be listed at all, it is a same-user process whose descriptors are readable.
    @Test func findsOnlyTheOwnersLoopbackListener() throws {
        let other = try startChild("/bin/sleep", ["30"])
        defer {
            other.terminate()
            other.waitUntilExit()
        }
        let listener = try TCPListener()
        let client = try LoopbackClient(port: listener.port)
        #expect(ProcessInspector.ownsLoopbackListener(pid: getpid(), port: listener.port))
        // While this process's connected socket holds the client's port, no listener of any test can take it.
        withExtendedLifetime(client) { #expect(!ProcessInspector.ownsLoopbackListener(pid: getpid(), port: client.localPort)) }
        #expect(ProcessInspector.record(for: other.processIdentifier)?.uid == getuid())
        #expect(!ProcessInspector.ownsLoopbackListener(pid: other.processIdentifier, port: listener.port))
        #expect(!ProcessInspector.ownsLoopbackListener(pid: 1, port: listener.port))
    }

    @Test func ignoresListenersOutsideLoopback() throws {
        let wildcard = try TCPListener(address: "0.0.0.0")
        #expect(ProcessInspector.tcpSockets(of: getpid())?.contains { $0.listening && !$0.localLoopback && $0.localPort == wildcard.port } == true)
        #expect(!ProcessInspector.ownsLoopbackListener(pid: getpid(), port: wildcard.port))
    }

    /// Waits for the settled holder set: a child being spawned by another test briefly holds copies of this process's descriptors.
    static func holders(_ localPort: UInt16, _ remotePort: UInt16, settleTo expected: Set<pid_t>) -> Bool {
        waitFor { ProcessInspector.loopbackConnectionHolders(localPort: localPort, remotePort: remotePort).map(Set.init) == expected ? true : nil } == true
    }

    @Test func findsEveryHolderOfALoopbackConnection() throws {
        let listener = try TCPListener()
        let client = try LoopbackClient(port: listener.port)
        let accepted = try listener.acceptClient()
        defer { close(accepted.descriptor) }
        #expect(accepted.clientPort == client.localPort)
        #expect(Self.holders(client.localPort, listener.port, settleTo: [getpid()]))
        #expect(Self.holders(listener.port, client.localPort, settleTo: [getpid()]))
        #expect(Self.holders(listener.port, listener.port, settleTo: []))
        // A child that inherits the client's descriptor holds the same connection.
        let child = try spawnSharing(client.descriptor, executable: "/bin/sleep", arguments: ["30"])
        defer { reap(child) }
        #expect(Self.holders(client.localPort, listener.port, settleTo: [getpid(), child]))
    }

    @Test func checksCodeRequirementsOfARunningProcess() throws {
        let sleeper = try startChild("/bin/sleep", ["30"])
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        let pid = sleeper.processIdentifier
        #expect(ProcessInspector.satisfies(pid: pid, requirement: "anchor apple"))
        #expect(!ProcessInspector.satisfies(pid: pid, requirement: "anchor apple generic and certificate leaf[subject.OU] = \"53Q6R32WPB\""))
        #expect(!ProcessInspector.satisfies(pid: pid, requirement: "not a requirement"))
        #expect(!ProcessInspector.satisfies(pid: 0, requirement: "anchor apple"))
    }
}
