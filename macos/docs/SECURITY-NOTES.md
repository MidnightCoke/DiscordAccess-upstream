# Güvenlik sınırları (macOS)

Bu belge macOS sürümünün güvendiği ve güvenmediği şeyleri özetler. Ayrıntılar ve gerekçeler [tasarım belgesinin](2026-10-14-macos-tasarim.md) 8. bölümündedir. Otomatik testlerin geçmesi yazılımın açık içermediğini ya da her Discord ve ağ koşulunda çalışacağını kanıtlamaz. Gerçek hesapla kullanım, ses ve oturum açılışında başlatma ayrı doğrulamalardır; yapılanlar tasarım belgesinde tarihleriyle kayıtlıdır.

## Korunan teknik sınırlar

- **Yerel kapı:** yalnız 127.0.0.1'de dinler.
  - Kabul ettiği süreçler: seçili Discord.app'in beş dosyasından (`Discord` ve dört `Discord Helper`) birini çalıştıran, oturum hazır olduktan sonra başlamış ve Discord'un imzasını (Team ID `53Q6R32WPB`) taşıyan süreçler.
  - Uygulamanın kendi tanı istekleri de kabul edilir.
  - Kapı her bağlantının sahibini denetler. Yalnız Windows'taki izin listesinde bulunan Discord alanlarına izin verir. En fazla 64 bağlantı açılır.
  - Kayıtlarda adres, başlık ya da gövde yer almaz; yalnız sabit kategoriler bulunur.
- **Motor:** sabit SHA-256 ve cdhash ile doğrulanır.
  - Askıda başlatılır; imzası sabit değeri karşılamazsa hiçbir kodu çalışmadan durdurulur.
  - Yalnız loopback'te, her çalıştırmada rastgele bir kimlik bilgisiyle dinler.
  - Pakete değiştirilmeden gömülür.
  - Çökme sonrası kalan bir motor, bir sonraki açılışta kapatılır.
- **Güncelleme köprüsü:** Discord'un kendi güncelleyicisi için loopback'te, rastgele bir yol belirteciyle dinler.
  - Kapı gibi yalnız kabul edilen süreçlere yanıt verir.
  - Yalnız Discord'un alanlarına https ile ve kapı üzerinden gider.
  - Discord dışına yönlendirmeleri reddeder.
- **Profil değişiklikleri:** önce kurtarma kaydına yazılır. Atomik karşılaştır-ve-takas ile yapılır (`renamex_np`) ve `F_FULLFSYNC` ile diske yazılır.
  - Kullanıcının sonradan değiştirdiği değerin üzerine yazılmaz; tanınmayan içerik `.discordaccess-fs-*.preserved` olarak korunur.
  - Discord açıkken geri alma yapılmaz; Discord'un adı değiştirilmiş kopyaları da açık sayılır.
  - Kurtarma yalnız standart Discord klasörüne dokunur. Güncelleme ayarlarına yalnız Discord'un kendi https adreslerini geri yazar.
- **Durum klasörü:** 0700 ve ACL'siz; dosyalar 0600. Klasörün sahibi kullanıcı değilse ya da başkaları erişebiliyorsa profil değişikliği yapılmaz.
- **Tek oturum:** durum klasöründeki bir `flock` kilidiyle sağlanır. Kilit süreç bitene kadar tutulur; böylece ikinci bir örnek ilk oturumun değişikliklerine dokunamaz.
- **Discord'u açma:** `/usr/bin/open` ile yapılır.
  - `open` yalnız /dev/null'a bağlı standart tanıtıcılarla başlar (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
  - Discord'u Launch Services başlatır; Discord bu sürecin ortamını almaz.
- **Oturum açılışında başlatma:** yalnız güvenli bir konumdaki uygulama paketi kaydolur. Güvenli konumun koşulları:
  - kökten pakete her klasör ve paketteki her dosya kullanıcının ya da root'un;
  - başkaları yazamıyor (grup yalnız admin ise yazabilir) ve değişiklik izni veren ACL girdisi yok;
  - yolda bağ yok ve uygulama App Translocation altında değil;
  - yerel bir birimde ve birim sahipliği yok saymıyor.

  Giriş açılışında konum yeniden denetlenir. Güvenilmezse kayıt kaldırılır.
- **Ek dosyası indirme (Terminal'de D):** yalnız Discord'un ek dosyası adresleri kabul edilir (https, 443).
  - En fazla üç yönlendirme izlenir ve her biri yeniden doğrulanır.
  - Dosya yeni bir klasöre, bağ izlenmeden ve var olan bir dosyanın üzerine yazılmadan kaydedilir.
  - Dosya internetten indirildi olarak işaretlenir (karantina özniteliği).
  - İmzalı adres kayda, ekrana ya da dosya adına girmez.
- **Ekran ve kayıt satırları:** kontrol karakterleri ve metin yönü işaretleri boşluğa çevrilir. Böylece bir dosya adı Terminal'i yönlendiremez ya da uzantısını gizleyemez.
- **Tam Disk Erişimi:** yalnız Discord'un veri klasöründeki sahiplenilen dosyalar için kullanılır. Uygulama izni kendisi açmaz; gerekçesini söyler ve Sistem Ayarları'nı açar.

## Kapsam

DiscordAccess normal kullanıcı yetkisiyle çalışır. Genel proxy, DNS ya da yönlendirme ayarı değiştirmez; sistem servisi, sürücü ya da ağ uzantısı kurmaz. İndirilen dosyaları çalıştırmaz.

Aşağıdakiler için ayrı bir güvenlik sınırı iddia edilmez:

- Aynı kullanıcı yetkisini ele geçirmiş zararlı yazılım ya da root saldırganı. Örneğin Discord'un Electron ayarlarında `NODE_OPTIONS` açıktır: aynı kullanıcıyla çalışan bir süreç, Discord imzalı bir süreçte kod çalıştırabilir. Windows'ta da durum aynıdır.
- İmzanın içerikle ilgili garantisi. Kod imzası hangi dosyanın çalıştığını kanıtlar; içinde hangi kodun çalıştığını kanıtlamaz.
- Gatekeeper onayı. Uygulama imzasızdır ya da yerel bir sertifikayla imzalanır. Dağıtım için Developer ID ve notarization ayrı bir karardır.
- Kayıt sonrası izin değişiklikleri. Oturum açılışı kaydından sonra kullanıcının bağımsız olarak değiştirdiği izinleri, geçmiş bir denetim güvenceye alamaz. Giriş açılışındaki yeniden denetim yalnız konum taşınmasını ve izinlerin gevşemesini yakalar.

Normal hata bildirimlerinde hesap token'ı, profil dosyaları, kurtarma kaydı, imzalı ek dosyası adresi, `.preserved` dosyaları ya da kişisel yollar paylaşmayın. Güvenlik açığı bildirim yolu kök dizindeki [SECURITY.md](../../SECURITY.md) dosyasındadır.
