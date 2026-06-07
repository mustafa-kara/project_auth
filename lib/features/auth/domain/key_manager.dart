/// Anahtar hiyerarşisi servisi (Ente modeli) — setup / unlock / recovery /
/// changePassword. ARCHITECTURE §2.2.
///
/// Hiyerarşi:
///   masterKey  : 32-byte rastgele, ASIL veri anahtarı (token'ları şifreler)
///   masterPass → Argon2id(salt, ops, mem) → KEK → wrap(masterKey)  = encryptedMasterKey
///   recoveryKey: 32-byte rastgele (BIP39 ile mnemonic) → wrap(masterKey) = recoveryEncryptedMasterKey
///
/// masterKey ASLA diske düz yazılmaz; yalnız oturum içinde bellekte (KeyHandle).
/// Tüm metotlar `Future` (deriveKek ayrı isolate'ta çalışır). Ara anahtarlar
/// (kek, recoveryKey) ve ham byte buffer'ları her zaman `finally`'de temizlenir.
library;

import 'dart:typed_data';

import '../../../core/crypto/bip39.dart';
import '../../../core/crypto/crypto_exceptions.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../core/crypto/key_attributes.dart';
import '../../../core/crypto/key_handle.dart';

/// AAD (Additional Authenticated Data) sabitleri — wrap bağlamını bağlar →
/// bir blob başka bağlamda (örn. token olarak) çözülemez.
const _aadMasterKek = 'masterkey-kek|1';
const _aadMasterRecovery = 'masterkey-recovery|1';

/// [KeyManager.setup] sonucu: persist edilecek attrs + kullanıcıya gösterilecek
/// mnemonic + oturum içi masterKey.
typedef SetupResult = ({
  KeyAttributes attrs,
  List<String> recoveryMnemonic,
  KeyHandle masterKey,
});

class KeyManager {
  /// Domain seviyesi minimum parola uzunluğu (UI validator'a ek güvenlik sınırı).
  /// Trim sonrası bu uzunluğun altı → [WeakPasswordException].
  static const int minPasswordLength = 8;

  final CryptoService _crypto;

  KeyManager(this._crypto);

  Uint8List _aad(String s) => Uint8List.fromList(s.codeUnits);

  /// Boş/çok kısa parola domain'de reddedilir (Argon2id'e gitmeden). Parola
  /// içeriği kırpılarak HASH'lenmez — yalnız politika kontrolü trim'lenir;
  /// gerçek KEK türetiminde parola birebir (orijinal) kullanılır.
  void _enforcePasswordPolicy(String password) {
    if (password.trim().isEmpty) {
      throw const WeakPasswordException('Parola boş olamaz');
    }
    if (password.length < minPasswordLength) {
      throw WeakPasswordException(
          'Parola en az $minPasswordLength karakter olmalı');
    }
  }

  /// Yeni vault kurulumu. masterKey + KEK(parola) + recovery key üretir,
  /// masterKey'i ikisiyle de sarmalar. **Hiçbir şey diske yazmaz** — dönen
  /// [SetupResult] çağıran (recovery verify sonrası) tarafından persist edilir.
  Future<SetupResult> setup(String masterPassword) async {
    _enforcePasswordPolicy(masterPassword);
    final masterKey = _crypto.generateMasterKey();
    final params = _crypto.defaultKdfParams();
    final salt = _crypto.randomBytes(params.saltBytes);

    KeyHandle? kek;
    KeyHandle? recoveryKey;
    Uint8List? recoveryKeyBytes;
    try {
      kek = await _crypto.deriveKek(
        password: masterPassword,
        salt: salt,
        opsLimit: params.opsLimit,
        memLimit: params.memLimit,
      );
      final encryptedMasterKey = _crypto.wrapKey(
        keyToWrap: masterKey,
        wrappingKey: kek,
        aad: _aad(_aadMasterKek),
      );

      recoveryKeyBytes = _crypto.randomBytes(Bip39.entropyBytes);
      recoveryKey = _crypto.keyFromBytes(recoveryKeyBytes);
      final recoveryEncryptedMasterKey = _crypto.wrapKey(
        keyToWrap: masterKey,
        wrappingKey: recoveryKey,
        aad: _aad(_aadMasterRecovery),
      );

      final mnemonic = Bip39.encode(recoveryKeyBytes);

      final attrs = KeyAttributes(
        kdfSalt: salt,
        kdfOps: params.opsLimit,
        kdfMem: params.memLimit,
        encryptedMasterKey: encryptedMasterKey,
        recoveryEncryptedMasterKey: recoveryEncryptedMasterKey,
      );

      return (attrs: attrs, recoveryMnemonic: mnemonic, masterKey: masterKey);
    } catch (_) {
      // Hata yolunda masterKey de sızmamalı (çağırana dönmüyoruz).
      masterKey.dispose();
      rethrow;
    } finally {
      kek?.dispose();
      recoveryKey?.dispose();
      if (recoveryKeyBytes != null) {
        recoveryKeyBytes.fillRange(0, recoveryKeyBytes.length, 0);
      }
    }
  }

  /// Master parola ile vault'u açar. Yanlış parola → [WrongPasswordException].
  Future<KeyHandle> unlock(KeyAttributes attrs, String masterPassword) async {
    KeyHandle? kek;
    try {
      kek = await _crypto.deriveKek(
        password: masterPassword,
        salt: attrs.kdfSalt,
        opsLimit: attrs.kdfOps,
        memLimit: attrs.kdfMem,
      );
      try {
        return _crypto.unwrapKey(
          blob: attrs.encryptedMasterKey,
          wrappingKey: kek,
          aad: _aad(_aadMasterKek),
        );
      } on DecryptException {
        throw const WrongPasswordException();
      }
    } finally {
      kek?.dispose();
    }
  }

  /// Recovery mnemonic ile masterKey'i kurtarır. Yanlış/bozuk mnemonic →
  /// [WrongRecoveryKeyException]. (Checksum hatası da buraya düşer.)
  Future<KeyHandle> recoverUnlock(
      KeyAttributes attrs, List<String> mnemonic) async {
    Uint8List? recoveryKeyBytes;
    KeyHandle? recoveryKey;
    try {
      try {
        recoveryKeyBytes = Bip39.decode(mnemonic);
      } on FormatException {
        throw const WrongRecoveryKeyException();
      }
      recoveryKey = _crypto.keyFromBytes(recoveryKeyBytes);
      try {
        return _crypto.unwrapKey(
          blob: attrs.recoveryEncryptedMasterKey,
          wrappingKey: recoveryKey,
          aad: _aad(_aadMasterRecovery),
        );
      } on DecryptException {
        throw const WrongRecoveryKeyException();
      }
    } finally {
      recoveryKey?.dispose();
      if (recoveryKeyBytes != null) {
        recoveryKeyBytes.fillRange(0, recoveryKeyBytes.length, 0);
      }
    }
  }

  /// Master parolayı değiştirir. masterKey AYNI kalır → token ciphertext'leri
  /// yeniden şifrelenmez; yalnız yeni salt + yeni KEK + yeni encryptedMasterKey
  /// üretilir. `recoveryEncryptedMasterKey` DOKUNULMAZ.
  ///
  /// Dönen [KeyAttributes]'ta `kdfSalt`, `kdfOps`, `kdfMem` VE
  /// `encryptedMasterKey` **birlikte** güncellenir (tutarlılık şart — yoksa yeni
  /// parolayla unlock kırılır). Çağıran bunu `vault_key_attributes_v1`'e yazar.
  Future<KeyAttributes> changePassword(
    KeyAttributes attrs,
    KeyHandle masterKey,
    String newPassword,
  ) async {
    _enforcePasswordPolicy(newPassword);
    final params = _crypto.defaultKdfParams();
    final newSalt = _crypto.randomBytes(params.saltBytes);
    KeyHandle? newKek;
    try {
      newKek = await _crypto.deriveKek(
        password: newPassword,
        salt: newSalt,
        opsLimit: params.opsLimit,
        memLimit: params.memLimit,
      );
      final newEncryptedMasterKey = _crypto.wrapKey(
        keyToWrap: masterKey,
        wrappingKey: newKek,
        aad: _aad(_aadMasterKek),
      );
      return attrs.copyWith(
        kdfSalt: newSalt,
        kdfOps: params.opsLimit,
        kdfMem: params.memLimit,
        encryptedMasterKey: newEncryptedMasterKey,
      );
    } finally {
      newKek?.dispose();
    }
  }
}
