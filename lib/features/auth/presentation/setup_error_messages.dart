/// Kurulum (setup / commitSetup) hatalarının Türkçe karşılıkları.
///
/// SECURITY (güvenlik denetimi P3-6): ekrana **hiçbir zaman ham `$e`
/// interpolasyonu** çıkmaz. Bir istisnanın `toString`'i çağrı bağlamını, dosya
/// adlarını, platform kanalı mesajlarını ve — ileride bir istisna tipi
/// değişirse — kullanıcı verisini taşıyabilir. Uygulamada bu kalıbın tek doğru
/// örneği `import_page.dart`'ın `importErrorMessage`'ıdır (tipleri sabit
/// dizgelere eşler); burası aynı deseni kurulum akışına taşır.
///
/// Bilinmeyen tipler jenerik mesaja düşer — teknik ayrıntı kullanıcıya
/// gösterilmez.
library;

import 'package:flutter/services.dart' show PlatformException;

import '../../../core/crypto/crypto_exceptions.dart';

/// [message] alanı OLAN, kullanıcıya gösterilebilir domain hataları için ortak
/// arayüz yerine tip-tip eşleme yapılır (bkz. `importErrorMessage`).
String setupErrorMessage(Object error) => switch (error) {
  // Parola politikası mesajları KeyManager.enforcePolicy'de tek kaynaktan
  // yazılır ve kullanıcıya yönelik, sabit metinlerdir (secret taşımaz).
  WeakPasswordException(message: final m) => m,
  // Keychain/Keystore yazma hatası — `resetOnError: false` (locator.dart) ile
  // artık sessiz kalmak yerine buraya kadar geliyor.
  PlatformException() =>
    'Cihazın güvenli deposuna yazılamadı. Cihazı yeniden başlatıp tekrar dene.',
  VaultIntegrityException() =>
    'Mevcut vault verisi okunamadı. Ayarlar\'dan vault\'u sıfırlayabilirsin.',
  _ => 'Kurulum tamamlanamadı — tekrar dene.',
};
