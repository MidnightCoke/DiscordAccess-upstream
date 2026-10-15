import Foundation

/// The terminal session (Windows `ConsoleHost.RunSession`): connects, then runs the commands typed in the terminal until
/// Q, an interrupt or the connection's end, and always disconnects within the shutdown time. Each operation runs on its
/// own thread, so the terminal can always stop.
public enum ConsoleSession {
    public static let help = "A: Discord aç | Q: kapat | T: tanılama | D: dosya indir"
    static let maxQueued = 64
    static let maxCommandLength = 8192

    /// What the terminal asks of the session; tests stand in for the controller here.
    public struct Operations {
        public var connect: () throws -> Void
        public var readyMessage: () -> String
        public var openDiscord: () throws -> String
        public var diagnose: () throws -> String
        public var download: (String) throws -> String
        public var disconnect: () throws -> Void

        public init(connect: @escaping () throws -> Void, readyMessage: @escaping () -> String, openDiscord: @escaping () throws -> String,
                    diagnose: @escaping () throws -> String, download: @escaping (String) throws -> String, disconnect: @escaping () throws -> Void) {
            self.connect = connect
            self.readyMessage = readyMessage
            self.openDiscord = openDiscord
            self.diagnose = diagnose
            self.download = download
            self.disconnect = disconnect
        }

        /// The operations of `controller`.
        public init(_ controller: SessionController) {
            self.init(connect: controller.connect, readyMessage: { SessionController.readyMessage }, openDiscord: controller.openDiscord,
                      diagnose: controller.diagnose, download: controller.download, disconnect: controller.disconnect)
        }
    }

    /// The commands typed so far, the stop request and whether the connection ended (Windows `SessionState`); used from
    /// any thread.
    public final class State {
        private let condition = NSCondition()
        private var commands: [String] = []
        private var stop = false
        private var code: Int32 = 0
        private var connected = false
        private var connectionEnded = false
        private var inputEnded = false
        private var signaled = false

        public init() {}

        public var stopRequested: Bool { read { stop } }
        /// The connection was active and is no more.
        public var ended: Bool { read { connectionEnded } }
        public var exitCode: Int32 { read { code } }
        public var inputClosed: Bool { read { inputEnded } }

        /// Stops the session; a nonzero `code` becomes the exit code.
        public func requestStop(_ code: Int32) {
            update {
                if code != 0 { self.code = code }
                stop = true
            }
        }

        public func stateChanged(_ active: Bool) {
            update {
                if active {
                    connected = true
                } else if connected {
                    connectionEnded = true
                }
            }
        }

        /// A line typed in the terminal; nil when the input ended. Q (or "çıkış") stops the session at once; other lines
        /// wait in order, 64 at most, each up to 8192 characters.
        public func command(_ text: String?) {
            guard !stopRequested, !ended else { return }
            guard let text else {
                update { inputEnded = true }
                return
            }
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return }
            if ["Q", "ÇIKIŞ", "CIKIS"].contains(command.uppercased()) {
                requestStop(0)
            } else if command.utf16.count <= ConsoleSession.maxCommandLength {
                update {
                    if commands.count < ConsoleSession.maxQueued { commands.append(command) }
                }
            }
        }

        func nextCommand() -> String? {
            condition.lock()
            defer { condition.unlock() }
            return commands.isEmpty ? nil : commands.removeFirst()
        }

        func wake() {
            update {}
        }

        /// Returns once something changed, or after 100 ms.
        func wait() {
            condition.lock()
            if !signaled { _ = condition.wait(until: Date().addingTimeInterval(0.1)) }
            signaled = false
            condition.unlock()
        }

        private func read<Value>(_ body: () -> Value) -> Value {
            condition.lock()
            defer { condition.unlock() }
            return body()
        }

        private func update(_ body: () -> Void) {
            condition.lock()
            body()
            signaled = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Runs the session until it stops or the connection ends, then disconnects, and returns the exit code: 0, 1 when
    /// connecting or cleaning up failed, the stop request's code, or 130 when shutting down took longer than
    /// `shutdownTimeout`.
    public static func run(_ session: Operations, state: State, show: @escaping (String) -> Void, shutdownTimeout: TimeInterval = 15) -> Int32 {
        var result: Int32 = 0
        var pendingDownload: Pending<String>?
        var pendingOpen: Pending<String>?
        do {
            if !state.stopRequested {
                let connecting = Pending(waking: state) { try session.connect() }
                if wait(for: connecting, state) {
                    try connecting.value()
                    show(session.readyMessage())
                    while !state.stopRequested && !state.ended {
                        guard let command = state.nextCommand() else {
                            state.wait()
                            continue
                        }
                        switch command.uppercased() {
                        case "A":
                            openDiscord(session, state, show, &pendingOpen)
                        case "D":
                            download(session, state, show, &pendingDownload, &pendingOpen)
                        case "T":
                            let diagnosis = Pending(waking: state) { try session.diagnose() }
                            if wait(for: diagnosis, state) {
                                do {
                                    show(try diagnosis.value())
                                } catch {
                                    show("Tanılama tamamlanamadı: " + message(error))
                                }
                            }
                        default:
                            show(help)
                        }
                    }
                }
            }
            if state.stopRequested { result = state.exitCode }
        } catch {
            show("Bağlantı kurulamadı: " + message(error))
            result = 1
        }
        let deadline = Date().addingTimeInterval(shutdownTimeout)
        var timedOut = false
        let disconnecting = Pending(waking: state) { try session.disconnect() }
        if disconnecting.wait(until: deadline) {
            do {
                try disconnecting.value()
            } catch {
                show("Oturum temizliği: " + message(error))
                if result == 0 { result = 1 }
            }
        } else {
            show("Kapanış süresi doldu; bağlantı motoru program kapanırken durdurulacak.")
            timedOut = true
        }
        // Disconnecting ends a download; its partial file is removed before the program exits, within the same time.
        if let pendingDownload {
            if pendingDownload.wait(until: deadline) {
                do {
                    _ = try pendingDownload.value()
                } catch is CancellationError {
                } catch {
                    show("İndirme temizliği: " + message(error))
                    if result == 0 { result = 1 }
                }
            } else {
                show("İndirmenin kapanış süresi doldu; yarım kalan dosya temizliği tamamlanamadı.")
                timedOut = true
            }
        }
        if let pendingOpen {
            if pendingOpen.wait(until: deadline) {
                do {
                    _ = try pendingOpen.value()
                } catch is CancellationError {
                } catch {
                    show("Discord açılış temizliği: " + message(error))
                    if result == 0 { result = 1 }
                }
            } else {
                show("Discord açılışının kapanış süresi doldu.")
                timedOut = true
            }
        }
        if timedOut { return 130 }
        show("Bağlantı kapatıldı.")
        return result
    }

    /// The text shown for a failure (Windows `ErrorMessage`): DiscordAccess's own failures carry fixed, actionable text;
    /// any other error may hold a path or an address, so only its kind is shown.
    public static func message(_ error: Error) -> String {
        switch error {
        case let error as KitError: return error.description
        case let error as ConnectivityFailure: return error.message
        case let error as GatewayHelloFailure: return error.message
        case let error as AttachmentDownloadFailure: return error.message
        case is CancellationError: return "İşlem iptal edildi."
        default: return "İşlem tamamlanamadı (" + String(describing: type(of: error)) + ")."
        }
    }

    /// Whether `operation` completed while the session still runs; its result is ignored otherwise (Windows
    /// `WaitOperation`).
    private static func wait<Value>(for operation: Pending<Value>, _ state: State) -> Bool {
        while !operation.isCompleted && !state.stopRequested && !state.ended { state.wait() }
        return operation.isCompleted && !state.stopRequested && !state.ended
    }

    private static func openDiscord(_ session: Operations, _ state: State, _ show: (String) -> Void, _ pendingOpen: inout Pending<String>?) {
        let opening = Pending(waking: state) { try session.openDiscord() }
        pendingOpen = opening
        if wait(for: opening, state) {
            do {
                let text = try opening.value()
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { show(text) }
            } catch {
                show("Discord açılamadı: " + message(error))
            }
        }
        if opening.isCompleted { pendingOpen = nil }
    }

    /// D asks for the link on the next line; an A typed meanwhile still opens Discord (Windows `Download`).
    private static func download(_ session: Operations, _ state: State, _ show: (String) -> Void, _ pendingDownload: inout Pending<String>?,
                                 _ pendingOpen: inout Pending<String>?) {
        show("Discord ek dosyasının bağlantısını yapıştırıp Enter'a basın. Q: kapat.")
        while !state.stopRequested && !state.ended {
            guard let link = state.nextCommand() else {
                if state.inputClosed {
                    show("Dosya bağlantısı alınamadı; komut girişi kapalı.")
                    return
                }
                state.wait()
                continue
            }
            if link.uppercased() == "A" {
                openDiscord(session, state, show, &pendingOpen)
                continue
            }
            let downloading = Pending(waking: state) { try session.download(link) }
            pendingDownload = downloading
            if wait(for: downloading, state) {
                do {
                    let saved = try downloading.value() as NSString
                    show("Kaydedildi: " + saved.lastPathComponent + " | " + saved.deletingLastPathComponent)
                } catch {
                    show("Dosya indirilemedi: " + message(error))
                }
            }
            if downloading.isCompleted { pendingDownload = nil }
            return
        }
    }
}

/// An operation running on its own thread; its end wakes the terminal session.
final class Pending<Value> {
    private let lock = NSLock()
    private let done = DispatchGroup()
    private var outcome: Result<Value, Error>?

    init(waking state: ConsoleSession.State, _ body: @escaping () throws -> Value) {
        done.enter()
        let thread = Thread { [self] in
            let result = Result { try body() }
            lock.lock()
            outcome = result
            lock.unlock()
            done.leave()
            state.wake()
        }
        thread.name = "DiscordAccess session operation"
        thread.start()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome != nil
    }

    /// The result of a completed operation.
    func value() throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try outcome!.get()
    }

    /// Whether the operation completed by `deadline`.
    func wait(until deadline: Date) -> Bool {
        done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success
    }
}
