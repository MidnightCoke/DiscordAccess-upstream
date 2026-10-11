# Katkı rehberi

## Derleme ve kontroller

Windows x64 üzerinde .NET Framework 4.8 ve Node.js kullanın. Depo kökünde:

```powershell
powershell -NoProfile -File scripts/Fetch-Engine.ps1
.\Build.cmd
.\Test.cmd
node tests/attachment-download.test.cjs
node tests/external-wrapper.test.cjs
.\tests\shortcuts\Run.cmd
.\tests\launcher\Run.cmd
```

`Test.cmd`, ikinci Node testinin ihtiyaç duyduğu sentetik wrapper dosyalarını `work/` altında üretir; bu nedenle sırayı koruyun. Kısayol testleri ayrı, geçici fixture verileri kullanır. Başlatıcı testleri yalnız sahte bir konsol EXE'siyle eksik dosyaları, argüman ve çıkış kodlarını, Türkçe/boşluk/parantez içeren yolları kontrol eder. Kontroller gerçek Discord hesabı açmaz; ağ kontrolleri loopback ve sentetik yanıtlarla yapılır. Test çıktıları ve derlenen dosyalar Git dışında kalır.

Windows bir üretilmiş test EXE'sini engellerse bunu tam test başarısı olarak raporlamayın. Hangi grubun çalışmadığını ve kalan kontrolleri PR'da belirtin; Windows güvenlik ayarlarını değiştiren veya engeli aşan kod eklemeyin.

## Ekip çalışma akışı

`main` üzerinden kendi iş dalınızı açın:

```powershell
git switch main
git pull --ff-only
git switch -c feature/kisa-ad
```

Değişikliği tamamlayıp ilgili kontrolleri çalıştırdıktan sonra dalı pushlayın ve `main` hedefli bir pull request açın. PR açıklamasında somut sorunu, yeni davranışı, doğrulamayı ve kalan sınırları yazın. Mevcut çalışan sürümü değiştiren büyük düzenlemeleri küçük, incelenebilir değişikliklere ayırın.

## Korunması gereken davranış

- Resmi Discord kısayol hedefini ve mevcut profilini koruyun; helper hedefi veya ayrı kopya kullanmayın.
- CMD açılışında Discord'u otomatik başlatmayın; normal Discord sürecini kapanışta öldürmeyin.
- Genel Windows proxy/DNS/yönlendirme ayarı, TUN, sürücü veya yönetici gereksinimi eklemeyin.
- Proxy erişimini mevcut kullanıcı/oturumda doğrulanmış resmi Discord görüntüleri ve uygulamanın kendi tanı/indirme işlemleriyle sınırlandırın.
- Yol bulma ve kısayol taramasını sınırlı tutun. Kullanıcının değiştirdiği dosya veya ayarların üzerine geri almada yazmayın.
- İndirme adreslerini belirli Discord ek dosyası alanlarıyla sınırlayın; dosyaları otomatik çalıştırmayın.

Bağlantı, yol bulma, kısayol argümanları, modül desteği veya geri alma değişikliklerine uygun anlamlı fixture ekleyin. Anonim Gateway HELLO kontrolü, hesap girişi, mesaj, dosya veya yayın işlevlerinin canlı doğrulaması değildir; sonuçları ayrı belirtin.

## Depoya eklenmeyecek veriler

Token, parola, kod imzalama anahtarı, Discord profili, oturum/kurtarma kaydı, `.lnk`, gerçek kullanıcı yolu, IP veya dosya indirme bağlantısı paylaşmayın. Hata örneklerinde sentetik veriler kullanın. Log klasörleri, motor EXE'si, paketler ve diğer derleme çıktıları `.gitignore` kapsamındadır.

Motor sürümünü değiştirirken indirme URL'si, ZIP/EXE SHA-256 değerleri, uygulamanın bağımlılık doğrulaması ve üçüncü taraf bildirimlerini birlikte güncelleyin. Üretim paketine test veya yerel kayıt dosyalarını dahil etmeyin.
