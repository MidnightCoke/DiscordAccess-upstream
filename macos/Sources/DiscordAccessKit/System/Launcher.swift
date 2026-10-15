import Darwin
import Foundation

/// Opens an app or an address through Launch Services with `/usr/bin/open` (design 8). `open` gets only its standard
/// descriptors, all on /dev/null (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so no socket of the session reaches it, even one another
/// thread is just creating; Launch Services then starts the app outside this process, without this process's environment.
enum Launcher {
    static let tool = "/usr/bin/open"

    /// Runs `open` with `arguments` and waits for it, `timeout` at most; true when it reported success in time. An `open`
    /// that takes longer is stopped; what it asked of Launch Services may still happen.
    static func open(_ arguments: [String], timeout: TimeInterval = 10) -> Bool {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF)) == 0, setDefaultSignals(&attributes),
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { return false }
        var pid: pid_t = 0
        let status = withCStringArray([tool] + arguments) { argv in
            withCStringArray(["PATH=/usr/bin:/bin"]) { environment in
                posix_spawn(&pid, tool, &actions, &attributes, argv, environment)
            }
        }
        guard status == 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var result: Int32 = 0
        while true {
            let reaped = waitpid(pid, &result, WNOHANG)
            if reaped == pid { break }
            guard reaped == 0 || errno == EINTR else { return false }
            guard Date() < deadline else {
                kill(pid, SIGKILL)
                while waitpid(pid, &result, 0) == -1 && errno == EINTR {}
                return false
            }
            usleep(20_000)
        }
        // A zero wait status is a normal exit with code 0.
        return result == 0
    }
}
