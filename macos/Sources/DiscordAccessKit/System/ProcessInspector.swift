import Darwin
import Foundation
import Security

/// Read-only views of local processes through libproc and Security.framework.
public enum ProcessInspector {
    public struct Record: Equatable, Sendable {
        public let pid: pid_t
        public let parentPid: pid_t
        public let uid: uid_t
        public let startSeconds: UInt64
        public let startMicroseconds: UInt64
        public let path: String
    }

    struct TCPSocket: Equatable {
        let listening: Bool
        let established: Bool
        let localLoopback: Bool
        let localPort: UInt16
        let remoteLoopback: Bool
        let remotePort: UInt16
    }

    public static func userProcessIDs(uid: uid_t = getuid()) -> [pid_t] {
        completeUserProcessIDs(uid: uid) ?? []
    }

    public static func record(for pid: pid_t) -> Record? {
        guard pid > 0, let info = bsdInfo(of: pid) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        // The path comes from a second call; an unchanged start time afterwards shows the pid was not reused in between.
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, let after = bsdInfo(of: pid),
              after.pbi_start_tvsec == info.pbi_start_tvsec, after.pbi_start_tvusec == info.pbi_start_tvusec else { return nil }
        return Record(pid: pid, parentPid: pid_t(info.pbi_ppid), uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                      startMicroseconds: info.pbi_start_tvusec, path: String(cString: buffer))
    }

    /// True when `pid` holds a TCP socket listening on 127.0.0.1:`port` (Windows `TcpOwner.OwnsListener`).
    public static func ownsLoopbackListener(pid: pid_t, port: UInt16) -> Bool {
        tcpSockets(of: pid)?.contains { $0.listening && $0.localLoopback && $0.localPort == port } ?? false
    }

    /// The same-user processes holding the loopback TCP connection that they see as 127.0.0.1:`localPort` to
    /// 127.0.0.1:`remotePort` (Windows `TcpOwner.Find`, which stops at the first). Nil when any process or descriptor list
    /// could not be read completely. Processes of other users cannot be inspected and are not part of the answer. A process
    /// being spawned holds copies of its parent's descriptors until it executes, so a caller needing an exact set retries.
    public static func loopbackConnectionHolders(localPort: UInt16, remotePort: UInt16, uid: uid_t = getuid()) -> [pid_t]? {
        guard let pids = completeUserProcessIDs(uid: uid) else { return nil }
        var holders: [pid_t] = []
        for pid in pids {
            guard let sockets = tcpSockets(of: pid) else { return nil }
            if sockets.contains(where: { $0.established && $0.localLoopback && $0.localPort == localPort && $0.remoteLoopback && $0.remotePort == remotePort }) {
                holders.append(pid)
            }
        }
        return holders
    }

    /// Dynamic code-signing check of a running process against a requirement, e.g. `cdhash H"…"` or a Team ID rule.
    /// It never uses the network: an online revocation or notarization check could stall a connection for a minute,
    /// and Gatekeeper already applied those checks when the process was launched.
    public static func satisfies(pid: pid_t, requirement text: String) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var requirement: SecRequirement?
        guard pid > 0, SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [.noNetworkAccess], requirement) == errSecSuccess
    }

    /// Every process of `uid`, or nil when the list could not be read completely.
    static func completeUserProcessIDs(uid: uid_t) -> [pid_t]? {
        for _ in 0..<4 {
            let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
            guard needed > 0 else { return nil }
            var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
            let filled = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), buffer.baseAddress, Int32(buffer.count))
            }
            guard filled > 0 else { return nil }
            // A full buffer may have been cut short by processes started meanwhile; read again with more room.
            let count = Int(filled) / MemoryLayout<pid_t>.stride
            if count < pids.count { return pids.prefix(count).filter { $0 > 0 } }
        }
        return nil
    }

    /// The IPv4 TCP sockets of `pid` ([] once it has exited), or nil when its descriptors could not be read completely.
    static func tcpSockets(of pid: pid_t) -> [TCPSocket]? {
        guard let descriptors = socketDescriptors(of: pid) else { return nil }
        let loopback = inet_addr("127.0.0.1")
        var sockets: [TCPSocket] = []
        for descriptor in descriptors {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            errno = 0
            guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size else {
                // A descriptor closed or reused meanwhile, or a process that exited, holds nothing any more.
                if errno == EBADF || errno == ENOTSOCK || errno == ESRCH { continue }
                return nil
            }
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let endpoint = tcp.tcpsi_ini
            guard endpoint.insi_vflag & UInt8(INI_IPV4) != 0 else { continue }
            sockets.append(TCPSocket(listening: tcp.tcpsi_state == Int32(TSI_S_LISTEN),
                                     established: tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED),
                                     localLoopback: endpoint.insi_laddr.ina_46.i46a_addr4.s_addr == loopback,
                                     localPort: networkPort(endpoint.insi_lport),
                                     remoteLoopback: endpoint.insi_faddr.ina_46.i46a_addr4.s_addr == loopback,
                                     remotePort: networkPort(endpoint.insi_fport)))
        }
        return sockets
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// The socket descriptors of `pid` ([] once it has exited), or nil when its table could not be read completely.
    private static func socketDescriptors(of pid: pid_t) -> [Int32]? {
        for _ in 0..<4 {
            errno = 0
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return errno == 0 || errno == ESRCH ? [] : nil }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16)
            errno = 0
            let filled = descriptors.withUnsafeMutableBytes { buffer in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard filled > 0 else { return errno == 0 || errno == ESRCH ? [] : nil }
            // A full buffer may have been cut short by descriptors opened meanwhile; read again with more room.
            let count = Int(filled) / MemoryLayout<proc_fdinfo>.stride
            if count < descriptors.count {
                return descriptors.prefix(count).filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }.map(\.proc_fd)
            }
        }
        return nil
    }

    private static func networkPort(_ value: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: value))
    }
}
