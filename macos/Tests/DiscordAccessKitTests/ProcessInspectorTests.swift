import Darwin
import Foundation
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

    @Test func tellsWhetherAProcessHoldsALoopbackConnection() throws {
        let listener = try TCPListener()
        let client = try LoopbackClient(port: listener.port)
        let accepted = try listener.acceptClient()
        defer { close(accepted.descriptor) }
        #expect(accepted.clientPort == client.localPort)
        #expect(ProcessInspector.holdsLoopbackConnection(pid: getpid(), localPort: client.localPort, remotePort: listener.port) == true)
        #expect(ProcessInspector.holdsLoopbackConnection(pid: getpid(), localPort: listener.port, remotePort: client.localPort) == true)
        #expect(ProcessInspector.holdsLoopbackConnection(pid: getpid(), localPort: listener.port, remotePort: listener.port) == false)
        // A child that inherits the client's descriptor holds the same connection; launchd's descriptors cannot be read.
        let child = try spawnSharing(client.descriptor, executable: "/bin/sleep", arguments: ["30"])
        defer { reap(child) }
        #expect(waitFor { ProcessInspector.holdsLoopbackConnection(pid: child, localPort: client.localPort, remotePort: listener.port) == true ? true : nil } == true)
        #expect(ProcessInspector.holdsLoopbackConnection(pid: 1, localPort: client.localPort, remotePort: listener.port) != true)
    }

    /// A child being spawned holds copies of its parent's descriptors until exec closes them. Inspecting such a copy at
    /// that moment made the kernel drain the socket, and blocked reads on it failed with EBADF for good. Here the children
    /// of this process (and no other process) are inspected over and over while children are spawned and reads wait.
    @Test func inspectingProcessesLeavesSocketsOfSpawningProcessesIntact() throws {
        let listener = try TCPListener()
        var clients: [LoopbackClient] = []
        var accepted: [Int32] = []
        defer { accepted.forEach { close($0) } }
        for _ in 0..<40 {
            let client = try LoopbackClient(port: listener.port)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            clients.append(client)
            accepted.append(try listener.acceptClient().descriptor)
        }
        let lock = NSLock()
        var running = true
        var failures: [Int32] = []
        let readers = DispatchGroup()
        for descriptor in clients.map(\.descriptor) {
            readers.enter()
            Thread {
                var byte: UInt8 = 0
                // Only the receive timeout may end the read: data or an end of stream is recorded as 0, an error as its errno.
                let count = read(descriptor, &byte, 1)
                let error = count < 0 ? errno : 0
                lock.lock()
                if error != EAGAIN { failures.append(error) }
                lock.unlock()
                readers.leave()
            }.start()
        }
        func keepRunning() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }
        let workers = DispatchGroup()
        for _ in 0..<3 {
            workers.enter()
            Thread {
                while keepRunning() {
                    for pid in ProcessInspector.userProcessIDs() where ProcessInspector.record(for: pid)?.parentPid == getpid() {
                        _ = ProcessInspector.tcpSockets(of: pid)
                    }
                }
                workers.leave()
            }.start()
            workers.enter()
            Thread {
                while keepRunning() {
                    if let child = try? startChild("/bin/sleep", ["0"]) { child.waitUntilExit() } else { usleep(10_000) }
                }
                workers.leave()
            }.start()
        }
        usleep(2_500_000)
        lock.lock()
        running = false
        lock.unlock()
        workers.wait()
        readers.wait()
        #expect(failures.isEmpty, "reads ended early: \(failures)")
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
