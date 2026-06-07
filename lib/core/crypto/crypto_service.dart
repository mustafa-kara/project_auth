/// E2E kripto servisi (soyut) — libsodium primitiflerini domain'e açar.
///
/// ARCHITECTURE §2.4: Argon2id (KDF) + XChaCha20-Poly1305 IETF (AEAD).
/// `crypto_secretbox` KULLANILMAZ. Hiçbir kripto rutini elle yazılmaz.
/// `SecureKey` (sodium tipi) dışarı sızmaz → [KeyHandle] opaque wrapper.
library;

import 'dart:typed_data';

import 'encrypted_blob.dart';
import 'key_handle.dart';

/// Argon2id maliyet parametreleri + beklenen salt uzunluğu. **Salt İÇERMEZ** —
/// salt her kurulumda rastgele üretilir (per-user benzersiz), sabit olamaz.
typedef KdfParams = ({int opsLimit, int memLimit, int saltBytes});

abstract interface class CryptoService {
  /// libsodium'u yükler (sumo). Diğer çağrılardan önce bir kez.
  Future<void> init();

  /// 32-byte rastgele master key (asıl veri anahtarı).
  KeyHandle generateMasterKey();

  /// Argon2id varsayılan maliyet (moderate) + salt uzunluğu.
  KdfParams defaultKdfParams();

  /// Master parola → KEK (Argon2id). **async + ayrı isolate** (UI bloklamaz).
  /// Parola birebir UTF-8 kullanılır (normalization yok — bkz. docs/CRYPTO.md).
  Future<KeyHandle> deriveKek({
    required String password,
    required Uint8List salt,
    required int opsLimit,
    required int memLimit,
  });

  /// Ham bytes'tan anahtar kurar (recovery key gibi). Bytes kopyalanır.
  KeyHandle keyFromBytes(Uint8List bytes);

  /// AEAD şifreleme. Nonce içeride rastgele üretilir. AAD bağlam doğrulaması.
  EncryptedBlob encrypt({
    required Uint8List plaintext,
    required KeyHandle key,
    required Uint8List aad,
  });

  /// AEAD çözme. Yanlış key/AAD/tamper → [DecryptException].
  Uint8List decrypt({
    required EncryptedBlob blob,
    required KeyHandle key,
    required Uint8List aad,
  });

  /// Bir anahtarı başka bir anahtarla sarmalar (key wrap). Çıkarılan ham byte
  /// helper içinde hemen zero-fill edilir (Dart heap'te asılı kalmaz).
  EncryptedBlob wrapKey({
    required KeyHandle keyToWrap,
    required KeyHandle wrappingKey,
    required Uint8List aad,
  });

  /// Sarmalı anahtarı çözer. Yanlış wrappingKey/AAD/tamper → [DecryptException].
  /// Çözülen ham byte `SecureKey`'e kopyalandıktan hemen sonra zero-fill edilir.
  KeyHandle unwrapKey({
    required EncryptedBlob blob,
    required KeyHandle wrappingKey,
    required Uint8List aad,
  });

  /// `n` byte kriptografik rastgele (nonce/salt/recovery key).
  Uint8List randomBytes(int n);
}
