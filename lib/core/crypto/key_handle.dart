/// Anahtar tutamacı (opaque) — `sodium` tipini (`SecureKey`) public API'den gizler.
///
/// `CryptoService` arayüzü bu soyutlamayla konuşur (ARCHITECTURE §3: domain
/// kripto interface'i framework-bağımsız). Gerçek `SecureKey`'i yalnızca
/// `SodiumCryptoService` içindeki `SodiumKeyHandle` tutar; dışarı `SecureKey`
/// sızmaz → `dispose()` disiplini ve test edilebilirlik netleşir.
library;

/// Bellek-güvenli (native) bir anahtarın opaque tutamacı. Kullanım bitince
/// [dispose] ZORUNLU — native bellek (mlock) serbest bırakılır ve sıfırlanır.
abstract interface class KeyHandle {
  /// Altındaki anahtarı serbest bırakır ve sıfırlar. İkinci çağrı no-op (idempotent).
  void dispose();
}
