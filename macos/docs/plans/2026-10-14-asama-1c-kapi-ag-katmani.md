# Aşama 1c — Kapının Ağ Katmanı Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Hedef:** Kapıyı `DiscordAccessKit`'te tamamlamak (Windows `ProcessGate`):

- 127.0.0.1'de dinleme; her bağlantıda eş kabulü, başlık okuma ve istek politikası
- motora bağlantı ve her bağlantıda motor kimliği
- iki yönlü aktarım ve Windows biçiminde tanı satırları

Ayrıca 1b'de bulunan bir hata düzeltilir: eş araması kullanıcının bütün süreçlerinin tanıtıcılarını inceliyordu ve bu, başka uygulamaların soketlerini bozabiliyordu.

**Mimari:**
- `PeerAdmission`, bağlantının istemci ucunu yalnız adaylarda arar: bu süreç ve onaylı Discord dosyalarını çalıştıran süreçler. `ProcessInspector`, `exec`'i bitmemiş ya da çıkmakta olan süreçlerin tanıtıcılarına bakmaz. Ret, nedeniyle döner (`PeerAdmission.Refusal`).
- `GateDiagnostics`, tanı satırlarını Windows biçiminde üretir; `TraceBudget` dakikadaki satır sayısını sınırlar.
- `LoopbackSocket`, bloklamayan loopback soketlerini ve beklemeleri sağlar. Her bekleme monoton saatle ölçülen bir son tarihte ya da kapanışı bildiren durdurma borusuyla biter.
- `Relay`, iki yönü tek iş parçacığında `poll` ile aktarır, yarım kapamayı geçirir ve boşaltmayı süreyle sınırlar.
- `ProxyGate`, bağlantıları kabul eder ve her birini kendi iş parçacığında aşama aşama işler.
- Kapının denetleyiciye ve Discord'a bağlanması 1g'dedir. Bu plan, testlerdeki loopback bağlantıları dışında ağ kullanmaz.

**Teknolojiler:** Swift 6.4 (Swift 5 dil modu), SwiftPM, Swift Testing, Darwin soketleri ve `poll`, libproc, Security.framework.

---

## Aşama 1 alt planları

| Alt plan | Kapsam |
| --- | --- |
| 1a | Tamamlandı: paket iskeleti, motor yapılandırması, motor doğrulama ve başlatma, yetim motor temizliği, derleme betiği sabitleri |
| 1b | Tamamlandı: kapı istek politikası ve eş kimliği |
| **1c** | Kapının ağ katmanı: dinleme, aktarım, her bağlantıda motor kimliği, tanı kayıtları (`SafeTarget`), ret nedenleri (bu plan) |
| 1d | Bağlantı tanısı (Gateway HELLO) ve otomatik DNS seçimi |
| 1e | Güncelleme köprüsü (manifest ve yönlendirme yeniden yazma, indirmeler) |
| 1f | Discord kurulumu ve profil değişiklikleri: günlük, tüm çekirdek nesilleri, gömülü kanca, Tam Disk Erişimi |
| 1g | Terminal modu (Q/T/D/A) ile uçtan uca birleştirme |

Tasarımdaki kararlar `macos/docs/2026-10-14-macos-tasarim.md` Bölüm 8'dedir ("Eş kabulü" ve "Kapının ağ katmanı").

## Yürütme notları

- Tüm komutlar depo kökünden (`/Users/alpertekin/Documents/GitHub/DiscordAccess`), `feature/macos` dalında çalıştırılır.
- `macos/` dışında hiçbir dosya değişmez. Commit yalnız kullanıcının açık isteğiyle yapılır.
- Bütün macOS testleri `macos/Tests/` altındadır. Küçük harfli `tests/` klasörü açılmaz.
- Kod blokları geçici klasörde derlendi. Tam takım son haliyle art arda 15 kez geçti. Bozma denetimlerinde 31 bozmanın her biri en az bir testte yakalandı (biri testi asılı bıraktığı için); testle oluşturulamayan yollar ilgili adımda belirtilir. Kod elle yeniden yazılmaz; aşağıdaki yardımcıyla hash doğrulanarak çıkarılır.
- 1b'nin dört dosyası (`ProcessInspectorTests.swift`, `PeerAdmissionTests.swift`, `ProcessInspector.swift`, `PeerAdmission.swift`) Görev 1'de tamamen değiştirilir. Yardımcıya 1b'deki son hash'leri verilir.
- Testler sistemdeki Apple imzalı `/usr/bin/nc` ve `/bin/sleep` dosyalarını kullanır. Discord'a özel test, `/Applications/Discord.app` yoksa atlanır. Bu Mac'te Discord kurulu olduğu için atlanmaz. Çıktıda `skipped` geçmediği her doğrulamada denetlenir.
- Testler boş port varsaymaz. Üç istisna vardır ve hepsi sistemin dağıttığı aralığın (49152–65535) dışında, daha önce hiçbir şeyin yanıt vermediği bir port arar: başlamadan kapatılan kapının portunu bıraktığını gösteren test 20000–20199, reddedilen bağlantı testi 21000–21199, kapanan kapının dinleyicisini `close()` dönmeden kapattığını gösteren test 22000–22199 arasında.
- Testler, bu sürecin alt süreçleri ile `/usr/bin/nc` ya da `/bin/sleep` çalıştıran süreçler dışında hiçbir sürecin tanıtıcılarına bakmaz; launchd'nin tanıtıcıları zaten okunamaz. Başka süreçlerin tanıtıcılarını incelemek onların soketlerini bozabilir (Görev 1).
- macOS, çalıştırılan her yeni dosyayı `syspolicyd` ile arka planda tarar ve tarama sırasında silinen dosyada çöker. Çalıştırılan dosyalar bu yüzden silinmez; motor kopyaları 1b'den beri `macos/build/test-engines/` altında kalıcıdır, tam takım her adımda çalışabilir. Bir komut yine beklerse `syspolicyd`'nin geri gelmesi beklenir; test döngüsü üst üste çalıştırılmaz.
- Swift'te "kırmızı" durum derleme hatasıdır.

## Dosya yapısı

| Dosya | Sorumluluk | SHA-256 |
| --- | --- | --- |
| `macos/Sources/DiscordAccessKit/System/ProcessInspector.swift` | Değişir: tek sürecin bağlantı sorusu; `exec`'i bitmemiş ya da çıkmakta olan süreç incelenmez | `4ab90f4b80275bec1550f86c30674a471b437b0290f4e5ea72b2ac6e744e673f` |
| `macos/Sources/DiscordAccessKit/Gate/PeerAdmission.swift` | Değişir: aday araması, ret nedenleri, eksik dosya hatası | `b9ec34a2419667f85740ea96603e145639926b110fec41bbc0877a183fb131cf` |
| `macos/Sources/DiscordAccessKit/Gate/GateDiagnostics.swift` | Yeni: aşamalar, hata kategorileri, tanı satırları, `SafeTarget`, `TraceBudget` | `a3284ab361a12e6c969e96d786cb987ce4b278e0fe36c22042533d0cf30866f4` |
| `macos/Sources/DiscordAccessKit/Gate/LoopbackSocket.swift` | Yeni: bloklamayan loopback soketleri, süreli beklemeler, durdurma borusu | `5d35338ac5cf961095dad036d47c6906fbb11b77099e028d9ebc8782e9c6413a` |
| `macos/Sources/DiscordAccessKit/Gate/Relay.swift` | Yeni: iki yönlü aktarım | `7763e18a7230db8c407bbb66fab0f8b1a3dbd9a90fcf2226695961284c5e0815` |
| `macos/Sources/DiscordAccessKit/Gate/ProxyGate.swift` | Yeni: kapı | `c6c99b07a82361daed6653efa09b94ff2c138ffa0f8570020c45226f22a9e979` |
| `macos/Tests/DiscordAccessKitTests/ProcessInspectorTests.swift` | Değişir: bağlantı sorusu; doğmakta olan süreçlerin soketleri bozulmaz | `6b59885be19617d9a562b08ef3872bb1380dbdecd136df3c79158d013ee2270f` |
| `macos/Tests/DiscordAccessKitTests/PeerAdmissionTests.swift` | Değişir: ret nedenleri, aday araması, hemen ret | `cb0de9c28df8f5d3712f2b4f2bc8b5221b1dd1ce66a3ff9fdcb812a0c75d2aca` |
| `macos/Tests/DiscordAccessKitTests/GateDiagnosticsTests.swift` | Yeni: Windows tanı vektörleri | `45189585652c4d8217a410089dd1c6da86d59dab38a027ad2d1903c1f7357c07` |
| `macos/Tests/DiscordAccessKitTests/LoopbackSocketTests.swift` | Yeni: soket seçenekleri, başlık okuma, süre ve durdurma, bağlantı reddi | `a273d0775d5f60cb3a5fe6a0dbd2435944e2ddb20679137b4446f997a026d3fc` |
| `macos/Tests/DiscordAccessKitTests/RelayTests.swift` | Yeni: gerçek loopback bağlantılarıyla aktarım | `8eca6bb6827068273151582683804d2903ccfe27bd3575117c4c5effefbf1ac1` |
| `macos/Tests/DiscordAccessKitTests/ProxyGateTests.swift` | Yeni: sahte motor ve `nc` istemcileriyle uçtan uca kapı | `73e87fee2e0d6897aeb51ea39f0467081ea107a8f8a0e262a1fd3c5d038a6131` |

Plandan dosya çıkarma yardımcısı. `LANG` kod bloğu dilidir, `INDEX` o dildeki 0 tabanlı sıradır. Yardımcı hash doğrular; yeni dosyada var olanın üzerine yazmaz, değiştirilen dosyada eski hash'i ister.

```bash
python3 -I - macos/docs/plans/2026-10-14-asama-1c-kapi-ag-katmani.md LANG INDEX TARGET EXPECTED_SHA256 OLD_SHA256_OR_NONE <<'EOF'
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

### Görev 1: Eş araması yalnız adaylarda

**Files:**
- Modify: `macos/Tests/DiscordAccessKitTests/ProcessInspectorTests.swift` (tam dosya; eski SHA-256 `ca8b9552be0e458f3b0652d3ee2d5dc9ccfbabfc88d31130bc7bda93f2a2e5f3`)
- Modify: `macos/Tests/DiscordAccessKitTests/PeerAdmissionTests.swift` (tam dosya; eski SHA-256 `032fcb9beed620a78dac60d35a3fd9ad772929929b49a09dff683359f61a38a2`)
- Modify: `macos/Sources/DiscordAccessKit/System/ProcessInspector.swift` (tam dosya; eski SHA-256 `89e91d6afc0e289a20b94d272fcef973d523ed6cb038da510ef0df49e6bdef32`)
- Modify: `macos/Sources/DiscordAccessKit/Gate/PeerAdmission.swift` (tam dosya; eski SHA-256 `5f4f75a9c085cfd954e4109653ca6793df8dd6f3461c7b4b375973aa675d3d53`)

Kapı testleri, 1b'deki eş aramasının başka süreçlerin soketlerini bozabildiğini gösterdi:
- Bir tanıtıcıyı `proc_pidfdinfo` ile incelemek ona geçici bir referans alır. Sahibi tanıtıcıyı tam o sırada kapatırsa çekirdek soketi boşaltır (drain); o soketi paylaşan her süreçte okumalar kalıcı olarak `EBADF` ile biter.
- Doğmakta olan bir alt süreç `exec` anına kadar ebeveyninin bütün tanıtıcılarının kopyasını tutar ve `exec`'te kapatır.
- `loopbackConnectionHolders` kullanıcının bütün süreçlerini taradığı için bu kopyalara da bakıyordu. Tarama ve alt süreç başlatma birlikteyken 16 bloklu okumanın 2-8'i `EBADF` ile bitti.

Kullanıcı, aramanın yalnız Discord süreçlerinde yapılmasını seçti. 1b'deki "bağlantıyı tutan her süreç kabul edilmeli" kuralı da kalkar: ucu tutan aday kabul edilmelidir. Windows da `TcpOwner.Find`'ın bulduğu tek sahibi denetler.

- [ ] **Adım 1: Süreç denetçisi testlerini güncelle** (`swift` bloğu 0; yardımcıyla, eski hash verilerek)

- `findsEveryHolderOfALoopbackConnection` yerine `tellsWhetherAProcessHoldsALoopbackConnection` gelir: artık tek bir sürecin bağlantıyı tutup tutmadığı sorulur. Soketi paylaşan alt süreç de bağlantıyı tutar; launchd'nin tanıtıcıları okunamaz.
- Yeni `inspectingProcessesLeavesSocketsOfSpawningProcessesIntact`: bu sürecin 40 bağlantısında bloklu okumalar 2,5 sn bekler. Bu sırada üç iş parçacığı alt süreç başlatır, üçü de bu sürecin alt süreçlerini inceler. Hiçbir okuma erken bitmemelidir. Test yalnız bu sürecin alt süreçlerine bakar. `exec` süzgeci kaldırıldığında her denemede başarısız oldu.

```swift
import Darwin
import Foundation
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

    @Test func tellsWhetherAProcessHoldsALoopbackConnection() throws {
        let listener = try TCPListener()
        let client = try LoopbackClient(port: listener.port)
        let accepted = try listener.acceptClient()
        defer { close(accepted.descriptor) }
        #expect(accepted.clientPort == client.localPort)
        #expect(ProcessInspector.holdsLoopbackConnection(pid: getpid(), localPort: client.localPort, remotePort: listener.port) == true)
        #expect(ProcessInspector.holdsLoopbackConnection(pid: getpid(), localPort: listener.port, remotePort: client.localPort) == true)
        #expect(ProcessInspector.holdsLoopbackConnection(pid: getpid(), localPort: listener.port, remotePort: listener.port) == false)
        // A child that inherits the client's descriptor holds the same connection; launchd's descriptors cannot be read.
        let child = try spawnSharing(client.descriptor, executable: "/bin/sleep", arguments: ["30"])
        defer { reap(child) }
        #expect(waitFor { ProcessInspector.holdsLoopbackConnection(pid: child, localPort: client.localPort, remotePort: listener.port) == true ? true : nil } == true)
        #expect(ProcessInspector.holdsLoopbackConnection(pid: 1, localPort: client.localPort, remotePort: listener.port) != true)
    }

    /// A child being spawned holds copies of its parent's descriptors until exec closes them. Inspecting such a copy at
    /// that moment made the kernel drain the socket, and blocked reads on it failed with EBADF for good. Here the children
    /// of this process (and no other process) are inspected over and over while children are spawned and reads wait.
    @Test func inspectingProcessesLeavesSocketsOfSpawningProcessesIntact() throws {
        let listener = try TCPListener()
        var clients: [LoopbackClient] = []
        var accepted: [Int32] = []
        defer { accepted.forEach { close($0) } }
        for _ in 0..<40 {
            let client = try LoopbackClient(port: listener.port)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            clients.append(client)
            accepted.append(try listener.acceptClient().descriptor)
        }
        let lock = NSLock()
        var running = true
        var failures: [Int32] = []
        let readers = DispatchGroup()
        for descriptor in clients.map(\.descriptor) {
            readers.enter()
            Thread {
                var byte: UInt8 = 0
                // Only the receive timeout may end the read: data or an end of stream is recorded as 0, an error as its errno.
                let count = read(descriptor, &byte, 1)
                let error = count < 0 ? errno : 0
                lock.lock()
                if error != EAGAIN { failures.append(error) }
                lock.unlock()
                readers.leave()
            }.start()
        }
        func keepRunning() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }
        let workers = DispatchGroup()
        for _ in 0..<3 {
            workers.enter()
            Thread {
                while keepRunning() {
                    for pid in ProcessInspector.userProcessIDs() where ProcessInspector.record(for: pid)?.parentPid == getpid() {
                        _ = ProcessInspector.tcpSockets(of: pid)
                    }
                }
                workers.leave()
            }.start()
            workers.enter()
            Thread {
                while keepRunning() {
                    if let child = try? startChild("/bin/sleep", ["0"]) { child.waitUntilExit() } else { usleep(10_000) }
                }
                workers.leave()
            }.start()
        }
        usleep(2_500_000)
        lock.lock()
        running = false
        lock.unlock()
        workers.wait()
        readers.wait()
        #expect(failures.isEmpty, "reads ended early: \(failures)")
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

- [ ] **Adım 2: Eş kabulü testlerini güncelle** (`swift` bloğu 1; yardımcıyla, eski hash verilerek)

- Retler nedenleriyle beklenir: `refusal(clientPort:gatePort:)` ve `requirement(for:)` artık `PeerAdmission.Refusal` döndürür.
- `refusesOtherExecutablesAndWrongRequirements`: onaylı bir dosyayı çalıştırmayan istemciye hiç bakılmaz; ret nedeni `NoHolder` olur.
- `requiresEveryHolderOfTheConnection` yerine `ignoresAnUnapprovedChildThatSharesTheClientSocket` gelir. Soketi paylaşan, onaylı olmayan bir alt süreç sonucu değiştirmez; ucu bu süreç de tuttuğu için karar tanı iznine kalır. Böyle bir sürece hiç bakılmadığını `refusesOtherExecutablesAndWrongRequirements` gösterir.
- Yeni `refusesAConnectionNoCandidateHoldsAtOnce`: hiçbir adayın tutmadığı bağlantı yeniden denenmeden reddedilir. Beş retten en hızlısı 25 ms'den kısa sürmelidir; yeniden denemeler 30 ms sürerdi.
- Yeni `namesRefusalsSafelyForDiagnostics`: ret adları ve tanı satırına güvenle yazılan dosya adı.
- Eksik onaylı dosya `unsafePath` yerine `missingExecutable` hatası verir; başka bir `realpath` hatası (ör. `ENOTDIR`) `unsafePath` olarak kalır.
- `eventuallyPermits` yardımcısı kalkar: doğmakta olan süreçlere artık bakılmadığı için beklemek gerekmez.

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

    static func record(uid: uid_t = getuid(), start: UInt64, path: String = "/usr/bin/nc") -> ProcessInspector.Record {
        ProcessInspector.Record(pid: 4242, parentPid: 1, uid: uid, startSeconds: start / 1_000_000, startMicroseconds: start % 1_000_000, path: path)
    }

    @Test func checksUserStartTimeAndExecutable() throws {
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date(timeIntervalSince1970: 1_800_000_000.25))
        let ready: UInt64 = 1_800_000_000_250_000
        let approved = Result<String, PeerAdmission.Refusal>.success(Self.netcat.requirement)
        #expect(admission.requirement(for: Self.record(start: ready)) == approved)
        #expect(admission.requirement(for: Self.record(start: ready + 1)) == approved)
        #expect(admission.requirement(for: Self.record(start: ready - 1)) == .failure(.startedBeforeReady))
        #expect(admission.requirement(for: Self.record(start: 0)) == .failure(.startedBeforeReady))
        #expect(admission.requirement(for: Self.record(uid: getuid() &+ 1, start: ready)) == .failure(.otherUser))
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/bin/curl")) == .failure(.unapprovedExecutable("curl")))
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/bin/../bin/nc")) == approved)
        // On a case-insensitive volume the process path may differ from the approved one in letter case only.
        #expect(admission.requirement(for: Self.record(start: ready, path: "/usr/BIN/nc")) ==
            (FileManager.default.fileExists(atPath: "/usr/BIN/nc") ? approved : .failure(.unapprovedExecutable("nc"))))
    }

    @Test func refusesUnsafeConfiguration() throws {
        #expect(throws: PeerAdmission.ConfigurationError.noExecutables) { try PeerAdmission(approved: [], readyTime: Date()) }
        #expect(throws: PeerAdmission.ConfigurationError.tooManyExecutables) {
            try PeerAdmission(approved: Array(repeating: Self.netcat, count: 17), readyTime: Date())
        }
        #expect(throws: Never.self) { try PeerAdmission(approved: Array(repeating: Self.netcat, count: 16), readyTime: Date()) }
        for path in ["usr/bin/nc", "/usr/bin/../bin/nc", "/tmp", "/usr/bin/nc/fixture"] {
            #expect(throws: PeerAdmission.ConfigurationError.unsafePath(path)) {
                try PeerAdmission(approved: [ApprovedExecutable(path: path, requirement: "anchor apple")], readyTime: Date())
            }
        }
        #expect(throws: PeerAdmission.ConfigurationError.missingExecutable("/usr/bin/missing-fixture")) {
            try PeerAdmission(approved: [ApprovedExecutable(path: "/usr/bin/missing-fixture", requirement: "anchor apple")], readyTime: Date())
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
        #expect(admission.refusal(pid: client.process.processIdentifier) == .unknownProcess)
        #expect(!admission.anyAdmittedRunning)
        // Nothing holds the client end any more; an empty set of holders is never admitted.
        #expect(admission.refusal(clientPort: client.clientPort, gatePort: gate.port) == .noHolder)
    }

    /// A process whose parent exits moves to launchd. It is still the same admitted instance and still counts as running.
    @Test func keepsAnAdmittedClientWhoseParentExits() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let launcher = try startChild("/bin/sh", ["-c", "/usr/bin/nc -d 127.0.0.1 \"$0\" & wait", String(gate.port)])
        defer { Self.stop(launcher) }
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        let client = try #require(waitFor {
            ProcessInspector.userProcessIDs().compactMap(ProcessInspector.record(for:)).first { $0.parentPid == launcher.processIdentifier && $0.path == "/usr/bin/nc" }?.pid
        })
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
        #expect(admission.refusal(clientPort: client.clientPort, gatePort: gate.port) == .startedBeforeReady)
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
        // A client that runs no approved executable is not even looked at.
        #expect(try PeerAdmission(approved: [Self.sleeper], readyTime: ready).refusal(clientPort: client.clientPort, gatePort: gate.port) == .noHolder)
        for requirement in requirements {
            let impostor = ApprovedExecutable(path: "/usr/bin/nc", requirement: requirement)
            #expect(try PeerAdmission(approved: [impostor], readyTime: ready).refusal(clientPort: client.clientPort, gatePort: gate.port) ==
                .requirementNotMet)
        }
        #expect((try PeerAdmission(approved: [Self.sleeper, Self.netcat], readyTime: ready)).permits(clientPort: client.clientPort, gatePort: gate.port))
    }

    /// A connection that no candidate holds is refused without retries, so that each connection of another local user
    /// cannot hold a gate slot through three 10 ms pauses. The fastest of five refusals is measured.
    @Test func refusesAConnectionNoCandidateHoldsAtOnce() throws {
        let gate = try TCPListener()
        let client = try Self.connectNetcat(to: gate)
        defer {
            close(client.accepted)
            Self.stop(client.process)
        }
        let admission = try PeerAdmission(approved: [Self.sleeper], readyTime: Date())
        let durations = (0..<5).map { _ -> TimeInterval in
            let started = Date()
            #expect(admission.refusal(clientPort: client.clientPort, gatePort: gate.port) == .noHolder)
            return Date().timeIntervalSince(started)
        }
        let fastest = try #require(durations.min())
        #expect(fastest < 0.025)
    }

    @Test func admitsItselfOnlyWithDiagnosticPermission() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let client = try LoopbackClient(port: gate.port)
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        #expect(admission.refusal(clientPort: client.localPort, gatePort: gate.port) == .diagnosticNotAllowed)
        admission.diagnosticAllowed = true
        #expect(admission.permits(clientPort: client.localPort, gatePort: gate.port))
        admission.diagnosticAllowed = false
        #expect(!admission.permits(clientPort: client.localPort, gatePort: gate.port))
    }

    /// A child running an executable that is not approved and shares the client's socket does not matter (1b refused
    /// every connection such a child also held): this process holds the socket too and is decided by `diagnosticAllowed`.
    /// That such a child is not even inspected shows in `refusesOtherExecutablesAndWrongRequirements`.
    @Test func ignoresAnUnapprovedChildThatSharesTheClientSocket() throws {
        let gate = try TCPListener()
        let admission = try PeerAdmission(approved: [Self.netcat], readyTime: Date())
        let client = try LoopbackClient(port: gate.port)
        let accepted = try gate.acceptClient()
        defer { close(accepted.descriptor) }
        let child = try spawnSharing(client.descriptor, executable: "/bin/sleep", arguments: ["30"])
        defer { reap(child) }
        #expect(admission.refusal(clientPort: client.localPort, gatePort: gate.port) == .diagnosticNotAllowed)
        admission.diagnosticAllowed = true
        #expect(admission.permits(clientPort: client.localPort, gatePort: gate.port))
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
        #expect(admission.refusal(clientPort: second.clientPort, gatePort: gate.port) == .capacity)
        admission.close()
        #expect(admission.refusal(clientPort: first.clientPort, gatePort: gate.port) == .closed)
        #expect(!admission.anyAdmittedRunning)
        #expect(!admission.permits(pid: 0))
        #expect(!admission.permits(pid: -1))
    }

    @Test func namesRefusalsSafelyForDiagnostics() {
        let names = [PeerAdmission.Refusal.closed, .unreadable, .noHolder, .holdersChanged, .diagnosticNotAllowed, .unknownProcess, .otherUser,
                     .startedBeforeReady, .requirementNotMet, .capacity].map(\.diagnostic)
        #expect(names == ["Closed", "Unreadable", "NoHolder", "HoldersChanged", "DiagnosticNotAllowed", "UnknownProcess", "OtherUser",
                          "StartedBeforeReady", "RequirementNotMet", "Capacity"])
        #expect(PeerAdmission.Refusal.unapprovedExecutable("Discord Helper (Foo)").diagnostic == "UnapprovedExecutable executable=Discord_Helper_(Foo)")
        #expect(PeerAdmission.Refusal.unapprovedExecutable("a\r\nb=c\u{1F600}\u{E9}").diagnostic == "UnapprovedExecutable executable=a__b_c__")
        #expect(PeerAdmission.Refusal.unapprovedExecutable(String(repeating: "x", count: 100)).diagnostic ==
            "UnapprovedExecutable executable=" + String(repeating: "x", count: 64))
    }
}
```

- [ ] **Adım 3: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `type 'ProcessInspector' has no member 'holdsLoopbackConnection'`. Derleme işlerinin sırasına göre `PeerAdmissionTests.swift`'in hataları da görülebilir: `value of type 'PeerAdmission' has no member 'refusal'`, `type 'PeerAdmission' has no member 'Refusal'`, `type 'PeerAdmission.ConfigurationError' has no member 'missingExecutable'` ve bunlara bağlı tür hataları. Bu Mac'teki beş denemede yalnız `holdsLoopbackConnection` hatası göründü.

- [ ] **Adım 4: Süreç denetçisini güncelle** (`swift` bloğu 2; yardımcıyla, eski hash verilerek)

Değişiklikler:
- `loopbackConnectionHolders` kalkar. `holdsLoopbackConnection(pid:localPort:remotePort:)` yalnız sorulan sürecin tanıtıcılarına bakar; liste eksiksiz okunamazsa `nil` döner.
- `exec`'i bitmemiş (`PROC_FLAG_EXEC` yok) ya da çıkmakta olan (`PROC_FLAG_INEXIT`) bir sürecin tanıtıcıları incelenmez; böyle bir süreç soket tutmuyor sayılır. XNU'da `exec_mach_imgact`, kopyaları kapatan `fdt_exec`'i `P_EXEC`'ten önce çalıştırır.
- Okumadan sonra süreç yeniden okunur. Bu arada çıkmaya başladıysa ya da PID başka bir sürece geçtiyse sonuç boştur.

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

    /// Whether `pid` holds the loopback TCP connection it sees as 127.0.0.1:`localPort` to 127.0.0.1:`remotePort`
    /// (Windows `TcpOwner.Find` answers the same question for the owner it finds). Nil when its descriptors could not
    /// be read completely. Only processes a caller already has reason to trust are asked about: see `tcpSockets(of:)`.
    public static func holdsLoopbackConnection(pid: pid_t, localPort: UInt16, remotePort: UInt16) -> Bool? {
        tcpSockets(of: pid)?.contains { $0.established && $0.localLoopback && $0.localPort == localPort && $0.remoteLoopback && $0.remotePort == remotePort }
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

    /// The IPv4 TCP sockets of `pid` ([] once it has exited or cannot be read at all), or nil when its descriptors could
    /// not be read completely.
    ///
    /// Inspecting a descriptor holds a reference to it. If its process closes it meanwhile, the kernel drains the socket,
    /// and from then on reads fail with EBADF in every process that shares the socket. A child being spawned holds copies
    /// of all its parent's descriptors and closes them when it executes, so inspecting it can break its parent's
    /// connections; scanning every process of the user did break other processes' sockets in tests. A process that has
    /// not finished exec, or is exiting, is therefore never inspected and counts as holding no socket.
    static func tcpSockets(of pid: pid_t) -> [TCPSocket]? {
        guard let before = inspectable(pid) else { return [] }
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
        // A process that began to exit meanwhile, or a pid that now names another process, holds nothing for this answer.
        guard let after = inspectable(pid), after.pbi_start_tvsec == before.pbi_start_tvsec, after.pbi_start_tvusec == before.pbi_start_tvusec else {
            return []
        }
        return sockets
    }

    /// The process when its descriptors may be inspected: it has finished exec, which closes the copies a spawned child
    /// holds (XNU `exec_mach_imgact` calls `fdt_exec` before it sets `P_EXEC`), and it is not exiting.
    private static func inspectable(_ pid: pid_t) -> proc_bsdinfo? {
        guard let info = bsdInfo(of: pid), info.pbi_flags & UInt32(PROC_FLAG_EXEC) != 0, info.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0 else {
            return nil
        }
        return info
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

- [ ] **Adım 5: Eş kabulünü güncelle** (`swift` bloğu 3; yardımcıyla, eski hash verilerek)

Akış:
1. Adaylar bu süreç ve bu kullanıcının onaylı bir dosyayı çalıştıran süreçleridir: dosya adı büyük-küçük harf ayırmadan, gerçek yolu tam olarak karşılaştırılır. Dosya adı dosya sistemine sorulmadan alınır; `URL(fileURLWithPath:)` yolu dosya sisteminde arar ve yanıt vermeyen bir ağ diskinden çalışan tek bir süreç her bağlantıyı bekletebilirdi. Ucu tutan ilk aday kabul ölçütlerinden geçmelidir. Hiçbir aday tutmuyorsa bağlantı hemen `NoHolder` ile reddedilir.
2. Geçebilecek retler 10 ms arayla üç kez yeniden denenir; son neden döner. Bunlar: eksik liste (`Unreadable`), değişen ya da okunamayan süreç (`UnknownProcess`), imza denetimi (`RequirementNotMet`) ve denetim sırasında ucu bırakan süreç (`HoldersChanged`).
3. Denetimlerden sonra ucun hâlâ aynı süreçte olduğu doğrulanır. Ardından `close()` ve tanı izni kilit altında yeniden okunur.
4. Kabul ölçütleri ve süreç örneği başına hatırlama 1b'deki gibidir.
5. Onaylı dosya yoksa (`ENOENT`) yapılandırma `missingExecutable` hatası verir.

`HoldersChanged` ve `Unreadable` testle oluşturulamaz; `ProcessInspector` statik olduğu için bu yollar incelemeyle doğrulandı.

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
/// The client end of a connection is looked for only in this process and in processes running an approved executable,
/// and the process found there must be admitted (Windows likewise checks the one owner `TcpOwner.Find` reports). No
/// other process is inspected (see `ProcessInspector.tcpSockets`). A process is admitted when it runs an approved
/// executable for this user, started at or after `readyTime`, and its running code satisfies the executable's
/// requirement; this process itself is admitted only while `diagnosticAllowed` is set. Admissions are remembered per
/// process instance (pid, start time and path), at most `capacity` at a time; refusals are not remembered.
public final class PeerAdmission {
    public enum ConfigurationError: Error, Equatable {
        case noExecutables
        case tooManyExecutables
        case unsafePath(String)
        case missingExecutable(String)
    }

    /// Why a connection or process was refused; the gate writes `diagnostic` to its diagnostic lines.
    public enum Refusal: Error, Equatable, Sendable {
        case closed
        /// A process or descriptor list could not be read completely.
        case unreadable
        /// Neither this process nor a process running an approved executable holds the client end.
        case noHolder
        /// The process holding the connection let go of it during the checks.
        case holdersChanged
        /// This process, while `diagnosticAllowed` is off.
        case diagnosticNotAllowed
        /// The process could not be read, or it was not the same process after the checks.
        case unknownProcess
        case otherUser
        case startedBeforeReady
        /// The file name of the executable that is not approved.
        case unapprovedExecutable(String)
        case requirementNotMet
        case capacity

        /// The name of the refusal; for an unapproved executable also its file name, reduced to letters, digits and
        /// `._()-` (anything else becomes `_`) and to 64 characters.
        public var diagnostic: String {
            switch self {
            case .closed: return "Closed"
            case .unreadable: return "Unreadable"
            case .noHolder: return "NoHolder"
            case .holdersChanged: return "HoldersChanged"
            case .diagnosticNotAllowed: return "DiagnosticNotAllowed"
            case .unknownProcess: return "UnknownProcess"
            case .otherUser: return "OtherUser"
            case .startedBeforeReady: return "StartedBeforeReady"
            case .requirementNotMet: return "RequirementNotMet"
            case .capacity: return "Capacity"
            case .unapprovedExecutable(let name):
                let safe = name.unicodeScalars.prefix(64).map { scalar -> Character in
                    scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._()-".unicodeScalars.contains(scalar)) ? Character(scalar) : "_"
                }
                return "UnapprovedExecutable executable=" + String(safe)
            }
        }
    }

    public static let maxExecutables = 16
    private let approved: [String: String]
    /// The file names of the approved executables in lower case: a cheap first test before a process path is resolved.
    private let approvedNames: Set<String>
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
        for executable in executables {
            guard executable.path.hasPrefix("/") else { throw ConfigurationError.unsafePath(executable.path) }
            guard let resolved = realpath(executable.path, nil) else {
                throw errno == ENOENT ? ConfigurationError.missingExecutable(executable.path) : ConfigurationError.unsafePath(executable.path)
            }
            defer { free(resolved) }
            guard String(cString: resolved) == executable.path else { throw ConfigurationError.unsafePath(executable.path) }
        }
        approved = Dictionary(executables.map { ($0.path, $0.requirement) }, uniquingKeysWith: { first, _ in first })
        approvedNames = Set(executables.map { fileName($0.path).lowercased() })
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
    public func permits(clientPort: UInt16, gatePort: UInt16) -> Bool {
        refusal(clientPort: clientPort, gatePort: gatePort) == nil
    }

    /// Why the connection whose client end is 127.0.0.1:`clientPort` to 127.0.0.1:`gatePort` may not use the gate, or
    /// nil when it may. Refusals that can pass (an incomplete list, a process that changed during the checks, a failed
    /// signature check) are retried three times, 10 ms apart, as Windows `FindPeer` retries; the last reason counts.
    /// A connection no candidate holds is refused at once: looking again would not change that, and connections of
    /// another local user would otherwise each hold a gate slot for the retries.
    public func refusal(clientPort: UInt16, gatePort: UInt16) -> Refusal? {
        var last = Refusal.noHolder
        for attempt in 0..<4 {
            if attempt > 0 { usleep(10_000) }
            let holder: pid_t
            switch self.holder(clientPort: clientPort, gatePort: gatePort) {
            case .failure(let refusal):
                last = refusal
                continue
            case .success(nil):
                return .noHolder
            case .success(let pid?):
                holder = pid
            }
            if let refused = refusal(pid: holder) {
                guard refused == .unknownProcess || refused == .requirementNotMet else { return refused }
                last = refused
                continue
            }
            // The connection must still be held by the process that was checked.
            switch ProcessInspector.holdsLoopbackConnection(pid: holder, localPort: clientPort, remotePort: gatePort) {
            case true?: break
            case false?:
                last = .holdersChanged
                continue
            case nil:
                last = .unreadable
                continue
            }
            // `close()` or the diagnostic permission may have changed meanwhile.
            lock.lock()
            let revoked: Refusal? = closed ? .closed : holder == getpid() && !diagnostic ? .diagnosticNotAllowed : nil
            lock.unlock()
            return revoked
        }
        return last
    }

    /// The process holding the client end, looked for in this process first and then in the processes of this user that
    /// run an approved executable; nil when none of them holds it.
    private func holder(clientPort: UInt16, gatePort: UInt16) -> Result<pid_t?, Refusal> {
        guard let pids = ProcessInspector.completeUserProcessIDs(uid: uid) else { return .failure(.unreadable) }
        let candidates = [getpid()] + pids.filter { pid in
            guard pid != getpid(), let record = ProcessInspector.record(for: pid),
                  approvedNames.contains(fileName(record.path).lowercased()) else { return false }
            return approved[canonicalPath(record.path) ?? ""] != nil
        }
        var unreadable = false
        for pid in candidates {
            switch ProcessInspector.holdsLoopbackConnection(pid: pid, localPort: clientPort, remotePort: gatePort) {
            case true?: return .success(pid)
            case false?: continue
            case nil: unreadable = true
            }
        }
        return unreadable ? .failure(.unreadable) : .success(nil)
    }

    /// Whether `pid` is admitted: this process only through `diagnosticAllowed`, any other through its checks.
    public func permits(pid: pid_t) -> Bool {
        refusal(pid: pid) == nil
    }

    /// Why `pid` is not admitted, or nil when it is.
    public func refusal(pid: pid_t) -> Refusal? {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return .closed
        }
        guard pid > 0 else {
            lock.unlock()
            return .unknownProcess
        }
        if pid == getpid() {
            let allowed = diagnostic
            lock.unlock()
            return allowed ? nil : .diagnosticNotAllowed
        }
        pruneGone()
        if let known = admitted[pid] {
            defer { lock.unlock() }
            // Kept as running or as unreadable: only a readable instance that still meets the checks is admitted.
            guard let current = ProcessInspector.record(for: pid), Self.sameInstance(current, known) else { return .unknownProcess }
            if case .failure(let refusal) = requirement(for: current) { return refusal }
            return nil
        }
        let full = admitted.count >= capacity
        lock.unlock()
        guard !full else { return .capacity }
        // The signature check runs without the lock, so a slow one does not hold up processes admitted before.
        guard let before = ProcessInspector.record(for: pid) else { return .unknownProcess }
        let requirement: String
        switch self.requirement(for: before) {
        case .success(let value): requirement = value
        case .failure(let refusal): return refusal
        }
        guard ProcessInspector.satisfies(pid: pid, requirement: requirement) else { return .requirementNotMet }
        guard let after = ProcessInspector.record(for: pid), Self.sameInstance(after, before) else { return .unknownProcess }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return .closed }
        guard admitted.count < capacity || admitted[pid] != nil else { return .capacity }
        admitted[pid] = before
        return nil
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

    /// The requirement of the approved executable `record` runs, or why the record is refused: it must be this user's,
    /// started at or after readiness.
    func requirement(for record: ProcessInspector.Record) -> Result<String, Refusal> {
        guard record.uid == uid else { return .failure(.otherUser) }
        guard record.startSeconds > 0, record.startSeconds * 1_000_000 + record.startMicroseconds >= readyMicroseconds else {
            return .failure(.startedBeforeReady)
        }
        guard let requirement = approved[canonicalPath(record.path) ?? ""] else {
            return .failure(.unapprovedExecutable(fileName(record.path)))
        }
        return .success(requirement)
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

/// The last component of `path`, without touching the file system. `URL(fileURLWithPath:)` would look the path up; the
/// candidate search does this for every process of the user on each connection, and one may run from an unresponsive
/// network volume.
private func fileName(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// The real path (links resolved, letter case as on disk), or nil when it does not exist.
private func canonicalPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
```

- [ ] **Adım 6: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 50 tests in 9 suites passed`, uyarısız ve `skipped` olmadan. `inspectingProcessesLeavesSocketsOfSpawningProcessesIntact` geçer. Ardından `pgrep -fl "nc -d|sleep 30"` hiçbir şey yazmaz.

---

### Görev 2: Tanı satırları

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/GateDiagnosticsTests.swift`, `macos/Sources/DiscordAccessKit/Gate/GateDiagnostics.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 4)

Vektörler Windows'taki `ProxyDiagnosticsChecks.cs` dosyasından alınmıştır. Bir satırda yalnız aşama, doğrulanmış ana bilgisayar ve port, sabit bir kategori ve Windows'un adlandırdığı bir soket hatası bulunur; `PRIVATE_FIXTURE` hiçbir satırda geçmez. Windows'ta adı olmayan bir hata sayı olarak da yazılmaz. Windows vektörlerine eklenenler: yolda ters bölü, yüzde kodlu ya da ASCII dışı ana bilgisayar, ret nedeninin süzülmesi ve hata satırlarının başarı kotasını tüketmemesi.

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows `ProxyDiagnosticsChecks.cs`. Every line keeps to the stage, a validated host and port and a
/// fixed category, so `PRIVATE_FIXTURE` must never appear.
@Suite struct GateDiagnosticsTests {
    @Test func namesTheTargetOfAChromiumConnect() throws {
        let chromium = "CONNECT gateway.discord.gg:443 HTTP/1.1\r\nHost: gateway.discord.gg:443\r\nProxy-Connection: keep-alive\r\n" +
            "User-Agent: Mozilla/5.0 Chrome/138.0.0.0 Electron/37.0.0\r\n\r\n"
        #expect(try RequestPolicy.rewrite(chromium, authorization: "Basic fixture-only").hasPrefix("CONNECT gateway.discord.gg:443 HTTP/1.1\r\n"))
        #expect(GateDiagnostics.safeTarget(chromium) == "gateway.discord.gg:443")
    }

    @Test(arguments: [
        ("CONNECT telemetry.example.invalid:443 HTTP/1.1\r\nHost: telemetry.example.invalid:443\r\nAuthorization: Bearer PRIVATE_FIXTURE\r\n\r\n",
         RequestFailure.forbiddenHost, "telemetry.example.invalid:443"),
        ("CONNECT discord.com:444 HTTP/1.1\r\nHost: discord.com:444\r\n\r\n", .invalidTarget, "discord.com:444"),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: conflict.example.invalid\r\n\r\n", .conflictingHost, "discord.com:443"),
        ("GET http://discord.com/PRIVATE_FIXTURE?token=PRIVATE_FIXTURE HTTP/1.1\r\nHost: discord.com\r\nBad(Name): PRIVATE_FIXTURE\r\n\r\n",
         .invalidHeader, "discord.com:80"),
        ("GET http://PRIVATE_FIXTURE@discord.com/private HTTP/1.1\r\nHost: discord.com\r\n\r\n", .invalidTarget, "unknown"),
        ("CONNECT discord.com:443/PRIVATE_FIXTURE HTTP/1.1\r\n\r\n", .invalidTarget, "unknown"),
        ("GET /PRIVATE_FIXTURE?token=PRIVATE_FIXTURE HTTP/1.1\r\nHost: discord.com\r\n\r\n", .invalidTarget, "unknown"),
    ])
    func logsARefusalWithItsCategoryAndASafeTarget(request: String, refusal: RequestFailure, target: String) {
        #expect(throws: refusal) { try RequestPolicy.rewrite(request, authorization: "Basic fixture-only") }
        #expect(GateDiagnostics.safeTarget(request) == target)
        let line = GateDiagnostics.failure(stage: .requestPolicy, target: GateDiagnostics.safeTarget(request), error: .refused(refusal))
        #expect(line == "Failure stage=RequestPolicy target=" + target + " category=" + refusal.rawValue)
    }

    @Test(arguments: [
        "CONNECT discord.com:443\r\nPRIVATE_FIXTURE HTTP/1.1\r\n\r\n", "CONNECT 127.0.0.1:443 HTTP/1.1\r\n\r\n",
        "CONNECT bad..discord.com:443 HTTP/1.1\r\n\r\n", "", "CONNECT discord.com:443 HTTP/1.1", "GET http://[::1]/ HTTP/1.1\r\n\r\n",
        "GET http://discord.com\\@example.com/ HTTP/1.1\r\n\r\n", "GET https://discord.com/ HTTP/1.1\r\n\r\n",
        "CONNECT discord.com:0 HTTP/1.1\r\n\r\n", "CONNECT discord.com:65536 HTTP/1.1\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\n" + String(repeating: "a", count: 32_768) + "\r\n\r\n",
        // Not in the Windows vectors: a backslash in the path (Windows refuses any backslash too), an encoded or non-ASCII host.
        "GET http://discord.com/a\\b HTTP/1.1\r\n\r\n", "GET http://discord%2Ecom/ HTTP/1.1\r\n\r\n", "CONNECT disc\u{F6}rd.com:443 HTTP/1.1\r\n\r\n",
    ])
    func hidesTargetsThatAreNotAPlainHostAndPort(header: String) {
        #expect(GateDiagnostics.safeTarget(header) == "unknown")
    }

    @Test func keepsHostsInLowerCaseWithTheDefaultOrGivenPort() {
        #expect(GateDiagnostics.safeTarget("GET HTTP://Discord.COM HTTP/1.1\r\n\r\n") == "discord.com:80")
        #expect(GateDiagnostics.safeTarget("GET http://cdn.discordapp.com:8080/a?b#c HTTP/1.1\r\n\r\n") == "cdn.discordapp.com:8080")
        #expect(GateDiagnostics.safeTarget("CONNECT C-WAW04.Discord.Media:02087 HTTP/1.1\r\n\r\n") == "c-waw04.discord.media:2087")
    }

    @Test func namesOnlyTheCategoryAndAKnownSocketError() {
        #expect(GateDiagnostics.failure(stage: .backendConnect, target: "discord.com:443", error: .io(nil)) ==
            "Failure stage=BackendConnect target=discord.com:443 category=IO")
        #expect(GateDiagnostics.failure(stage: .relay, target: "discord.com:443\r\nPRIVATE_FIXTURE", error: .unexpected) ==
            "Failure stage=Relay target=unknown category=Unexpected")
        #expect(GateDiagnostics.failure(stage: .backendConnect, target: "discord.com:443", error: .socket(ECONNREFUSED)) ==
            "Failure stage=BackendConnect target=discord.com:443 category=Socket socket=ConnectionRefused")
        #expect(GateDiagnostics.failure(stage: .relay, target: "discord.com:443", error: .io(ECONNRESET)) ==
            "Failure stage=Relay target=discord.com:443 category=IO socket=ConnectionReset")
        #expect(GateDiagnostics.failure(stage: .headerRead, target: "unknown", error: .timeout) ==
            "Failure stage=HeaderRead target=unknown category=Timeout")
        #expect(GateDiagnostics.failure(stage: .backendIdentity, target: "discord.com:443", error: .invalidData) ==
            "Failure stage=BackendIdentity target=discord.com:443 category=InvalidData")
        // An error Windows has no name for is never written as a number.
        #expect(GateDiagnostics.failure(stage: .relay, target: "discord.com:443", error: .io(ENOENT)) ==
            "Failure stage=Relay target=discord.com:443 category=IO")
        #expect(!GateDiagnostics.failure(stage: .backendConnect, target: "discord.com:443", error: .socket(Int32.max)).contains(" socket="))
        #expect(GateDiagnostics.unownedClient(reason: "NoHolder") == "Failure stage=Ownership target=unknown category=UnownedClient reason=NoHolder")
        #expect(GateDiagnostics.unownedClient(reason: PeerAdmission.Refusal.unapprovedExecutable("Discord Helper (GPU)").diagnostic) ==
            "Failure stage=Ownership target=unknown category=UnownedClient reason=UnapprovedExecutable executable=Discord_Helper_(GPU)")
        // A reason can never start another line, whoever passes it.
        let hostile = "NoHolder\r\nFailure stage=Relay \u{E9}" + String(repeating: "x", count: 200)
        #expect(GateDiagnostics.unownedClient(reason: hostile) ==
            "Failure stage=Ownership target=unknown category=UnownedClient reason=NoHolder__Failure stage=Relay _" + String(repeating: "x", count: 65))
        #expect(GateDiagnostics.capacityFailure == "Failure stage=Admission target=unknown category=Capacity")
    }

    @Test func addsTheFailedDirectionAndAClampedDurationToRelayFailures() {
        for direction in [RelayDirection.clientToEngine, .engineToClient] {
            #expect(GateDiagnostics.relayFailure(target: "discord.com:443", error: .io(ECONNRESET), direction: direction, elapsedMilliseconds: 24) ==
                "Failure stage=Relay target=discord.com:443 category=IO socket=ConnectionReset direction=" + direction.rawValue + " elapsed_ms=24")
        }
        #expect(GateDiagnostics.relayFailure(target: "discord.com:443/PRIVATE_FIXTURE", error: .io(nil), direction: nil, elapsedMilliseconds: -1) ==
            "Failure stage=Relay target=unknown category=IO direction=unknown elapsed_ms=0")
        #expect(GateDiagnostics.relayFailure(target: "discord.com:443", error: .timeout, direction: nil, elapsedMilliseconds: .max)
            .hasSuffix("direction=unknown elapsed_ms=86400000"))
        #expect(GateDiagnostics.relayFailure(target: "discord.com:443", error: .timeout, direction: nil, elapsedMilliseconds: .min)
            .hasSuffix("direction=unknown elapsed_ms=0"))
    }

    @Test func boundsSuccessAndFailureLinesSeparatelyPerMinute() {
        let budget = TraceBudget()
        let instant = Date(timeIntervalSince1970: 1_767_225_600)
        #expect((0..<100).filter { _ in budget.admit(failure: false, now: instant) }.count == TraceBudget.successLimit)
        #expect((0..<100).filter { _ in budget.admit(failure: true, now: instant) }.count == TraceBudget.failureLimit)
        #expect(!budget.admit(failure: true, now: instant.addingTimeInterval(59)))
        #expect(budget.admit(failure: true, now: instant.addingTimeInterval(60)))
        #expect(budget.admit(failure: false, now: instant.addingTimeInterval(60)))
        // Failures do not use up the success budget either.
        let other = TraceBudget()
        #expect((0..<100).filter { _ in other.admit(failure: true, now: instant) }.count == TraceBudget.failureLimit)
        #expect(other.admit(failure: false, now: instant))
        // A clock set back starts a new window instead of keeping a spent one.
        #expect((0..<100).filter { _ in budget.admit(failure: true, now: instant.addingTimeInterval(60)) }.count == TraceBudget.failureLimit - 1)
        #expect(budget.admit(failure: true, now: instant.addingTimeInterval(-60)))
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'GateDiagnostics' in scope`, `cannot find 'TraceBudget' in scope` ve `cannot find 'RelayDirection' in scope`, ayrıca buna bağlı `reference to member 'engineToClient' cannot be resolved without a contextual type`.

- [ ] **Adım 3: Tanı satırlarını yaz** (`swift` bloğu 5)

Satırlar Windows'takiyle aynı biçimdedir:
- `Failure stage=<aşama> target=<host:port ya da unknown> category=<kategori>`
- bilinen bir soket hatasında ek olarak ` socket=<ad>`
- aktarım hatasında ek olarak ` direction=<yön> elapsed_ms=<süre>`; süre 0 ile bir gün arasına sıkıştırılır

macOS'a özgü iki ek vardır: sahiplik reddine ` reason=<neden>` eklenir, `errno` değerleri Windows `SocketError` adlarına eşlenir. Neden de satırın öteki değişken parçaları gibi burada süzülür: harf, rakam, boşluk ve `._()=-` kalır, gerisi `_` olur, en fazla 96 karakter yazılır; böylece bir neden yeni bir satır başlatamaz. `safeTarget` baytlarla çalışır; kullanıcı bilgisi içeren hedef `unknown` olur. `TraceBudget`, başarı ve hata satırlarını dakikada ayrı ayrı 32 ve 64 ile sınırlar; geri alınan saat yeni bir pencere başlatır.

```swift
import Darwin
import Foundation

/// The stage at which a gate connection ended (Windows `ProcessGate.RelayStage`).
public enum GateStage: String, Sendable {
    case admission = "Admission"
    case ownership = "Ownership"
    case headerRead = "HeaderRead"
    case requestPolicy = "RequestPolicy"
    case backendConnect = "BackendConnect"
    case backendIdentity = "BackendIdentity"
    case backendWrite = "BackendWrite"
    case relay = "Relay"
}

/// A direction of the relay, as diagnostics name it.
public enum RelayDirection: String, Sendable {
    case clientToEngine = "client_to_engine"
    case engineToClient = "engine_to_client"
}

/// Why a gate step failed, in the categories of the Windows diagnostics. A failed socket call carries its `errno`.
public enum GateFailure: Error, Equatable, Sendable {
    /// The request policy refused the header.
    case refused(RequestFailure)
    case timeout
    /// The gate closed.
    case canceled
    /// Creating, binding, accepting or connecting a socket failed.
    case socket(Int32)
    /// A read or write failed (`errno`), or the peer ended the stream early (nil).
    case io(Int32?)
    /// The header is too long or not ASCII, or the engine did not accept the connection itself.
    case invalidData
    case unexpected
}

/// The gate's diagnostic lines (Windows `ProcessGate` traces). A line holds only the stage, a validated host and port,
/// a fixed category and a known socket error name: never a URL, header, body, credential or error message.
public enum GateDiagnostics {
    public static let capacityFailure = "Failure stage=Admission target=unknown category=Capacity"

    /// A refused client (Windows `category=UnownedClient`) with the reason of the refusal. Callers pass
    /// `PeerAdmission.Refusal.diagnostic` or a fixed reason; the reason is not checked against that vocabulary, but it is
    /// filtered here: letters, digits, spaces and `._()=-` are kept, anything else becomes `_`, and at most 96 characters
    /// remain, so a reason can never start another line.
    public static func unownedClient(reason: String) -> String {
        let safe = reason.unicodeScalars.prefix(96).map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " ._()=-".unicodeScalars.contains(scalar)) ? Character(scalar) : "_"
        }
        return "Failure stage=Ownership target=unknown category=UnownedClient reason=" + String(safe)
    }

    public static func failure(stage: GateStage, target: String, error: GateFailure) -> String {
        "Failure stage=" + stage.rawValue + " target=" + safeAuthority(target) + " category=" + category(of: error) + socketDetail(of: error)
    }

    /// A relay failure with the direction that failed first and how long the relay ran, clamped to one day.
    public static func relayFailure(target: String, error: GateFailure, direction: RelayDirection?, elapsedMilliseconds: Int64) -> String {
        failure(stage: .relay, target: target, error: error) + " direction=" + (direction?.rawValue ?? "unknown") +
            " elapsed_ms=" + String(min(86_400_000, max(0, elapsedMilliseconds)))
    }

    /// The validated `host:port` a request header names, with the host in lower case, or `unknown` (Windows `SafeTarget`).
    public static func safeTarget(_ header: String) -> String {
        let bytes = Array(header.utf8)
        guard !bytes.isEmpty, bytes.count <= RequestPolicy.maxHeaderLength,
              let end = bytes.indices.dropLast().first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 }) else { return "unknown" }
        let line = bytes[..<end].split(separator: 32, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard line.count == 3 else { return "unknown" }
        if line[0] == "CONNECT" { return safeAuthority(line[1]) }
        let target = Array(line[1].utf8)
        guard target.count > 7, String(decoding: target.prefix(7), as: UTF8.self).lowercased() == "http://", !target.contains(92) else {
            return "unknown"
        }
        // The authority ends at the path, query or fragment; user information is never logged.
        let authority = target.dropFirst(7).prefix { $0 != 47 && $0 != 63 && $0 != 35 }
        guard !authority.contains(64) else { return "unknown" }
        let text = String(decoding: authority, as: UTF8.self)
        return safeAuthority(authority.contains(58) ? text : text + ":80")
    }

    /// `host:port` with the host in lower case, or `unknown` unless the host is a DNS name and the port is 1-65535
    /// (Windows `SafeAuthority`).
    static func safeAuthority(_ authority: String) -> String {
        guard authority.utf8.count <= 259 else { return "unknown" }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...5).contains(parts[1].utf8.count), parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = Int(parts[1]), (1...65535).contains(port), RequestPolicy.validDNSHost(String(parts[0])) else { return "unknown" }
        return parts[0].lowercased() + ":" + String(port)
    }

    static func category(of error: GateFailure) -> String {
        switch error {
        case .refused(let refusal): return refusal.rawValue
        case .timeout: return "Timeout"
        case .canceled: return "Canceled"
        case .socket: return "Socket"
        case .io: return "IO"
        case .invalidData: return "InvalidData"
        case .unexpected: return "Unexpected"
        }
    }

    /// ` socket=<name>` for an error that Windows names the same way (`SocketError`); nothing for any other.
    static func socketDetail(of error: GateFailure) -> String {
        let code: Int32?
        switch error {
        case .socket(let value): code = value
        case .io(let value): code = value
        default: code = nil
        }
        guard let code, let name = socketErrorNames[code] else { return "" }
        return " socket=" + name
    }

    static let socketErrorNames: [Int32: String] = [
        ECONNREFUSED: "ConnectionRefused", ECONNRESET: "ConnectionReset", ECONNABORTED: "ConnectionAborted", ETIMEDOUT: "TimedOut",
        ENETUNREACH: "NetworkUnreachable", EHOSTUNREACH: "HostUnreachable", ENETDOWN: "NetworkDown", EHOSTDOWN: "HostDown",
        EADDRINUSE: "AddressAlreadyInUse", EADDRNOTAVAIL: "AddressNotAvailable", ENOTCONN: "NotConnected", EPIPE: "Shutdown",
        ENOBUFS: "NoBufferSpaceAvailable", EMFILE: "TooManyOpenSockets",
    ]
}

/// Limits diagnostic lines per minute. Successes and failures have separate budgets, so success lines never use up the
/// failure budget, and both renew every minute (Windows `ProcessGate.TraceBudget`).
public final class TraceBudget {
    public static let successLimit = 32
    public static let failureLimit = 64
    private let lock = NSLock()
    private var window: Date?
    private var successes = 0
    private var failures = 0

    public init() {}

    public func admit(failure: Bool, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A clock set back starts a new window, so it cannot silence failures for good.
        if let start = window, now >= start, now.timeIntervalSince(start) < 60 {} else {
            window = now
            successes = 0
            failures = 0
        }
        if failure {
            guard failures < Self.failureLimit else { return false }
            failures += 1
        } else {
            guard successes < Self.successLimit else { return false }
            successes += 1
        }
        return true
    }
}
```

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 57 tests in 10 suites passed`, uyarısız ve `skipped` olmadan.

---

### Görev 3: Loopback soketleri ve aktarım

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/LoopbackSocketTests.swift`, `macos/Tests/DiscordAccessKitTests/RelayTests.swift`, `macos/Sources/DiscordAccessKit/Gate/LoopbackSocket.swift`, `macos/Sources/DiscordAccessKit/Gate/Relay.swift`

- [ ] **Adım 1: Soket testlerini yaz** (`swift` bloğu 6)

Bağlantıların ikisi de sınanan kodla kurulur: dinleyici, bağlanan uç ve kabul edilen uç. Sınanan durumlar:
- dinleyicide `SO_REUSEADDR`; bütün soketlerde ve durdurma borusunda close-on-exec; soketlerde bloklamama; bağlantılarda `SO_NOSIGPIPE` ve `TCP_NODELAY`;
- başlık ve ardından gelen baytların (ASCII olmayanlar dahil) dokunulmadan dönmesi;
- ASCII olmayan başlık, sonu olmayan 32 KiB'lik başlık ve sonu 32 KiB'yi aşan başlık için `invalidData`; başlık bitmeden kapanan akış için `io(nil)`;
- okuma ve yazmanın son tarihte (`timeout`) ve durdurma borusu kapanınca hemen (`canceled`) bitmesi;
- bağlantı denemesinin son tarihte ve durdurmayla bitmesi: dinlemeyen ama bağlanmış bir soket portunu tutar ve macOS ona gelen bağlantı isteklerini yanıtsız bırakır;
- reddedilen bağlantı için `socket(ECONNREFUSED)`;
- `poll` süresinin tam milisaniyeye yukarı yuvarlanması ve bir günle sınırlanması.

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The gate's sockets on their own, over real loopback connections in this process that the code under test makes.
@Suite struct LoopbackSocketTests {
    /// A stop pipe whose ends are each closed once: the write end by `fire()` or at the end, the read end at the end.
    final class Stop {
        let read: Int32
        private var write: Int32

        init() throws {
            (read, write) = try LoopbackSocket.stopPipe()
        }

        func fire() {
            guard write >= 0 else { return }
            close(write)
            write = -1
        }

        deinit {
            fire()
            close(read)
        }
    }

    /// The next connection of `listener` within 5 seconds.
    static func accept(_ listener: Int32, stop: Stop) throws -> (descriptor: Int32, peer: sockaddr_in) {
        try LoopbackSocket.wait(listener, for: Int16(POLLIN), until: .now + .seconds(5), stop: stop.read)
        guard let accepted = try LoopbackSocket.accept(listener) else { throw POSIXError(.ECONNABORTED) }
        return accepted
    }

    /// Runs `body` with both ends of one connection, the accepted end first, and closes them afterwards.
    static func withConnection(_ body: (_ accepted: Int32, _ connected: Int32, _ stop: Stop) throws -> Void) throws {
        let stop = try Stop()
        let listener = try LoopbackSocket.listen(port: 0, backlog: 4)
        defer { close(listener.descriptor) }
        let connected = try LoopbackSocket.connect(port: listener.port, until: .now + .seconds(5), stop: stop.read)
        defer { close(connected) }
        let accepted = try accept(listener.descriptor, stop: stop)
        defer { close(accepted.descriptor) }
        try body(accepted.descriptor, connected, stop)
    }

    /// The value of an integer socket option, or 0 when it cannot be read.
    static func option(_ descriptor: Int32, _ level: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, level, name, &value, &length) == 0 ? value : 0
    }

    @Test func setsTheOptionsTheGateReliesOn() throws {
        let stop = try Stop()
        let listener = try LoopbackSocket.listen(port: 0, backlog: 4)
        defer { close(listener.descriptor) }
        let connected = try LoopbackSocket.connect(port: listener.port, until: .now + .seconds(5), stop: stop.read)
        defer { close(connected) }
        let accepted = try Self.accept(listener.descriptor, stop: stop)
        defer { close(accepted.descriptor) }
        let pipe = try LoopbackSocket.stopPipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }
        #expect(LoopbackSocket.loopbackPeerPort(accepted.peer) == LoopbackSocket.localPort(connected))
        #expect(Self.option(listener.descriptor, SOL_SOCKET, SO_REUSEADDR) != 0)
        for descriptor in [listener.descriptor, connected, accepted.descriptor, pipe.read, pipe.write] {
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }
        for descriptor in [listener.descriptor, connected, accepted.descriptor] {
            #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0)
        }
        for descriptor in [connected, accepted.descriptor] {
            #expect(Self.option(descriptor, SOL_SOCKET, SO_NOSIGPIPE) != 0)
            #expect(Self.option(descriptor, IPPROTO_TCP, TCP_NODELAY) != 0)
        }
    }

    /// The header ends at the first CR LF CR LF; what follows it, even bytes that are not ASCII, comes back untouched.
    @Test func returnsTheHeaderAndTheBytesAfterItUntouched() throws {
        let header = Array("GET http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\n\r\n".utf8)
        let rest: [UInt8] = [0xC3, 0x28, 0x00, 13, 10, 13, 10]
        try Self.withConnection { accepted, connected, stop in
            try LoopbackSocket.write(connected, header + rest, until: .now + .seconds(5), stop: stop.read)
            let read = try LoopbackSocket.readHeader(accepted, until: .now + .seconds(5), stop: stop.read)
            #expect(read.header == header)
            #expect(read.remainder == rest)
        }
    }

    /// A header with a byte that is not ASCII, one of 32 KiB without its end, and one whose end would finish past 32 KiB.
    static let refusedHeaders: [[UInt8]] = [
        Array("GET http://discord.com/ HTTP/1.1\r\nUser-Agent: caf".utf8) + [0xC3, 0xA9] + Array("\r\n\r\n".utf8),
        [UInt8](repeating: 97, count: 32_768),
        [UInt8](repeating: 97, count: 32_766) + [13, 10, 13, 10],
    ]

    @Test(arguments: refusedHeaders)
    func refusesAHeaderThatIsNotASCIIOrDoesNotEndWithin32KiB(bytes: [UInt8]) throws {
        try Self.withConnection { accepted, connected, stop in
            try LoopbackSocket.write(connected, bytes, until: .now + .seconds(5), stop: stop.read)
            #expect(throws: GateFailure.invalidData) { try LoopbackSocket.readHeader(accepted, until: .now + .seconds(5), stop: stop.read) }
        }
    }

    @Test func reportsAStreamThatEndsBeforeTheHeaderDoes() throws {
        try Self.withConnection { accepted, connected, stop in
            try LoopbackSocket.write(connected, Array("GET http://discord.com/ HTTP/1.1\r\n".utf8), until: .now + .seconds(5), stop: stop.read)
            shutdown(connected, SHUT_WR)
            #expect(throws: GateFailure.io(nil)) { try LoopbackSocket.readHeader(accepted, until: .now + .seconds(5), stop: stop.read) }
        }
    }

    /// Reads and writes end at their deadline, and at once when the stop pipe closes, even with time left.
    @Test func endsReadsAndWritesAtTheDeadlineOrTheStop() throws {
        // Nobody reads the other end, so the buffers fill up and the write has to wait.
        let large = [UInt8](repeating: 0, count: 16 << 20)
        try Self.withConnection { accepted, connected, stop in
            #expect(throws: GateFailure.timeout) { try LoopbackSocket.readHeader(accepted, until: .now + .milliseconds(100), stop: stop.read) }
            #expect(throws: GateFailure.timeout) { try LoopbackSocket.write(connected, large, until: .now + .milliseconds(100), stop: stop.read) }
            stop.fire()
            let started = ContinuousClock.now
            #expect(throws: GateFailure.canceled) { try LoopbackSocket.readHeader(accepted, until: .now + .seconds(5), stop: stop.read) }
            #expect(throws: GateFailure.canceled) { try LoopbackSocket.write(connected, large, until: .now + .seconds(5), stop: stop.read) }
            #expect(ContinuousClock.now - started < .seconds(1))
        }
    }

    /// A socket bound to 127.0.0.1:`port` (0 picks one) that does not listen, and its port; the caller closes it.
    static func boundSocket(port: UInt16 = 0) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw lastPOSIXError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
        }
        guard bound else {
            let error = lastPOSIXError()
            close(descriptor)
            throw error
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    /// A bound socket that does not listen keeps its port from every other test, and macOS drops the connection attempts
    /// it gets without an answer: a connection to it ends only at its deadline or with the stop.
    @Test func endsAConnectionAttemptAtTheDeadlineOrTheStop() throws {
        let stop = try Stop()
        let holder = try Self.boundSocket()
        defer { close(holder.descriptor) }
        #expect(throws: GateFailure.timeout) { _ = try LoopbackSocket.connect(port: holder.port, until: .now + .milliseconds(200), stop: stop.read) }
        stop.fire()
        let started = ContinuousClock.now
        #expect(throws: GateFailure.canceled) { _ = try LoopbackSocket.connect(port: holder.port, until: .now + .seconds(5), stop: stop.read) }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    /// A port outside the range the system hands out (49152-65535) stays free once its socket is closed, since no other
    /// test binds there; a connection to it is refused.
    @Test func reportsARefusedConnection() throws {
        let stop = try Stop()
        var free: UInt16?
        for candidate in UInt16(21_000)..<21_200 where free == nil {
            guard let holder = try? Self.boundSocket(port: candidate) else { continue }
            close(holder.descriptor)
            free = holder.port
        }
        let port = try #require(free)
        #expect(throws: GateFailure.socket(ECONNREFUSED)) { _ = try LoopbackSocket.connect(port: port, until: .now + .seconds(5), stop: stop.read) }
    }

    /// `poll` gets whole milliseconds, rounded up so that a wait never wakes before its deadline, and at most one day.
    @Test func roundsPollTimeoutsUpToWholeMilliseconds() {
        let now = ContinuousClock.now
        #expect(LoopbackSocket.pollTimeout(until: now, now: now) == nil)
        #expect(LoopbackSocket.pollTimeout(until: now - .milliseconds(1), now: now) == nil)
        #expect(LoopbackSocket.pollTimeout(until: now + .nanoseconds(1), now: now) == 1)
        #expect(LoopbackSocket.pollTimeout(until: now + .milliseconds(1), now: now) == 1)
        #expect(LoopbackSocket.pollTimeout(until: now + .microseconds(1_001), now: now) == 2)
        #expect(LoopbackSocket.pollTimeout(until: now + .seconds(15), now: now) == 15_000)
        #expect(LoopbackSocket.pollTimeout(until: now + .seconds(200_000), now: now) == 86_400_000)
    }
}
```

- [ ] **Adım 2: Aktarım testlerini yaz** (`swift` bloğu 7)

Testler bu süreçte iki gerçek loopback bağlantısı kurar. Test bir bağlantıda istemciyi, ötekinde motoru oynar; aktarım ikisinin arasında kendi iş parçacığında çalışır. Aktarımın uçları kapıdaki gibi kurulur. Testin uçları 5 sn'de vazgeçer; bir test asılı kalmaz. Her tanıtıcı tam bir kez kapatılır: iki kez kapatılan bir numara o sırada başka bir testin tanıtıcısı olabilir. Sınanan durumlar: iki yönde yarım kapama, soket arabelleklerinden büyük iki akışın aynı anda iki yönde aktarılması, yarım kapamadan sonra karşı yönün akmaya devam etmesi ve boşaltma süresinin o andan sayılması, sıfırlamanın yönü, durdurma borusu.

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The relay between two real loopback TCP connections in this process: the test plays the client on one and the engine
/// on the other.
@Suite struct RelayTests {
    /// Both ends of one loopback TCP connection; the caller closes them.
    static func connection() throws -> (near: Int32, far: Int32) {
        let listener = try TCPListener()
        let near = socket(AF_INET, SOCK_STREAM, 0)
        guard near >= 0 else { throw lastPOSIXError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = listener.port.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(near, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        do {
            guard connected else { throw lastPOSIXError() }
            return (near, try listener.acceptClient().descriptor)
        } catch {
            close(near)
            throw error
        }
    }

    /// The relay running on its own thread between the relay ends of a client and an engine connection. Every
    /// descriptor is closed exactly once: a descriptor number closed twice could belong to another test by then.
    final class Run {
        private final class Result {
            let done = DispatchSemaphore(value: 0)
            var outcome: Relay.Outcome?
        }

        private(set) var client: Int32
        private(set) var engine: Int32
        private let relayClient: Int32
        private let relayEngine: Int32
        private let stopRead: Int32
        private var stopWrite: Int32
        private let finished = Result()

        init(drainTimeout: TimeInterval = 5) throws {
            let clientSide = try RelayTests.connection()
            let engineSide: (near: Int32, far: Int32)
            let stop: (read: Int32, write: Int32)
            do {
                engineSide = try RelayTests.connection()
                do {
                    stop = try LoopbackSocket.stopPipe()
                } catch {
                    for descriptor in [engineSide.near, engineSide.far] { Darwin.close(descriptor) }
                    throw error
                }
            } catch {
                for descriptor in [clientSide.near, clientSide.far] { Darwin.close(descriptor) }
                throw error
            }
            (client, relayClient) = clientSide
            (relayEngine, engine) = engineSide
            (stopRead, stopWrite) = stop
            var one: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            // The relay's ends are set up as the gate sets up its own.
            for descriptor in [relayClient, relayEngine] {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
                setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, size)
            }
            // The test's ends give up after 5 seconds instead of hanging.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            for descriptor in [client, engine] {
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
            }
            // The thread holds only what it uses, so releasing the run stops it.
            let (relayClient, relayEngine, stopRead, finished) = (relayClient, relayEngine, stopRead, finished)
            Thread {
                finished.outcome = Relay.run(client: relayClient, engine: relayEngine, stop: stopRead, drainTimeout: drainTimeout)
                finished.done.signal()
            }.start()
        }

        /// The outcome, once the relay ends within `timeout`.
        func result(timeout: TimeInterval = 5) -> Relay.Outcome? {
            guard finished.done.wait(timeout: .now() + timeout) == .success else { return nil }
            finished.done.signal()
            return finished.outcome
        }

        /// Closes the write end of the stop pipe, as closing the gate does.
        func cancel() {
            guard stopWrite >= 0 else { return }
            Darwin.close(stopWrite)
            stopWrite = -1
        }

        /// Closes the engine's socket with a reset instead of an orderly end.
        func resetEngine() {
            RelayTests.reset(engine)
            engine = -1
        }

        /// Closes the client's socket with a reset instead of an orderly end.
        func resetClient() {
            RelayTests.reset(client)
            client = -1
        }

        deinit {
            cancel()
            guard result() != nil else { return }  // never close what a running relay still uses
            for descriptor in [client, engine, relayClient, relayEngine, stopRead] where descriptor >= 0 { Darwin.close(descriptor) }
        }
    }

    static func reset(_ descriptor: Int32) {
        var reset = linger(l_onoff: 1, l_linger: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
        Darwin.close(descriptor)
    }

    static func send(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard count > 0 else { throw lastPOSIXError() }
                offset += count
            }
        }
    }

    /// Everything until the peer's end of stream (or `limit` bytes).
    static func receive(_ descriptor: Int32, limit: Int = .max) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while bytes.count < limit {
            let count = read(descriptor, &chunk, min(chunk.count, limit - bytes.count))
            guard count >= 0 else { throw lastPOSIXError() }
            if count == 0 { break }
            bytes += chunk[0..<count]
        }
        return bytes
    }

    static let pattern = (0..<(256 * 1024)).map { UInt8($0 % 251) }

    @Test func copiesBothWaysAndPassesEachHalfCloseOn() throws {
        let run = try Run()
        try Self.send(run.client, Array("ping".utf8))
        #expect(try Self.receive(run.engine, limit: 4) == Array("ping".utf8))
        try Self.send(run.engine, Self.pattern)
        shutdown(run.engine, SHUT_WR)
        #expect(try Self.receive(run.client) == Self.pattern)
        // The engine has finished sending; what the client still sends must arrive.
        try Self.send(run.client, Array("late".utf8))
        shutdown(run.client, SHUT_WR)
        #expect(try Self.receive(run.engine) == Array("late".utf8))
        #expect(run.result() == .finished)
    }

    /// Streams larger than the socket buffers in both directions at once, so the relay meets full buffers, partial writes
    /// and both events on one socket.
    @Test func copiesLargeStreamsBothWaysAtOnce() throws {
        let run = try Run()
        let upstream = (0..<(2 << 20)).map { UInt8($0 % 241) }
        let downstream = (0..<(2 << 20)).map { UInt8($0 % 239) }
        let sent = DispatchGroup()
        for (descriptor, bytes) in [(run.client, upstream), (run.engine, downstream)] {
            sent.enter()
            Thread {
                // A failed send ends the stream early, so the comparison below fails instead of the test hanging.
                _ = try? RelayTests.send(descriptor, bytes)
                shutdown(descriptor, SHUT_WR)
                sent.leave()
            }.start()
        }
        // If a check below fails early, the senders may still use their descriptors: the run must outlive them.
        defer {
            _ = sent.wait(timeout: .now() + 15)
            withExtendedLifetime(run) {}
        }
        #expect(try Self.receive(run.engine) == upstream)
        #expect(try Self.receive(run.client) == downstream)
        #expect(sent.wait(timeout: .now() + 5) == .success)
        #expect(run.result() == .finished)
    }

    /// After the client's half-close the engine may still answer, for at most the drain time counted from that end.
    @Test func boundsTheDrainOnceOneDirectionHasEnded() throws {
        let run = try Run(drainTimeout: 0.3)
        usleep(200_000)
        shutdown(run.client, SHUT_WR)
        let halfClosed = ContinuousClock.now
        #expect(try Self.receive(run.engine) == [])
        try Self.send(run.engine, Array("late".utf8))
        #expect(try Self.receive(run.client, limit: 4) == Array("late".utf8))
        let outcome = try #require(run.result())
        let drained = ContinuousClock.now - halfClosed
        guard case .failed(.timeout, .engineToClient, let elapsed) = outcome else {
            Issue.record("unexpected outcome \(outcome)")
            return
        }
        // A drain counted from the start of the relay, 200 ms before the half-close, would end about 100 ms after it.
        #expect(drained >= .milliseconds(280) && elapsed < 3000)
    }

    /// With nothing pending, a reset is seen by the direction that reads from the side that reset. With bytes pending,
    /// the other direction's write may see it first; Windows names whichever copy failed first in the same way.
    @Test func reportsAResetWithTheDirectionItCameFrom() throws {
        let run = try Run()
        try Self.send(run.client, Array("ping".utf8))
        #expect(try Self.receive(run.engine, limit: 4) == Array("ping".utf8))
        run.resetEngine()
        let outcome = try #require(run.result())
        guard case .failed(.io(ECONNRESET), .engineToClient, _) = outcome else {
            Issue.record("unexpected outcome \(outcome)")
            return
        }
    }

    @Test func reportsAClientResetInTheOtherDirection() throws {
        let run = try Run()
        try Self.send(run.engine, Array("pong".utf8))
        #expect(try Self.receive(run.client, limit: 4) == Array("pong".utf8))
        run.resetClient()
        let outcome = try #require(run.result())
        guard case .failed(.io(ECONNRESET), .clientToEngine, _) = outcome else {
            Issue.record("unexpected outcome \(outcome)")
            return
        }
    }

    @Test func endsAtOnceWhenTheStopPipeCloses() throws {
        let run = try Run()
        let started = Date()
        run.cancel()
        #expect(run.result(timeout: 2) == .canceled)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
```

- [ ] **Adım 3: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'LoopbackSocket' in scope`, `cannot find 'Relay' in scope` ve `cannot find type 'Relay' in scope`. Türler henüz olmadığı için `no calls to throwing functions occur within 'try' expression` uyarısı da görülür; türler tanımlanınca kaybolur. Derleme işlerinin sırasına göre hatalar yalnız bir test dosyasından gelebilir: `LoopbackSocketTests.swift` tek başına yalnız `cannot find 'LoopbackSocket' in scope` verir.

- [ ] **Adım 4: Loopback soketlerini yaz** (`swift` bloğu 8)

- Bütün soketler close-on-exec'tir ve bloklamaz. Bağlantılar SIGPIPE üretmez ve Nagle gecikmesi kullanmaz. macOS'ta `SOCK_CLOEXEC` yoktur; soketin açılmasıyla bayrağın konması arasında başlatılan bir alt süreç tanıtıcıyı devralabilir. Uygulamanın tek alt süreci olan motor `POSIX_SPAWN_CLOEXEC_DEFAULT` ile başlatılır ve ona verilmeyen hiçbir tanıtıcıyı almaz.
- Her bekleme `poll` ile yapılır ve iki durumda biter: monoton saatle ölçülen son tarih geçince (`timeout`) ya da durdurma borusu okunabilir olunca (`canceled`). Süre tam milisaniyeye yukarı yuvarlanır; bekleme son tarihten önce bitmez.
- Başlık okuyucu ilk CR LF CR LF'ye kadar en fazla 32 KiB okur ve başlığın ASCII olmasını ister. Başlıktan sonra gelen baytları dokunmadan döndürür.
- Dinleyici `SO_REUSEADDR` ile açılır: yeni bir kapı, kapanan kapının portunu eski bağlantılar TIME_WAIT'teyken de alabilir.

```swift
import Darwin
import Foundation

/// Non-blocking TCP sockets on 127.0.0.1 for the gate. Every socket is close-on-exec and never raises SIGPIPE, and
/// connections send without Nagle's delay. Every wait also ends when `stop` becomes readable: the gate closes the write
/// end of that pipe when it closes, which wakes all waits at once. Deadlines use a monotonic clock, so changing the
/// system time does not shorten or extend them.
enum LoopbackSocket {
    static let loopback = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)

    /// A listener on 127.0.0.1:`port` (0 picks a free port) and the port it got. `SO_REUSEADDR` lets a new gate take
    /// the port of a closed one while its old connections linger in TIME_WAIT; no other socket can bind 127.0.0.1:`port`
    /// while this one listens, since that would need `SO_REUSEPORT` on both.
    static func listen(port: UInt16, backlog: Int32) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GateFailure.socket(errno) }
        var address = loopbackAddress(port: port)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var one: Int32 = 1
        let reusable = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        let ready = setFlags(descriptor) && reusable && withGenericAddress(&address) { generic in
            bind(descriptor, generic, length) == 0 && Darwin.listen(descriptor, backlog) == 0 && getsockname(descriptor, generic, &length) == 0
        }
        guard ready else {
            let error = errno
            Darwin.close(descriptor)
            throw GateFailure.socket(error)
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    /// The next pending connection and its peer address, or nil when none is pending (or it went away meanwhile).
    static func accept(_ listener: Int32) throws -> (descriptor: Int32, peer: sockaddr_in)? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let descriptor = withGenericAddress(&address) { Darwin.accept(listener, $0, &length) }
        guard descriptor >= 0 else {
            if errno == EAGAIN || errno == EINTR || errno == ECONNABORTED { return nil }
            throw GateFailure.socket(errno)
        }
        guard setFlags(descriptor), setConnectionOptions(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }
        return (descriptor, address)
    }

    /// A connection to 127.0.0.1:`port`, established before `deadline`.
    static func connect(port: UInt16, until deadline: ContinuousClock.Instant, stop: Int32) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GateFailure.socket(errno) }
        do {
            guard setFlags(descriptor), setConnectionOptions(descriptor) else { throw GateFailure.socket(errno) }
            var address = loopbackAddress(port: port)
            let started = withGenericAddress(&address) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            if started != 0 {
                guard errno == EINPROGRESS || errno == EINTR else { throw GateFailure.socket(errno) }
                try wait(descriptor, for: Int16(POLLOUT), until: deadline, stop: stop)
                var status: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &status, &length) == 0 else { throw GateFailure.socket(errno) }
                guard status == 0 else { throw GateFailure.socket(status) }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// The request header: the bytes up to and including the first CR LF CR LF, at most 32 KiB in all, read before
    /// `deadline`; the header must be ASCII. Bytes that arrived after it are returned untouched (Windows `ReadHeader`).
    static func readHeader(_ descriptor: Int32, until deadline: ContinuousClock.Instant, stop: Int32) throws -> (header: [UInt8], remainder: [UInt8]) {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1024)
        var scan = 0
        while bytes.count < RequestPolicy.maxHeaderLength {
            try wait(descriptor, for: Int16(POLLIN), until: deadline, stop: stop)
            let wanted = min(chunk.count, RequestPolicy.maxHeaderLength - bytes.count)
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw GateFailure.io(errno)
            }
            guard count > 0 else { throw GateFailure.io(nil) }
            bytes += chunk[0..<count]
            while scan + 3 < bytes.count {
                if bytes[scan] == 13 && bytes[scan + 1] == 10 && bytes[scan + 2] == 13 && bytes[scan + 3] == 10 {
                    let end = scan + 4
                    guard bytes[..<end].allSatisfy({ $0 <= 127 }) else { throw GateFailure.invalidData }
                    return (Array(bytes[..<end]), Array(bytes[end...]))
                }
                scan += 1
            }
        }
        throw GateFailure.invalidData
    }

    /// Writes all of `bytes` before `deadline`.
    static func write(_ descriptor: Int32, _ bytes: [UInt8], until deadline: ContinuousClock.Instant, stop: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0 && errno != EAGAIN && errno != EINTR { throw GateFailure.io(errno) }
            try wait(descriptor, for: Int16(POLLOUT), until: deadline, stop: stop)
        }
    }

    /// Waits until `descriptor` is ready for `events`, or has an error or hang-up to report. Throws `.timeout` at
    /// `deadline` and `.canceled` once `stop` is readable.
    static func wait(_ descriptor: Int32, for events: Int16, until deadline: ContinuousClock.Instant, stop: Int32) throws {
        while true {
            guard let timeout = pollTimeout(until: deadline) else { throw GateFailure.timeout }
            var watched = [pollfd(fd: descriptor, events: events, revents: 0), pollfd(fd: stop, events: Int16(POLLIN), revents: 0)]
            let result = poll(&watched, 2, timeout)
            if result < 0 {
                if errno == EINTR { continue }
                throw GateFailure.unexpected
            }
            if watched[1].revents != 0 { throw GateFailure.canceled }
            if watched[0].revents != 0 { return }
        }
    }

    /// Whole milliseconds from `now` until `deadline` for `poll`, rounded up so a wait never ends early and at most one
    /// day; nil once the deadline has passed.
    static func pollTimeout(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Int32? {
        let remaining = deadline - now
        guard remaining > .zero else { return nil }
        let (seconds, attoseconds) = remaining.components
        return Int32(min(seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000, 86_400_000))
    }

    static func localPort(_ descriptor: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withGenericAddress(&address, { getsockname(descriptor, $0, &length) }) == 0, address.sin_family == sa_family_t(AF_INET) else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    /// The client port of a peer that connected from exactly 127.0.0.1, otherwise nil.
    static func loopbackPeerPort(_ peer: sockaddr_in) -> UInt16? {
        guard peer.sin_family == sa_family_t(AF_INET), peer.sin_addr.s_addr == loopback.s_addr else { return nil }
        return UInt16(bigEndian: peer.sin_port)
    }

    /// A pipe whose read end becomes readable for good once the write end is closed; both ends are close-on-exec.
    static func stopPipe() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw GateFailure.socket(errno) }
        guard fcntl(ends[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(ends[1], F_SETFD, FD_CLOEXEC) == 0 else {
            let error = errno
            Darwin.close(ends[0])
            Darwin.close(ends[1])
            throw GateFailure.socket(error)
        }
        return (ends[0], ends[1])
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = loopback
        address.sin_port = port.bigEndian
        return address
    }

    /// Close-on-exec and non-blocking.
    private static func setFlags(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 && flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// No SIGPIPE on a write to a closed peer, and no Nagle delay (Windows `NoDelay`).
    private static func setConnectionOptions(_ descriptor: Int32) -> Bool {
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, size) == 0 && setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, size) == 0
    }

    private static func withGenericAddress<Result>(_ address: inout sockaddr_in, _ body: (UnsafeMutablePointer<sockaddr>) -> Result) -> Result {
        withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, body) }
    }
}
```

- [ ] **Adım 5: Aktarımı yaz** (`swift` bloğu 9)

İki yön tek iş parçacığında `poll` ile yürür; her yönün 16 KiB'lik arabelleği vardır. Bir yönün girdisi bitip okunanların hepsi yazılınca hedefin gönderme yönü kapatılır (`shutdown(SHUT_WR)`); TCP yarım kapaması böylece geçer. İlk biten yönden sonra öteki en fazla `drainTimeout` içinde bitmelidir (0'dan büyük, en fazla 30 sn). Sonuç ilk hatayı, onu gören yönü ve geçen süreyi taşır (Windows'taki iki `CopyToAsync` pompası). Aktarım hiçbir tanıtıcıyı kapatmaz; kapatmak çağıranın işidir.

```swift
import Darwin
import Foundation

/// Copies bytes both ways between a client and the engine (Windows: the two `CopyToAsync` pumps of
/// `ProcessGate.Handle`). A direction ends when its input ends and everything read has been written; then the sending
/// side of its destination is shut down, so a TCP half-close passes through, and the other direction may still finish
/// within `drainTimeout` (more than 0 and at most 30 seconds). Both sockets must be non-blocking; one thread does all the
/// work with `poll`. The relay never closes a descriptor; its caller does.
enum Relay {
    enum Outcome: Equatable {
        case finished
        case canceled
        /// The first failure, the direction it happened in (nil when shutting down a sending side failed) and how long
        /// the relay had run.
        case failed(GateFailure, RelayDirection?, elapsedMilliseconds: Int64)
    }

    static let bufferSize = 16384

    private struct Pump {
        let direction: RelayDirection
        let source: Int32
        let destination: Int32
        var buffer = [UInt8](repeating: 0, count: Relay.bufferSize)
        /// Bytes read but not yet written.
        var pending = 0..<0
        var inputEnded = false
        var finished = false
    }

    static func run(client: Int32, engine: Int32, stop: Int32, drainTimeout: TimeInterval) -> Outcome {
        precondition(drainTimeout > 0 && drainTimeout <= 30)
        let started = ContinuousClock.now
        func elapsed() -> Int64 {
            let (seconds, attoseconds) = (ContinuousClock.now - started).components
            return seconds * 1000 + attoseconds / 1_000_000_000_000_000
        }
        var pumps = [Pump(direction: .clientToEngine, source: client, destination: engine),
                     Pump(direction: .engineToClient, source: engine, destination: client)]
        var drainDeadline: ContinuousClock.Instant?
        while !(pumps[0].finished && pumps[1].finished) {
            var timeout: Int32 = -1
            if let drainDeadline {
                guard let remaining = LoopbackSocket.pollTimeout(until: drainDeadline) else {
                    return .failed(.timeout, pumps.first(where: { !$0.finished })?.direction, elapsedMilliseconds: elapsed())
                }
                timeout = remaining
            }
            var watched = [pollfd(fd: stop, events: Int16(POLLIN), revents: 0), pollfd(fd: client, events: 0, revents: 0),
                           pollfd(fd: engine, events: 0, revents: 0)]
            for pump in pumps where !pump.finished {
                if !pump.pending.isEmpty {
                    watched[pump.destination == client ? 1 : 2].events |= Int16(POLLOUT)
                } else if !pump.inputEnded {
                    watched[pump.source == client ? 1 : 2].events |= Int16(POLLIN)
                }
            }
            let result = poll(&watched, 3, timeout)
            if result < 0 {
                if errno == EINTR { continue }
                return .failed(.unexpected, nil, elapsedMilliseconds: elapsed())
            }
            if watched[0].revents != 0 { return .canceled }
            let failed = Int16(POLLHUP | POLLERR | POLLNVAL)
            for index in pumps.indices where !pumps[index].finished {
                let sourceReady = watched[pumps[index].source == client ? 1 : 2].revents & (Int16(POLLIN) | failed) != 0
                let destinationReady = watched[pumps[index].destination == client ? 1 : 2].revents & (Int16(POLLOUT) | failed) != 0
                do {
                    try step(&pumps[index], sourceReady: sourceReady, destinationReady: destinationReady)
                } catch {
                    return .failed(error as? GateFailure ?? .unexpected, pumps[index].direction, elapsedMilliseconds: elapsed())
                }
                if pumps[index].inputEnded && pumps[index].pending.isEmpty {
                    // A shutdown error cannot be put down to either copy (Windows logs `direction=unknown`).
                    guard shutdown(pumps[index].destination, SHUT_WR) == 0 || errno == ENOTCONN else {
                        return .failed(.io(errno), nil, elapsedMilliseconds: elapsed())
                    }
                    pumps[index].finished = true
                    if drainDeadline == nil { drainDeadline = .now + .seconds(drainTimeout) }
                }
            }
        }
        return .finished
    }

    /// Writes pending bytes when the destination is ready, otherwise reads more when the source is ready.
    private static func step(_ pump: inout Pump, sourceReady: Bool, destinationReady: Bool) throws {
        if !pump.pending.isEmpty {
            guard destinationReady else { return }
            let range = pump.pending
            let count = pump.buffer.withUnsafeBytes { write(pump.destination, $0.baseAddress! + range.lowerBound, range.count) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                throw GateFailure.io(errno)
            }
            pump.pending = (range.lowerBound + count)..<range.upperBound
        } else if !pump.inputEnded && sourceReady {
            let count = pump.buffer.withUnsafeMutableBytes { read(pump.source, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                throw GateFailure.io(errno)
            }
            if count == 0 { pump.inputEnded = true } else { pump.pending = 0..<count }
        }
    }
}
```

- [ ] **Adım 6: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 71 tests in 12 suites passed`, uyarısız ve `skipped` olmadan.

---

### Görev 4: Kapı

**Files:**
- Create: `macos/Tests/DiscordAccessKitTests/ProxyGateTests.swift`, `macos/Sources/DiscordAccessKit/Gate/ProxyGate.swift`

- [ ] **Adım 1: Testleri yaz** (`swift` bloğu 10)

Testler Windows'taki `ProxyTransportChecks.cs` ve `ProxyDiagnosticsChecks.cs` dosyalarını ve `MediaPolicyChecks.cs`'deki medya kabul düzeneğini izler. Sahte motor bu süreçte bir loopback portunda dinler ve Windows aktarım düzeneğinin kiplerini oynar:
- `N` 256 KiB yanıt verir; `C` istemci yarım kapatınca yanıt verir.
- `S` 1 KiB gönderip kendisi yarım kapatır; `H` istemci yarım kapatınca susar.
- `F` bağlantıyı sıfırlar; `K` kapı kapanana kadar bekler.

İstemci bu süreçtir (tanı izniyle kabul edilir) ya da bir `nc` alt sürecidir. Sınanan durumlar:
- iki yönde yarım kapama, 16 eşzamanlı bağlantı, boşaltma süresi, motor sıfırlaması ve kapanışta bağlantıların hemen bitmesi;
- kabul edilmeyen istemciye `403`, onaylı dosyayı çalıştırmayan istemci için `reason=NoHolder`, kapasite sınırı;
- politika reddinin tek satırla yazılması, ASCII olmayan ve bitmeyen başlık, başlık süresi;
- motora giden baytların politikanın gördükleriyle aynı olması: yeniden yazılan başlık ve ardından gelen ikili baytlar, tam 32 KiB'lik başlık, ayrı pakette gelen başlık sonu;
- motor kimliği: ucunu motorun PID'si tutmayan arka uca (launchd ya da bu sürecin bir alt süreci) ve denetimden önce ya da sonra çalışmayan motora tek bayt gitmez; bağlantıyı geç kabul eden motora aktarım olur;
- kapasite dolunca yeni bağlantının geri çevrilmesi ve boşalan yuvanın yeniden kullanılması;
- yalnız tam olarak 127.0.0.1'deki eşin eşleştirilmesi; başlamadan kapatılan kapının portunu bırakması; `close()` dönmeden dinleyicinin kapanması, kabul iş parçacığı o sırada yavaş bir tanı geri çağrısındayken bile.

```swift
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The gate end to end: a fake engine listens on a loopback port in this process, and the client is this process
/// (admitted through `diagnosticAllowed`) or a `/usr/bin/nc` child. Modelled on the Windows `ProxyTransportChecks.cs`,
/// `ProxyDiagnosticsChecks.cs` and the media admission fixture of `MediaPolicyChecks.cs`.
@Suite struct ProxyGateTests {
    static let payload = Array("transport-fixture-payload".utf8)
    static let pattern = (0..<(256 * 1024)).map { UInt8($0 % 251) }
    static let connect = Array("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\n\r\n".utf8)
    /// The fake engine's credential, `fake-engine:fixture-password`.
    static let authorization = "Basic ZmFrZS1lbmdpbmU6Zml4dHVyZS1wYXNzd29yZA=="
    static let netcat = ApprovedExecutable(path: "/usr/bin/nc", requirement: "identifier \"com.apple.nc\" and anchor apple")

    /// Values collected from other threads.
    final class Collected<Value> {
        private let lock = NSLock()
        private var values: [Value] = []

        func append(_ value: Value) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var all: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// The gate's diagnostic lines.
    final class Lines {
        let collected = Collected<String>()

        /// Whether a line holding every part arrives within 5 seconds.
        func contain(_ parts: String...) -> Bool {
            waitFor { collected.all.contains { line in parts.allSatisfy(line.contains) } ? true : nil } == true
        }

        /// No line holds the engine credential, the fixture payload or private fixture text.
        var arePrivate: Bool {
            collected.all.allSatisfy { line in
                ["ZmFrZS1lbmdpbmU", "fixture-password", "transport-fixture-payload", "PRIVATE_FIXTURE"].allSatisfy { !line.contains($0) }
            }
        }
    }

    /// An engine stand-in on a loopback port: each connection goes to `serve` on its own thread and is closed after it.
    final class FakeEngine: GateEngine {
        let pid: pid_t
        let port: UInt16
        let authorization = ProxyGateTests.authorization
        let accepted = Collected<Int32>()
        private let running: () -> Bool
        private let listener: Int32
        private let stop: (read: Int32, write: Int32)
        private let accepting = DispatchGroup()

        var isRunning: Bool { running() }

        /// `acceptDelay` holds back each accept, as an engine that accepts on its own schedule.
        init(pid: pid_t = getpid(), running: @escaping () -> Bool = { true }, acceptDelay: useconds_t = 0, serve: @escaping (Int32) -> Void) throws {
            self.pid = pid
            self.running = running
            stop = try LoopbackSocket.stopPipe()
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ready = descriptor >= 0 && fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 && withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, length) == 0 && listen(descriptor, 64) == 0 && getsockname(descriptor, $0, &length) == 0
                }
            }
            guard ready else {
                let error = lastPOSIXError()
                for unused in [descriptor, stop.read, stop.write] where unused >= 0 { close(unused) }
                throw error
            }
            listener = descriptor
            port = UInt16(bigEndian: address.sin_port)
            // The thread holds only what it uses, so releasing the engine stops it.
            let (stopRead, accepting, accepted) = (stop.read, accepting, accepted)
            accepting.enter()
            Thread {
                defer { accepting.leave() }
                while true {
                    var watched = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0), pollfd(fd: stopRead, events: Int16(POLLIN), revents: 0)]
                    if poll(&watched, 2, -1) < 0 && errno != EINTR { return }
                    if watched[1].revents != 0 { return }
                    if acceptDelay > 0 { usleep(acceptDelay) }
                    let connection = accept(descriptor, nil, nil)
                    guard connection >= 0 else { continue }
                    _ = fcntl(connection, F_SETFL, 0)
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    var noSignal: Int32 = 1
                    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    accepted.append(connection)
                    Thread {
                        serve(connection)
                        close(connection)
                    }.start()
                }
            }.start()
        }

        deinit {
            close(stop.write)
            accepting.wait()
            close(listener)
            close(stop.read)
        }
    }

    // MARK: Byte helpers, also used on the fake engine's threads (so they throw instead of recording issues).

    static func send(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw lastPOSIXError() }
                offset += count
            }
        }
    }

    /// Exactly `count` bytes, or nil when the stream ends or fails first.
    static func receive(_ descriptor: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let read = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + offset, count - offset) }
            if read < 0 && errno == EINTR { continue }
            guard read > 0 else { return nil }
            offset += read
        }
        return bytes
    }

    /// Everything until the end of the stream; what arrived before a failure.
    static func receiveAll(_ descriptor: Int32) -> [UInt8] {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return bytes }
            bytes += chunk[0..<count]
        }
    }

    /// A header up to and including CR LF CR LF, or nil when the stream ends first.
    static func receiveHeader(_ descriptor: Int32) -> [UInt8]? {
        var bytes: [UInt8] = []
        while bytes.count < 16384 {
            guard let next = receive(descriptor, count: 1) else { return nil }
            bytes += next
            if bytes.suffix(4).elementsEqual([13, 10, 13, 10]) { return bytes }
        }
        return nil
    }

    /// The Windows transport fixture: the fake engine answers the CONNECT, then acts out the mode the client sends first.
    /// `N` replies 256 KiB, `C` replies after the client half-closes, `S` sends 1 KiB and half-closes itself, `H` stays
    /// silent after the client half-closes, `F` resets the connection and `K` keeps it until the gate hangs up (and marks
    /// that it waits and that it saw the gate's close).
    static func transport(_ marks: Collected<String>) -> (Int32) -> Void {
        { connection in
            guard receiveHeader(connection) != nil, (try? send(connection, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))) != nil,
                  let mode = receive(connection, count: 1).map({ Unicode.Scalar($0[0]) }) else { return }
            if mode == "S" {
                try? send(connection, [UInt8](repeating: 0, count: 1024))
                shutdown(connection, SHUT_WR)
                if receive(connection, count: payload.count) == payload { marks.append("server-half") }
                return
            }
            guard receive(connection, count: payload.count) == payload else { return }
            switch mode {
            case "F":
                // The close after `serve` then resets the connection.
                var reset = linger(l_onoff: 1, l_linger: 0)
                setsockopt(connection, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
                return
            case "C", "H":
                guard receive(connection, count: 1) == nil else { return }
                if mode == "H" {
                    usleep(3_000_000)
                    return
                }
            case "K":
                marks.append("engine-waiting")
                var watched = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                // The gate's close reaches the engine as the end of the stream.
                if poll(&watched, 1, 10_000) == 1 && receive(connection, count: 1) == nil { marks.append("engine-saw-close") }
                return
            default:
                break
            }
            usleep(50_000)
            try? send(connection, pattern)
        }
    }

    // MARK: Gate and client helpers.

    /// A started gate in front of `engine` that admits this process while `diagnostic` is set.
    static func gate(_ engine: GateEngine, lines: Lines, approved: [ApprovedExecutable] = [netcat], diagnostic: Bool = true,
                     headerTimeout: TimeInterval = 5, drainTimeout: TimeInterval = 0.5, capacity: Int = ProxyGate.maxConnections) throws -> ProxyGate {
        let admission = try PeerAdmission(approved: approved, readyTime: Date())
        admission.diagnosticAllowed = diagnostic
        let gate = try ProxyGate(admission: admission, engine: engine, headerTimeout: headerTimeout, drainTimeout: drainTimeout,
                                 capacity: capacity, trace: lines.collected.append)
        gate.start()
        return gate
    }

    /// A connection from this process to the gate; reads give up after 5 seconds.
    static func dial(_ gate: ProxyGate) throws -> LoopbackClient {
        let client = try LoopbackClient(port: gate.port)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(client.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client.descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return client
    }

    /// Sends `request` from this process and returns everything the gate sends back.
    static func exchange(_ gate: ProxyGate, _ request: [UInt8]) throws -> [UInt8] {
        let client = try dial(gate)
        try send(client.descriptor, request)
        return receiveAll(client.descriptor)
    }

    /// A CONNECT through the gate that the fake engine answered, followed by `mode` (and the payload, except in `S`).
    /// The header goes in `parts`, sent 50 ms apart.
    static func open(_ gate: ProxyGate, mode: Unicode.Scalar, parts: [[UInt8]] = [connect]) throws -> LoopbackClient {
        let client = try dial(gate)
        for (index, part) in parts.enumerated() {
            if index > 0 { usleep(50_000) }
            try send(client.descriptor, part)
        }
        guard receiveHeader(client.descriptor) == Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8) else { throw POSIXError(.EPROTO) }
        try send(client.descriptor, [UInt8(mode.value)] + (mode == "S" ? [] : payload))
        return client
    }

    /// The length of the fake engine's reply; it must follow the fixture pattern when `verify` is set.
    static func reply(_ client: LoopbackClient, verify: Bool) throws -> Int {
        let bytes = receiveAll(client.descriptor)
        if verify && !bytes.elementsEqual(pattern.prefix(bytes.count)) { throw POSIXError(.EBADMSG) }
        return bytes.count
    }

    /// A whole request through the gate: modes `C` and `H` half-close after the payload.
    static func request(_ gate: ProxyGate, mode: Unicode.Scalar) throws -> Int {
        let client = try open(gate, mode: mode)
        if mode == "C" || mode == "H" { shutdown(client.descriptor, SHUT_WR) }
        return try reply(client, verify: true)
    }

    /// A gate that admits this process, on a port in `range` (outside the range the system hands out, 49152-65535) where
    /// nothing answered before, so no other test or process is given that port while the test runs.
    static func quietGate(_ range: Range<UInt16>, engine: GateEngine, capacity: Int = ProxyGate.maxConnections,
                          trace: ((String) -> Void)? = nil) throws -> ProxyGate {
        let admission = try PeerAdmission(approved: [netcat], readyTime: Date())
        admission.diagnosticAllowed = true
        let stop = try LoopbackSocket.stopPipe()
        defer {
            close(stop.read)
            close(stop.write)
        }
        for port in range {
            // A port that something answers on, or swallows connections on, is skipped.
            do {
                close(try LoopbackSocket.connect(port: port, until: .now + .milliseconds(200), stop: stop.read))
                continue
            } catch GateFailure.socket(let code) where code == ECONNREFUSED {
            } catch {
                continue
            }
            if let gate = try? ProxyGate(admission: admission, engine: engine, port: port, capacity: capacity, trace: trace) { return gate }
        }
        throw POSIXError(.EADDRINUSE)
    }

    static func settles(_ gate: ProxyGate) -> Bool {
        waitFor { gate.activeConnections == 0 ? true : nil } == true
    }

    // MARK: Transport (Windows `ProxyTransportChecks.cs`).

    @Test func relaysRepliesAndPassesHalfClosesOnInBothDirections() throws {
        let marks = Collected<String>()
        let engine = try FakeEngine(serve: Self.transport(marks))
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        #expect(try Self.request(gate, mode: "N") == Self.pattern.count)
        #expect(try Self.request(gate, mode: "C") == Self.pattern.count)
        // The engine half-closes first; what the client sends afterwards must still reach it.
        let client = try Self.open(gate, mode: "S")
        #expect(try Self.reply(client, verify: false) == 1024)
        try Self.send(client.descriptor, Self.payload)
        shutdown(client.descriptor, SHUT_WR)
        #expect(waitFor { marks.all.contains("server-half") ? true : nil } == true)
        #expect(lines.contain("Owned request discord.com:443"))
        #expect(lines.contain("Backend identity verified target=discord.com:443"))
        #expect(Self.settles(gate))
        #expect(lines.arePrivate)
    }

    @Test func relaysSixteenConnectionsAtOnce() throws {
        let engine = try FakeEngine(serve: Self.transport(Collected<String>()))
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        let lengths = Collected<Int>()
        let finished = DispatchGroup()
        for _ in 0..<16 {
            finished.enter()
            Thread {
                lengths.append((try? Self.request(gate, mode: "N")) ?? -1)
                finished.leave()
            }.start()
        }
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(lengths.all == Array(repeating: Self.pattern.count, count: 16))
    }

    @Test func boundsTheDrainAndNamesTheDirectionThatStalled() throws {
        let engine = try FakeEngine(serve: Self.transport(Collected<String>()))
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        let started = Date()
        #expect(try Self.request(gate, mode: "H") == 0)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(Self.settles(gate))
        #expect(lines.contain("Failure stage=Relay target=discord.com:443 category=Timeout direction=engine_to_client elapsed_ms="))
        #expect(lines.arePrivate)
    }

    @Test func namesTheSocketErrorAndDirectionOfAnEngineReset() throws {
        let engine = try FakeEngine(serve: Self.transport(Collected<String>()))
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        #expect(try Self.request(gate, mode: "F") == 0)
        #expect(Self.settles(gate))
        #expect(lines.contain("Failure stage=Relay target=discord.com:443 category=IO socket=ConnectionReset direction=engine_to_client elapsed_ms="))
        #expect(lines.arePrivate)
    }

    @Test func closingTheGateEndsItsConnectionsAtOnce() throws {
        let marks = Collected<String>()
        let engine = try FakeEngine(serve: Self.transport(marks))
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        let client = try Self.open(gate, mode: "K")
        #expect(waitFor { marks.all.contains("engine-waiting") ? true : nil } == true)
        let started = Date()
        gate.close()
        gate.close()
        #expect(try Self.reply(client, verify: false) == 0)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(waitFor { marks.all.contains("engine-saw-close") ? true : nil } == true)
        #expect(Self.settles(gate))
        // Ending connections on close is not a failure.
        #expect(!lines.collected.all.contains { $0.contains("stage=Relay") })
    }

    // MARK: Admission, header and policy (Windows `ProxyDiagnosticsChecks.cs`, `MediaPolicyChecks.cs`).

    @Test func answersAClientThatIsNotAdmittedWith403() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines, diagnostic: false)
        defer { gate.close() }
        let client = try Self.dial(gate)
        try Self.send(client.descriptor, Self.connect)
        #expect(Self.receiveAll(client.descriptor) == ProxyGate.forbidden)
        #expect(lines.contain("Failure stage=Ownership target=unknown category=UnownedClient reason="))
        #expect(engine.accepted.all.isEmpty)
    }

    /// A client that runs no approved executable is never inspected, so no process is found holding its connection.
    @Test func refusesAClientThatRunsNoApprovedExecutable() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let sleeper = ApprovedExecutable(path: "/bin/sleep", requirement: "identifier \"com.apple.sleep\" and anchor apple")
        let gate = try Self.gate(engine, lines: lines, approved: [sleeper])
        defer { gate.close() }
        let client = try startChild("/usr/bin/nc", ["-d", "127.0.0.1", String(gate.port)])
        defer {
            client.terminate()
            client.waitUntilExit()
        }
        #expect(lines.contain("Failure stage=Ownership target=unknown category=UnownedClient reason=NoHolder"))
        #expect(engine.accepted.all.isEmpty)
    }

    @Test func logsARefusedRequestWithOnlyItsStageTargetAndCategory() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        let request = "GET http://telemetry.example.invalid/PRIVATE_FIXTURE?token=PRIVATE_FIXTURE HTTP/1.1\r\nHost: telemetry.example.invalid\r\n" +
            "Authorization: PRIVATE_FIXTURE\r\n\r\n"
        #expect(try Self.exchange(gate, Array(request.utf8)) == [])
        #expect(lines.contain("Failure stage=RequestPolicy target=telemetry.example.invalid:80 category=ForbiddenHost"))
        #expect(lines.collected.all == ["Failure stage=RequestPolicy target=telemetry.example.invalid:80 category=ForbiddenHost"])
        #expect(engine.accepted.all.isEmpty)
    }

    @Test(arguments: [Array("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nUser-Agent: caf\u{E9}\r\n\r\n".utf8),
                      [UInt8](repeating: UInt8(ascii: "a"), count: 32_768)])
    func refusesAHeaderThatIsNotASCIIOrNeverEnds(request: [UInt8]) throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        #expect(try Self.exchange(gate, request) == [])
        #expect(lines.contain("Failure stage=HeaderRead target=unknown category=InvalidData"))
        #expect(engine.accepted.all.isEmpty)
    }

    @Test func closesAConnectionWhoseHeaderDoesNotArriveInTime() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines, headerTimeout: 0.3)
        defer { gate.close() }
        let started = Date()
        #expect(try Self.exchange(gate, []) == [])
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(lines.contain("Failure stage=HeaderRead target=unknown category=Timeout"))
    }

    /// The policy's view and the engine's view are the same bytes: the rewritten header, then whatever followed the
    /// header in the client's stream, unchanged (binary bytes included).
    @Test func forwardsTheRewrittenHeaderAndTheBytesAfterItUntouched() throws {
        let header = "CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nProxy-Authorization: Basic client-fixture\r\n\r\n"
        let tunnel: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0xFF, 0x0D, 0x0A, 0x0D, 0x0A, 0xC3, 0x28]
        let expected = Array(("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nProxy-Authorization: " + Self.authorization +
            "\r\n\r\n").utf8) + tunnel
        let received = Collected<[UInt8]>()
        let engine = try FakeEngine(serve: { connection in received.append(Self.receive(connection, count: expected.count) ?? []) })
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        // The client keeps its sending side open: only established connections are matched to their processes.
        #expect(try Self.exchange(gate, Array(header.utf8) + tunnel) == [])
        #expect(received.all == [expected])
    }

    /// A header of exactly 32 KiB is the longest the gate reads; the engine gets it rewritten with its credential.
    @Test func forwardsAHeaderOfExactly32KiB() throws {
        let frame = ("GET http://discord.com/", " HTTP/1.1\r\nHost: discord.com\r\n\r\n")
        let header = frame.0 + String(repeating: "a", count: 32_768 - frame.0.utf8.count - frame.1.utf8.count) + frame.1
        // Bytes, not Characters: Swift treats CR LF as one Character.
        let expected = Array(header.utf8.dropLast(2)) + Array(("Proxy-Authorization: " + Self.authorization + "\r\n\r\n").utf8)
        let received = Collected<[UInt8]>()
        let engine = try FakeEngine(serve: { connection in received.append(Self.receive(connection, count: expected.count) ?? []) })
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        #expect(header.utf8.count == 32_768)
        #expect(try Self.exchange(gate, Array(header.utf8)) == [])
        #expect(received.all == [expected])
    }

    /// The end of the header may arrive in a later packet than the rest of it.
    @Test func joinsAHeaderEndThatArrivesSeparately() throws {
        let engine = try FakeEngine(serve: Self.transport(Collected<String>()))
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        let client = try Self.open(gate, mode: "N", parts: [Array(Self.connect.dropLast(1)), [10]])
        #expect(try Self.reply(client, verify: true) == Self.pattern.count)
    }

    enum Backend: CaseIterable, Sendable {
        case launchd, otherProcess, stoppedEngine, engineStoppingDuringTheCheck
    }

    /// The media port exception must not bypass the engine identity: a backend whose end of the connection is not held
    /// by the engine's pid (launchd, whose descriptors cannot be read, or a child of this process, which holds no such
    /// connection), or an engine that is not running before or after the check, receives no byte at all.
    @Test(arguments: Backend.allCases)
    func sendsNothingToABackendThatIsNotTheRunningEngine(backend: Backend) throws {
        let other = try startChild("/bin/sleep", ["30"])
        defer {
            other.terminate()
            other.waitUntilExit()
        }
        let pid = backend == .launchd ? 1 : backend == .otherProcess ? other.processIdentifier : getpid()
        let reads = Collected<Int>()
        let running: () -> Bool = {
            reads.append(1)
            switch backend {
            case .stoppedEngine: return false
            // Running when the check starts, stopped when it ends.
            case .engineStoppingDuringTheCheck: return reads.all.count == 1
            case .launchd, .otherProcess: return true
            }
        }
        let received = Collected<[UInt8]>()
        let engine = try FakeEngine(pid: pid, running: running, serve: { connection in received.append(Self.receiveAll(connection)) })
        let lines = Lines()
        let gate = try Self.gate(engine, lines: lines)
        defer { gate.close() }
        let authority = "c-waw04-9501efbe.discord.media:2087"
        #expect(try Self.exchange(gate, Array(("CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\n\r\n").utf8)) == [])
        #expect(lines.contain("Failure stage=BackendIdentity target=" + authority + " category=InvalidData"))
        #expect(waitFor { received.all.isEmpty ? nil : true } == true)
        #expect(received.all == [[]])
    }

    @Test func turnsAwayConnectionsBeyondItsCapacity() throws {
        let engine = try FakeEngine(serve: { _ in })
        let lines = Lines()
        // A long header timeout keeps the admitted clients in their slots however slowly the next one starts.
        let gate = try Self.gate(engine, lines: lines, headerTimeout: 60, capacity: 2)
        defer { gate.close() }
        // Two netcat clients are admitted and wait with their headers unsent; a refused one would give its slot back.
        var clients = try (0..<2).map { _ in try startChild("/usr/bin/nc", ["-d", "127.0.0.1", String(gate.port)]) }
        defer {
            for client in clients {
                client.terminate()
                client.waitUntilExit()
            }
        }
        #expect(waitFor { gate.activeConnections == 2 ? true : nil } == true)
        let third = try Self.dial(gate)
        #expect(Self.receiveAll(third.descriptor) == [])
        #expect(lines.contain(GateDiagnostics.capacityFailure))
        #expect(gate.activeConnections == 2)
        // A slot that frees up is used again.
        let leaving = clients.removeFirst()
        leaving.terminate()
        leaving.waitUntilExit()
        #expect(waitFor { gate.activeConnections == 1 ? true : nil } == true)
        clients.append(try startChild("/usr/bin/nc", ["-d", "127.0.0.1", String(gate.port)]))
        #expect(waitFor { gate.activeConnections == 2 ? true : nil } == true)
    }

    /// The engine accepts on its own schedule: the gate waits up to a second for the engine's end of the connection.
    @Test func relaysThroughAnEngineThatAcceptsLate() throws {
        let engine = try FakeEngine(acceptDelay: 300_000, serve: Self.transport(Collected<String>()))
        let gate = try Self.gate(engine, lines: Lines())
        defer { gate.close() }
        #expect(try Self.request(gate, mode: "N") == Self.pattern.count)
    }

    @Test func matchesOnlyPeersAtExactly127001() {
        var peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = UInt16(40_000).bigEndian
        peer.sin_addr.s_addr = inet_addr("127.0.0.1")
        #expect(LoopbackSocket.loopbackPeerPort(peer) == 40_000)
        peer.sin_addr.s_addr = inet_addr("127.0.0.2")
        #expect(LoopbackSocket.loopbackPeerPort(peer) == nil)
        peer.sin_addr.s_addr = inet_addr("127.0.0.1")
        peer.sin_family = sa_family_t(AF_INET6)
        #expect(LoopbackSocket.loopbackPeerPort(peer) == nil)
    }

    @Test func aGateClosedBeforeItStartsReleasesItsPort() throws {
        let engine = try FakeEngine(serve: { _ in })
        let gate = try Self.quietGate(20_000..<20_200, engine: engine)
        gate.close()
        gate.start()
        // A child that another test is spawning may hold a copy of the listener until it executes.
        #expect(waitFor {
            do {
                _ = try LoopbackClient(port: gate.port)
                return nil
            } catch {
                return error as? POSIXError == POSIXError(.ECONNREFUSED) ? true : nil
            }
        } == true)
    }

    /// `close()` returns only once the listener is closed, even while the accept thread is busy (here in a slow
    /// diagnostic callback), so a new gate can take the port at once (Windows `Dispose`). Only this process's descriptors
    /// are inspected: a child that another test is spawning may briefly hold a copy of the listener.
    @Test func closingAStartedGateClosesItsListenerBeforeReturning() throws {
        let engine = try FakeEngine(serve: { _ in })
        let busy = DispatchSemaphore(value: 0)
        let gate = try Self.quietGate(22_000..<22_200, engine: engine, capacity: 1, trace: { line in
            guard line == GateDiagnostics.capacityFailure else { return }
            busy.signal()
            usleep(300_000)
        })
        gate.start()
        let first = try Self.dial(gate)
        #expect(waitFor { gate.activeConnections == 1 ? true : nil } == true)
        let second = try Self.dial(gate)
        #expect(busy.wait(timeout: .now() + 5) == .success)
        gate.close()
        #expect(ProcessInspector.tcpSockets(of: getpid())?.contains { $0.listening && $0.localPort == gate.port } == false)
        // The first connection ended with the close: refused with a 403 if its admission was still running (one that
        // finishes after `close()` does not count), otherwise while it waited for its header.
        let rest = Self.receiveAll(first.descriptor)
        #expect(rest == [] || rest == ProxyGate.forbidden)
        withExtendedLifetime(second) {}
    }
}
```

- [ ] **Adım 2: Testi çalıştır, başarısız olduğunu gör**

Run: `swift test --package-path macos`
Expected: Derleme hatası: `cannot find 'ProxyGate' in scope`, `cannot find type 'ProxyGate' in scope` ve `cannot find type 'GateEngine' in scope`.

- [ ] **Adım 3: Kapıyı yaz** (`swift` bloğu 11)

Akış (Windows `ProcessGate.Handle`):
1. Kabul döngüsü kendi iş parçacığında çalışır. Sınır doluysa bağlantı kapatılır ve `Capacity` satırı yazılır. Her bağlantı kendi iş parçacığında işlenir; eş denetimi kabul döngüsünü bekletmez.
2. Uzak adres tam olarak 127.0.0.1 olmalı ve `PeerAdmission` bağlantıyı kabul etmelidir. Reddedilen istemciye `403 Forbidden` gider. Kabulün sonucu `close()` ile çakışırsa kapının kendi durumu karar verir.
3. Başlık `headerTimeout` içinde okunur ve `RequestPolicy`'den geçer.
4. Motora 5 sn içinde bağlanılır. Motor çalışıyor olmalı, bağlantının ucunu motorun PID'si tutmalı ve motor hâlâ çalışıyor olmalıdır; bu uç en fazla 1 sn beklenir. Yalnız motorun tanıtıcıları incelenir. Doğrulanmamış bir arka uca tek bayt gönderilmez.
5. Yeniden yazılan başlık ve kalan baytlar 5 sn içinde yazılır, ardından `Relay` çalışır.
6. `close()` durdurma borusunun yazma ucunu kapatır ve bütün beklemeler hemen biter. Hiçbir iş parçacığı başkasının tanıtıcısını kapatmaz; dinleyiciyi kabul iş parçacığı kapatır (kapı hiç başlamadıysa `close()`). `close()` dinleyici kapanana kadar bekler; döndüğünde port boştur (Windows `Dispose`). Kabul iş parçacığı o sırada `trace` içinde olabileceği için `close()`, `trace`'in beklediği bir kilit ya da kuyruk tutulurken çağrılmamalıdır. Kapanıştan sonraki hatalar yazılmaz.

`trace` ve `faulted`, kapının iş parçacıklarından eşzamanlı çağrılır; biten bağlantılar `close()` döndükten kısa süre sonra da `trace` çağırabilir. Kabul sırasında beklenmeyen bir hata (örneğin `EMFILE`) kapıyı kapatır: önce dinleyici kapanır, sonra `faulted` çağrılır (Windows da `Faulted`'dan önce dinleyiciyi durdurur), böylece işleyici aynı portta hemen yeni bir kapı kurabilir. Kabul iş parçacığına zayıf başvuru tutulur; iş parçacığının bloğu kapıyı tuttuğu için güçlü başvuru ikisini de sonsuza dek ayakta tutardı. `close()` ile çakışan eş kabulü ve kabul hatası testle oluşturulamaz; incelemeyle doğrulandı. Motor sahte olduğu ve bu süreçte çalıştığı için kimlik denetimindeki port sırası testle ayırt edilemez; sıra ters olursa her bağlantı reddedilir, yani hata güvenli tarafa düşer.

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
    private let faulted: (() -> Void)?
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

- [ ] **Adım 4: Testleri çalıştır, geçtiğini gör**

Run: `swift test --package-path macos`
Expected: `✔ Test run with 90 tests in 13 suites passed`, uyarısız ve `skipped` olmadan. Ardından `pgrep -fl "nc -d|sleep 30"` hiçbir şey yazmaz.

---

### Görev 5: Son doğrulama ve teslim

- [ ] **Adım 1: Bütün testler**

Run: `swift test --package-path macos && python3 -B macos/Tests/build-engine.test.py`
Expected: `✔ Test run with 90 tests in 13 suites passed`, ardından `Ran 35 tests` ve `OK`. Swift çıktısında `skipped` geçmez. Swift takımı iki kez daha çalıştırılır; geride `nc`, `sleep 30` ya da `sing-box` süreci kalmaz.

- [ ] **Adım 2: Tasarım belgesine durum notu**

`macos/docs/2026-10-14-macos-tasarim.md` Bölüm 11'de, **1b durumu** satırının altına şu satır eklenir:

`- **1c durumu:** Tamamlandı (kapının ağ katmanı; eş araması yalnız adaylarda). Plan: macos/docs/plans/2026-10-14-asama-1c-kapi-ag-katmani.md.`

- [ ] **Adım 3: Git durumu ve commit sorusu**

Run: `git status --porcelain --untracked-files=all; git diff --name-only main -- . ':!macos'`
Expected: ikinci komut hiçbir şey yazmaz; durum yalnız `macos/` altındaki dosyaları gösterir.

Kullanıcıya değişen dosyalar, yapılan ve yapılmayan kontroller raporlanır, commit isteyip istemediği sorulur. İsterse:

```bash
git add macos/Sources macos/Tests macos/docs
git commit -m "feat(macos): add the gate network layer and limit peer lookup to Discord processes"
```
