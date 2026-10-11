# DiscordAccess

Windows'ta kurulu resmi Discord Stable için CMD üzerinden çalışan bağlantı yardımcısı. Başlangıç sürümü **v4.16**.

CMD bağlantıyı hazırlar; Discord'u kendi masaüstü veya Başlat menüsü simgenizden açarsınız. Kısayolun gerçek Discord hedefi korunur, yalnız oturumun yerel proxy argümanları eklenir. Ayrı Discord veya profil kopyası oluşturulmaz; mevcut hesabınız kullanılır.

## Gereksinimler

- Windows 10/11 x64 ve .NET Framework 4.8.
- Yazma izniniz olan resmi Discord Stable kurulumu.
- Derlemek için Windows'un .NET Framework x64 C# derleyicisi.
- Node.js: yalnız JavaScript testleri için.

Yönetici olarak çalıştırmayın. Bu proje Windows'un genel proxy, DNS veya yönlendirme ayarlarını değiştirmez; ağ sürücüsü veya sistem servisi kurmaz.

## Windows ilk açılış engeli

Smart App Control, internetten indirilen ZIP'ten çıkan `Baslat.cmd` veya kaynak hazırlama betiklerini çalışmadan önce "Web’den tehlikeli dosya uzantısı" mesajıyla engelleyebilir. Yalnız kaynağını doğruladığınız ve güvendiğiniz bu proje indirmesi için:

1. ZIP'i çıkarmadan önce sağ tıklayın, **Özellikler > Genel** bölümünü açın.
2. Varsa **Engellemeyi kaldır** seçeneğini işaretleyip **Uygula**'ya basın.
3. ZIP'i yeni bir klasöre çıkarın; aşağıdaki hazırlama ve kullanım adımlarını izleyin.

Paket zaten çıkarılmışsa yalnız `Baslat.cmd` için aynı Özellikler adımını uygulayabilirsiniz. Alternatif olarak paketin çıkarıldığı klasörde PowerShell açın:

```powershell
Unblock-File -LiteralPath '.\Baslat.cmd'
```

Bu işlem dosya içeriğini değiştirmeden Windows'un indirme sırasında eklediği `Zone.Identifier` bilgisini kaldırır. Bu bilgi Git ile taşınmaz; depodaki kod değişikliği sonraki indirmelerin işaretlenmesini önleyemez. CMD çalışmadan engellendiği için içine eklenecek bir komut da ilk açılış engelini çözemez.

Smart App Control açık kalabilir. `DiscordAccess.exe` veya `sing-box.exe` ayrıca engellenirse bu farklı bir imza/güven değerlendirmesidir; yukarıdaki adım EXE'lere SAC onayı sağlamaz. Ayrıntılar: [Microsoft'un tehlikeli dosya uzantısı açıklaması](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-has-blocked-an-app-with-a-dangerous-file-extension) ve [Unblock-File belgesi](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file).

## Kaynaktan hazırlama

Depo klasöründe PowerShell açın:

```powershell
powershell -NoProfile -File scripts/Fetch-Engine.ps1
.\Build.cmd
```

Motor betiği resmi sing-box 1.14.3 Windows amd64 sürümünü indirir; ZIP ve EXE SHA-256 değerlerini doğrular. Motor veya derlenmiş program Git geçmişine dahil değildir. Doğrulanmış aynı motor zaten `engine/sing-box.exe` konumundaysa yeniden indirilmez.

## Kullanım

1. Discord'u sistem tepsisinden tamamen kapatın.
2. `Baslat.cmd` dosyasını açıp bağlantı hazır mesajını bekleyin.
3. Discord'u kendi simgenizden açın. CMD açıkken aynı simgeden kapatıp tekrar açabilirsiniz.
4. Çıkarken önce Discord'u tamamen kapatın, ardından CMD'de `Q` yazıp Enter'a basın.

Kurulum, doğrulanmış hatırlanan klasör, `%LOCALAPPDATA%\Discord` ve kişisel Discord kısayollarından bulunur. Başka diskte bulunamazsa:

```powershell
.\Baslat.cmd --discord-path "D:\Programlar\Discord"
```

Kurulum klasörü, `Discord.exe`, `Update.exe` veya `app-sürüm` klasörü kabul edilir. Yalnız kurulum kökü hatırlanır; sürüm sonraki açılışta yeniden bulunur. Tam disk taraması yapılmaz. PTB/Canary, ağ paylaşımı ve junction/symlink kurulumları desteklenmez.

| CMD komutu | İşlev |
| --- | --- |
| `Q` + Enter | Bağlantıyı kapatır; normal Discord sürecini öldürmez. |
| `T` + Enter | Bağlantı tanısı. |
| `D` + Enter | Discord ek dosyası bağlantısıyla indirme. |
| `A` + Enter | Uyumlu kısayol bulunmazsa seçilen resmi Discord'u açma. |

Discord içindeki ek dosyası indirme desteği korunur. Tanınan modül girişine geçici destek eklenir; normal `settings.json` dosyasındaki iki güncelleme uç noktası oturumun yerel köprüsüne gider. Discord EXE'si, güncelleyici ve `app.asar`/`core.asar` değiştirilmez. Hesap veya profil kopyalanmaz.

## Geri alma ve güncelleme

Discord açıkken CMD kapatılırsa geri alma kaydı kalabilir. Discord'u tamamen kapatıp aşağıdaki komutu çalıştırın veya bağlantıyı yeniden başlatın:

```powershell
.\Baslat.cmd --restore
```

Discord'un uygulama sürümü veya desktop core modülü güncellenirse Discord'u tamamen kapatın, CMD'de `Q` ile çıkın ve `Baslat.cmd` dosyasını yeniden açın. Oturum boyunca doğrulanan sürümün dosyaları tutulur; yeni sürüm ve modül desteği sonraki başlangıçta hazırlanır.

EXE'yi doğrudan açmak, Windows otomatik başlangıcı ve `discord://` bağlantıları bu kısayol akışının kapsamına girmez. Ortak Başlat menüsü kısayolları okunabilir, değiştirilmez. Ses/video UDP akışı doğrudan kalır. Her internet sağlayıcısı veya tüm ses/yayın işlevleri için başarı garantisi verilmez.

Kayıtlar `%LOCALAPPDATA%\DiscordAccess\v3` konumundadır. Bağlantı açıkken paket klasörünü taşımayın. Proje imzasızdır; Smart App Control veya anti-cheat onayı olduğunu iddia etmez.

## Geliştirme

Derleme, testler ve ekip çalışma akışı için [CONTRIBUTING.md](CONTRIBUTING.md) dosyasına bakın. Üretim kaynak kodu v4.16 paketinden değiştirilmeden alınmıştır. Loglar, hesap/profil dosyaları ve yerel test çıktıları depoya dahil edilmez.

## Lisans

DiscordAccess kaynak kodu [MIT](LICENSE) lisansıyla paylaşılır. Ayrı sing-box motorunun kendi lisansı ve kaynak bağlantıları [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) içindedir. Discord uygulaması bu depoda dağıtılmaz; bu proje Discord'un resmi ürünü değildir.
