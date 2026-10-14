# Aşama 1a — Swift Paketi ve Motor Katmanı Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Hedef:** `macos/` altında `DiscordAccessKit` Swift paketini kurmak. Paket, motor katmanının Windows'taki karşılığını kapsar:

- motor yapılandırması (`Package.Config`)
- motor dosyası doğrulaması (`TrustedImage`)
- motor süreci (`DnsConnection`)
- dinleyici sahipliği (`TcpOwner.OwnsListener`)
- yetim motor temizliği

Ayrıca derleme betiğine Aşama 0'da doğrulanan motor sabitleri eklenir.

**Mimari:**
- `DiscordAccessKit` arayüzsüz, test edilebilir bir kütüphanedir.
- Motor yapılandırması bellekte üretilir ve Aşama 0'ın bağımsız Python üreticisinin çıktısıyla karşılaştırılır.
- Motor dosyası SHA-256 ile doğrulanır.
- Motor askıda başlatılır ve Security.framework ile `cdhash` gereksinimini karşılamadan çalışmaz. Dinleyici sahipliği libproc ile doğrulanır. Windows'taki dosya kiralamasının yerini bu alır.
- Gerçek motorla yapılan testler, motor `macos/build/engine/sing-box` yolunda yoksa atlanır.

**Teknolojiler:** Swift 6.4 (Swift 5 dil modu), SwiftPM, Swift Testing, Darwin libproc, Security.framework, CryptoKit, Python 3.12 (derleme betiği).

---

## Aşama 1 alt planları

Tasarımın (`macos/docs/2026-10-14-macos-tasarim.md`) Aşama 1'i, her biri kendi başına çalışan ve test edilen alt planlara bölünür. Bu belge yalnız **1a**'yı uygular.

| Alt plan | Kapsam |
| --- | --- |
| **1a** | Paket iskeleti, motor yapılandırması, motor doğrulama ve başlatma, yetim motor temizliği, derleme betiği sabitleri |
| 1b | Kapı istek politikası (Windows `RewriteHeader`) ve eş kimliği (libproc ile soketten sürece, Team ID imzası) |
| 1c | Kapının ağ katmanı (dinleme, aktarım, motor kimliği) |
| 1d | Bağlantı tanısı (Gateway HELLO) ve otomatik DNS seçimi |
| 1e | Güncelleme köprüsü (manifest ve yönlendirme yeniden yazma, indirmeler) |
| 1f | Discord kurulumu ve profil değişiklikleri: günlük, tüm çekirdek nesilleri, gömülü kanca, Tam Disk Erişimi |
| 1g | Terminal modu (Q/T/D/A) ile uçtan uca birleştirme |

## Yürütme notları

- Tüm komutlar depo kökünden (`/Users/alpertekin/Documents/GitHub/DiscordAccess`), `feature/macos` dalında çalıştırılır.
- `macos/` dışında hiçbir dosya değişmez.
- Commit yalnız kullanıcının açık isteğiyle yapılır. Kontrol noktaları Git durumunu doğrular.
- SwiftPM derleme çıktısı `macos/.build/` altındadır ve `macos/.gitignore` ile Git dışında kalır.
- Bütün macOS testleri `macos/Tests/` altındadır: Swift test hedefleri alt klasörlerde, betik testleri (`*.test.py`, `*.test.cjs`) doğrudan bu klasörde. Ayrı bir küçük harfli `tests/` klasörü açılmaz: macOS'un varsayılan diski büyük/küçük harf ayırmaz, `tests/` ile `Tests/` aynı klasör olur ve Git yolları karışır.
- Gerçek motor testleri `macos/build/engine/sing-box` dosyasını kullanır (Aşama 0'da derlendi). Dosya yoksa bu testler atlanır; diğer testler çalışır. Atlama son satırdaki "passed" sonucunu değiştirmediği için her doğrulamada çıktıda `skipped` geçmediği ayrıca denetlenir.
- Kod blokları geçici klasörde derlenip testleri geçmiş dosyalardır. Elle yeniden yazılmaz. Plandan çıkarılıp aşağıdaki hash'lerle doğrulanır.
- Swift'te ilk "kırmızı" durum derleme hatasıdır. Test dosyası yazıldığında henüz var olmayan türler için `cannot find '…' in scope` beklenir.

## Dosya yapısı

| Dosya | Sorumluluk | SHA-256 |
| --- | --- | --- |
| `macos/Package.swift` | SwiftPM paketi: `DiscordAccessKit` kütüphanesi ve test hedefi | `0ffc590aaa2bb6537178f120ef076dd63939d7469f0842de2985c6da3bada551` |
| `macos/Sources/DiscordAccessKit/KitError.swift` | Kullanıcıya gösterilen hatalar (`PKG-E01…04`, `ENG-E01`, `SYS-E01`) | `c930e4cf21983b1a3c0f3eaab466aa8c17f20c1290c969913f97943d728b3b51` |
| `macos/Sources/DiscordAccessKit/DiscordDestinations.swift` | Windows `ProcessGate` ile aynı alan listeleri | `b59acf7d59c21150dd672ac22857984e8a044bc04748b0cfb4fa0400d63b982e` |
| `macos/Sources/DiscordAccessKit/Secrets.swift` | 32 baytlık rastgele kimlik bilgisi | `f19f0729f5b2da17aa41683bf59994ddd2f0672ee46d3e7ae4cfeb039158de91` |
| `macos/Sources/DiscordAccessKit/Engine/DnsProvider.swift` | DoH sağlayıcıları ve otomatik seçim sırası | `052cb6ccd022abd40931f42fa215361a0427cab530e6bdde7bf989a320230d76` |
| `macos/Sources/DiscordAccessKit/Engine/EngineConfig.swift` | Motor yapılandırması (Windows `Package.Config`) | `877b90da30e8b61466e47519c2d723fd53e523e9ecd7f336249b2e89c3a402d5` |
| `macos/Sources/DiscordAccessKit/Engine/EngineImage.swift` | Motor sabitleri ve dosya doğrulaması | `4773e90269d9d675d4f8ae012f261db8ba23bddaf85ee0eecfcc55f047e4885b` |
| `macos/Sources/DiscordAccessKit/Engine/EngineProcess.swift` | Motorun başlatılması, doğrulanması, durdurulması, yetim temizliği | `e5d95604575c6103ac061999e571ba47eeb5a67bd2dcc6eea63e319434673b25` |
| `macos/Sources/DiscordAccessKit/System/ProcessInspector.swift` | libproc ve Security.framework ile salt okunur süreç bilgisi | `99923b149b2302df2a45c3fc63f186d5221e5ee34daba1049d320ac2e2a64540` |
| `macos/Tests/DiscordAccessKitTests/TestSupport.swift` | Test yardımcıları | `33d9205126eb1157cfec2eb2bda954555076941fd2289aff8a321537b016f8f7` |
| `macos/Tests/DiscordAccessKitTests/SupportTests.swift` | Hata kodları, kimlik bilgisi, alan listeleri | `c175b06cff3bb8aa2f02edb077832af6fa35393e24d9d08f3996883efb4ac271` |
| `macos/Tests/DiscordAccessKitTests/EngineConfigTests.swift` | DNS sağlayıcısı ve yapılandırma testleri | `ef51adba7697af1bbfd6518b3a3f69463e6ee9a4358cb89c419cfe8de0e57b98` |
| `macos/Tests/DiscordAccessKitTests/Fixtures/engine-configs.json` | Aşama 0 üreticisinden 6 yapılandırma fikstürü | `fd6d12e5c793d2199801323dd2800055c95c8ae2b2d8bdfbc6c9aac191c0301a` |
| `macos/Tests/DiscordAccessKitTests/ProcessInspectorTests.swift` | Süreç denetçisi testleri | `673948496623fbe35ff90c5804e957b5a2f870e3914dc7b09714b43a443f2dae` |
| `macos/Tests/DiscordAccessKitTests/EngineImageTests.swift` | Motor dosyası doğrulama testleri | `6e79f3051db3d9bea2c2707dd6ea5587d20b897ffc427ce92ddad3bd9284462a` |
| `macos/Tests/DiscordAccessKitTests/EngineProcessTests.swift` | Gerçek motorla süreç ve yetim temizliği testleri | `5c9102406c6fe7c67cf2ca085fd4d442bf7ac3dee3869b56ae02dd3ef959be38` |
| `macos/scripts/build-engine.py` | Değişir: motor sabitleri, derleme kaydı denetimi, indirme sınırı, Türkçe `OSError` | `1bb7415c54a29d92eae40f4be0a697a9b89b73bee973b89d5f938785594c9ac6` |
| `macos/Tests/build-engine.test.py` | Değişir: yeni testler (35 test) | `03a336e4bfa4a26d1c15e0b352865cc5e437d4f1ac385a71759167be0dbbcd45` |

Plandan dosya çıkarma yardımcısı. `LANG` kod bloğu dilidir, `INDEX` o dildeki 0 tabanlı sıradır. Yardımcı hash doğrular; yeni dosyada var olanın üzerine yazmaz, değiştirilen dosyada eski hash'i ister.

```bash
python3 -I - macos/docs/plans/2026-10-14-asama-1a-motor-katmani.md LANG INDEX TARGET EXPECTED_SHA256 OLD_SHA256_OR_NONE <<'EOF'
import hashlib, os, re, sys
plan, lang, index, target, expected, old = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
fence = "`" * 3
body = re.findall(re.escape(fence + lang) + r"\n(.*?)" + re.escape(fence), open(plan, encoding="utf-8").read(), re.S)[index].encode("utf-8")
if hashlib.sha256(body).hexdigest() != expected:
    sys.exit("plan block hash mismatch")
if os.path.lexists(target):
    if old == "none" or os.path.islink(target) or hashlib.sha256(open(target, "rb").read()).hexdigest() != old:
        sys.exit("refusing to replace unexpected existing file: " + target)
os.makedirs(os.path.dirname(target), exist_ok=True)
temporary = target + ".installing"
with open(temporary, "xb") as stream:
    stream.write(body)
os.replace(temporary, target)
print("wrote", target, len(body), expected)
EOF
```

---

### Görev 1: Paket iskeleti ve destek kodu

**Files:**
- Create: `macos/Package.swift`, `macos/Tests/DiscordAccessKitTests/TestSupport.swift`, `macos/Tests/DiscordAccessKitTests/SupportTests.swift`
- Create: `macos/Sources/DiscordAccessKit/KitError.swift`, `macos/Sources/DiscordAccessKit/DiscordDestinations.swift`, `macos/Sources/DiscordAccessKit/Secrets.swift`
- Create (boş klasör): `macos/Tests/DiscordAccessKitTests/Fixtures/`

- [ ] **Adım 1: Paket tanımını yaz** (`swift` bloğu 0 → `macos/Package.swift`)

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiscordAccess",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiscordAccessKit", targets: ["DiscordAccessKit"]),
    ],
    targets: [
        .target(name: "DiscordAccessKit"),
        .testTarget(name: "DiscordAccessKitTests", dependencies: ["DiscordAccessKit"], resources: [.copy("Fixtures")]),
    ],
    // Swift 5 language mode until the networking layers (Aşama 1c-1e) settle their concurrency model.
    swiftLanguageModes: [.v5]
)
```

Test hedefi `Fixtures` klasörünü kaynak olarak kopyalar. Klasör yoksa derleme `CpResource … Fixtures` hatasıyla durur. Fikstür dosyası Görev 2'de gelir; şimdilik boş klasör oluşturulur:

```bash
mkdir -p macos/Tests/DiscordAccessKitTests/Fixtures
```

- [ ] **Adım 2: Test yardımcılarını ve destek testlerini yaz** (`swift` blokları 1 ve 2)

```swift
import Darwin
import Foundation

/// The engine built by `macos/scripts/build-engine.py`; engine tests are skipped when it is absent.
enum TestEngine {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var path: String { realPath(packageRoot.appendingPathComponent("build/engine/sing-box").path) }
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }
}

func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A temporary directory addressed by its real (link-free) path; removed when released.
final class TemporaryDirectory {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("discordaccess-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = realPath(base.path)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// A TCP listener owned by the test process, on 127.0.0.1 unless another IPv4 address is given.
final class TCPListener {
    let descriptor: Int32
    let port: UInt16

    init(address host: String = "127.0.0.1") throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw lastPOSIXError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard ready else {
            let error = lastPOSIXError()
            close(fd)
            throw error
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(descriptor) }
}

func startChild(_ executable: String, _ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func waitFor<Value>(timeout: TimeInterval = 5, _ probe: () -> Value?) -> Value? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let value = probe() { return value }
        usleep(50_000)
    } while Date() < deadline
    return probe()
}

/// The current `errno` as a thrown error.
func lastPOSIXError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

/// Sends one request to 127.0.0.1:`port` and returns the first bytes of the reply, or "" when the peer closes
/// without replying. Throws `EAGAIN` when no reply arrives within 3 seconds.
func exchange(port: UInt16, request: String) throws -> String {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw lastPOSIXError() }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    var noSignal: Int32 = 1
    // A peer that resets the connection fails this call instead of killing the test runner with SIGPIPE.
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw lastPOSIXError() }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
    guard connected else { throw lastPOSIXError() }
    try Array(request.utf8).withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw lastPOSIXError() }
            offset += count
        }
    }
    var buffer = [UInt8](repeating: 0, count: 1024)
    var count: Int
    repeat { count = read(descriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
    guard count >= 0 else { throw lastPOSIXError() }
    return String(decoding: buffer[0..<count], as: UTF8.self)
}
```

```swift
import Foundation
import Testing
@testable import DiscordAccessKit

@Suite struct SupportTests {
    @Test func tokensAreRandom32ByteBase64() throws {
        let first = try Secrets.randomToken()
        let second = try Secrets.randomToken()
        #expect(Data(base64Encoded: first)?.count == 32)
        #expect(first != second)
        #expect(!first.contains(":"))
    }

    @Test func errorsCarryWindowsCodes() {
        #expect(KitError.engineMissing("x").code == "PKG-E01")
        #expect(KitError.engineUnreadable("x").code == "PKG-E02")
        #expect(KitError.engineIntegrity("x").description.hasPrefix("[PKG-E03] x "))
        #expect(KitError.engineUnsafePath("x").code == "PKG-E04")
        #expect(KitError.engineStartFailed().code == "ENG-E01")
        #expect(KitError.randomUnavailable().code == "SYS-E01")
    }

    @Test func destinationsMatchWindowsProcessGate() {
        #expect(DiscordDestinations.allowedDomains == ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media",
                                                       "discordcdn.com", "discordstatus.com", "discord.gift"])
        #expect(DiscordDestinations.uploadHosts == ["discord-attachments-uploads-prd.storage.googleapis.com"])
        #expect(DiscordDestinations.challengeDomains == ["hcaptcha.com"])
    }
}
```

- [ ] **Adım 3: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Paket hatası `target 'DiscordAccessKit' referenced in product 'DiscordAccessKit' is empty`. Kütüphane hedefinde henüz kaynak dosya olmadığı için testler derlenmeye başlamaz.

- [ ] **Adım 4: Destek kodunu yaz** (`swift` blokları 3, 4, 5)

```swift
import Foundation

/// A user-facing failure. Codes follow the Windows `PKG-E*` family where the meaning is the same.
public struct KitError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "[" + code + "] " + message }

    static func engineMissing(_ path: String) -> KitError {
        KitError(code: "PKG-E01", message: path + " bulunamadı. Paket eksik; DiscordAccess'i yeniden kurun.")
    }

    static func engineUnreadable(_ path: String) -> KitError {
        KitError(code: "PKG-E02", message: path + " okunamadı. DiscordAccess'i yeniden kurup tekrar deneyin.")
    }

    static func engineIntegrity(_ path: String) -> KitError {
        KitError(code: "PKG-E03", message: path + " bütünlük kontrolünden geçemedi. DiscordAccess'i yeniden kurun.")
    }

    static func engineUnsafePath(_ path: String) -> KitError {
        KitError(code: "PKG-E04", message: path + " dosya yolu güvenli biçimde doğrulanamadı. DiscordAccess'i normal bir yerel klasöre kurun.")
    }

    static func engineStartFailed() -> KitError {
        KitError(code: "ENG-E01", message: "Bağlantı motoru hazır olamadı.")
    }

    static func randomUnavailable() -> KitError {
        KitError(code: "SYS-E01", message: "Güvenli rastgele değer üretilemedi.")
    }
}
```

```swift
/// Discord destinations; the same lists as Windows `ProcessGate` (src/Proxy.cs).
public enum DiscordDestinations {
    public static let allowedDomains = ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media",
                                        "discordcdn.com", "discordstatus.com", "discord.gift"]
    /// Discord's web application CSP names this upload bucket explicitly. HTTPS only, never a Google suffix.
    public static let uploadHosts = ["discord-attachments-uploads-prd.storage.googleapis.com"]
    /// hCaptcha uses changing asset subdomains. HTTPS only; no Discord HTTP or media-port rules.
    public static let challengeDomains = ["hcaptcha.com"]
}
```

```swift
import Foundation
import Security

public enum Secrets {
    /// 32 random bytes, base64 encoded (Windows `DnsConnection.RandomSecret`).
    public static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw KitError.randomUnavailable() }
        return Data(bytes).base64EncodedString()
    }
}
```

- [ ] **Adım 5: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 3 tests in 1 suite passed`.

- [ ] **Adım 6: Kontrol noktası**

Run: `git status --porcelain --untracked-files=all; git diff --name-only main`
Expected: Yalnız `macos/` altındaki yeni dosyalar görünür; `macos/.build/` görünmez; `git diff` boştur.

---

### Görev 2: DNS sağlayıcısı ve motor yapılandırması

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/Fixtures/engine-configs.json`, `macos/Tests/DiscordAccessKitTests/EngineConfigTests.swift`
- Create: `macos/Sources/DiscordAccessKit/Engine/DnsProvider.swift`, `macos/Sources/DiscordAccessKit/Engine/EngineConfig.swift`

- [ ] **Adım 1: Fikstürü yaz** (`json` bloğu 0)

Fikstür, Aşama 0'daki bağımsız Python üreticisinin (`spike.py` → `engine_config`) çıktısıdır. Pinned motor bu çıktıyı kabul etmişti. Altı varyant içerir; kimlik bilgileri sentetiktir.

```json
{
"cloudflare-plain":{"dns":{"final":"discord-dns","servers":[{"path":"/dns-query","server":"1.1.1.1","server_port":443,"tag":"discord-dns","tls":{"enabled":true,"server_name":"cloudflare-dns.com"},"type":"https"}],"strategy":"ipv4_only"},"inbounds":[{"listen":"127.0.0.1","listen_port":32123,"tag":"private-backend","type":"http","users":[{"password":"engine-smoke-fixture-password","username":"engine-smoke-fixture-user"}]}],"log":{"disabled":true},"outbounds":[{"domain_resolver":{"server":"discord-dns","strategy":"ipv4_only"},"tag":"discord-direct","type":"direct"}],"route":{"default_domain_resolver":"discord-dns","rules":[{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443,"tls_record_fragment":true},{"action":"route","domain_suffix":["discord.media"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port_range":["1:65535"]},{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":80},{"action":"route","domain":["discord-attachments-uploads-prd.storage.googleapis.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"route","domain_suffix":["hcaptcha.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"reject"}]}},
"cloudflare-fragment":{"dns":{"final":"discord-dns","servers":[{"path":"/dns-query","server":"1.1.1.1","server_port":443,"tag":"discord-dns","tls":{"enabled":true,"record_fragment":true,"server_name":"cloudflare-dns.com"},"type":"https"}],"strategy":"ipv4_only"},"inbounds":[{"listen":"127.0.0.1","listen_port":32123,"tag":"private-backend","type":"http","users":[{"password":"engine-smoke-fixture-password","username":"engine-smoke-fixture-user"}]}],"log":{"disabled":true},"outbounds":[{"domain_resolver":{"server":"discord-dns","strategy":"ipv4_only"},"tag":"discord-direct","type":"direct"}],"route":{"default_domain_resolver":"discord-dns","rules":[{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443,"tls_record_fragment":true},{"action":"route","domain_suffix":["discord.media"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port_range":["1:65535"]},{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":80},{"action":"route","domain":["discord-attachments-uploads-prd.storage.googleapis.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"route","domain_suffix":["hcaptcha.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"reject"}]}},
"cloudflare-ip-plain":{"dns":{"final":"discord-dns","servers":[{"path":"/dns-query","server":"1.1.1.1","server_port":443,"tag":"discord-dns","tls":{"enabled":true,"server_name":"1.1.1.1"},"type":"https"}],"strategy":"ipv4_only"},"inbounds":[{"listen":"127.0.0.1","listen_port":32123,"tag":"private-backend","type":"http","users":[{"password":"engine-smoke-fixture-password","username":"engine-smoke-fixture-user"}]}],"log":{"disabled":true},"outbounds":[{"domain_resolver":{"server":"discord-dns","strategy":"ipv4_only"},"tag":"discord-direct","type":"direct"}],"route":{"default_domain_resolver":"discord-dns","rules":[{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443,"tls_record_fragment":true},{"action":"route","domain_suffix":["discord.media"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port_range":["1:65535"]},{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":80},{"action":"route","domain":["discord-attachments-uploads-prd.storage.googleapis.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"route","domain_suffix":["hcaptcha.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"reject"}]}},
"cloudflare-ip-fragment":{"dns":{"final":"discord-dns","servers":[{"path":"/dns-query","server":"1.1.1.1","server_port":443,"tag":"discord-dns","tls":{"enabled":true,"record_fragment":true,"server_name":"1.1.1.1"},"type":"https"}],"strategy":"ipv4_only"},"inbounds":[{"listen":"127.0.0.1","listen_port":32123,"tag":"private-backend","type":"http","users":[{"password":"engine-smoke-fixture-password","username":"engine-smoke-fixture-user"}]}],"log":{"disabled":true},"outbounds":[{"domain_resolver":{"server":"discord-dns","strategy":"ipv4_only"},"tag":"discord-direct","type":"direct"}],"route":{"default_domain_resolver":"discord-dns","rules":[{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443,"tls_record_fragment":true},{"action":"route","domain_suffix":["discord.media"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port_range":["1:65535"]},{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":80},{"action":"route","domain":["discord-attachments-uploads-prd.storage.googleapis.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"route","domain_suffix":["hcaptcha.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"reject"}]}},
"google-plain":{"dns":{"final":"discord-dns","servers":[{"path":"/dns-query","server":"8.8.8.8","server_port":443,"tag":"discord-dns","tls":{"enabled":true,"server_name":"dns.google"},"type":"https"}],"strategy":"ipv4_only"},"inbounds":[{"listen":"127.0.0.1","listen_port":32123,"tag":"private-backend","type":"http","users":[{"password":"engine-smoke-fixture-password","username":"engine-smoke-fixture-user"}]}],"log":{"disabled":true},"outbounds":[{"domain_resolver":{"server":"discord-dns","strategy":"ipv4_only"},"tag":"discord-direct","type":"direct"}],"route":{"default_domain_resolver":"discord-dns","rules":[{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443,"tls_record_fragment":true},{"action":"route","domain_suffix":["discord.media"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port_range":["1:65535"]},{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":80},{"action":"route","domain":["discord-attachments-uploads-prd.storage.googleapis.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"route","domain_suffix":["hcaptcha.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"reject"}]}},
"google-fragment":{"dns":{"final":"discord-dns","servers":[{"path":"/dns-query","server":"8.8.8.8","server_port":443,"tag":"discord-dns","tls":{"enabled":true,"record_fragment":true,"server_name":"dns.google"},"type":"https"}],"strategy":"ipv4_only"},"inbounds":[{"listen":"127.0.0.1","listen_port":32123,"tag":"private-backend","type":"http","users":[{"password":"engine-smoke-fixture-password","username":"engine-smoke-fixture-user"}]}],"log":{"disabled":true},"outbounds":[{"domain_resolver":{"server":"discord-dns","strategy":"ipv4_only"},"tag":"discord-direct","type":"direct"}],"route":{"default_domain_resolver":"discord-dns","rules":[{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443,"tls_record_fragment":true},{"action":"route","domain_suffix":["discord.media"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port_range":["1:65535"]},{"action":"route","domain_suffix":["discord.com","discord.gg","discordapp.com","discordapp.net","discord.media","discordcdn.com","discordstatus.com","discord.gift"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":80},{"action":"route","domain":["discord-attachments-uploads-prd.storage.googleapis.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"route","domain_suffix":["hcaptcha.com"],"inbound":["private-backend"],"network":"tcp","outbound":"discord-direct","port":443},{"action":"reject"}]}}
}
```

- [ ] **Adım 2: Testleri yaz** (`swift` bloğu 6)

```swift
import Foundation
import Testing
@testable import DiscordAccessKit

@Suite struct DnsProviderTests {
    @Test func providersMatchWindowsDnsOptions() {
        #expect(DnsProvider(.cloudflareIP).address == "1.1.1.1")
        #expect(DnsProvider(.cloudflareIP).serverName == "1.1.1.1")
        #expect(DnsProvider(.cloudflare).address == "1.1.1.1")
        #expect(DnsProvider(.cloudflare).serverName == "cloudflare-dns.com")
        #expect(DnsProvider(.google).address == "8.8.8.8")
        #expect(DnsProvider(.google).serverName == "dns.google")
    }

    @Test func automaticCandidatesKeepWindowsOrderAndFragmentFlag() {
        let candidates = DnsProvider.automaticCandidates(recordFragment: true)
        #expect(candidates.map(\.name) == [.cloudflareIP, .cloudflare, .google])
        #expect(candidates.allSatisfy { $0.recordFragment })
        #expect(DnsProvider.automaticCandidates(recordFragment: false).allSatisfy { !$0.recordFragment })
    }
}

@Suite struct EngineConfigTests {
    static let username = "engine-smoke-fixture-user"
    static let password = "engine-smoke-fixture-password"

    static func generate(_ name: DnsProvider.Name, _ fragment: Bool) throws -> Data {
        try EngineConfig.json(dns: DnsProvider(name, recordFragment: fragment), username: username, password: password, port: 32123)
    }

    static func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// The fixture comes from the independent Aşama 0 generator, whose output the pinned engine accepted.
    @Test(arguments: DnsProvider.Name.allCases, [false, true])
    func matchesIndependentFixture(name: DnsProvider.Name, fragment: Bool) throws {
        let url = try #require(Bundle.module.url(forResource: "engine-configs", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let expected = try #require(fixtures[name.rawValue + (fragment ? "-fragment" : "-plain")] as? NSDictionary)
        let generated = try Self.object(Self.generate(name, fragment))
        #expect(generated == expected)
    }

    @Test func omitsUnsetFieldsAndKeepsValuesVerbatim() throws {
        let plain = String(decoding: try EngineConfig.json(dns: DnsProvider(.cloudflare), username: "u", password: "p/+=", port: 1), as: UTF8.self)
        #expect(!plain.contains("null"))
        #expect(!plain.contains("\"record_fragment\""))
        #expect(plain.contains("\"path\":\"/dns-query\""))
        #expect(plain.contains("\"password\":\"p/+=\""))
        let fragmented = String(decoding: try Self.generate(.google, true), as: UTF8.self)
        #expect(fragmented.contains("\"record_fragment\":true"))
    }

    @Test(.enabled(if: TestEngine.isAvailable), arguments: DnsProvider.Name.allCases, [false, true])
    func pinnedEngineAcceptsGeneratedConfig(name: DnsProvider.Name, fragment: Bool) throws {
        let directory = try TemporaryDirectory()
        let file = URL(fileURLWithPath: directory.path + "/config.json")
        try Self.generate(name, fragment).write(to: file)
        let check = try startChild(TestEngine.path, ["check", "-c", file.path])
        check.waitUntilExit()
        #expect(check.terminationStatus == 0)
    }
}
```

- [ ] **Adım 3: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'DnsProvider' in scope` ve `cannot find type 'DnsProvider' in scope`. `EngineConfig` çağrıları `DnsProvider` ile aynı ifadelerde olduğu için ayrıca raporlanmaz.

- [ ] **Adım 4: DNS sağlayıcısını ve yapılandırmayı yaz** (`swift` blokları 7 ve 8)

```swift
/// One resolved DNS-over-HTTPS provider (Windows `DnsOptions` after automatic selection).
public struct DnsProvider: Equatable, Sendable {
    public enum Name: String, CaseIterable, Sendable {
        case cloudflareIP = "cloudflare-ip"
        case cloudflare
        case google
    }

    public let name: Name
    public let recordFragment: Bool

    public init(_ name: Name, recordFragment: Bool = false) {
        self.name = name
        self.recordFragment = recordFragment
    }

    public var address: String { name == .google ? "8.8.8.8" : "1.1.1.1" }

    public var serverName: String {
        switch name {
        case .google: return "dns.google"
        case .cloudflareIP: return "1.1.1.1"
        case .cloudflare: return "cloudflare-dns.com"
        }
    }

    /// Automatic selection order, as Windows `DnsOptions.Candidates`.
    public static func automaticCandidates(recordFragment: Bool) -> [DnsProvider] {
        [DnsProvider(.cloudflareIP, recordFragment: recordFragment),
         DnsProvider(.cloudflare, recordFragment: recordFragment),
         DnsProvider(.google, recordFragment: recordFragment)]
    }
}
```

```swift
import Foundation

/// Builds the engine policy in memory, like Windows `Package.Config`. Nothing is read from or written to disk.
public enum EngineConfig {
    static let inboundTag = "private-backend"
    static let outboundTag = "discord-direct"
    static let resolverTag = "discord-dns"

    public static func json(dns: DnsProvider, username: String, password: String, port: UInt16) throws -> Data {
        let inbound = [inboundTag]
        let allowed = DiscordDestinations.allowedDomains
        let tls = TLS(enabled: true, serverName: dns.serverName, recordFragment: dns.recordFragment ? true : nil)
        let document = Document(
            log: Log(disabled: true),
            dns: DNS(servers: [Server(type: "https", tag: resolverTag, server: dns.address, serverPort: 443, path: "/dns-query", tls: tls)],
                     final: resolverTag, strategy: "ipv4_only"),
            inbounds: [Inbound(type: "http", tag: inboundTag, listen: "127.0.0.1", listenPort: Int(port),
                               users: [User(username: username, password: password)])],
            outbounds: [Outbound(type: "direct", tag: outboundTag, domainResolver: Resolver(server: resolverTag, strategy: "ipv4_only"))],
            route: Route(rules: [
                Rule(inbound: inbound, network: "tcp", domainSuffix: allowed, port: 443, action: "route", outbound: outboundTag,
                     tlsRecordFragment: true),
                // Discord media keeps its dynamic WSS ports; fragmentation stays limited to the HTTPS rule above.
                Rule(inbound: inbound, network: "tcp", domainSuffix: ["discord.media"], portRange: ["1:65535"], action: "route",
                     outbound: outboundTag),
                Rule(inbound: inbound, network: "tcp", domainSuffix: allowed, port: 80, action: "route", outbound: outboundTag),
                Rule(inbound: inbound, network: "tcp", domain: DiscordDestinations.uploadHosts, port: 443, action: "route",
                     outbound: outboundTag),
                Rule(inbound: inbound, network: "tcp", domainSuffix: DiscordDestinations.challengeDomains, port: 443, action: "route",
                     outbound: outboundTag),
                Rule(action: "reject"),
            ], defaultDomainResolver: resolverTag))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}

private struct Document: Encodable {
    let log: Log
    let dns: DNS
    let inbounds: [Inbound]
    let outbounds: [Outbound]
    let route: Route
}

private struct Log: Encodable {
    let disabled: Bool
}

private struct TLS: Encodable {
    let enabled: Bool
    let serverName: String
    let recordFragment: Bool?
}

private struct Server: Encodable {
    let type: String
    let tag: String
    let server: String
    let serverPort: Int
    let path: String
    let tls: TLS
}

private struct DNS: Encodable {
    let servers: [Server]
    let `final`: String
    let strategy: String
}

private struct User: Encodable {
    let username: String
    let password: String
}

private struct Inbound: Encodable {
    let type: String
    let tag: String
    let listen: String
    let listenPort: Int
    let users: [User]
}

private struct Resolver: Encodable {
    let server: String
    let strategy: String
}

private struct Outbound: Encodable {
    let type: String
    let tag: String
    let domainResolver: Resolver
}

private struct Rule: Encodable {
    var inbound: [String]? = nil
    var network: String? = nil
    var domainSuffix: [String]? = nil
    var domain: [String]? = nil
    var port: Int? = nil
    var portRange: [String]? = nil
    var action: String
    var outbound: String? = nil
    var tlsRecordFragment: Bool? = nil
}

private struct Route: Encodable {
    let rules: [Rule]
    let defaultDomainResolver: String
}
```

- [ ] **Adım 5: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: Bütün testler geçer:
- 6 fikstür karşılaştırması
- 6 motor `check` denetimi (`macos/build/engine/sing-box` varsa)

Son satır `✔ Test run with 8 tests in 3 suites passed`. Swift Testing, parametreli testleri tek test olarak sayar.

---

### Görev 3: Süreç denetçisi

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/ProcessInspectorTests.swift`, `macos/Sources/DiscordAccessKit/System/ProcessInspector.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 9)

```swift
import Darwin
import Testing
@testable import DiscordAccessKit

@Suite struct ProcessInspectorTests {
    @Test func describesTheCurrentProcess() throws {
        let record = try #require(ProcessInspector.record(for: getpid()))
        #expect(record.uid == getuid())
        #expect(record.parentPid > 0)
        #expect(record.path.hasPrefix("/"))
        #expect(ProcessInspector.userProcessIDs().contains(getpid()))
        #expect(ProcessInspector.record(for: 0) == nil)
        #expect(ProcessInspector.record(for: -1) == nil)
    }

    /// The child starts before the listener exists, so it cannot inherit the socket. Unlike launchd (pid 1), whose
    /// descriptors cannot be listed at all, it is a same-user process whose descriptors are readable.
    @Test func findsOnlyTheOwnersLoopbackListener() throws {
        let other = try startChild("/bin/sleep", ["30"])
        defer {
            other.terminate()
            other.waitUntilExit()
        }
        let listener = try TCPListener()
        #expect(ProcessInspector.ownsLoopbackListener(pid: getpid(), port: listener.port))
        #expect(!ProcessInspector.ownsLoopbackListener(pid: getpid(), port: listener.port &+ 1))
        #expect(ProcessInspector.record(for: other.processIdentifier)?.uid == getuid())
        #expect(!ProcessInspector.ownsLoopbackListener(pid: other.processIdentifier, port: listener.port))
        #expect(!ProcessInspector.ownsLoopbackListener(pid: 1, port: listener.port))
    }

    @Test func ignoresListenersOutsideLoopback() throws {
        let wildcard = try TCPListener(address: "0.0.0.0")
        #expect(ProcessInspector.tcpSockets(of: getpid()).contains { $0.listening && !$0.localLoopback && $0.localPort == wildcard.port })
        #expect(!ProcessInspector.ownsLoopbackListener(pid: getpid(), port: wildcard.port))
    }

    @Test func checksCodeRequirementsOfARunningProcess() throws {
        let sleeper = try startChild("/bin/sleep", ["30"])
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        let pid = sleeper.processIdentifier
        #expect(ProcessInspector.satisfies(pid: pid, requirement: "anchor apple"))
        #expect(!ProcessInspector.satisfies(pid: pid, requirement: "anchor apple generic and certificate leaf[subject.OU] = \"53Q6R32WPB\""))
        #expect(!ProcessInspector.satisfies(pid: pid, requirement: "not a requirement"))
        #expect(!ProcessInspector.satisfies(pid: 0, requirement: "anchor apple"))
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'ProcessInspector' in scope`. Tür henüz olmadığı için `no calls to throwing functions occur within 'try' expression` uyarısı da görülebilir.

- [ ] **Adım 3: Süreç denetçisini yaz** (`swift` bloğu 10)

Kaynaklar:
- libproc çağrıları Aşama 0'daki `peer_probe.swift` yoklamasında canlı Discord'la doğrulandı.
- `satisfies` çalışan sürecin imzasını dinamik olarak, verilen gereksinime göre denetler.

```swift
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
        let localLoopback: Bool
        let localPort: UInt16
        let remoteLoopback: Bool
        let remotePort: UInt16
    }

    public static func userProcessIDs(uid: uid_t = getuid()) -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 32)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
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
        tcpSockets(of: pid).contains { $0.listening && $0.localLoopback && $0.localPort == port }
    }

    /// Dynamic code-signing check of a running process against a requirement, e.g. `cdhash H"…"` or a Team ID rule.
    public static func satisfies(pid: pid_t, requirement text: String) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var requirement: SecRequirement?
        guard pid > 0, SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func tcpSockets(of pid: pid_t) -> [TCPSocket] {
        socketDescriptors(of: pid).compactMap { descriptor in
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { return nil }
            let tcp = info.psi.soi_proto.pri_tcp
            let endpoint = tcp.tcpsi_ini
            guard endpoint.insi_vflag & UInt8(INI_IPV4) != 0 else { return nil }
            let loopback = inet_addr("127.0.0.1")
            return TCPSocket(listening: tcp.tcpsi_state == Int32(TSI_S_LISTEN),
                             localLoopback: endpoint.insi_laddr.ina_46.i46a_addr4.s_addr == loopback,
                             localPort: networkPort(endpoint.insi_lport),
                             remoteLoopback: endpoint.insi_faddr.ina_46.i46a_addr4.s_addr == loopback,
                             remotePort: networkPort(endpoint.insi_fport))
        }
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func socketDescriptors(of pid: pid_t) -> [Int32] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16)
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .map { $0.proc_fd }
    }

    private static func networkPort(_ value: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: value))
    }
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 12 tests in 4 suites passed`.

---

### Görev 4: Motor dosyası doğrulama

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/EngineImageTests.swift`, `macos/Sources/DiscordAccessKit/Engine/EngineImage.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 11)

```swift
import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import DiscordAccessKit

@Suite struct EngineImageTests {
    static let content = Data("fixture-engine-bytes".utf8)
    static let identity = pin(for: content)

    static func pin(for data: Data) -> EngineIdentity {
        EngineIdentity(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), cdhash: String(repeating: "0", count: 40))
    }

    static func code(_ body: () throws -> EngineImage) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as KitError {
            return error.code
        } catch {
            return "unexpected"
        }
    }

    @Test func acceptsExactPinnedBytes() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        try Self.content.write(to: URL(fileURLWithPath: path))
        let image = try EngineImage.verify(path: path, expected: Self.identity)
        #expect(image.path == path)
        #expect(image.identity == Self.identity)
    }

    /// 2.5 MiB: two full read chunks and a partial one.
    @Test func hashesFilesLargerThanOneChunk() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        let original = Data((0..<(5 << 19)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try original.write(to: URL(fileURLWithPath: path))
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.pin(for: original)) } == nil)
        var changed = original
        changed[changed.count - 1] ^= 1
        try changed.write(to: URL(fileURLWithPath: path))
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.pin(for: original)) } == "PKG-E03")
    }

    @Test func rejectsChangedBytesAsIntegrityFailure() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: path))
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.identity) } == "PKG-E03")
    }

    @Test func rejectsMissingFileAndMissingFolder() throws {
        let directory = try TemporaryDirectory()
        let file = directory.path + "/file"
        try Self.content.write(to: URL(fileURLWithPath: file))
        #expect(Self.code { try EngineImage.verify(path: directory.path + "/missing", expected: Self.identity) } == "PKG-E01")
        #expect(Self.code { try EngineImage.verify(path: file + "/sing-box", expected: Self.identity) } == "PKG-E01")
    }

    @Test(.enabled(if: geteuid() != 0)) func rejectsUnreadableFile() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        try Self.content.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.identity) } == "PKG-E02")
    }

    @Test func rejectsLinkedFileParentAndDirectory() throws {
        let directory = try TemporaryDirectory()
        let real = directory.path + "/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try Self.content.write(to: URL(fileURLWithPath: real + "/sing-box"))
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/file-link", withDestinationPath: real + "/sing-box")
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/folder-link", withDestinationPath: real)
        #expect(Self.code { try EngineImage.verify(path: directory.path + "/file-link", expected: Self.identity) } == "PKG-E04")
        #expect(Self.code { try EngineImage.verify(path: directory.path + "/folder-link/sing-box", expected: Self.identity) } == "PKG-E04")
        #expect(Self.code { try EngineImage.verify(path: real, expected: Self.identity) } == "PKG-E04")
    }

    @Test func rejectsFIFOWithoutBlocking() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/sing-box"
        #expect(mkfifo(path, 0o600) == 0)
        #expect(Self.code { try EngineImage.verify(path: path, expected: Self.identity) } == "PKG-E04")
    }

    @Test func rejectsNonCanonicalSpellings() throws {
        let directory = try TemporaryDirectory()
        try Self.content.write(to: URL(fileURLWithPath: directory.path + "/sing-box"))
        #expect(Self.code { try EngineImage.verify(path: directory.path + "//sing-box", expected: Self.identity) } == "PKG-E04")
        #expect(Self.code { try EngineImage.verify(path: directory.path + "/./sing-box", expected: Self.identity) } == "PKG-E04")
    }

    /// Both pinned values describe the built engine: the bytes through `verify`, the signature through Security.framework.
    @Test(.enabled(if: TestEngine.isAvailable)) func builtEngineMatchesThePin() throws {
        #expect(try EngineImage.verify(path: TestEngine.path).identity == .pinned)
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: TestEngine.path) as CFURL, [], &code) == errSecSuccess)
        let staticCode = try #require(code)
        var information: CFDictionary?
        #expect(SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess)
        let cdhash = try #require((information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
        #expect(cdhash.map { String(format: "%02x", $0) }.joined() == EngineIdentity.pinned.cdhash)
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find type 'EngineIdentity' in scope` ve `cannot find type 'EngineImage' in scope`.

- [ ] **Adım 3: Motor sabitlerini ve doğrulamayı yaz** (`swift` bloğu 12)

Sabit değerler Aşama 0'daki iki bağımsız derlemenin ortak sonucudur:
- SHA-256 `013ba5d5…2cb0`
- cdhash `344f8bd0…99e`

Paket dışından yalnız `verify(path:)` çağrılabilir; o da her zaman sabit kimliği kullanır. Başka bir kimlik bekleyen sürüm yalnız paket içinde ve testlerde kullanılır. `O_NONBLOCK`, yolda bir FIFO varsa açılışın takılmasını önler. Bir test sabit cdhash'i Security.framework ile derlenmiş motorun imzasından da okur.

```swift
import CryptoKit
import Darwin
import Foundation

/// The pinned identity of the engine built by `macos/scripts/build-engine.py` (darwin/arm64, reproduced in Aşama 0).
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
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 21 tests in 5 suites passed`.

---

### Görev 5: Motor süreci ve yetim temizliği

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/EngineProcessTests.swift`, `macos/Sources/DiscordAccessKit/Engine/EngineProcess.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 13)

Süreç sayan testler motorun özel bir kopyasını kullanır, çünkü `EngineConfigTests` aynı yoldan paralel `check` süreçleri başlatır. Yetim temizliği testi sahte motor olarak gerçek motorun kopyalarını kullanır. Apple sistem ikililerinin kopyaları (örneğin `/bin/sleep`) sistem dışı konumda çalıştırılınca macOS onları anında öldürür (launch constraint, çıkış kodu 137).

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Tests that count engine processes use a private copy of the engine: `EngineConfigTests` runs `sing-box check`
/// children from `TestEngine.path` in parallel.
@Suite(.serialized) struct EngineProcessTests {
    static func copyOfEngine(in directory: TemporaryDirectory, named name: String = "sing-box") throws -> String {
        let path = directory.path + "/" + name
        try FileManager.default.copyItem(atPath: TestEngine.path, toPath: path)
        return path
    }

    static func processes(at path: String, parent: pid_t) -> [ProcessInspector.Record] {
        ProcessInspector.userProcessIDs().compactMap(ProcessInspector.record(for:)).filter { $0.parentPid == parent && $0.path == path }
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func startsOwnsItsListenerRequiresTheCredentialAndStops() throws {
        let engine = try EngineProcess.start(image: try EngineImage.verify(path: TestEngine.path), dns: DnsProvider(.cloudflareIP))
        #expect(engine.isRunning)
        #expect(ProcessInspector.ownsLoopbackListener(pid: engine.pid, port: engine.port))
        #expect(ProcessInspector.satisfies(pid: engine.pid, requirement: EngineIdentity.pinned.requirement))
        // example.com matches no route: with the credential the engine answers 200 and then rejects the tunnel,
        // so no traffic leaves the machine.
        let connect = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n"
        #expect(try exchange(port: engine.port, request: connect + "\r\n").hasPrefix("HTTP/1.1 407"))
        #expect(try exchange(port: engine.port, request: connect + "Proxy-Authorization: Basic dTpw\r\n\r\n").hasPrefix("HTTP/1.1 407"))
        #expect(try exchange(port: engine.port, request: connect + "Proxy-Authorization: " + engine.authorization + "\r\n\r\n")
            .hasPrefix("HTTP/1.1 200"))
        #expect(engine.stop())
        #expect(engine.stop())
        #expect(!engine.isRunning)
        #expect(throws: POSIXError(.ECONNREFUSED)) { try exchange(port: engine.port, request: "") }
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func refusesAnEngineOutsideTheCdhashPinBeforeItRuns() throws {
        let directory = try TemporaryDirectory()
        let copy = try Self.copyOfEngine(in: directory)
        let wrong = EngineIdentity(sha256: EngineIdentity.pinned.sha256, cdhash: String(repeating: "0", count: 40))
        let image = try EngineImage.verify(path: copy, expected: wrong)
        #expect(throws: KitError.engineIntegrity(copy)) { try EngineProcess.start(image: image, dns: DnsProvider(.cloudflare)) }
        #expect(Self.processes(at: copy, parent: getpid()).isEmpty)
    }

    /// The file may change after it was verified; `start` measures it again and reports the package error.
    @Test(.enabled(if: TestEngine.isAvailable))
    func reportsAFileChangedAfterVerificationAsAPackageError() throws {
        let directory = try TemporaryDirectory()
        let copy = try Self.copyOfEngine(in: directory)
        let image = try EngineImage.verify(path: copy)
        try Data("not an engine".utf8).write(to: URL(fileURLWithPath: copy))
        #expect(throws: KitError.engineIntegrity(copy)) { try EngineProcess.start(image: image, dns: DnsProvider(.google)) }
        try FileManager.default.removeItem(atPath: copy)
        #expect(throws: KitError.engineMissing(copy)) { try EngineProcess.start(image: image, dns: DnsProvider(.google)) }
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func stopsAnEngineThatIsNotReadyInTime() throws {
        let directory = try TemporaryDirectory()
        let copy = try Self.copyOfEngine(in: directory)
        let image = try EngineImage.verify(path: copy)
        #expect(throws: KitError.engineStartFailed()) { try EngineProcess.start(image: image, dns: DnsProvider(.google), readyTimeout: 0) }
        #expect(Self.processes(at: copy, parent: getpid()).isEmpty)
    }

    /// Uses the built engine, not a fresh copy: macOS scans a new executable on its first run, which can delay readiness.
    @Test(.enabled(if: TestEngine.isAvailable))
    func releasingTheRunStopsTheEngine() throws {
        var engine: EngineProcess? = try EngineProcess.start(image: try EngineImage.verify(path: TestEngine.path), dns: DnsProvider(.google))
        let pid = try #require(engine?.pid)
        #expect(ProcessInspector.record(for: pid)?.parentPid == getpid())
        engine = nil
        #expect(ProcessInspector.record(for: pid) == nil)
    }

    /// Uses copies of the engine: copies of Apple system binaries are killed outside system paths (launch constraints).
    /// A process of another user cannot be started without root, so the uid filter is not exercised here.
    @Test(.enabled(if: TestEngine.isAvailable))
    func terminatesOnlyLaunchdAdoptedCopiesOfTheEnginePath() throws {
        let directory = try TemporaryDirectory()
        let fakeEngine = try Self.copyOfEngine(in: directory)
        let otherEngine = try Self.copyOfEngine(in: directory, named: "other-sing-box")
        let emptyConfig = directory.path + "/empty.json"
        try Data("{\"log\":{\"disabled\":true}}".utf8).write(to: URL(fileURLWithPath: emptyConfig))
        let child = try startChild(fakeEngine, ["run", "-c", emptyConfig])
        defer {
            child.terminate()
            child.waitUntilExit()
            // Nothing is left behind even if an expectation below fails.
            for leftover in Self.processes(at: fakeEngine, parent: 1) + Self.processes(at: otherEngine, parent: 1) { kill(leftover.pid, SIGKILL) }
        }
        for engine in [fakeEngine, otherEngine] {
            let launcher = try startChild("/bin/sh", ["-c", "\"$0\" run -c \"$1\" >/dev/null 2>&1 &", engine, emptyConfig])
            launcher.waitUntilExit()
        }
        let orphan = try #require(waitFor { Self.processes(at: fakeEngine, parent: 1).first })
        let other = try #require(waitFor { Self.processes(at: otherEngine, parent: 1).first })
        #expect(EngineProcess.terminateOrphans(enginePath: fakeEngine) == [orphan.pid])
        #expect(waitFor { ProcessInspector.record(for: orphan.pid) == orphan ? nil : true } == true)
        #expect(child.isRunning)
        #expect(ProcessInspector.record(for: other.pid) == other)
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'EngineProcess' in scope` ve `cannot find type 'EngineProcess' in scope`. Tür henüz olmadığı için `no calls to throwing functions occur within 'try' expression` uyarısı da görülebilir.

- [ ] **Adım 3: Motor sürecini yaz** (`swift` bloğu 14)

Akış:
1. `start` dosyayı yeniden ölçer. Dosya doğrulamadan sonra değiştiyse ilgili `PKG-E*` hatası döner.
2. Motor yalnız stdin/stdout/stderr ile, kendi süreç grubunda ve askıda başlatılır (`POSIX_SPAWN_CLOEXEC_DEFAULT`, `POSIX_SPAWN_START_SUSPENDED`).
3. Askıdaki sürecin kodu cdhash sabitini karşılamazsa motor hiç çalışmadan öldürülür ve `PKG-E03` döner. Karşılarsa sürdürülür ve yapılandırma stdin'den verilir.
4. Hazır sayılması için dinleyicinin motora ait olması gerekir. Süre dolarsa motor durdurulur ve `ENG-E01` döner.
5. `stop()` motoru, Windows'ta iş nesnesinin kapatılması gibi hemen öldürür (`SIGKILL`) ve toplar. Nesne bırakıldığında da aynısı olur.

```swift
import Darwin
import Foundation

/// One engine run (Windows `DnsConnection`). The engine starts suspended and resumes only if its code matches the
/// pinned cdhash; the policy then goes in on stdin with a random credential, and the engine must own its loopback
/// listener before the run is handed out.
public final class EngineProcess {
    public let pid: pid_t
    public let port: UInt16
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var reaped = false

    private init(pid: pid_t, port: UInt16, username: String, password: String) {
        self.pid = pid
        self.port = port
        self.username = username
        self.password = password
    }

    deinit { stop() }

    public static func start(image: EngineImage, dns: DnsProvider, readyTimeout: TimeInterval = 12) throws -> EngineProcess {
        // The file may have changed since `image` was verified; measuring it again keeps the PKG-E* codes accurate.
        let current = try EngineImage.verify(path: image.path, expected: image.identity)
        let port = try reserveLoopbackPort()
        let username = try Secrets.randomToken()
        let password = try Secrets.randomToken()
        let config = try EngineConfig.json(dns: dns, username: username, password: password, port: port)
        let engine = EngineProcess(pid: try spawn(image: current, input: config), port: port, username: username, password: password)
        do {
            try engine.waitUntilListening(timeout: readyTimeout)
            return engine
        } catch {
            engine.stop()
            throw error
        }
    }

    /// `Proxy-Authorization` value for this run's credential.
    public var authorization: String { "Basic " + Data((username + ":" + password).utf8).base64EncodedString() }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !reapIfExited()
    }

    /// Kills the engine at once, as closing the Windows job object does (it keeps no state), and reaps it; returns false
    /// only if it was not reaped within `timeout`. Can block that long, and so can releasing the last reference
    /// (`deinit` stops the engine); keep both off the main thread.
    @discardableResult
    public func stop(timeout: TimeInterval = 5) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if reapIfExited() { return true }
        kill(pid, SIGKILL)
        return waitForExit(timeout: timeout)
    }

    /// Terminates engines of `enginePath` left behind by a crashed session: same user, adopted by launchd.
    /// Each process is re-identified (pid, start time, path) before it is force-killed.
    @discardableResult
    public static func terminateOrphans(enginePath: String, uid: uid_t = getuid()) -> [pid_t] {
        let orphans = ProcessInspector.userProcessIDs(uid: uid).compactMap(ProcessInspector.record(for:))
            .filter { $0.parentPid == 1 && $0.uid == uid && $0.path == enginePath }
            .filter { kill($0.pid, SIGTERM) == 0 }
        let deadline = Date().addingTimeInterval(3)
        var remaining = orphans
        while !remaining.isEmpty && Date() < deadline {
            usleep(50_000)
            remaining = remaining.filter { ProcessInspector.record(for: $0.pid) == $0 }
        }
        for orphan in remaining where ProcessInspector.record(for: orphan.pid) == orphan { kill(orphan.pid, SIGKILL) }
        return orphans.map(\.pid)
    }

    private func waitUntilListening(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isRunning else { throw KitError.engineStartFailed() }
            if ProcessInspector.ownsLoopbackListener(pid: pid, port: port) { return }
            usleep(40_000)
        }
        throw KitError.engineStartFailed()
    }

    /// Must be called with `lock` held.
    private func reapIfExited() -> Bool {
        if reaped { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) { reaped = true }
        return reaped
    }

    /// Must be called with `lock` held.
    private func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if reapIfExited() { return true }
            usleep(20_000)
        } while Date() < deadline
        return reapIfExited()
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw KitError.engineStartFailed() }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else { throw KitError.engineStartFailed() }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func spawn(image: EngineImage, input: Data) throws -> pid_t {
        // Every setup call is checked: without these attributes the engine would run before the signature check.
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw KitError.engineStartFailed() }
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors set up below reach the engine; it gets its own process group and starts suspended,
        // so none of its code runs before the signature check.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw KitError.engineStartFailed() }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw KitError.engineStartFailed() }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw KitError.engineStartFailed() }
        let readEnd = ends[0], writeEnd = ends[1]
        // Neither end may leak into a process spawned elsewhere meanwhile; dup2 clears the flag on the engine's stdin.
        guard fcntl(readEnd, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeEnd, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeEnd, F_SETNOSIGPIPE, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, (image.path as NSString).deletingLastPathComponent) == 0 else {
            close(readEnd)
            close(writeEnd)
            throw KitError.engineStartFailed()
        }
        var pid: pid_t = 0
        let status = withCStringArray([image.path, "run", "-c", "stdin", "--disable-color"]) { arguments in
            withCStringArray(["PATH=/usr/bin:/bin"]) { environment in
                posix_spawn(&pid, image.path, &actions, &attributes, arguments, environment)
            }
        }
        close(readEnd)
        guard status == 0 else {
            close(writeEnd)
            throw KitError.engineStartFailed()
        }
        guard ProcessInspector.satisfies(pid: pid, requirement: image.identity.requirement) else {
            close(writeEnd)
            discard(pid)
            throw KitError.engineIntegrity(image.path)
        }
        kill(pid, SIGCONT)
        let delivered = input.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(writeEnd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        close(writeEnd)
        guard delivered else {
            discard(pid)
            throw KitError.engineStartFailed()
        }
        return pid
    }

    /// Kills and reaps a child that was never handed out.
    private static func discard(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var ignored: Int32 = 0
        while waitpid(pid, &ignored, 0) == -1 && errno == EINTR {}
    }
}

private func withCStringArray<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 27 tests in 6 suites passed`. Gerçek motor testleri:
- başlatma
- 407 kimlik doğrulama yanıtı
- durdurma
- cdhash uyuşmazlığının motor çalışmadan reddi
- doğrulamadan sonra değişen veya silinen dosyanın paket hatasıyla reddi
- zamanında hazır olmayan motorun durdurulması
- nesne bırakılınca motorun durması
- yetim temizliği (başka yoldaki yetim korunur)

Sandbox engeli çıkarsa aynı komut sandbox dışında yeniden çalıştırılır.

- [ ] **Adım 5: Kontrol noktası**

Run: `git status --porcelain --untracked-files=all; git diff --name-only main`
Expected: Yalnız `macos/` altındaki yeni dosyalar; `git diff` boş.

---

### Görev 6: Derleme betiğinin motor sabitleri

Aşama 0 incelemesinden ertelenen küçük bulgular da burada kapatılır:
- `OSError` için Türkçe mesaj
- indirme boyut sınırı
- `go version -m` kaydının denetimi

**Files:**
- Modify: `macos/Tests/build-engine.test.py` (tam dosya; eski SHA-256 `4c92e60f523ebba1af6f515a683d72eccb9a39c4b6c2dc21edaf14bd6430facc`)
- Modify: `macos/scripts/build-engine.py` (tam dosya; eski SHA-256 `9d1f3c3fbcb1e6bca9d8ceed4ecd48660f79ac79b109cf2f8fe3d5d495c663c4`)

- [ ] **Adım 1: Testleri güncelle** (`python` bloğu 0; yardımcıyla, eski hash verilerek)

Yeni testler:
- derleme kaydının sabit hedef, etiket ve araç zinciriyle tam eşleşmesi; fazladan veya yinelenen ayarın reddi
- motor kimliğinin (SHA-256, boyut, cdhash) her alanının denetlenmesi ve `build()` içinde yayımlamadan önce çağrılması
- yanlış hash'li önbellek dosyasının yenisiyle değiştirilmesi
- `file://` adresiyle indirme ve önbellek
- boyut sınırı ve hash uyuşmazlığında geride dosya kalmaması
- Swift `EngineIdentity.pinned` ile Python sabitlerinin aynı olması
- `OSError` için Türkçe mesaj

```python
"""Offline checks for macos/scripts/build-engine.py: synthetic fixtures only; no network, Go or engine run."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import inspect
import io
import os
from pathlib import Path
import stat
import sys
import re
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

sys.dont_write_bytecode = True
MACOS = Path(os.path.realpath(__file__)).parent.parent
REPO = MACOS.parent
_spec = importlib.util.spec_from_file_location("build_engine_under_test", MACOS / "scripts" / "build-engine.py")
build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class TemporaryRoot(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.temporary.name))

    def tearDown(self):
        self.temporary.cleanup()


class PathTests(TemporaryRoot):
    def test_paths_must_stay_inside_without_symlinks(self):
        (self.root / "real").mkdir()
        (self.root / "link").symlink_to(self.root / "real")
        self.assertEqual(build.require_inside(self.root / "real" / "x", self.root), self.root / "real" / "x")
        for path in (self.root / ".." / "x", self.root / "link" / "x", Path("/etc/hosts")):
            with self.subTest(path=str(path)), self.assertRaises(build.BuildError):
                build.require_inside(path, self.root)


class OverlayTests(TemporaryRoot):
    def setUp(self):
        super().setUp()
        self.repo, self.source = self.root / "repo", self.root / "source"
        self.payloads = self.repo / "engine-patches" / "http-limits" / "source"
        (self.payloads / "pkg").mkdir(parents=True)
        (self.source / "pkg").mkdir(parents=True)
        self.original, self.patched = b"package pkg\n", b"package pkg\n// reviewed change\n"
        (self.source / "pkg" / "a.go").write_bytes(self.original)
        (self.payloads / "pkg" / "a.go").write_bytes(self.patched)

    def manifest(self, **changes):
        record = {"source_relative": "pkg/a.go", "payload_relative": "engine-patches/http-limits/source/pkg/a.go",
                  "before_sha256": digest(self.original), "after_sha256": digest(self.patched), "bytes": len(self.patched)}
        record.update(changes)
        return {"files": [record]}

    def test_modified_file_is_replaced_when_both_hashes_match(self):
        self.assertEqual(build.apply_overlay(self.manifest(), self.repo, self.source), ["pkg/a.go"])
        self.assertEqual((self.source / "pkg" / "a.go").read_bytes(), self.patched)

    def test_changed_upstream_base_is_rejected(self):
        (self.source / "pkg" / "a.go").write_bytes(b"package pkg\n// drift\n")
        with self.assertRaises(build.BuildError):
            build.apply_overlay(self.manifest(), self.repo, self.source)

    def test_added_file_must_not_already_exist(self):
        with self.assertRaises(build.BuildError):
            build.apply_overlay(self.manifest(before_sha256=None), self.repo, self.source)

    def test_added_file_is_created(self):
        (self.payloads / "pkg" / "new.go").write_bytes(self.patched)
        manifest = self.manifest(source_relative="pkg/new.go", before_sha256=None,
                                 payload_relative="engine-patches/http-limits/source/pkg/new.go")
        build.apply_overlay(manifest, self.repo, self.source)
        self.assertEqual((self.source / "pkg" / "new.go").read_bytes(), self.patched)

    def test_payload_bytes_must_match_before_anything_is_written(self):
        (self.payloads / "pkg" / "a.go").write_bytes(b"package pkg\n// tampered\n")
        with self.assertRaises(build.BuildError):
            build.apply_overlay(self.manifest(), self.repo, self.source)
        self.assertEqual((self.source / "pkg" / "a.go").read_bytes(), self.original)

    def test_traversal_names_are_rejected(self):
        for name in ("../escape.go", "pkg/../../escape.go", "/abs.go", "pkg//a.go"):
            with self.subTest(name=name), self.assertRaises(build.BuildError):
                build.apply_overlay(self.manifest(source_relative=name, payload_relative="engine-patches/http-limits/source/" + name),
                                    self.repo, self.source)

    def test_symlinked_target_is_rejected(self):
        outside = self.root / "outside.go"
        outside.write_bytes(self.original)
        (self.source / "pkg" / "a.go").unlink()
        (self.source / "pkg" / "a.go").symlink_to(outside)
        with self.assertRaises(build.BuildError):
            build.apply_overlay(self.manifest(), self.repo, self.source)
        self.assertEqual(outside.read_bytes(), self.original)


class ArchiveTests(TemporaryRoot):
    def zip_file(self, entries):
        path = self.root / "source.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data, mode in entries:
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                archive.writestr(info, data)
        return path

    def tar_file(self, members):
        path = self.root / "go.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, kind, data, mode in members:
                info = tarfile.TarInfo(name)
                info.type, info.mode = kind, mode
                if kind == tarfile.SYMTYPE:
                    info.linkname = "/etc/hosts"
                    archive.addfile(info)
                elif kind == tarfile.DIRTYPE:
                    archive.addfile(info)
                else:
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
        return path

    def test_zip_extracts_files_under_prefix(self):
        path = self.zip_file([("top/", b"", stat.S_IFDIR | 0o755), ("top/a/b.go", b"package b\n", stat.S_IFREG | 0o644)])
        self.assertEqual(build.extract_zip(path, self.root / "out", "top/", 1 << 20), 1)
        self.assertEqual((self.root / "out" / "a" / "b.go").read_bytes(), b"package b\n")

    def test_zip_rejects_foreign_prefix_and_traversal(self):
        for index, name in enumerate(("other/a.go", "top/../a.go", "top/a/../../b.go", "top\\a.go")):
            with self.subTest(name=name):
                path = self.zip_file([(name, b"x", stat.S_IFREG | 0o644)])
                with self.assertRaises(build.BuildError):
                    build.extract_zip(path, self.root / ("out-" + str(index)), "top/", 1 << 20)

    def test_zip_link_entry_is_written_as_plain_file(self):
        path = self.zip_file([("top/link", b"target-text", stat.S_IFLNK | 0o777)])
        build.extract_zip(path, self.root / "out", "top/", 1 << 20)
        self.assertFalse((self.root / "out" / "link").is_symlink())
        self.assertEqual((self.root / "out" / "link").read_bytes(), b"target-text")

    def test_zip_size_limit(self):
        path = self.zip_file([("top/big", b"x" * 2048, stat.S_IFREG | 0o644)])
        with self.assertRaises(build.BuildError):
            build.extract_zip(path, self.root / "out", "top/", 1024)

    def test_go_archive_keeps_executable_bits(self):
        path = self.tar_file([("go", tarfile.DIRTYPE, b"", 0o755), ("go/bin/go", tarfile.REGTYPE, b"#!fixture", 0o755),
                              ("go/VERSION", tarfile.REGTYPE, b"go1.26.9", 0o644)])
        self.assertEqual(build.extract_go_toolchain(path, self.root / "go"), 2)
        self.assertTrue(os.access(self.root / "go" / "bin" / "go", os.X_OK))
        self.assertFalse(os.access(self.root / "go" / "VERSION", os.X_OK))

    def test_go_archive_rejects_links_and_foreign_paths(self):
        cases = ([("go/link", tarfile.SYMTYPE, b"", 0o777)], [("other/file", tarfile.REGTYPE, b"x", 0o644)],
                 [("go/../escape", tarfile.REGTYPE, b"x", 0o644)])
        for index, members in enumerate(cases):
            with self.subTest(name=members[0][0]):
                path = self.tar_file(members)
                with self.assertRaises(build.BuildError):
                    build.extract_go_toolchain(path, self.root / ("go-" + str(index)))


class EnvironmentTests(TemporaryRoot):
    def test_environment_pins_target_and_drops_ambient_go_settings(self):
        environment = build.go_environment(self.root / "b", self.root / "b" / "go", base={
            "HOME": "/Users/fixture", "LANG": "tr_TR.UTF-8", "GOFLAGS": "-mod=mod", "GOPROXY": "direct", "GOARCH": "amd64",
            "CGO_ENABLED": "1", "GOFIPS140": "latest", "GOAMD64": "v3", "GOROOT_FINAL": "/fixture", "PATH": "/opt/homebrew/bin"})
        expected = {"GOOS": "darwin", "GOARCH": "arm64", "GOARM64": "v8.0", "CGO_ENABLED": "0", "GOTOOLCHAIN": "local",
                    "GOFLAGS": "", "GOPROXY": "https://proxy.golang.org", "GOSUMDB": "sum.golang.org", "GOVCS": "*:off",
                    "GOENV": "off", "GOWORK": "off", "HOME": str(self.root / "b" / "home"),
                    "GOTMPDIR": str(self.root / "b" / "tmp"), "GOCACHE": str(self.root / "b" / "gocache"), "LANG": "tr_TR.UTF-8"}
        for key, value in expected.items():
            self.assertEqual(environment[key], value, key)
        for key in ("GOFIPS140", "GOAMD64", "GOROOT_FINAL"):
            self.assertNotIn(key, environment)
        self.assertTrue(environment["PATH"].startswith(str(self.root / "b" / "go" / "bin") + os.pathsep))
        self.assertNotIn("/opt/homebrew/bin", environment["PATH"])


class PublishTests(TemporaryRoot):
    def setUp(self):
        super().setUp()
        self.engine = self.root / "artifacts" / "sing-box"
        self.engine.parent.mkdir()
        self.engine.write_bytes(b"engine-bytes")
        self.digest = digest(b"engine-bytes")
        self.output = self.root / "build" / "engine" / "sing-box"

    def test_new_output_is_a_complete_executable_copy(self):
        build.publish(self.engine, self.output, self.digest, root=self.root)
        self.assertEqual(self.output.read_bytes(), b"engine-bytes")
        self.assertTrue(os.access(self.output, os.X_OK))
        self.assertEqual(sorted(path.name for path in self.output.parent.iterdir()), ["sing-box"])

    def test_identical_existing_output_is_accepted(self):
        build.publish(self.engine, self.output, self.digest, root=self.root)
        build.publish(self.engine, self.output, self.digest, root=self.root)
        self.assertEqual(self.output.read_bytes(), b"engine-bytes")

    def test_different_existing_output_is_never_replaced(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"other-engine")
        with self.assertRaises(build.BuildError):
            build.publish(self.engine, self.output, self.digest, root=self.root)
        self.assertEqual(self.output.read_bytes(), b"other-engine")

    def test_symlinked_output_is_rejected(self):
        self.output.parent.mkdir(parents=True)
        elsewhere = self.root / "elsewhere"
        elsewhere.write_bytes(b"engine-bytes")
        self.output.symlink_to(elsewhere)
        with self.assertRaises(build.BuildError):
            build.publish(self.engine, self.output, self.digest, root=self.root)

    def test_digest_mismatch_leaves_no_output_or_partial_file(self):
        with self.assertRaises(build.BuildError):
            build.publish(self.engine, self.output, "0" * 64, root=self.root)
        self.assertEqual(list(self.output.parent.iterdir()), [])


class CodesignTests(unittest.TestCase):
    SAMPLE = ("Executable=/fixture/sing-box\nIdentifier=sing-box\nFormat=Mach-O thin (arm64)\n"
              "CodeDirectory v=20400 size=1 flags=0x20002(adhoc,linker-signed) hashes=1+0 location=embedded\n"
              "Hash type=sha256 size=32\nCandidateCDHash sha256=" + "ab" * 32 + "\nCDHash=" + "ab" * 20 + "\nSignature=adhoc\n")

    def test_cdhash_is_read_from_codesign_output(self):
        self.assertEqual(build.parse_cdhash(self.SAMPLE), "ab" * 20)

    def test_missing_cdhash_is_rejected(self):
        with self.assertRaises(build.BuildError):
            build.parse_cdhash("Signature=adhoc\n")


class RepositoryPinTests(unittest.TestCase):
    def test_shared_inputs_match_pins(self):
        manifest = build.load_overlay_manifest()
        build.require_locks(build.LOCK_MOD, build.LOCK_SUM)
        for record in manifest["files"]:
            self.assertEqual(build.sha256_file(REPO / record["payload_relative"]), record["after_sha256"], record["source_relative"])

    def test_pins_equal_the_windows_recipe(self):
        recipe = (REPO / "scripts" / "Build-SecurityEngine.ps1").read_text(encoding="utf-8")
        literals = ("$sourceCommit = '" + build.SOURCE_COMMIT + "'", "$sourceUrl = '" + build.SOURCE_URL + "'",
                    "$sourceSha = '" + build.SOURCE_SHA256.upper() + "'", "$goVersion = '" + build.GO_VERSION + "'",
                    "$engineVersion = '" + build.ENGINE_VERSION + "'",
                    "$patchManifestSha = '" + build.PATCH_MANIFEST_SHA256.upper() + "'",
                    "$lockModSha = '" + build.LOCK_MOD_SHA256.upper() + "'", "$lockSumSha = '" + build.LOCK_SUM_SHA256.upper() + "'",
                    "$buildTags = '" + build.BUILD_TAGS + "'",
                    "'-X github.com/sagernet/sing-box/constant.Version=' + $engineVersion + ' -checklinkname=0 -s -w -buildid='")
        for literal in literals:
            self.assertIn(literal, recipe)
        self.assertEqual(build.LINKER_FLAGS, "-X github.com/sagernet/sing-box/constant.Version=" + build.ENGINE_VERSION +
                         " -checklinkname=0 -s -w -buildid=")


class BuildRecordTests(unittest.TestCase):
    VALID = ["sing-box: go1.26.9", "\tpath\tgithub.com/sagernet/sing-box/cmd/sing-box",
             "\tmod\tgithub.com/sagernet/sing-box\t(devel)\t", "\tbuild\t-buildmode=exe", "\tbuild\t-compiler=gc",
             "\tbuild\t-tags=with_purego,badlinkname,tfogo_checklinkname0", "\tbuild\t-trimpath=true", "\tbuild\tCGO_ENABLED=0",
             "\tbuild\tGOARCH=arm64", "\tbuild\tGOOS=darwin", "\tbuild\tGOARM64=v8.0"]

    def test_pinned_record_is_accepted(self):
        build.require_build_record(list(self.VALID))

    def test_changed_target_tags_or_toolchain_is_rejected(self):
        changes = {"\tbuild\tGOOS=darwin": "\tbuild\tGOOS=linux", "\tbuild\tCGO_ENABLED=0": "\tbuild\tCGO_ENABLED=1",
                   "\tbuild\t-trimpath=true": None,
                   "\tbuild\t-tags=with_purego,badlinkname,tfogo_checklinkname0": "\tbuild\t-tags=with_purego",
                   "sing-box: go1.26.9": "sing-box: go1.26.8",
                   "\tpath\tgithub.com/sagernet/sing-box/cmd/sing-box": "\tpath\texample.com/other"}
        for old, new in changes.items():
            with self.subTest(old=old):
                lines = [new if line == old else line for line in self.VALID if not (line == old and new is None)]
                with self.assertRaises(build.BuildError):
                    build.require_build_record(lines)

    def test_extra_or_repeated_settings_are_rejected(self):
        position = self.VALID.index("\tbuild\tGOOS=darwin")
        # A repeated key must not let a later line overwrite an earlier, wrong one.
        repeated = self.VALID[:position] + ["\tbuild\tGOOS=linux"] + self.VALID[position:]
        for name, lines in (("extra", self.VALID + ["\tbuild\t-gcflags=all=-N"]), ("repeated", repeated)):
            with self.subTest(name), self.assertRaises(build.BuildError):
                build.require_build_record(lines)


class EngineIdentityTests(unittest.TestCase):
    @staticmethod
    def pinned() -> list:
        return [build.ENGINE_SHA256, build.ENGINE_BYTES, build.ENGINE_CDHASH]

    def test_exact_pinned_engine_is_accepted(self):
        build.require_engine_identity(*self.pinned())

    def test_any_differing_field_is_rejected_with_the_measured_values(self):
        for index, value in enumerate(("0" * 64, build.ENGINE_BYTES + 1, "0" * 40)):
            measured = self.pinned()
            measured[index] = value
            with self.subTest(field=index):
                with self.assertRaises(build.BuildError) as raised:
                    build.require_engine_identity(*measured)
                self.assertIn(str(value), str(raised.exception))

    def test_build_checks_the_identity_before_publishing(self):
        source = inspect.getsource(build.build)
        self.assertLess(source.index("require_engine_identity("), source.index("publish("))


class FetchTests(TemporaryRoot):
    def setUp(self):
        super().setUp()
        self.saved_work = build.WORK_ROOT
        build.WORK_ROOT = self.root / "work"

    def tearDown(self):
        build.WORK_ROOT = self.saved_work
        super().tearDown()

    def source(self, data: bytes) -> str:
        path = self.root / "source.bin"
        path.write_bytes(data)
        return path.as_uri()

    def test_verified_download_and_cache_reuse(self):
        data = b"archive-bytes"
        destination = self.root / "work" / "cache" / "archive.bin"
        self.assertEqual(build.fetch_verified(self.source(data), destination, digest(data), 1024), destination)
        self.assertEqual(destination.read_bytes(), data)
        (self.root / "source.bin").unlink()
        self.assertEqual(build.fetch_verified("file:///nonexistent/archive.bin", destination, digest(data), 1024), destination)

    def test_cached_file_with_wrong_hash_is_replaced(self):
        data = b"archive-bytes"
        destination = self.root / "work" / "cache" / "archive.bin"
        destination.parent.mkdir(parents=True)
        destination.write_bytes(b"stale")
        self.assertEqual(build.fetch_verified(self.source(data), destination, digest(data), 1024), destination)
        self.assertEqual(destination.read_bytes(), data)

    def test_oversized_or_mismatched_download_leaves_nothing(self):
        destination = self.root / "work" / "cache" / "archive.bin"
        for data, expected in ((b"x" * 2048, digest(b"x" * 2048)), (b"other", digest(b"archive"))):
            with self.subTest(size=len(data)), self.assertRaises(build.BuildError):
                build.fetch_verified(self.source(data), destination, expected, 1024)
            self.assertEqual(sorted(path.name for path in destination.parent.iterdir()), [])


class PinTests(unittest.TestCase):
    def test_engine_pins_match_the_swift_identity(self):
        swift = (MACOS / "Sources" / "DiscordAccessKit" / "Engine" / "EngineImage.swift").read_text(encoding="utf-8")
        matches = re.findall(r'static let pinned = EngineIdentity\(sha256: "([0-9a-f]{64})",\s*cdhash: "([0-9a-f]{40})"\)', swift)
        self.assertEqual(matches, [(build.ENGINE_SHA256, build.ENGINE_CDHASH)])


class MainTests(unittest.TestCase):
    def test_os_errors_are_reported_in_turkish(self):
        stream = io.StringIO()
        with mock.patch.object(build, "build", side_effect=OSError(2, "No such file or directory")), contextlib.redirect_stderr(stream):
            self.assertEqual(build.main([]), 1)
        self.assertTrue(stream.getvalue().startswith("HATA: "))
        self.assertNotIn("Traceback", stream.getvalue())


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `python3 -B macos/Tests/build-engine.test.py`
Expected: `Ran 35 tests` ve `FAILED (errors=18)`; `require_build_record`, `require_engine_identity`, yeni `fetch_verified` imzası ve sabitler henüz yok.

- [ ] **Adım 3: Betiği güncelle** (`python` bloğu 1; yardımcıyla, eski hash verilerek)

```python
#!/usr/bin/env python3
"""Build the pinned DiscordAccess sing-box engine for macOS arm64.

This mirrors scripts/Build-SecurityEngine.ps1 without changing it: the same
upstream commit, Go release, byte-pinned dependency locks, reviewed source
overlay, build tags and linker flags. Only GOOS/GOARCH and the Go archive for
this host differ. The script never runs sing-box and never edits system
settings. Downloads, caches, Go work files, Go's home/telemetry files and
outputs stay under macos/work and macos/build; only the patch tests themselves
may create short-lived files in the system temporary directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import urllib.request
import uuid
import zipfile
from pathlib import Path

MACOS_ROOT = Path(os.path.realpath(__file__)).parent.parent
REPO_ROOT = MACOS_ROOT.parent
WORK_ROOT = MACOS_ROOT / "work"
CACHE_ROOT = WORK_ROOT / "cache"
OUTPUT_ROOT = MACOS_ROOT / "build" / "engine"

SOURCE_COMMIT = "7054cac5124465ffdb145870d7c01885566711b1"
SOURCE_URL = "https://github.com/SagerNet/sing-box/archive/" + SOURCE_COMMIT + ".zip"
SOURCE_SHA256 = "cd8a3508f36d74ef7c9c515bdc8586f048fd06c22499d38ee3787faa7d220f74"
GO_VERSION = "go1.26.9"
GO_URL = "https://go.dev/dl/go1.26.9.darwin-arm64.tar.gz"
GO_SHA256 = "f9bb7c0a02506c5d9bf0d1eb1f7ee6c7684f844ae49558308a0427b830e022cc"
ENGINE_VERSION = "1.14.3-discordaccess.2"
PATCH_MANIFEST = REPO_ROOT / "engine-patches" / "http-limits" / "manifest.json"
PATCH_MANIFEST_SHA256 = "14f99d93af5f910bd5c00f0f536b8ae2e018dea910400043c821493c0569e367"
LOCK_MOD = REPO_ROOT / "engine-build" / "go.mod"
LOCK_SUM = REPO_ROOT / "engine-build" / "go.sum"
LOCK_MOD_SHA256 = "2c335df61e036819c4a0694e32748b4a3998c0faf898fc05bcc7c0213c27baf5"
LOCK_SUM_SHA256 = "c391d32564c5c66c7eb76fae8595129e234784b03a0e4100ecb762beec9a103e"
BUILD_TAGS = "with_purego,badlinkname,tfogo_checklinkname0"
LINKER_FLAGS = "-X github.com/sagernet/sing-box/constant.Version=" + ENGINE_VERSION + " -checklinkname=0 -s -w -buildid="
SOURCE_TEST_PACKAGES = ("./internal/discordaccess/httpguard", "./protocol/http", "./common/listener")
# Pinned after Aşama 0 reproduced two identical builds; must equal EngineIdentity.pinned in
# macos/Sources/DiscordAccessKit/Engine/EngineImage.swift (checked by the tests).
ENGINE_SHA256 = "013ba5d5055988953ebec1a1ac0eceb8aead52415e3ef186a5c7481083472cb0"
ENGINE_BYTES = 33315362
ENGINE_CDHASH = "344f8bd088ce068a1745cf16e7bb0c9a4bbbe99e"
SOURCE_MAX_BYTES = 64 * 1024 * 1024
GO_MAX_BYTES = 128 * 1024 * 1024
# `go version -m` omits -ldflags under -trimpath; everything else that shapes the target is recorded.
EXPECTED_BUILD_SETTINGS = {"-buildmode": "exe", "-compiler": "gc", "-tags": BUILD_TAGS, "-trimpath": "true",
                           "CGO_ENABLED": "0", "GOARCH": "arm64", "GOOS": "darwin", "GOARM64": "v8.0"}
CA_FILE = "/etc/ssl/cert.pem"
NAME_PATTERN = re.compile(r"\A[A-Za-z0-9_./-]+\Z")
DIGEST_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")


class BuildError(Exception):
    """A pinned input, archive, overlay or toolchain check failed."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_digest(path: Path, expected: str, label: str) -> None:
    if not path.is_file() or sha256_file(path) != expected:
        raise BuildError(label + " sabit SHA-256 ile eşleşmedi: " + str(path))


def require_locks(go_mod: Path, go_sum: Path) -> None:
    require_digest(go_mod, LOCK_MOD_SHA256, "go.mod kilidi")
    require_digest(go_sum, LOCK_SUM_SHA256, "go.sum kilidi")


def require_inside(path: Path, root: Path) -> Path:
    """Return path when it stays under root and no component below root is a symlink."""
    root = Path(os.path.realpath(root))
    full = Path(os.path.normpath(path if Path(path).is_absolute() else root / path))
    try:
        relative = full.relative_to(root)
    except ValueError:
        raise BuildError("Yol izin verilen klasörün dışına çıktı: " + str(full)) from None
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise BuildError("Yolda sembolik bağ var: " + str(current))
    return full


def _relative_member(name: str, prefix: str) -> str:
    if not name.startswith(prefix) or "\\" in name or ":" in name or "\x00" in name or name.startswith("/"):
        raise BuildError("Beklenmeyen arşiv yolu: " + name)
    relative = name[len(prefix):]
    if relative and any(part in ("", ".", "..") for part in relative.rstrip("/").split("/")):
        raise BuildError("Arşivde yol geçişi yasak: " + name)
    return relative


def extract_zip(archive: Path, destination: Path, prefix: str, max_bytes: int, max_entries: int = 40000) -> int:
    """Extract a verified source zip like the Windows recipe: links are written as plain files."""
    destination.mkdir(parents=True, exist_ok=True)
    destination = Path(os.path.realpath(destination))
    written = total = 0
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > max_entries:
            raise BuildError("Kaynak arşivi girdi sınırını aştı.")
        for entry in entries:
            relative = _relative_member(entry.filename, prefix)
            if not relative:
                continue
            total += entry.file_size
            if entry.file_size > 268435456 or total > max_bytes:
                raise BuildError("Kaynak arşivi boyut sınırını aştı.")
            target = require_inside(destination / relative.rstrip("/"), destination)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(entry) as data, open(target, "xb") as output:
                shutil.copyfileobj(data, output)
            written += 1
    return written


def extract_go_toolchain(archive: Path, destination: Path, max_bytes: int = 1073741824, max_entries: int = 40000) -> int:
    """Extract the pinned Go archive; only regular files and directories are accepted."""
    destination.mkdir(parents=True, exist_ok=True)
    destination = Path(os.path.realpath(destination))
    written = total = count = 0
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            count += 1
            if count > max_entries:
                raise BuildError("Araç zinciri arşivi girdi sınırını aştı.")
            if member.name == "go" and member.isdir():
                continue
            relative = _relative_member(member.name, "go/")
            if not relative:
                continue
            target = require_inside(destination / relative.rstrip("/"), destination)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise BuildError("Araç zinciri arşivinde normal dosya olmayan girdi: " + member.name)
            total += member.size
            if member.size > 268435456 or total > max_bytes:
                raise BuildError("Araç zinciri arşivi boyut sınırını aştı.")
            target.parent.mkdir(parents=True, exist_ok=True)
            data = source.extractfile(member)
            if data is None:
                raise BuildError("Araç zinciri dosyası okunamadı: " + member.name)
            with data, open(target, "xb") as output:
                shutil.copyfileobj(data, output)
            os.chmod(target, 0o755 if member.mode & 0o111 else 0o644)
            written += 1
    return written


def load_overlay_manifest(path: Path = PATCH_MANIFEST) -> dict:
    require_digest(path, PATCH_MANIFEST_SHA256, "Yama manifesti")
    manifest = json.loads(path.read_bytes())
    files = manifest.get("files")
    if (manifest.get("schema") != 1 or manifest.get("main_source_commit") != SOURCE_COMMIT or
            manifest.get("source_archive_sha256") != SOURCE_SHA256 or manifest.get("engine_version") != ENGINE_VERSION or
            not isinstance(files, list) or not 1 <= len(files) <= 16):
        raise BuildError("Yama manifestinin kimliği geçersiz.")
    return manifest


def apply_overlay(manifest: dict, repo_root: Path, source_root: Path) -> list:
    """Apply the reviewed exact-file overlay; every base and payload byte is hash checked first."""
    repo_root = Path(os.path.realpath(repo_root))
    source_root = Path(os.path.realpath(source_root))
    applied, seen = [], set()
    for record in manifest["files"]:
        name, after, size = record.get("source_relative"), record.get("after_sha256"), record.get("bytes")
        if (not isinstance(name, str) or not NAME_PATTERN.match(name) or name.startswith("/") or
                any(part in ("", ".", "..") for part in name.split("/")) or name in seen or
                record.get("payload_relative") != "engine-patches/http-limits/source/" + name or
                not isinstance(after, str) or not DIGEST_PATTERN.match(after) or
                type(size) is not int or not 1 <= size <= 1048576):
            raise BuildError("Yama yolu veya kimliği geçersiz: " + str(name))
        seen.add(name)
        target = require_inside(source_root / name, source_root)
        payload = require_inside(repo_root / record["payload_relative"], repo_root)
        before = record.get("before_sha256")
        if before is None:
            if os.path.lexists(target):
                raise BuildError("Eklenen yama dosyası upstream kaynakta zaten var: " + name)
        elif (not isinstance(before, str) or not DIGEST_PATTERN.match(before) or
              not target.is_file() or sha256_file(target) != before):
            raise BuildError("Yamanın temel kaynak baytları eşleşmedi: " + name)
        data = payload.read_bytes() if payload.is_file() else b""
        if len(data) != size or hashlib.sha256(data).hexdigest() != after:
            raise BuildError("Yama yükünün baytları eşleşmedi: " + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "wb") as output:
            output.write(data)
        if sha256_file(target) != after:
            raise BuildError("Uygulanan yama baytları eşleşmedi: " + name)
        applied.append(name)
    return applied


def go_environment(build_root: Path, go_root: Path, base: dict | None = None) -> dict:
    """Isolated, reproducible Go settings; ambient GO* variables never leak into the build."""
    inherited = dict(os.environ if base is None else base)
    environment = {key: value for key, value in inherited.items() if not key.startswith("GO") and key != "CGO_ENABLED"}
    environment.update({
        "GOENV": "off", "GOAUTH": "off", "GOROOT": str(go_root), "GOPATH": str(build_root / "gopath"),
        "GOCACHE": str(build_root / "gocache"), "GOMODCACHE": str(build_root / "modules"), "GOTOOLCHAIN": "local",
        "GOOS": "darwin", "GOARCH": "arm64", "GOARM64": "v8.0", "CGO_ENABLED": "0", "GOFLAGS": "", "GOEXPERIMENT": "",
        "GOWORK": "off", "GOPROXY": "https://proxy.golang.org", "GOSUMDB": "sum.golang.org", "GONOSUMDB": "",
        "GONOPROXY": "", "GOPRIVATE": "", "GOINSECURE": "", "GOVCS": "*:off", "GODEBUG": "",
        # Go keeps its config/telemetry under HOME and its work files under GOTMPDIR; both stay in the build root.
        "HOME": str(build_root / "home"), "GOTMPDIR": str(build_root / "tmp"),
    })
    environment["PATH"] = str(go_root / "bin") + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"
    return environment


def parse_cdhash(output: str) -> str:
    match = re.search(r"^CDHash=([0-9a-f]{40}|[0-9a-f]{64})$", output, re.MULTILINE)
    if match is None:
        raise BuildError("codesign çıktısında CDHash bulunamadı.")
    return match.group(1)


def require_build_record(lines: list) -> None:
    """The binary's own Go build record must show exactly the pinned toolchain, target and tags."""
    settings, repeated = {}, False
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) == 3 and fields[0] == "" and fields[1] == "build" and "=" in fields[2]:
            key, value = fields[2].split("=", 1)
            repeated = repeated or key in settings
            settings[key] = value
    if (repeated or not lines or not lines[0].endswith(": " + GO_VERSION) or
            "\tpath\tgithub.com/sagernet/sing-box/cmd/sing-box" not in lines or settings != EXPECTED_BUILD_SETTINGS):
        raise BuildError("Motorun Go derleme kaydı sabit araç zinciri, hedef veya etiketlerle eşleşmedi.")


def require_engine_identity(digest: str, size: int, cdhash: str, evidence: str = "") -> None:
    """Only the pinned engine is ever published: its SHA-256, size and cdhash must all match."""
    if (digest, size, cdhash) != (ENGINE_SHA256, ENGINE_BYTES, ENGINE_CDHASH):
        raise BuildError("Derlenen motor sabit SHA-256, boyut ve cdhash ile eşleşmedi; kopyalanmadı. Ölçülen: SHA-256 " + digest +
                         ", " + str(size) + " bayt, cdhash " + cdhash + "." + (" Kanıtlar: " + evidence if evidence else ""))


def read_cdhash(binary: Path) -> str:
    result = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(binary)], capture_output=True, text=True)
    if result.returncode != 0:
        raise BuildError("codesign motor imzasını okuyamadı: " + result.stderr.strip())
    return parse_cdhash(result.stderr + result.stdout)


def fetch_verified(url: str, destination: Path, expected: str, max_bytes: int) -> Path:
    destination = require_inside(destination, WORK_ROOT)
    if destination.is_file() and sha256_file(destination) == expected:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    for stale in (destination, partial):
        if os.path.lexists(stale):
            stale.unlink()
    context = ssl.create_default_context(cafile=CA_FILE)
    try:
        with urllib.request.urlopen(url, timeout=300, context=context) as response, open(partial, "xb") as output:
            received = 0
            for chunk in iter(lambda: response.read(1 << 20), b""):
                received += len(chunk)
                if received > max_bytes:
                    raise BuildError("İndirilen arşiv boyut sınırını aştı: " + url)
                output.write(chunk)
    except BaseException:
        if os.path.lexists(partial):
            partial.unlink()
        raise
    if sha256_file(partial) != expected:
        partial.unlink()
        raise BuildError("İndirilen arşiv sabit SHA-256 ile eşleşmedi: " + url)
    os.replace(partial, destination)
    return destination


def run_go(go: Path, arguments: list, environment: dict, cwd: Path) -> str:
    result = subprocess.run([str(go), *arguments], cwd=cwd, env=environment, capture_output=True, text=True)
    if result.returncode != 0:
        raise BuildError("Sabit Go komutu başarısız (çıkış " + str(result.returncode) + "): go " + " ".join(arguments) +
                         "\n" + result.stdout[-4000:] + result.stderr[-4000:])
    return result.stdout


def publish(engine: Path, output: Path, digest: str, root: Path = MACOS_ROOT) -> None:
    """Publish a verified engine: never overwrite a different file, follow a link or leave a partial file."""
    output = require_inside(output, root)
    if os.path.lexists(output):
        if output.is_symlink() or not output.is_file() or sha256_file(output) != digest:
            raise BuildError("Mevcut çıktı motoru farklı; üzerine yazılmadı. Yeni derleme: " + str(engine))
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output = require_inside(output, root)
    partial = output.with_name(".sing-box.partial-" + uuid.uuid4().hex)
    descriptor = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o755)
    try:
        with os.fdopen(descriptor, "wb") as target, open(engine, "rb") as source:
            shutil.copyfileobj(source, target)
        if sha256_file(partial) != digest:
            raise BuildError("Kopyalanan motor doğrulanamadı; yayımlanmadı.")
        try:
            os.link(partial, output)
        except FileExistsError:
            raise BuildError("Çıktı motoru derleme sırasında oluştu; üzerine yazılmadı.") from None
    finally:
        partial.unlink()


def build(run_source_tests: bool, output: Path | None) -> dict:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise BuildError("Bu hedef macOS arm64 gerektirir.")
    require_locks(LOCK_MOD, LOCK_SUM)
    manifest = load_overlay_manifest()
    if output is not None:
        output = require_inside(output, MACOS_ROOT)
        if output.name != "sing-box" or not (output.parent == OUTPUT_ROOT or WORK_ROOT in output.parents):
            raise BuildError("--out yalnız macos/build/engine/sing-box veya macos/work altında bir sing-box yolu olabilir.")
        if output.is_dir():
            raise BuildError("Çıktı yolu bir klasör; değiştirilmedi.")
    build_root = require_inside(WORK_ROOT / ("engine-build-" + uuid.uuid4().hex), WORK_ROOT)
    build_root.mkdir(parents=True)
    for folder in ("home", "tmp"):
        (build_root / folder).mkdir()
    source_root, go_root, artifacts = build_root / "source", build_root / "go", build_root / "artifacts"
    artifacts.mkdir()
    source_zip = fetch_verified(SOURCE_URL, CACHE_ROOT / ("sing-box-" + SOURCE_COMMIT + ".zip"), SOURCE_SHA256, SOURCE_MAX_BYTES)
    go_archive = fetch_verified(GO_URL, CACHE_ROOT / "go1.26.9.darwin-arm64.tar.gz", GO_SHA256, GO_MAX_BYTES)
    extract_zip(source_zip, source_root, "sing-box-" + SOURCE_COMMIT + "/", 268435456)
    applied = apply_overlay(manifest, REPO_ROOT, source_root)
    extract_go_toolchain(go_archive, go_root)
    go = go_root / "bin" / "go"
    if not go.is_file():
        raise BuildError("Sabit Go çalıştırılabilir dosyası doğrulanmış arşivde yok.")
    shutil.copyfile(source_root / "go.mod", artifacts / "upstream-go.mod")
    shutil.copyfile(source_root / "go.sum", artifacts / "upstream-go.sum")
    shutil.copyfile(LOCK_MOD, source_root / "go.mod")
    shutil.copyfile(LOCK_SUM, source_root / "go.sum")
    require_locks(source_root / "go.mod", source_root / "go.sum")
    environment = go_environment(build_root, go_root)
    toolchain = run_go(go, ["version"], environment, source_root).strip()
    if toolchain != "go version " + GO_VERSION + " darwin/arm64":
        raise BuildError("Sabit araç zinciri kimliği eşleşmedi: " + toolchain)
    run_go(go, ["mod", "download"], environment, source_root)
    run_go(go, ["mod", "verify"], environment, source_root)
    require_locks(source_root / "go.mod", source_root / "go.sum")
    if run_source_tests:
        report = run_go(go, ["test", "-mod=readonly", "-count=1", "-tags=" + BUILD_TAGS, "-ldflags=-checklinkname=0",
                             "-timeout=60s", *SOURCE_TEST_PACKAGES], environment, source_root)
        (artifacts / "source-unit-tests.txt").write_text(report, encoding="utf-8")
    modules = run_go(go, ["list", "-mod=readonly", "-m", "all"], environment, source_root)
    (artifacts / "selected-modules.txt").write_text(modules, encoding="utf-8")
    packages = run_go(go, ["list", "-mod=readonly", "-tags=" + BUILD_TAGS, "-deps", "./cmd/sing-box"], environment, source_root)
    (artifacts / "compiled-packages.txt").write_text(packages, encoding="utf-8")
    if any(line == "golang.org/x/crypto/openpgp" or line.startswith("golang.org/x/crypto/openpgp/") for line in packages.splitlines()):
        raise BuildError("Bakımı bırakılmış OpenPGP paketi bu hedefe derlenmemeli.")
    engine = artifacts / "sing-box"
    run_go(go, ["build", "-trimpath", "-buildvcs=false", "-mod=readonly", "-tags=" + BUILD_TAGS, "-ldflags=" + LINKER_FLAGS,
                "-o", str(engine), "./cmd/sing-box"], environment, source_root)
    require_locks(source_root / "go.mod", source_root / "go.sum")
    digest, size, cdhash = sha256_file(engine), engine.stat().st_size, read_cdhash(engine)
    build_info = run_go(go, ["version", "-m", str(engine)], environment, source_root).splitlines()
    # Written before the checks as evidence; the first line names the output path, so only the file name is kept.
    record = ["sing-box:" + line.rsplit(":", 1)[-1] if index == 0 else line for index, line in enumerate(build_info)]
    (artifacts / "go-version-m.txt").write_text("\n".join(record) + "\n", encoding="utf-8")
    require_build_record(build_info)
    require_engine_identity(digest, size, cdhash, str(artifacts))
    metadata = {
        "schema": 1, "target": "darwin/arm64", "engine_version": ENGINE_VERSION, "engine_sha256": digest,
        "engine_bytes": size, "engine_cdhash": cdhash, "engine_pin_enforced": True,
        "go_version": GO_VERSION, "go_archive_url": GO_URL, "go_archive_sha256": GO_SHA256,
        "main_source_commit": SOURCE_COMMIT, "source_archive_url": SOURCE_URL, "source_archive_sha256": SOURCE_SHA256,
        "main_source_patch_sha256": PATCH_MANIFEST_SHA256, "patched_files": applied,
        "lock_go_mod_sha256": LOCK_MOD_SHA256, "lock_go_sum_sha256": LOCK_SUM_SHA256,
        "build_tags": BUILD_TAGS, "linker_flags": LINKER_FLAGS, "source_unit_tests_ran": run_source_tests,
        "build_script_sha256": sha256_file(Path(os.path.realpath(__file__))), "engine_executed": False,
    }
    (artifacts / "build-metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    sums = "".join(sha256_file(path) + "  " + path.name + "\n"
                   for path in sorted(artifacts.iterdir()) if path.is_file() and path.name != "SHA256SUMS.txt")
    (artifacts / "SHA256SUMS.txt").write_text(sums, encoding="ascii")
    if output is not None:
        publish(engine, output, digest)
    metadata["artifacts"] = str(artifacts)
    return metadata


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description="DiscordAccess motorunu macOS arm64 için sabit girdilerle derler; motoru çalıştırmaz.")
    parser.add_argument("--run-source-tests", action="store_true", help="Yamaların Go testlerini de çalıştır")
    parser.add_argument("--out", type=Path, help="macos/build/engine/sing-box (verilmezse yalnız kanıt klasörüne derlenir)")
    args = parser.parse_args(argv)
    try:
        result = build(args.run_source_tests, Path(os.path.abspath(args.out)) if args.out else None)
    except BuildError as error:
        print("HATA: " + str(error), file=sys.stderr)
        return 1
    except OSError as error:
        print("HATA: Dosya veya ağ işlemi başarısız oldu (" + type(error).__name__ + "): " + str(error)[:300], file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `python3 -B macos/Tests/build-engine.test.py`
Expected: `Ran 35 tests` ve `OK`.

- [ ] **Adım 5: Sabitlenmiş derlemeyi uçtan uca çalıştır** (yaklaşık 40 saniye)

Run: `python3 -B macos/scripts/build-engine.py --out macos/build/engine/sing-box`
Expected: Sıfır çıkış kodu ve JSON çıktısı:
- `"engine_pin_enforced": true`
- `"engine_sha256": "013ba5d5055988953ebec1a1ac0eceb8aead52415e3ef186a5c7481083472cb0"`
- `"engine_bytes": 33315362`
- `"engine_cdhash": "344f8bd088ce068a1745cf16e7bb0c9a4bbbe99e"`

Mevcut `macos/build/engine/sing-box` aynı olduğu için yayımlama onu kabul eder. Derleme Go modüllerini `proxy.golang.org` üzerinden indirir; ağ erişimi gerekir. Kaynak ve Go arşivleri `macos/work/cache` önbelleğinden gelir.

Ardından büyük ara dosyalar Çöp Kutusu'na taşınır. Kalıcı silme yapılmaz; Çöp Kutusu'nu boşaltmak kullanıcıya kalır. `artifacts` klasörü kanıt olarak yerinde kalır:

```bash
for d in macos/work/engine-build-*; do t="$HOME/.Trash/$(basename "$d")-intermediates"; chmod -R u+w "$d/modules" "$d/gopath" 2>/dev/null; for s in go gopath gocache modules source home tmp; do if [ -e "$d/$s" ]; then mkdir -p "$t" && mv "$d/$s" "$t/"; fi; done; done
```

---

### Görev 7: Son doğrulama ve teslim

- [ ] **Adım 1: Bütün testler**

Run: `swift test --package-path macos && python3 -B macos/Tests/build-engine.test.py`
Expected: `✔ Test run with 27 tests in 6 suites passed`, ardından `Ran 35 tests` ve `OK`. Swift çıktısında `skipped` geçmez.

- [ ] **Adım 2: Tasarım belgesine durum notu**

`macos/docs/2026-10-14-macos-tasarim.md` Bölüm 11'de **Aşama 1** başlığının altına şu satır eklenir:

`- **1a durumu:** Tamamlandı (motor katmanı ve derleme betiği sabitleri). Plan: macos/docs/plans/2026-10-14-asama-1a-motor-katmani.md.`

- [ ] **Adım 3: Git durumu ve commit sorusu**

Run: `git status --porcelain --untracked-files=all; git diff --name-only main`
Expected: `git diff` boş; durum yalnız `macos/` altındaki dosyaları gösterir.

Kullanıcıya değişen dosyalar, yapılan ve yapılmayan kontroller raporlanır, commit isteyip istemediği sorulur. İsterse:

```bash
git add macos/.gitignore macos/Package.swift macos/Sources macos/Tests macos/docs macos/scripts/build-engine.py
git commit -m "feat(macos): add DiscordAccessKit engine layer and pin the macOS engine"
```

---

## Sonradan değişenler (Aşama 1b)

- `EngineProcessTests.swift`: motor kopyasını çalıştıran testler, kopyaları artık `macos/build/test-engines/` altında kalıcı tutar. Sebep: macOS çalıştırılan her yeni dosyayı `syspolicyd` ile arka planda tarar. Testler kopyayı çalıştırıp hemen sildiği için `syspolicyd` tarama sırasında çöktü: 16:31–17:56 arasında 18 kez, 18:24'te bu testler 1b'nin Görev 1 adımında bir kez daha çalışınca 19. kez. macOS da yeniden başlatmayı üstel gecikmeyle erteledi.
- `TestSupport.swift`, `ProcessInspectorTests.swift` ve `ProcessInspector.swift` 1b'de genişletildi. Bu plandaki bloklar 1a'nın tarihsel halidir; güncel hash'ler 1b planındadır.
