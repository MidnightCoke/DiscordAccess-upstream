# DiscordAccess macOS tasarımı

Tarih: 2026-10-14 · Dal: `feature/macos` · Durum: tasarım onaylandı; sonraki adım uygulama planı.

## 1. Amaç

Windows v4.22 akışının macOS karşılığını yapmak. Kullanıcı açısından akış aynıdır; yalnız işletim sistemi mekanizmaları değişir.

İlk hedef, bu Mac'te (Apple Silicon, macOS 27) kaynaktan derlenen ve gerçek engelli ağda canlı doğrulanan sürümdür. Tasarım, sonraki herkese açık yayına uygun kurulur. İmza, notarization ve paketleme Aşama 3'tedir.

Uygulama yerel Swift ile yazılır. sing-box motoru, `engine-patches/` yamaları ve ek dosyası kancası (`bridge/attachment-download.cjs`) iki platformda ortaktır.

## 2. Değişmez kısıt: Windows tarafı korunur

- Mac'e ait her dosya `macos/` altındadır. `macos/` dışında hiçbir dosya eklenmez, değiştirilmez veya silinmez.
- Ortak girdiler yalnız okunur: `bridge/attachment-download.cjs`, `engine-patches/http-limits/` (manifest ve `source/`), `engine-build/go.mod`, `engine-build/go.sum`.
- Mac'e özgü motor kaynak değişikliği bu tasarımın kapsamında değildir. Gerekirse ayrı karar ve inceleme ister.
- Commit, push ve PR yalnız kullanıcının açık isteğiyle yapılır.

Gerekçeler (depodaki kanıt):

| Kanıt | Sonuç |
| --- | --- |
| `Test.cmd` `src\*.cs`, `Build.cmd` `build-production.rsp` listesini derler. | `src/` altına dosya eklenmez. |
| `scripts/ReleaseChecks.py`, `engine-patches/http-limits/source/` altında bildirilmemiş dosyayı reddeder; Windows motor hash'i bu girdilere bağlıdır. | Yamalar ve manifest değişmez. |
| `scripts/Build-SecurityEngine.ps1` hash'i `licenses/engine-source-manifest.json` içinde sabittir. | Mac motoru ayrı betikle derlenir. |
| `docs/OKU-BENI.txt`, Windows hazır paketine girer (`scripts/Package-Release.py`). | Mac belgeleri `macos/docs/` altındadır. |
| Yayın betiği (`exact_head`), Git dışı bırakılmamış izlenmeyen dosya varsa durur. | Mac çıktıları `macos/.gitignore` ile Git dışında tutulur. |

Her aşamanın sonunda `git status --porcelain` ve `git diff --name-only main` çıktısında yalnız `macos/` altındaki yollar görünür.

## 3. Tasarımın dayandığı bulgular

Bu Mac'teki kurulumdan ve Discord'un kendi kodundan (`app.asar`) okunmuştur.

- **Kurulum:** `/Applications/Discord.app` 0.0.397, bundle id `com.hnc.Discord`, Team ID `53Q6R32WPB` (Discord, Inc.), hardened runtime, evrensel ikili, Electron 37.6.0. `Info.plist` içinde `NSAllowsArbitraryLoads = true` vardır.
- **Güncelleyici (Aşama 0'da düzeltildi):** 0.0.397'nin kodu `USE_NEW_UPDATER` ayarını macOS'ta varsayılan olarak kapalı okuyordu. Ama bu Mac'te ayar `true` idi ve Discord, Windows'takiyle aynı yeni yerel güncelleyiciyi (`updater.node`) kullanıyordu. 0.0.415'te bu ayar `OBSOLETED_SETTINGS` listesinde; yeni güncelleyici macOS'ta da tek güncelleyici. Mac'teki güncelleme ve modül düzeni artık Windows'la aynı.
- **Yeni güncelleyicinin ağ davranışı:** `NEW_UPDATE_ENDPOINT` (varsayılan `https://updates.discord.com/`) üzerinden manifest alır ve kendi HTTPS istemcisiyle indirir. Bu istemci Chromium proxy'sine uymaz. Engelli ağda "The certificate was not trusted" hatasıyla düşer (güncelleyici kaydı, 2026-09-23); Discord bu Mac'te Temmuz'dan beri güncellenememişti.
- **Ana uygulama güncellemesi:** Güncelleyici yeni sürümü `app-<sürüm>/Discord.app` içine indirir ve ShipIt ile `/Applications/Discord.app` yerine kurar.
- **Eski güncelleyici (artık kullanılmıyor):** Squirrel.Mac ile sistem ağına gidiyordu. Denetim başarısız olursa açılış ekranı 10–60 saniye aralıkla sonsuza kadar yeniden deniyor ve ana pencereyi açmıyordu (0.0.397 kodu).
- **`chromiumSwitches`:** `settings.json` içindeki bu ayar yalnız anahtar adlarını uygular, değer geçirmez. `--proxy-server` bu yolla verilemez.
- **Çekirdek modül:** `requireNative("discord_desktop_core")` ile yüklenir ve hemen ardından `core.startup(...)` çağrılır. Dosya yolu Windows'takiyle aynı biçimdedir: `~/Library/Application Support/discord/app-<sürüm>/modules/discord_desktop_core-<N>/discord_desktop_core/index.js`.
- **Diğer uygulamaların verisi (TCC):** Discord'un veri klasörü `com.apple.macl` ile etiketlidir. macOS, başka bir uygulamanın bu klasörü okumasını `kTCCServiceSystemPolicyAppDataDetailed` ile engeller ve izin penceresi göstermez. Bu kural Claude için de, Apple'ın kendi Terminal uygulaması için de geçerliydi. Tam Disk Erişimi verilen Terminal klasöre erişebildi. Terminal'in oluşturduğu `DiscordAccess-spike` klasörü ise etiketsizdi.
- **Ağ:** Bu ağda `discord.com`, Türk Telekom engel adresine (195.175.254.2) çözülür ve HTTPS bağlantısı kurulamaz. Canlı doğrulama burada yapılabilir.
- **Araçlar:** Xcode 27, Swift 6.4 ve macOS 27.0.1 arm64 hazırdır. Go ve .NET kurulu değildir; motor derleme betiği sabit Go araç zincirini kendisi indirir.

### Aşama 0 sonuçları (2026-10-14, Discord 0.0.397 → 0.0.415)

Ayrıntılı kanıtlar Git dışındaki `macos/work/` klasöründedir. Gerçek hesapla yapılan kontroller kullanıcı tarafından ekranda doğrulanmıştır.

| Kontrol | Sonuç |
| --- | --- |
| Motor derlemesi (darwin/arm64) | SHA-256 `013ba5d5055988953ebec1a1ac0eceb8aead52415e3ef186a5c7481083472cb0`, 33.315.362 bayt, cdhash `344f8bd088ce068a1745cf16e7bb0c9a4bbbe99e`, ad-hoc imza. Go bağlayıcısı tanımlayıcıyı `a.out` olarak yazar. |
| Tekrarlanabilirlik | İki bağımsız derleme (temiz modül ve derleme önbelleğiyle) byte düzeyinde aynı. |
| Yamaların Go testleri | `httpguard`, `protocol/http`, `common/listener`: üçü de `ok`. |
| 6 DNS yapılandırması | 6/6 motorun `check` komutundan geçti. |
| Kapı üzerinden API | `/api/v10/gateway` → `{"url":"wss://gateway.discord.gg"}`; `example.com` → 403. |
| Köprü | Eski Squirrel beslemesi ve yeni güncelleyici manifesti 200 döndü. Manifestteki 35 indirme adresinin hepsi köprüye yazıldı; hedef alan yalnız `stable.dl2.discordapp.net`. |
| Ana uygulama güncellemesi | Gerçek güncelleme köprüden geçti: 16 indirme, yaklaşık 240 MB, hata yok. ShipIt kurdu. Discord 0.0.415 olarak açıldı; imza resmi (`com.hnc.Discord`, `53Q6R32WPB`). |
| Deney A (argümanla açılış) | Hesap yüklendi, mesaj ve resim gönderildi. Ek dosyası indirme tarayıcıya gitti (Windows'taki kanca gerekli). |
| Eş kimliği | Kapıya bağlı 10 soketin hepsi `Discord Helper.app` sürecine ait; imza `com.hnc.Discord.helper`, Team ID gereksinimi geçti. 493 süreç 1 ms'de tarandı. |
| Deney B (Dock, sarmalayıcı) | `open -a` ile ve gerçek Dock tıklamasıyla iki açılışta da sarmalayıcı proxy'yi uyguladı (`PROXY 127.0.0.1:<kapı>;DIRECT`). Kapıdan `gateway.discord.gg` geçti, kullanıcı mesajları gördü. |
| Kapının reddettikleri | `api.spotify.com`, `dealer.spotify.com`, `*.dc-telemetry.net`. Windows izin listesiyle aynı davranış; Discord içindeki Spotify bağlantısı çalışmaz. |
| Geri alma | Sahiplenilen anahtarlar özgün durumuna döndü; çekirdek giriş dosyası hash doğrulamasıyla resmi haline döndü. `USE_NEW_UPDATER` anahtarını Discord 0.0.415 kendisi kaldırdı. |
| Profil erişimi | Discord'un veri klasörüne yalnız Tam Disk Erişimi verilen Terminal'den erişilebildi (bkz. TCC bulgusu). |

## 4. Kullanıcı akışı

1. Discord'u tamamen kapatın.
2. `DiscordAccess.app`'i açın; "bağlantı hazır" bildirimini bekleyin.
3. Discord'u kendi simgenizden (Dock, Launchpad, Spotlight) açın. Mevcut kurulum ve hesap kullanılır; kopya oluşturulmaz.
4. Çıkarken önce Discord'u kapatın, sonra menü çubuğundan **Çıkış**'ı seçin.

Kullanıcının fark edeceği farklar:

- Simge tepside değil, menü çubuğundadır.
- Discord'un kendi giriş öğesi programla okunamaz ve devralınamaz. "Girişte Discord'u da aç" tercihi DiscordAccess menüsündedir; Discord'un kendi giriş öğesi kapatılmalıdır.
- Windows'taki "güvensiz klasördeki paketi kişisel klasöre kopyalama" yerine uygulama Applications klasörüne taşınır.
- "Kendi simgenden aç" deneyimi aynıdır ama yöntem farklıdır (bkz. 7.2). Aşama 0'da doğrulandı.
- İlk açılışta DiscordAccess için bir kerelik **Tam Disk Erişimi** izni gerekir. macOS, Discord'un veri klasörünü diğer uygulamalara karşı koruyor ve izin penceresi göstermiyor (bkz. 3, TCC bulgusu). Uygulama izni kendisi açmaz; gerekçesini açıklar ve Sistem Ayarları'ndaki ilgili sayfayı açar.

## 5. Windows → macOS eşlemesi

| Windows v4.22 | macOS |
| --- | --- |
| Tepside `DiscordAccess.exe` | Menü çubuğunda `DiscordAccess.app` (`LSUIElement`, Dock simgesi yok). Menü: Discord'u aç, Yeniden bağlan, Bağlantıyı kontrol et, Oturum açılışında başlat, Girişte Discord'u da aç, Çıkış. |
| sing-box `1.14.3-discordaccess.2`, sabit hash | Aynı kaynak commit'i, Go sürümü ve yamalar; `darwin/arm64` için derlenir; ayrı sabit hash ve cdhash. |
| Bellekte üretilen motor yapılandırması | Birebir aynı politika (DoH, IPv4, kimlik doğrulamalı HTTP girişi, TLS kayıt parçalama, kurallar ve son `reject`). |
| `ProcessGate` | Aynı politika; eş süreç tespiti libproc ile, kimlik Discord Team ID imzasıyla. |
| `.lnk` kısayollarına proxy argümanı | Çekirdek sarmalayıcısı oturum proxy'sini çalışma anında uygular; "Discord'u aç" ayrıca argümanla açar. |
| `UpdateBridge` (native güncelleyici) | Aynı köprü. Mac'te de aynı yerel güncelleyici kullanıldığı için manifest ve indirme yeniden yazma kuralları birebir aynı; Aşama 0'da gerçek güncellemeyle doğrulandı. |
| `%LOCALAPPDATA%\Discord` dosyalarına doğrudan erişim | `~/Library/Application Support/discord` için Tam Disk Erişimi gerekir (TCC). İzin yoksa profil değişikliği yapılmaz, kullanıcı yönlendirilir. |
| Ek dosyası kancası | Aynı dosya, değişmeden. |
| Run kaydı ve Discord Run kaydı koordinasyonu | SMAppService giriş öğesi; Discord'u açma tercihi DiscordAccess'te. |
| Özel ad alanı, mutex, dosya kilidi | Kullanıcıya özel klasörde `flock` kilidi ve Unix kontrol soketi. |
| ACL ve üst klasör güveni, kişisel paket kopyası | POSIX sahiplik/izin ve macOS ACL denetimi; güvensiz veya translocated konumda başlangıç kaydı kurulmaz, Applications'a taşıma istenir. |
| `WinVerifyTrust` + "Discord Inc." | Security.framework: `anchor apple generic and certificate leaf[subject.OU] = "53Q6R32WPB"` ve bundle id. |
| `GetExtendedTcpTable` | libproc (`proc_pidfdinfo`, `PROC_PIDFDSOCKETINFO`). |
| Job nesnesi | Yok; motor alt süreç olarak izlenir, çökme sonrası yetim motor bir sonraki açılışta temizlenir. |
| Yönetici olarak çalıştırma reddi | root (`geteuid() == 0`) reddi. |
| `--console`, `--restore`, `--discord-path`, `--dns=…`, `--dns-record-fragment`, `--verify-package`, `--help` | Aynı seçenekler; Terminal'den `DiscordAccess.app/Contents/MacOS/DiscordAccess`. |

Değişmeyen ilkeler: genel proxy/DNS/yönlendirme ayarı, TUN, ağ uzantısı, sürücü veya yönetici gereksinimi eklenmez; `Discord.app` paketi değiştirilmez; normal Discord süreci kapanışta öldürülmez; elle açılışta Discord kendiliğinden başlatılmaz.

## 6. Mimari

```
macos/
  .gitignore                 .build/, build/, work/
  Package.swift              SwiftPM, Swift 6.4, macOS 13 hedefi, ilk aşamada arm64
  Sources/DiscordAccessKit/  arayüzsüz, test edilebilir çekirdek
  Sources/DiscordAccess/     menü çubuğu uygulaması ve Terminal girişi
  Tests/DiscordAccessKitTests/  Swift testleri
  Tests/build-engine.test.py   derleme betiğinin çevrimdışı testleri
  Tests/wrapper.test.cjs       üretilen sarmalayıcının Node testi (sahte Electron)
  Resources/                 Info.plist, simge, giriş öğesi tanımı
  scripts/build-engine.py    sabit Go, kaynak ve yamalarla macOS motoru; hash doğrulaması
  scripts/build-app.sh       .app paketini build/apps.noindex/<zaman>/ altına kurar (Spotlight listelemez); motoru ve kancayı gömer
  docs/                      bu tasarım, kullanım ve güven sınırları
```

Bütün testler `Tests/` altındadır; ayrı bir `tests/` klasörü yoktur. macOS'un varsayılan diski büyük/küçük harf ayırmadığı için `tests/` ile SwiftPM'in `Tests/` klasörü aynı klasör olur.

### DiscordAccessKit bileşenleri

| Bileşen | Sorumluluk | Windows karşılığı |
| --- | --- | --- |
| EngineConfig | Motor yapılandırmasını bellekte üretir. | `Package.Config` |
| EngineProcess | Motoru hash ile doğrular, askıda başlatıp cdhash'ini denetler, rastgele kimlik bilgisiyle sürdürür; dinleyicinin motora ait olduğunu denetler. | `DnsConnection`, `TcpOwner.OwnsListener` |
| DnsSelection | Otomatik DoH seçimi: cloudflare-ip → cloudflare → google. | `DnsOptions`, `DnsSelection` |
| ProxyGate | Eş kimliği, alan adı ve başlık politikası; motor kimlik bilgisini ekler; motor kimliğini doğrular. | `ProcessGate` |
| PeerIdentity | Soket → PID, başlangıç zamanı, kullanıcı, yürütülebilir dosya ve kod imzası. | `TcpOwner.Find`, `ExternalDiscordScope`, `TrustedImage` |
| UpdateBridge | Yerel güncelleme köprüsü; manifest ve yönlendirme adreslerini köprüye yazar. | `UpdateBridge` |
| DiscordInstallation | `Discord.app`'i bulur ve doğrular; hatırlanan yol ve `--discord-path`. | `DiscordInstallation`, `DiscordPathOptions` |
| DiscordProfileChanges | `settings.json`'daki iki anahtar ve çekirdek sarmalayıcısı; günlüklü değiştirme ve geri alma. | `InstalledDiscord`, `FileTransaction` |
| Launcher | Discord'u Launch Services ile (`/usr/bin/open`) argümanlı açar (1g). | `ResidentController` açma yolu |
| ResidentInstance | Tek oturum kilidi ve kontrol soketi. | `ResidentInstance`, `ManualLaunchSignal` |
| StartupRegistration | Giriş öğesi ve konum güveni. | `StartupCoordinator`, `StartupPathTrust`, `StartupPackage` |
| Connectivity | Anonim Gateway HELLO tanısı. | `ConnectivityChecks` |
| StateStore | `~/Library/Application Support/DiscordAccess` (0700), kayıtlar, kurtarma günlüğü. | `Safety.EnsureStateDirectory`, `SessionLog`, `PrivateFileTrust` |

### Uygulama katmanı

| Bileşen | Sorumluluk | Windows karşılığı |
| --- | --- | --- |
| MenuBarController | Menü, durum metni, bildirimler. | `TrayHost` |
| SessionController | Oturum yaşam döngüsü (7.1); 1g'de Kit içinde yazıldı, menü çubuğu da onu kullanır. | `BackgroundLifecycle`, `ResidentController` |
| CommandLine | Terminal modları ve seçenek ayrıştırma (1g: Kit'te `CommandOptions`, `ConsoleSession`, `ConsoleProgram`). | `ConsoleHost`, `ConsoleDownload`, `ResidentOptions` |

## 7. Veri akışı

### 7.1 Oturumun açılması

1. Ön denetimler:
   - root ise durulur.
   - Tek oturum kilidi alınır. Kilit başka oturumdaysa ona durum isteği gönderilip çıkılır. 1g'de Terminal'deki ikinci örnek yalnız uyarı verip çıkar; durum isteği kontrol soketiyle Aşama 2'de gelir.
   - Bekleyen kurtarma günlüğü varsa ve Discord kapalıysa önce geri alma yapılır.
   - `Discord.app` bulunur ve imzası doğrulanır.
   - Discord açıksa profil değişikliği yapılmaz. Süreç listesi eksiksiz okunamazsa Discord açık sayılır (DSC-E04); başka bir konumdaki Discord kopyaları da sayılır (1f). 1g'den beri Discord'un ana ya da yardımcı dosyasını çalıştıran, adı değiştirilmiş bir uygulama da sayılır. Okunamayan ama yaşayan bir süreç de, çekirdek onu Discord olarak adlandırıyorsa sayılır (Windows `Unknown` gözlemini engel sayar).
   - Discord veri klasörüne erişim (Tam Disk Erişimi) denetlenir. İzin yoksa profil değişikliği yapılmaz; kullanıcıya gerekçe gösterilir ve ilgili Sistem Ayarları sayfası açılır.
2. DNS seçimi: Adaylar sırayla denenir. Her aday için motor ve kapı açılır; kapı üzerinden Discord Gateway API'sine (`https://discord.com/api/v10/gateway`) HTTPS isteği yapılır ve yanıtın Gateway adresi olduğu doğrulanır (Windows `CheckDnsCandidate`). Başarılı aday oturuma alınır; başarısız aday, sıradaki açılmadan önce tamamen kapatılır. Kullanıcı bir sağlayıcı adlandırdıysa (`--dns=…`) denetim yapılmaz. Anonim Gateway WebSocket HELLO tanısı "Bağlantıyı kontrol et" ile yapılır.
3. Güncelleme köprüsü rastgele port ve gizli yol belirteciyle başlar.
4. Profil değişiklikleri (günlüklü):
   - `settings.json` → `UPDATE_ENDPOINT = <köprü>/legacy`, `NEW_UPDATE_ENDPOINT = <köprü>/updates/`.
   - `discord_desktop_core/index.js` → oturum sarmalayıcısı (7.2).
   - Kurulu sürümün (`build_info.json`) bütün çekirdek nesilleri sarılır: `app-<sürüm>/modules/discord_desktop_core-<N>`, en fazla 16. Her giriş dosyası Discord'un kendi girişi ya da günlüğü kaybolmuş eski bir sarmalayıcı olmalıdır; başka içerik PRF-E02, eksik modül PRF-E03 verir (1f).
   - Her değişiklik önce durum klasöründeki günlüğe yazılır (`installed-session/journal.json`). Geri alma ve bir sonraki açılıştaki kurtarma yalnız hâlâ DiscordAccess'e ait olanı geri koyar; kullanıcının ya da bir güncellemenin değiştirdiği değer yerinde kalır ve PRF-E01 ile bildirilir, günlük korunur (Windows `InstalledDiscord`).
5. Hazır bildirimi gösterilir. Açılış oturum girişindeyse ve "Girişte Discord'u da aç" açıksa Discord bir kez açılır.

### 7.2 Discord açıldığında

**Güncelleme denetimi**
- Yeni yerel güncelleyici `NEW_UPDATE_ENDPOINT` üzerinden köprüye gider. `UPDATE_ENDPOINT`, Windows'taki gibi eski güncelleyici için ayrıca yönlendirilir. Köprü loopback'tedir, proxy gerekmez.
- Köprü istemcinin kabul edilen Discord süreci olduğunu doğrular ve isteği kapı → motor üzerinden iletir.
- Yol eşlemesi Windows'takiyle aynıdır:
  - `/legacy…` → `https://discord.com/api…`
  - `/updates/…` → `https://updates.discord.com/…`
  - `/download/<alan>/…` → `https://<alan>/…` (alan, `ProcessGate.AllowedDomains` kapsamında olmalı)
- Manifest ve yönlendirmedeki indirme adresleri köprüye yeniden yazılır. Ana uygulama güncellemesini ShipIt kurar; Discord'un imzasını kendisi doğrular. Aşama 0'da 0.0.397 → 0.0.415 güncellemesiyle doğrulandı.
- Köprünün sınırları Windows'takiyle aynıdır (1e):
  - en fazla 16 bağlantı; başlık en fazla 16 KiB ve 10 sn içinde gelir;
  - yalnız gövdesiz GET ve HEAD; istemcinin başlıkları Discord'a iletilmez;
  - istek başına toplam 180 sn, indirme dahil; URLSession'ın iki paket arasındaki sınırı 30 sn (Windows ilk yanıtı 180 sn bekler; burada ilk bayt da 30 sn içinde gelmelidir);
  - manifest en fazla 4 MiB ve 64 düzey.
- İstekler URLSession'la kapı üzerinden gider. Kapı onları bu sürecin tanı izniyle kabul eder (1d). İndirme URLSession delegesiyle akar: delege istemciye yazarken URLSession okumayı bekletir. Bu Mac'te yavaş bir tüketiciyle 600 MB'lık aktarımda bellek yaklaşık 12 MB'ta kaldı.
- 1e canlı doğrulaması (2026-10-15, bu Mac'in engelli ağı): eski güncelleyicinin beslemesi, yeni güncelleyicinin manifesti ve bir indirmenin HEAD isteği köprü, kapı ve motor üzerinden geçti. Manifestteki 35 adresin hepsi köprüye yazıldı. Yeni güncelleyicinin manifest isteği `arch` parametresi olmadan `400` alır. İlk denemede manifest isteği 30 sn içinde yanıt almadı (nedeni belirlenemedi; köprü bu durumda zaman aşımıyla 502 döndürür); sonraki bütün denemeler 2 sn içinde geçti.

**Proxy'nin uygulanması**
- Menüdeki "Discord'u aç" şu argümanlarla açar: `--proxy-server=http://127.0.0.1:<kapı> --proxy-bypass-list=127.0.0.1;localhost --disable-quic`. Açılış `NSWorkspace.OpenConfiguration.arguments` ile yapılır.
- Dock, Launchpad veya Spotlight açılışında argüman yoktur. Bu durumda oturum sarmalayıcısı proxy'yi çalışma anında uygular:

```js
// DiscordAccess macOS session wrapper v1
if (process.type === 'browser') {
  try {
    const electron = require('electron');
    const proxy = '<oturum proxy adresi>';
    if (electron.app.commandLine.getSwitchValue('proxy-server') !== proxy) {
      // session.defaultSession.setProxy({ proxyRules: proxy + ',direct://', proxyBypassRules: '127.0.0.1;localhost' })
      // Proxy uygulanana kadar her webContents.loadURL çağrısı bekletilir (yükleme bariyeri).
    }
    require('<kanca yolu>').install(electron, { env: {
      DISCORDACCESS_ATTACHMENTS: '1',
      DISCORDACCESS_DOWNLOAD_LOG: '<indirme kaydı yolu>'
    } });
  } catch (_) {}
}
module.exports = require('./core.asar');
```

  Aşama 0'da doğrulandı:
  - Yükleme bariyeri `app.on('web-contents-created')` olayında her `loadURL` çağrısını `setProxy` tamamlanana kadar bekletir.
  - `,direct://` yedeği, kapı kapalıysa Discord'u denemeden önceki davranışına döndürür. Başarı bu yüzden Discord'un açılmasıyla değil, kapı kaydındaki bağlantılarla değerlendirilir.
  - Kanca kurulumu Windows'taki sarmalayıcıyla aynı çağrıyı kullanır. Kanca dosyası Discord'un okuyabileceği yerde olmalıdır (bkz. 12); bu yüzden kanca sarmalayıcıya gömülür (1f). Gömülen kanca `bridge/attachment-download.cjs`'dir; SHA-256'sı Kit'te sabittir, farklı bir dosya PKG-E05 verir. Kancanın kayıtları Discord'un kendi klasörüne yazılır (`DiscordAccess-downloads.log`).
  - Üretilen sarmalayıcı Node ile, sahte bir Electron'la sınanır (`Tests/wrapper.test.cjs`): proxy yokken `setProxy` ve yükleme bariyeri, `setProxy` başarısız olsa da sayfanın yüklenmesi, menünün proxy argümanıyla açılışta ek iş olmaması, kancanın kurulması, ana süreç dışındaki süreçlere ve Electron hatasında Discord'a dokunulmaması.

**Trafik**
- Pencere trafiği (HTTPS/WSS) şu yolu izler: Discord Helper (ağ süreci) → kapı → motor → DoH ve TLS kayıt parçalamayla doğrudan çıkış.
- Ses ve görüntünün UDP trafiği doğrudan kalır (Windows ile aynı).

### 7.3 Kapanış ve kurtarma

- Çıkış'ta profil değişiklikleri geri alınır, ardından köprü, kapı ve motor kapanır.
- Discord açıksa kurtarma günlüğü korunur. Geri alma bir sonraki açılışta veya `--restore` ile yapılır.
- Geri almada yalnız sahiplenilen değerler geri yazılır. Kullanıcının sonradan değiştirdiği değerlerin ve diğer tercihlerin üzerine yazılmaz.

### 7.4 Oturum açılışında başlatma

- Uygulama yalnız güvenli bir konumdaysa kaydedilir (2c, `StartupRegistration.verifyLocation`):
  - kökten pakete kadar her klasör ve paketin içindeki her dosya kullanıcının veya root'un;
  - diğer kullanıcılar yazamıyor; grup yalnız admin ya da wheel ise yazabilir (`/Applications` böyledir, üyeleri zaten root olabilir); değişiklik izni veren ACL girdisi yok;
  - yolda ve pakette sembolik bağ yok;
  - App Translocation altında değil;
  - yerel bir birimde ve birim sahipliği yok saymıyor. macOS harici disklerde sahipliği varsayılan olarak yok sayar; orada her dosya soranın sahipliğinde görünür.
- Giriş açılışında (`--startup`) konum yeniden denetlenir. Güvenilmezse kayıt kaldırılır, Discord açılmaz ve kullanıcı uyarılır (Windows başka bir yolun başlangıç kaydını reddeder).
- Kayıt `SMAppService.agent` ile yapılır. Paket içindeki LaunchAgent tanımı (`Contents/Library/LaunchAgents/`) uygulamayı `--startup` argümanıyla başlatır; böylece giriş açılışı elle açılıştan ayırt edilir.
- "Oturum açılışında başlat" kapatılırsa kayıt kaldırılır. Normal Çıkış bu tercihi değiştirmez.
- İlk çalışan bağlantıdan sonra, kullanıcı henüz seçmediyse oturum açılışında başlatma Windows'taki gibi kendiliğinden açılır (`EnsureEnabled`). Kullanıcının kapatması kalıcıdır. Seçim, kayıt değiştirilmeden önce durum klasöründeki `preferences.json` dosyasına yazılır. Bu dosya var ama güvenle okunamıyorsa uygulama kendini kaydetmez.
- "Girişte Discord'u da aç" varsayılan olarak kapalıdır. Açıksa, girişte ilk çalışan bağlantıdan sonra Discord bir kez açılır; ilk deneme başarısız olsa da istek "Yeniden bağlan"a kadar korunur. Açık bir Discord yeniden açılmaz.
- Discord bağlantı hazır olmadan açılmışsa uyarı verilir; Discord zorla kapatılmaz.

## 8. Güvenlik sınırları

- **Kapı politikası** Windows `ProcessGate` ile aynıdır:
  - `AllowedDomains`, `UploadHosts` ve `ChallengeDomains` listeleri.
  - CONNECT yalnız 443'e; `discord.media` alanı için tüm portlara.
  - Düz HTTP `Upgrade` reddedilir.
  - Başlık en fazla 32 KiB ve yalnız ASCII.
  - En fazla 64 eşzamanlı bağlantı.
  - Kayıtlarda URL, başlık veya gövde bulunmaz.
- **Motor:**
  - Yalnız loopback'te, rastgele kimlik bilgisiyle dinler.
  - Kapı, istek göndermeden önce dinleyicinin motor sürecine ait olduğunu doğrular.
  - Motor askıda başlatılır. cdhash'i sabit değeri karşılamazsa hiçbir kodu çalışmadan öldürülür. Her başlatmada dosya yeniden ölçülür.
  - Go bağlayıcısının ad-hoc imzası tanımlayıcıyı `a.out` olarak yazar. Motor pakete bu imzayla, değiştirilmeden gömülür (`Contents/Helpers/sing-box`, 2d). Yeniden imzalamak sabit SHA-256'yı ve cdhash'i değiştirirdi; kişisel bir sertifikayla imzalamak da SHA-256'yı her Mac'te farklı kılardı. Bütünlüğünü sabit değerler ve uygulamanın imzası birlikte korur.
- **İstek politikası** (1b, Windows `RewriteHeader` karşılığı): Windows'taki bütün test vektörleri ret kategorileriyle birlikte geçer. Mutlak `http://` hedefleri Windows'taki `Uri` ayrıştırmasından katıdır:
  - Ana bilgisayar adı zaten DNS biçiminde olmalı ve yalnız harf, rakam, `-` ve `.` içermelidir. Bu yüzden ana bilgisayar bölümünde `%`, `[` (IPv6) ve `@` (kullanıcı bilgisi) reddedilir; yolda ve sorguda serbesttir.
  - Yazılan port tam olarak `80` olmalıdır.
  - `#`, `\`, boşluk ve kontrol karakterleri hedefin hiçbir yerinde kabul edilmez.
- **Eş kabulü** (1b'de yazıldı, 1c'de değişti; Windows `ExternalDiscordScope` ve `PermittedOwner` karşılığı):
  - Bağlantının istemci ucu yalnız adaylarda aranır: DiscordAccess'in kendisi ve onaylı Discord dosyalarından birini çalıştıran süreçler. Ucu tutan aday kabul ölçütlerinden geçmelidir; Windows da `TcpOwner.Find`'ın bulduğu tek sahibi denetler. Başka hiçbir sürecin tanıtıcılarına bakılmaz. Onaylanmamış bir süreç bağlantıyı tutuyorsa ret nedeni `NoHolder` olur.
  - Neden yalnız adaylar: bir tanıtıcıyı `proc_pidfdinfo` ile incelemek ona geçici bir referans alır. Sahibi tanıtıcıyı tam o sırada kapatırsa çekirdek soketi boşaltır (drain); o soketi paylaşan her süreçte okumalar kalıcı olarak `EBADF` döner. Doğmakta olan bir alt süreç `exec` anına kadar ebeveyninin bütün tanıtıcılarının kopyasını tutar ve `exec`'te kapatır. 1b'deki, kullanıcının bütün süreçlerini tarayan sürüm bu yüzden başka uygulamaların soketlerini bozabiliyordu: 1c testlerinde tarama ve alt süreç başlatma birlikteyken 16 bloklu okumanın 2-8'i `EBADF` ile bitti, soket de bozuk kaldı.
  - `exec`'i tamamlamamış (`PROC_FLAG_EXEC` yok) ya da çıkmakta olan bir sürecin tanıtıcılarına hiç bakılmaz; aynı denemede bu süzgeçle on binden fazla taramada hiç hata olmadı. XNU'da `exec_mach_imgact`, `exec` öncesi kopyaları kapatan `fdt_exec`'i `P_EXEC` bayrağından önce çalıştırır; bayrak görünüyorsa kopyalar kapanmıştır. Okumadan sonra süreç yeniden okunur; bu arada çıkmaya başlamışsa ya da PID başka bir sürece geçmişse sonuç kullanılmaz. Doğmakta olan bir Discord sürecinin kopyaları bu yüzden görülmez. Motorun kimliği de yalnız motor sürecinin tanıtıcılarıyla doğrulanır. Bir test, süzgeç kaldırılınca bu hatayı her denemede yakalar.
  - Kalan risk (kabul edildi): bir aday (Discord süreci ya da motor), başka bir süreçle paylaştığı bir soketi tam incelendiği anda kapatırsa ya da `exec`'i yeniden çalıştırırsa o soket yine boşalır. Bu mikrosaniyelik bir çakışma gerektirir. Adayın her soketi incelenir (TCP, UDP ya da yerel); soketin türü ancak incelenerek öğrenilir. Zararı bir Discord bağlantısının ya da Discord süreçleri arasında paylaşılan yerel bir soketin bozulmasıdır. Kullanıcının başka uygulamalarına artık hiç bakılmadığı için onlar etkilenmez. Çekirdeğin TCP listesi (`net.inet.tcp.pcblist_n`) ayrıcalıksız bir sürece yalnız kendi soketlerini gösterdiği için sahibi tanıtıcılara dokunmadan bulmanın yolu yoktur.
  - Aday seçimiyle inceleme arasında bir adayın PID'si başka bir sürece geçerse o süreç de incelenir. PID'ler sırayla dağıtıldığı için bu pratikte olmaz; olsa da sonuç o sürecin kabul denetiminden geçer.
  - Bulunamayan uçlar: bir adayın Mach fileport olarak tuttuğu ya da bir SCM_RIGHTS iletisi içinde yolda olan soket. Bunlar aynı kullanıcının iş birliğini gerektirir ve kapsam dışıdır; sonuç da güvenli taraftadır (ret).
  - Süreç listesi ve adayların tanıtıcı listeleri eksiksiz okunur: arabellek dolarsa büyütülüp yeniden okunur, bir liste yine eksik kalırsa bağlantı reddedilir. Bu Mac'te aynı kullanıcının 437 süreci 0,3 ms'de listelendi.
  - Geçebilecek retler (eksik liste, denetim sırasında değişen süreç ya da sahip, imza denetimi) 10 ms arayla üç kez yeniden denenir (Windows `FindPeer` gibi). Hiçbir adayın tutmadığı bağlantı ise hemen reddedilir: yeniden bakmak sonucu değiştirmez ve başka bir yerel kullanıcının her bağlantısı aksi halde bir kapı yuvasını 30 ms tutardı. Aday araması dosya adını büyük-küçük harf ayırmadan karşılaştırır, yolu `realpath` ile doğrular. Dosya adı dosya sistemine sorulmadan alınır: yanıt vermeyen bir ağ diskinden çalışan bir süreç bağlantıları bekletmez.
  - Kabul ölçütleri:
    - süreç bu kullanıcıya ait;
    - başlangıç zamanı oturumun hazır olduğu andan sonra (eşitlik kabul);
    - yürütülebilir dosyanın gerçek yolu (bağlar çözülmüş, harf düzeni diskteki gibi) seçili `Discord.app` içindeki beş dosyadan biri: `Discord` ve dört `Discord Helper`;
    - çalışan kod, o dosyanın Discord'daki designated requirement'ını karşılıyor (kendi tanımlayıcısı, Developer ID ve Team ID `53Q6R32WPB`).
  - Windows ayrıca oturum kimliğini karşılaştırır. macOS'ta karşılığı kullanıcı kimliğidir: bir kullanıcının aynı anda tek grafik oturumu olur; aynı kullanıcının SSH oturumları kapsam dışıdır.
  - Kabul, süreç örneği başına (PID, başlangıç zamanı, yol) kaydıyla hatırlanır. En fazla 256 kayıt tutulur; doluyken yeni süreç reddedilir. Retler hatırlanmaz. Kabul edilmiş bir süreç aynı yoldaki dosyayı yeniden çalıştırırsa (`exec`) kabul sürer ve imza yeniden denetlenmez; bu, onaylı dosyanın aynı kullanıcı tarafından değiştirilmesini gerektirir ve kapsam dışıdır. Kayıt denetimden önce ve sonra karşılaştırılır; denetimlerden sonra ucun hâlâ aynı süreçte olduğu doğrulanır. Hiçbir adayın tutmadığı bağlantı reddedilir.
  - Ebeveyn örnek kimliğine girmez: ebeveyni ölen süreç launchd'ye geçer ve kabul edilmiş kalır. Okunamayan ama var olan süreç listeden düşmez; `anyAdmittedRunning` onu çalışıyor sayar, kabul ise reddedilir (Windows `Unknown`). Windows'ta bu sinyal, Discord çalışırken ayarların geri yüklenmesini engeller. Çıkmış ama toplanmamış (zombi) süreç de okunamaz ama var sayılır; ebeveyni onu toplayana kadar çalışıyor sayılır. DiscordAccess Discord'u kendisi başlatırsa onu toplamalıdır.
  - İmza denetimi kilit dışında yapılır; yavaş bir denetim önceden kabul edilmiş süreçlerin bağlantılarını bekletmez.
  - DiscordAccess'in kendi süreci yalnız tanı izni açıkken kabul edilir.
- **İmza denetimleri ağ kullanmaz** (`kSecCSNoNetworkAccess`). Çevrimiçi iptal ve noterleştirme denetimleri bir bağlantıyı dakikalarca bekletebilir; Gatekeeper bunları açılışta zaten yapar.
- **Paketlerin statik doğrulaması istek yolunda yapılmaz.** `SecStaticCodeCheckValidity`, paketin noterleştirme biletini `syspolicyd`'ye eşzamanlı bir XPC çağrısıyla kaydeder. Bu çağrı 1b testlerinde 49 ile 256 sn arasında bekledi. Çalışan sürecin dinamik denetimi bu yolu kullanmaz: yük altında 1651 denetimde en uzun süre 10 ms oldu.
- **Electron sigortaları** (Discord 0.0.415): `RunAsNode` ve `NodeCliInspectArguments` kapalı, `NodeOptionsEnvironmentVariable` açık, asar bütünlük denetimi kapalı. Aynı kullanıcıyla çalışan bir süreç, Discord'u `NODE_OPTIONS` ile başlatıp Discord imzalı bir süreçte kod çalıştırabilir. Bu kapsam dışı saldırgandır; Windows'ta da durum aynıdır. Beş dosyanın hepsinde `allow-unsigned-executable-memory`, `Discord` ve `Discord Helper (Renderer)`'da `allow-jit`, ağ hizmetini taşıyan `Discord Helper`'da ayrıca `disable-library-validation` yetkisi vardır. İmza, hangi dosyanın çalıştığını kanıtlar; içinde hangi kodun çalıştığını kanıtlamaz.
- **Onay listesinin daraltılması (1g):** Chromium'un ağ hizmeti `Discord Helper` içinde çalışır; GPU ve Renderer süreçleri kum havuzundadır ve soket açmaz. Gerçek bağlantı sahipleri uçtan uca gözlendikten sonra liste `Discord` ve `Discord Helper` ile sınırlanabilir. Windows'ta bütün süreçler aynı `Discord.exe` dosyasını çalıştırdığı için liste fiilen hepsini kapsar. Kurulu uygulamayla karşılaştıran test yalnız `Contents/MacOS` ve `Contents/Frameworks/*.app` altını tarar; `*.framework/Helpers` altındaki `chrome_crashpad_handler` ve Squirrel'in `ShipIt`'i kapıyı kullanmaz.
- **Kapının ağ katmanı** (1c, Windows `ProcessGate` karşılığı):
  - Her bağlantı sırayla: eş kabulü (reddedilene `403 Forbidden`), başlık (en fazla 32 KiB, 15 sn içinde, yalnız ASCII), istek politikası, motora bağlantı (5 sn), motor kimliği, başlığın yazılması, iki yönlü aktarım. Bir yön bitince karşı soketin gönderme yönü kapatılır; kalan yön en fazla 30 sn boşalır. Aşamalar, süreler, 64 bağlantı sınırı ve tanı satırları Windows'takiyle aynıdır.
  - Motor kimliği her bağlantıda doğrulanır: motor çalışıyor, bağlantının kendi ucunu motor tutuyor ve motor hâlâ çalışıyor. Motor toplanmamış bir alt süreç olduğu için iki denetim arasında PID'si başka bir sürece geçemez. Motor bağlantıyı kendi zamanında kabul ettiği için bu uç en fazla 1 sn beklenir. Doğrulanmamış bir arka uca tek bayt gönderilmez; kimlik bilgisi de buna dahildir.
  - Bütün soketler close-on-exec'tir. macOS'ta `SOCK_CLOEXEC` yoktur: soketin açılmasıyla bayrağın konması arasında başka bir iş parçacığının başlattığı alt süreç tanıtıcıyı devralabilir. Uygulamanın her alt süreci bu yüzden `POSIX_SPAWN_CLOEXEC_DEFAULT` ile başlatılır; motor 1a'dan beri böyledir, Discord'u başlatan kod da (1f/1g) böyle olmalıdır.
  - Her bağlantı kendi iş parçacığında, bloklamayan soketler ve `poll` ile çalışır; eş denetimi kabul döngüsünü bekletmez. Kapanış, bütün beklemelere katılan bir borunun yazma ucu kapatılarak bildirilir; hiçbir iş parçacığı başkasının tanıtıcısını kapatmaz. Dinleyiciyi kabul iş parçacığı kapatır; `close()` bunu bekler ve döndüğünde port boştur (Windows `Dispose` gibi). Kabul iş parçacığı o sırada bir tanı geri çağrısında olabileceği için `close()`, geri çağrının beklediği bir kilit ya da kuyruk tutulurken çağrılmaz; 1g'de tanı kaydı eşzamansız yazılır (`ConsoleOutput`). Biten bağlantıların tanı satırları `close()` döndükten kısa süre sonra da gelebilir. Kapı kendi kapanış durumunu da denetler; eş kabulünün `close()` ile çakışan bir sonucu kullanılmaz.
  - Zaman sınırları monoton saatle (`ContinuousClock`) ölçülür; sistem saatinin değişmesi onları kısaltmaz ya da uzatmaz.
  - Dinleyici `SO_REUSEADDR` ile açılır: yeni bir kapı, kapanan kapının portunu eski bağlantılar TIME_WAIT'teyken de alabilir. Dinleyici açıkken başka bir soket 127.0.0.1 üzerindeki aynı portu alamaz.
  - Kabul sırasında beklenmeyen bir hata (örneğin `EMFILE`) kapıyı kapatır: önce dinleyici kapanır, sonra `faulted` bildirilir (Windows gibi). 1g'de kapı arızası Windows'taki gibi oturumu kapatır; kapı yeniden kurulmaz. Kabulde `EMFILE` gibi hatalar yeniden denenmez. Bunun yerine uygulama açılışta yumuşak tanıtıcı sınırını (`RLIMIT_NOFILE`) 4096'ya, sert sınır izin verdiği kadar yükseltir: 64 bağlantı 128 tanıtıcı kullanır ve macOS'un varsayılan yumuşak sınırı 256'dır.
  - Retler görünür: sahiplik reddi `Failure stage=Ownership target=unknown category=UnownedClient reason=<neden>` satırıyla yazılır. Neden, satırın öteki değişken parçaları gibi yazılmadan önce süzülür; yeni bir satır başlatamaz. Nedenler: `NoHolder`, `DiagnosticNotAllowed`, `OtherUser`, `StartedBeforeReady`, `RequirementNotMet`, `UnknownProcess`, `HoldersChanged`, `Unreadable`, `Capacity`, `Closed` ve yürütülebilir dosya adıyla birlikte `UnapprovedExecutable`. Onaylanmamış bir Discord yardımcısı aday olmadığından `NoHolder` olarak görünür; yeni yardımcıları kurulu uygulamayla karşılaştıran test geliştirme sırasında yakalar. Onaylı dosyalardan biri eksikse `PeerAdmission` artık `missingExecutable` hatası verir (kullanıcı iletisi 1f).
  - Kapı yalnız tam olarak 127.0.0.1'den gelen bağlantıyı eşleştirir. Başka bir loopback adresi (ör. root'un lo0'a eklediği 127.0.0.2) `RemoteAddress` nedeniyle reddedilir.
  - Politika, motora gidecek baytların aynısını görür: başlık ham baytlarda ilk CRLFCRLF'de ayrılır; motora `rewrite` çıktısı ve ardından kalan baytlar olduğu gibi gider.
  - Başka bir yerel kullanıcı kapıya bağlantı yağdırabilir. Bu bağlantılar aday bulunamadığı için birkaç milisaniyede reddedilir ve bir yuvayı ancak o kadar tutar. Tanı satırlarının dakikalık kotasını yine de tüketebilirler; Windows'ta da durum aynıdır.
- **Bağlantı tanısı** (1d, Windows `ConnectivityChecks` ve `GatewayChecks` karşılığı):
  - İstekler yalnız oturum kapısından geçer: URLSession'a sabit bir loopback proxy verilir; sistem proxy'si, proxy betiği ya da doğrudan bağlantı yoktur. Proxy reddederse istek hemen başarısız olur (CFNetwork 306 düz HTTP için, 310 HTTPS ve WebSocket için); doğrudan bağlantıya düşmez.
  - Yönlendirme izlenmez; çerez, önbellek ve kimlik bilgisi tutulmaz. Gövde yalnız Gateway'in 200 yanıtında ve en fazla 16 KiB okunur; başka her durum yanıt başlığıyla sayılır (Windows gibi). Uzun, yarıda kesilen ya da yavaş gelen bir sayfayla gelen 429 böylece yine 429'dur.
  - Kimlik bilgisi hiçbir zaman sunulmaz: kimlik doğrulama isteğinde CFNetwork bir kez daha kimlik bilgisi olmadan sorar, sonra 401 olduğu gibi döner. Başlık değerleri sabittir; URLSession'ın bu Mac'ten aldığı dil listesi ve tarayıcı adı gönderilmez (Windows da göndermez).
  - Her isteğin 10 sn son tarihi vardır. Süre dolunca istek iptal edilir ve kapanması en fazla 5 sn daha beklenir. HTTPS denetimi iki istek yapar (Gateway API, güncelleme sunucusu); DNS adayının denetimi yalnız Gateway API isteğidir.
  - Gateway WebSocket denetimi yalnız herkese açık HELLO'yu okur ve normal kapanır; IDENTIFY, belirteç ya da hesap verisi gönderilmez.
  - Kapı bu süreci tanı izniyle kabul eder; Windows'taki gibi bu izin oturum boyunca açık kalır. URLSession'ın proxy bağlantısı bu süreçte BSD soketi olarak görünür, eş kabulü onu tanır (1d'de ölçüldü).
  - Hata iletileri yalnız sabit bir kategori, HTTP durumu ve yanıt türü içerir; URL, başlık, gövde ya da hata metni tutulmaz.
  - `discord.com` ve `discord.gg` HSTS önyükleme listesindedir: URLSession düz `http` ve `ws` isteklerini de `https` ve `wss`'e çevirir. Testler bu yüzden `.invalid` adlarla düz HTTP kullanır; bu adlar hiçbir yere çözülmez.
  - Seçilen aday oturumun motoru ve kapısı olur. Oturum (1g), kapının kendini kapattığını `DnsConnection.onGateFault` ile öğrenir (Windows `Gate.Faulted`). Motorun çıkışını da ayrıca izlemelidir (Windows `Engine.Exited`): 1d'de duran motor yalnız denetim sırasında fark edilir ve ENG-E02 olarak bildirilir.
  - 1d'de açık kalan noktalar 1g'de şöyle kapandı:
    - İşleyici ayarlanmadan önce kapı arızalanırsa bunu bildiren bir şey yoktu (Windows'ta da aynı boşluk var). Oturum, işleyiciyi ayarladıktan sonra ve bağlantının sonunda kapının hâlâ kabul ettiğini `ProxyGate.isAccepting` ile denetler.
    - İşleyiciler oturumu zayıf tutar. Kapanışla yarışan bir arıza yine bir kez bildirilebilir; oturumun bağlantısı artık o aday olmadığı için yok sayılır.
    - `DnsConnection.close()` ikinci çağrıda hiçbir şey yapmaz, ilk çağrı DNS-E03 vermiş olsa da. Oturum denetleyicisi bu yüzden tek kullanımlıktır; yeniden bağlanma yeni bir denetleyiciyle yapılır. Menü çubuğunun "Yeniden bağlan"ı (Aşama 2) da toplanamayan motor varken yeni aday başlatmamalıdır.
- **Güncelleme köprüsü** (1e, Windows `UpdateBridge` karşılığı):
  - Yalnız 127.0.0.1'de, rastgele bir portta dinler. Her yol 24 baytlık rastgele bir token ile başlar.
  - İstemci, kapıdaki gibi `PeerAdmission` ile kabul edilir: kabul edilen Discord süreçleri ve tanı izniyle bu süreç. Reddedilen istemci, isteği okunmadan 403 alır.
  - Yalnız izinli Discord alanlarına, https ve 443 ile ve kapı üzerinden gider. Yönlendirme izlenmez; çerez, önbellek ve kimlik bilgisi tutulmaz ya da sunulmaz.
  - Yönlendirme ve manifestteki adresler yalnız izinli bir Discord adresiyse köprüye yazılır. Discord dışına giden bir yönlendirme 400 ile reddedilir; güncelleyici başka bir yere gönderilemez.
  - Tanı satırları yalnız sabit aşama, kategori, HTTP durumu ve sayısal hata kodu içerir; URL, token, başlık, gövde ya da hata metni yazılmaz.
- **Oturum ve Terminal modu** (1g, Windows `Controller` ve `ConsoleHost` karşılığı):
  - Bağlanma sırası: Discord.app doğrulanır ve kapalı olmalıdır; önceki oturumun günlüğü geri alınır; veri klasörü okunabilmelidir; kanca ve motor doğrulanır; bu paketin motor yolundan launchd'ye geçmiş (yetim) motorlar kapatılır; DNS adayı seçilir; köprü başlar; Discord hâlâ kapalı olmalıdır; profil değişiklikleri yapılır. Bir adım başarısız olursa yapılan her şey geri alınır.
  - Arka uç hatası: motorun çıkışı (`DispatchSource` süreç izleyicisi), kapının ya da köprünün kendini kapatması oturumu kapatır. Kapı ve motor hemen durur, geri kalanı kapanıştaki gibi işlem kilidi alındıktan sonra yapılır (Windows `BackendFailed`).
  - Kapanış: profil değişiklikleri ancak Discord kapalıysa geri alınır. Kapının kabul ettiği bir Discord süreci hâlâ çalışıyorsa, bir Discord süreci 1 sn içinde kapanmazsa, süreç listesi okunamazsa, geri alma başarısız olursa ya da bir günlük kalırsa değişiklikler günlükleriyle korunur (SES-E01). Geri alma bir sonraki açılışta ya da `--restore` ile yapılır; `--restore` Discord açıkken bir şey değiştirmez (DSC-E07).
  - Tek oturum: durum klasöründeki `session.lock` üzerinde `flock`. Kilit süreç bitene kadar tutulur ve sistemce bırakılır, çökme de buna dahildir; süresi dolan bir kapanışta profili değiştirmekte olan bir iş parçacığı varken başka bir örnek başlayamaz. İkinci örnek "zaten çalışıyor" der ve çıkar; `--restore` da kilidi alır (SES-E04). Böylece ikinci bir örnek, ilk oturumun değişikliklerini geri alamaz ya da üstüne yazamaz.
  - Discord'u açma (A): Discord yeniden doğrulanır; sürüm değiştiyse açılmaz (SES-E03), açıksa ikinci kez açılmaz. İmza denetimi saniyeler sürebildiği için işlem kilidi tutulmadan yapılır; Discord açılırken oturum hâlâ aynı olmalıdır. `open` en fazla 10 sn beklenir. Açılış `/usr/bin/open -a <Discord.app> --args --proxy-server=… --proxy-bypass-list=127.0.0.1;localhost --disable-quic` ile yapılır. `open` yalnız /dev/null'a bağlı standart tanıtıcılarla ve `POSIX_SPAWN_CLOEXEC_DEFAULT` ile başlar. Discord'u Launch Services başlatır; Discord bu sürecin ortamını almaz (testte doğrulandı).
  - Terminal: A, Q, T, D komutları; en fazla 64 bekleyen komut, her biri en fazla 8192 karakter. Her işlem kendi iş parçacığında çalışır; Q her an kapatır. Ctrl-C, SIGTERM ve SIGHUP (kapanan Terminal penceresi) Q gibi kapatır, çıkış kodu 130 olur. Kapanış en fazla 15 sn sürer; süre dolarsa bu sürecin motor alt süreçleri öldürülür, çünkü macOS'ta motor ebeveyninden sonra da yaşar. Çıkış kodları: 0, 1 (bağlantı ya da temizlik başarısız), 3 (açılamadı), 64 (hatalı komut satırı), 130.
  - Çıktı: ekran ve kayıt için ayrı, sınırlı kuyruklar vardır (32 ve 512 satır). Duraklatılmış bir Terminal ya da yavaş bir disk kapıyı, köprüyü ve kapanışı bekletmez; sığmayan satırlar düşer ve sayılır. Satırlar 1000 karakterle sınırlıdır; kontrol ve metin yönü karakterleri boşluk olur, böylece bir dosya adı uzantısını gizleyemez. Kayıt `session.log` dosyasına yazılır (0600, 256 KiB'da yeniden başlar). Kayıtta bağlantı, belirteç ya da başlık bulunmaz.
  - Tam Disk Erişimi: Terminal'den çalıştırıldığında macOS izni terminal uygulamasından ister. PRF-E04'te Sistem Ayarları'nın Tam Disk Erişimi sayfası açılır ve Terminal'e özgü ileti gösterilir.
  - Açılışta root reddedilir (SYS-E02) ve SIGPIPE yok sayılır; kapanmış bir Terminal temizliği yarıda kesmez. Alt süreçler (motor, `open`) bu sinyallerin varsayılan işleyişiyle başlar. Terminal satırları en fazla 32 KiB okunur; daha uzunu atlanır. Komut satırı dışında yazılan hata satırları da temizlenir.
  - Ek dosyası indirme (D) Windows kurallarını izler. Bağlantı yazıldığı gibi gönderilir. En fazla 3 yönlendirme izlenir ve her biri yeniden doğrulanır. İndirme toplam 15 dk, veri gelmeden en fazla 30 sn sürer. Dosya `~/Downloads/DiscordAccess/<zaman>-<rastgele>/` altında gizli bir `.part` dosyasına yazılır, `RENAME_EXCL` ile adına taşınır ve karantina özniteliği alır. Windows'un aygıt adı kuralı (CON vb.) macOS'ta uygulanmaz. Ad en fazla 160 karakter ve macOS'un sınırı olan 255 bayttır; daha uzun bir ad uzantısını korur ve `_` ile başlar (Windows'un kısalttığı adlar gibi). Dosya tanıtıcısı yazılırken kilitli kalır; kapatılan bir tanıtıcının numarası yazma sürerken başka bir dosyaya geçemez. İmzalı bağlantı kayda, ekrana ya da dosya adına girmez.
- **Kapı için bilinen sınırlar:**
  - Düz HTTP keep-alive bağlantısında yalnız ilk istek politikadan geçer; sonraki istekler olduğu gibi aktarılır. Windows'ta da durum aynıdır ve motorun kendi yönlendirmesi hedefleri yine sınırlar.
  - Başlığı gönderip hemen yarım kapatan istemci reddedilir: sahiplik yalnız kurulu (ESTABLISHED) bağlantılara bakar. Windows'ta da durum aynıdır; Chromium böyle yapmaz.
- **Discord kurulumu:** bundle id `com.hnc.Discord`, Team ID imzası, yolda sembolik bağ yok, yerel disk. PTB ve Canary desteklenmez. Onaylı yollar `proc_pidpath`'in verdiği biçimde olmalıdır (`/Applications/...`); `/System/Volumes/Data/...` biçimi hiçbir süreçle eşleşmez ve Discord reddedilir. Paket seçimi (1f) bu biçimi `/Applications` biçimine çevirir ya da reddeder.
- **Dosya işlemleri:**
  - `O_NOFOLLOW` kullanılır, her üst bileşen `lstat` ile denetlenir, son yol `F_GETPATH` ile doğrulanır.
  - Sahiplik, izin ve ACL denetlenir.
  - Değişiklik `renamex_np(RENAME_SWAP)` ile atomik takasla yapılır; yerinden çıkan içerik beklenenle karşılaştırılır.
  - Tanınmayan içerik `.discordaccess-fs-*.preserved` olarak korunur.
  - Silme de bir karşılaştırmadır: dosya önce benzersiz bir ada taşınır, baytları beklenenle aynıysa silinir, değilse geri konur ya da yanında korunur (1f).
- **Durum klasörü:** klasör 0700, dosyalar 0600. Kurtarma günlüğü ve kayıtlar kişisel veridir. Klasörün sahibi bu kullanıcı olmalı, grup ve diğerlerine izin vermemeli ve erişim denetim listesi (ACL) taşımamalıdır; değilse profil değişikliği yapılmaz (1f).
  - Günlük, macOS'un Discord'un klasörü kadar korumadığı bir yerdedir. Kurtarma bu yüzden günlüğe sınırlı güvenir: yalnız standart Discord klasörüne dokunur ve güncelleme ayarlarına yalnız Discord'un kendi alanlarındaki https adreslerini geri yazar. Başka bir önceki değer, oturum başında değiştirilmeden reddedilir (PRF-E01).
  - Günlük ve değiştirilen dosyalar `F_FULLFSYNC` ile diske yazılır, klasör de eşitlenir; önce yazılan günlük, güç kesintisinden sonra da önce kalır.
- **Kontrol soketi:** Aşama 2'de yapılmadı. Launch Services bir uygulama paketini tek örnekle açar ve yeniden açılışı çalışan örneğe iletir; uygulama o zaman durumunu bildirir. İkinci bir süreç (Terminal ya da launchd) yalnız "zaten çalışıyor" der ve çıkar. Soket gerekirse eklenir: dosya 0600 olur, karşı tarafın kullanıcısı (`LOCAL_PEERCRED`) ve kod imzası (audit token) doğrulanır.
- **Diğer uygulamaların verisi (Tam Disk Erişimi):**
  - Bu izin geniştir. Uygulama onu yalnız Discord'un veri klasöründeki sahiplenilen dosyalar için kullanır.
  - İzin yoksa profil değişikliği yapılmaz. Uygulama izni kendisi değiştirmeye çalışmaz. İzin, klasörün içeriği okunarak denetlenir (`DiscordProfile.access`); macOS'un engellediği bir dosya işlemi PRF-E04 verir (1f).
  - TCC izni uygulamanın kod kimliğine bağlıdır. Ad-hoc imzalı derlemede her yeniden derleme izni geçersiz kılar. Kalıcı izin için sabit bir imza kimliği gerekir (yerel kişisel imza veya Developer ID).
- **Kapsam dışı (Windows ile aynı):** aynı kullanıcı yetkisini ele geçirmiş zararlı yazılım ve root saldırganı. İmzasız/yerel imzalı uygulama Gatekeeper onayı iddia etmez.

## 9. Hata yönetimi

- **Mesajlar:** Hata kodları ve Türkçe mesajlar Windows'taki aileyi izler (`PKG-E01` vb.). Arka planda uyarı penceresi, Terminal'de stderr kullanılır.
- **DNS:** Başarısız adayın ardından sıradaki denenir. Hepsi başarısızsa yalnız sabit bir ileti gösterilir (DNS-E02) ve "Yeniden bağlan" önerilir. HTTP 429 (Discord'un hız sınırı başka bir sağlayıcıyla aşılmaya çalışılmaz), iptal edilen denetim, açılamayan aday (paket bütünlüğü, motor başlatma) ve güvenle kapatılamayan aday (DNS-E03) seçimi başka sağlayıcı denemeden durdurur. Denetim sırasında duran motor ENG-E02 olarak bildirilir. Geçersiz ya da tekrarlanan `--dns` seçeneği DNS-E01'dir.
- **Motor kopması:** Menü durumu "bağlantı koptu" olur. "Yeniden bağlan" temiz yeniden kurulum yapar. Terminal modunda oturum kapanır ve neden ekranda gösterilir (1g).
- **Yetim motor:** Çökme sonrası kalan motor, bir sonraki açılışta bu paketin motor yolu, kullanıcı kimliği ve üst süreç (1) ile bulunup kapatılır.
- **Profil çakışması:** Kullanıcının değiştirdiği değerin üzerine yazılmaz. İşlem durur, kurtarma dosyası korunur ve kullanıcı bilgilendirilir.
- **Discord güncellemesi:** Oturum boyunca doğrulanan sürüm tutulur. Yeni sürüm desteği bir sonraki açılışta hazırlanır. Tanınmayan profil yapısında değişiklik yapılmaz.
- **Erken açılan Discord:** Discord bağlantı hazır olmadan açılmışsa uyarı verilir; zorla kapatılmaz.

## 10. Test ve doğrulama

- **Swift birim testleri** (`swift test --package-path macos`):
  - motor yapılandırması
  - kapı politikası (Windows fixture'larından türetilen vektörlerle)
  - köprü yol eşlemesi ve yeniden yazma
  - günlük ve geri alma akışı (geçici klasörlerde)
  - yol güveni
  - imza gereksinimi
  - soketten süreç bulma (yerel test süreciyle)
  - oturum yaşam döngüsü (gerçek motor, örnek Discord.app ve örnek profille; ağsız), Terminal komut akışı, ek dosyası indirme (URLSession içinde sahte sunucu), Launch Services ile açılış (arka planda çalışan deneme uygulaması) (1g)
- **Node testleri:**
  - `node macos/Tests/wrapper.test.cjs`
  - mevcut `node tests/attachment-download.test.cjs` (yalnız çalıştırılır, değiştirilmez)
- **Motor:**
  - Yamaların Go testleri macOS'ta çalıştırılır.
  - Altı DNS ayarı motorun `check` komutuyla doğrulanır.
  - Motor iki kez derlenip aynı hash'in üretildiği gösterilir.
- **Canlı doğrulama** (bu Mac, engelli ağ):
  - menüden açılış
  - Dock'tan açılış
  - mesaj
  - ek dosyası yükleme ve indirme
  - ses
  - güncelleme denetiminin köprüden geçmesi
  - çıkışta geri alma
  - çökme sonrası kurtarma
  - oturum açılışında başlatma

  Canlı sonuçlar otomatik testlerden ayrı raporlanır. Yapılmayan kontrol yapılmış gibi gösterilmez.

## 11. Aşamalar ve çıkış ölçütleri

**Aşama 0 — Fizibilite.** Atılabilir bir denemedir; `macos/work/` altında, Git dışında yapılır.

- Motor `darwin/arm64` için sabit Go, kaynak ve yamalarla derlenir; yamaların Go testleri geçer.
- Discord, motor ve deneme kapısıyla `--proxy-server` argümanıyla açılır; ana pencere yüklenir.
- Ana uygulama ve modül güncelleme denetimleri deneme köprüsünden geçer. Gerçekte Discord'un yeni yerel güncelleyicisi kullanıldı; eski Squirrel beslemesi de köprüden yanıt verdi.
- Sarmalayıcıyla Dock'tan açılan Discord bağlanır.
- Discord profil yapısı doğrulanır: `~/Library/Application Support/discord/settings.json`, sürüm klasörü, `modules/discord_desktop_core/index.js` içeriği.
- Kullanıcının Discord profil dosyalarına dokunan her adım (okuma veya geçici değişiklik) öncesinde onay alınır. Değiştirilen dosyanın yedeği alınır ve deneme sonunda geri yüklenir.
- Çıkış: "kendi simgenden aç" yöntemi ve güncelleme yolu kesinleşir; sonuç bu belgeye işlenir.
- **Durum (2026-10-14): Tamamlandı.** "Kendi simgenden aç" yöntemi (çalışma anı proxy'si) ve güncelleme yolu (yeni güncelleyici ve köprü) doğrulandı. Ayrıntılar Bölüm 3'tedir. Deneme araçları güvenlik incelemesinden geçirilerek kullanıldı.

**Aşama 1 — Çekirdek ve Terminal modu.**

- **1a durumu:** Tamamlandı (motor katmanı ve derleme betiği sabitleri). Plan: macos/docs/plans/2026-10-14-asama-1a-motor-katmani.md.
- **1b durumu:** Tamamlandı (kapı istek politikası ve eş kimliği). Plan: macos/docs/plans/2026-10-14-asama-1b-kapi-politikasi-ve-es-kimligi.md.
- **1c durumu:** Tamamlandı (kapının ağ katmanı; eş araması yalnız adaylarda). Plan: macos/docs/plans/2026-10-14-asama-1c-kapi-ag-katmani.md.
- **1d durumu:** Tamamlandı (bağlantı tanısı ve otomatik DNS seçimi; canlı doğrulama bu Mac'te geçti). Plan: macos/docs/plans/2026-10-15-asama-1d-baglanti-tanisi-ve-dns-secimi.md.
- **1e durumu:** Tamamlandı (güncelleme köprüsü; canlı doğrulama bu Mac'te geçti). 1e'den itibaren aşamalar hash'li plan olmadan, doğrudan depoda testleriyle yazılır; güvenlik açısından önemli kodu bağımsız bir kritik inceleme denetler.
- **1f durumu:** Kit tamamlandı: Discord.app doğrulaması, Tam Disk Erişimi denetimi, güvenli dosya işlemleri, oturum sarmalayıcısı (gömülü kanca, Node testi) ve günlüklü profil değişiklikleri. Testler yalnız geçici örnek profillerle çalışır. Gerçek profile uygulama, Sistem Ayarları yönlendirmesi ve Discord içinden ek dosyası indirmenin doğrulanması 1g'de, kullanıcının onayıyla yapılır.
- **1g durumu:** Tamamlandı; Aşama 1'in çıkış ölçütleri karşılandı. Terminal modu yazıldı: oturum denetleyicisi, `DiscordAccess` komutu (`--console`, `--restore`, `--verify-package`, `--discord-path`, `--dns`, `--help`), tek oturum kilidi, Launch Services ile Discord açılışı, Terminal'den ek dosyası indirme ve Sistem Ayarları yönlendirmesi. Otomatik testler ağsız ve örnek profillerle geçer.
  - Canlı doğrulama (2026-10-15, bu Mac, Discord 0.0.415; kullanıcı Tam Disk Erişimi verilmiş Terminal'de çalıştırdı). Geçenler:
    - Otomatik DNS seçimi Cloudflare (IP sertifikası) adayında durdu.
    - Dock'tan açılan Discord sarmalayıcıyla bağlandı ve tamamen kullanılabildi. Kapı yalnız Discord alanlarına izin verdi; sahiplik reddi olmadı.
    - Gerçek profilin düzeni (`app-<sürüm>/modules/discord_desktop_core-<N>`) beklendiği gibiydi. Kanca iki Discord açılışında da kuruldu.
    - Discord içinden 28,6 MB'lık bir ek dosyası kayıt penceresiyle indirildi.
    - T: HTTPS denetimi ve Gateway HELLO geçti.
    - Q: profil değişiklikleri geri alındı. Günlük silindi, SES-E01 olmadı.
    - A: Discord `open` ile argümanlarıyla açıldı ve kapıdan bağlandı; Q'da değişiklikler yine geri alındı.
  - Kapı politikası Windows'taki gibi Spotify'ı (`api.spotify.com`, `dealer.spotify.com`) ve `dc-telemetry.net`'i reddetti; Discord'un Spotify bağlantısı oturumda çalışmaz.
  - Canlıda yapılmayanlar: ses, çökme sonrası kurtarma ve gerçek günlükle `--restore`.
- `scripts/build-engine.py` darwin hash sabitiyle tamamlanır: `ENGINE_SHA256 = 013ba5d5055988953ebec1a1ac0eceb8aead52415e3ef186a5c7481083472cb0`; tekrarlanabilirlik Aşama 0'da doğrulandı.
- Profil değişiklikleri yeni güncelleyici düzenine (`app-<sürüm>/modules/discord_desktop_core-<N>`) göre yazılır. Windows'taki gibi tüm çekirdek nesilleri sarılır.
- Ek dosyası kancası sarmalayıcıya gömülü olarak kurulur. Discord içinden ek dosyası indirme Mac'te doğrulanır.
- Tam Disk Erişimi denetimi ve kullanıcı yönlendirmesi eklenir.
- Kit bileşenleri yazılır: EngineConfig, EngineProcess, DnsSelection, ProxyGate, PeerIdentity, UpdateBridge, DiscordInstallation, DiscordProfileChanges, StateStore, Connectivity.
- `--console` (Q/T/D/A) ile uçtan uca bağlantı kurulur.
- Çıkış: Terminal modunda Discord menüden ve Dock'tan bağlanır; birim ve Node testleri geçer; `macos/` dışında değişiklik yoktur.

**Aşama 2 — Menü çubuğu uygulaması.**

- ResidentInstance, MenuBarController, SessionController, StartupRegistration ve bildirimler yazılır.
- `KitError`, `LocalizedError`'a uyar; uygulamanın uyarı ve bildirimleri Türkçe hata mesajını gösterir.
- Terminal için 1g'de eklenen seçenekler (`--restore`, `--verify-package`, `--help`, `--discord-path`, `--dns`) paketlenmiş uygulamada da çalışır.
- `build-app.sh` ile `.app` paketi üretilir. Paket, kalıcı TCC izni için sabit bir imza kimliğiyle imzalanır; gömülü motor kendi sabit imzasını korur.
- **2a–2c durumu:** Yazıldı:
  - `ResidentLifecycle` (Windows `BackgroundLifecycle`): bağlanırken gelen açma istekleri birleşir, kapanış sınırlıdır.
  - AppKit menü çubuğu uygulaması: Discord'u aç, Yeniden bağlan, Bağlantıyı kontrol et, Oturum açılışında başlat, Girişte Discord'u da aç, Çıkış. Bildirimler yalnız pakette ve izin verilince gösterilir; çıkışta uyarı penceresi beklenmez.
  - `StartupRegistration`: `SMAppService.agent` ve konum güveni.
  - `ResidentPreferences`.
  - Paket kimliği `io.github.alpertknn.DiscordAccess`.
- **Yeniden bağlanma:** Windows'tan bilerek ayrılır. Önceki oturum yalnız profil değişikliklerini koruyarak bittiyse (SES-E01) yeni oturum başlar ve önce onları geri alır; Windows ise uygulama yeniden başlatılana kadar reddeder. Önceki oturum zamanında kapanmadıysa, başka bir hatayla bittiyse ya da motorunu toplayamadıysa (DNS-E03) yeni motor başlatılmaz.
- **2d durumu:** `build-app.sh` paketi kurar: `Contents/Helpers/sing-box`, `Contents/Resources/attachment-download.cjs` ve `Contents/Library/LaunchAgents/io.github.alpertknn.DiscordAccess.agent.plist`. Paket `DISCORDACCESS_SIGN_IDENTITY` ile imzalanır, verilmezse ad-hoc. İmza `--strict --deep` ile doğrulanır ve paket kendi motorunu ve kancasını `--verify-package` ile denetler. Önceki derlemeler silinmez.
- **Aşama 2 canlı doğrulama** (2026-10-15, bu Mac; ad-hoc imzalı paket `/Applications`'ta). Geçenler:
  - İlk açılışta Tam Disk Erişimi uyarısı çıktı ve Sistem Ayarları'na yönlendirdi. Terminal'e verilen izin uygulamaya geçmedi.
  - İzinden sonra uygulama kendiliğinden bağlandı.
  - İlk bağlantıdan sonra oturum açılışında başlatma kendiliğinden açıldı; `SMAppService` ad-hoc imzada çalıştı.
  - Menüden açılan Discord kapıdan bağlandı.
  - "Bağlantıyı kontrol et": HTTPS denetimi ve Gateway HELLO geçti.
  - Yeniden açılış çalışan örneğe gitti ve durumu bildirdi.
  - Çıkış'ta profil değişiklikleri geri alındı, günlük silindi; geride süreç kalmadı.
  - Yapılmayanlar: gerçek oturum açılışı (`--startup`) ve "Girişte Discord'u da aç", sertifikalı imza.
- `macos/docs/` altına kullanım ve güven sınırları belgeleri yazılır.
- Çıkış: canlı doğrulama listesi bu Mac'te tamamlanır ve sonuçlar ayrı raporlanır.

**Aşama 3 — Yayın.** Ayrı karar gerektirir.

- Evrensel ikili (macOS 26 ve öncesindeki Intel Mac'ler).
- İmza ve notarization kararı.
- Paketleme.
- Mac motoru için karşılık gelen kaynak ve lisans envanteri.
- Sürüm numaralandırması.
- Kök README'ye Mac bölümü. Bu adım `macos/` dışına dokunur ve ayrıca onaylanır.

## 12. Açık riskler ve yedek planlar

| Risk | Doğrulama | Yedek plan |
| --- | --- | --- |
| Çalışma anında proxy (sarmalayıcı) Dock açılışında çalışmayabilir. | Aşama 0: doğrulandı (iki açılış, gerçek Dock tıklaması dahil) | Discord menüden argümanla açılır (Deney A ile doğrulandı); Dock'a konabilen küçük bir başlatıcı eklenir. |
| Ana uygulama güncellemesi köprüden geçmeyebilir. | Aşama 0: doğrulandı (yeni güncelleyici ve ShipIt, 0.0.397 → 0.0.415) | Oturum boyunca `SKIP_HOST_UPDATE` sahiplenilen ayar olarak yazılır ve geri alınır. |
| macOS, Discord'un veri klasörüne erişimi engelliyor ve izin penceresi göstermiyor (TCC). | Aşama 0: doğrulandı | Tam Disk Erişimi gerekir; uygulama yönlendirir. İzin verilmezse profil değişikliği yapılamaz; yalnız argümanla açılış kalır ve güncelleme yapılamaz. |
| Ad-hoc imzalı uygulamada TCC izni her yeniden derlemede sıfırlanır. | Aşama 2 | Sabit imza kimliği (yerel kişisel sertifika veya Developer ID). |
| DiscordAccess'in kendi veri klasörü etiketlenirse Discord kanca dosyasını okuyamaz. | 1f: uygulandı | Kanca sarmalayıcıya gömülür. Discord'un yazdığı kayıtlar Discord'un kendi klasörüne yazılır. |
| Güncelleyici oturum sırasında yeni bir çekirdek nesli kurarsa sarmalayıcı devre dışı kalır. | 1f: tüm nesiller sarılıyor | Windows'taki gibi tüm nesiller sarılır; oturum başında yeniden denetlenir. |
| Discord'un kendi giriş öğesiyle açılış sırası koordine edilemez. | Tasarım gereği | Belgelenir; erken açılışta uyarı verilir. |
| Job nesnesi olmadığı için çökme sonrası motor kalabilir. | Aşama 1 | Bir sonraki açılışta yetim motor temizlenir. Temizlik motorun yoluna bakar; uygulama taşınmışsa eski yoldaki yetim motor kalır. Zararsızdır, çünkü kimlik bilgisini bilen yoktur. Aşama 2'de cdhash'e veya durum klasöründeki PID ve başlangıç zamanı kaydına göre eşleştirme değerlendirilir. |
| macOS yeni bir çalıştırılabilir dosyayı ilk çalıştırmada tarar. Motorun ilk açılışı bu yüzden gecikir. `syspolicyd` zaman zaman takılır ve sistem onu yeniden başlatana kadar yeni dosyaların açılışı bekler. | Aşama 1a: yeni kopyada 0,4 sn; sistem yükü altında 7–10 sn görüldü. Aşama 1b: `syspolicyd` takılıp yeniden başlarken bir derleme 160 sn bekledi. | DNS adayının motoru dinleyicisini 30 sn içinde açmalıdır (1d); motor çıkarsa sınır beklenmez. `EngineProcess.start`'ın varsayılanı Windows'taki gibi 12 sn kalır. |
| Önceki DNS adayının motoru toplanamazsa yeni aday başlatılmamalıdır (Windows `DnsConnection.Dispose`). | 1d: uygulandı | `DnsConnection.close()`, motor toplanamazsa DNS-E03 verir; seçim başka aday başlatmaz. |
| Motor yalnız `PATH` ortam değişkeniyle başlatılıyor; dış DoH/TLS bağlantısı birim testlerinde denenmiyor. | 1d canlı doğrulama (2026-10-15, bu Mac'in engelli ağı): otomatik seçim ilk adayı (Cloudflare, IP sertifikası) seçti; Gateway API, güncelleme sunucusu ve WebSocket HELLO kapı üzerinden doğrulandı; üç sağlayıcı da Gateway API'ye erişti. | Canlı denetim normal test çalıştırmasına girmez; `-Xswiftc -DDISCORDACCESS_LIVE` ile derlenir. |
| Bir köprü isteği, indirme dahil, en fazla 180 sn sürer (Windows'ta da aynı). Yavaş ağda büyük bir indirme yarıda kesilir; örneğin 154 MB'lık tam paket 0,85 MB/s'nin altında. | 1e | Windows'la aynı bırakıldı. Gerekirse indirmede toplam süre yerine yalnız boşta kalma süresi uygulanır. |
| SMAppService ve bildirimler yerel imzalı uygulamada kısıtlı olabilir. | Aşama 2 | Kullanıcı LaunchAgent plist'i; bildirim yerine menü durum metni. |
| Discord güncellemesi profil yapısını değiştirebilir. | Sürekli | Tanınmayan yapıda değişiklik yapılmaz; kullanıcı bilgilendirilir. |
| macOS 13–26'da test yapılmadı. | — | Yalnız macOS 27'de doğrulandığı belirtilir. |

## 13. Kapsam dışı

- Genel sistem proxy, DNS veya yönlendirme değişikliği; ağ uzantısı; TUN; yönetici yetkisi.
- `Discord.app` paketini değiştirmek.
- Discord PTB ve Canary.
- Windows kaynaklarında, derlemesinde, testlerinde veya yayın betiklerinde değişiklik.
