/// Supabase oturumu + PKCE code-verifier'ı Keychain/Keystore'a taşıyan
/// adaptörler (review [P2-5]).
///
/// ## Sorun
/// `supabase_flutter 2.17.2` her ikisini de **SharedPreferences**'a yazar:
/// `SharedPreferencesLocalStorage` (oturum) ve `SharedPreferencesGotrueAsyncStorage`
/// (PKCE verifier) — bkz. `supabase_flutter/lib/src/supabase.dart:122-136`,
/// varsayılan oturum anahtarı `"sb-${host.split('.').first}-auth-token"`.
/// Yani UZUN ÖMÜRLÜ refresh token, uygulamanın geri kalanı Keychain/Keystore
/// kullanırken düz bir XML/plist dosyasında durur.
///
/// E2E sınırı bundan ETKİLENMEZ — çalınan bir refresh token yalnız şifreli veri
/// verir (CRYPTO.md §12/§13 doğru). Verdiği şey (a) çevrimdışı saldırıya açık
/// Argon2id-sarmalı master key ve (b) YAZMA erişimi: saldırgan her token
/// satırını tombstone'layabilir, sync bunu kullanıcının gerçek cihazlarına
/// sadakatle kopyalar. Ayrıca Android D2D transferinde bu dosya —
/// Keystore-sarmalı secure storage'ın aksine — OKUNABİLİR biçimde taşınır
/// (review [P1-2]), yani cihaz göçünden sağ çıkan tek kimlik bilgisi en zayıf
/// saklananıdır.
///
/// ## Sıralama kısıtı
/// `Supabase.initialize` `configureDependencies()`'ten ÖNCE çalışır
/// (`main.dart`), dolayısıyla bu adaptörler `locator<FlutterSecureStorage>()`'a
/// BAĞLANAMAZ; kendi örneklerini [secureStorageOptions] ile kurarlar. Seçenekler
/// DI'daki paylaşılan örnekle AYNI olmalı — tek tanım burada.
///
/// ## Hata politikası — vault verisinden KASITLI olarak farklı
/// Vault anahtar metadata'sı yeri doldurulamaz: orada bir Keystore hatası
/// SESSİZCE null dönmemeli (review [P1-2]: `resetOnError: false` + üstte
/// `keyAttributesCorrupted` ekranı). Oturum ise yeri doldurulabilir bir
/// ÖNBELLEKTİR: kullanıcı yeniden giriş yaparak aynısını üretir. Bu yüzden
/// buradaki okuma/yazma hataları YUTULUR → kullanıcı "çıkış yapmış" görünür ve
/// yeniden giriş yapar. Alternatif — istisnanın `Supabase.initialize` içinden
/// kaçması — açılışta KARA EKRAN olurdu ve o ekranda kurtarma yolu yoktur.
/// Vault'un anahtarları bundan bağımsızdır; oturum kaybı veri kaybı DEĞİLDİR.
library;

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Vault ve oturum depolarının PAYLAŞTIĞI secure-storage seçenekleri.
///
/// * `resetOnError: false` — fss 10.x Android varsayılanı `true`'dur ve bir
///   çözme hatasında kaydı KALICI OLARAK SİLER (review [P1-2]).
/// * `migrateWithBackup: true` — v9→v10 algoritma göçünü çökmeye dayanıklı
///   yapar; yarıda kalan bir göç aksi hâlde `resetOnError` koluna düşer.
/// * `unlocked_this_device` — iOS varsayılanı `unlocked`, yani öge şifreli bir
///   iTunes/Finder yedeğiyle YENİ CİHAZA taşınır. Belgelenen yeni-cihaz hikâyesi
///   sunucudan restore'dur (CRYPTO.md §12), keychain göçü değil (review [P3-1]).
///
/// `const` bir fabrika: DI tarafı da bunu çağırır → iki yerde ayrışamaz.
({AndroidOptions android, IOSOptions ios}) secureStorageOptions() => (
  android: const AndroidOptions(resetOnError: false, migrateWithBackup: true),
  ios: const IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  ),
);

/// [secureStorageOptions] ile kurulmuş, DI'dan BAĞIMSIZ bir örnek.
///
/// `Supabase.initialize` DI'dan önce koştuğu için locator kullanılamaz.
/// `FlutterSecureStorage` durumsuzdur (tüm durum platform tarafındadır), bu
/// yüzden ikinci bir örnek olması sorun değildir — seçenekler aynı olduğu
/// sürece aynı Keychain/Keystore ad alanını görürler.
FlutterSecureStorage _defaultStorage() {
  final options = secureStorageOptions();
  return FlutterSecureStorage(aOptions: options.android, iOptions: options.ios);
}

/// `Supabase.initialize`'ın varsayılan oturum anahtarı ile AYNI biçim.
///
/// `supabase_flutter/lib/src/supabase.dart:132` ile birebir: aynı anahtarı
/// üretmek, eski SharedPreferences kaydını GÖÇÜRMENİN tek yoludur (yoksa mevcut
/// kullanıcılar güncellemede çıkış yapmış olurdu).
String supabasePersistSessionKeyFor(String url) =>
    'sb-${Uri.parse(url).host.split('.').first}-auth-token';

/// Oturumu (refresh token dâhil) Keychain/Keystore'da tutan [LocalStorage].
///
/// Varsayılanın anlambilimi birebir korunur — özellikle [accessToken]: adına
/// rağmen SERİLEŞTİRİLMİŞ OTURUMUN TAMAMINI döndürür (gotrue onu `Session`
/// olarak çözer), yalnız access token'ı değil.
class SecureLocalStorage extends LocalStorage {
  SecureLocalStorage({
    required this.persistSessionKey,
    FlutterSecureStorage? storage,
    LocalStorage? legacy,
  }) : _storage = storage ?? _defaultStorage(),
       _legacy =
           legacy ??
           SharedPreferencesLocalStorage(persistSessionKey: persistSessionKey);

  /// Hem secure storage hem eski SharedPreferences kaydının anahtarı.
  final String persistSessionKey;

  final FlutterSecureStorage _storage;

  /// Yalnız GÖÇ için okunur: ilk açılışta buradan alınıp secure storage'a
  /// taşınır ve SİLİNİR.
  final LocalStorage _legacy;

  @override
  Future<void> initialize() async {
    await _migrateFromPrefs();
  }

  /// Tek yönlü, tek seferlik göç: eski düz-metin oturumu secure storage'a taşı,
  /// prefs kopyasını sil.
  ///
  /// Secure storage'da ZATEN bir kayıt varsa eski kopya sadece TEMİZLENİR — göç
  /// bitmiştir ve bayat prefs değeri güncel oturumu ezmemelidir.
  ///
  /// **`containsKey` fırlatırsa göç İPTAL edilir (doğrulama NEW-6):** hata
  /// "kayıt yok" ile aynı sayılırsa (bkz. [_hasSecure]) bayat prefs oturumu
  /// CANLI secure oturumun üzerine yazılabilirdi. Bilinmeyen ≠ yok; hiçbir şeye
  /// dokunmadan dönülür (prefs kopyası da DURUR) ve göç bir sonraki açılışta
  /// yeniden denenir.
  Future<void> _migrateFromPrefs() async {
    try {
      await _legacy.initialize();
      final stale = await _legacy.accessToken();
      if (stale == null) return;
      final bool secureHas;
      try {
        secureHas = await _storage.containsKey(key: persistSessionKey);
      } on PlatformException {
        return; // bilinmeyen → ne yaz ne sil (bir sonraki açılışta yeniden dene)
      }
      if (!secureHas) {
        await _storage.write(key: persistSessionKey, value: stale);
      }
      // Yalnız secure kopya sağlama alındıktan SONRA sil: arada bir çökme
      // olursa göç bir sonraki açılışta baştan denenir, oturum kaybolmaz.
      await _legacy.removePersistedSession();
    } catch (_) {
      // Prefs okunamadı/silinemedi ya da secure yazma reddedildi → göç bir
      // sonraki açılışta yeniden denenir. Açılışı BLOKLAMAZ.
    }
  }

  /// **YALNIZ [hasAccessToken] için** (doğrulama NEW-6). Burada hatayı "oturum
  /// yok" saymak doğrudur: sonuç kullanıcının yeniden giriş yapmasıdır, veri
  /// kaybı değil. Göç yolu bunu KULLANMAZ — orada aynı varsayım bayat bir
  /// oturumun canlı olanı ezmesine yol açardı.
  Future<bool> _hasSecure() async {
    try {
      return await _storage.containsKey(key: persistSessionKey);
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> hasAccessToken() => _hasSecure();

  @override
  Future<String?> accessToken() async {
    try {
      return await _storage.read(key: persistSessionKey);
    } on PlatformException {
      // Keystore/Keychain açılamadı → "oturum yok". Kullanıcı yeniden giriş
      // yapar; vault anahtarları ayrı ve etkilenmez (bkz. dosya başlığı).
      return null;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    try {
      await _storage.write(key: persistSessionKey, value: persistSessionString);
    } on PlatformException {
      // Oturum bu açılış boyunca bellekte yaşar, kalıcı olmaz.
    }
  }

  @override
  Future<void> removePersistedSession() async {
    try {
      await _storage.delete(key: persistSessionKey);
    } on PlatformException {
      /* zaten yok sayılır */
    }
  }
}

/// PKCE code-verifier'ı (ve gotrue'nun bu depoya yazdığı her şeyi)
/// Keychain/Keystore'da tutan [GotrueAsyncStorage].
///
/// Anahtar adı gotrue tarafından VERİLİR (`supabase.auth.token-code-verifier`,
/// `gotrue/lib/src/gotrue_client.dart:428`), burada sabitlenmez → gotrue anahtar
/// adını değiştirirse bu sınıf çalışmaya devam eder.
class SecureGotrueAsyncStorage extends GotrueAsyncStorage {
  SecureGotrueAsyncStorage({
    FlutterSecureStorage? storage,
    GotrueAsyncStorage? legacy,
  }) : _storage = storage ?? _defaultStorage(),
       _legacy = legacy ?? SharedPreferencesGotrueAsyncStorage();

  final FlutterSecureStorage _storage;
  final GotrueAsyncStorage _legacy;

  /// Aynı anahtar için göç en fazla BİR kez denensin (getItem sıcak yoldadır).
  final Set<String> _migrated = <String>{};

  @override
  Future<String?> getItem({required String key}) async {
    try {
      final secure = await _storage.read(key: key);
      if (secure != null) return secure;
    } on PlatformException {
      return null;
    }
    // Secure'da yok → uçuştaki bir e-posta onayına ait eski prefs verifier'ı
    // olabilir. Onu taşı, yoksa güncelleme sırasında bekleyen onay linki kırılır.
    return _migrateFromPrefs(key);
  }

  Future<String?> _migrateFromPrefs(String key) async {
    if (!_migrated.add(key)) return null;
    try {
      final stale = await _legacy.getItem(key: key);
      if (stale == null) return null;
      await _storage.write(key: key, value: stale);
      await _legacy.removeItem(key: key);
      return stale;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setItem({required String key, required String value}) async {
    _migrated.add(key); // artık secure kaynak; prefs'e bir daha bakma
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException {
      /* verifier kalıcı olmaz → onay linki yeniden istenir */
    }
  }

  @override
  Future<void> removeItem({required String key}) async {
    _migrated.add(key);
    try {
      await _storage.delete(key: key);
    } on PlatformException {
      /* zaten yok sayılır */
    }
  }
}
