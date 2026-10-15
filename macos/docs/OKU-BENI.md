# DiscordAccess (macOS) — kullanım

Bu notlar **macos-v0.1** ön sürümünü anlatır. Ön sürüm yalnız Apple Silicon (arm64) Mac'lerde çalışır ve yalnız macOS 27'de denendi. Ayrıntılı tasarım: [2026-10-14-macos-tasarim.md](2026-10-14-macos-tasarim.md).

## Gereksinimler

- Apple Silicon Mac, macOS 13 veya üstü.
- Resmi Discord (Stable) uygulaması: `/Applications/Discord.app` ya da `~/Applications/Discord.app`. PTB ve Canary desteklenmez.
- Normal kullanıcı hesabı. DiscordAccess yönetici (root) olarak çalışmaz.

## Hazır paketi kurma

1. [Releases](https://github.com/alpertknn/DiscordAccess/releases) sayfasındaki **macos-v0.1** sürümünden `DiscordAccess-macos-v0.1.zip` dosyasını indirip açın. `DiscordAccess-macos-v0.1-engine-source.zip` motorun kaynak paketidir; çalıştırmak için gerekmez.
2. `DiscordAccess.app`'i Finder'da Uygulamalar klasörüne sürükleyin.
3. Uygulama Apple tarafından imzalanmamış ve onaylanmamıştır. Bu yüzden ilk açılışta macOS "Apple, DiscordAccess'in kötü amaçlı yazılım içermediğini doğrulayamadı" der:
   - **Done**'a basın.
   - System Settings > Privacy & Security'yi açın. En alttaki **Security** bölümünde DiscordAccess için **Open Anyway**'e basıp parolanızı girin.
   - Uygulamayı yeniden açın; son pencerede de **Open Anyway**'i seçin.

   Bu onay bir kez yapılır.
4. Ardından aşağıdaki "İlk açılış" adımlarını izleyin.

Paketteki `LISANSLAR.txt` lisans bildirimlerini, `KAYNAK.txt` kaynak paketinin kimliğini içerir. İndirilen dosyaların SHA-256 değerlerini aynı sürümdeki `SHA256SUMS.txt` ile karşılaştırabilirsiniz:
```bash
shasum -a 256 DiscordAccess-macos-v0.1.zip
```
Hash dosyası kod imzası sağlamaz.

## Kaynaktan derleme

1. Motoru derleyin. Betik, sabit SHA-256 ve cdhash'le eşleşmeyen bir motoru kopyalamaz:
   ```bash
   python3 macos/scripts/build-engine.py --out macos/build/engine/sing-box
   ```
2. Uygulama paketini kurun. Betik paketin yolunu en sonda yazar (`macos/build/apps.noindex/<zaman>/DiscordAccess.app`); önceki derlemeleri silmez.
   ```bash
   macos/scripts/build-app.sh
   ```
   Anahtar zincirinizde bir kod imzalama kimliği varsa paketi onunla imzalatabilirsiniz. Böylece Tam Disk Erişimi izni yeniden derlemelerde korunur:
   ```bash
   DISCORDACCESS_SIGN_IDENTITY="DiscordAccess Local Signing" macos/scripts/build-app.sh
   ```
3. Paketi Uygulamalar klasörüne kopyalayın. Kendi derlediğiniz paket internetten gelmediği için "Open Anyway" adımı gerekmez:
   ```bash
   ditto macos/build/apps.noindex/<zaman>/DiscordAccess.app /Applications/DiscordAccess.app
   ```

## İlk açılış

1. Discord'u tamamen kapatın (Discord > Discord'dan Çık ya da Cmd+Q).
2. DiscordAccess'i Uygulamalar klasöründen açın. Simgesi Dock'ta değil, menü çubuğunda görünür.
3. macOS, Discord'un veri klasörünü öteki uygulamalardan korur ve bunun için izin penceresi göstermez. İlk açılışta "Tam Disk Erişimi gerekiyor" uyarısı çıkar:
   - "Sistem Ayarları'nı aç" düğmesine basın ve Tam Disk Erişimi'nde DiscordAccess'i açın.
   - Ardından uygulamayı yeniden başlatın.
   - İzin verilmeden Discord ayarları değiştirilmez.
   - Ad-hoc imzalı derlemede bu izin her yeni derlemeden sonra yeniden verilir.
4. "Bağlantı hazır" bildirimini bekleyin. Discord'u kendi simgesinden (Dock, Launchpad, Spotlight) ya da menüden "Discord'u aç" ile açın. Mevcut kurulumunuz ve hesabınız kullanılır; kopya oluşturulmaz.
5. Çıkarken önce Discord'u kapatın, sonra menüden Çıkış'ı seçin. Discord açıkken çıkarsanız Discord kapatılmaz. Geçici ayarların kurtarma kaydı korunur; ayarlar bir sonraki açılışta ya da `--restore` ile geri alınır.

## Menü

- **Durum satırı:** bağlantının durumu.
- **Discord'u aç:** bağlantı hazırken Discord'u açar. Discord zaten açıksa ikinci kez açmaz.
- **Yeniden bağlan:** kapanmış ya da kurulamamış bağlantıyı yeniden kurar.
- **Bağlantıyı kontrol et:** Discord'a HTTPS erişimini ve Gateway bağlantısını (HELLO) anonim olarak denetler. Hesap bilgisi gönderilmez.
- **Oturum açılışında başlat:** girişte DiscordAccess'i başlatır.
  - İlk başarılı bağlantıdan sonra, siz kapatmadıysanız kendiliğinden açılır. Kapattığınızda kapalı kalır.
  - Yalnız güvenli bir konumdaki uygulama kaydolur; Uygulamalar klasörü buna uygundur. Harici diskler ve başkalarının değiştirebildiği klasörler reddedilir.
  - macOS onay isterse Sistem Ayarları > Genel > Giriş Öğeleri'nde DiscordAccess'e izin verin.
- **Girişte Discord'u da aç:** oturum açılışında bağlantı hazır olunca Discord'u bir kez açar; varsayılan olarak kapalıdır. Discord'un kendi "başlangıçta aç" ayarını kapatın; yoksa Discord bağlantıdan önce açılır ve bağlantı kurulamaz.
- **Çıkış:** bağlantıyı kapatır ve geçici ayarları geri alır.

DiscordAccess'i yeniden açmak ikinci bir oturum başlatmaz; çalışan uygulama durumunu bildirir.

## Komut satırı

Seçenekler uygulamanın içindeki programa verilir: `/Applications/DiscordAccess.app/Contents/MacOS/DiscordAccess <seçenek>`.

| Seçenek | Ne yapar |
| --- | --- |
| `--console` | Bağlantıyı Terminal'de açar. A + Enter: Discord'u aç. Q + Enter ya da Ctrl+C: kapat. T: tanılama. D: ek dosyası bağlantısını yapıştırıp `~/Downloads/DiscordAccess` altına indir. |
| `--restore` | Discord kapalıyken geçici Discord ayarlarını geri alır. |
| `--verify-package` | Motoru başlatmadan motorun ve kancanın bütünlüğünü doğrular. |
| `--dns=auto`, `--dns=cloudflare`, `--dns=cloudflare-ip`, `--dns=google` | DNS seçimi; varsayılan otomatik seçimdir. |
| `--dns-record-fragment` | Seçilen DoH bağlantısında TLS kayıt parçalamayı açar. |
| `--discord-path=/…/Discord.app` | Standart konumda olmayan bir Discord kurulumunu seçer. |
| `--help` | Kullanımı gösterir. |

Terminal'den çalıştırıldığında macOS, Tam Disk Erişimi'ni Terminal uygulamasından ister. Menü çubuğu uygulaması açıkken ikinci bir oturum başlamaz.

## Ne değişir, ne değişmez

- Discord.app paketine dokunulmaz.
- Profilde yalnız iki şey geçici olarak değişir: Discord'un çekirdek modülünün giriş dosyası (oturum sarmalayıcısı) ve `settings.json` içindeki iki güncelleme ayarı. Değişiklikler önce kurtarma kaydına yazılır, çıkışta geri alınır. Sonradan sizin değiştirdiğiniz değerlerin üzerine yazılmaz.
- Genel proxy, DNS ya da yönlendirme ayarı değişmez. Sistem servisi, sürücü ya da ağ uzantısı kurulmaz.
- Ses ve görüntünün UDP trafiği doğrudan kalır, Windows'taki gibi.
- Discord'un Spotify bağlantısı oturum sırasında çalışmaz; izin listesi Windows'takiyle aynıdır.
- Ek dosyaları Discord içinden kayıt penceresiyle indirilir. Terminal'deki D yalnız yedek yoldur.

## Kayıtlar ve dosyalar

- `~/Library/Application Support/DiscordAccess/` (klasör 0700, dosyalar 0600):
  - `session.log`: oturum kaydı; 256 KiB'a ulaşınca yeniden başlar.
  - `preferences.json`: menü tercihleri.
  - `session.lock`: tek oturum kilidi.
  - `installed-session/journal.json`: oturum açıkken kurtarma kaydı. Kişisel veridir.
- `~/Library/Application Support/discord/DiscordAccess-downloads.log`: Discord içindeki indirme desteğinin kaydı. Yalnız sabit kodlar ve bayt sayıları içerir.
- `.discordaccess-fs-*.preserved`: bir çakışmada korunan içerik. Silmeyin, paylaşmayın.

## Sık görülen iletiler

- **[DSC-E05]:** Discord açık. Discord'u Cmd+Q ile kapatıp "Yeniden bağlan"ı seçin.
- **[PRF-E04]:** Tam Disk Erişimi yok. İlk açılıştaki adımları izleyin.
- **[SES-E01]:** Bağlantı Discord açıkken kapandı. Discord'u kapatıp DiscordAccess'i yeniden açın ya da `--restore` çalıştırın.
- **[SYS-E03]:** Uygulama güvenli bir konumda değil. Uygulamalar klasörüne taşıyıp oradan açın.

Hata bildirirken sürümü, kısa hata kodunu ve adımları yazın. Hesap token'ı, profil dosyaları, kurtarma kaydı, imzalı ek dosyası adresi ya da kişisel yollar paylaşmayın. Güvenlik bildirimleri için kök dizindeki [SECURITY.md](../../SECURITY.md) dosyasına bakın; macOS'un güven sınırları [SECURITY-NOTES.md](SECURITY-NOTES.md) içindedir.
