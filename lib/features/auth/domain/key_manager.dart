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

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/crypto/bip39.dart';
import '../../../core/crypto/crypto_exceptions.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../core/crypto/key_attributes.dart';
import '../../../core/crypto/key_handle.dart';
import 'biometric_exceptions.dart';

/// AAD (Additional Authenticated Data) sabitleri — wrap bağlamını bağlar →
/// bir blob başka bağlamda (örn. token olarak) çözülemez.
const _aadMasterKek = 'masterkey-kek|1';
const _aadMasterRecovery = 'masterkey-recovery|1';
const _aadMasterBiometric = 'masterkey-biometric|1';

/// [KeyManager.setup] sonucu: persist edilecek attrs + kullanıcıya gösterilecek
/// mnemonic + oturum içi masterKey.
typedef SetupResult = ({
  KeyAttributes attrs,
  List<String> recoveryMnemonic,
  KeyHandle masterKey,
});

/// [KeyManager.enrollBiometric] sonucu: bmk eklenmiş attrs + OS keystore'a
/// yazılacak ham biometricKey byte'ları. **Çağıran, [biometricKeyBytes]'ı
/// `BiometricService.enroll`'a verdikten SONRA zero-fill etmelidir** (bu metot
/// içinde silinmez — çağırana taşınır; tıpkı `setup`'ın masterKey'i döndürmesi gibi).
typedef BiometricEnrollResult = ({
  KeyAttributes attrs,
  Uint8List biometricKeyBytes,
});

class KeyManager {
  /// Domain seviyesi minimum parola uzunluğu (UI validator'a ek güvenlik sınırı).
  /// Bu uzunluğun altı → [WeakPasswordException]. E2E tehdit modeli: DB/storage
  /// sızıntısında Argon2id yavaşlatır ama zayıf parola offline brute-force'u
  /// kolaylaştırır → 12 karakter taban.
  static const int minPasswordLength = 12;

  /// Minimum karakter sınıfı çeşitliliği (büyük/küçük/rakam/sembol arasından).
  /// < bu kadar farklı sınıf → [WeakPasswordException].
  static const int minPasswordClasses = 3;

  /// Bir parolanın içerdiği karakter sınıfı sayısı (0–4):
  /// büyük harf · küçük harf · rakam · sembol. **Tek doğruluk noktası** —
  /// hem domain politikası hem UI güç göstergesi bunu kullanır. Politika
  /// kontrolü `trim`'lenmez; sınıf sayımı parolanın birebir kendisinden yapılır.
  static int passwordClassCount(String password) {
    var classes = 0;
    if (password.contains(RegExp(r'[A-Z]'))) classes++;
    if (password.contains(RegExp(r'[a-z]'))) classes++;
    if (password.contains(RegExp(r'[0-9]'))) classes++;
    if (password.contains(RegExp(r'[^A-Za-z0-9]'))) classes++;
    return classes;
  }

  /// Politikaya uyuyor mu (UI validator'ın domain'e gitmeden hızlı kullanımı için).
  static bool meetsPolicy(String password) =>
      password.length >= minPasswordLength &&
      passwordClassCount(password) >= minPasswordClasses;

  /// Politika ihlalinde [WeakPasswordException] atar. **Mesajların tek kaynağı**
  /// burasıdır: hem master parola (`setup`/`changePassword`) hem de şifreli yedek
  /// parolası (`BackupService.export`) aynı metni ve aynı eşikleri kullanır.
  ///
  /// Parola içeriği kırpılarak HASH'lenmez — yalnız "boş mu" kontrolü trim'lenir;
  /// gerçek KEK türetiminde parola birebir (orijinal) kullanılır.
  static void enforcePolicy(String password) {
    if (password.trim().isEmpty) {
      throw const WeakPasswordException('Parola boş olamaz');
    }
    if (password.length < minPasswordLength) {
      throw WeakPasswordException(
        'Parola en az $minPasswordLength karakter olmalı',
      );
    }
    if (passwordClassCount(password) < minPasswordClasses) {
      throw WeakPasswordException(
        'Parola büyük harf, küçük harf, rakam ve sembolden en az '
        '$minPasswordClasses farklı tür içermeli',
      );
    }
  }

  final CryptoService _crypto;

  KeyManager(this._crypto);

  /// Bu sınıfın ürettiği TÜM AAD dizgeleri (güvenlik denetimi P3-6 testi için).
  /// Hepsi ASCII'dir → [_aad]'in `utf8.encode`'u `codeUnits` ile BAYT-BİREBİR
  /// aynıdır; test: `test/features/auth/aad_encoding_test.dart`.
  @visibleForTesting
  static const aadStrings = [
    _aadMasterKek,
    _aadMasterRecovery,
    _aadMasterBiometric,
  ];

  /// AAD baytları. `utf8.encode` — `String.codeUnits` DEĞİL (güvenlik denetimi
  /// P3-6): codeUnits UTF-16 birimlerini 8 bite kırpar, yani ASCII olmayan tek
  /// bir karakter sessizce YANLIŞ bir AAD üretirdi. Buradaki tüm AAD'ler bugün
  /// ASCII olduğu için iki kodlama bayt-birebir aynıdır (bkz. [aadStrings] ve
  /// `aad_encoding_test.dart`) → mevcut blob'lar etkilenmez; değişiklik yalnız
  /// örtük değişmezi ORTADAN KALDIRIR.
  Uint8List _aad(String s) => utf8.encode(s);

  /// Boş/çok kısa parola domain'de reddedilir (Argon2id'e gitmeden).
  /// Tek kaynak [enforcePolicy]'dir — burası yalnız ona delege eder.
  void _enforcePasswordPolicy(String password) => enforcePolicy(password);

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
    KeyAttributes attrs,
    List<String> mnemonic,
  ) async {
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

  /// Biyometrik kilit açma için masterKey'i taze bir biometricKey ile sarmalar
  /// (Patch 5). masterKey AYNI kalır (sahipliği çağırandadır — dispose ETMEZ).
  /// Dönen [BiometricEnrollResult.attrs] `bmk` içerir; [biometricKeyBytes] OS
  /// keystore'a yazılmak üzere çağırana verilir.
  ///
  /// **Yalnız `unlocked` iken (masterKey bellekte) çağrılmalı.** Argon2id YOK →
  /// senkron (yavaş kısım yok); yine de `Future` API tutarlılığı için sync döner.
  BiometricEnrollResult enrollBiometric(
    KeyAttributes attrs,
    KeyHandle masterKey,
  ) {
    final biometricKeyBytes = _crypto.randomBytes(32);
    KeyHandle? biometricKey;
    try {
      biometricKey = _crypto.keyFromBytes(biometricKeyBytes);
      final blob = _crypto.wrapKey(
        keyToWrap: masterKey,
        wrappingKey: biometricKey,
        aad: _aad(_aadMasterBiometric),
      );
      return (
        attrs: attrs.copyWith(biometricEncryptedMasterKey: blob),
        biometricKeyBytes: biometricKeyBytes,
      );
    } catch (_) {
      // HATA YOLU (güvenlik denetimi P3-6): `keyFromBytes`/`wrapKey` fırlatırsa
      // byte'lar KİMSEYE taşınmaz — sahipliği devralacak çağıran yok, dolayısıyla
      // onları silecek de yok. Burada sil, sonra yükselt.
      biometricKeyBytes.fillRange(0, biometricKeyBytes.length, 0);
      rethrow;
    } finally {
      // NB: BAŞARI yolunda biometricKeyBytes zero-fill EDİLMEZ — çağırana taşınır
      // (enroll sonrası çağıran siler: vault_lock_cubit.enableBiometric `finally`).
      // Yalnız ara KeyHandle dispose edilir.
      biometricKey?.dispose();
    }
  }

  /// OS keystore'dan (biyometri geçidi ardından) okunan [biometricKeyBytes] ile
  /// masterKey'i açar (Patch 5). bmk yok / yanlış key / bozuk → [BiometricUnwrapException].
  /// **Çağıran [biometricKeyBytes]'ı bu çağrıdan SONRA zero-fill etmelidir.**
  KeyHandle biometricUnlock(KeyAttributes attrs, Uint8List biometricKeyBytes) {
    final blob = attrs.biometricEncryptedMasterKey;
    if (blob == null) {
      throw const BiometricUnwrapException(
        'Bu cihazda biyometri enroll edilmemiş',
      );
    }
    KeyHandle? biometricKey;
    try {
      biometricKey = _crypto.keyFromBytes(biometricKeyBytes);
      try {
        return _crypto.unwrapKey(
          blob: blob,
          wrappingKey: biometricKey,
          aad: _aad(_aadMasterBiometric),
        );
      } on DecryptException {
        throw const BiometricUnwrapException();
      }
    } finally {
      biometricKey?.dispose();
    }
  }
}
