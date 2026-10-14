# Aşama 1b — Kapı İstek Politikası ve Eş Kimliği Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Hedef:** Kapının ağdan bağımsız iki kararını `DiscordAccessKit`'e eklemek:

- istek politikası (Windows `ProcessGate.RewriteHeader`)
- eş kimliği ve kabulü (Windows `TcpOwner.Find`, `ExternalDiscordScope` ve `ProcessGate.PermittedOwner`)

**Mimari:**
- `RequestPolicy`, bir istek başlığını Discord hedeflerine göre denetler ve motorun kimlik bilgisini ekler. Ret, Windows'taki kategoriyle (`RequestFailure`) döner.
- `ProcessInspector.loopbackConnectionHolders`, bir loopback TCP bağlantısını tutan, aynı kullanıcıya ait bütün süreçleri bulur. Listeler eksiksiz okunamazsa `nil` döner.
- `PeerAdmission`, bağlantının bütün sahiplerini kabul ölçütlerinden geçirir ve kabulü süreç örneği başına hatırlar.
- `DiscordApplication`, seçili `Discord.app` içindeki beş yürütülebilir dosyayı Discord'un kendi designated requirement'larıyla eşler.
- Kapının dinleme ve aktarma katmanı 1c'dedir. Bu plan, testlerdeki loopback bağlantıları dışında ağ kullanmaz.

**Teknolojiler:** Swift 6.4 (Swift 5 dil modu), SwiftPM, Swift Testing, Darwin libproc, Security.framework.

---

## Aşama 1 alt planları

| Alt plan | Kapsam |
| --- | --- |
| 1a | Tamamlandı: paket iskeleti, motor yapılandırması, motor doğrulama ve başlatma, yetim motor temizliği, derleme betiği sabitleri |
| **1b** | Kapı istek politikası ve eş kimliği (bu plan) |
| 1c | Kapının ağ katmanı: dinleme, aktarım, her bağlantıda motor kimliği, tanı kayıtları (`SafeTarget`) |
| 1d | Bağlantı tanısı (Gateway HELLO) ve otomatik DNS seçimi |
| 1e | Güncelleme köprüsü (manifest ve yönlendirme yeniden yazma, indirmeler) |
| 1f | Discord kurulumu ve profil değişiklikleri: günlük, tüm çekirdek nesilleri, gömülü kanca, Tam Disk Erişimi |
| 1g | Terminal modu (Q/T/D/A) ile uçtan uca birleştirme |

Tasarımdaki kararlar `macos/docs/2026-10-14-macos-tasarim.md` Bölüm 8'dedir.

## Yürütme notları

- Tüm komutlar depo kökünden (`/Users/alpertekin/Documents/GitHub/DiscordAccess`), `feature/macos` dalında çalıştırılır.
- `macos/` dışında hiçbir dosya değişmez. Commit yalnız kullanıcının açık isteğiyle yapılır.
- Bütün macOS testleri `macos/Tests/` altındadır. Küçük harfli `tests/` klasörü açılmaz.
- Kod blokları geçici klasörde derlendi. Tam takım tekrar tekrar geçti; son haliyle art arda 6 kez. Bozma denetimleri, yeni testlerin hedefledikleri hataları yakaladığını gösterdi. Kod elle yeniden yazılmaz; aşağıdaki yardımcıyla hash doğrulanarak çıkarılır.
- 1a'nın dört dosyası (`TestSupport.swift`, `ProcessInspectorTests.swift`, `EngineProcessTests.swift`, `ProcessInspector.swift`) burada tamamen değiştirilir. Yardımcıya 1a'daki son hash'leri verilir.
- Testler sistemdeki Apple imzalı `/usr/bin/nc` ve `/bin/sleep` dosyalarını kullanır. Discord'a özel test, `/Applications/Discord.app` yoksa atlanır. Bu Mac'te Discord kurulu olduğu için atlanmaz. Çıktıda `skipped` geçmediği her doğrulamada denetlenir.
- Testler boş port varsaymaz: paralel çalışan testlerin dinleyicileri herhangi bir geçici portu alabilir.
- macOS, çalıştırılan her yeni dosyayı `syspolicyd` ile arka planda tarar. 1a testleri motor kopyalarını çalıştırıp hemen siliyordu; `syspolicyd` tarama sırasında silinen dosyada çöktü (16:31'den itibaren 18 kez) ve macOS yeniden başlatmayı üstel gecikmeyle erteledi. O sırada `codesign`, derleme ve yeni dosyaların açılışı dakikalarca bekler. Bu yüzden çalıştırılan motor kopyaları artık `macos/build/test-engines/` altında kalıcıdır ve hiç silinmez. Bu değişiklik Görev 2'dedir; o zamana kadar tam takım çalıştırılmaz. Testler paketlerin statik imza doğrulamasını da kullanmaz. Bir komut yine beklerse `syspolicyd`'nin geri gelmesi beklenir; test döngüsü üst üste çalıştırılmaz.
- Swift'te "kırmızı" durum derleme hatasıdır.

## Dosya yapısı

| Dosya | Sorumluluk | SHA-256 |
| --- | --- | --- |
| `macos/Sources/DiscordAccessKit/Gate/RequestPolicy.swift` | Yeni: istek politikası ve `RequestFailure` | `387a6b756164ed837d6029ee866526a1a9a08a63c3fb8a73e4d396be00bfed71` |
| `macos/Sources/DiscordAccessKit/Gate/PeerAdmission.swift` | Yeni: `ApprovedExecutable` ve eş kabulü | `5f4f75a9c085cfd954e4109653ca6793df8dd6f3461c7b4b375973aa675d3d53` |
| `macos/Sources/DiscordAccessKit/Discord/DiscordApplication.swift` | Yeni: Discord'un onaylı dosyaları ve imza gereksinimleri | `53c97d92b9fc250cf7a3ed40fc3ce7ab3a363785d6929e719cd356a6fed06caf` |
| `macos/Sources/DiscordAccessKit/System/ProcessInspector.swift` | Değişir: eksiksiz liste okuma, bağlantı sahipleri, ağsız imza denetimi | `89e91d6afc0e289a20b94d272fcef973d523ed6cb038da510ef0df49e6bdef32` |
| `macos/Tests/DiscordAccessKitTests/TestSupport.swift` | Değişir: bağlantı kabulü, istemci soketi, soketi paylaşan alt süreç | `51975aa17b220fd997922507f4967fecef95c9a7e726193e4b79ceed4c655189` |
| `macos/Tests/DiscordAccessKitTests/ProcessInspectorTests.swift` | Değişir: bağlantı sahipleri; boş port varsayımı kaldırıldı | `ca8b9552be0e458f3b0652d3ee2d5dc9ccfbabfc88d31130bc7bda93f2a2e5f3` |
| `macos/Tests/DiscordAccessKitTests/EngineProcessTests.swift` | Değişir: çalıştırılan motor kopyaları kalıcı | `241359ede06b199155bbc9425b15bd71d003ecae6b4482fc3c1fc935795ffc8d` |
| `macos/Tests/DiscordAccessKitTests/RequestPolicyTests.swift` | Yeni: Windows vektörleri ve macOS'a özgü katı durumlar | `cc1d88b23e0bf4140bb1559c27154a6dbb25f31ca35ee14fa9353b7f9f5a3614` |
| `macos/Tests/DiscordAccessKitTests/PeerAdmissionTests.swift` | Yeni: `nc` istemcileriyle eş kabulü | `032fcb9beed620a78dac60d35a3fd9ad772929929b49a09dff683359f61a38a2` |
| `macos/Tests/DiscordAccessKitTests/DiscordApplicationTests.swift` | Yeni: kurulu Discord'un designated requirement'larıyla karşılaştırma | `e1951f8dca02e84971ae49951083f913989f70cf32ab9706118d3be1d42d38bf` |

Plandan dosya çıkarma yardımcısı. `LANG` kod bloğu dilidir, `INDEX` o dildeki 0 tabanlı sıradır. Yardımcı hash doğrular; yeni dosyada var olanın üzerine yazmaz, değiştirilen dosyada eski hash'i ister.

```bash
python3 -I - macos/docs/plans/2026-10-14-asama-1b-kapi-politikasi-ve-es-kimligi.md LANG INDEX TARGET EXPECTED_SHA256 OLD_SHA256_OR_NONE <<'EOF'
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

### Görev 1: İstek politikası

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/RequestPolicyTests.swift`, `macos/Sources/DiscordAccessKit/Gate/RequestPolicy.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 0)

Vektörler Windows'taki `SecurityChecks.cs`, `MediaPolicyChecks.cs` ve `ProxyDiagnosticsChecks.cs` dosyalarından alınmıştır. Windows yalnız reddi beklediği yerde de ret kategorisi doğrulanır. Son grup macOS'a özgüdür: Windows'tan katı ayrıştırma ve Windows'ta sabitlenmemiş çerçeveleme ayrıntıları. Ayrı bir test, DNS adı sınırlarını (253 karakterlik ad, 63 karakterlik etiket) ve IP adresi yazımlarının reddini doğrudan sınar.

```swift
import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows checks (`SecurityChecks.cs`, `MediaPolicyChecks.cs`, `ProxyDiagnosticsChecks.cs`); the
/// refusal categories are asserted for every vector, also where the Windows check only expects a refusal.
@Suite struct RequestPolicyTests {
    static let authorization = "Basic Zml4dHVyZS1vbmx5Om5vdC1hLXJlYWwtc2VjcmV0"
    static let upload = "discord-attachments-uploads-prd.storage.googleapis.com"

    /// `CONNECT` with a Host line and an old credential to drop (Windows `MediaPolicyChecks.Request`).
    static func connect(_ authority: String, host: String? = nil) -> String {
        "CONNECT " + authority + " HTTP/1.1\r\nHost: " + (host ?? authority) + "\r\nProxy-Authorization: Basic obsolete-fixture\r\n\r\n"
    }

    static func bare(_ authority: String) -> String {
        "CONNECT " + authority + " HTTP/1.1\r\n\r\n"
    }

    static func get(_ target: String, host: String, _ headers: String = "") -> String {
        "GET " + target + " HTTP/1.1\r\nHost: " + host + "\r\n" + headers + "\r\n"
    }

    /// `header` with its final CR LF replaced by this run's credential line and the blank line.
    static func credentialed(_ header: String, _ authorization: String = authorization) -> String {
        String(decoding: header.utf8.dropLast(2), as: UTF8.self) + "Proxy-Authorization: " + authorization + "\r\n\r\n"
    }

    static func failure(_ header: String) -> RequestFailure? {
        do {
            _ = try RequestPolicy.rewrite(header, authorization: authorization)
            return nil
        } catch {
            return error as? RequestFailure
        }
    }

    @Test(arguments: [
        "discord.com:443", "discord.gg:443", "discordapp.com:443", "discordapp.net:443", "discord.media:443", "discordcdn.com:443",
        "discordstatus.com:443", "discord.gift:443", "CDN.DISCORDAPP.COM:443", "gateway.discord.gg:443",
        "c-waw04-9501efbe.discord.media:2087", "c-fra07-7cbb2779.discord.media:2087", "discord.media:2087",
        "C-WAW04-9501EFBE.DISCORD.MEDIA:2087", "a.b.discord.media:2087", "c-waw05-eaef8be4.discord.media:443", "cdn.discordapp.com:443",
        "c-waw04-9501efbe.discord.media:2083", "c-fra07-7cbb2779.discord.media:2096", "c-waw04-9501efbe.discord.media:8443",
        "discord.media:1", "discord.media:80", "discord.media:2088", "discord.media:4430", "a.b.discord.media:50000",
        "discord.media:65535", upload + ":443", upload.uppercased() + ":443",
        "hcaptcha.com:443", "js.hcaptcha.com:443", "newassets.hcaptcha.com:443", "a.b.hcaptcha.com:443", "JS.HCAPTCHA.COM:443",
    ])
    func acceptsDiscordConnectTargetsAndReplacesTheCredential(authority: String) throws {
        let rewritten = try RequestPolicy.rewrite(Self.connect(authority), authorization: Self.authorization)
        #expect(rewritten == "CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\nProxy-Authorization: " + Self.authorization + "\r\n\r\n")
    }

    @Test func keepsOtherHeadersAndDropsEveryClientCredential() throws {
        let header = "CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nProxy-Authorization: Basic obsolete-fixture\r\n" +
            "pRoXy-AuThOrIzAtIoN: Bearer other-fixture\r\nUser-Agent: fixture\r\n\r\n"
        #expect(try RequestPolicy.rewrite(header, authorization: Self.authorization) ==
            "CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nUser-Agent: fixture\r\nProxy-Authorization: " + Self.authorization + "\r\n\r\n")
        let chromium = "CONNECT gateway.discord.gg:443 HTTP/1.1\r\nHost: gateway.discord.gg:443\r\nProxy-Connection: keep-alive\r\n" +
            "User-Agent: Mozilla/5.0 Chrome/138.0.0.0 Electron/37.0.0\r\n\r\n"
        #expect(try RequestPolicy.rewrite(chromium, authorization: "Basic fixture-only") == Self.credentialed(chromium, "Basic fixture-only"))
        let plain = Self.get("http://discord.com/", host: "discord.com", "proxy-authorization: Basic obsolete-fixture\r\nUser-Agent: fixture\r\n")
        #expect(try RequestPolicy.rewrite(plain, authorization: Self.authorization) ==
            "GET http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\nUser-Agent: fixture\r\nProxy-Authorization: " + Self.authorization + "\r\n\r\n")
    }

    @Test(arguments: [
        get("http://discord.com:80/api/v10/gateway", host: "discord.com:80"),
        get("http://discord.com/api/v10/gateway", host: "discord.com"),
        get("http://discord.com/", host: "discord.com", "Connection: keep-alive\r\n"),
        get("http://discord.media/", host: "discord.media"),
        get("HTTP://DISCORD.COM/", host: "discord.com"),
        get("http://discord.com?query", host: "DISCORD.COM"),
        "HEAD http://discord.com/ HTTP/1.0\r\nHost: discord.com\r\n\r\n",
        "POST http://discord.com/api HTTP/1.1\r\nHost: discord.com\r\nContent-Length: 2\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\nUpgrade: websocket\r\n\r\n",
        "POST http://discord.com/api HTTP/1.1\r\nHost: discord.com\r\nTransfer-Encoding: chunked\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\nHost:\tdiscord.com:443 \t\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\nHost:discord.com:443\r\n\r\n",
    ])
    func acceptsPlainHTTPToDiscordAndConnectWithoutHost(header: String) throws {
        #expect(try RequestPolicy.rewrite(header, authorization: Self.authorization) == Self.credentialed(header))
    }

    static let refusals: [(String, RequestFailure)] = [
        // SecurityChecks.cs: host names and authorities.
        (bare("bad..discord.com:443"), RequestFailure.forbiddenHost), (bare(".discord.com:443"), .forbiddenHost),
        (bare("-bad.discord.com:443"), .forbiddenHost), (bare("bad-.discord.com:443"), .forbiddenHost),
        (bare(String(repeating: "a", count: 64) + ".discord.com:443"), .forbiddenHost),
        (bare(String(repeating: "a", count: 63) + "." + String(repeating: "b", count: 63) + "." + String(repeating: "c", count: 63) +
            "." + String(repeating: "d", count: 63) + ".discord.com:443"), .forbiddenHost),
        (bare("example.com:443"), .forbiddenHost), (bare("discord.com.evil.example:443"), .forbiddenHost),
        (bare("evildiscord.com:443"), .forbiddenHost), (bare("discordcom:443"), .forbiddenHost), (bare("127.0.0.1:443"), .forbiddenHost),
        (bare("2130706433:443"), .forbiddenHost), (bare("0x7f000001:443"), .forbiddenHost), (bare("[::1]:443"), .invalidTarget),
        (bare("[::ffff:127.0.0.1]:443"), .invalidTarget), (bare("user@discord.com:443"), .invalidTarget),
        (bare("user:pass@discord.com:443"), .invalidTarget), (bare("discord.com"), .invalidTarget), (bare("discord.com:80"), .invalidTarget),
        (bare("discord.com:444"), .invalidTarget), (bare("discord.com:0"), .invalidTarget), (bare("discord.com:65536"), .invalidTarget),
        (bare("discord.com:+443"), .invalidTarget), (bare("discord.com:-443"), .invalidTarget), (bare("discord.com:443:443"), .invalidTarget),
        (bare("discord.com:443/"), .invalidTarget), (bare("discord.com:443/path"), .invalidTarget), (bare("discord.com:443?query"), .invalidTarget),
        (bare("discord.com:443#fragment"), .invalidTarget), (bare("discord.com\\@example.com:443"), .invalidTarget),
        (bare("discord.com%2eexample.com:443"), .invalidTarget),
        // SecurityChecks.cs: plain HTTP targets and upgrades.
        (get("http://user:pass@discord.com/api", host: "discord.com"), .invalidTarget), (get("http://example.com/", host: "discord.com"), .forbiddenHost),
        (get("http://discord.com:8080/", host: "discord.com:8080"), .invalidTarget), (get("/api/v10/gateway", host: "discord.com"), .invalidTarget),
        (get("ftp://discord.com/file", host: "discord.com"), .invalidTarget),
        (get("http://discord.com/", host: "discord.com", "Connection: Upgrade\r\nUpgrade: websocket\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "connection: keep-alive, uPgRaDe\r\nupgrade: h2c\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "Connection: keep-alive\r\nConnection: upgrade\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "Upgrade: websocket\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "Upgrade:\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "Proxy-Connection: keep-alive, Upgrade\r\n"), .unsupportedUpgrade),
        // SecurityChecks.cs: Host lines, header syntax, framing and size.
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n", .conflictingHost),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nhost: example.com:443\r\n\r\n", .conflictingHost),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\n continued: forbidden\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\n\tcontinued: forbidden\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost : discord.com:443\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nBad(Name): fixture\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nMalformed\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: invalid\0value\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\nHost: discord.com:443\n\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\rHost: discord.com:443\r\r", .invalidHeader),
        ("CONNECT  discord.com:443 HTTP/1.1\r\n\r\n", .invalidRequestLine), ("CONNECT discord.com:443 HTTP/1.1evil\r\n\r\n", .invalidRequestLine),
        ("CONNECT discord.com:443 HTTP/2.0\r\n\r\n", .invalidRequestLine),
        ("TRACE http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\n\r\n", .unsupportedMethod),
        ("POST http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n", .invalidFraming),
        ("POST http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\n", .invalidFraming),
        ("CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: " + String(repeating: "a", count: 32768) + "\r\n\r\n", .invalidHeader),
        ("", .invalidHeader), ("CONNECT discord.com:443 HTTP/1.1\r\n", .invalidHeader),
        // MediaPolicyChecks.cs: media ports belong to discord.media only.
        (connect("example.com:2087"), .forbiddenHost), (connect("discord.media.evil.example:2087"), .forbiddenHost),
        (connect("evildiscord.media:2087"), .forbiddenHost), (connect("discord-media:2087"), .forbiddenHost),
        (connect(".discord.media:2087"), .forbiddenHost), (connect("bad..discord.media:2087"), .forbiddenHost),
        (connect("-bad.discord.media:2087"), .forbiddenHost), (connect("bad-.discord.media:2087"), .forbiddenHost),
        (connect("discord.media.:2087"), .forbiddenHost), (connect(String(repeating: "a", count: 64) + ".discord.media:2087"), .forbiddenHost),
        (connect("127.0.0.1:2087"), .forbiddenHost), (connect("2130706433:2087"), .forbiddenHost), (connect("0x7f000001:2087"), .forbiddenHost),
        (connect("discord.com:2087"), .invalidTarget), (connect("cdn.discordapp.com:2087"), .invalidTarget),
        (connect("gateway.discord.gg:2087"), .invalidTarget), (connect("[::1]:2087"), .invalidTarget),
        (connect("[::ffff:127.0.0.1]:2087"), .invalidTarget), (connect("user@discord.media:2087"), .invalidTarget),
        (connect("user:pass@discord.media:2087"), .invalidTarget), (connect("discord.media%2eexample.com:2087"), .invalidTarget),
        (connect("discord.media\\@example.com:2087"), .invalidTarget), (connect("discord.media:2087/path"), .invalidTarget),
        (connect("discord.media:2087?secret"), .invalidTarget), (connect("discord.media:2087#fragment"), .invalidTarget),
        (connect("discord.media:2087:443"), .invalidTarget), (connect("discord.media:02087"), .invalidTarget),
        (connect("discord.media:+2087"), .invalidTarget), (connect("discord.media:-2087"), .invalidTarget),
        (connect("discord.media:2.087"), .invalidTarget), (connect("discord.media:0x827"), .invalidTarget),
        (connect("discord.media:0"), .invalidTarget), (connect("discord.media:65536"), .invalidTarget),
        (connect("discord.media:0443"), .invalidTarget), (connect("discord.media:0001"), .invalidTarget),
        (connect("discord.media:00000"), .invalidTarget), (connect("discord.media:655350"), .invalidTarget),
        (connect("discord.media:2147483647"), .invalidTarget), (connect("discord.media:"), .invalidTarget),
        (connect("discord.media: 2083"), .invalidRequestLine), (connect("discord.media:2096\n"), .invalidHeader),
        (connect("c-waw04-9501efbe.discord.media:2087", host: "c-waw04-9501efbe.discord.media:443"), .conflictingHost),
        (connect("c-waw04-9501efbe.discord.media:2087", host: "evil.example:2087"), .conflictingHost),
        (get("http://discord.media:2087/", host: "discord.media:2087"), .invalidTarget),
        ("CONNECT discord.media:2087 HTTP/1.1\r\nHost: discord.media:2087\r\nHost: discord.media:2087\r\n\r\n", .conflictingHost),
        // MediaPolicyChecks.cs: the upload bucket is one exact HTTPS host.
        (connect(upload + ":2087"), .forbiddenHost), (connect(upload + ":80"), .forbiddenHost), (connect(upload + ":2083"), .forbiddenHost),
        (connect(upload + ":2096"), .forbiddenHost), (connect(upload + ":8443"), .forbiddenHost), (connect(upload + ":65535"), .forbiddenHost),
        (connect(upload + ".evil:443"), .forbiddenHost),
        (connect("sub." + upload + ":443"), .forbiddenHost), (connect(upload + ".evil.example:443"), .forbiddenHost),
        (connect("evil" + upload + ":443"), .forbiddenHost), (connect("storage.googleapis.com:443"), .forbiddenHost),
        (connect("other-bucket.storage.googleapis.com:443"), .forbiddenHost), (connect(upload + ".:443"), .forbiddenHost),
        (connect("user@" + upload + ":443"), .invalidTarget),
        ("PUT http://" + upload + "/file HTTP/1.1\r\nHost: " + upload + "\r\n\r\n", .forbiddenHost),
        ("PUT http://" + upload + ":443/file HTTP/1.1\r\nHost: " + upload + ":443\r\n\r\n", .invalidTarget),
        (connect(upload + ":443", host: "other-bucket.storage.googleapis.com:443"), .conflictingHost),
        // MediaPolicyChecks.cs: hCaptcha is HTTPS on 443 only.
        (connect("hcaptcha.com:80"), .forbiddenHost), (connect("js.hcaptcha.com:80"), .forbiddenHost), (connect("js.hcaptcha.com:2083"), .forbiddenHost),
        (connect("js.hcaptcha.com:2087"), .forbiddenHost), (connect("js.hcaptcha.com:2096"), .forbiddenHost), (connect("js.hcaptcha.com:8443"), .forbiddenHost),
        (connect("js.hcaptcha.com:65535"), .forbiddenHost),
        (connect("js.hcaptcha.com:0443"), .invalidTarget), (connect("hcaptcha.com.evil.example:443"), .forbiddenHost),
        (connect("evilhcaptcha.com:443"), .forbiddenHost), (connect("hcaptcha-com:443"), .forbiddenHost), (connect("captcha.com:443"), .forbiddenHost),
        (connect("hcaptcha.com.:443"), .forbiddenHost), (connect(".hcaptcha.com:443"), .forbiddenHost), (connect("bad..hcaptcha.com:443"), .forbiddenHost),
        (connect("-bad.hcaptcha.com:443"), .forbiddenHost), (connect("bad-.hcaptcha.com:443"), .forbiddenHost),
        (connect(String(repeating: "a", count: 64) + ".hcaptcha.com:443"), .forbiddenHost), (connect("user@hcaptcha.com:443"), .invalidTarget),
        (connect("hcaptcha.com%2eevil.example:443"), .invalidTarget), (connect("hcaptcha.com\\@evil.example:443"), .invalidTarget),
        (connect("hcaptcha.com:443/path"), .invalidTarget), (get("http://hcaptcha.com/", host: "hcaptcha.com"), .forbiddenHost),
        (get("http://hcaptcha.com:443/", host: "hcaptcha.com:443"), .invalidTarget), (get("http://js.hcaptcha.com/", host: "js.hcaptcha.com"), .forbiddenHost),
        (get("http://js.hcaptcha.com:443/", host: "js.hcaptcha.com:443"), .invalidTarget),
        (connect("js.hcaptcha.com:443", host: "hcaptcha.com:443"), .conflictingHost),
        (connect("js.hcaptcha.com:443", host: "js.hcaptcha.com:80"), .conflictingHost),
        (connect("js.hcaptcha.com:443", host: "evil.example:443"), .conflictingHost),
        // ProxyDiagnosticsChecks.cs, where Windows asserts the category itself.
        ("CONNECT telemetry.example.invalid:443 HTTP/1.1\r\nHost: telemetry.example.invalid:443\r\nAuthorization: Bearer PRIVATE_FIXTURE\r\n\r\n",
         .forbiddenHost),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: conflict.example.invalid\r\n\r\n", .conflictingHost),
        (get("http://discord.com/PRIVATE_FIXTURE?token=PRIVATE_FIXTURE", host: "discord.com", "Bad(Name): PRIVATE_FIXTURE\r\n"), .invalidHeader),
        (get("http://PRIVATE_FIXTURE@discord.com/private", host: "discord.com"), .invalidTarget),
        (bare("discord.com:443/PRIVATE_FIXTURE"), .invalidTarget), (get("/PRIVATE_FIXTURE?token=PRIVATE_FIXTURE", host: "discord.com"), .invalidTarget),
        // macOS only: stricter than the Windows `Uri` parsing, and framing details Windows does not pin.
        (get("http://discord.com:/", host: "discord.com"), .invalidTarget), (get("http://discord.com:080/", host: "discord.com"), .invalidTarget),
        (get("http://%64iscord.com/", host: "discord.com"), .invalidTarget), (get("http://discord.com/#top", host: "discord.com"), .invalidTarget),
        (get("http://[::1]/", host: "[::1]"), .invalidTarget), (get("http://discord.com/\u{1}", host: "discord.com"), .invalidTarget),
        (get("http://discord.com./", host: "discord.com."), .forbiddenHost), (get("http://discord.com/", host: "discord.com", "Content-Length: +1\r\n"), .invalidFraming),
        (get("http://discord.com.evil.example/", host: "discord.com.evil.example"), .forbiddenHost),
        (get("http://discord.com@evil.example/", host: "evil.example"), .invalidTarget),
        (get("http://discord.com/", host: "discord.com", "Content-Length: 99999999999999999999\r\n"), .invalidFraming),
        (get("http://discord.com/", host: "discord.com", "Content-Length:\r\n"), .invalidFraming),
        (get("http://discord.com/", host: "discord.com", "Transfer-Encoding: chunked\r\ntransfer-encoding: chunked\r\n"), .invalidFraming),
        ("GET http://discord.com/ HTTP/1.1\r\n\r\n", .conflictingHost), ("connect discord.com:443 HTTP/1.1\r\n\r\n", .unsupportedMethod),
        ("CONNECT discord.com:443 http/1.1\r\n\r\n", .invalidRequestLine), ("CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: \u{7f}\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: café\r\n\r\n", .invalidHeader),
    ] + ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discordcdn.com", "discordstatus.com", "discord.gift"].flatMap { host in
        // MediaPolicyChecks.cs: media ports never extend to the other Discord domains.
        ["2083", "2096", "8443", "65535"].map { (connect(host + ":" + $0), RequestFailure.invalidTarget) }
    }

    @Test(arguments: refusals)
    func refusesWithTheWindowsCategory(header: String, expected: RequestFailure) {
        #expect(Self.failure(header) == expected)
    }

    /// No allowed name can be an `inet_aton` literal (each ends in a label that starts with a letter), so this check never
    /// changes a `rewrite` outcome; it is tested directly.
    @Test func validatesDNSHostsLikeWindows() throws {
        let labels = [String(repeating: "a", count: 63), String(repeating: "b", count: 63), String(repeating: "c", count: 63)]
        let longest = (labels + [String(repeating: "d", count: 49), "discord.com"]).joined(separator: ".")
        let tooLong = (labels + [String(repeating: "d", count: 50), "discord.com"]).joined(separator: ".")
        #expect(longest.utf8.count == 253 && tooLong.utf8.count == 254)
        #expect(try RequestPolicy.rewrite(Self.bare(longest + ":443"), authorization: "x").hasPrefix("CONNECT " + longest + ":443 "))
        #expect(Self.failure(Self.bare(tooLong + ":443")) == .forbiddenHost)
        #expect(RequestPolicy.validDNSHost(String(repeating: "a", count: 63) + ".discord.com"))
        #expect(!RequestPolicy.validDNSHost(String(repeating: "a", count: 64) + ".discord.com"))
        for literal in ["127.0.0.1", "2130706433", "0x7f000001", "127.1"] {
            #expect(!RequestPolicy.validDNSHost(literal), "\(literal)")
        }
    }

    @Test func limitsTheHeaderTo32KiB() throws {
        let start = "CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: "
        let fill = String(repeating: "a", count: RequestPolicy.maxHeaderLength - start.utf8.count - 4)
        #expect(try RequestPolicy.rewrite(start + fill + "\r\n\r\n", authorization: "x").hasPrefix(start + fill + "\r\n"))
        #expect(Self.failure(start + fill + "a\r\n\r\n") == .invalidHeader)
    }

    @Test func refusalsCarryTheWindowsCategoryNames() {
        let failures: [RequestFailure] = [.invalidHeader, .invalidRequestLine, .invalidTarget, .unsupportedMethod, .forbiddenHost, .conflictingHost,
                                          .invalidFraming, .unsupportedUpgrade]
        #expect(failures.map(\.rawValue) == ["InvalidHeader", "InvalidRequestLine", "InvalidTarget", "UnsupportedMethod", "ForbiddenHost",
                                             "ConflictingHost", "InvalidFraming", "UnsupportedUpgrade"])
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'RequestFailure' in scope` ve `cannot find type 'RequestFailure' in scope`. Tür henüz olmadığı için büyük vektör dizisinde `the compiler is unable to type-check this expression in reasonable time` hatası da görülür; tür tanımlanınca kaybolur. Derleme işlerinin sırasına göre işlev gövdelerinden `cannot find 'RequestPolicy' in scope` ve `cannot infer key path type from context` hataları da çıkabilir: modül arayüzünün derlemesi başarısız olunca gövdelerin derlemesi bazen tamamlanır, bazen iptal edilir.

- [ ] **Adım 3: İstek politikasını yaz** (`swift` bloğu 1)

Denetimlerin sırası ve ret kategorileri Windows'takiyle aynıdır. Fark mutlak `http://` hedeflerindedir: Windows `Uri` ayrıştırmasını kullanır, burada elle yazılmış katı bir ayrıştırıcı vardır. Ana bilgisayar adı zaten DNS biçiminde olmalı, yazılan port tam olarak `80` olmalıdır.

```swift
import Darwin

/// Why the gate refused a request; the raw values are the Windows `ProcessGate.RequestFailure` names used in diagnostics.
public enum RequestFailure: String, Error, Sendable {
    case invalidHeader = "InvalidHeader"
    case invalidRequestLine = "InvalidRequestLine"
    case invalidTarget = "InvalidTarget"
    case unsupportedMethod = "UnsupportedMethod"
    case forbiddenHost = "ForbiddenHost"
    case conflictingHost = "ConflictingHost"
    case invalidFraming = "InvalidFraming"
    case unsupportedUpgrade = "UnsupportedUpgrade"
}

/// The gate's request policy (Windows `ProcessGate.RewriteHeader`): one request header from an admitted Discord process
/// is checked against the Discord destinations, then rewritten to carry this run's engine credential.
public enum RequestPolicy {
    public static let maxHeaderLength = 32768
    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"]

    /// The request line and every header except `Proxy-Authorization`, unchanged and in order, followed by
    /// `Proxy-Authorization: <authorization>` as the last header. Throws `RequestFailure` when the request is refused.
    public static func rewrite(_ header: String, authorization: String) throws -> String {
        let bytes = Array(header.utf8)
        guard !bytes.isEmpty, bytes.count <= maxHeaderLength, bytes.suffix(4).elementsEqual([13, 10, 13, 10]),
              !bytes.contains(where: { $0 == 0 || $0 > 127 }) else { throw RequestFailure.invalidHeader }
        let rawLines = splitLines(Array(bytes.dropLast(4)))
        guard rawLines.allSatisfy({ !$0.contains(13) && !$0.contains(10) }) else { throw RequestFailure.invalidHeader }
        // Plain ASCII without CR or LF from here on, so every Character is one byte.
        let lines = rawLines.map { String(decoding: $0, as: UTF8.self) }
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { throw RequestFailure.invalidRequestLine }
        let connect = request[0] == "CONNECT"
        let host: String, port: Int
        if connect {
            guard let target = connectTarget(request[1]) else { throw RequestFailure.invalidTarget }
            (host, port) = target
        } else {
            guard methods.contains(request[0]) else { throw RequestFailure.unsupportedMethod }
            guard let target = absoluteHTTPHost(request[1]) else { throw RequestFailure.invalidTarget }
            (host, port) = (target, 80)
        }
        // Upload and challenge hosts are HTTPS-only exceptions; they never inherit Discord's HTTP or media-port rules.
        guard allowedHost(host) || (connect && port == 443 && (allowedChallengeHost(host) || uploadHost(host))) else {
            throw RequestFailure.forbiddenHost
        }
        // Discord's media servers use changing stream ports; every other CONNECT destination stays on 443.
        guard !connect || port == 443 || mediaHost(host) else { throw RequestFailure.invalidTarget }
        var output = lines[0] + "\r\n"
        var sawHost = false, sawLength = false, sawTransfer = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, line[..<colon].utf8.allSatisfy(isTokenByte),
                  !line.utf8.contains(where: { ($0 < 32 && $0 != 9) || $0 == 127 }) else { throw RequestFailure.invalidHeader }
            let name = line[..<colon].lowercased()
            let value = trimmed(line[line.index(after: colon)...])
            // A plain HTTP upgrade would hand the engine credential to the remote peer; inside CONNECT it stays opaque.
            if !connect && (name == "upgrade" || ((name == "connection" || name == "proxy-connection") &&
                value.split(separator: ",", omittingEmptySubsequences: false).contains { trimmed($0).lowercased() == "upgrade" })) {
                throw RequestFailure.unsupportedUpgrade
            }
            if name == "host" {
                let written = value.lowercased(), expected = host.lowercased()
                guard !sawHost, written == expected || written == expected + ":" + String(port) else { throw RequestFailure.conflictingHost }
                sawHost = true
            }
            if name == "content-length" {
                guard !sawLength, !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), Int64(value) != nil else {
                    throw RequestFailure.invalidFraming
                }
                sawLength = true
            }
            if name == "transfer-encoding" {
                guard !sawTransfer else { throw RequestFailure.invalidFraming }
                sawTransfer = true
            }
            if name != "proxy-authorization" { output += line + "\r\n" }
        }
        guard !(sawLength && sawTransfer) else { throw RequestFailure.invalidFraming }
        guard connect || sawHost else { throw RequestFailure.conflictingHost }
        return output + "Proxy-Authorization: " + authorization + "\r\n\r\n"
    }

    /// `host:port` with a host of `[A-Za-z0-9.-]` and a port of 1-65535 without sign or leading zero.
    static func connectTarget(_ target: String) -> (host: String, port: Int)? {
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy(isHostByte), let first = parts[1].utf8.first,
              first >= 49, first <= 57, parts[1].utf8.count <= 5, parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = Int(parts[1]), port <= 65535 else { return nil }
        return (String(parts[0]), port)
    }

    /// The host of an absolute `http://` target on port 80, with no user information or fragment. Stricter than the
    /// Windows `Uri` parsing: the host must already be in DNS form, and a written port must be exactly `80`.
    static func absoluteHTTPHost(_ target: String) -> String? {
        guard target.utf8.count > 7, target.prefix(7).lowercased() == "http://", target.utf8.allSatisfy({ $0 > 32 && $0 != 127 }),
              !target.contains("\\"), !target.contains("#") else { return nil }
        let authority = target.dropFirst(7).prefix { $0 != "/" && $0 != "?" }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy(isHostByte), parts.count == 1 || parts[1] == "80" else {
            return nil
        }
        return String(parts[0])
    }

    /// A DNS name of 1-253 characters whose labels have 1-63 letters, digits or inner hyphens; never an IP literal.
    static func validDNSHost(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count), host.utf8.allSatisfy(isHostByte) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ (1...63).contains($0.utf8.count) && $0.utf8.first != 45 && $0.utf8.last != 45 }) else { return false }
        var address = in_addr()
        return inet_aton(host, &address) == 0
    }

    static func allowedHost(_ host: String) -> Bool {
        validDNSHost(host) && matches(host, DiscordDestinations.allowedDomains)
    }

    static func allowedChallengeHost(_ host: String) -> Bool {
        validDNSHost(host) && matches(host, DiscordDestinations.challengeDomains)
    }

    static func uploadHost(_ host: String) -> Bool {
        DiscordDestinations.uploadHosts.contains(host.lowercased())
    }

    static func mediaHost(_ host: String) -> Bool {
        matches(host, ["discord.media"])
    }

    /// The domain itself or any subdomain of it, ignoring case.
    private static func matches(_ host: String, _ domains: [String]) -> Bool {
        let lowered = host.lowercased()
        return domains.contains { lowered == $0 || lowered.hasSuffix("." + $0) }
    }

    private static func isHostByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 46
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    /// Without leading and trailing spaces or tabs; no other whitespace survives the control-character check.
    private static func trimmed(_ text: Substring) -> String {
        var result = text.drop(while: { $0 == " " || $0 == "\t" })
        while let last = result.last, last == " " || last == "\t" { result = result.dropLast() }
        return String(result)
    }

    /// Splits at every CR LF pair, keeping empty pieces (C# `Split("\r\n", None)`).
    private static func splitLines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = [], start = 0, index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 13 && bytes[index + 1] == 10 {
                lines.append(bytes[start..<index])
                index += 2
                start = index
            } else {
                index += 1
            }
        }
        lines.append(bytes[start..<bytes.count])
        return lines
    }
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Yalnız yeni takım çalıştırılır. 1a'nın motor testleri çalıştırdıkları kopyaları hâlâ siliyor ve bu `syspolicyd`'yi çökertebilir; 18:24'te bu adımın tam takım çalıştırmasında bir kez daha oldu. Tam takım, motor testleri Görev 2'de kalıcı kopyalara geçtikten sonra çalışır.

Run: `swift test --package-path macos --filter RequestPolicyTests`
Expected: `✔ Test run with 7 tests in 1 suite passed`. `refusesWithTheWindowsCategory` 204 vakayla geçer. Çıktıda uyarı, hata ya da `skipped` yoktur.

---

### Görev 2: Bağlantı sahipleri

**Files:**
- Modify: `macos/Tests/DiscordAccessKitTests/TestSupport.swift` (tam dosya; eski SHA-256 `33d9205126eb1157cfec2eb2bda954555076941fd2289aff8a321537b016f8f7`)
- Modify: `macos/Tests/DiscordAccessKitTests/ProcessInspectorTests.swift` (tam dosya; eski SHA-256 `673948496623fbe35ff90c5804e957b5a2f870e3914dc7b09714b43a443f2dae`)
- Modify: `macos/Tests/DiscordAccessKitTests/EngineProcessTests.swift` (tam dosya; eski SHA-256 `5c9102406c6fe7c67cf2ca085fd4d442bf7ac3dee3869b56ae02dd3ef959be38`)
- Modify: `macos/Sources/DiscordAccessKit/System/ProcessInspector.swift` (tam dosya; eski SHA-256 `99923b149b2302df2a45c3fc63f186d5221e5ee34daba1049d320ac2e2a64540`)

- [ ] **Adım 1: Test yardımcılarını güncelle** (`swift` bloğu 2; yardımcıyla, eski hash verilerek)

Yeni yardımcılar:
- `TestEngine.runnableCopy(named:)`: çalıştırılacak motor kopyası. Kopyalar `macos/build/test-engines/<SHA-256 öneki>/` altında kalır; hiç silinmez ve üzerine yazılmaz. Yeniden derlenen motor yeni bir klasöre kopyalanır.
- `TCPListener.acceptClient()`: bir bağlantıyı kabul eder ve istemcinin portunu verir.
- `LoopbackClient`: test sürecinden bir loopback bağlantısı.
- `spawnSharing`: bir soketi 3 numaralı tanıtıcı olarak paylaşan alt süreç.
- `reap`: bu alt süreci öldürüp toplar.

```swift
import CryptoKit
import Darwin
import Foundation

/// The engine built by `macos/scripts/build-engine.py`; engine tests are skipped when it is absent.
enum TestEngine {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var path: String { realPath(packageRoot.appendingPathComponent("build/engine/sing-box").path) }
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// A copy of the engine for tests that run a copy, kept under `build/test-engines/<SHA-256 prefix>`. macOS scans every
    /// newly run file in the background; its scanner (syspolicyd) crashed when test copies were deleted mid-scan. Copies
    /// are therefore never deleted or replaced: a rebuilt engine gets a new folder.
    static func runnableCopy(named name: String) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
        let folder = packageRoot.appendingPathComponent("build/test-engines/" + digest.prefix(16)).path
        let copy = folder + "/" + name
        if !FileManager.default.fileExists(atPath: copy) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            // An interrupted copy never takes the final name, and a copy made meanwhile by another run is kept.
            let partial = copy + ".partial-" + UUID().uuidString
            try FileManager.default.copyItem(atPath: path, toPath: partial)
            guard renamex_np(partial, copy, UInt32(RENAME_EXCL)) == 0 || errno == EEXIST else { throw lastPOSIXError() }
        }
        return realPath(copy)
    }
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

    /// Accepts one connection within 5 seconds; returns its descriptor (the caller closes it) and the client's port.
    func acceptClient() throws -> (descriptor: Int32, clientPort: UInt16) {
        var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 5000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(descriptor, $0, &length) }
        }
        guard client >= 0 else { throw lastPOSIXError() }
        return (client, UInt16(bigEndian: address.sin_port))
    }
}

/// A TCP connection from the test process to 127.0.0.1:`port`.
final class LoopbackClient {
    let descriptor: Int32
    let localPort: UInt16

    init(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw lastPOSIXError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let connected = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(fd, generic, length) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard connected else {
            let error = lastPOSIXError()
            close(fd)
            throw error
        }
        descriptor = fd
        localPort = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(descriptor) }
}

/// Starts `executable` with `descriptor` as its descriptor 3, so that both processes hold the same socket.
func spawnSharing(_ descriptor: Int32, executable: String, arguments: [String]) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_adddup2(&actions, descriptor, 3) == 0,
          posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw POSIXError(.EINVAL) }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, argv, nil)
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    return pid
}

/// Kills and reaps a child started with `spawnSharing`.
func reap(_ pid: pid_t) {
    kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
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

- [ ] **Adım 2: Testleri güncelle** (`swift` bloğu 3; yardımcıyla, eski hash verilerek)

1a'daki `port &+ 1` varsayımı kaldırılır: geçici portlar sırayla dağıtıldığı için paralel bir testin dinleyicisi o portu alabiliyordu. Bağlantı sahipleri testi kümenin oturmasını bekler. Başka bir testin o sırada başlattığı alt süreç, `exec` anına kadar bu sürecin tanıtıcılarının kopyasını tutar.

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
        let client = try LoopbackClient(port: listener.port)
        #expect(ProcessInspector.ownsLoopbackListener(pid: getpid(), port: listener.port))
        // While this process's connected socket holds the client's port, no listener of any test can take it.
        withExtendedLifetime(client) { #expect(!ProcessInspector.ownsLoopbackListener(pid: getpid(), port: client.localPort)) }
        #expect(ProcessInspector.record(for: other.processIdentifier)?.uid == getuid())
        #expect(!ProcessInspector.ownsLoopbackListener(pid: other.processIdentifier, port: listener.port))
        #expect(!ProcessInspector.ownsLoopbackListener(pid: 1, port: listener.port))
    }

    @Test func ignoresListenersOutsideLoopback() throws {
        let wildcard = try TCPListener(address: "0.0.0.0")
        #expect(ProcessInspector.tcpSockets(of: getpid())?.contains { $0.listening && !$0.localLoopback && $0.localPort == wildcard.port } == true)
        #expect(!ProcessInspector.ownsLoopbackListener(pid: getpid(), port: wildcard.port))
    }

    /// Waits for the settled holder set: a child being spawned by another test briefly holds copies of this process's descriptors.
    static func holders(_ localPort: UInt16, _ remotePort: UInt16, settleTo expected: Set<pid_t>) -> Bool {
        waitFor { ProcessInspector.loopbackConnectionHolders(localPort: localPort, remotePort: remotePort).map(Set.init) == expected ? true : nil } == true
    }

    @Test func findsEveryHolderOfALoopbackConnection() throws {
        let listener = try TCPListener()
        let client = try LoopbackClient(port: listener.port)
        let accepted = try listener.acceptClient()
        defer { close(accepted.descriptor) }
        #expect(accepted.clientPort == client.localPort)
        #expect(Self.holders(client.localPort, listener.port, settleTo: [getpid()]))
        #expect(Self.holders(listener.port, client.localPort, settleTo: [getpid()]))
        #expect(Self.holders(listener.port, listener.port, settleTo: []))
        // A child that inherits the client's descriptor holds the same connection.
        let child = try spawnSharing(client.descriptor, executable: "/bin/sleep", arguments: ["30"])
        defer { reap(child) }
        #expect(Self.holders(client.localPort, listener.port, settleTo: [getpid(), child]))
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

- [ ] **Adım 3: Motor süreci testlerini güncelle** (`swift` bloğu 4; yardımcıyla, eski hash verilerek)

Motor kopyasını çalıştıran üç test (`refusesAnEngineOutsideTheCdhashPinBeforeItRuns`, `stopsAnEngineThatIsNotReadyInTime`, `terminatesOnlyLaunchdAdoptedCopiesOfTheEnginePath`) kalıcı kopyaları kullanır. Kopyayı hiç çalıştırmayan `reportsAFileChangedAfterVerificationAsAPackageError` geçici kopyasıyla kalır.

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Tests that count engine processes use their own copy of the engine, because `EngineConfigTests` runs `sing-box check`
/// children from `TestEngine.path` in parallel. Copies that are run stay under `build/test-engines` (`TestEngine.runnableCopy`).
@Suite(.serialized) struct EngineProcessTests {
    /// A copy that is never run, so it may be changed and deleted.
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
        let copy = try TestEngine.runnableCopy(named: "refused-sing-box")
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
        let copy = try TestEngine.runnableCopy(named: "not-ready-sing-box")
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
        let fakeEngine = try TestEngine.runnableCopy(named: "orphan-sing-box")
        let otherEngine = try TestEngine.runnableCopy(named: "other-sing-box")
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

- [ ] **Adım 4: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `type 'ProcessInspector' has no member 'loopbackConnectionHolders'` ve `cannot use optional chaining on non-optional value of type '[ProcessInspector.TCPSocket]'`, ayrıca buna bağlı `generic parameter 'Element' could not be inferred`.

- [ ] **Adım 5: Süreç denetçisini güncelle** (`swift` bloğu 5; yardımcıyla, eski hash verilerek)

Değişiklikler:
- Süreç ve tanıtıcı listeleri eksiksiz okunur. Arabellek dolarsa büyütülüp yeniden okunur; bir liste yine eksik kalırsa `nil` döner. Kapanmış tanıtıcı ve çıkmış süreç atlanır.
- `loopbackConnectionHolders`, bir bağlantıyı tutan bütün süreçleri döndürür. Windows `TcpOwner.Find` ilkinde durur.
- `satisfies` ağ kullanmaz (`kSecCSNoNetworkAccess`). Çevrimiçi iptal ve noterleştirme denetimi bir bağlantıyı dakikalarca bekletebilir.

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
        let established: Bool
        let localLoopback: Bool
        let localPort: UInt16
        let remoteLoopback: Bool
        let remotePort: UInt16
    }

    public static func userProcessIDs(uid: uid_t = getuid()) -> [pid_t] {
        completeUserProcessIDs(uid: uid) ?? []
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
        tcpSockets(of: pid)?.contains { $0.listening && $0.localLoopback && $0.localPort == port } ?? false
    }

    /// The same-user processes holding the loopback TCP connection that they see as 127.0.0.1:`localPort` to
    /// 127.0.0.1:`remotePort` (Windows `TcpOwner.Find`, which stops at the first). Nil when any process or descriptor list
    /// could not be read completely. Processes of other users cannot be inspected and are not part of the answer. A process
    /// being spawned holds copies of its parent's descriptors until it executes, so a caller needing an exact set retries.
    public static func loopbackConnectionHolders(localPort: UInt16, remotePort: UInt16, uid: uid_t = getuid()) -> [pid_t]? {
        guard let pids = completeUserProcessIDs(uid: uid) else { return nil }
        var holders: [pid_t] = []
        for pid in pids {
            guard let sockets = tcpSockets(of: pid) else { return nil }
            if sockets.contains(where: { $0.established && $0.localLoopback && $0.localPort == localPort && $0.remoteLoopback && $0.remotePort == remotePort }) {
                holders.append(pid)
            }
        }
        return holders
    }

    /// Dynamic code-signing check of a running process against a requirement, e.g. `cdhash H"…"` or a Team ID rule.
    /// It never uses the network: an online revocation or notarization check could stall a connection for a minute,
    /// and Gatekeeper already applied those checks when the process was launched.
    public static func satisfies(pid: pid_t, requirement text: String) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var requirement: SecRequirement?
        guard pid > 0, SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [.noNetworkAccess], requirement) == errSecSuccess
    }

    /// Every process of `uid`, or nil when the list could not be read completely.
    static func completeUserProcessIDs(uid: uid_t) -> [pid_t]? {
        for _ in 0..<4 {
            let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
            guard needed > 0 else { return nil }
            var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
            let filled = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), buffer.baseAddress, Int32(buffer.count))
            }
            guard filled > 0 else { return nil }
            // A full buffer may have been cut short by processes started meanwhile; read again with more room.
            let count = Int(filled) / MemoryLayout<pid_t>.stride
            if count < pids.count { return pids.prefix(count).filter { $0 > 0 } }
        }
        return nil
    }

    /// The IPv4 TCP sockets of `pid` ([] once it has exited), or nil when its descriptors could not be read completely.
    static func tcpSockets(of pid: pid_t) -> [TCPSocket]? {
        guard let descriptors = socketDescriptors(of: pid) else { return nil }
        let loopback = inet_addr("127.0.0.1")
        var sockets: [TCPSocket] = []
        for descriptor in descriptors {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            errno = 0
            guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size else {
                // A descriptor closed or reused meanwhile, or a process that exited, holds nothing any more.
                if errno == EBADF || errno == ENOTSOCK || errno == ESRCH { continue }
                return nil
            }
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let endpoint = tcp.tcpsi_ini
            guard endpoint.insi_vflag & UInt8(INI_IPV4) != 0 else { continue }
            sockets.append(TCPSocket(listening: tcp.tcpsi_state == Int32(TSI_S_LISTEN),
                                     established: tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED),
                                     localLoopback: endpoint.insi_laddr.ina_46.i46a_addr4.s_addr == loopback,
                                     localPort: networkPort(endpoint.insi_lport),
                                     remoteLoopback: endpoint.insi_faddr.ina_46.i46a_addr4.s_addr == loopback,
                                     remotePort: networkPort(endpoint.insi_fport)))
        }
        return sockets
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// The socket descriptors of `pid` ([] once it has exited), or nil when its table could not be read completely.
    private static func socketDescriptors(of pid: pid_t) -> [Int32]? {
        for _ in 0..<4 {
            errno = 0
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return errno == 0 || errno == ESRCH ? [] : nil }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16)
            errno = 0
            let filled = descriptors.withUnsafeMutableBytes { buffer in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard filled > 0 else { return errno == 0 || errno == ESRCH ? [] : nil }
            // A full buffer may have been cut short by descriptors opened meanwhile; read again with more room.
            let count = Int(filled) / MemoryLayout<proc_fdinfo>.stride
            if count < descriptors.count {
                return descriptors.prefix(count).filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }.map(\.proc_fd)
            }
        }
        return nil
    }

    private static func networkPort(_ value: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: value))
    }
}
```

- [ ] **Adım 6: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 35 tests in 7 suites passed`, uyarısız ve `skipped` olmadan. `findsEveryHolderOfALoopbackConnection` geçer.

---

### Görev 3: Eş kabulü

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/PeerAdmissionTests.swift`, `macos/Sources/DiscordAccessKit/Gate/PeerAdmission.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 6)

`/usr/bin/nc`, Discord'un yerine geçer: Apple imzalı ve kapıya açtığı bağlantıyı açık tutan (`-d`) gerçek bir istemcidir.

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// `/usr/bin/nc` stands in for Discord: an Apple-signed client that keeps its connection to the gate open (`-d`).
@Suite struct PeerAdmissionTests {
    static let netcat = ApprovedExecutable(path: "/usr/bin/nc", requirement: "identifier \"com.apple.nc\" and anchor apple")
    static let sleeper = ApprovedExecutable(path: "/bin/sleep", requirement: "identifier \"com.apple.sleep\" and anchor apple")

    /// A netcat child connected to `gate`, the client port the gate saw, and the accepted descriptor (the caller closes it).
    static func connectNetcat(to gate: TCPListener) throws -> (process: Process, clientPort: UInt16, accepted: Int32) {
        let process = try startChild("/usr/bin/nc", ["-d", "127.0.0.1", String(gate.port)])
        do {
            let accepted = try gate.acceptClient()
            return (process, accepted.clientPort, accepted.descriptor)
        } catch {
            stop(process)
            throw error
        }
    }

    static func stop(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }

    /// Waits out a process that another test is spawning: until it executes, it holds copies of this process's
    /// descriptors, so for a moment it also holds the connections this process made.
    static func eventuallyPermits(_ admission: PeerAdmission, clientPort: UInt16, gatePort: UInt16) -> Bool {
        waitFor { admission.permits(clientPort: clientPort, gatePort: gatePort) ? true : nil } == true
    }

    static func record(uid: uid_t = getuid(), start: UInt64, path: String = "/usr/bin/nc") -> ProcessInspector.Record {
        ProcessInspector.Record(pid: 4242, parentPid: 1, uid: uid, startSeconds: start / 1_000_000, startMicroseconds: start % 1_000_000, path: path)
    }

    @Test func checksUserStartTimeAndExecutable() throws {
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date(timeIntervalSince1970: 1_800_000_000.25))
        let ready: UInt64 = 1_800_000_000_250_000
        #expect(admission.requirement(for: Self.record(start: ready)) == Self.netcat.requirement)
        #expect(admission.requirement(for: Self.record(start: ready + 1)) == Self.netcat.requirement)
        #expect(admission.requirement(for: Self.record(start: ready - 1)) == nil)
        #expect(admission.requirement(for: Self.record(start: 0)) == nil)
        #expect(admission.requirement(for: Self.record(uid: getuid() &+ 1, start: ready)) == nil)
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/bin/curl")) == nil)
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/bin/../bin/nc")) == Self.netcat.requirement)
        // On a case-insensitive volume the process path may differ from the approved one in letter case only.
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/BIN/nc")) ==
            (FileManager.default.fileExists(atPath: "/usr/BIN/nc") ? Self.netcat.requirement : nil))
    }

    @Test func refusesUnsafeConfiguration() throws {
        #expect(throws: PeerAdmission.ConfigurationError.noExecutables) { try PeerAdmission(approved: [], readyTime: Date()) }
        #expect(throws: PeerAdmission.ConfigurationError.tooManyExecutables) {
            try PeerAdmission(approved: Array(repeating: Self.netcat, count: 17), readyTime: Date())
        }
        #expect(throws: Never.self) { try PeerAdmission(approved: Array(repeating: Self.netcat, count: 16), readyTime: Date()) }
        for path in ["usr/bin/nc", "/usr/bin/../bin/nc", "/tmp", "/usr/bin/missing-fixture"] {
            #expect(throws: PeerAdmission.ConfigurationError.unsafePath(path)) {
                try PeerAdmission(approved: [ApprovedExecutable(path: path, requirement: "anchor apple")], readyTime: Date())
            }
        }
    }

    @Test func admitsAnApprovedClientUntilItExits() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let client = try Self.connectNetcat(to: gate)
        defer { close(client.accepted) }
        #expect(admission.permits(clientPort: client.clientPort, gatePort: gate.port))
        #expect(admission.permits(clientPort: client.clientPort, gatePort: gate.port))
        #expect(admission.anyAdmittedRunning)
        Self.stop(client.process)
        #expect(!admission.permits(pid: client.process.processIdentifier))
        #expect(!admission.anyAdmittedRunning)
        // Nothing holds the client end any more; an empty set of holders is never admitted.
        #expect(!admission.permits(clientPort: client.clientPort, gatePort: gate.port))
    }

    /// A process whose parent exits moves to launchd. It is still the same admitted instance and still counts as running.
    @Test func keepsAnAdmittedClientWhoseParentExits() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let launcher = try startChild("/bin/sh", ["-c", "/usr/bin/nc -d 127.0.0.1 \"$0\" & wait", String(gate.port)])
        defer { Self.stop(launcher) }
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        let client = try #require(waitFor { ProcessInspector.loopbackConnectionHolders(localPort: accepted.clientPort, remotePort: gate.port)?.first })
        defer { kill(client, SIGKILL) }
        #expect(ProcessInspector.record(for: client)?.parentPid == launcher.processIdentifier)
        #expect(admission.permits(clientPort: accepted.clientPort, gatePort: gate.port))
        kill(launcher.processIdentifier, SIGTERM)
        launcher.waitUntilExit()
        #expect(waitFor { ProcessInspector.record(for: client)?.parentPid == 1 ? true : nil } == true)
        #expect(admission.anyAdmittedRunning)
        #expect(admission.permits(clientPort: accepted.clientPort, gatePort: gate.port))
    }

    @Test func refusesClientsStartedBeforeReadiness() throws {
        let gate = try TCPListener()
        let client = try Self.connectNetcat(to: gate)
        defer {
            close(client.accepted)
            Self.stop(client.process)
        }
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        #expect(!admission.permits(clientPort: client.clientPort, gatePort: gate.port))
    }

    @Test func refusesOtherExecutablesAndWrongRequirements() throws {
        let gate = try TCPListener()
        let ready = Date()
        let client = try Self.connectNetcat(to: gate)
        defer {
            close(client.accepted)
            Self.stop(client.process)
        }
        let requirements = [Self.sleeper.requirement, "identifier \"com.hnc.Discord\" and anchor apple generic and certificate leaf[subject.OU] = \"53Q6R32WPB\""]
        #expect(!(try PeerAdmission(approved: [Self.sleeper], readyTime: ready)).permits(clientPort: client.clientPort, gatePort: gate.port))
        for requirement in requirements {
            let impostor = ApprovedExecutable(path: "/usr/bin/nc", requirement: requirement)
            #expect(!(try PeerAdmission(approved: [impostor], readyTime: ready)).permits(clientPort: client.clientPort, gatePort: gate.port))
        }
        #expect((try PeerAdmission(approved: [Self.sleeper, Self.netcat], readyTime: ready)).permits(clientPort: client.clientPort, gatePort: gate.port))
    }

    @Test func admitsItselfOnlyWithDiagnosticPermission() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let client = try LoopbackClient(port: gate.port)
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        #expect(!admission.permits(clientPort: client.localPort, gatePort: gate.port))
        admission.diagnosticAllowed = true
        #expect(Self.eventuallyPermits(admission, clientPort: client.localPort, gatePort: gate.port))
        admission.diagnosticAllowed = false
        #expect(!admission.permits(clientPort: client.localPort, gatePort: gate.port))
    }

    /// Windows admits the first process it finds; here every process holding the connection must be admitted.
    @Test func requiresEveryHolderOfTheConnection() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        admission.diagnosticAllowed = true
        let client = try LoopbackClient(port: gate.port)
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        let child = try spawnSharing(client.descriptor, executable: "/bin/sleep", arguments: ["30"])
        #expect(!admission.permits(clientPort: client.localPort, gatePort: gate.port))
        reap(child)
        #expect(Self.eventuallyPermits(admission, clientPort: client.localPort, gatePort: gate.port))
    }

    @Test func remembersAtMostItsCapacityAndNothingAfterClose() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date(), capacity: 1)
        let first = try Self.connectNetcat(to: gate)
        defer {
            close(first.accepted)
            Self.stop(first.process)
        }
        let second = try Self.connectNetcat(to: gate)
        defer {
            close(second.accepted)
            Self.stop(second.process)
        }
        #expect(admission.permits(clientPort: first.clientPort, gatePort: gate.port))
        #expect(!admission.permits(clientPort: second.clientPort, gatePort: gate.port))
        admission.close()
        #expect(!admission.permits(clientPort: first.clientPort, gatePort: gate.port))
        #expect(!admission.anyAdmittedRunning)
        #expect(!admission.permits(pid: 0))
        #expect(!admission.permits(pid: -1))
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'ApprovedExecutable' in scope`, `cannot find 'PeerAdmission' in scope` ve `cannot find type 'PeerAdmission' in scope`.

- [ ] **Adım 3: Eş kabulünü yaz** (`swift` bloğu 7)

Akış:
1. Bağlantının istemci ucunu tutan bütün süreçler bulunur. Liste eksikse ya da bir süreç kabul edilmezse 10 ms arayla üç kez yeniden denenir; doğmakta olan bir süreç `exec` anına kadar ebeveyninin tanıtıcılarını tutar. Hiçbir sürecin tutmadığı bağlantı reddedilir.
2. Bu süreç yalnız tanı izni açıkken kabul edilir.
3. Diğer süreçler için: aynı kullanıcı, başlangıç zamanı hazır olma anından sonra, gerçek yolu onaylı bir dosya, çalışan kodu o dosyanın gereksinimini karşılıyor. Kayıt denetimden önce ve sonra karşılaştırılır. Windows ayrıca oturum kimliğini karşılaştırır; macOS'ta bunun karşılığı kullanıcı kimliğidir, çünkü bir kullanıcının aynı anda tek bir grafik oturumu olur.
4. İmza denetimi kilit dışında yapılır. Kabul, süreç örneği (PID, başlangıç zamanı, yol) başına ve en fazla 256 süreç için hatırlanır. Ebeveyn örnek kimliğine girmez: ebeveyni ölen süreç launchd'ye geçer ve kabul edilmiş kalır. Okunamayan ama var olan süreç listeden düşmez; `anyAdmittedRunning` onu çalışıyor sayar, kabul ise reddedilir (Windows `Unknown`).
5. Denetimlerden sonra bağlantının sahip kümesi yeniden okunur ve aynı olmalıdır.

Sahip kümesinin yeniden okunması, kaydın imza denetiminden önce ve sonra karşılaştırılması ve önbellek isabetindeki örnek denetimi yarışlara karşıdır. Okunamayan ama var olan sürecin listede tutulması (`kill(pid, 0)`) da test edilemeyen bir durumdur. `ProcessInspector` statik olduğu için bunlar testle bozulamaz; incelemeyle doğrulandılar. İki kapasite denetimi birbirini yedekler: biri kaldırılınca testler geçer, ikisi birlikte kaldırılınca yakalanır.

```swift
import Darwin
import Foundation

/// An executable that may use the gate, and the code-signing requirement its running processes must satisfy.
public struct ApprovedExecutable: Equatable, Sendable {
    public let path: String
    public let requirement: String

    public init(path: String, requirement: String) {
        self.path = path
        self.requirement = requirement
    }
}

/// Which local processes may use the gate (Windows `ExternalDiscordScope` with `ProcessGate.PermittedOwner`).
///
/// Every same-user holder of the client end of a connection must be admitted. A process is admitted when it runs an
/// approved executable for this user, started at or after `readyTime`, and its running code satisfies the executable's
/// requirement. This process itself is admitted only while `diagnosticAllowed` is set. Admissions are remembered per
/// process instance (pid, start time and path), at most `capacity` at a time; refusals are not remembered.
public final class PeerAdmission {
    public enum ConfigurationError: Error, Equatable {
        case noExecutables
        case tooManyExecutables
        case unsafePath(String)
    }

    public static let maxExecutables = 16
    private let approved: [String: String]
    private let readyMicroseconds: UInt64
    private let uid: uid_t
    private let capacity: Int
    private let lock = NSLock()
    private var admitted: [pid_t: ProcessInspector.Record] = [:]
    private var diagnostic = false
    private var closed = false

    /// Each path must be the real path of an existing executable: matching compares real paths exactly.
    public init(approved executables: [ApprovedExecutable], readyTime: Date, uid: uid_t = getuid(), capacity: Int = 256) throws {
        guard !executables.isEmpty else { throw ConfigurationError.noExecutables }
        guard executables.count <= Self.maxExecutables else { throw ConfigurationError.tooManyExecutables }
        for executable in executables where canonicalPath(executable.path) != executable.path {
            throw ConfigurationError.unsafePath(executable.path)
        }
        approved = Dictionary(executables.map { ($0.path, $0.requirement) }, uniquingKeysWith: { first, _ in first })
        readyMicroseconds = UInt64(max(0, readyTime.timeIntervalSince1970 * 1_000_000))
        self.uid = uid
        self.capacity = capacity
    }

    /// Lets this process use the gate, for the controller's own diagnostics.
    public var diagnosticAllowed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return diagnostic
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            diagnostic = newValue
        }
    }

    /// Whether the connection whose client end is 127.0.0.1:`clientPort` to 127.0.0.1:`gatePort` may use the gate.
    /// A process being spawned holds copies of its parent's descriptors until it executes, so a refusal is retried
    /// three times, 10 ms apart (Windows `FindPeer` retries the same way); lasting extra holders are still refused.
    public func permits(clientPort: UInt16, gatePort: UInt16) -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { usleep(10_000) }
            guard let holders = ProcessInspector.loopbackConnectionHolders(localPort: clientPort, remotePort: gatePort, uid: uid),
                  !holders.isEmpty, holders.allSatisfy(permits(pid:)) else { continue }
            // The connection must still belong to exactly the processes that were checked.
            if ProcessInspector.loopbackConnectionHolders(localPort: clientPort, remotePort: gatePort, uid: uid).map(Set.init) == Set(holders) {
                return true
            }
        }
        return false
    }

    /// Whether `pid` is admitted: this process only through `diagnosticAllowed`, any other through its checks.
    public func permits(pid: pid_t) -> Bool {
        lock.lock()
        guard !closed, pid > 0 else {
            lock.unlock()
            return false
        }
        if pid == getpid() {
            let allowed = diagnostic
            lock.unlock()
            return allowed
        }
        pruneGone()
        if let known = admitted[pid] {
            defer { lock.unlock() }
            // Kept as running or as unreadable: only a readable instance that still meets the checks is admitted.
            guard let current = ProcessInspector.record(for: pid) else { return false }
            return Self.sameInstance(current, known) && requirement(for: current) != nil
        }
        let full = admitted.count >= capacity
        lock.unlock()
        // The signature check runs without the lock, so a slow one does not hold up processes admitted before.
        guard !full, let before = ProcessInspector.record(for: pid), let requirement = requirement(for: before),
              ProcessInspector.satisfies(pid: pid, requirement: requirement),
              let after = ProcessInspector.record(for: pid), Self.sameInstance(after, before) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !closed, admitted.count < capacity || admitted[pid] != nil else { return false }
        admitted[pid] = before
        return true
    }

    /// Whether a process admitted earlier is still running (Windows `AnyRunning`); one that cannot be read but still
    /// exists counts as running.
    public var anyAdmittedRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneGone()
        return !admitted.isEmpty
    }

    /// Admits nothing afterwards; running processes are not affected.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        admitted.removeAll()
    }

    /// The requirement of the approved executable `record` runs, when it is this user's and started after readiness.
    func requirement(for record: ProcessInspector.Record) -> String? {
        guard record.uid == uid, record.startSeconds > 0,
              record.startSeconds * 1_000_000 + record.startMicroseconds >= readyMicroseconds else { return nil }
        return approved[canonicalPath(record.path) ?? ""]
    }

    /// Drops admissions whose process instance is gone. One that cannot be read but still exists is kept (Windows keeps
    /// `Unknown` the same way). Must be called with `lock` held.
    private func pruneGone() {
        admitted = admitted.filter { pid, known in
            guard let current = ProcessInspector.record(for: pid) else { return kill(pid, 0) == 0 || errno == EPERM }
            return Self.sameInstance(current, known)
        }
    }

    /// The parent may change (a process whose parent exits moves to launchd); the pid, start time and path may not.
    private static func sameInstance(_ current: ProcessInspector.Record, _ known: ProcessInspector.Record) -> Bool {
        current.pid == known.pid && current.startSeconds == known.startSeconds &&
            current.startMicroseconds == known.startMicroseconds && current.path == known.path
    }
}

/// The real path (links resolved, letter case as on disk), or nil when it does not exist.
private func canonicalPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 44 tests in 8 suites passed`, uyarısız ve `skipped` olmadan. Ardından `pgrep -fl "nc -d|sleep 30"` hiçbir şey yazmaz.

---

### Görev 4: Discord'un onaylı dosyaları

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/DiscordApplicationTests.swift`, `macos/Sources/DiscordAccessKit/Discord/DiscordApplication.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 8)

Kurulu Discord'la karşılaştırma imzayı doğrulamaz, yalnız okur. Paketlerin statik doğrulaması noterleştirme biletini `syspolicyd`'ye kaydeder; bu çağrı testlerde dakikalarca bekledi. Kurulu uygulamanın bütün yürütülebilir dosyaları da onay listesiyle karşılaştırılır: listede olmayan bir yardımcının bağlantıları çalışma anında sessizce reddedilirdi; Discord yeni bir yardımcı eklerse ya da birinin adını değiştirirse bu test başarısız olur.

```swift
import Foundation
import Security
import Testing
@testable import DiscordAccessKit

@Suite struct DiscordApplicationTests {
    static let installed = "/Applications/Discord.app"
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installed + "/Contents/MacOS/Discord") }

    /// Discord's designated requirement for the executable, read from its signature without validating it: static
    /// validation registers the stapled notarization ticket with syspolicyd and can wait on it for minutes.
    static func designatedRequirement(_ path: String) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &information) == errSecSuccess,
              let designated = (information as? [String: Any])?[kSecCodeInfoDesignatedRequirement as String] else { return nil }
        return text(of: designated as! SecRequirement)
    }

    /// The canonical text of a requirement, as Security.framework prints it.
    static func text(of requirement: SecRequirement) -> String? {
        var text: CFString?
        return SecRequirementCopyString(requirement, [], &text) == errSecSuccess ? text as String? : nil
    }

    static func canonical(_ source: String) -> String? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess, let requirement else { return nil }
        return text(of: requirement)
    }

    @Test func approvesTheMainExecutableAndEveryHelperWithItsOwnIdentifier() {
        let approved = DiscordApplication.approvedExecutables(bundle: "/Applications/Discord.app")
        let frameworks = "/Applications/Discord.app/Contents/Frameworks/"
        #expect(approved.map(\.path) == ["/Applications/Discord.app/Contents/MacOS/Discord",
                                         frameworks + "Discord Helper.app/Contents/MacOS/Discord Helper",
                                         frameworks + "Discord Helper (GPU).app/Contents/MacOS/Discord Helper (GPU)",
                                         frameworks + "Discord Helper (Plugin).app/Contents/MacOS/Discord Helper (Plugin)",
                                         frameworks + "Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"])
        #expect(approved.map { $0.requirement.components(separatedBy: "\"")[1] } ==
            ["com.hnc.Discord", "com.hnc.Discord.helper", "com.hnc.Discord.helper.GPU", "com.hnc.Discord.helper.Plugin", "com.hnc.Discord.helper.Renderer"])
        #expect(approved[0].requirement == "identifier \"com.hnc.Discord\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]" +
            " exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"53Q6R32WPB\"")
    }

    /// Each requirement is the installed Discord's own designated requirement for that executable.
    @Test(.enabled(if: isInstalled)) func requirementsAreTheInstalledDiscordsDesignatedRequirements() {
        for executable in DiscordApplication.approvedExecutables(bundle: Self.installed) {
            let designated = Self.designatedRequirement(executable.path)
            #expect(designated != nil, "\(executable.path)")
            #expect(Self.canonical(executable.requirement) == designated, "\(executable.path)")
        }
    }

    /// The connections of a helper missing from the list would be refused silently at run time, so a helper app that
    /// Discord adds or renames must fail this test instead.
    @Test(.enabled(if: isInstalled)) func approvesEveryExecutableOfTheInstalledApp() throws {
        let files = FileManager.default
        let contents = Self.installed + "/Contents"
        var executables = try files.contentsOfDirectory(atPath: contents + "/MacOS").map { contents + "/MacOS/" + $0 }
        for helper in try files.contentsOfDirectory(atPath: contents + "/Frameworks") where helper.hasSuffix(".app") {
            let folder = contents + "/Frameworks/" + helper + "/Contents/MacOS"
            executables += try files.contentsOfDirectory(atPath: folder).map { folder + "/" + $0 }
        }
        #expect(Set(executables) == Set(DiscordApplication.approvedExecutables(bundle: Self.installed).map(\.path)))
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'DiscordApplication' in scope`. Tür henüz olmadığı için `generic parameter 'some StringProtocol' could not be inferred`, `cannot infer key path type from context` ve `the compiler is unable to type-check this expression in reasonable time` hataları da görülür; tür tanımlanınca kaybolur.

- [ ] **Adım 3: Onaylı dosyaları yaz** (`swift` bloğu 9)

Gereksinimler Discord 0.0.415'in designated requirement'larıdır (`codesign -d -r-` ile okundu): her dosyanın kendi tanımlayıcısı, Developer ID sertifika alanları ve Team ID `53Q6R32WPB`.

```swift
/// The executables of a Discord.app that may use the gate. Each one is bound to its own signing identifier and to
/// Discord's Developer ID, as in the designated requirements of Discord 0.0.415.
public enum DiscordApplication {
    public static let teamIdentifier = "53Q6R32WPB"
    static let executables = [
        (path: "Contents/MacOS/Discord", identifier: "com.hnc.Discord"),
        (path: "Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper", identifier: "com.hnc.Discord.helper"),
        (path: "Contents/Frameworks/Discord Helper (GPU).app/Contents/MacOS/Discord Helper (GPU)", identifier: "com.hnc.Discord.helper.GPU"),
        (path: "Contents/Frameworks/Discord Helper (Plugin).app/Contents/MacOS/Discord Helper (Plugin)", identifier: "com.hnc.Discord.helper.Plugin"),
        (path: "Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)",
         identifier: "com.hnc.Discord.helper.Renderer"),
    ]

    /// Discord's designated requirement for one of its signing identifiers.
    public static func requirement(identifier: String) -> String {
        "identifier \"" + identifier + "\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists" +
            " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"" + teamIdentifier + "\""
    }

    /// The approved executables inside `bundle`, the real path of the selected Discord.app.
    public static func approvedExecutables(bundle: String) -> [ApprovedExecutable] {
        executables.map { ApprovedExecutable(path: bundle + "/" + $0.path, requirement: requirement(identifier: $0.identifier)) }
    }
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 47 tests in 9 suites passed`, uyarısız ve `skipped` olmadan. `requirementsAreTheInstalledDiscordsDesignatedRequirements` geçer.

---

### Görev 5: Son doğrulama ve teslim

- [ ] **Adım 1: Bütün testler**

Run: `swift test --package-path macos && python3 -B macos/Tests/build-engine.test.py`
Expected: `✔ Test run with 47 tests in 9 suites passed`, ardından `Ran 35 tests` ve `OK`. Swift çıktısında `skipped` geçmez. Swift takımı iki kez daha çalıştırılır; geride `nc`, `sleep 30` ya da `sing-box` süreci kalmaz.

- [ ] **Adım 2: Tasarım belgesine durum notu**

`macos/docs/2026-10-14-macos-tasarim.md` Bölüm 11'de, **1a durumu** satırının altına şu satır eklenir:

`- **1b durumu:** Tamamlandı (kapı istek politikası ve eş kimliği). Plan: macos/docs/plans/2026-10-14-asama-1b-kapi-politikasi-ve-es-kimligi.md.`

- [ ] **Adım 3: Git durumu ve commit sorusu**

Run: `git status --porcelain --untracked-files=all; git diff --name-only main`
Expected: `git diff` boş; durum yalnız `macos/` altındaki dosyaları gösterir.

Kullanıcıya değişen dosyalar, yapılan ve yapılmayan kontroller raporlanır, commit isteyip istemediği sorulur. 1a henüz commit edilmediyse bu commit 1a dosyalarını da içerir. İsterse:

```bash
git add macos/.gitignore macos/Package.swift macos/Sources macos/Tests macos/docs macos/scripts/build-engine.py
git commit -m "feat(macos): add the DiscordAccessKit engine layer, gate request policy and peer admission"
```
