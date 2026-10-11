# Güvenlik sınırları

v4.19 güvenlik düzeltmeleri içerir. Otomatik kontrollerin geçmesi, yazılımın açık içermediğini veya her Discord/ağ koşulunda çalışacağını kanıtlamaz. Bu sürümün gerçek hesap, ses/yayın ve Windows yeniden başlatma denemesi ayrıca yapılmalıdır.

## Bu revizyondaki korumalar

- Yerel proxy düz HTTP `Upgrade` isteklerini motor kimlik bilgileri eklenmeden reddeder. HTTPS/WSS için mevcut CONNECT akışı korunur.
- Otomatik başlangıçtan önce EXE ve üst klasörlerin sahibi ve etkin yazma/silme izinleri doğrulanır. Başka standart kullanıcıların değiştirebildiği hedefe kalıcı başlangıç kaydı kurulmaz; kullanıcı izinleri değiştirilmez.
- Tek oturum kilidi, kullanıcı SID'siyle sınırlandırılmış özel Windows nesne ad alanında tutulur. Başka kullanıcının aynı görünür adı önceden oluşturması güvenilir oturum sayılmaz. Terk edilmiş kilit güvenli biçimde geri alınır; ikinci açılış çalışan oturuma durum isteği iletir.
- Dosya değiştirme işlemi, gerçekten yerinden çıkarılan dosyayı yedekleyip beklenen içerikle karşılaştırır. Çakışmada bilinmeyen veri korunur. Silme, doğrulanmış açık dosyanın tanıtıcısı üzerinden yapılır.
- Motor, kararlı sing-box 1.14.3 kaynakları ve sabit güvenlik güncellemeleriyle yeniden derlenir. Kaynak arşivi, araç zinciri, bağımlılık kilitleri ve sonuç EXE hash'i doğrulanır. Lisans envanteri dağıtılan EXE'nin Go build bilgisine dayanır.

## Kapsam

Program standart kullanıcı yetkisiyle çalışır. Yerel proxy yalnız doğrulanmış Discord süreçleri ve uygulamanın kendi işlemlerine açıktır. Genel Windows proxy/DNS/yönlendirme ayarı, sürücü, TUN veya sistem servisi kurulmaz. İndirilen dosyalar otomatik çalıştırılmaz. Resmî Discord EXE'si ve mevcut profil kullanılır; kısayol hedefi korunur.

Aynı kullanıcı yetkisini ele geçiren zararlı yazılım veya yönetici/SYSTEM saldırganı için ayrı bir güvenlik sınırı iddia edilmez. Dosya işlemleri Windows dosya adı alanında mutlak karşılaştır-ve-değiştir garantisi vermez; çakışma yedekleri kullanıcı içeriğini korumak içindir. Paket kaydı kurulduktan sonra kullanıcı izinleri bağımsız olarak değiştirilirse sonraki Windows açılışını geçmiş bir kontrol güvenceye alamaz.

Bu proje imzasızdır. Açık kaynak lisansı, hash kontrolü ve test başarısı Smart App Control veya anti-cheat onayı sağlamaz. Güvenlik politikaları düşürülmez; engellenen yerel testler farklı yükleme yöntemiyle çalıştırılmaz. Windows regresyonları ayrı GitHub Actions ortamında yapılır.

Hata bildirirken hesap token'ı, profil, imzalı ek dosyası URL'si, kurtarma journal'ı veya `.preserved` dosyalarını paylaşmayın. Program sürümü, kısa hata kodu ve kişisel verilerden arındırılmış yeniden üretim adımları yeterlidir.
