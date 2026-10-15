# Aşama 1d — Bağlantı Tanısı ve Otomatik DNS Seçimi Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Hedef:** Oturumun DNS sağlayıcısını otomatik seçmek ve Discord'a erişimi kapı üzerinden denetlemek (Windows `DnsOptions`, `DnsSelection`, `DnsConnection`, `ConnectivityChecks`, `GatewayChecks`):

- `--dns=…` ve `--dns-record-fragment` seçenekleri
- her aday için motor ve kapı; Discord Gateway API'siyle denetim; başarısız adayın tamamen kapatılması
- "Bağlantıyı kontrol et" için HTTPS ve anonim Gateway WebSocket HELLO denetimleri

**Mimari:**
- `DnsOptions`, komut satırındaki DNS seçeneklerini okur ve aday sırasını verir (cloudflare-ip → cloudflare → google).
- `ConnectivityProbe` ve `GatewayHello`, URLSession'la yalnız oturum kapısı üzerinden bağlanır. Sistem proxy'si ya da doğrudan bağlantı yoktur. Yönlendirme izlenmez, durum tutulmaz, kimlik bilgisi sunulmaz ve başlık değerleri sabittir. Yanıt 16 KiB, her istek 10 sn ile sınırlıdır. Hatalar yalnız sabit kategorilerle döner (`ConnectivityFailure`, `GatewayHelloFailure`).
- `DnsSelection`, adayları sırayla açar, otomatik kipte denetler, başarısızı sıradaki açılmadan önce kapatır. `DnsConnection` bir adayın motoru ve kapısıdır; kapının kendini kapattığını sonradan ayarlanan bir işleyiciye iletir.
- `Cancellation`, seçimi, başlayan motorun beklenmesini ve süren isteği iptal eder.
- Bütün testler makinede kalır: denetimler `.invalid` adlı hedeflerle yerel sahte proxy'lere gider. Canlı denetim ayrı bir derleme bayrağıyla açılır (Görev 7).

**Teknolojiler:** Swift 6.4 (Swift 5 dil modu), SwiftPM, Swift Testing, Foundation URLSession (`URLSessionDataTask`, `URLSessionWebSocketTask`), CryptoKit (yalnız testlerde, WebSocket el sıkışması için).

---

## Aşama 1 alt planları

| Alt plan | Kapsam |
| --- | --- |
| 1a | Tamamlandı: paket iskeleti, motor yapılandırması, motor doğrulama ve başlatma, yetim motor temizliği, derleme betiği sabitleri |
| 1b | Tamamlandı: kapı istek politikası ve eş kimliği |
| 1c | Tamamlandı: kapının ağ katmanı |
| **1d** | Bağlantı tanısı (Gateway HELLO) ve otomatik DNS seçimi (bu plan) |
| 1e | Güncelleme köprüsü (manifest ve yönlendirme yeniden yazma, indirmeler) |
| 1f | Discord kurulumu ve profil değişiklikleri: günlük, tüm çekirdek nesilleri, gömülü kanca, Tam Disk Erişimi |
| 1g | Terminal modu (Q/T/D/A) ile uçtan uca birleştirme |

Tasarımdaki kararlar `macos/docs/2026-10-14-macos-tasarim.md` içindedir: 7.1 (DNS seçimi), 8 ("Bağlantı tanısı"), 9 ("DNS") ve 12.

## Yürütme notları

- Tüm komutlar depo kökünden (`/Users/alpertekin/Documents/GitHub/DiscordAccess`), `feature/macos` dalında çalıştırılır.
- `macos/` dışında hiçbir dosya değişmez. Commit yalnız kullanıcının açık isteğiyle yapılır.
- Bütün macOS testleri `macos/Tests/` altındadır. Küçük harfli `tests/` klasörü açılmaz.
- Kod blokları geçici klasörde derlendi; tam takım ve canlı denetim geçti. Kod elle yeniden yazılmaz; aşağıdaki yardımcıyla hash doğrulanarak çıkarılır.
- Önceki aşamaların üç dosyası tamamen değiştirilir; yardımcıya 1c'deki hash'leri verilir: `KitError.swift` Görev 1'de, `EngineProcess.swift` ve `ProxyGate.swift` Görev 6'da. Diğer bütün dosyalar yenidir.
- URLSession davranışı bu Mac'te ölçüldü:
  - Proxy bağlantısı bu süreçte BSD soketi olarak görünür; kapının eş kabulü onu tanır.
  - Reddedilen proxy hemen 306 (düz HTTP) ya da 310 (HTTPS, WebSocket) hatası verir; doğrudan bağlantıya düşmez. Kapının 403'ü de 310 olarak görünür.
  - `discord.com` ve `discord.gg` HSTS önyükleme listesindedir; düz `http` ve `ws` istekleri de tünellenir. Testler bu yüzden `.invalid` adlarla düz HTTP kullanır. `URLRequest`'le kurulan düz `ws` isteği proxy'ye `GET ws://…` biçiminde, `Upgrade` başlığıyla gider.
  - URLSession kendiliğinden `Pragma: no-cache` ekler; değer verilmezse bu Mac'in dil listesini ve kendi tarayıcı adını da ekler.
  - 401 yanıtında kimlik doğrulama isteği reddedilirse (`rejectProtectionSpace`) CFNetwork isteği bir kez kimlik bilgisi olmadan yineler, sonra 401'i teslim eder. İsteği iptal etmek (`cancelAuthenticationChallenge`) ise denetimi -999 iptaliyle bitirirdi; seçim bunu ölümcül sayardı.
- Testler boş port varsaymaz. Reddedilen proxy testleri, sistemin dağıttığı aralığın (49152–65535) dışında boş bir port arar: HTTPS denetimi 23000–23199, WebSocket denetimi 23200–23399 arasında.
- Motor testleri 1b'den beri kalıcı motor kopyalarını kullanır (`macos/build/test-engines/`); çalıştırılan dosya silinmez (`syspolicyd`). Testlerin başlattığı motorlar dışarıya bağlanmaz: gerçek motorun önündeki kapıdan geçirilen tek istek `example.com` içindir ve kapının politikası onu motora ulaşmadan reddeder. `discord.com` isteğini kapıdan geçiren test (Görev 3) motorun yerine yerel bir sahte motor kullanır.
- Swift'te "kırmızı" durum derleme hatasıdır.

## Dosya yapısı

| Dosya | Sorumluluk | SHA-256 |
| --- | --- | --- |
| `macos/Sources/DiscordAccessKit/KitError.swift` | Değişir: DNS-E01..E03 ve ENG-E02 | `5555ba77aa65efee3e7320818e6c62e0052ff9446192fea11ee6a01d3d90c86c` |
| `macos/Sources/DiscordAccessKit/Engine/DnsOptions.swift` | Yeni: DNS seçenekleri, aday sırası, açıklamalar | `39ad709f46289cf9d7f648d69bbf9cd6fe297a3034f15af12655b92ae852e092` |
| `macos/Sources/DiscordAccessKit/Engine/EngineProcess.swift` | Değişir: motor başlarken iptal | `53b552842e236e05320446d214283c488971e5835a660c9d822804454eb6251c` |
| `macos/Sources/DiscordAccessKit/Gate/ProxyGate.swift` | Değişir: `faulted` testler için modül içinde görünür | `0f74b158ac91a54bbdc2f56cee2c2c83e09e96ea4690a4cef5517f778878ddd8` |
| `macos/Sources/DiscordAccessKit/Connectivity/Cancellation.swift` | Yeni: iptal sinyali | `e5b8357a44d3cb4b7c1ac136199bb59b6b3842f126e7dbf8468ba7b15cc844eb` |
| `macos/Sources/DiscordAccessKit/Connectivity/ConnectivityFailure.swift` | Yeni: bağlantı hatalarının sabit kategorileri ve iletileri | `32558aa018edae2cc78fe526eed8c8d62ae19493d11059995556ac869e839247` |
| `macos/Sources/DiscordAccessKit/Connectivity/ConnectivityProbe.swift` | Yeni: kapı üzerinden HTTPS denetimleri | `303eff6a979affa385e620bcf74a71cdc5763b5cb034401d90de66d03dde4851` |
| `macos/Sources/DiscordAccessKit/Connectivity/GatewayHello.swift` | Yeni: anonim Gateway WebSocket HELLO denetimi | `3111d4668144883bb90b5565bbdc2e31beaaf8a91513cc401de92d9a8ed10769` |
| `macos/Sources/DiscordAccessKit/Connectivity/DnsSelection.swift` | Yeni: aday arayüzü ve seçim | `b229c62c6b5969d2a1db66ba79946e30aab589031d62648f37fc888a06875622` |
| `macos/Sources/DiscordAccessKit/Connectivity/DnsConnection.swift` | Yeni: bir adayın motoru ve kapısı | `83dc166989de5558d50fdbacc4ae9ce5ea14d05d0a80bfeb0f571b28fe4cc3da` |
| `macos/Tests/DiscordAccessKitTests/DnsOptionsTests.swift` | Yeni: seçenek vektörleri ve hata kodları | `f35daeb77850165ebf54e11c9b84d80100ef4abf9ee5a1c9dc3ee8b98245f2d1` |
| `macos/Tests/DiscordAccessKitTests/CancellationTests.swift` | Yeni: iptal sinyali | `ea26762dfa3ad9b9bb9322656477d740bb91779a301fad06fa4ed4e2f259327a` |
| `macos/Tests/DiscordAccessKitTests/ConnectivityFailureTests.swift` | Yeni: iletiler ve hata sınıflandırması | `973d38a880aca1d6b91d0e3ca3fe9541278805f82fdc4e05c5ba65df8e760536` |
| `macos/Tests/DiscordAccessKitTests/ConnectivityProbeTests.swift` | Yeni: yerel sahte proxy ile HTTPS denetimleri | `854e2ebf8ffa9b00a65a8ff3f49eea6965d7ae4398d5624825c85506a30fba79` |
| `macos/Tests/DiscordAccessKitTests/GatewayHelloTests.swift` | Yeni: yerel sahte WebSocket sunucusuyla HELLO denetimi | `5fe50668b0fa5d861a3860f2b6056783ac20ebf2a7613de5d2673445d1365662` |
| `macos/Tests/DiscordAccessKitTests/DnsSelectionTests.swift` | Yeni: Windows senaryolarıyla seçim | `f84a654d12a3efa08bfed2946d08966830bcf73e00f332b930d11ad94ff81878` |
| `macos/Tests/DiscordAccessKitTests/DnsConnectionTests.swift` | Yeni: gerçek motor ve kapıyla aday; başlayan motorun iptali | `2d08198b514da2d8cf9640f3b0e3b2f17ae986cf2003ca32a7ae0de56a375a0f` |
| `macos/Tests/DiscordAccessKitTests/LiveConnectivityTests.swift` | Yeni: derleme bayrağıyla açılan canlı denetim | `16a77abaabedcc35476b79d9e296eb79a85a9c04abb79d740abed32cbbeb198d` |

Plandan dosya çıkarma yardımcısı. `LANG` kod bloğu dilidir, `INDEX` o dildeki 0 tabanlı sıradır. Yardımcı hash doğrular; yeni dosyada var olanın üzerine yazmaz, değiştirilen dosyada eski hash'i ister.

```bash
python3 -I - macos/docs/plans/2026-10-15-asama-1d-baglanti-tanisi-ve-dns-secimi.md LANG INDEX TARGET EXPECTED_SHA256 OLD_SHA256_OR_NONE <<'EOF'
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

### Görev 1: DNS seçenekleri ve hata kodları

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/DnsOptionsTests.swift`, `macos/Sources/DiscordAccessKit/Engine/DnsOptions.swift`
- Modify: `macos/Sources/DiscordAccessKit/KitError.swift` (tam dosya; eski SHA-256 `c930e4cf21983b1a3c0f3eaab466aa8c17f20c1290c969913f97943d728b3b51`)

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 0)

Vektörler Windows'taki `DnsOptions` ve `DnsSelection.RunOfflineChecks`'ten alınmıştır:
- varsayılan otomatik seçim ve aday sırası;
- adı verilen sağlayıcı ve açıklaması;
- kayıt parçalama seçeneğinin her adaya geçmesi;
- geçersiz ya da tekrarlanan seçenekler (`--DNS=google` ve `--dns=Google` dahil);
- diğer argümanların başka ayrıştırıcılara bırakılması;
- yeni hata kodlarının iletileri.

```swift
import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows `DnsSelection.RunOfflineChecks` and `DnsOptions`.
@Suite struct DnsOptionsTests {
    @Test func selectsAutomaticallyInTheWindowsOrderByDefault() throws {
        let options = try DnsOptions.parse([])
        #expect(options == .automatic && options.isAutomatic && !options.recordFragment)
        #expect(options.candidates.map(\.name) == [.cloudflareIP, .cloudflare, .google])
        #expect(options.candidates.allSatisfy { !$0.recordFragment })
        #expect(options.description == "Otomatik seçim DoH | DNS TLS kayıt parçalama: kapalı")
        #expect(try DnsOptions.parse(["--dns=auto"]) == .automatic)
    }

    @Test(arguments: [("cloudflare", DnsProvider.Name.cloudflare, "Cloudflare DoH"), ("cloudflare-ip", .cloudflareIP, "Cloudflare (IP sertifikası) DoH"),
                      ("google", .google, "Google DoH")])
    func usesOnlyTheProviderNamed(argument: String, name: DnsProvider.Name, label: String) throws {
        let options = try DnsOptions.parse(["--dns=" + argument])
        #expect(!options.isAutomatic && options.provider == name)
        #expect(options.candidates == [DnsProvider(name)])
        #expect(options.description == label + " | DNS TLS kayıt parçalama: kapalı")
        let fragmented = try DnsOptions.parse(["--dns-record-fragment", "--dns=" + argument])
        #expect(fragmented.candidates == [DnsProvider(name, recordFragment: true)])
        #expect(fragmented.description == label + " | DNS TLS kayıt parçalama: açık")
    }

    @Test func keepsTheFragmentOptionForEveryAutomaticCandidate() throws {
        let options = try DnsOptions.parse(["--dns=auto", "--dns-record-fragment"])
        #expect(options.isAutomatic && options.recordFragment)
        #expect(options.candidates.count == 3 && options.candidates.allSatisfy(\.recordFragment))
        #expect(options.description == "Otomatik seçim DoH | DNS TLS kayıt parçalama: açık")
    }

    @Test(arguments: [["--dns=auto", "--dns=google"], ["--dns=auto", "--dns=auto"], ["--dns=google", "--dns=cloudflare"],
                      ["--dns-record-fragment", "--dns-record-fragment"], ["--dns=quad9"], ["--DNS=google"], ["--dns"], ["--dnsx"],
                      ["--dns=Google"], ["--dns-record-fragment=1"], ["--Dns-record-fragment"], ["--dns= google"]])
    func refusesAnUnknownOrRepeatedDnsOption(arguments: [String]) {
        #expect(throws: KitError.invalidDnsOption()) { try DnsOptions.parse(arguments) }
    }

    @Test func leavesOtherArgumentsToTheirParsers() throws {
        #expect(try DnsOptions.parse(["--console", "--dns=google", "-x", "dns"]) == DnsOptions(provider: .google))
        for argument in ["--dns=auto", "--dns=cloudflare", "--dns=cloudflare-ip", "--dns=google", "--dns-record-fragment"] {
            #expect(DnsOptions.isArgument(argument))
        }
        for argument in ["--DNS=google", "--dns=quad9", "--dns", "--console", ""] {
            #expect(!DnsOptions.isArgument(argument))
        }
    }

    @Test func namesItsErrorsWithFixedCodes() {
        #expect(KitError.invalidDnsOption().description == "[DNS-E01] DNS seçeneği geçersiz veya tekrarlanmış. --dns=auto, --dns=cloudflare, " +
            "--dns=cloudflare-ip ya da --dns=google seçin; gerekirse bir kez --dns-record-fragment ekleyin.")
        #expect(KitError.dnsSelectionFailed().description ==
            "[DNS-E02] Discord'a erişebilen bir DNS bağlantısı bulunamadı. İnternet bağlantısını kontrol edip yeniden bağlanın.")
        #expect(KitError.dnsCandidateNotClosed().description == "[DNS-E03] DNS bağlantısı güvenli biçimde kapatılamadı; başka bir aday başlatılmadı.")
        #expect(KitError.engineStopped().description == "[ENG-E02] Bağlantı motoru durdu.")
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'DnsOptions' in scope` ve `type 'KitError' has no member 'invalidDnsOption'` (aynı biçimde `dnsSelectionFailed`, `dnsCandidateNotClosed` ve `engineStopped` için). Tür henüz olmadığı için `cannot infer key path type from context; consider explicitly specifying a root type` ve `reference to member 'cloudflare' cannot be resolved without a contextual type` (ayrıca `cloudflareIP` ve `google` için) hataları da görülür; tür tanımlanınca kaybolur.

- [ ] **Adım 3: Hata kodlarını ekle** (`swift` bloğu 1; yardımcıyla, eski hash verilerek)

Yeni kodlar:
- `ENG-E02`: denetim sırasında duran motor;
- `DNS-E01`: geçersiz ya da tekrarlanan seçenek (Windows iletisi);
- `DNS-E02`: bütün adaylar başarısız (Windows `DnsSelectionException`); yalnız bu sabit ileti gösterilir, macOS menüsündeki "Yeniden bağlan" önerilir;
- `DNS-E03`: aday güvenle kapatılamadı, başka aday başlatılmadı (Windows `DnsConnection.Dispose`).

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

    static func engineStopped() -> KitError {
        KitError(code: "ENG-E02", message: "Bağlantı motoru durdu.")
    }

    static func invalidDnsOption() -> KitError {
        KitError(code: "DNS-E01", message: "DNS seçeneği geçersiz veya tekrarlanmış. --dns=auto, --dns=cloudflare, --dns=cloudflare-ip ya da " +
            "--dns=google seçin; gerekirse bir kez --dns-record-fragment ekleyin.")
    }

    /// Every candidate failed its check; only this fixed message is shown (Windows `DnsSelectionException`).
    static func dnsSelectionFailed() -> KitError {
        KitError(code: "DNS-E02", message: "Discord'a erişebilen bir DNS bağlantısı bulunamadı. İnternet bağlantısını kontrol edip yeniden bağlanın.")
    }

    static func dnsCandidateNotClosed() -> KitError {
        KitError(code: "DNS-E03", message: "DNS bağlantısı güvenli biçimde kapatılamadı; başka bir aday başlatılmadı.")
    }

    static func randomUnavailable() -> KitError {
        KitError(code: "SYS-E01", message: "Güvenli rastgele değer üretilemedi.")
    }
}
```

- [ ] **Adım 4: DNS seçeneklerini yaz** (`swift` bloğu 2)

`DnsOptions`, Windows `DnsOptions.Parse`'ın kurallarını izler: sağlayıcı ve parçalama seçeneği en fazla birer kez verilir; `--dns` ile başlayan başka her argüman (harf düzeni ne olursa olsun) reddedilir. `provider == nil` otomatik seçimdir. Aday sırası 1a'nın `DnsProvider.automaticCandidates`'idir. Açıklamalar Windows'takiyle aynıdır.

```swift
/// The DNS choice of a session (Windows `DnsOptions`): automatic selection, or the one provider the user named. The
/// chosen provider stays fixed for the session; the system's DNS settings are never changed.
public struct DnsOptions: Equatable, Sendable, CustomStringConvertible {
    /// The provider the user named; nil selects one automatically.
    public let provider: DnsProvider.Name?
    public let recordFragment: Bool

    public init(provider: DnsProvider.Name? = nil, recordFragment: Bool = false) {
        self.provider = provider
        self.recordFragment = recordFragment
    }

    public static let automatic = DnsOptions()

    public var isAutomatic: Bool { provider == nil }

    /// The providers to try, in order: the automatic order, or the one provider named.
    public var candidates: [DnsProvider] {
        guard let provider else { return DnsProvider.automaticCandidates(recordFragment: recordFragment) }
        return [DnsProvider(provider, recordFragment: recordFragment)]
    }

    /// For logs (Windows `Description`).
    public var description: String {
        guard let provider else { return "Otomatik seçim DoH | DNS TLS kayıt parçalama: " + (recordFragment ? "açık" : "kapalı") }
        return DnsProvider(provider, recordFragment: recordFragment).description
    }

    /// The DNS options among command-line arguments (Windows `Parse`): `--dns=auto`, `--dns=cloudflare`,
    /// `--dns=cloudflare-ip` or `--dns=google` at most once, and `--dns-record-fragment` at most once. Any other argument
    /// that starts with `--dns`, in any letter case, is refused (DNS-E01); other arguments are left to their own parsers.
    public static func parse(_ arguments: [String]) throws -> DnsOptions {
        var provider: DnsProvider.Name?
        var providerSet = false, fragment = false
        for argument in arguments {
            if argument == "--dns=auto" || DnsProvider.Name.allCases.contains(where: { argument == "--dns=" + $0.rawValue }) {
                guard !providerSet else { throw KitError.invalidDnsOption() }
                // "auto" names no provider.
                provider = DnsProvider.Name(rawValue: String(argument.dropFirst("--dns=".count)))
                providerSet = true
            } else if argument == "--dns-record-fragment" {
                guard !fragment else { throw KitError.invalidDnsOption() }
                fragment = true
            } else if argument.lowercased().hasPrefix("--dns") {
                throw KitError.invalidDnsOption()
            }
        }
        return DnsOptions(provider: provider, recordFragment: fragment)
    }

    /// Whether `argument` is one of the DNS options that `parse` accepts (Windows `IsArgument`).
    public static func isArgument(_ argument: String) -> Bool {
        argument == "--dns=auto" || argument == "--dns-record-fragment" || DnsProvider.Name.allCases.contains { argument == "--dns=" + $0.rawValue }
    }
}

extension DnsProvider: CustomStringConvertible {
    /// For logs (Windows `DnsOptions.Description` of a resolved provider).
    public var description: String {
        let label: String
        switch name {
        case .google: label = "Google"
        case .cloudflareIP: label = "Cloudflare (IP sertifikası)"
        case .cloudflare: label = "Cloudflare"
        }
        return label + " DoH | DNS TLS kayıt parçalama: " + (recordFragment ? "açık" : "kapalı")
    }
}
```

- [ ] **Adım 5: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 96 tests in 14 suites passed`, uyarısız ve `skipped` olmadan.

---

### Görev 2: İptal ve bağlantı hataları

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/CancellationTests.swift`, `macos/Tests/DiscordAccessKitTests/ConnectivityFailureTests.swift`, `macos/Sources/DiscordAccessKit/Connectivity/Cancellation.swift`, `macos/Sources/DiscordAccessKit/Connectivity/ConnectivityFailure.swift`

- [ ] **Adım 1: İptal testlerini yaz** (`swift` bloğu 3)

İptal bir kez olur; kayıtlı her işleyici bir kez çalışır (çok iş parçacığından iptal edilse de); kaydı silinen işleyici çalışmaz; iptalden sonra kaydedilen işleyici hemen çalışır; bir işleyici yeniden iptal edebilir.

```swift
import Foundation
import Testing
@testable import DiscordAccessKit

@Suite struct CancellationTests {
    final class Counter {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test func throwsOnlyOnceCanceled() throws {
        let cancel = Cancellation()
        #expect(!cancel.isCanceled)
        try cancel.check()
        cancel.cancel()
        cancel.cancel()
        #expect(cancel.isCanceled)
        #expect(throws: CancellationError.self) { try cancel.check() }
    }

    @Test func runsEachRegisteredHandlerOnce() {
        let cancel = Cancellation()
        let kept = Counter(), removed = Counter(), late = Counter()
        _ = cancel.whenCanceled { kept.increment() }
        let unregister = cancel.whenCanceled { removed.increment() }
        unregister()
        // A handler may cancel again without deadlocking.
        _ = cancel.whenCanceled { cancel.cancel() }
        cancel.cancel()
        cancel.cancel()
        #expect(kept.count == 1 && removed.count == 0)
        // Registered after the cancellation: runs at once.
        _ = cancel.whenCanceled { late.increment() }
        #expect(late.count == 1)
    }

    @Test func runsAHandlerOnceWhenCanceledFromManyThreads() {
        let cancel = Cancellation()
        let calls = Counter()
        _ = cancel.whenCanceled { calls.increment() }
        DispatchQueue.concurrentPerform(iterations: 32) { _ in cancel.cancel() }
        #expect(calls.count == 1)
    }
}
```

- [ ] **Adım 2: Hata testlerini yaz** (`swift` bloğu 4)

Vektörler Windows `ConnectivityChecks.RunFailureChecks`'ten alınmıştır:
- her nedenin ve iki uç noktanın iletisi, sözcüğü sözcüğüne;
- HTTP durumunun yalnız 100–599 arasında ve yalnız HTTP hatasında tutulması;
- yanıt türünün `Content-Type`'tan, değeri tutulmadan çıkarılması;
- URLSession hatalarının sınıflandırılması: CFNetwork'ün proxy kodları (306, 310, 311), son tarihin iptali zaman aşımı sayması, bilinmeyen alanlar.

```swift
import Foundation
import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows `ConnectivityChecks.RunFailureChecks`. A message holds only fixed words, an HTTP status and
/// a response type, so `PRIVATE` must never appear.
@Suite struct ConnectivityFailureTests {
    static let secret = "SYNTHETIC_SECRET https://private.invalid/?token=PRIVATE /Users/PRIVATE/config.json\u{1B}"

    @Test(arguments: [
        (ConnectivityFailure.Reason.dns, "DNS çözümleme başarısız"),
        (.tls, "TLS bağlantısı veya sertifika doğrulaması başarısız"),
        (.connect, "ağ veya yerel proxy bağlantısı kurulamadı"),
        (.timeout, "zaman aşımı"),
        (.invalidResponse, "beklenen yanıt biçimi doğrulanamadı"),
        (.responseTooLarge, "yanıt boyut sınırını aşıyor"),
        (.incompleteResponse, "yanıt aktarımı tamamlanamadı"),
        (.canceled, "işlem iptal edildi"),
        (.other, "erişim doğrulanamadı"),
    ])
    func namesTheEndpointAndTheReason(reason: ConnectivityFailure.Reason, detail: String) {
        #expect(ConnectivityFailure(endpoint: .gateway, reason: reason).message == "Discord Gateway API kontrolü başarısız (" + detail + ").")
        #expect(ConnectivityFailure(endpoint: .updates, reason: reason).description == "Discord güncelleme sunucusu kontrolü başarısız (" + detail + ").")
    }

    @Test func keepsAnHTTPStatusOnlyWhenItIsOne() {
        #expect(ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 429, responseKind: .html).message ==
            "Discord Gateway API kontrolü başarısız (HTTP 429; yanıt türü HTML).")
        #expect(ConnectivityFailure(endpoint: .updates, reason: .http, httpStatus: 503, responseKind: .json).message ==
            "Discord güncelleme sunucusu kontrolü başarısız (HTTP 503; yanıt türü JSON).")
        #expect(ConnectivityFailure(endpoint: .gateway, reason: .invalidResponse, responseKind: .other).message ==
            "Discord Gateway API kontrolü başarısız (beklenen yanıt biçimi doğrulanamadı; yanıt türü diğer).")
        for status in [-1, 0, 99, 600, Int.max] {
            let failure = ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: status)
            #expect(failure.httpStatus == 0 && failure.message == "Discord Gateway API kontrolü başarısız (HTTP hata yanıtı).")
        }
        #expect(ConnectivityFailure(endpoint: .gateway, reason: .timeout, httpStatus: 429).httpStatus == 0)
    }

    @Test func classifiesTheResponseTypeWithoutKeepingIt() {
        #expect(ConnectivityFailure.responseKind(contentType: "Application/JSON; charset=utf-8") == .json)
        #expect(ConnectivityFailure.responseKind(contentType: "text/json") == .json)
        #expect(ConnectivityFailure.responseKind(contentType: "text/html; PRIVATE") == .html)
        #expect(ConnectivityFailure.responseKind(contentType: " application/xhtml+xml ") == .html)
        #expect(ConnectivityFailure.responseKind(contentType: Self.secret) == .other)
        #expect(ConnectivityFailure.responseKind(contentType: "application/json" + String(repeating: " ", count: 300)) == .other)
        for empty in [nil, "", "   "] as [String?] {
            #expect(ConnectivityFailure.responseKind(contentType: empty) == ConnectivityFailure.ResponseKind.none)
        }
    }

    @Test(arguments: [
        (URLError.Code.timedOut, ConnectivityFailure.Reason.timeout), (.cancelled, .canceled), (.cannotFindHost, .dns), (.dnsLookupFailed, .dns),
        (.secureConnectionFailed, .tls), (.serverCertificateUntrusted, .tls), (.serverCertificateHasUnknownRoot, .tls),
        (.cannotConnectToHost, .connect), (.notConnectedToInternet, .connect), (.networkConnectionLost, .incompleteResponse),
        (.badServerResponse, .invalidResponse), (.cannotParseResponse, .invalidResponse), (.dataLengthExceedsMaximum, .responseTooLarge),
        (.unsupportedURL, .other),
    ])
    func classifiesURLSessionErrors(code: URLError.Code, reason: ConnectivityFailure.Reason) {
        let error = NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: Self.secret])
        let failure = ConnectivityFailure.from(error, endpoint: .updates, expired: false)
        #expect(failure == ConnectivityFailure(endpoint: .updates, reason: reason))
        #expect(!String(describing: failure).contains("PRIVATE") && !failure.message.contains("SYNTHETIC_SECRET"))
    }

    @Test func classifiesProxyFailuresTheDeadlineAndOtherErrors() {
        // CFNetwork's codes for a proxy it cannot use, as data and WebSocket tasks report them.
        for domain in [kCFErrorDomainCFNetwork as String, NSURLErrorDomain] {
            for code in [306, 310, 311] {
                #expect(ConnectivityFailure.from(NSError(domain: domain, code: code), endpoint: .gateway, expired: false).reason == .connect)
            }
        }
        // The check's own deadline cancels the task; that is a timeout, not a user's cancellation.
        #expect(ConnectivityFailure.from(URLError(.cancelled), endpoint: .gateway, expired: true).reason == .timeout)
        // Socket errors as Windows `SocketException`.
        #expect(ConnectivityFailure.from(POSIXError(.ECONNRESET), endpoint: .gateway, expired: false).reason == .connect)
        #expect(ConnectivityFailure.from(POSIXError(.ECONNREFUSED), endpoint: .gateway, expired: false).reason == .connect)
        #expect(ConnectivityFailure.from(POSIXError(.ETIMEDOUT), endpoint: .gateway, expired: false).reason == .timeout)
        #expect(ConnectivityFailure.from(POSIXError(.EPERM), endpoint: .gateway, expired: false).reason == .other)
        #expect(ConnectivityFailure.from(NSError(domain: "PRIVATE", code: 310), endpoint: .gateway, expired: false).reason == .other)
        let known = ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 429)
        #expect(ConnectivityFailure.from(known, endpoint: .updates, expired: false) == known)
    }
}
```

- [ ] **Adım 3: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'Cancellation' in scope`. Derleme işlerinin sırasına göre `ConnectivityFailureTests.swift`'in hataları da görülebilir: `cannot find 'ConnectivityFailure' in scope`, `cannot find type 'ConnectivityFailure' in scope` ve buna bağlı `cannot infer contextual base in reference to member '…'` hataları. Bu Mac'teki denemede yalnız `Cancellation` hatası göründü.

- [ ] **Adım 4: İptal sinyalini yaz** (`swift` bloğu 5)

Windows `CancellationToken` karşılığı: `check()` iptalden sonra `CancellationError` atar; `whenCanceled` süren bir URLSession görevini iptal etmek için kullanılır. İşleyiciler kilit dışında, iptal eden iş parçacığında çalışır.

```swift
import Foundation

/// A cancellation signal shared by a DNS selection and its checks (Windows `CancellationToken`). Canceling runs each
/// registered handler once, on the canceling thread.
public final class Cancellation {
    private let lock = NSLock()
    private var canceled = false
    private var handlers: [Int: () -> Void] = [:]
    private var nextHandler = 0

    public init() {}

    public var isCanceled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceled
    }

    public func cancel() {
        lock.lock()
        guard !canceled else {
            lock.unlock()
            return
        }
        canceled = true
        let pending = handlers.values
        handlers.removeAll()
        lock.unlock()
        for handler in pending { handler() }
    }

    /// Throws `CancellationError` once canceled.
    public func check() throws {
        if isCanceled { throw CancellationError() }
    }

    /// Runs `handler` when this is canceled, at once when it already is; the returned function unregisters it.
    func whenCanceled(_ handler: @escaping () -> Void) -> () -> Void {
        lock.lock()
        guard !canceled else {
            lock.unlock()
            handler()
            return {}
        }
        let key = nextHandler
        nextHandler += 1
        handlers[key] = handler
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.handlers[key] = nil
            self.lock.unlock()
        }
    }
}
```

- [ ] **Adım 5: Bağlantı hatalarını yaz** (`swift` bloğu 6)

Windows `ConnectivityFailureException` karşılığı. İleti yalnız sabit sözcükler, HTTP durumu ve yanıt türü içerir; URL, başlık, gövde ya da hata metni tutulmaz. CFNetwork, kullanamadığı bir proxy'yi 306 (düz HTTP), 310 ya da 311 (HTTPS, WebSocket) olarak bildirir: proxy'nin reddetmesi, 403 yanıtı ve tünelin kopması aynı biçimde biter. Bunlar bağlantı hatasıdır.

```swift
import Foundation

/// Why a connectivity check failed (Windows `ConnectivityFailureException`). Only fixed categories, an HTTP status and
/// the type of a response are kept: never a URL, header, body or error text.
public struct ConnectivityFailure: Error, Equatable, CustomStringConvertible {
    public enum Endpoint: Equatable, Sendable {
        case gateway
        case updates
    }

    public enum Reason: Equatable, Sendable {
        case http, dns, tls, connect, timeout, invalidResponse, responseTooLarge, incompleteResponse, canceled, other
    }

    public enum ResponseKind: Equatable, Sendable {
        case none, json, html, other
    }

    public let endpoint: Endpoint
    public let reason: Reason
    /// The status of an `http` failure when it is 100-599, otherwise 0.
    public let httpStatus: Int
    public let responseKind: ResponseKind

    public init(endpoint: Endpoint, reason: Reason, httpStatus: Int = 0, responseKind: ResponseKind = .none) {
        self.endpoint = endpoint
        self.reason = reason
        self.httpStatus = reason == .http && (100...599).contains(httpStatus) ? httpStatus : 0
        self.responseKind = responseKind
    }

    public var description: String { message }

    /// Windows `MessageFor`, word for word.
    public var message: String {
        let label = endpoint == .gateway ? "Discord Gateway API" : "Discord güncelleme sunucusu"
        var detail: String
        switch reason {
        case .http: detail = httpStatus == 0 ? "HTTP hata yanıtı" : "HTTP " + String(httpStatus)
        case .dns: detail = "DNS çözümleme başarısız"
        case .tls: detail = "TLS bağlantısı veya sertifika doğrulaması başarısız"
        case .connect: detail = "ağ veya yerel proxy bağlantısı kurulamadı"
        case .timeout: detail = "zaman aşımı"
        case .invalidResponse: detail = "beklenen yanıt biçimi doğrulanamadı"
        case .responseTooLarge: detail = "yanıt boyut sınırını aşıyor"
        case .incompleteResponse: detail = "yanıt aktarımı tamamlanamadı"
        case .canceled: detail = "işlem iptal edildi"
        case .other: detail = "erişim doğrulanamadı"
        }
        switch responseKind {
        case .none: break
        case .json: detail += "; yanıt türü JSON"
        case .html: detail += "; yanıt türü HTML"
        case .other: detail += "; yanıt türü diğer"
        }
        return label + " kontrolü başarısız (" + detail + ")."
    }

    /// The type of a response from its `Content-Type` (Windows `ContentKind`).
    static func responseKind(contentType: String?) -> ResponseKind {
        guard let contentType, !contentType.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        guard contentType.utf8.count <= 256 else { return .other }
        let kind = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch kind {
        case "application/json", "text/json": return .json
        case "text/html", "application/xhtml+xml": return .html
        default: return .other
        }
    }

    /// The failure of a URLSession task, by its error (Windows `From`); `expired` reports that the check's own deadline
    /// ended the task.
    static func from(_ error: Error, endpoint: Endpoint, expired: Bool) -> ConnectivityFailure {
        if expired { return ConnectivityFailure(endpoint: endpoint, reason: .timeout) }
        if let known = error as? ConnectivityFailure { return known }
        let failure = error as NSError
        // CFNetwork reports a proxy it cannot use as kCFErrorHTTPProxyConnectionFailure (306) for plain HTTP, and as
        // kCFErrorHTTPSProxyConnectionFailure (310) or an unexpected answer to CONNECT (311) for HTTPS and WebSocket; the
        // proxy refusing the connection, answering 403 or dropping the tunnel all end this way, in either domain.
        if [306, 310, 311].contains(failure.code) && (failure.domain == NSURLErrorDomain || failure.domain == kCFErrorDomainCFNetwork as String) {
            return ConnectivityFailure(endpoint: endpoint, reason: .connect)
        }
        // A socket error, as Windows `SocketException`: a timeout, or a connection that could not be made or was lost.
        if failure.domain == NSPOSIXErrorDomain {
            if failure.code == Int(ETIMEDOUT) { return ConnectivityFailure(endpoint: endpoint, reason: .timeout) }
            let connection = [ECONNREFUSED, ECONNRESET, ECONNABORTED, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ENOTCONN, EPIPE]
            return ConnectivityFailure(endpoint: endpoint, reason: connection.contains(Int32(failure.code)) ? .connect : .other)
        }
        guard failure.domain == NSURLErrorDomain else { return ConnectivityFailure(endpoint: endpoint, reason: .other) }
        let reason: Reason
        switch URLError.Code(rawValue: failure.code) {
        case .timedOut: reason = .timeout
        case .cancelled: reason = .canceled
        case .cannotFindHost, .dnsLookupFailed: reason = .dns
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired: reason = .tls
        case .cannotConnectToHost, .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed: reason = .connect
        case .networkConnectionLost, .zeroByteResource: reason = .incompleteResponse
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData: reason = .invalidResponse
        case .dataLengthExceedsMaximum: reason = .responseTooLarge
        default: reason = .other
        }
        return ConnectivityFailure(endpoint: endpoint, reason: reason)
    }
}
```

- [ ] **Adım 6: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 104 tests in 16 suites passed`, uyarısız ve `skipped` olmadan.

---

### Görev 3: HTTPS tanısı

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/ConnectivityProbeTests.swift`, `macos/Sources/DiscordAccessKit/Connectivity/ConnectivityProbe.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 7)

Sahte proxy (Windows `FixtureResponse`) her bağlantının istek başlığını kaydeder ve sabit bir yanıt verir. Sınanan durumlar:
- Gateway adresinin kabulü ve isteğin içeriği: başlıklar izinli bir kümeden ve sabit değerlerle (`Accept`, `User-Agent`, `Accept-Language`, `Accept-Encoding`; URLSession'ın kendi `Pragma: no-cache`'i); çerez ya da kimlik bilgisi yok;
- 429'un, sayfası nasıl gelirse gelsin 429 kalması: 16 KiB'yi aşan (uzunluk bildirilse de bildirilmese de), yarıda kesilen ya da hiç tamamlanmayan sayfa; seçim bu yüzden durur;
- 401'e kimlik bilgisi sunulmaması: en fazla bir yineleme, hiçbir istekte `Authorization` yok;
- gerçek kapı ve sahte motorla: kapının bu süreci tanı izniyle kabul etmesi, motora motor kimlik bilgisiyle `CONNECT discord.com:443` gitmesi;
- HTTP hataları (429 HTML, 503 JSON, 302) yalnız durum ve türle; yönlendirme izlenmez;
- Gateway adresi olmayan yanıtlar, geçersiz UTF-8, 16 KiB'yi aşan 200 yanıtı (uzunluğu bildirilse de bildirilmese de);
- reddedilen proxy'de hemen bağlantı hatası;
- son tarih ve iptal: iptal edilen denetim kimseye bağlanmaz;
- güncelleme sunucusunun `HEAD` isteği ve kabul edilen durumlar (2xx, 404, 405); gövdesiz `HEAD` yanıtının bildirdiği büyük uzunluk sayılmaz;
- Gateway adresinin doğrulanması (Windows vektörleri);
- yapılandırmanın her şemayı tek loopback proxy'ye bağlaması ve durum tutmaması.

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The HTTPS checks against a loopback stand-in for the proxy (Windows `FixtureResponse`). Plain
/// `http://fixture.invalid/...` targets reach the stand-in in absolute form and are answered there; the `.invalid` name
/// never resolves, so nothing leaves the machine. (discord.com itself is on the HSTS preload list, so URLSession would
/// always tunnel it.)
@Suite struct ConnectivityProbeTests {
    typealias Collected = ProxyGateTests.Collected
    static let gateway = URL(string: "http://fixture.invalid/api/v10/gateway")!
    static let updates = URL(string: "http://fixture.invalid/updates/")!
    static let validGateway = Array("{\"url\":\"wss://gateway.discord.gg\"}".utf8)

    /// Answers up to `connections` connections, one after another: each request head is recorded and answered with
    /// `respond`'s bytes, then the connection closes, or with `holdsOpen` stays open until the client closes. For nil it
    /// says nothing and waits for the client to close.
    final class FixtureProxy {
        let listener: TCPListener
        let heads = Collected<String>()
        private let served = DispatchGroup()

        var port: UInt16 { listener.port }

        init(connections: Int = 1, holdsOpen: Bool = false, respond: @escaping (String) -> [UInt8]?) throws {
            listener = try TCPListener()
            let (listener, heads, served) = (listener, heads, served)
            served.enter()
            Thread {
                defer { served.leave() }
                for _ in 0..<connections {
                    guard let client = try? listener.acceptClient().descriptor else { return }
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    var noSignal: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    let head = FixtureProxy.readHead(client)
                    heads.append(head)
                    let bytes = respond(head)
                    if let bytes { _ = try? RelayTests.send(client, bytes) }
                    if bytes == nil || holdsOpen {
                        var byte: UInt8 = 0
                        while read(client, &byte, 1) > 0 {}
                    }
                    close(client)
                }
            }.start()
        }

        /// Waits until every connection was served, at most 15 seconds.
        func finished() -> Bool { served.wait(timeout: .now() + 15) == .success }

        static func readHead(_ descriptor: Int32) -> String {
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while bytes.count < 16384, read(descriptor, &byte, 1) == 1 {
                bytes.append(byte)
                if bytes.suffix(4).elementsEqual([13, 10, 13, 10]) { break }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        static func response(_ status: Int, contentType: String? = "application/json", body: [UInt8] = [], length: Bool = true,
                             extra: String = "") -> [UInt8] {
            var head = "HTTP/1.1 " + String(status) + " Fixture\r\n"
            if let contentType { head += "Content-Type: " + contentType + "\r\n" }
            if length { head += "Content-Length: " + String(body.count) + "\r\n" }
            return Array((head + extra + "Connection: close\r\n\r\n").utf8) + body
        }
    }

    /// A port in a range the system never hands out on its own, where nothing listens any more.
    static func refusedPort(in range: Range<UInt16>) throws -> UInt16 {
        for candidate in range {
            guard let holder = try? LoopbackSocketTests.boundSocket(port: candidate) else { continue }
            close(holder.descriptor)
            return holder.port
        }
        throw POSIXError(.EADDRINUSE)
    }

    static func failure(_ body: () throws -> Void) -> ConnectivityFailure? {
        do {
            try body()
            return nil
        } catch {
            return error as? ConnectivityFailure
        }
    }

    /// The fields of a request head by lower-case name.
    static func fields(_ head: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// Only fixed values leave this process: no languages, agent string, cookie or credential of this Mac.
    @Test func acceptsTheGatewayAddressAndSendsOnlyAFixedRequest() throws {
        let proxy = try FixtureProxy { _ in FixtureProxy.response(200, body: Self.validGateway) }
        try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation())
        #expect(proxy.finished())
        let head = try #require(proxy.heads.all.first)
        #expect(head.hasPrefix("GET http://fixture.invalid/api/v10/gateway HTTP/1.1\r\n"))
        let fields = Self.fields(head)
        #expect(Set(fields.keys).isSubset(of: ["host", "accept", "user-agent", "accept-language", "accept-encoding", "pragma", "connection",
                                               "proxy-connection"]))
        #expect(fields["host"] == "fixture.invalid" && fields["accept"] == "application/json" && (fields["pragma"] ?? "no-cache") == "no-cache")
        #expect(fields["user-agent"] == "DiscordAccess/3 (connectivity check)" && fields["accept-language"] == "en" && fields["accept-encoding"] == "identity")
    }

    /// How the page of an error answer arrives.
    enum ErrorPage: CaseIterable {
        /// Over 16 KiB, with its length announced or not.
        case announcedOverLimit, unannouncedOverLimit
        /// The connection closes before the announced length arrived.
        case cutOff
        /// The announced length never arrives; the connection stays open.
        case held
    }

    /// The status counts as it arrives (Windows reads the body only for a 200): a rate limit stays a rate limit however
    /// its page arrives, so selection stops.
    @Test(arguments: ErrorPage.allCases)
    func keepsTheStatusOfAnErrorAnswerWhateverItsPage(page: ErrorPage) throws {
        let long = Array(repeating: UInt8(ascii: "x"), count: 20_000)
        let partial = FixtureProxy.response(429, contentType: "text/html", length: false, extra: "Content-Length: 1000\r\n") + Array("<html>".utf8)
        let answer = switch page {
        case .announcedOverLimit: FixtureProxy.response(429, contentType: "text/html", body: long)
        case .unannouncedOverLimit: FixtureProxy.response(429, contentType: "text/html", body: long, length: false)
        case .cutOff, .held: partial
        }
        let proxy = try FixtureProxy(holdsOpen: page == .held) { _ in answer }
        let failure = Self.failure {
            try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation(), deadline: 2)
        }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 429, responseKind: .html))
        #expect(proxy.finished())
    }

    /// No credential is ever offered: CFNetwork asks once more without one, and the 401 then stands.
    @Test func answersAnAuthenticationRequestWithoutCredentials() throws {
        let proxy = try FixtureProxy(connections: 2) { _ in
            FixtureProxy.response(401, contentType: "text/html", extra: "WWW-Authenticate: Basic realm=\"fixture\"\r\n")
        }
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 401, responseKind: .html))
        #expect((1...2).contains(proxy.heads.all.count) && proxy.heads.all.allSatisfy { Self.fields($0)["authorization"] == nil })
    }

    /// URLSession's connection to the proxy is a socket of this process, so a real gate admits it through its diagnostic
    /// permission and forwards the request with the engine credential. The stand-in engine cannot speak TLS for
    /// discord.com, so the check itself fails afterwards; nothing leaves the machine.
    @Test func reachesTheEngineThroughARealGateAsThisProcess() throws {
        let received = Collected<[UInt8]>()
        let engine = try ProxyGateTests.FakeEngine(serve: { connection in
            received.append(ProxyGateTests.receiveHeader(connection) ?? [])
            _ = try? ProxyGateTests.send(connection, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            usleep(200_000)
        })
        let lines = ProxyGateTests.Lines()
        let gate = try ProxyGateTests.gate(engine, lines: lines)
        defer { gate.close() }
        #expect(throws: ConnectivityFailure.self) {
            try ConnectivityProbe.checkGateway(url: ConnectivityProbe.gatewayURL, proxyPort: gate.port, cancel: Cancellation(), deadline: 3)
        }
        let header = String(decoding: try #require(received.all.first), as: UTF8.self)
        #expect(header.hasPrefix("CONNECT discord.com:443 HTTP/1.1\r\n"))
        #expect(header.contains("\r\nProxy-Authorization: " + ProxyGateTests.authorization + "\r\n"))
        #expect(lines.contain("Owned request discord.com:443"))
    }

    static let statusFailures: [(Int, String?, String, ConnectivityFailure.ResponseKind)] = [
        (429, "text/html", "<html>SYNTHETIC_SECRET PRIVATE</html>", .html),
        (503, "application/json", "{\"secret\":\"SYNTHETIC_SECRET PRIVATE\"}", .json),
        (302, nil, "", .none),
    ]

    @Test(arguments: statusFailures)
    func reportsAnHTTPFailureWithItsStatusAndTypeOnly(status: Int, contentType: String?, body: String, kind: ConnectivityFailure.ResponseKind) throws {
        // A redirect is not followed: the stand-in sees a single request.
        let proxy = try FixtureProxy(connections: 2) { _ in
            FixtureProxy.response(status, contentType: contentType, body: Array(body.utf8), extra: "Location: http://fixture.invalid/PRIVATE\r\n")
        }
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: status, responseKind: kind))
        #expect(failure.map { !$0.message.contains("SYNTHETIC_SECRET") && !String(describing: $0).contains("PRIVATE") } == true)
        #expect(proxy.heads.all.count == 1)
    }

    @Test(arguments: [("application/json", "{\"url\":\"wss://SYNTHETIC_SECRET.invalid/\"}"), ("text/html", "<html>SYNTHETIC_SECRET</html>"),
                      ("application/json", "\u{FF}not utf-8")])
    func refusesAnAnswerThatIsNotTheGatewayAddress(contentType: String, body: String) throws {
        let bytes = body.hasPrefix("\u{FF}") ? [0xFF, 0xFE] + Array("{}".utf8) : Array(body.utf8)
        let proxy = try FixtureProxy { _ in FixtureProxy.response(200, contentType: contentType, body: bytes) }
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .invalidResponse))
    }

    /// The body may not exceed 16 KiB, whether the response announces its length or not.
    @Test(arguments: [true, false])
    func refusesAnAnswerOver16KiB(announced: Bool) throws {
        let body = Array(repeating: UInt8(ascii: "x"), count: ConnectivityProbe.maxResponseBytes + 1)
        let proxy = try FixtureProxy { _ in FixtureProxy.response(200, body: body, length: announced) }
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .responseTooLarge))
    }

    /// Nothing listens on the proxy port: the check fails at once and never connects directly instead.
    @Test func failsAtOnceWhenTheProxyRefuses() throws {
        let port = try Self.refusedPort(in: 23_000..<23_200)
        let started = Date()
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .connect))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func endsAtItsDeadlineWhenTheAnswerDoesNotCome() throws {
        let proxy = try FixtureProxy { _ in nil }
        let started = Date()
        let failure = Self.failure {
            try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation(), deadline: 0.5)
        }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .timeout))
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(proxy.finished())
    }

    /// Canceling ends a request in flight at once, as `CancellationError`; a canceled check contacts nobody.
    @Test func endsAtOnceWhenCanceled() throws {
        let cancel = Cancellation()
        let proxy = try FixtureProxy { _ in
            cancel.cancel()
            return nil
        }
        let started = Date()
        #expect(throws: CancellationError.self) { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: cancel) }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(proxy.finished())
        let quiet = try FixtureProxy { _ in FixtureProxy.response(200, body: Self.validGateway) }
        #expect(throws: CancellationError.self) { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: quiet.port, cancel: cancel) }
        #expect(quiet.heads.all.isEmpty)
    }

    @Test func checksTheUpdateServerWithAHeadRequest() throws {
        // A HEAD answer may announce a length over the limit without a body; only its status counts.
        let accepted = try FixtureProxy(connections: 2) { head in
            head.hasPrefix("GET ") ? FixtureProxy.response(200, body: Self.validGateway)
                : FixtureProxy.response(404, contentType: "text/html", length: false, extra: "Content-Length: 20000\r\n")
        }
        try ConnectivityProbe.check(gateway: Self.gateway, updates: Self.updates, proxyPort: accepted.port, cancel: Cancellation())
        #expect(accepted.finished())
        #expect(accepted.heads.all.last?.hasPrefix("HEAD http://fixture.invalid/updates/ HTTP/1.1\r\n") == true)
        let refused = try FixtureProxy(connections: 2) { head in
            head.hasPrefix("GET ") ? FixtureProxy.response(200, body: Self.validGateway) : FixtureProxy.response(503, contentType: "text/html")
        }
        let failure = Self.failure { try ConnectivityProbe.check(gateway: Self.gateway, updates: Self.updates, proxyPort: refused.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .updates, reason: .http, httpStatus: 503, responseKind: .html))
        for status in [200, 204, 404, 405] { #expect(ConnectivityProbe.acceptsUpdateStatus(status)) }
        for status in [301, 302, 401, 403, 407, 429, 500, 502, 503] { #expect(!ConnectivityProbe.acceptsUpdateStatus(status)) }
    }

    @Test func acceptsOnlyTheDiscordGatewayAddress() throws {
        for body in ["{\"url\":\"wss://gateway.discord.gg\"}", "{\"url\":\"wss://gateway.discord.gg/\"}", "{\"url\":\"WSS://GATEWAY.Discord.gg:443/\"}"] {
            try ConnectivityProbe.validateGateway(Data(body.utf8))
        }
        for body in ["{}", "[]", "null", "not json", "{\"url\":7}", "{\"url\":\"ws://gateway.discord.gg/\"}",
                     "{\"url\":\"wss://gateway.discord.gg.attacker.invalid/\"}", "{\"url\":\"wss://gateway.discord.gg:444/\"}",
                     "{\"url\":\"wss://user@gateway.discord.gg/\"}", "{\"url\":\"wss://gateway.discord.gg/#fragment\"}",
                     "{\"SYNTHETIC_SECRET\":\"PRIVATE\"}"] {
            #expect(throws: ConnectivityFailure(endpoint: .gateway, reason: .invalidResponse)) { try ConnectivityProbe.validateGateway(Data(body.utf8)) }
        }
    }

    /// Windows "Connectivity check can bypass its local proxy": every scheme goes to the one loopback proxy.
    @Test func pinsEveryRequestToTheLoopbackProxyAndKeepsNoState() throws {
        let configuration = ConnectivityProbe.configuration(proxyPort: 40_000, deadline: 10)
        let proxies = try #require(configuration.connectionProxyDictionary)
        #expect(proxies[kCFNetworkProxiesHTTPEnable as String] as? Bool == true && proxies[kCFNetworkProxiesHTTPSEnable as String] as? Bool == true)
        #expect(proxies[kCFNetworkProxiesHTTPProxy as String] as? String == "127.0.0.1" && proxies[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1")
        #expect(proxies[kCFNetworkProxiesHTTPPort as String] as? Int == 40_000 && proxies[kCFNetworkProxiesHTTPSPort as String] as? Int == 40_000)
        #expect(proxies[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Bool == false)
        #expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil && configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(ConnectivityProbe.gatewayURL.absoluteString == "https://discord.com/api/v10/gateway")
        #expect(ConnectivityProbe.updatesURL.absoluteString == "https://updates.discord.com/")
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'ConnectivityProbe' in scope`. Tür henüz olmadığı için `cannot infer contextual base in reference to member 'reloadIgnoringLocalCacheData'` hatası ve `no calls to throwing functions occur within 'try' expression` uyarısı da görülür; tür tanımlanınca kaybolur.

- [ ] **Adım 3: HTTPS tanısını yaz** (`swift` bloğu 8)

- URLSession'a sabit loopback proxy verilir (HTTP ve HTTPS için, proxy betiği kapalı). Sistem proxy'si ve doğrudan bağlantı kullanılmaz.
- Yönlendirme izlenmez. Çerez, önbellek ve kimlik bilgisi tutulmaz.
- Kimlik bilgisi sunulmaz: sunucu güveni sistemin kendi değerlendirmesine bırakılır, başka her kimlik doğrulama isteği reddedilir (URLSession aksi halde sistemin tek oturum açma hizmetini deneyebilirdi). Yerel testlerde TLS olmadığı için sunucu güveni yalnız canlı denetimde, gerçek sertifikalarla sınanır.
- `User-Agent`, `Accept-Language` ve `Accept-Encoding` sabittir. URLSession aksi halde bu Mac'in dil listesini ve kendi tarayıcı adını gönderirdi; Windows ikisini de göndermez.
- Gövde yalnız Gateway'in 200 yanıtında okunur (Windows gibi); başka her durumda istek yanıt başlığıyla biter. Uzun, yarıda kesilen ya da yavaş gelen bir sayfayla gelen 429 böylece yine 429'dur. Güncelleme sunucusunun `HEAD` yanıtında da yalnız durum sayılır.
- Okunan gövde akarken sayılır; 16 KiB'yi aşınca istek iptal edilir, ama gelmiş olan yanıt geçerli kalır ve sonuç `responseTooLarge` olur.
- Son tarihi denetimin kendisi tutar (Windows'taki zamanlayıcı gibi): her isteğin 10 sn'si vardır; süre dolunca görev iptal edilir, kapanması en fazla 5 sn daha beklenir ve sonuç zaman aşımıdır. URLSession'ın kendi süreleri bunun arkasında kalır. Son tarih geçerken tamamlanan yanıt da sayılmaz. `check` iki istek yapar.
- İptal süren görevi hemen keser ve `CancellationError` atar.
- Gateway yanıtı `{"url": "wss://gateway.discord.gg"}` olmalıdır: 443 dışında port, kullanıcı bilgisi ya da parça olamaz (Windows `ValidateGateway`). Güncelleme sunucusunun kökü belgelenmiş bir uç nokta değildir; 404 ve 405 HTTPS erişimini kanıtlar.

```swift
import Foundation

/// HTTPS checks through the session's loopback proxy (Windows `ConnectivityChecks`). A request goes only through
/// 127.0.0.1:`proxyPort`: no system proxy, no proxy script and no direct connection, even when the proxy refuses. It
/// follows no redirect, keeps no cookie, cache or credential and offers none, sends only fixed header values, reads at
/// most 16 KiB of a body and has a 10-second deadline. The proxy must admit this process (the gate's diagnostic
/// permission). Nothing in the system, the account or Discord changes.
public enum ConnectivityProbe {
    static let deadline: TimeInterval = 10
    static let maxResponseBytes = 16384
    static let gatewayURL = URL(string: "https://discord.com/api/v10/gateway")!
    static let updatesURL = URL(string: "https://updates.discord.com/")!

    /// Discord's Gateway API answers with its Gateway address (Windows `CheckDnsCandidate`). Throws
    /// `ConnectivityFailure`, or `CancellationError` once `cancel` is canceled.
    public static func checkGateway(proxyPort: UInt16, cancel: Cancellation = Cancellation()) throws {
        try checkGateway(url: gatewayURL, proxyPort: proxyPort, cancel: cancel)
    }

    /// The Gateway API and the update server both answer (Windows `Check`); returns the summary to show.
    public static func check(proxyPort: UInt16, cancel: Cancellation = Cancellation()) throws -> String {
        try check(gateway: gatewayURL, updates: updatesURL, proxyPort: proxyPort, cancel: cancel)
        return "Discord API ve güncelleme sunucusuna proxy üzerinden HTTPS erişimi doğrulandı. Masaüstü güncellemesi, hesap girişi ve " +
            "sesli sohbet ayrıca kontrol edilmelidir."
    }

    static func check(gateway: URL, updates: URL, proxyPort: UInt16, cancel: Cancellation, deadline: TimeInterval = deadline) throws {
        try checkGateway(url: gateway, proxyPort: proxyPort, cancel: cancel, deadline: deadline)
        let (response, _, _) = try fetch(updates, method: "HEAD", proxyPort: proxyPort, endpoint: .updates, cancel: cancel, deadline: deadline,
                                         readsBody: { _ in false })
        // The root is no documented manifest: 404 or 405 proves HTTPS reachability, not a completed desktop update.
        guard acceptsUpdateStatus(response.statusCode) else { throw statusFailure(.updates, response) }
    }

    static func checkGateway(url: URL, proxyPort: UInt16, cancel: Cancellation, deadline: TimeInterval = deadline) throws {
        // Windows reads the body only for a 200: any other status counts as it arrives, so a 429 stays a 429 whether
        // its page is long, cut off or slow.
        let (response, body, truncated) = try fetch(url, method: "GET", proxyPort: proxyPort, endpoint: .gateway, cancel: cancel, deadline: deadline,
                                                    readsBody: { $0.statusCode == 200 })
        guard response.statusCode == 200 else { throw statusFailure(.gateway, response) }
        guard !truncated else { throw ConnectivityFailure(endpoint: .gateway, reason: .responseTooLarge) }
        try validateGateway(body)
    }

    /// The response of one request, its body and whether the body was cut off at the limit; the caller judges the status.
    /// The body of a response for which `readsBody` is false is not read: the request ends with the response head. A
    /// failed request and the deadline throw `ConnectivityFailure`; a canceled `cancel` throws `CancellationError`.
    static func fetch(_ url: URL, method: String, proxyPort: UInt16, endpoint: ConnectivityFailure.Endpoint, cancel: Cancellation,
                      deadline: TimeInterval = deadline, readsBody: @escaping (HTTPURLResponse) -> Bool)
        throws -> (response: HTTPURLResponse, body: Data, truncated: Bool) {
        try cancel.check()
        let collector = ResponseCollector(limit: maxResponseBytes, readsBody: readsBody)
        let session = URLSession(configuration: configuration(proxyPort: proxyPort, deadline: deadline), delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        setFixedHeaders(&request)
        let task = session.dataTask(with: request)
        let unregister = cancel.whenCanceled { task.cancel() }
        defer { unregister() }
        task.resume()
        // The check's own deadline bounds the whole response, also against a peer that sends slowly.
        let expired = collector.done.wait(timeout: .now() + deadline) == .timedOut
        if expired {
            task.cancel()
            _ = collector.done.wait(timeout: .now() + 5)
        }
        try cancel.check()
        let result = collector.result
        // A response that completed only as the deadline passed does not count either (Windows).
        if expired { throw ConnectivityFailure(endpoint: endpoint, reason: .timeout) }
        // A response read without its body, or whose body went over the limit, ended the task; it still stands.
        if result.headOnly || result.tooLarge, let response = result.response { return (response, result.body, result.tooLarge) }
        if let error = result.error { throw ConnectivityFailure.from(error, endpoint: endpoint, expired: false) }
        guard let response = result.response else { throw ConnectivityFailure(endpoint: endpoint, reason: .invalidResponse) }
        return (response, result.body, false)
    }

    /// Header values that do not depend on this Mac: URLSession would otherwise send the user's languages and its own
    /// agent string. Windows sends neither.
    static func setFixedHeaders(_ request: inout URLRequest) {
        request.setValue("DiscordAccess/3 (connectivity check)", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    /// Server trust gets the system's own evaluation; no credential of any kind is offered, so an authentication request
    /// is answered as it is (`URLSession` would otherwise try the system's single sign-on).
    static func answer(_ challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .rejectProtectionSpace
    }

    /// One proxy for every scheme, URLSession's own timeouts behind the check's deadline, and no state kept.
    static func configuration(proxyPort: UInt16, deadline: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort), kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: Int(proxyPort),
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
        ]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = deadline + 5
        configuration.timeoutIntervalForResource = deadline + 5
        return configuration
    }

    /// `{"url": "wss://gateway.discord.gg"}`, the address on port 443 with no user information or fragment (Windows
    /// `ValidateGateway`).
    static func validateGateway(_ body: Data) throws {
        guard body.count <= maxResponseBytes, let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = payload["url"] as? String, let address = URLComponents(string: text), address.scheme?.lowercased() == "wss",
              address.host?.lowercased() == "gateway.discord.gg", address.port == nil || address.port == 443,
              address.user == nil, address.password == nil, address.fragment == nil else {
            throw ConnectivityFailure(endpoint: .gateway, reason: .invalidResponse)
        }
    }

    static func acceptsUpdateStatus(_ status: Int) -> Bool {
        (200...299).contains(status) || status == 404 || status == 405
    }

    static func statusFailure(_ endpoint: ConnectivityFailure.Endpoint, _ response: HTTPURLResponse) -> ConnectivityFailure {
        ConnectivityFailure(endpoint: endpoint, reason: .http, httpStatus: response.statusCode,
                            responseKind: ConnectivityFailure.responseKind(contentType: response.value(forHTTPHeaderField: "Content-Type")))
    }
}

/// Collects one response for `ConnectivityProbe.fetch`; a redirect is answered as it is, a body is read only when
/// `readsBody` says so, and it may not exceed `limit` bytes.
private final class ResponseCollector: NSObject, URLSessionDataDelegate {
    let done = DispatchSemaphore(value: 0)
    private let limit: Int
    private let readsBody: (HTTPURLResponse) -> Bool
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var body = Data()
    private var error: Error?
    private var headOnly = false
    private var tooLarge = false

    init(limit: Int, readsBody: @escaping (HTTPURLResponse) -> Bool) {
        self.limit = limit
        self.readsBody = readsBody
    }

    var result: (response: HTTPURLResponse?, body: Data, error: Error?, headOnly: Bool, tooLarge: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (response, body, error, headOnly, tooLarge)
    }

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
        let http = response as? HTTPURLResponse
        let headOnly = http.map { !readsBody($0) } ?? false
        let over = !headOnly && response.expectedContentLength > Int64(limit)
        lock.lock()
        self.response = http
        self.headOnly = headOnly
        if over { tooLarge = true }
        lock.unlock()
        completionHandler(headOnly || over ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        body.append(data)
        let over = body.count > limit
        if over { tooLarge = true }
        lock.unlock()
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
        done.signal()
    }
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 117 tests in 17 suites passed`, uyarısız ve `skipped` olmadan.

---

### Görev 4: Gateway WebSocket HELLO

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/GatewayHelloTests.swift`, `macos/Sources/DiscordAccessKit/Connectivity/GatewayHello.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 9)

Sahte sunucu, URLSession'ın düz `ws://fixture.invalid/...` el sıkışmasını kendisi tamamlar (`Sec-WebSocket-Accept`, CryptoKit SHA-1), istemci çerçevelerini çözer ve senaryosunu oynar. Sınanan durumlar:
- HELLO'nun okunması: istek sabit başlık değerleriyle gider, istemci yalnız normal kapanış çerçevesi (1000) gönderir; hiçbir metin ya da ikili mesaj (IDENTIFY) gitmez;
- HELLO olmayan mesajlar (Windows vektörleri; Boolean ve kesirli sayılar dahil), ikili mesaj, 16 KiB'yi aşan mesaj ve HELLO yerine kapanış;
- reddedilen el sıkışma (`[WS-CONNECT-WEBSOCKET]`) ve reddedilen proxy (`[WS-CONNECT-TRANSPORT]`);
- hata nedenlerinin sınıflandırılması (Windows `FailureCategory`): kapanan karşı taraf, POSIX, CFNetwork ve URLSession kodları;
- son tarih (`[WS-HELLO-TIMEOUT]`) ve iptal;
- iletilerin biçimi.

```swift
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The Gateway WebSocket check against a loopback stand-in for the proxy and the Gateway. URLSession sends a plain
/// `ws://fixture.invalid/...` upgrade to the proxy in absolute form (with the `ws` scheme), so the stand-in completes the
/// handshake itself and then acts out its script; the `.invalid` name never resolves. Vectors from the Windows
/// `GatewayChecks.RunOfflineChecks`.
@Suite struct GatewayHelloTests {
    typealias Collected = ProxyGateTests.Collected
    static let target = URL(string: "ws://fixture.invalid/gateway?v=10&encoding=json")!
    static let hello = "{\"op\":10,\"d\":{\"heartbeat_interval\":41250}}"

    enum Script {
        /// Answers the upgrade with 403.
        case refuse
        /// Completes the handshake, then sends one text message.
        case text(String)
        case binary
        /// A text message over the 16 KiB limit.
        case oversized
        /// A close frame instead of HELLO.
        case close
        /// Nothing after the handshake.
        case silent
    }

    final class FixtureGateway {
        let listener: TCPListener
        let heads = Collected<String>()
        /// The opcodes of the frames the client sent, and the status code of its closing frame.
        let clientFrames = Collected<UInt8>()
        let closeCodes = Collected<Int>()
        private let served = DispatchGroup()

        var port: UInt16 { listener.port }

        init(_ script: Script) throws {
            listener = try TCPListener()
            let (listener, heads, clientFrames, closeCodes, served) = (listener, heads, clientFrames, closeCodes, served)
            served.enter()
            Thread {
                defer { served.leave() }
                guard let client = try? listener.acceptClient().descriptor else { return }
                defer { close(client) }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                let head = ConnectivityProbeTests.FixtureProxy.readHead(client)
                heads.append(head)
                if case .refuse = script {
                    _ = try? RelayTests.send(client, ConnectivityProbeTests.FixtureProxy.response(403, contentType: "text/html"))
                    return
                }
                let key = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                    .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                var reply = Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
                    accept + "\r\n\r\n").utf8)
                switch script {
                case .refuse, .silent: break
                case .text(let text): reply += FixtureGateway.frame(opcode: 1, payload: Array(text.utf8))
                case .binary: reply += FixtureGateway.frame(opcode: 2, payload: Array(GatewayHelloTests.hello.utf8))
                case .oversized: reply += FixtureGateway.frame(opcode: 1, payload: Array(repeating: UInt8(ascii: " "), count: 16_385))
                case .close: reply += FixtureGateway.frame(opcode: 8, payload: [0x03, 0xE8])
                }
                guard (try? RelayTests.send(client, reply)) != nil else { return }
                while let frame = FixtureGateway.readFrame(client) {
                    clientFrames.append(frame.opcode)
                    if frame.opcode == 8 {
                        closeCodes.append(frame.payload.count >= 2 ? Int(frame.payload[0]) << 8 | Int(frame.payload[1]) : 0)
                        break
                    }
                }
            }.start()
        }

        /// Waits until the connection was served, at most 15 seconds.
        func finished() -> Bool { served.wait(timeout: .now() + 15) == .success }

        /// One unmasked frame from the server.
        static func frame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
            var bytes: [UInt8] = [0x80 | opcode]
            if payload.count < 126 {
                bytes.append(UInt8(payload.count))
            } else if payload.count <= 0xFFFF {
                bytes += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
            } else {
                bytes.append(127)
                bytes += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
            }
            return bytes + payload
        }

        /// The client's next frame, unmasked, or nil at the end of the stream.
        static func readFrame(_ descriptor: Int32) -> (opcode: UInt8, payload: [UInt8])? {
            guard let start = ProxyGateTests.receive(descriptor, count: 2) else { return nil }
            var length = Int(start[1] & 0x7F)
            if length == 126 {
                guard let extended = ProxyGateTests.receive(descriptor, count: 2) else { return nil }
                length = Int(extended[0]) << 8 | Int(extended[1])
            } else if length == 127 {
                guard let extended = ProxyGateTests.receive(descriptor, count: 8) else { return nil }
                length = extended.reduce(0) { $0 << 8 | Int($1) }
            }
            guard let mask = start[1] & 0x80 != 0 ? ProxyGateTests.receive(descriptor, count: 4) : [0, 0, 0, 0],
                  let payload = ProxyGateTests.receive(descriptor, count: length) else { return nil }
            return (start[0] & 0x0F, payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
    }

    static func failure(_ body: () throws -> Void) -> GatewayHelloFailure? {
        do {
            try body()
            return nil
        } catch {
            return error as? GatewayHelloFailure
        }
    }

    @Test func readsTheHelloAndClosesWithoutSendingAMessage() throws {
        let gateway = try FixtureGateway(.text(Self.hello))
        try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation())
        #expect(gateway.finished())
        let head = try #require(gateway.heads.all.first)
        #expect(head.hasPrefix("GET ws://fixture.invalid/gateway?v=10&encoding=json HTTP/1.1\r\n"))
        #expect(head.lowercased().contains("\r\nupgrade: websocket\r\n") && !head.lowercased().contains("authorization"))
        let fields = ConnectivityProbeTests.fields(head)
        #expect(fields["user-agent"] == "DiscordAccess/3 (connectivity check)" && fields["accept-language"] == "en" && fields["accept-encoding"] == "identity")
        // Public HELLO only: the client never sends a text or binary message, only its closing frame, and it closes
        // normally (1000) rather than as a reset or a client going away.
        #expect(gateway.clientFrames.all == [8])
        #expect(gateway.closeCodes.all == [1000])
    }

    @Test(arguments: ["null", "[]", "{}", "SYNTHETIC_SECRET", "{\"op\":0,\"d\":{\"heartbeat_interval\":41250}}", "{\"op\":10,\"d\":{}}",
                      "{\"op\":10,\"d\":{\"heartbeat_interval\":0}}", "{\"op\":10,\"d\":{\"heartbeat_interval\":\"45000\"}}",
                      "{\"op\":10,\"d\":{\"heartbeat_interval\":300001}}", "{\"op\":10,\"d\":{\"heartbeat_interval\":41250.5}}",
                      "{\"op\":true,\"d\":{\"heartbeat_interval\":41250}}", "{\"op\":10,\"d\":{\"heartbeat_interval\":true}}"])
    func refusesAMessageThatIsNotAHello(text: String) throws {
        let gateway = try FixtureGateway(.text(text))
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation()) }
        #expect(failure == GatewayHelloFailure(opened: true, reason: .response))
        #expect(failure.map { !$0.message.contains("SYNTHETIC_SECRET") } == true)
    }

    @Test(arguments: [Script.binary, .oversized, .close])
    func refusesABinaryOversizedOrClosingAnswer(script: Script) throws {
        let gateway = try FixtureGateway(script)
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation()) }
        #expect(failure == GatewayHelloFailure(opened: true, reason: .response))
    }

    @Test func reportsARefusedHandshakeBeforeTheConnectionOpens() throws {
        let gateway = try FixtureGateway(.refuse)
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation()) }
        #expect(failure == GatewayHelloFailure(opened: false, reason: .webSocket))
        #expect(failure?.message.hasPrefix("[WS-CONNECT-WEBSOCKET] ") == true)
    }

    @Test func failsAtOnceWhenTheProxyRefuses() throws {
        let port = try ConnectivityProbeTests.refusedPort(in: 23_200..<23_400)
        let started = Date()
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: port, cancel: Cancellation()) }
        #expect(failure == GatewayHelloFailure(opened: false, reason: .transport))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func endsAtItsDeadlineWhenTheHelloDoesNotCome() throws {
        let gateway = try FixtureGateway(.silent)
        let started = Date()
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation(), deadline: 0.5) }
        #expect(failure == GatewayHelloFailure(opened: true, reason: .timeout))
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func endsAtOnceWhenCanceled() throws {
        let gateway = try FixtureGateway(.silent)
        let cancel = Cancellation()
        Thread {
            usleep(200_000)
            cancel.cancel()
        }.start()
        let started = Date()
        #expect(throws: CancellationError.self) { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: cancel) }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    static let reasons: [(Error, Bool, GatewayHelloFailure.Reason)] = [
        (URLError(.networkConnectionLost), true, .response),
        (NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE)), false, .response),
        (NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)), false, .transport),
        (NSError(domain: NSURLErrorDomain, code: 310), false, .transport),
        (NSError(domain: kCFErrorDomainCFNetwork as String, code: 306), false, .transport),
        (URLError(.badServerResponse), false, .webSocket),
        (URLError(.secureConnectionFailed), false, .transport),
        (URLError(.timedOut), false, .timeout),
        (URLError(.cancelled), false, .canceled),
        (URLError(.unknown), false, .failed),
        (NSError(domain: "SYNTHETIC_SECRET", code: 1), false, .failed),
    ]

    /// Windows `FailureCategory`: a closing peer counts first, then the proxy, POSIX and URLSession codes.
    @Test func classifiesAFailureWithAFixedReason() {
        for (error, closedByPeer, reason) in Self.reasons {
            #expect(GatewayHello.reason(for: error, closedByPeer: closedByPeer) == reason)
        }
    }

    @Test func namesTheStageAndAFixedReasonOnly() {
        #expect(GatewayHelloFailure(opened: true, reason: .timeout).message ==
            "[WS-HELLO-TIMEOUT] Gateway WebSocket kontrolü tamamlanamadı. HTTP API başarısı canlı mesaj bağlantısını doğrulamaz.")
        #expect(GatewayHelloFailure(opened: false, reason: .canceled).description.hasPrefix("[WS-CONNECT-CANCELLED] "))
        #expect(GatewayHelloFailure(opened: false, reason: .failed).description.hasPrefix("[WS-CONNECT-FAILED] "))
        #expect(GatewayHello.valid(hello: Self.hello))
        #expect(GatewayHello.url.absoluteString == "wss://gateway.discord.gg/?v=10&encoding=json")
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'GatewayHello' in scope`, `cannot find 'GatewayHelloFailure' in scope` ve `cannot find type 'GatewayHelloFailure' in scope`. Tür henüz olmadığı için neden vektörlerinde `cannot infer contextual base in reference to member '…'` hataları da görülür (`response`, `transport`, `webSocket`, `timeout`, `canceled`, `failed`); tür tanımlanınca kaybolur.

- [ ] **Adım 3: HELLO denetimini yaz** (`swift` bloğu 10)

- `wss://gateway.discord.gg/?v=10&encoding=json`'a, HTTPS tanısıyla aynı yapılandırmayla, sabit başlıklarla ve aynı kimlik doğrulama yanıtıyla bağlanılır; mesaj sınırı 16 KiB'dir.
- İlk mesaj metin olmalı ve `{"op": 10, "d": {"heartbeat_interval": 1...300000}}` biçimini, yalnız tam sayılarla taşımalıdır (Windows `ValidateHello`).
- Başarıdan sonra bağlantı normal kapatılır, kapanış en fazla 1 sn beklenir. Sıfırlanan bir tünel kayıtta başarısız bir Gateway bağlantısı gibi görünürdü.
- Hata, bağlantının açılıp açılmadığını (`HELLO` ya da `CONNECT`) ve sabit bir nedeni taşır (Windows `GatewayProbeException`):
  - `RESPONSE`: kapanan karşı taraf, sınırı aşan (`EMSGSIZE`) ya da yanlış türde mesaj;
  - `WEBSOCKET`: reddedilen el sıkışma;
  - `TRANSPORT`: proxy, bağlantı ya da TLS hatası; başka POSIX hataları.
- Karşı tarafın kapatıp kapatmadığı ancak görev tamamlanınca kesindir: hata sınıflandırılmadan önce tamamlanma en fazla 1 sn beklenir. Bu Mac'te kapanış kodu, alma hatası bildirilmeden önce konuyor; bekleme başka bir sıraya karşı korumadır ve testle ayırt edilemez.

```swift
import Foundation

/// Why the Gateway WebSocket check failed (Windows `GatewayProbeException`): whether the connection had opened, and a
/// fixed reason. The message holds nothing from the peer.
public struct GatewayHelloFailure: Error, Equatable, CustomStringConvertible {
    public enum Reason: String, Sendable {
        case timeout = "TIMEOUT"
        case response = "RESPONSE"
        case webSocket = "WEBSOCKET"
        case transport = "TRANSPORT"
        case canceled = "CANCELLED"
        case failed = "FAILED"
    }

    /// Whether the WebSocket connection had opened: `[WS-HELLO-…]` then, `[WS-CONNECT-…]` before.
    public let opened: Bool
    public let reason: Reason

    public var message: String {
        "[WS-" + (opened ? "HELLO" : "CONNECT") + "-" + reason.rawValue + "] Gateway WebSocket kontrolü tamamlanamadı. HTTP API başarısı " +
            "canlı mesaj bağlantısını doğrulamaz."
    }

    public var description: String { message }
}

/// The anonymous Gateway WebSocket check through the loopback proxy (Windows `GatewayChecks`): it connects to Discord's
/// Gateway, reads only the public HELLO and closes normally. It never sends IDENTIFY, a token or account data. Like
/// `ConnectivityProbe`, it goes only through the proxy and ends within 10 seconds.
public enum GatewayHello {
    static let url = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    static let maxHelloBytes = 16384
    static let deadline: TimeInterval = 10

    /// Returns the summary to show; throws `GatewayHelloFailure`, or `CancellationError` once `cancel` is canceled.
    public static func check(proxyPort: UInt16, cancel: Cancellation = Cancellation()) throws -> String {
        try check(url: url, proxyPort: proxyPort, cancel: cancel)
        return "[WS-OK] Gateway WebSocket bağlantısı ve HELLO yanıtı proxy üzerinden doğrulandı. Bu kontrol hesap oturumunu, mesaj " +
            "gönderimini veya ses/ekran paylaşımını doğrulamaz."
    }

    static func check(url: URL, proxyPort: UInt16, cancel: Cancellation, deadline: TimeInterval = deadline) throws {
        try cancel.check()
        let observer = SocketObserver()
        let session = URLSession(configuration: ConnectivityProbe.configuration(proxyPort: proxyPort, deadline: deadline), delegate: observer,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        ConnectivityProbe.setFixedHeaders(&request)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maxHelloBytes
        let unregister = cancel.whenCanceled { task.cancel() }
        defer { unregister() }
        task.resume()
        task.receive { observer.received($0) }
        let expired = observer.done.wait(timeout: .now() + deadline) == .timedOut
        if expired {
            task.cancel()
            _ = observer.done.wait(timeout: .now() + 5)
        }
        try cancel.check()
        let (opened, outcome) = observer.result
        if expired { throw GatewayHelloFailure(opened: opened, reason: .timeout) }
        switch outcome {
        case .success(.string(let text))?:
            guard valid(hello: text) else { throw GatewayHelloFailure(opened: true, reason: .response) }
        case .success?:
            throw GatewayHelloFailure(opened: true, reason: .response)
        case .failure(let error)?:
            // Whether the peer closed is known for certain once the task has completed.
            _ = observer.completed.wait(timeout: .now() + 1)
            throw GatewayHelloFailure(opened: opened, reason: reason(for: error, closedByPeer: observer.peerClosed || task.closeCode != .invalid))
        case nil:
            throw GatewayHelloFailure(opened: opened, reason: .failed)
        }
        // A completed check closes normally: a reset tunnel would look like a failed Gateway connection in the log.
        // Waiting for the close is bounded and best effort.
        task.cancel(with: .normalClosure, reason: Data("diagnostic complete".utf8))
        _ = observer.completed.wait(timeout: .now() + 1)
    }

    /// `{"op": 10, "d": {"heartbeat_interval": 1...300000}}` with integers only (Windows `ValidateHello`).
    static func valid(hello text: String) -> Bool {
        guard text.utf8.count <= maxHelloBytes, let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              integer(payload["op"]) == 10, let data = payload["d"] as? [String: Any],
              let interval = integer(data["heartbeat_interval"]), (1...300_000).contains(interval) else { return false }
        return true
    }

    /// Windows `FailureCategory`: a closing peer, a message over the limit or of the wrong kind is a response failure;
    /// a refused handshake is a WebSocket failure; the proxy, the connection or TLS failing is a transport failure.
    static func reason(for error: Error, closedByPeer: Bool) -> GatewayHelloFailure.Reason {
        if closedByPeer { return .response }
        let failure = error as NSError
        let cfNetwork = failure.domain == NSURLErrorDomain || failure.domain == kCFErrorDomainCFNetwork as String
        if cfNetwork && [306, 310, 311].contains(failure.code) { return .transport }
        if failure.domain == NSPOSIXErrorDomain { return failure.code == Int(EMSGSIZE) ? .response : .transport }
        guard failure.domain == NSURLErrorDomain else { return .failed }
        switch URLError.Code(rawValue: failure.code) {
        case .timedOut: return .timeout
        case .cancelled: return .canceled
        case .badServerResponse: return .webSocket
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .transport
        default: return .failed
        }
    }

    /// A JSON integer: not a Boolean, and without a fraction or exponent.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return nil }
        return number.intValue
    }
}

/// Watches one WebSocket task for `GatewayHello`; a redirect is not followed.
private final class SocketObserver: NSObject, URLSessionWebSocketDelegate {
    let done = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false
    private var closed = false
    private var outcome: Result<URLSessionWebSocketTask.Message, Error>?

    var result: (opened: Bool, outcome: Result<URLSessionWebSocketTask.Message, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        return (opened, outcome)
    }

    /// Whether the WebSocket closing handshake took place.
    var peerClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func received(_ outcome: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
        done.signal()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        opened = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(ConnectivityProbe.answer(challenge), nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completed.signal()
    }
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 126 tests in 18 suites passed`, uyarısız ve `skipped` olmadan.

---

### Görev 5: DNS seçimi

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/DnsSelectionTests.swift`, `macos/Sources/DiscordAccessKit/Connectivity/DnsSelection.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 11)

Windows `DnsSelection.RunOfflineChecks` senaryoları, yerine konan adaylarla:
- çalışan ilk aday çağırana kalır;
- başarısız aday sıradaki açılmadan önce kapatılır;
- hepsi başarısız olunca yalnız sabit ileti (DNS-E02) kalır, her aday bir kez denetlenip kapatılır;
- adı verilen sağlayıcı denetlenmez;
- HTTP 429 ya da iptal edilmiş denetim başka sağlayıcıyla denenmez;
- iptal: denetim sırasında, başarılı denetimden sonra, seçimden önce;
- açılamayan aday ve beklenmeyen denetim hatası başka sağlayıcıyla gizlenmez;
- kapatılamayan aday seçimi durdurur.

```swift
import Foundation
import Testing
@testable import DiscordAccessKit

/// Scenarios from the Windows `DnsSelection.RunOfflineChecks`, with stand-in candidates.
@Suite struct DnsSelectionTests {
    typealias Collected = ProxyGateTests.Collected

    final class Fixture: DnsCandidate {
        let provider: DnsProvider
        private let events: Collected<String>
        var onVerify: ((Cancellation) throws -> Void)?
        var onClose: (() throws -> Void)?
        private(set) var verifications = 0
        private(set) var closings = 0

        init(provider: DnsProvider, events: Collected<String>) {
            self.provider = provider
            self.events = events
        }

        func verify(cancel: Cancellation) throws {
            verifications += 1
            events.append("verify:" + provider.name.rawValue)
            try onVerify?(cancel)
        }

        func close() throws {
            closings += 1
            events.append("close:" + provider.name.rawValue)
            try onClose?()
        }
    }

    /// Opens fixtures, letting `prepare` set each one up by its index, and records them and the order of events.
    final class Opener {
        let events = Collected<String>()
        let logs = Collected<String>()
        private(set) var fixtures: [Fixture] = []
        private let prepare: (Fixture, Int) -> Void

        init(_ prepare: @escaping (Fixture, Int) -> Void = { _, _ in }) {
            self.prepare = prepare
        }

        func open(_ provider: DnsProvider, _ cancel: Cancellation) throws -> DnsCandidate {
            events.append("open:" + provider.name.rawValue)
            let fixture = Fixture(provider: provider, events: events)
            prepare(fixture, fixtures.count)
            fixtures.append(fixture)
            return fixture
        }

        func select(_ options: DnsOptions = .automatic, cancel: Cancellation = Cancellation()) throws -> DnsCandidate {
            try DnsSelection.select(options, open: open, log: logs.append, cancel: cancel)
        }
    }

    static let connectFailure = ConnectivityFailure(endpoint: .gateway, reason: .connect)

    @Test func keepsTheFirstCandidateThatWorksForTheCaller() throws {
        let opener = Opener()
        let winner = try opener.select()
        #expect(opener.fixtures.count == 1 && winner === opener.fixtures[0])
        #expect(opener.fixtures[0].verifications == 1 && opener.fixtures[0].closings == 0)
        #expect(opener.logs.all == ["DNS erişim kontrolü: Cloudflare (IP sertifikası) DoH | DNS TLS kayıt parçalama: kapalı",
                                    "DNS bağlantısı seçildi: Cloudflare (IP sertifikası) DoH | DNS TLS kayıt parçalama: kapalı"])
    }

    @Test func closesAFailedCandidateBeforeTheNextOneOpens() throws {
        let opener = Opener { fixture, index in
            if index == 0 { fixture.onVerify = { _ in throw Self.connectFailure } }
        }
        let winner = try opener.select()
        #expect(opener.fixtures.count == 2 && winner.provider.name == .cloudflare)
        #expect(opener.fixtures[0].closings == 1 && opener.fixtures[1].closings == 0)
        let events = opener.events.all
        #expect(try #require(events.firstIndex(of: "close:cloudflare-ip")) < #require(events.firstIndex(of: "open:cloudflare")))
        #expect(opener.logs.all.contains("DNS erişim kontrolü: " + Self.connectFailure.message))
    }

    @Test func keepsOnlyAFixedMessageWhenEveryCandidateFails() {
        let opener = Opener { fixture, _ in fixture.onVerify = { _ in throw ConnectivityFailure(endpoint: .gateway, reason: .timeout) } }
        #expect(throws: KitError.dnsSelectionFailed()) { try opener.select() }
        #expect(opener.fixtures.count == 3)
        #expect(opener.fixtures.allSatisfy { $0.verifications == 1 && $0.closings == 1 })
    }

    @Test func opensANamedProviderWithoutCheckingIt() throws {
        let opener = Opener { fixture, _ in fixture.onVerify = { _ in Issue.record("a named provider was checked") } }
        let winner = try opener.select(DnsOptions(provider: .google))
        #expect(opener.fixtures.count == 1 && winner.provider == DnsProvider(.google))
        #expect(opener.fixtures[0].verifications == 0 && opener.fixtures[0].closings == 0)
    }

    /// A rate limit is never retried with another provider, and neither is a canceled check.
    @Test(arguments: [ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 429, responseKind: .html),
                      ConnectivityFailure(endpoint: .gateway, reason: .canceled)])
    func stopsAtARateLimitOrACanceledCheck(failure: ConnectivityFailure) {
        let opener = Opener { fixture, _ in fixture.onVerify = { _ in throw failure } }
        #expect(throws: failure) { try opener.select() }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }

    @Test func stopsAndClosesWhenCanceledDuringTheCheck() {
        let cancel = Cancellation()
        let opener = Opener { fixture, _ in
            fixture.onVerify = { cancel in
                cancel.cancel()
                try cancel.check()
            }
        }
        #expect(throws: CancellationError.self) { try opener.select(cancel: cancel) }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }

    @Test func closesACheckedCandidateWhenCanceledMeanwhile() {
        let cancel = Cancellation()
        let opener = Opener { fixture, _ in fixture.onVerify = { cancel in cancel.cancel() } }
        #expect(throws: CancellationError.self) { try opener.select(cancel: cancel) }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }

    @Test func opensNothingWhenAlreadyCanceled() {
        let cancel = Cancellation()
        cancel.cancel()
        let opener = Opener()
        #expect(throws: CancellationError.self) { try opener.select(cancel: cancel) }
        #expect(opener.fixtures.isEmpty)
    }

    /// Package integrity and engine start failures must not be hidden by trying another provider.
    @Test(arguments: [KitError(code: "PKG-E03", message: "SYNTHETIC_SECRET") as Error, ConnectivityFailure(endpoint: .gateway, reason: .connect)])
    func neverHidesAFailureToOpen(error: Error) {
        var opens = 0
        var thrown: Error?
        do {
            _ = try DnsSelection.select(.automatic, open: { _, _ in
                opens += 1
                throw error
            }, cancel: Cancellation())
        } catch {
            thrown = error
        }
        #expect(opens == 1)
        #expect((thrown as? KitError) == (error as? KitError) && (thrown as? ConnectivityFailure) == (error as? ConnectivityFailure))
        #expect(thrown != nil)
    }

    @Test func neverRetriesAnUnexpectedCheckError() {
        let opener = Opener { fixture, _ in fixture.onVerify = { _ in throw POSIXError(.EPERM) } }
        #expect(throws: POSIXError(.EPERM)) { try opener.select() }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }

    /// Windows `DnsConnection.Dispose`: a candidate that cannot be closed safely stops the selection.
    @Test func stopsWhenACandidateCannotBeClosed() {
        let opener = Opener { fixture, _ in
            fixture.onVerify = { _ in throw Self.connectFailure }
            fixture.onClose = { throw KitError.dnsCandidateNotClosed() }
        }
        #expect(throws: KitError.dnsCandidateNotClosed()) { try opener.select() }
        #expect(opener.fixtures.count == 1 && opener.fixtures[0].closings == 1)
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'DnsSelection' in scope` ve `cannot find type 'DnsCandidate' in scope`, ayrıca buna bağlı `cannot infer contextual base in reference to member 'cloudflare'`.

- [ ] **Adım 3: Seçimi yaz** (`swift` bloğu 12)

Her aday tek bir yerde kapatılır: başarısız denetimden sonra ya da ölümcül bir hatada, hata yeniden atılmadan önce. Kapatma hatası asıl hatanın yerine geçer ve seçimi durdurur (Windows'taki `finally { Dispose }` gibi). Kayıtlara yalnız sağlayıcı açıklaması ve sabit hata iletisi yazılır.

```swift
/// One DNS candidate's connection (Windows `IDnsCandidateConnection`).
public protocol DnsCandidate: AnyObject {
    var provider: DnsProvider { get }
    /// Checks that Discord answers through this candidate; throws `ConnectivityFailure` when it does not.
    func verify(cancel: Cancellation) throws
    /// Closes the candidate completely; throws when that cannot be done safely.
    func close() throws
}

/// Picks the session's DNS candidate (Windows `DnsSelection`).
public enum DnsSelection {
    /// Opens the candidates of `options` one after another and returns the first that works; the caller then owns it.
    /// In automatic mode each candidate is verified, and one that fails with a `ConnectivityFailure` is closed before the
    /// next opens. A provider the user named is opened without verification, as before automatic selection existed.
    ///
    /// These end the selection without trying another provider: a failure to open (package integrity or engine start
    /// must not be hidden by another provider), any other error, an HTTP 429 (selection never tries to get past Discord's
    /// rate limit with another endpoint), a canceled check, a candidate that cannot be closed, and cancellation
    /// (`CancellationError`). When every candidate fails, only a fixed message is kept (DNS-E02).
    public static func select(_ options: DnsOptions, open: (DnsProvider, Cancellation) throws -> DnsCandidate,
                              log: ((String) -> Void)? = nil, cancel: Cancellation) throws -> DnsCandidate {
        for provider in options.candidates {
            try cancel.check()
            let candidate = try open(provider, cancel)
            let selected: Bool
            do {
                selected = try attempt(candidate, automatic: options.isAutomatic, log: log, cancel: cancel)
            } catch {
                try candidate.close()
                throw error
            }
            if selected {
                log?("DNS bağlantısı seçildi: " + provider.description)
                return candidate
            }
            // Completely closed before the next opens; a failure to close ends the selection.
            try candidate.close()
        }
        throw KitError.dnsSelectionFailed()
    }

    /// True when `candidate` is selected, false when it failed its check and the next one may be tried.
    private static func attempt(_ candidate: DnsCandidate, automatic: Bool, log: ((String) -> Void)?, cancel: Cancellation) throws -> Bool {
        try cancel.check()
        if automatic {
            log?("DNS erişim kontrolü: " + candidate.provider.description)
            do {
                try candidate.verify(cancel: cancel)
            } catch let failure as ConnectivityFailure {
                try cancel.check()
                guard !(failure.reason == .http && failure.httpStatus == 429), failure.reason != .canceled else { throw failure }
                log?("DNS erişim kontrolü: " + failure.message)
                return false
            }
        }
        try cancel.check()
        return true
    }
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 137 tests in 19 suites passed`, uyarısız ve `skipped` olmadan.

---

### Görev 6: DNS adayı

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/DnsConnectionTests.swift`, `macos/Sources/DiscordAccessKit/Connectivity/DnsConnection.swift`
- Modify: `macos/Sources/DiscordAccessKit/Engine/EngineProcess.swift` (tam dosya; eski SHA-256 `e5d95604575c6103ac061999e571ba47eeb5a67bd2dcc6eea63e319434673b25`)
- Modify: `macos/Sources/DiscordAccessKit/Gate/ProxyGate.swift` (tam dosya; eski SHA-256 `c6c99b07a82361daed6653efa09b94ff2c138ffa0f8570020c45226f22a9e979`)

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 13)

Gerçek motor ve kapıyla. Bağlantı denetimi internet gerektirdiği için testler denetimin yerine kendi işlevlerini koyar; gerçek denetim Görev 7'dedir. Sınanan durumlar:
- denetime kapının portunun gitmesi ve kapının bu süreci kabul etmesi: politika dışı bir hedef, kabul edilmeyen istemcinin alacağı 403 olmadan reddedilir;
- kapı satırlarının `Proxy: ` önekiyle gelmesi;
- kapatmanın motoru toplaması ve portu bırakması, ikinci kapatmanın bir şey yapmaması;
- duran motorun bağlantı hatası yerine ENG-E02 olarak bildirilmesi: denetim motor giderken başarısız olsa da (motor henüz toplanmamışken), motor gittikten sonra geçse de; çalışan motorun bağlantı hatasının olduğu gibi geçmesi;
- iptal edilen açılışın motor başlatmaması ve iptal edilen denetim;
- motor başlarken iptal: dinleyici beklenirken motor durdurulur, geride süreç kalmaz;
- kapının kendini kapattığının aday seçildikten sonra ayarlanan işleyiciye ulaşması ve kapatmanın işleyiciyi temizlemesi: test kabul hatası oluşturamadığı için kapının `faulted`'ını kapı gibi çağırır;
- ilk motor açılışı için 30 sn sınırı.

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// A DNS candidate with the real engine and gate. The connectivity check itself needs the internet, so these tests put
/// their own check in its place; the live check is `LiveConnectivityTests`.
@Suite struct DnsConnectionTests {
    typealias Collected = ProxyGateTests.Collected

    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    static func admission() throws -> PeerAdmission {
        try PeerAdmission(approved: [ProxyGateTests.netcat], readyTime: Date())
    }

    static func open(image: EngineImage? = nil, trace: ((String) -> Void)? = nil, cancel: Cancellation = Cancellation(),
                     check: @escaping (UInt16, Cancellation) throws -> Void) throws -> DnsConnection {
        try DnsConnection.open(provider: DnsProvider(.cloudflareIP), image: image ?? EngineImage.verify(path: TestEngine.path), admission: admission(),
                               trace: trace, cancel: cancel, readyTimeout: DnsConnection.readyTimeout, check: check)
    }

    /// The check gets the gate's port, and the gate admits this process: a request for a host outside the policy is
    /// refused without the 403 that a client that is not admitted gets.
    @Test(.enabled(if: TestEngine.isAvailable))
    func opensAnEngineAndAGateThatAdmitsThisProcess() throws {
        let lines = Collected<String>()
        let checked = Collected<UInt16>()
        let connection = try Self.open(trace: lines.append) { port, _ in
            checked.append(port)
            let reply = try exchange(port: port, request: "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
            #expect(reply == "")
        }
        #expect(connection.engine.isRunning && ProcessInspector.ownsLoopbackListener(pid: connection.engine.pid, port: connection.engine.port))
        try connection.verify(cancel: Cancellation())
        #expect(checked.all == [connection.gate.port] && connection.gate.port != connection.engine.port)
        #expect(waitFor { lines.all.contains("Proxy: Failure stage=RequestPolicy target=example.com:443 category=ForbiddenHost") ? true : nil } == true)
        try connection.close()
        try connection.close()
        #expect(!connection.engine.isRunning)
        // A child that another test is spawning may hold a copy of the listener until it executes.
        #expect(waitFor {
            do {
                _ = try LoopbackClient(port: connection.gate.port)
                return nil
            } catch {
                return error as? POSIXError == POSIXError(.ECONNREFUSED) ? true : nil
            }
        } == true)
    }

    /// An engine that stopped is reported as such, so that selection does not try another provider: whether the check
    /// failed as the engine went or still passed.
    @Test(.enabled(if: TestEngine.isAvailable), arguments: [true, false])
    func reportsAStoppedEngineInsteadOfAConnectivityFailure(checkFails: Bool) throws {
        let engine = Box<EngineProcess?>(nil)
        let connection = try Self.open { _, _ in
            let process = try #require(engine.value)
            kill(process.pid, SIGKILL)
            // Thrown at once: the engine has not exited yet, let alone been reaped.
            if checkFails { throw ConnectivityFailure(endpoint: .gateway, reason: .connect) }
            #expect(waitFor { process.isRunning ? nil : true } == true)
        }
        engine.value = connection.engine
        #expect(throws: KitError.engineStopped()) { try connection.verify(cancel: Cancellation()) }
        try connection.close()
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func passesOnTheConnectivityFailureOfARunningEngine() throws {
        let failure = ConnectivityFailure(endpoint: .gateway, reason: .timeout)
        let connection = try Self.open { _, _ in throw failure }
        defer { try? connection.close() }
        #expect(throws: failure) { try connection.verify(cancel: Cancellation()) }
        #expect(connection.engine.isRunning)
    }

    @Test(.enabled(if: TestEngine.isAvailable))
    func startsNothingWhenCanceled() throws {
        let copy = try TestEngine.runnableCopy(named: "dns-connection")
        let image = try EngineImage.verify(path: copy)
        let cancel = Cancellation()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try Self.open(image: image, cancel: cancel) { _, _ in } }
        #expect(EngineProcessTests.processes(at: copy, parent: getpid()).isEmpty)
        let checking = try Self.open(image: image) { _, _ in }
        let running = Cancellation()
        running.cancel()
        #expect(throws: CancellationError.self) { try checking.verify(cancel: running) }
        try checking.close()
        #expect(EngineProcessTests.processes(at: copy, parent: getpid()).isEmpty)
    }

    /// Canceling ends the wait for a starting engine's listener; the engine is stopped and nothing is left running.
    @Test(.enabled(if: TestEngine.isAvailable))
    func stopsAStartingEngineWhenCanceled() throws {
        let copy = try TestEngine.runnableCopy(named: "dns-connection-start")
        let cancel = Cancellation()
        cancel.cancel()
        #expect(throws: CancellationError.self) {
            _ = try EngineProcess.start(image: EngineImage.verify(path: copy), dns: DnsProvider(.google), readyTimeout: 30, cancel: cancel)
        }
        #expect(EngineProcessTests.processes(at: copy, parent: getpid()).isEmpty)
    }

    /// A gate that closes itself reaches the handler set once the candidate is selected (Windows `Gate.Faulted`). A test
    /// cannot make accepting fail, so it calls the gate's `faulted` as the gate would.
    @Test(.enabled(if: TestEngine.isAvailable))
    func relaysAGateFaultToTheHandlerSetLater() throws {
        let connection = try Self.open { _, _ in }
        defer { try? connection.close() }
        let faulted = try #require(connection.gate.faulted)
        let calls = CancellationTests.Counter()
        faulted()
        connection.onGateFault = { calls.increment() }
        faulted()
        connection.onGateFault = nil
        faulted()
        // Closing clears the handler: it does not outlive the candidate.
        connection.onGateFault = { calls.increment() }
        try connection.close()
        faulted()
        #expect(calls.count == 1)
    }

    @Test func waitsLongerThanWindowsForTheFirstEngineStart() {
        #expect(DnsConnection.readyTimeout == 30)
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'DnsConnection' in scope`, `cannot find type 'DnsConnection' in scope` ve `EngineProcess.start` henüz iptal almadığı için `extra argument 'cancel' in call`. Tür henüz olmadığı için `no calls to throwing functions occur within 'try' expression` uyarısı da görülür; tür tanımlanınca kaybolur.

- [ ] **Adım 3: Motor başlarken iptali ekle** (`swift` bloğu 14; yardımcıyla, eski hash verilerek)

`EngineProcess.start` isteğe bağlı bir `Cancellation` alır. Dinleyici beklenirken her turda iptal denetlenir; iptal edilince motor durdurulur ve `CancellationError` atılır. Varsayılan hazır olma sınırı Windows'taki gibi 12 sn kalır; 1a'nın çağıranları değişmez. Test, önceden iptal edilmiş belirteçle ilk turdaki denetimi sınar. Beklemenin ortasında gelen iptal testle oluşturulamaz, çünkü motor hızla dinler; her turdaki denetim incelemeyle doğrulanır.

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

    /// Starts an engine for `dns` and waits up to `readyTimeout` for its listener. Canceling `cancel` ends the wait: the
    /// engine is stopped and `CancellationError` is thrown.
    public static func start(image: EngineImage, dns: DnsProvider, readyTimeout: TimeInterval = 12, cancel: Cancellation? = nil) throws -> EngineProcess {
        // The file may have changed since `image` was verified; measuring it again keeps the PKG-E* codes accurate.
        let current = try EngineImage.verify(path: image.path, expected: image.identity)
        let port = try reserveLoopbackPort()
        let username = try Secrets.randomToken()
        let password = try Secrets.randomToken()
        let config = try EngineConfig.json(dns: dns, username: username, password: password, port: port)
        let engine = EngineProcess(pid: try spawn(image: current, input: config), port: port, username: username, password: password)
        do {
            try engine.waitUntilListening(timeout: readyTimeout, cancel: cancel)
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

    private func waitUntilListening(timeout: TimeInterval, cancel: Cancellation?) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try cancel?.check()
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

- [ ] **Adım 4: Kapının hata işleyicisini testlere aç** (`swift` bloğu 15; yardımcıyla, eski hash verilerek)

Tek değişiklik: `faulted` artık `private` değildir. Kabul hatası testle oluşturulamaz (1c); aday testi işleyiciyi kapı gibi çağırır.

```swift
import Darwin
import Foundation

/// What the gate needs of the engine run it forwards to. `isRunning` must stay false once the engine has exited, and
/// `pid` must not belong to another process while `isRunning` is true; an unreaped child, as `EngineProcess`, meets both.
public protocol GateEngine: AnyObject {
    var pid: pid_t { get }
    var port: UInt16 { get }
    var authorization: String { get }
    var isRunning: Bool { get }
}

extension EngineProcess: GateEngine {}

/// The local proxy Discord uses (Windows `ProcessGate`). Each connection goes through these steps in order:
/// 1. The process holding its client end must be admitted (`PeerAdmission`); a refused client gets `403 Forbidden`.
/// 2. The request header (32 KiB at most, read within `headerTimeout`) must pass `RequestPolicy`, which adds the
///    engine credential.
/// 3. The engine must have accepted the gate's connection itself before a single byte is sent to it.
/// 4. Bytes are relayed both ways; once one side has finished, the other may finish within `drainTimeout`.
///
/// At most `capacity` connections run at once, each on its own thread. Diagnostic lines (`GateDiagnostics`) go to
/// `trace`, within `TraceBudget`. The gate runs until `close()`.
public final class ProxyGate {
    public static let maxConnections = 64
    static let forbidden = Array("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

    public let port: UInt16
    private let admission: PeerAdmission
    private let engine: GateEngine
    private let headerTimeout: TimeInterval
    private let drainTimeout: TimeInterval
    private let capacity: Int
    private let trace: ((String) -> Void)?
    /// Internal so that tests can stand in for an accept failure, which they cannot cause.
    let faulted: (() -> Void)?
    private let budget = TraceBudget()
    private let listener: Int32
    private let stopRead: Int32
    private let lock = NSLock()
    /// Left when the accept thread has closed the listener.
    private let acceptEnded = DispatchGroup()
    /// Weak: the thread's block holds the gate, so a strong reference would keep both alive for good.
    private weak var acceptThread: Thread?
    private var stopWrite: Int32
    private var active = 0
    private var started = false
    private var closed = false

    /// Listens on 127.0.0.1:`port` (0 picks a free port). `trace` and `faulted` are called concurrently from the gate's
    /// threads, so they must be thread-safe and must not block; connections that were ending may still call `trace`
    /// briefly after `close()` returns. `faulted` reports that the gate closed itself because accepting connections
    /// failed; its listener is closed by then, so the handler may start a new gate on the same port at once.
    public init(admission: PeerAdmission, engine: GateEngine, port: UInt16 = 0, headerTimeout: TimeInterval = 15,
                drainTimeout: TimeInterval = 30, capacity: Int = ProxyGate.maxConnections,
                trace: ((String) -> Void)? = nil, faulted: (() -> Void)? = nil) throws {
        precondition(headerTimeout > 0 && drainTimeout > 0 && drainTimeout <= 30 && (1...Self.maxConnections).contains(capacity))
        let stop = try LoopbackSocket.stopPipe()
        let bound: (descriptor: Int32, port: UInt16)
        do {
            bound = try LoopbackSocket.listen(port: port, backlog: Int32(Self.maxConnections))
        } catch {
            Darwin.close(stop.read)
            Darwin.close(stop.write)
            throw error
        }
        listener = bound.descriptor
        self.port = bound.port
        (stopRead, stopWrite) = stop
        self.admission = admission
        self.engine = engine
        self.headerTimeout = headerTimeout
        self.drainTimeout = drainTimeout
        self.capacity = capacity
        self.trace = trace
        self.faulted = faulted
    }

    deinit {
        // A started gate lives until its accept thread ends, which happens only after `close()`.
        if !closed {
            Darwin.close(listener)
            Darwin.close(stopWrite)
        }
        Darwin.close(stopRead)
    }

    /// Connections being handled now.
    public var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !closed else { return }
        started = true
        acceptEnded.enter()
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "DiscordAccess gate"
        acceptThread = thread
        thread.start()
    }

    /// Stops accepting and ends every connection; calling it again changes nothing. When it returns the listener is
    /// closed, so a new gate can take the port at once (Windows `Dispose`); only when called from `trace` on the accept
    /// thread does it return before that. It waits for the accept thread, which may be inside `trace`, so it must not be
    /// called while holding a lock or queue that `trace` waits for. Waits end at once; a connection whose admission is
    /// being checked ends when the check returns.
    public func close() {
        _ = markClosed()
        lock.lock()
        let thread = acceptThread
        lock.unlock()
        // The accept thread closes the listener as soon as it wakes. Called on that thread (from `trace`), close() must
        // not wait for it.
        if Thread.current !== thread { acceptEnded.wait() }
    }

    /// Marks the gate closed and closes the write end of the stop pipe, which wakes every wait of the gate; closes the
    /// listener too when no accept thread was started. False when the gate was closed already.
    private func markClosed() -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        closed = true
        let write = stopWrite
        stopWrite = -1
        let ownsListener = !started
        lock.unlock()
        Darwin.close(write)
        if ownsListener { Darwin.close(listener) }
        return true
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func acceptLoop() {
        let failed = acceptConnections()
        // A failure closes the gate as `close()` would; the listener is closed before `faulted` is reported (as Windows
        // stops its listener before `Faulted`).
        let unexpected = failed && markClosed()
        Darwin.close(listener)
        acceptEnded.leave()
        if unexpected { faulted?() }
    }

    /// Accepts connections until the gate closes (false) or accepting fails (true).
    private func acceptConnections() -> Bool {
        while true {
            var watched = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: stopRead, events: Int16(POLLIN), revents: 0)]
            if poll(&watched, 2, -1) < 0 {
                if errno == EINTR { continue }
                return true
            }
            if watched[1].revents != 0 { return false }
            guard watched[0].revents & Int16(POLLIN) != 0 else { return true }
            let accepted: (descriptor: Int32, peer: sockaddr_in)?
            do {
                accepted = try LoopbackSocket.accept(listener)
            } catch {
                return true
            }
            guard let (client, peer) = accepted else { continue }
            lock.lock()
            if closed || active >= capacity {
                let full = !closed
                lock.unlock()
                Darwin.close(client)
                if full { emit(GateDiagnostics.capacityFailure, failure: true) }
                continue
            }
            active += 1
            lock.unlock()
            Thread { [self] in handle(client, peer: peer) }.start()
        }
    }

    private func handle(_ client: Int32, peer: sockaddr_in) {
        var backend: Int32 = -1
        defer {
            Darwin.close(client)
            if backend >= 0 { Darwin.close(backend) }
            lock.lock()
            active -= 1
            lock.unlock()
        }
        if let reason = refusal(peer: peer) {
            if !isClosed { emit(GateDiagnostics.unownedClient(reason: reason), failure: true) }
            try? LoopbackSocket.write(client, Self.forbidden, until: .now + .seconds(2), stop: stopRead)
            return
        }
        var stage = GateStage.headerRead
        var target = "unknown"
        do {
            let (header, remainder) = try LoopbackSocket.readHeader(client, until: .now + .seconds(headerTimeout), stop: stopRead)
            let text = String(decoding: header, as: UTF8.self)
            target = GateDiagnostics.safeTarget(text)
            stage = .requestPolicy
            let outgoing: String
            do {
                outgoing = try RequestPolicy.rewrite(text, authorization: engine.authorization)
            } catch let refusal as RequestFailure {
                throw GateFailure.refused(refusal)
            }
            emit("Owned request " + target, failure: false)
            stage = .backendConnect
            backend = try LoopbackSocket.connect(port: engine.port, until: .now + .seconds(5), stop: stopRead)
            // No request, credential or tunnel byte is sent to a peer that is not the engine.
            stage = .backendIdentity
            guard let local = LoopbackSocket.localPort(backend), engineAccepted(localPort: local) else { throw GateFailure.invalidData }
            emit("Backend identity verified target=" + target, failure: false)
            stage = .backendWrite
            try LoopbackSocket.write(backend, Array(outgoing.utf8) + remainder, until: .now + .seconds(5), stop: stopRead)
            stage = .relay
            let outcome = Relay.run(client: client, engine: backend, stop: stopRead, drainTimeout: drainTimeout)
            if case .failed(let error, let direction, let elapsed) = outcome, !isClosed {
                emit(GateDiagnostics.relayFailure(target: target, error: error, direction: direction, elapsedMilliseconds: elapsed), failure: true)
            }
        } catch {
            if !isClosed { emit(GateDiagnostics.failure(stage: stage, target: target, error: error as? GateFailure ?? .unexpected), failure: true) }
        }
    }

    /// Why the client may not use the gate (the diagnostic reason), or nil when the process holding its end is admitted.
    /// Only a peer at exactly 127.0.0.1 is matched against the processes' sockets.
    private func refusal(peer: sockaddr_in) -> String? {
        guard let clientPort = LoopbackSocket.loopbackPeerPort(peer) else { return "RemoteAddress" }
        if let refusal = admission.refusal(clientPort: clientPort, gatePort: port) { return refusal.diagnostic }
        // An admission can finish after `close()`; the gate's own state decides.
        return isClosed ? PeerAdmission.Refusal.closed.diagnostic : nil
    }

    /// The engine accepted the gate's connection itself (Windows `ExpectedBackend`): it is running, it holds its end of
    /// the connection, and it is still running afterwards, so the pid that held it was not reused in between. Only the
    /// engine's descriptors are inspected. The engine accepts on its own schedule, so its end may take a moment to appear.
    private func engineAccepted(localPort: UInt16) -> Bool {
        guard engine.isRunning else { return false }
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline && !isClosed {
            if ProcessInspector.holdsLoopbackConnection(pid: engine.pid, localPort: engine.port, remotePort: localPort) == true { return engine.isRunning }
            usleep(5_000)
        }
        return false
    }

    private func emit(_ line: String, failure: Bool) {
        guard let trace, budget.admit(failure: failure) else { return }
        trace(line)
    }
}
```

- [ ] **Adım 5: Adayı yaz** (`swift` bloğu 16)

- Motor `EngineProcess.start`'la, adayın iptaliyle başlar ve dinleyicisini 30 sn içinde açması beklenir: macOS yeni bir çalıştırılabilir dosyayı ilk çalıştırmada tarar (yük altında 7–10 sn görüldü). Motor çıkarsa sınır beklenmez. İptalin motor başlangıcına geçirildiği testle ayırt edilemez: önceden iptal edilmiş belirteçle hiçbir motor başlamaz, başlayan motorun yarıda kesilmesi ise zamanlamaya bağlıdır. `EngineProcess`'in iptali Adım 1'deki testle sınanır; geçirme incelemeyle doğrulanır.
- Kapı bu süreci tanı izniyle kabul eder. Windows'taki gibi bu izin seçilen adayda oturum boyunca açık kalır.
- Kapı kendini kapatırsa (`faulted`) bu, `onGateFault` işleyicisine iletilir. İşleyici aday seçildikten sonra ayarlanır (Windows `Gate.Faulted`); oturum onu 1g'de kullanır. Kapatma işleyiciyi temizler: oturumu tutan bir işleyici aday kapanınca bırakılır. Kapanışla yarışan bir arıza yine de bir kez bildirilebilir (Windows olayındaki gibi).
- Denetim bağlantı hatası verince motor 0,5 sn izlenir: çöken motorun soketleri, süreç toplanmadan önce kapanır. Motor durmuşsa, denetim geçmiş olsa da, ENG-E02 atılır; seçim bu yüzden başka sağlayıcıya geçmez.
- Kapatma motoru toplayamazsa DNS-E03 atılır; başka aday başlatılmaz. Açılış iptal ya da motor hatasıyla biterse başlamış motor durdurulur; seçim o hatayla bittiği için motor toplanamasa da başka aday başlamaz.

```swift
import Foundation

/// One DNS candidate's engine and gate (Windows `DnsConnection`). The selected candidate becomes the session's engine and
/// gate. Its gate admits this process (`PeerAdmission.diagnosticAllowed`) for the connectivity checks, as on Windows.
public final class DnsConnection: DnsCandidate {
    /// The engine may take this long to own its listener: macOS scans a new executable the first time it runs, which
    /// took 7-10 seconds under load. An engine that exits is reported at once, without waiting.
    public static let readyTimeout: TimeInterval = 30

    public let provider: DnsProvider
    public let engine: EngineProcess
    public let gate: ProxyGate
    private let faults: FaultRelay
    private let check: (UInt16, Cancellation) throws -> Void
    private let lock = NSLock()
    private var closed = false

    private init(provider: DnsProvider, engine: EngineProcess, gate: ProxyGate, faults: FaultRelay,
                 check: @escaping (UInt16, Cancellation) throws -> Void) {
        self.provider = provider
        self.engine = engine
        self.gate = gate
        self.faults = faults
        self.check = check
    }

    /// Called on the gate's thread when the gate closes itself because accepting connections failed. Set it once the
    /// candidate is selected, as Windows sets `Gate.Faulted` after selection. Closing the candidate clears it; a fault
    /// that raced with closing may still be reported once (as a Windows event may). The gate holds the handler until
    /// then, so the handler should hold the session weakly.
    public var onGateFault: (() -> Void)? {
        get { faults.handler }
        set { faults.handler = newValue }
    }

    /// Starts the engine for `provider` from `image` and a gate in front of it that admits through `admission`; gate
    /// lines go to `trace` with a `Proxy: ` prefix. Throws what starting the engine throws (`PKG-E*`, `ENG-E01`), or
    /// `CancellationError` (also while the engine starts). A started engine is stopped then; either error ends the
    /// selection, so no other candidate starts even if that engine could not be reaped.
    public static func open(provider: DnsProvider, image: EngineImage, admission: PeerAdmission, trace: ((String) -> Void)? = nil,
                            cancel: Cancellation) throws -> DnsConnection {
        try open(provider: provider, image: image, admission: admission, trace: trace, cancel: cancel, readyTimeout: readyTimeout) { port, cancel in
            try ConnectivityProbe.checkGateway(proxyPort: port, cancel: cancel)
        }
    }

    static func open(provider: DnsProvider, image: EngineImage, admission: PeerAdmission, trace: ((String) -> Void)?, cancel: Cancellation,
                     readyTimeout: TimeInterval, check: @escaping (UInt16, Cancellation) throws -> Void) throws -> DnsConnection {
        try cancel.check()
        let engine = try EngineProcess.start(image: image, dns: provider, readyTimeout: readyTimeout, cancel: cancel)
        let faults = FaultRelay()
        let gate: ProxyGate
        do {
            admission.diagnosticAllowed = true
            gate = try ProxyGate(admission: admission, engine: engine, trace: trace.map { trace in { trace("Proxy: " + $0) } }, faulted: faults.fire)
        } catch {
            guard engine.stop() else { throw KitError.dnsCandidateNotClosed() }
            throw error
        }
        let connection = DnsConnection(provider: provider, engine: engine, gate: gate, faults: faults, check: check)
        gate.start()
        do {
            try cancel.check()
        } catch {
            try connection.close()
            throw error
        }
        return connection
    }

    /// Checks Discord through this candidate's gate. An engine that stopped is reported as such (ENG-E02) rather than
    /// as a connectivity failure, so selection does not move on to another provider.
    public func verify(cancel: Cancellation) throws {
        try cancel.check()
        do {
            try check(gate.port, cancel)
        } catch let failure as ConnectivityFailure {
            try cancel.check()
            // A crashed engine's sockets close before it can be reaped: it gets a moment to show as stopped.
            guard !stops(within: 0.5) else { throw KitError.engineStopped() }
            throw failure
        }
        try cancel.check()
        guard engine.isRunning else { throw KitError.engineStopped() }
    }

    /// Whether the engine shows as stopped within `timeout`.
    private func stops(within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.isRunning {
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    /// Closes the gate and stops the engine; calling it again does nothing. Throws DNS-E03 when the engine could not be
    /// reaped: no other candidate may start then (Windows `Dispose`).
    public func close() throws {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        // The handler may hold the session, which holds this candidate: clearing it breaks that cycle.
        faults.handler = nil
        gate.close()
        guard engine.stop() else { throw KitError.dnsCandidateNotClosed() }
    }
}

/// Forwards a gate's fault to a handler that may be set after the gate was created.
private final class FaultRelay {
    private let lock = NSLock()
    private var current: (() -> Void)?

    var handler: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    func fire() {
        handler?()
    }
}
```

- [ ] **Adım 6: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 144 tests in 20 suites passed`, uyarısız ve `skipped` olmadan. Ardından `pgrep -fl "nc -d|sleep 30|sing-box"` hiçbir şey yazmaz.

---

### Görev 7: Canlı doğrulama

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/LiveConnectivityTests.swift`

- [ ] **Adım 1: Canlı denetimi yaz** (`swift` bloğu 17)

Dosya yalnız `DISCORDACCESS_LIVE` derleme bayrağıyla derlenir; normal test çalıştırmaları makineden çıkmaz ve çıktıda `skipped` görünmez. Canlı denetim gerçek motorla, bir oturum gibi Discord'un herkese açık uç noktalarına anonim istekler gönderir:
- otomatik seçim, ardından seçilen kapı üzerinden HTTPS denetimi ve Gateway WebSocket HELLO; kapının kendi satırları üç hedefin (`discord.com`, `updates.discord.com`, `gateway.discord.gg`) kapıdan geçtiğini gösterir;
- her sağlayıcının Gateway API'ye erişip erişmediği (kaydedilir, şart değildir).

```swift
#if DISCORDACCESS_LIVE
import Foundation
import Testing
@testable import DiscordAccessKit

/// Live checks on this Mac's own network, built only with `-Xswiftc -DDISCORDACCESS_LIVE` so that ordinary runs never
/// leave the machine. They reach Discord's public endpoints through the real engine, as a session does: automatic
/// selection followed by the HTTPS and Gateway HELLO checks through the selected gate, then each provider on its own.
/// Nothing is sent but anonymous requests; results are printed with a `LIVE` prefix for the live report.
@Suite(.serialized) struct LiveConnectivityTests {
    static func admission() throws -> PeerAdmission {
        try PeerAdmission(approved: [ProxyGateTests.netcat], readyTime: Date())
    }

    /// The gate's own lines show that the checks went through it.
    @Test func selectsAProviderAndReachesDiscordThroughIt() throws {
        let image = try EngineImage.verify(path: TestEngine.path)
        let admission = try Self.admission()
        let lines = ProxyGateTests.Collected<String>()
        let selected = try DnsSelection.select(.automatic, open: { provider, cancel in
            try DnsConnection.open(provider: provider, image: image, admission: admission, trace: lines.append, cancel: cancel)
        }, log: { print("LIVE " + $0) }, cancel: Cancellation())
        defer { try? selected.close() }
        let connection = try #require(selected as? DnsConnection)
        print("LIVE " + (try ConnectivityProbe.check(proxyPort: connection.gate.port)))
        print("LIVE " + (try GatewayHello.check(proxyPort: connection.gate.port)))
        for target in ["discord.com:443", "updates.discord.com:443", "gateway.discord.gg:443"] {
            #expect(waitFor { lines.all.contains("Proxy: Owned request " + target) ? true : nil } == true)
        }
    }

    /// Which providers work on this network: recorded, not required.
    @Test(arguments: DnsProvider.Name.allCases)
    func recordsWhetherEachProviderReachesDiscord(name: DnsProvider.Name) throws {
        let provider = DnsProvider(name)
        let connection = try DnsConnection.open(provider: provider, image: EngineImage.verify(path: TestEngine.path), admission: Self.admission(),
                                                cancel: Cancellation())
        defer { try? connection.close() }
        do {
            try connection.verify(cancel: Cancellation())
            print("LIVE " + provider.description + ": Gateway API erişildi")
        } catch {
            print("LIVE " + provider.description + ": " + String(describing: error))
        }
    }
}
#endif
```

- [ ] **Adım 2: Normal takım değişmez**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 144 tests in 20 suites passed`; çıktıda `LiveConnectivityTests` geçmez.

- [ ] **Adım 3: Canlı denetimi çalıştır**

İnternet gerektirir. Sonuçlar otomatik testlerden ayrı raporlanır.

Run: `swift test --package-path macos -Xswiftc -DDISCORDACCESS_LIVE --filter LiveConnectivityTests 2>&1 | grep -E "LIVE|Test run with"`
Expected (2026-10-15, bu Mac'in engelli ağı):
- `LIVE DNS bağlantısı seçildi: Cloudflare (IP sertifikası) DoH | DNS TLS kayıt parçalama: kapalı`;
- `LIVE Discord API ve güncelleme sunucusuna proxy üzerinden HTTPS erişimi doğrulandı. …` ve `LIVE [WS-OK] …`;
- her sağlayıcı için `Gateway API erişildi`;
- `✔ Test run with 2 tests in 1 suite passed`.

Başka bir ağda seçilen sağlayıcı ve sağlayıcı satırları farklı olabilir. Bayraklı derleme önbelleği değiştirir; sonraki normal çalıştırma bir kez yeniden derler.

---

### Görev 8: Son doğrulama ve teslim

- [ ] **Adım 1: Bütün testler**

Run: `swift test --package-path macos && python3 -B macos/Tests/build-engine.test.py`
Expected: `✔ Test run with 144 tests in 20 suites passed`, ardından `Ran 35 tests` ve `OK`. Swift çıktısında `skipped` geçmez. Swift takımı iki kez daha çalıştırılır; geride `nc`, `sleep 30` ya da `sing-box` süreci kalmaz.

- [ ] **Adım 2: Tasarım belgesine durum notu**

`macos/docs/2026-10-14-macos-tasarim.md` Bölüm 11'de, **1c durumu** satırının altına şu satır eklenir:

`- **1d durumu:** Tamamlandı (bağlantı tanısı ve otomatik DNS seçimi; canlı doğrulama bu Mac'te geçti). Plan: macos/docs/plans/2026-10-15-asama-1d-baglanti-tanisi-ve-dns-secimi.md.`

- [ ] **Adım 3: Git durumu ve commit sorusu**

Run: `git status --porcelain --untracked-files=all; git diff --name-only main -- . ':!macos'`
Expected: ikinci komut hiçbir şey yazmaz; durum yalnız `macos/` altındaki dosyaları gösterir.

Kullanıcıya değişen dosyalar, yapılan ve yapılmayan kontroller (canlı denetim ayrı) raporlanır, commit isteyip istemediği sorulur. İsterse:

```bash
git add macos/Sources macos/Tests macos/docs
git commit -m "feat(macos): add connectivity checks and automatic DNS selection"
```
