import CryptoKit
import Darwin
import Foundation

/// The pinned identity of the engine built by `macos/scripts/build-engine.py` (darwin/arm64, reproduced in stage 0).
public struct EngineIdentity: Equatable, Sendable {
    public let sha256: String
    public let cdhash: String

    /// Internal so that callers outside the package can only use `pinned`.
    init(sha256: String, cdhash: String) {
        self.sha256 = sha256
        self.cdhash = cdhash
    }

    public static let pinned = EngineIdentity(sha256: "013ba5d5055988953ebec1a1ac0eceb8aead52415e3ef186a5c7481083472cb0",
                                              cdhash: "344f8bd088ce068a1745cf16e7bb0c9a4bbbe99e")

    /// Code-signing requirement for the launched engine, checked before it runs (Windows leases the image instead).
    public var requirement: String { "cdhash H\"" + cdhash + "\"" }
}

/// An engine file whose real path was exactly `path` and whose bytes matched the expected SHA-256 when it was verified.
/// `identity.cdhash` is not measured here; `EngineProcess.start` enforces it on the launched process.
public struct EngineImage: Equatable, Sendable {
    public let path: String
    public let identity: EngineIdentity

    /// `path` must be absolute and spelled as the system reports it: no links, no `.` or `..` components and no
    /// repeated slashes. Any other spelling is reported as an unsafe path (PKG-E04).
    public static func verify(path: String) throws -> EngineImage {
        try verify(path: path, expected: .pinned)
    }

    static func verify(path: String, expected: EngineIdentity) throws -> EngineImage {
        // O_NONBLOCK keeps a FIFO at the path from blocking open; reads of a regular file ignore it.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw KitError.engineMissing(path)
            case ELOOP: throw KitError.engineUnsafePath(path)
            default: throw KitError.engineUnreadable(path)
            }
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw KitError.engineUnsafePath(path) }
        var realPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &realPath) == 0, String(cString: realPath) == path else { throw KitError.engineUnsafePath(path) }
        var hasher = SHA256()
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw KitError.engineUnreadable(path)
            }
            if count == 0 { break }
            chunk.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.sha256 else { throw KitError.engineIntegrity(path) }
        return EngineImage(path: path, identity: expected)
    }
}
