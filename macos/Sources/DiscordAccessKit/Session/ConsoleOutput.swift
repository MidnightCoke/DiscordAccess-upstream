import Foundation

/// The terminal session's output (Windows `ConsoleOutput`). Producers never write to the screen or the disk themselves:
/// the file log and the screen each have a bounded queue drained by its own thread, so a paused terminal or a slow disk
/// cannot hold up the gate, the bridge, the session's operations or its cleanup. Lines that do not fit are dropped and
/// counted.
public final class ConsoleOutput {
    private let files: Sink
    private let screen: Sink

    public init(file: @escaping (String) -> Void, screen: @escaping (String) -> Void) {
        self.files = Sink(capacity: 512, name: "DiscordAccess file log", write: file)
        self.screen = Sink(capacity: 32, name: "DiscordAccess console output", write: screen)
    }

    /// A line for the log only.
    public func file(_ message: String) {
        files.enqueue(Self.clean(message))
    }

    /// A line for the screen and the log.
    public func show(_ message: String) {
        let clean = Self.clean(message)
        files.enqueue(clean)
        screen.enqueue(clean)
    }

    /// Writes what is queued, giving each queue 150 ms; a write blocked for good is left behind (Windows `Dispose`).
    public func close() {
        files.stop()
        screen.stop()
        _ = files.join(timeout: 0.15)
        _ = screen.join(timeout: 0.15)
    }

    /// One line of at most 1000 characters, control and direction characters shown as spaces (Windows `Clean`).
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let shown = scalars.prefix(1000).map { scalar -> Unicode.Scalar in
            scalar.properties.generalCategory == .control || isDirectionControl(scalar) ? " " : scalar
        }
        let clean = String(String.UnicodeScalarView(shown)).trimmingCharacters(in: .whitespaces)
        return scalars.count > 1000 ? clean + "…" : clean
    }

    /// The marks and overrides that change the order text is shown in, as a file name could carry to disguise itself.
    private static func isDirectionControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) || [0x200E, 0x200F, 0x061C].contains(scalar.value)
    }
}

/// A bounded queue with the thread that writes it.
private final class Sink {
    private let condition = NSCondition()
    private let capacity: Int
    private let write: (String) -> Void
    private let finished = DispatchSemaphore(value: 0)
    private var queue: [String] = []
    private var dropped = 0
    private var stopped = false

    init(capacity: Int, name: String, write: @escaping (String) -> Void) {
        self.capacity = capacity
        self.write = write
        let thread = Thread { [self] in drain() }
        thread.name = name
        thread.start()
    }

    func enqueue(_ message: String) {
        guard !message.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { return }
        if queue.count < capacity {
            queue.append(message)
            condition.signal()
        } else {
            dropped += 1
        }
    }

    /// Accepts nothing more; what is queued is still written.
    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    func join(timeout: TimeInterval) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    private func drain() {
        while true {
            condition.lock()
            while queue.isEmpty && !stopped { condition.wait() }
            guard !queue.isEmpty else {
                condition.unlock()
                finished.signal()
                return
            }
            let item = queue.removeFirst()
            let skipped = dropped
            dropped = 0
            condition.unlock()
            if skipped > 0 { write("Skipped " + String(skipped) + " diagnostic lines because of heavy logging.") }
            write(item)
        }
    }
}
