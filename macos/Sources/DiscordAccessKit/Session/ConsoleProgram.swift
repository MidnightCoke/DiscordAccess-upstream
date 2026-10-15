import Darwin
import Foundation

/// The `DiscordAccess` command (Windows `Program.Main` with `ConsoleHost.Run`): options, no root, one instance per user,
/// then `--restore`, `--verify-package` or the terminal session. Exit codes: 0; 1 when connecting or cleaning up failed;
/// 3 when the command could not start; 64 for a wrong command line; 130 after an interrupt, or when shutting down took
/// too long.
public enum ConsoleProgram {
    /// Held until the process ends, never released before: a shutdown that took too long may leave a thread still
    /// changing Discord's profile until the program exits.
    private static var heldLock: SessionLock?

    /// `engine` and `hook` are the package's engine and attachment download hook.
    public static func run(arguments: [String], engine: String, hook: String) -> Int32 {
        let options: CommandOptions
        do {
            options = try CommandOptions.parse(arguments)
        } catch let invalid as CommandOptions.Invalid {
            writeLine(invalid.message, to: STDERR_FILENO)
            return 64
        } catch {
            writeLine(ConsoleSession.message(error), to: STDERR_FILENO)
            return 64
        }
        if options.mode == .help {
            CommandOptions.help.forEach { writeLine($0) }
            return 0
        }
        // A closed terminal must not end the program in the middle of its cleanup.
        signal(SIGPIPE, SIG_IGN)
        raiseDescriptorLimit()
        do {
            guard getuid() != 0, geteuid() != 0 else { throw KitError.runningAsRoot() }
            switch options.mode {
            case .verifyPackage:
                _ = try EngineImage.verify(path: engine)
                _ = try SessionWrapper.loadHook(path: hook)
                writeLine("Paket doğrulandı.")
                return 0
            case .restore:
                guard let lock = try SessionLock.acquire() else { throw KitError.sessionStillOpen() }
                heldLock = lock
                writeLine(try terminalAccess { try SessionController.restore() } ? "Discord'un geçici bağlantı ayarları geri alındı." :
                    "Geri alınacak geçici Discord ayarı bulunmadı.")
                return 0
            case .console, .help:
                guard let lock = try SessionLock.acquire() else {
                    writeLine("DiscordAccess zaten çalışıyor; ikinci bağlantı başlatılmadı.")
                    return 0
                }
                heldLock = lock
                return console(options, engine: engine, hook: hook)
            }
        } catch {
            writeLine("DiscordAccess açılamadı: " + ConsoleSession.message(error), to: STDERR_FILENO)
            return 3
        }
    }

    private static func console(_ options: CommandOptions, engine: String, hook: String) -> Int32 {
        let log = try? SessionLog()
        let output = ConsoleOutput(file: { log?.write($0) }, screen: { writeLine($0) })
        defer { output.close() }
        let state = ConsoleSession.State()
        output.show("DiscordAccess | Bağlanıyor...")
        let settings = SessionController.Settings(engine: engine, hook: hook, dns: options.dns, discordPath: options.discordPath)
        let controller = SessionController(settings: settings, log: output.file, changed: { active, message in
            state.stateChanged(active)
            guard !message.isEmpty else { return }
            if state.ended { output.show(message) } else { output.file(message) }
        })
        // An interrupt, a closed terminal window or a termination request stops the session as Q does, with code 130.
        let signals = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                state.requestStop(130)
                controller.cancel()
            }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        let input = Thread {
            readLines { line in
                state.command(line)
                return line != nil && !state.stopRequested && !state.ended
            }
        }
        input.name = "DiscordAccess console input"
        input.start()
        var operations = ConsoleSession.Operations(controller)
        operations.connect = { try terminalAccess(controller.connect) }
        let result = ConsoleSession.run(operations, state: state, show: output.show)
        // An engine left by a shutdown that took too long would outlive the program on macOS.
        if let resolved = realpath(engine, nil) {
            EngineProcess.terminateChildren(enginePath: String(cString: resolved))
            free(resolved)
        }
        return result
    }

    /// Run from a terminal, macOS asks Full Disk Access of the terminal app: a refused data folder opens System Settings
    /// there and says so.
    private static func terminalAccess<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch let error as KitError where error == KitError.profileAccessDenied() {
            DiscordProfile.openFullDiskAccessSettings()
            throw KitError.profileAccessDeniedInTerminal()
        }
    }

    /// 64 gate connections use 128 descriptors, and macOS starts a program with a soft limit of 256 (design 9).
    static func raiseDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(rlim_t(4096), limit.rlim_max)
        guard limit.rlim_cur < wanted else { return }
        limit.rlim_cur = wanted
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }

    /// The lines typed in the terminal, passed to `deliver` until it returns false; nil when the input ends. A line is read
    /// at most 32 KiB far, and a longer one is dropped, as one over 8192 characters would be (Windows reads it whole).
    static func readLines(from descriptor: Int32 = STDIN_FILENO, _ deliver: (String?) -> Bool) {
        let maxLineBytes = 32_768
        var line: [UInt8] = []
        var dropping = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                if !line.isEmpty && !dropping && !deliver(String(decoding: line, as: UTF8.self)) { return }
                _ = deliver(nil)
                return
            }
            for byte in buffer[..<count] {
                if byte == 10 {
                    if !dropping && !deliver(String(decoding: line.last == 13 ? line.dropLast() : line[...], as: UTF8.self)) { return }
                    line.removeAll(keepingCapacity: true)
                    dropping = false
                } else if !dropping {
                    line.append(byte)
                    if line.count > maxLineBytes {
                        line.removeAll()
                        dropping = true
                    }
                }
            }
        }
    }

    /// Writes a line as the terminal session shows its lines (`ConsoleOutput.clean`); a closed terminal loses it.
    private static func writeLine(_ text: String, to descriptor: Int32 = STDOUT_FILENO) {
        let bytes = Array((ConsoleOutput.clean(text) + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            offset += count
        }
    }
}
