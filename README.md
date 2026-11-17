# Hızlı Aktar ⚡

İki iPhone arasında çok sayıda fotoğrafı ve videoyu **orijinal kalitesinde** (birebir aynı dosya) ve hızlı göndermek için yapılmış bir uygulama.

## Neden AirDrop'tan hızlı?

İki telefon arasındaki radyo bağlantısı AirDrop'la aynı (doğrudan Wi‑Fi). Hızın kaynağı bu bağlantının çok daha verimli kullanılması:

| | AirDrop | Hızlı Aktar |
|---|---|---|
| Dosya hazırlama | Gönderimden önce hepsini paketler | Hazırlama ile gönderme **aynı anda** yapılır |
| Aynı anda giden dosya | 1 akış | **4 paralel akış** (1–8 arası ayarlanabilir) |
| Karşıda zaten olan fotoğraflar | Yine gönderilir | **Atlanır** (hiç gönderilmez) |
| Bağlantı koparsa | Baştan başlar | **Kaldığı yerden** devam eder |
| Fotoğraflar'a kaydetme | Sonda tek seferde | Gelirken **20'şerli gruplar** halinde |
| Kalite | Orijinal | Orijinal (HEIC/ProRAW/Live Photo/4K video birebir) |

Ekranda canlı MB/sn göstergesi var; AirDrop'la kendi telefonlarında karşılaştırabilirsin.

## Özellikler
- **Gönder:** Fotoğraflar seçicisinden sınırsız seçim (parmakla sürükleyerek toplu işaretleme), ya da tek dokunuşla *Son 7 gün / Son 30 gün / Bu yıl / Tüm kütüphane*.
- **Al:** Gelenler Fotoğraflar'a orijinal tarih, konum, favori bilgisiyle kaydedilir; istersen gönderen adına ayrı bir albüme.
- **İyileştir:** Seçtiğin fotoğrafların 2× çözünürlüklü, gürültüsü azaltılmış, netleştirilmiş kopyasını oluşturur (orijinal yerinde kalır).

## Kurulum (sadece Windows ile)

### 1) IPA dosyasını GitHub'da derle
1. github.com'da yeni bir **public** repo aç: `HizliAktar`.
2. Bu klasördeki her şeyi (gizli `.github` klasörü dahil) repoya yükle.
3. Repoda **Actions** sekmesi → *Build IPA* çalışır (~5 dk).
4. Bitince çalışmaya tıkla → altta **HizliAktar-ipa** dosyasını indir, zip'ten `HizliAktar.ipa`'yı çıkar.

### 2) iPhone'a yükle (Sideloadly)
1. Bilgisayara **iTunes** ve **iCloud**'u apple.com'dan kur (Microsoft Store sürümünü değil).
2. **Sideloadly**'yi kur (sideloadly.io).
3. iPhone'u kabloyla bağla, telefonda "Bu Bilgisayara Güven"e dokun.
4. `HizliAktar.ipa`'yı Sideloadly'ye sürükle, Apple ID'ni yaz, **Start**.
5. iPhone'da: **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu → Aç** (telefon yeniden başlar).
6. **Ayarlar → Genel → VPN ve Aygıt Yönetimi** → Apple ID'ne dokun → **Güven**.
7. Aynısını ikinci iPhone için de yap.

> Ücretsiz Apple ID ile uygulama 7 gün çalışır. Süre dolunca Sideloadly'de tekrar **Start**'a basman yeterli; uygulama verileri silinmez.

### İlk açılışta
- Fotoğraflar izninde **Tam Erişim** seç.
- "Yerel ağdaki aygıtları bulma" iznine **İzin Ver** de.

## Kullanım
1. Alacak telefonda: **Al → Almaya Başla**.
2. Gönderen telefonda: **Gönder** → fotoğrafları seç → alıcıyı seç → **Gönder**.
3. İki telefonda da uygulama açık kalsın (ekran kendiliğinden kapanmaz).

## En yüksek hız için
- İki telefon yan yana olsun, Wi‑Fi ve Bluetooth açık olsun (Wi‑Fi'ye bağlı olmak gerekmez).
- **Düşük Güç Modu** kapalı olsun.
- Gönderen telefonda *iPhone Saklama Alanını Optimize Et* açıksa, orijinali iCloud'da kalan fotoğraflar önce indirilir; bu kısım internet hızına bağlıdır.
