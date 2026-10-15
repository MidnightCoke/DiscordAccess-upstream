import Darwin
import Foundation

/// A fixed, user-facing reason an attachment download failed (Windows `AttachmentDownloadException`); it never holds the
/// link, a header or an error message.
public struct AttachmentDownloadFailure: Error, Equatable, CustomStringConvertible {
    public let message: String

    public var description: String { message }
}

/// Downloads a Discord attachment from the terminal through the session's gate (Windows `AttachmentDownloader` and
/// `ConsoleDownload`): only an https link of Discord's attachment hosts, at most three redirects to such links, 15 minutes
/// in all and 30 seconds without data. The file goes into a new folder under `~/Downloads/DiscordAccess`, written beside
/// its final name and moved there only when complete, marked as downloaded from the internet (quarantine). The signed
/// link never reaches a log or the file name.
public enum AttachmentDownloader {
    static let totalTimeout: TimeInterval = 900
    static let idleTimeout: TimeInterval = 30
    static let maxRedirects = 3
    static let maxNameLength = 160
    /// macOS's limit for one file name (`NAME_MAX`), in UTF-8 bytes.
    static let maxNameBytes = 255
    static let hosts = ["cdn.discordapp.com", "media.discordapp.net"]
    static let invalidLink = "Only the HTTPS link of a Discord attachment is accepted. Copy the link in Discord and paste it again."

    /// `~/Downloads/DiscordAccess`.
    public static var standardRoot: String { DiscordProfile.home() + "/Downloads/DiscordAccess" }

    /// The attachment link, checked as Windows checks it: Discord's attachment hosts on port 443,
    /// `/attachments/<id>/<id>/<name>` (or `ephemeral-attachments`), no user information, fragment, white space,
    /// backslash or encoded separator in the name.
    public static func validate(_ link: String) throws -> URL {
        let failure = AttachmentDownloadFailure(message: invalidLink)
        let bytes = Array(link.utf8)
        guard (1...8192).contains(bytes.count), bytes.allSatisfy({ $0 > 32 && $0 != 127 && $0 != 92 }) else { throw failure }
        let lowered = link.lowercased()
        guard hosts.contains(where: { lowered.hasPrefix("https://" + $0 + "/") || lowered.hasPrefix("https://" + $0 + ":443/") }),
              let components = URLComponents(string: link), components.scheme?.lowercased() == "https", components.port == nil || components.port == 443,
              components.user == nil, components.password == nil, components.fragment == nil, let host = components.host?.lowercased(),
              // The link goes out exactly as written: its signed query must not change.
              hosts.contains(host), let url = URL(string: link), url.absoluteString == link else { throw failure }
        // The path as written, before any normalization of dot segments.
        let afterScheme = link.dropFirst("https://".count)
        guard let slash = afterScheme.firstIndex(of: "/") else { throw failure }
        let path = afterScheme[slash...].prefix { $0 != "?" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "attachments" || parts[1] == "ephemeral-attachments",
              parts[2...3].allSatisfy({ (1...22).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } }), !parts[4].isEmpty,
              !hasBrokenEscape(parts[4]), let name = String(parts[4]).removingPercentEncoding, name != ".", name != "..",
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == "\\" }),
              !["%2f", "%5c", "%00", "%0a", "%0d"].contains(where: { name.lowercased().contains($0) }) else { throw failure }
        return url
    }

    /// The file name an attachment link suggests, safe as a file name here (Windows `SuggestedName`): characters that
    /// paths or other systems treat specially become `_`, a leading dot too (the file would be hidden), and at most 160
    /// characters remain, within macOS's 255 bytes.
    static func suggestedName(_ url: URL) -> String {
        var name = (url.path as NSString).lastPathComponent
        name = String(name.unicodeScalars.map { scalar -> Character in
            scalar.value < 32 || scalar.value == 127 || "<>:\"/\\|?*".unicodeScalars.contains(scalar) ? "_" : Character(scalar)
        })
        name = trimmed(name.trimmingCharacters(in: .whitespaces))
        if name.count > maxNameLength { name = trimmed(String(name.prefix(maxNameLength))) }
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return fitted(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Discord-file" : name)
    }

    /// A name over 255 bytes keeps its extension (20 bytes at most) and starts with `_`, as Windows marks a name it
    /// shortened to fit its paths (`ConsoleDownload.PrepareDestination`).
    private static func fitted(_ name: String) -> String {
        guard name.utf8.count > maxNameBytes else { return name }
        var suffix = name.lastIndex(of: ".").map { String(name[$0...]) } ?? ""
        if suffix.utf8.count > 20 { suffix = "" }
        var stem = String(name.dropLast(suffix.count))
        while !stem.isEmpty && ("_" + stem + suffix).utf8.count > maxNameBytes { stem.removeLast() }
        stem = trimmed(stem)
        return stem.isEmpty ? "Discord-file" + suffix : "_" + stem + suffix
    }

    /// Downloads the attachment of `link` into a new folder under `root` and returns the saved file's path. Throws
    /// `AttachmentDownloadFailure`, or `CancellationError` once `cancel` is canceled.
    public static func download(_ link: String, root: String = standardRoot, proxyPort: UInt16, cancel: Cancellation, now: Date = Date()) throws -> String {
        try download(link, root: root, proxyPort: proxyPort, cancel: cancel, now: now, protocolClasses: nil)
    }

    /// `protocolClasses` lets tests stand in for Discord's servers.
    static func download(_ link: String, root: String, proxyPort: UInt16, cancel: Cancellation, now: Date, protocolClasses: [AnyClass]?) throws -> String {
        var current = try validate(link)
        guard proxyPort > 0 else { throw AttachmentDownloadFailure(message: "Start the DiscordAccess connection first.") }
        let destination = try prepareDestination(for: current, root: root, now: now)
        let folder = (destination as NSString).deletingLastPathComponent
        let deadline = Date().addingTimeInterval(totalTimeout)
        var redirects = 0
        do {
            while true {
                try cancel.check()
                let transfer = try Transfer(directory: folder)
                let outcome = transfer.run(current, proxyPort: proxyPort, cancel: cancel, deadline: deadline, protocolClasses: protocolClasses)
                guard !cancel.isCanceled else {
                    transfer.discard()
                    throw CancellationError()
                }
                switch outcome {
                case .redirect(let location):
                    guard redirects < maxRedirects else { throw AttachmentDownloadFailure(message: "The download server returned too many redirects.") }
                    redirects += 1
                    guard let location, (1...8192).contains(location.utf8.count), location.utf8.allSatisfy({ $0 > 32 && $0 != 127 && $0 != 92 }),
                          let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                        throw AttachmentDownloadFailure(message: "The download redirect could not be verified.")
                    }
                    current = try validate(next.absoluteString)
                case .saved(let temporary):
                    return try finish(temporary, at: destination, now: now)
                case .failed(let failure):
                    transfer.discard()
                    throw failure
                }
            }
        } catch {
            // The folder of a download that did not complete is removed if it stayed empty.
            rmdir(folder)
            throw error
        }
    }

    /// A Retry-After value as whole seconds, when it is a small number or an HTTP date in the next day; never shown as
    /// it came (Windows `RetryAfterSeconds`).
    static func retryAfterSeconds(_ value: String?, now: Date) -> Int? {
        guard let value, value.utf8.count <= 128 else { return nil }
        let text = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        let seconds: Double
        if text.range(of: #"\A[0-9]+(\.[0-9]+)?\z"#, options: .regularExpression) != nil, let number = Double(text) {
            seconds = number
        } else {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(identifier: "GMT")
            format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            guard let date = format.date(from: text) else { return nil }
            seconds = date.timeIntervalSince(now)
        }
        guard seconds.isFinite, seconds > 0, seconds <= 86400 else { return nil }
        return Int(seconds.rounded(.up))
    }

    static func rateLimitMessage(_ retryAfter: String?) -> String {
        let wait = retryAfterSeconds(retryAfter, now: Date()).map { "Wait about " + String($0) + " seconds and try again." } ??
            "Wait a while and try again."
        return "The download server is rate limiting requests (HTTP 429). " + wait + " No automatic retry was made."
    }

    /// A new folder `<yyyyMMdd-HHmmss>-<id>` under `root` and the file's path in it; no link anywhere on the way.
    static func prepareDestination(for url: URL, root: String, now: Date) throws -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        let folder = root + "/" + format.string(from: now) + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard (try? SafeFile.requireNoLinks(folder)) != nil else {
            throw AttachmentDownloadFailure(message: "A redirected file path cannot be used in the download folder.")
        }
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            guard mkdir(folder, 0o755) == 0 else { throw AttachmentDownloadFailure(message: "The download folder could not be verified.") }
        } catch let failure as AttachmentDownloadFailure {
            throw failure
        } catch {
            throw AttachmentDownloadFailure(message: "The download folder could not be created. Check access to the Downloads folder.")
        }
        guard (try? SafeFile.requireNoLinks(folder)) != nil else { throw AttachmentDownloadFailure(message: "The download folder could not be verified.") }
        return folder + "/" + suggestedName(url)
    }

    /// Marks the complete file as downloaded from the internet and moves it to its name, which must still be free.
    private static func finish(_ temporary: String, at destination: String, now: Date) throws -> String {
        let quarantine = "0081;" + String(Int(now.timeIntervalSince1970), radix: 16) + ";DiscordAccess;"
        guard setxattr(temporary, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, XATTR_NOFOLLOW) == 0,
              renamex_np(temporary, destination, UInt32(RENAME_EXCL)) == 0 else {
            unlink(temporary)
            throw AttachmentDownloadFailure(message: "The file could not be saved. Check access to the Downloads folder.")
        }
        return destination
    }

    private static func trimmed(_ name: String) -> String {
        String(name.reversed().drop { $0 == "." || $0 == " " }.reversed())
    }

    /// A `%` that does not start two hex digits.
    private static func hasBrokenEscape(_ text: Substring) -> Bool {
        let bytes = Array(text.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count, bytes[(index + 1)...(index + 2)].allSatisfy({ isHex($0) }) else { return true }
        }
        return false
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
    }
}

/// One request of a download; a 200 answer streams into a new hidden file beside the destination.
private final class Transfer: NSObject, URLSessionDataDelegate {
    enum Outcome {
        case redirect(String?)
        case saved(String)
        case failed(AttachmentDownloadFailure)
    }

    let done = DispatchSemaphore(value: 0)
    private let temporary: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var status = 0
    private var expected: Int64 = -1
    private var received: Int64 = 0
    private var location: String?
    private var retryAfter: String?
    private var failure: AttachmentDownloadFailure?
    private var error: Error?

    init(directory: String) throws {
        temporary = directory + "/.DiscordAccess-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".part"
    }

    func run(_ url: URL, proxyPort: UInt16, cancel: Cancellation, deadline: Date, protocolClasses: [AnyClass]?) -> Outcome {
        let configuration = ConnectivityProbe.configuration(proxyPort: proxyPort, deadline: AttachmentDownloader.idleTimeout)
        configuration.timeoutIntervalForRequest = AttachmentDownloader.idleTimeout
        configuration.timeoutIntervalForResource = AttachmentDownloader.totalTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("DiscordAccess/3 (attachment download)", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        // The exact bytes of the file, as Windows asks for them.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        let unregister = cancel.whenCanceled { task.cancel() }
        defer { unregister() }
        task.resume()
        if done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
            task.cancel()
            _ = done.wait(timeout: .now() + 5)
            close()
            return .failed(Self.generic)
        }
        close()
        lock.lock()
        defer { lock.unlock() }
        if let failure { return .failed(failure) }
        if [301, 302, 303, 307, 308].contains(status) { return .redirect(location) }
        if status == 429 { return .failed(AttachmentDownloadFailure(message: AttachmentDownloader.rateLimitMessage(retryAfter))) }
        if error != nil || status == 0 { return .failed(Self.generic) }
        if status != 200 {
            return .failed(AttachmentDownloadFailure(message: "The file could not be downloaded (HTTP " + String(status) + "). Copy a new file link from Discord."))
        }
        if expected >= 0 && received != expected { return .failed(AttachmentDownloadFailure(message: "The file arrived incomplete. The download did not finish.")) }
        return .saved(temporary)
    }

    /// Removes the hidden file of this request, if it made one.
    func discard() {
        unlink(temporary)
    }

    static let generic = AttachmentDownloadFailure(message: "The file could not be downloaded. The connection or disk access may have been lost, or the " +
        "time ran out. Copy a new link from Discord and try again.")

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(ConnectivityProbe.answer(challenge), nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            record(AttachmentDownloadFailure(message: "The download response could not be verified."))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        status = http.statusCode
        expected = http.expectedContentLength
        location = http.value(forHTTPHeaderField: "Location")
        retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        lock.unlock()
        guard status == 200 else {
            completionHandler(.cancel)
            return
        }
        let file = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else {
            record(AttachmentDownloadFailure(message: "The file could not be saved. Check access to the Downloads folder."))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        descriptor = file
        lock.unlock()
        completionHandler(.allow)
    }

    /// The descriptor stays locked while it is written: `close()` cannot close it, and its number cannot go to another
    /// file, under a write that is still running.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let file = descriptor
        guard file >= 0, failure == nil else {
            lock.unlock()
            return
        }
        guard expected < 0 || received + Int64(data.count) <= expected else {
            lock.unlock()
            record(AttachmentDownloadFailure(message: "The file size did not match the server's response. The download did not finish."))
            dataTask.cancel()
            return
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(file, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        if written { received += Int64(data.count) }
        lock.unlock()
        guard written else {
            record(AttachmentDownloadFailure(message: "The file could not be saved. Check access to the Downloads folder."))
            dataTask.cancel()
            return
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        // A canceled request after its answer (a redirect or an error status) completed what was needed.
        if let error, !((error as NSError).code == NSURLErrorCancelled && status != 0 && status != 200) { self.error = error }
        lock.unlock()
        done.signal()
    }

    private func record(_ failure: AttachmentDownloadFailure) {
        lock.lock()
        if self.failure == nil { self.failure = failure }
        lock.unlock()
    }

    private func close() {
        lock.lock()
        let file = descriptor
        descriptor = -1
        lock.unlock()
        if file >= 0 {
            _ = fsync(file)
            Darwin.close(file)
        }
    }
}
