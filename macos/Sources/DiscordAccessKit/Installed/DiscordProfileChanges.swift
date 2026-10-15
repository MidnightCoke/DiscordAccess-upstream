import Foundation

/// The session's changes to Discord's profile (design 7.1 step 4 and 7.3; Windows `InstalledDiscord`): the session
/// wrapper over every core generation of the installed version, and Discord's two update settings pointed at the update
/// bridge. Every change is journaled before Discord's files are touched, in DiscordAccess's private state folder. Undoing
/// restores only what DiscordAccess still owns: a setting or entry that changed since (the user, or an official update)
/// is never overwritten; it is reported (PRF-E01) and the journal is kept. Discord must be closed meanwhile; callers
/// check `DiscordInstallation.runningProcesses()`.
///
/// The journal lives where macOS does not protect it the way it protects Discord's folder, so recovery trusts it
/// little: it acts only on the profile it is given, and it writes back only values an update setting may have, an
/// https address of Discord's own hosts.
public final class DiscordProfileChanges {
    public static let settingKeys = ["UPDATE_ENDPOINT", "NEW_UPDATE_ENDPOINT"]
    static let settingsLimit = 1_048_576
    /// The wrapper carries the hook (64 KiB at most).
    static let entryLimit = 131_072
    static let maxEntries = 16

    /// Discord's new updater uses numbered generations; the legacy Mac updater uses a flat core folder.
    /// These are templates, never paths taken from a recovery record.
    private enum Layout: String {
        case modern, legacy

        func modules(version: String) -> String {
            (self == .modern ? "app-" : "") + version + "/modules"
        }

        func entry(version: String, module: Int) -> String {
            modules(version: version) + (self == .modern
                ? "/discord_desktop_core-" + String(module) + "/discord_desktop_core/index.js"
                : "/discord_desktop_core/index.js")
        }
    }

    public let profile: String
    public let version: String
    private let state: String
    private let wrapperDigest: String
    private var journal: [String: Any]?

    private init(profile: String, version: String, state: String, wrapperDigest: String) {
        self.profile = profile
        self.version = version
        self.state = state
        self.wrapperDigest = wrapperDigest
    }

    /// Whether an earlier session left changes to undo (`recover`).
    public static func hasPendingRecovery(state: String) throws -> Bool {
        let journal = state + "/installed-session/journal.json"
        try SafeFile.requireNoLinks(journal)
        var status = stat()
        guard lstat(journal, &status) == 0 else {
            guard errno == ENOENT || errno == ENOTDIR else { throw SafeFile.failure(errno) }
            return false
        }
        return true
    }

    /// Journals, then writes `wrapper` over every core generation of `version` in the profile at `profile`: each
    /// `app-<version>/modules/discord_desktop_core-<N>/discord_desktop_core/index.js`, or the legacy
    /// `<version>/modules/discord_desktop_core/index.js`, must hold Discord's own entry, or a
    /// wrapper an earlier session left (its original is Discord's entry). A journal left by an earlier session must be
    /// recovered first. If a write fails, what was written is undone.
    public static func prepare(profile: String, version: String, state: String, wrapper: SessionWrapper) throws -> DiscordProfileChanges {
        guard validVersion(version) else { throw KitError.profileUnsupported() }
        try SafeFile.requireNoLinks(profile)
        // Neither folder may hold the other (Windows `Safety.Under`).
        guard !(profile + "/").hasPrefix(state + "/"), !(state + "/").hasPrefix(profile + "/") else { throw KitError.profileConflict() }
        _ = try StateStore.sessionDirectory(root: state, create: true)
        let changes = DiscordProfileChanges(profile: profile, version: version, state: state, wrapperDigest: SafeFile.sha256(wrapper.bytes))
        guard try SafeFile.read(changes.journalPath, limit: settingsLimit) == nil else { throw KitError.profileConflict() }
        let entries = try changes.entries()
        let official = Array((SessionWrapper.officialEntry + "\n").utf8)
        changes.journal = [
            "schema": 2, "profile": profile, "version": version, "wrapper": changes.wrapperDigest, "configured": false,
            "entries": entries.map { ["layout": $0.layout.rawValue, "module": $0.module,
                                      "original": Data(SessionWrapper.isOfficial($0.bytes) ? $0.bytes : official).base64EncodedString()] },
        ]
        try changes.saveJournal(expected: nil)
        do {
            for entry in entries {
                // A wrapper of another session is kept beside the entry, in case it was not quite one.
                try SafeFile.replace(changes.entryPath(entry.module, layout: entry.layout), expected: entry.bytes, with: wrapper.bytes, limit: entryLimit, mode: 0o644,
                                     keepDisplaced: !SessionWrapper.isOfficial(entry.bytes))
            }
        } catch {
            try? changes.restore()
            throw error
        }
        return changes
    }

    /// Points Discord's update settings at the update bridge (`UPDATE_ENDPOINT` to `legacy`, `NEW_UPDATE_ENDPOINT` to
    /// `modern`), after journaling their previous values. Other settings stay as they are. A previous value other than an
    /// https address of Discord's own hosts could not be written back, so it is refused before anything changes.
    /// Configuring again with the same values changes nothing; with other values it is refused.
    public func configure(legacy: String, modern: String) throws {
        let legacy = String(legacy.reversed().drop { $0 == "/" }.reversed())
        let modern = String(modern.reversed().drop { $0 == "/" }.reversed()) + "/"
        guard Self.validEndpoint(legacy), Self.validEndpoint(modern), let saved = journal else { throw KitError.profileConflict() }
        if Self.boolean(saved["configured"]) == true {
            guard saved["new_legacy"] as? String == legacy, saved["new_modern"] as? String == modern else { throw KitError.profileConflict() }
            return
        }
        let current = try SafeFile.read(settingsPath, limit: Self.settingsLimit)
        var settings = try current.map(Self.object) ?? [:]
        guard Self.settingKeys.allSatisfy({ settings[$0].map(Self.restorable) ?? true }) else { throw KitError.profileConflict() }
        let previous = try SafeFile.read(journalPath, limit: Self.settingsLimit)
        var updated = saved
        updated["configured"] = true
        updated["new_legacy"] = legacy
        updated["new_modern"] = modern
        for (index, key) in Self.settingKeys.enumerated() {
            updated["had_" + String(index)] = settings[key] != nil
            if let old = settings[key] { updated["old_" + String(index)] = old }
        }
        journal = updated
        do {
            try saveJournal(expected: previous)
            settings[Self.settingKeys[0]] = legacy
            settings[Self.settingKeys[1]] = modern
            try SafeFile.replace(settingsPath, expected: current, with: Self.json(settings), limit: Self.settingsLimit, mode: 0o644)
        } catch {
            // Configuring again must not take a failed attempt for a done one.
            journal = saved
            throw error
        }
    }

    /// Undoes what DiscordAccess still owns, then removes the journal. A setting the user changed since, or an entry an
    /// update replaced with something other than Discord's own entry, is left as it is; every other part is still
    /// restored, and PRF-E01 reports it with the journal kept. An entry an update removed or reset to Discord's own entry
    /// is fine; one holding a wrapper of another session is taken back as well.
    public func restore() throws {
        _ = try StateStore.sessionDirectory(root: state, create: false)
        guard let saved = try SafeFile.read(journalPath, limit: Self.settingsLimit) else {
            journal = nil
            return
        }
        let journal = try Self.validate(saved, profile: profile, version: version, wrapper: wrapperDigest)
        var conflict = false
        if Self.boolean(journal["configured"]) == true {
            do {
                conflict = try restoreSettings(journal) || conflict
            } catch let error as KitError where error == KitError.profileAccessDenied() {
                throw error
            } catch {
                conflict = true
            }
        }
        for record in journal["entries"] as! [[String: Any]] {
            let layout = Self.integer(journal["schema"]) == 1 ? Layout.modern : Layout(rawValue: record["layout"] as! String)!
            let path = entryPath(Self.integer(record["module"])!, layout: layout)
            let original = [UInt8](Data(base64Encoded: record["original"] as! String)!)
            do {
                guard let current = try SafeFile.read(path, limit: Self.entryLimit) else { continue }
                if SafeFile.sha256(current) == wrapperDigest || SessionWrapper.isWrapper(current) {
                    try SafeFile.replace(path, expected: current, with: original, limit: Self.entryLimit, mode: 0o644,
                                         keepDisplaced: SafeFile.sha256(current) != wrapperDigest)
                } else if !SessionWrapper.isOfficial(current) {
                    conflict = true
                }
            } catch let error as KitError where error == KitError.profileAccessDenied() {
                throw error
            } catch {
                conflict = true
            }
        }
        guard !conflict else { throw KitError.profileConflict() }
        try SafeFile.delete(journalPath, expected: saved, limit: Self.settingsLimit)
        self.journal = nil
    }

    /// Undoes an earlier session's changes from its journal (at start, or `--restore`). Only a journal of `profile`, the
    /// standard Discord folder unless tests give another, is acted on; false when there is none.
    public static func recover(state: String, profile: String = DiscordProfile.standardRoot) throws -> Bool {
        guard try hasPendingRecovery(state: state) else { return false }
        let session = try StateStore.sessionDirectory(root: state, create: false)
        guard let saved = try SafeFile.read(session + "/journal.json", limit: settingsLimit) else { return false }
        let journal = try validate(saved, profile: profile, version: nil, wrapper: nil)
        let changes = DiscordProfileChanges(profile: profile, version: journal["version"] as! String, state: state,
                                            wrapperDigest: journal["wrapper"] as! String)
        try changes.restore()
        return true
    }

    /// Restores the two settings DiscordAccess still owns; true when one changed since and was left.
    private func restoreSettings(_ journal: [String: Any]) throws -> Bool {
        let current = try SafeFile.read(settingsPath, limit: Self.settingsLimit)
        var settings = try current.map(Self.object) ?? [:]
        var conflict = false
        var changed = false
        for (index, key) in Self.settingKeys.enumerated() {
            let had = Self.boolean(journal["had_" + String(index)]) == true
            let old = journal["old_" + String(index)]
            let value = settings[key]
            if (value != nil) == had && (!had || Self.same(value!, old!)) { continue }
            guard let value, value as? String == journal[index == 0 ? "new_legacy" : "new_modern"] as? String else {
                conflict = true
                continue
            }
            settings[key] = had ? old : nil
            changed = true
        }
        if changed { try SafeFile.replace(settingsPath, expected: current, with: Self.json(settings), limit: Self.settingsLimit, mode: 0o644) }
        return conflict
    }

    var settingsPath: String { profile + "/settings.json" }

    private var journalPath: String { state + "/installed-session/journal.json" }

    private func entryPath(_ module: Int, layout: Layout) -> String {
        profile + "/" + layout.entry(version: version, module: module)
    }

    /// Every core generation of the version, with its entry's bytes: an entry beside its `core.asar`, holding Discord's
    /// own entry or a wrapper. A folder named like a generation but otherwise is not recognized (PRF-E02).
    private func entries() throws -> [(layout: Layout, module: Int, bytes: [UInt8])] {
        var result: [(layout: Layout, module: Int, bytes: [UInt8])] = []
        // Check only the installed host version. An older version is never a fallback for a missing current core.
        // During an updater transition both layouts may exist; both must be validated before either is changed.
        for layout in [Layout.modern, .legacy] {
            let modules = profile + "/" + layout.modules(version: version)
            try SafeFile.requireNoLinks(modules)
            var status = stat()
            guard lstat(modules, &status) == 0 else {
                if errno == ENOENT { continue }
                throw SafeFile.failure(errno)
            }
            guard status.st_mode & S_IFMT == S_IFDIR else { throw KitError.profileUnsupported() }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: modules)
            } catch {
                throw KitError.profileAccessDenied()
            }
            let cores = names.sorted().filter {
                layout == .modern ? $0.hasPrefix("discord_desktop_core-") : $0 == "discord_desktop_core"
            }
            for name in cores {
                let number = layout == .legacy ? 0 : Self.moduleNumber(name)
                guard let module = number, result.count < Self.maxEntries else { throw KitError.profileUnsupported() }
                let entry = entryPath(module, layout: layout)
                let folder = (entry as NSString).deletingLastPathComponent
                try SafeFile.requireNoLinks(folder + "/core.asar")
                for directory in [modules + "/" + name, folder] {
                    guard lstat(directory, &status) == 0 else {
                        if errno == ENOENT { throw KitError.profileMissingModule() }
                        throw SafeFile.failure(errno)
                    }
                    guard status.st_mode & S_IFMT == S_IFDIR else { throw KitError.profileUnsupported() }
                }
                guard let bytes = try SafeFile.read(entry, limit: Self.entryLimit) else { throw KitError.profileMissingModule() }
                guard lstat(folder + "/core.asar", &status) == 0 else {
                    if errno == ENOENT { throw KitError.profileMissingModule() }
                    throw SafeFile.failure(errno)
                }
                guard status.st_mode & S_IFMT == S_IFREG else { throw KitError.profileUnsupported() }
                guard SessionWrapper.isOfficial(bytes) || SessionWrapper.isWrapper(bytes) else { throw KitError.profileUnsupported() }
                result.append((layout, module, bytes))
            }
        }
        guard !result.isEmpty else { throw KitError.profileMissingModule() }
        return result
    }

    private func saveJournal(expected: [UInt8]?) throws {
        _ = try StateStore.sessionDirectory(root: state, create: false)
        try SafeFile.replace(journalPath, expected: expected, with: Self.json(journal ?? [:]), limit: Self.settingsLimit, mode: 0o600)
    }

    /// The journal's fields, all of them checked (Windows `ValidateJournal`): only known keys, the profile, version and
    /// wrapper of this session when given, 1-16 distinct core generations whose originals are Discord's own entry, and
    /// the bridge endpoints and previous values once configured.
    private static func validate(_ bytes: [UInt8], profile: String?, version: String?, wrapper: String?) throws -> [String: Any] {
        let journal = try object(bytes)
        guard let schema = integer(journal["schema"]), schema == 1 || schema == 2,
              let savedProfile = journal["profile"] as? String, profile == nil || savedProfile == profile,
              (try? SafeFile.requireNoLinks(savedProfile)) != nil, let savedVersion = journal["version"] as? String, validVersion(savedVersion),
              version == nil || savedVersion == version, let digest = journal["wrapper"] as? String, digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }), wrapper == nil || digest == wrapper,
              let entries = journal["entries"] as? [[String: Any]], (1...maxEntries).contains(entries.count),
              let configured = boolean(journal["configured"]) else { throw KitError.profileConflict() }
        var modules = Set<String>()
        for record in entries {
            let layout: Layout? = schema == 1 ? .modern : (record["layout"] as? String).flatMap { Layout(rawValue: $0) }
            guard let layout, Set(record.keys) == (schema == 1 ? ["module", "original"] : ["layout", "module", "original"]),
                  let module = integer(record["module"]),
                  (layout == .legacy ? module == 0 : (1...Int(Int32.max)).contains(module)),
                  modules.insert(layout.rawValue + ":" + String(module)).inserted,
                  let original = record["original"] as? String, let data = Data(base64Encoded: original), data.count <= entryLimit,
                  SessionWrapper.isOfficial([UInt8](data)) else { throw KitError.profileConflict() }
        }
        var allowed: Set<String> = ["schema", "profile", "version", "wrapper", "entries", "configured"]
        if configured {
            for key in ["new_legacy", "new_modern"] {
                guard let value = journal[key] as? String, validEndpoint(value) else { throw KitError.profileConflict() }
                allowed.insert(key)
            }
            for index in settingKeys.indices {
                guard let had = boolean(journal["had_" + String(index)]) else { throw KitError.profileConflict() }
                allowed.insert("had_" + String(index))
                if had {
                    guard let old = journal["old_" + String(index)], restorable(old) else { throw KitError.profileConflict() }
                    allowed.insert("old_" + String(index))
                }
            }
        }
        guard Set(journal.keys).isSubset(of: allowed) else { throw KitError.profileConflict() }
        return journal
    }

    /// A value DiscordAccess may write back into an update setting: an https address of Discord's own hosts.
    static func restorable(_ value: Any) -> Bool {
        guard let text = value as? String else { return false }
        return BridgeRequest.allowedURL(text) != nil
    }

    /// `<major>.<minor>.<patch>`, as Discord names its host versions.
    static func validVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { (1...9).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// A bridge endpoint (Windows `ValidateEndpoint`): `http://127.0.0.1:<port>/` and a path of letters, digits, `/`, `_`
    /// and `-`, at most 512 characters.
    static func validEndpoint(_ value: String) -> Bool {
        let prefix = "http://127.0.0.1:"
        guard value.utf8.count <= 512, value.hasPrefix(prefix) else { return false }
        let rest = value.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), let port = Int(rest[..<slash]), (1...65535).contains(port), rest[..<slash].count <= 5 else { return false }
        let path = rest[rest.index(after: slash)...]
        return !path.isEmpty && path.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/_-".unicodeScalars.contains($0)) }
    }

    private static func moduleNumber(_ name: String) -> Int? {
        let digits = name.dropFirst("discord_desktop_core-".count)
        guard (1...10).contains(digits.count), digits.first != "0", digits.allSatisfy({ $0.isASCII && $0.isNumber }), let module = Int(digits),
              module <= Int(Int32.max) else { return nil }
        return module
    }

    /// A JSON object from UTF-8 bytes; a leading byte order mark is dropped (Windows).
    private static func object(_ bytes: [UInt8]) throws -> [String: Any] {
        guard let text = String(bytes: bytes, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(String(text.unicodeScalars.drop { $0 == "\u{FEFF}" }).utf8)) as? [String: Any] else {
            throw KitError.profileConflict()
        }
        return object
    }

    private static func json(_ value: Any) throws -> [UInt8] {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              data.count <= settingsLimit else { throw KitError.profileConflict() }
        return [UInt8](data) + [10]
    }

    /// Two JSON values that serialize alike, keys sorted.
    private static func same(_ left: Any, _ right: Any) -> Bool {
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        guard let one = try? JSONSerialization.data(withJSONObject: left, options: options),
              let other = try? JSONSerialization.data(withJSONObject: right, options: options) else { return false }
        return one == other
    }

    /// A JSON Boolean only: an integer 1 is not true here.
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A JSON integer only: not a Boolean, without a fraction.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return nil }
        return number.intValue
    }
}
