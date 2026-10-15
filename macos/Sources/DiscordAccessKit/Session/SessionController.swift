import Dispatch
import Foundation

/// One DiscordAccess session (design 7.1-7.3; Windows `Controller`). A controller connects once; connecting again takes
/// a new one. Connecting takes these steps, and undoes what it did if one fails:
/// 1. Discord.app is found and verified, and must be closed; changes an earlier session left are undone.
/// 2. Discord's data folder must be readable (Full Disk Access).
/// 3. The hook and the engine image are verified, engines a crashed session left are stopped, and the DNS candidate is
///    selected (`DnsSelection`); its gate admits Discord's executables started from now on.
/// 4. The update bridge starts in front of the gate.
/// 5. Discord must still be closed; the profile gets the session wrapper and its update settings point at the bridge.
///
/// An engine that exits, or a gate or bridge that closes itself, ends the session as disconnecting does. Disconnecting
/// undoes the profile changes if Discord is closed (within a second); otherwise their journal stays for the next start or
/// `--restore` (SES-E01). Operations run one at a time; disconnecting first ends a check or download under way.
public final class SessionController {
    public struct Settings {
        /// The engine (`sing-box`) and the attachment download hook both platforms share.
        public var engine: String
        public var hook: String
        public var dns: DnsOptions
        public var discordPath: String?
        public var profile: String
        public var state: String
        public var downloads: String

        public init(engine: String, hook: String, dns: DnsOptions = .automatic, discordPath: String? = nil, profile: String = DiscordProfile.standardRoot,
                    state: String = StateStore.standardRoot, downloads: String = AttachmentDownloader.standardRoot) {
            self.engine = engine
            self.hook = hook
            self.dns = dns
            self.discordPath = discordPath
            self.profile = profile
            self.state = state
            self.downloads = downloads
        }
    }

    /// What the session asks of the system about Discord; tests stand in for Discord here.
    struct System {
        var locate: (String?) throws -> DiscordInstallation = { try DiscordInstallation.locate(path: $0) }
        var running: (DiscordInstallation) throws -> Bool = { try !$0.runningProcesses().isEmpty }
        var launch: (DiscordInstallation, [String]) throws -> Void = { installation, arguments in
            guard Launcher.open(["-a", installation.bundle, "--args"] + arguments) else { throw KitError.discordLaunchFailed() }
        }
    }

    public static let readyMessage = "Bağlantı hazır. Discord'u kendi simgesinden (Dock, Launchpad, Spotlight) ya da A + Enter ile açabilirsiniz."
    /// How long disconnecting waits for Discord to close before it leaves the profile changes to their journal.
    static let exitWait: TimeInterval = 1

    private let settings: Settings
    private let system: System
    private let log: (String) -> Void
    private let changed: (Bool, String) -> Void
    private let operations = NSLock()
    /// Canceled when the session ends: it ends a connection, check or download under way.
    private let lifetime = Cancellation()
    private var installation: DiscordInstallation?
    private var admission: PeerAdmission?
    private var connection: DnsConnection?
    private var bridge: UpdateBridge?
    private var changes: DiscordProfileChanges?
    private var engineWatch: DispatchSourceProcess?
    private var active = false

    /// `log` gets the session's detailed lines, the gate's and the bridge's diagnostics among them; `changed` whether the
    /// session is active, with a short state message. Both are called from the session's threads, `changed` while an
    /// operation runs: neither may block or call the controller.
    public convenience init(settings: Settings, log: @escaping (String) -> Void, changed: @escaping (Bool, String) -> Void) {
        self.init(settings: settings, system: System(), log: log, changed: changed)
    }

    init(settings: Settings, system: System, log: @escaping (String) -> Void, changed: @escaping (Bool, String) -> Void) {
        self.settings = settings
        self.system = system
        self.log = log
        self.changed = changed
    }

    /// `--restore` (Windows `--restore`): undoes an earlier session's profile changes while Discord is closed; true when
    /// there was something to undo. The caller must hold the `SessionLock`.
    public static func restore(profile: String = DiscordProfile.standardRoot, state: String = StateStore.standardRoot) throws -> Bool {
        try restore(profile: profile, state: state, running: { try !DiscordInstallation.runningProcesses(bundle: nil).isEmpty })
    }

    static func restore(profile: String, state: String, running: () throws -> Bool) throws -> Bool {
        guard try DiscordProfileChanges.hasPendingRecovery(state: state) else { return false }
        guard try !running() else { throw KitError.discordRunningDuringRestore() }
        return try DiscordProfileChanges.recover(state: state, profile: profile)
    }

    public func connect() throws {
        operations.lock()
        defer { operations.unlock() }
        guard !active else { return }
        changed(false, "Bağlanıyor")
        log("DiscordAccess: bağlantı hazırlanıyor.")
        do {
            try connectCore()
            active = true
            changed(true, "Bağlantı hazır; Discord kendi simgesinden açılabilir.")
        } catch {
            do {
                try disconnectCore()
            } catch {
                log("Başlangıç sonrası geri alma tamamlanamadı; kurtarma kaydı korundu.")
            }
            changed(false, "Bağlantı kurulamadı")
            throw error
        }
    }

    /// Ends a connection, check or download under way, from another thread (an interrupt in the terminal); the session
    /// can then only disconnect.
    public func cancel() {
        lifetime.cancel()
    }

    /// Opens Discord with the session's proxy as arguments ("Discord'u aç"); Discord's own icon works as well (design 7.2).
    /// Discord's signature is checked again without holding up other operations, as it can take seconds; the session must
    /// still be the same one when Discord is opened.
    public func openDiscord() throws -> String {
        operations.lock()
        guard active, let observed = connection, let installation else {
            operations.unlock()
            throw KitError.sessionNotReady()
        }
        operations.unlock()
        try lifetime.check()
        // Discord may have updated itself since; that version's profile has no wrapper (Windows: "Discord sürümü değişti").
        guard (try? system.locate(installation.bundle)) == installation else { throw KitError.discordChanged() }
        operations.lock()
        defer { operations.unlock() }
        guard active, connection === observed else { throw KitError.sessionNotReady() }
        try lifetime.check()
        if try system.running(installation) { return "Discord zaten açık; ikinci açılış yapılmadı." }
        try system.launch(installation, ["--proxy-server=" + proxy(observed), "--proxy-bypass-list=127.0.0.1;localhost", "--disable-quic"])
        return "Resmi Discord'a açılış isteği gönderildi."
    }

    /// The HTTPS checks go to the log, the Gateway HELLO check is the result (Windows `DiagnoseAsync`).
    public func diagnose() throws -> String {
        operations.lock()
        defer { operations.unlock() }
        guard active, let connection, connection.engine.isRunning else { return "Bağlantı açık değil." }
        log(try ConnectivityProbe.check(proxyPort: connection.gate.port, cancel: lifetime))
        return try GatewayHello.check(proxyPort: connection.gate.port, cancel: lifetime)
    }

    /// Downloads an attachment by its link through the gate and returns the saved file's path; disconnecting ends it.
    public func download(_ link: String) throws -> String {
        operations.lock()
        guard active, let connection else {
            operations.unlock()
            throw AttachmentDownloadFailure(message: "Dosya indirmek için önce DiscordAccess ile bağlantıyı açın.")
        }
        let port = connection.gate.port
        operations.unlock()
        return try AttachmentDownloader.download(link, root: settings.downloads, proxyPort: port, cancel: lifetime)
    }

    public func disconnect() throws {
        lifetime.cancel()
        operations.lock()
        defer { operations.unlock() }
        try disconnectCore()
        changed(false, "Bağlantı kesildi")
    }

    /// The engine's process ID, for tests.
    var enginePID: pid_t? {
        connection?.engine.pid
    }

    private func connectCore() throws {
        try lifetime.check()
        let installation = try system.locate(settings.discordPath)
        guard try !system.running(installation) else { throw KitError.discordRunning() }
        self.installation = installation
        if try DiscordProfileChanges.recover(state: settings.state, profile: settings.profile) {
            log("Önceki oturumun geçici Discord ayarları geri alındı.")
        }
        switch DiscordProfile.access(root: settings.profile) {
        case .denied: throw KitError.profileAccessDenied()
        case .missing: throw KitError.profileMissingModule()
        case .granted: break
        }
        let hook = try SessionWrapper.loadHook(path: settings.hook)
        let image = try EngineImage.verify(path: settings.engine)
        if !EngineProcess.terminateOrphans(enginePath: image.path).isEmpty { log("Önceki oturumdan kalan bağlantı motoru durduruldu.") }
        let admission: PeerAdmission
        do {
            admission = try PeerAdmission(approved: installation.approvedExecutables, readyTime: Date())
        } catch is PeerAdmission.ConfigurationError {
            throw KitError.discordUnverified(installation.bundle)
        }
        self.admission = admission
        log("DNS: " + settings.dns.description)
        let selected = try DnsSelection.select(settings.dns, open: { [log] provider, cancel in
            try DnsConnection.open(provider: provider, image: image, admission: admission, trace: log, cancel: cancel)
        }, log: log, cancel: lifetime)
        guard let connection = selected as? DnsConnection else {
            try selected.close()
            throw KitError.engineStartFailed()
        }
        self.connection = connection
        // The handlers hold the session weakly; the session holds the gate, the bridge and the watch.
        connection.onGateFault = { [weak self, weak connection] in
            if let connection { self?.backendFailed(connection) }
        }
        watch(connection)
        // A gate that failed before its handler was in place reported it to no one (design 9).
        guard connection.gate.isAccepting else { throw KitError.engineStopped() }
        let bridge = try UpdateBridge(proxyPort: connection.gate.port, admission: admission, log: log, faulted: { [weak self, weak connection] in
            if let connection { self?.backendFailed(connection) }
        })
        self.bridge = bridge
        bridge.start()
        try lifetime.check()
        guard try !system.running(installation) else { throw KitError.discordOpenedDuringPreparation() }
        let wrapper = try SessionWrapper(proxy: proxy(connection), hook: hook, downloadLog: DiscordProfile.downloadLog(root: settings.profile))
        let changes = try DiscordProfileChanges.prepare(profile: settings.profile, version: installation.version, state: settings.state, wrapper: wrapper)
        self.changes = changes
        try changes.configure(legacy: bridge.legacyEndpoint, modern: bridge.newEndpoint)
        guard connection.engine.isRunning, connection.gate.isAccepting else { throw KitError.engineStopped() }
    }

    private func proxy(_ connection: DnsConnection) -> String {
        "http://127.0.0.1:" + String(connection.gate.port)
    }

    /// The engine exiting ends the session (Windows `Engine.Exited`). An engine that exited before the watch began is
    /// reported as well: the process is gone by then, and Dispatch reports a process it cannot find as exited.
    private func watch(_ connection: DnsConnection) {
        let source = DispatchSource.makeProcessSource(identifier: connection.engine.pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self, weak connection] in
            if let connection { self?.backendFailed(connection) }
        }
        engineWatch = source
        source.resume()
    }

    /// Ends the session after its engine exited, or its gate or bridge closed itself (Windows `BackendFailed`): the gate
    /// and the engine stop at once, the rest as disconnecting does once no other operation runs.
    private func backendFailed(_ observed: DnsConnection) {
        DispatchQueue.global().async { [weak self] in
            observed.gate.close()
            observed.engine.stop()
            guard let self else { return }
            self.operations.lock()
            defer { self.operations.unlock() }
            guard self.connection === observed else { return }
            do {
                try self.disconnectCore()
            } catch {
                self.log(ConsoleSession.message(error))
            }
            self.changed(false, "Bağlantı motoru durdu; bağlantı kapatıldı.")
        }
    }

    /// Must be called with `operations` held. The profile changes stay (SES-E01) while Discord runs: one of its processes
    /// the gate admitted, or any process of a Discord.app within `exitWait`, or when the process list cannot be read.
    private func disconnectCore() throws {
        active = false
        lifetime.cancel()
        engineWatch?.cancel()
        engineWatch = nil
        var deferred = false
        if let changes, let installation {
            if admission?.anyAdmittedRunning == true || !waitForExit(installation) {
                deferred = true
            } else {
                do {
                    try changes.restore()
                    self.changes = nil
                } catch {
                    deferred = true
                    log("Discord ayarları geri alınamadı; kurtarma kaydı korundu.")
                }
            }
        }
        // A journal also stays when an earlier session's could not be undone (Windows `HasPendingRecovery`).
        if (try? DiscordProfileChanges.hasPendingRecovery(state: settings.state)) != false { deferred = true }
        bridge?.close()
        bridge = nil
        var failure: Error?
        if let connection {
            do {
                try connection.close()
            } catch {
                failure = error
            }
        }
        connection = nil
        admission?.close()
        admission = nil
        if deferred {
            if let failure { log(ConsoleSession.message(failure)) }
            throw KitError.sessionRestoreDeferred()
        }
        if let failure { throw failure }
    }

    /// Whether Discord is closed, or closes within `exitWait`; a process list that cannot be read counts as open.
    private func waitForExit(_ installation: DiscordInstallation) -> Bool {
        let deadline = Date().addingTimeInterval(Self.exitWait)
        while true {
            if (try? system.running(installation)) == false { return true }
            guard Date() < deadline else { return false }
            usleep(50_000)
        }
    }
}
