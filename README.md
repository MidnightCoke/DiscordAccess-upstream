# DiscordAccess

Windows'ta kurulu resmi Discord Stable için sistem tepsisinde çalışan bağlantı yardımcısı. Güncel sürüm **v4.18**.

`DiscordAccess.exe` bağlantıyı hazırlar; Discord'u kendi masaüstü veya Başlat menüsü simgenizden açarsınız. Kısayolun gerçek Discord hedefi korunur, yalnız oturumun yerel proxy argümanları eklenir. Ayrı Discord veya profil kopyası oluşturulmaz; mevcut hesabınız kullanılır. Açık CMD penceresi gerekmez.

## Hazır Windows paketini indir

**[DiscordAccess-v4.18.zip dosyasını indir](https://github.com/alpertknn/DiscordAccess/releases/download/v4.18/DiscordAccess-v4.18.zip)**

ZIP'i tamamen kısa, kalıcı bir yerel klasöre çıkarın. `DiscordAccess.exe` ve `engine/sing-box.exe` aynı paket içinde bulunmalıdır. `DiscordAccess.exe` dosyasını açın; hazır paket için derleme gerekmez. `Baslat.cmd` kaldırıldı.

GitHub'daki **Code > Download ZIP** ile Releases bölümündeki **Source code** dosyaları yalnız kaynak kodudur; program EXE'si ve motor içermez. Geliştirme için bu dosyaları kullanacaksanız önce “Kaynaktan hazırlama” adımlarını tamamlayın. Depo private olduğu sürece hazır indirmeye erişmek için depoya erişimi olan GitHub hesabınızla giriş yapın. [Tüm sürümler](https://github.com/alpertknn/DiscordAccess/releases).

İndirilen ZIP'in SHA-256 değerini `Get-FileHash .\DiscordAccess-v4.18.zip -Algorithm SHA256` ile hesaplayıp aynı Release'teki `SHA256SUMS.txt` ile karşılaştırabilirsiniz. Hash dosyası kod imzası sağlamaz.

## Gereksinimler

- Windows 10/11 x64 ve .NET Framework 4.8.
- Yazma izniniz olan resmi Discord Stable kurulumu.
- Yalnız kaynaktan derlemek için Windows'un .NET Framework x64 C# derleyicisi.
- Node.js: yalnız JavaScript testleri için.

Yönetici olarak çalıştırmayın. Bu proje Windows'un genel proxy, DNS veya yönlendirme ayarlarını değiştirmez; ağ sürücüsü veya sistem servisi kurmaz.

## Windows uygulama denetimi

Hazır paket doğrudan EXE ile çalışır. EXE ve motor Windows'un güvenlik değerlendirmesine tabidir; tepsi modu veya açık kaynak lisansı uygulamalara kod imzası sağlamaz. Proje Windows güvenlik ayarlarını değiştirmez ve engel kaldıran komut çalıştırmaz.

## Kaynaktan hazırlama

Depo klasöründe PowerShell açın:

```powershell
powershell -NoProfile -File scripts/Fetch-Engine.ps1
.\Build.cmd
```

Motor betiği resmi sing-box 1.14.3 Windows amd64 sürümünü indirir; ZIP ve EXE SHA-256 değerlerini doğrular. Motor veya derlenmiş program Git geçmişine dahil değildir. Doğrulanmış aynı motor zaten `engine/sing-box.exe` konumundaysa yeniden indirilmez.

## Kullanım

1. Discord'u sistem tepsisinden tamamen kapatın.
2. `DiscordAccess.exe` dosyasını açıp sistem tepsisinde bağlantı hazır bildirimini bekleyin.
3. Discord'u kendi simgenizden açın. DiscordAccess tepside çalışırken Discord'u kapatıp aynı simgeden tekrar açabilirsiniz.
4. Çıkarken önce Discord'u tamamen kapatın, ardından DiscordAccess tepsi simgesine sağ tıklayıp **Çıkış** seçin.

EXE'yi tekrar açmak ikinci bağlantı/motor oluşturmaz; mevcut tepsi oturumuna durum isteği iletir. Tepside **Discord'u aç**, **Yeniden bağlan**, **Bağlantıyı kontrol et**, **Windows ile başlat** ve **Çıkış** bulunur. Elle açılışta Discord kendiliğinden başlamaz.

## Windows açılış sırası

İlk başarılı bağlantıdan sonra yalnız mevcut kullanıcı için DiscordAccess otomatik başlangıcı hazırlanır. Discord'un seçili resmi kurulumuna ait tanınan kişisel `Run` kaydı varsa, özgün komut ve etkin/devre dışı tercihi kurtarma kaydında korunur. Windows'a girişte önce DiscordAccess hazırlanır; yalnız Discord'un otomatik açılma tercihi etkinse bağlantı hazır olduktan sonra resmi Discord bir kez açılır. Discord'un otomatik açılması kapalıysa yalnız bağlantı hazırlanır.

Tepside **Windows ile başlat** seçeneğini kapatmak DiscordAccess'in başlangıç kaydını kaldırır ve özgün Discord kaydını kullanıcı değişikliklerinin üzerine yazmadan geri alır. Sonraki elle açılışlar bu kapalı tercihi korur. Normal **Çıkış** seçimi otomatik başlangıç tercihini kapatmaz.

Bağımsız iki `Run` kaydı açılış sırasını garanti etmediği için özgün Discord kaydı bağlantı yardımcısı tarafından koordine edilir ([Windows belgesi](https://learn.microsoft.com/windows/win32/setupapi/run-and-runonce-registry-keys)). Tanınan Discord kaydı sonradan tekrar oluşturulursa tepsi oturumu bunu beş saniyede bir kontrol eder. Tanınmayan/değişmiş komutlar veya birden fazla kayıt korunur ve uyarı verilir. Seçili Discord için HKLM/başlangıç klasörü kaydı varsa sıra koordinasyonu kurulmaz; bu kayıtlar değiştirilmez.

Paketi bağlantı açıkken taşımayın. Başlangıç kaydı açıkken başka klasöre geçecekseniz önce tepsiden **Windows ile başlat** seçeneğini kapatın; yeni kalıcı klasörde tekrar etkinleştirin. Uzun başlangıç komutları Windows'un 260 karakter sınırına takılırsa paket için daha kısa klasör kullanın.

Sürekli durumda bir DiscordAccess ve bir sing-box motoru çalışır. Discord'un kendi Electron alt süreçleri normaldir; bunlar ek Discord kopyası değildir ve program tarafından kapatılmaz.

Kurulum, doğrulanmış hatırlanan klasör, `%LOCALAPPDATA%\Discord` ve kişisel Discord kısayollarından bulunur. Başka diskte bulunamazsa:

```powershell
.\DiscordAccess.exe --discord-path "D:\Programlar\Discord"
```

Kurulum klasörü, `Discord.exe`, `Update.exe` veya `app-sürüm` klasörü kabul edilir. Yalnız kurulum kökü hatırlanır; sürüm sonraki açılışta yeniden bulunur. Tam disk taraması yapılmaz. PTB/Canary, ağ paylaşımı ve junction/symlink kurulumları desteklenmez.

Önceki konsol akışı gerekirse `DiscordAccess.exe --console` ile kullanılabilir:

| Konsol komutu | İşlev |
| --- | --- |
| `Q` + Enter | Bağlantıyı kapatır; normal Discord sürecini öldürmez. |
| `T` + Enter | Bağlantı tanısı. |
| `D` + Enter | Discord ek dosyası bağlantısıyla indirme. |
| `A` + Enter | Uyumlu kısayol bulunmazsa seçilen resmi Discord'u açma. |

Tepsi modu açıkken konsol indirmesine geçecekseniz önce Discord'u tamamen kapatın ve DiscordAccess tepsisinden **Çıkış** seçin. Paket klasöründe `DiscordAccess.exe --console` açın; bağlantı hazır olunca `D` + Enter ile ek dosyası bağlantısını yapıştırın. İkinci EXE açmak açık tepsi oturumunu konsola dönüştürmez.

Discord içindeki ek dosyası indirme desteği korunur. Tanınan modül girişine geçici destek eklenir; normal `settings.json` dosyasındaki iki güncelleme uç noktası oturumun yerel köprüsüne gider. Discord EXE'si, güncelleyici ve `app.asar`/`core.asar` değiştirilmez. Hesap veya profil kopyalanmaz.

## Geri alma ve güncelleme

Discord açıkken DiscordAccess kapatılırsa geri alma kaydı kalabilir. Discord'u tamamen kapatıp aşağıdaki komutu çalıştırın veya bağlantıyı yeniden başlatın:

```powershell
.\DiscordAccess.exe --restore
```

Discord'un uygulama sürümü veya desktop core modülü güncellenirse Discord'u tamamen kapatın, tepsiden **Çıkış** seçin ve `DiscordAccess.exe` dosyasını yeniden açın. Oturum boyunca doğrulanan sürümün dosyaları tutulur; yeni sürüm ve modül desteği sonraki başlangıçta hazırlanır. `--restore`, bağlantı/kısayollar ile birlikte DiscordAccess otomatik başlangıcını da geri alır ve kapalı tercih bırakır.

Discord EXE'sini doğrudan açmak ve `discord://` bağlantıları kısayol akışının kapsamına girmez. Koordine edilmiş Windows başlangıcı resmi Discord'u sabit proxy argümanlarıyla açar. Ortak Başlat menüsü kısayolları okunabilir, değiştirilmez. Ses/video UDP akışı doğrudan kalır. Her internet sağlayıcısı veya tüm ses/yayın işlevleri için başarı garantisi verilmez.

Kayıtlar `%LOCALAPPDATA%\DiscordAccess\v3` konumundadır. Bağlantı açıkken paket klasörünü taşımayın. Proje imzasızdır; Smart App Control veya anti-cheat onayı olduğunu iddia etmez.

## Geliştirme

Derleme, testler ve ekip çalışma akışı için [CONTRIBUTING.md](CONTRIBUTING.md) dosyasına bakın. v4.18, v4.17'nin bağlantı ve başlangıç akışını korur; dağıtım lisans bildirimlerini ve tepsi moduna uygun indirme hata metnini tamamlar. Loglar, hesap/profil dosyaları ve yerel test çıktıları depoya dahil edilmez.

Hata bildirirken program ve Windows sürümünü, yapılan işlemi ve görünen kısa hata kodunu yazın. Discord profili, kurtarma `journal.json` dosyası, hesap token'ı veya imzalı dosya bağlantısı paylaşmayın. Yerel kayıtlar kişisel yol içeriyorsa paylaşmadan önce bu kısımları çıkarın.

## Lisans

DiscordAccess kaynak kodu [MIT](LICENSE) lisansıyla paylaşılır. Ayrı sing-box motorunun kendi GPL bildirimi [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt), gömülü bağımlılık ve Go runtime bildirimleri [ENGINE-THIRD-PARTY-NOTICES.txt](licenses/ENGINE-THIRD-PARTY-NOTICES.txt), sabit sürüm ve kaynak bilgileri [engine-source-manifest.json](licenses/engine-source-manifest.json) içindedir. Hazır paketteki `LISANSLAR.txt` bu metinleri birlikte içerir. Discord uygulaması bu depoda dağıtılmaz; bu proje Discord'un resmi ürünü değildir.
