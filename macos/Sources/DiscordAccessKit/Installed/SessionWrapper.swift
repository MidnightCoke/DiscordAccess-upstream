import Darwin
import Foundation

/// The session wrapper written over Discord's core entry (design 7.2). In Discord's main process it applies the
/// session's proxy when Discord was opened without it (Dock, Launchpad, Spotlight) and holds every page load until the
/// proxy is in place; it installs the attachment download hook, embedded so that Discord never reads a file of
/// DiscordAccess; then it loads Discord's own core. Any failure leaves Discord as it was without DiscordAccess, and the
/// `direct://` fallback keeps Discord working if the gate is gone.
public struct SessionWrapper: Equatable, Sendable {
    static let marker = "// DiscordAccess macOS session wrapper v1\n"
    static let officialEntry = "module.exports = require('./core.asar');"
    /// SHA-256 of `bridge/attachment-download.cjs`, the hook both platforms share.
    static let hookSHA256 = "a8f3e76feb620871f777437d0e2c0b9aa7afa0742d6e225aaa62fba74d8ab979"
    static let maxHookBytes = 65536

    let bytes: [UInt8]

    /// `proxy` is the gate (`http://127.0.0.1:<port>`) and `downloadLog` an absolute path for the hook's records (PRF-E01
    /// otherwise); `hook` must be the shared hook (PKG-E05 otherwise). The proxy step and the hook each fail on their own,
    /// page loads wait for the proxy ten seconds at most, and the hook sees none of Discord's environment, so only the
    /// wrapper's settings apply to it.
    public init(proxy: String, hook: [UInt8], downloadLog: String) throws {
        guard hook.count <= Self.maxHookBytes, SafeFile.sha256(hook) == Self.hookSHA256, let source = String(bytes: hook, encoding: .utf8) else {
            throw KitError.hookIntegrity()
        }
        guard Self.validProxy(proxy), downloadLog.hasPrefix("/"), !downloadLog.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw KitError.profileConflict()
        }
        let text = Self.marker + """
        if (process.type === 'browser') {
          let electron = null;
          try { electron = require('electron'); } catch (_) {}
          if (electron) {
            try {
              const proxy = \(Self.literal(proxy));
              if (electron.app.commandLine.getSwitchValue('proxy-server') !== proxy) {
                const ready = Promise.race([
                  electron.session.defaultSession.setProxy({ proxyRules: proxy + ',direct://', proxyBypassRules: '127.0.0.1;localhost' }),
                  new Promise((resolve) => setTimeout(resolve, 10000)),
                ]);
                electron.app.on('web-contents-created', (_event, contents) => {
                  const load = contents.loadURL;
                  contents.loadURL = function (...args) {
                    return ready.then(() => load.apply(this, args), () => load.apply(this, args));
                  };
                });
              }
            } catch (_) {}
            try {
              const hook = { exports: {} };
              (function (module, exports, process) {

        """ + source + """

              })(hook, hook.exports, { type: process.type, env: {} });
              hook.exports.install(electron, { env: { DISCORDACCESS_ATTACHMENTS: '1', DISCORDACCESS_DOWNLOAD_LOG: \(Self.literal(downloadLog)) } });
            } catch (_) {}
          }
        }

        """ + Self.officialEntry + "\n"
        bytes = Array(text.utf8)
    }

    /// The shared hook at `path`, read without following a link at its end: PKG-E01 when it is missing, PKG-E05 when it
    /// is not the pinned hook. Only its digest is trusted, so whoever owns the file does not matter.
    public static func loadHook(path: String) throws -> [UInt8] {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw KitError.engineMissing(path) }
            throw KitError.hookIntegrity()
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size <= off_t(maxHookBytes) else {
            throw KitError.hookIntegrity()
        }
        var bytes = [UInt8](repeating: 0, count: maxHookBytes + 1)
        var count = 0
        while count < bytes.count {
            let result = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + count, $0.count - count) }
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw KitError.hookIntegrity() }
            if result == 0 { break }
            count += result
        }
        let hook = Array(bytes[..<count])
        guard SafeFile.sha256(hook) == hookSHA256 else { throw KitError.hookIntegrity() }
        return hook
    }

    /// Discord's own entry (Windows `InstalledDiscord.Original`): UTF-8, at most 16 KiB.
    static func isOfficial(_ bytes: [UInt8]) -> Bool {
        guard bytes.count <= 16384, var text = String(bytes: bytes, encoding: .utf8) else { return false }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let pattern = #"\Amodule\.exports\s*=\s*require\(\s*(['"])\./core\.asar\1\s*\);?\z"#
        return text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: pattern, options: .regularExpression) != nil
    }

    /// A wrapper of some session: it starts with the marker and ends with Discord's own entry.
    static func isWrapper(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: Array(marker.utf8)) && bytes.reversed().starts(with: Array((officialEntry + "\n").utf8).reversed())
    }

    /// `http://127.0.0.1:<1-65535>`, exactly (Windows `ValidateProxy`).
    static func validProxy(_ value: String) -> Bool {
        let prefix = "http://127.0.0.1:"
        guard value.hasPrefix(prefix), let port = Int(value.dropFirst(prefix.count)), (1...65535).contains(port) else { return false }
        return value == prefix + String(port)
    }

    /// A JavaScript string literal (a JSON string).
    private static func literal(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}
