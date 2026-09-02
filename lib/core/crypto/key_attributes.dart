/// Anahtar metadata'sı — masterKey'i açmak için gereken her şey (kendisi HARİÇ).
///
/// ARCHITECTURE §5 `key_attributes` tablosuyla hizalı; Faz 3'te sunucuya
/// birebir taşınır. **Hiçbiri plaintext masterKey/KEK içermez** — yalnız:
///   - KDF parametreleri (salt + ops/mem) → parola → KEK türetmek için
///   - encryptedMasterKey: masterKey'in KEK ile sarmalanmış hâli
///   - recoveryEncryptedMasterKey: masterKey'in recovery key ile sarmalanmış hâli
///
/// `vault_key_attributes_v1` altında saklanır. Defensive copy disiplini:
/// `kdfSalt` ctor'da kopyalanır, getter kopya döndürür; `EncryptedBlob`'lar
/// zaten kendi içinde kopyalar.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'encrypted_blob.dart';

/// Değişmez anahtar metadata değer nesnesi.
class KeyAttributes {
  final Uint8List _kdfSalt;

  /// Desteklenen en yüksek şema versiyonu. İleri sürüm → [FormatException].
  static const int supportedVersion = 1;

  /// libsodium Argon2id salt uzunluğu (`crypto_pwhash_SALTBYTES` = 16, sabit).
  /// Bozuk/ileri metadata'yı erkenden yakalamak için doğrulanır.
  static const int saltBytes = 16;

  final int kdfOps;
  final int kdfMem;
  final EncryptedBlob encryptedMasterKey;
  final EncryptedBlob recoveryEncryptedMasterKey;

  /// masterKey'in biyometri-anahtarı ile sarmalanmış hâli (Patch 5). Opsiyonel:
  /// `null` = biyometri bu cihazda enroll edilmemiş. Sarmalama anahtarı (biometricKey)
  /// OS keystore'da biyometrik erişim kontrolüyle ayrı saklanır — bu blob tek başına
  /// işe yaramaz. `bmk` JSON anahtarı yalnız non-null iken yazılır → mevcut vault'lar
  /// byte-identical kalır (geriye dönük uyumlu, sürüm bump YOK).
  final EncryptedBlob? biometricEncryptedMasterKey;

  final int version;

  KeyAttributes({
    required Uint8List kdfSalt,
    required this.kdfOps,
    required this.kdfMem,
    required this.encryptedMasterKey,
    required this.recoveryEncryptedMasterKey,
    this.biometricEncryptedMasterKey,
    this.version = supportedVersion,
  }) : _kdfSalt = Uint8List.fromList(kdfSalt) {
    _validate(version, _kdfSalt, kdfOps, kdfMem);
  }

  /// Bozuk/ileri-sürüm metadata sodium'a ulaşmadan ERKENDEN reddedilir
  /// (review P2): yoksa geç sodium hatası / "yanlış parola" gibi görünür ya da
  /// ileri şema yanlış yorumlanır.
  static void _validate(int version, Uint8List salt, int ops, int mem) {
    if (version < 1 || version > supportedVersion) {
      throw FormatException(
        'KeyAttributes: desteklenmeyen version $version (beklenen 1..$supportedVersion)',
      );
    }
    if (salt.length != saltBytes) {
      throw FormatException(
        'KeyAttributes: kdfSalt $saltBytes byte olmalı (${salt.length})',
      );
    }
    if (ops <= 0) {
      throw FormatException('KeyAttributes: kdfOps pozitif olmalı ($ops)');
    }
    if (mem <= 0) {
      throw FormatException('KeyAttributes: kdfMem pozitif olmalı ($mem)');
    }
  }

  /// Defensive copy — çağıran kod iç salt buffer'ını mutate edemez.
  Uint8List get kdfSalt => Uint8List.fromList(_kdfSalt);

  /// Aynı masterKey ile yeni KDF/encryptedMasterKey'e kopya (changePassword).
  /// `recoveryEncryptedMasterKey` ve diğer alanlar korunur.
  ///
  /// [biometricEncryptedMasterKey] verilirse set edilir; [clearBiometric] true ise
  /// `null`'a çekilir (biyometriyi kapat). İkisi birden verilemez (assert).
  /// `changePassword` bu metodu yalnız KDF/emk için çağırır → bmk KORUNUR
  /// (masterKey değişmediği için biyometri sarması geçerli kalır).
  KeyAttributes copyWith({
    Uint8List? kdfSalt,
    int? kdfOps,
    int? kdfMem,
    EncryptedBlob? encryptedMasterKey,
    EncryptedBlob? biometricEncryptedMasterKey,
    bool clearBiometric = false,
  }) {
    assert(
      !(clearBiometric && biometricEncryptedMasterKey != null),
      'copyWith: clearBiometric ile biometricEncryptedMasterKey aynı anda verilemez',
    );
    return KeyAttributes(
      kdfSalt: kdfSalt ?? _kdfSalt,
      kdfOps: kdfOps ?? this.kdfOps,
      kdfMem: kdfMem ?? this.kdfMem,
      encryptedMasterKey: encryptedMasterKey ?? this.encryptedMasterKey,
      recoveryEncryptedMasterKey: recoveryEncryptedMasterKey,
      biometricEncryptedMasterKey: clearBiometric
          ? null
          : (biometricEncryptedMasterKey ?? this.biometricEncryptedMasterKey),
      version: version,
    );
  }

  Map<String, dynamic> toJson() => {
    'v': version,
    'salt': base64Encode(_kdfSalt),
    'ops': kdfOps,
    'mem': kdfMem,
    'emk': encryptedMasterKey.toJson(),
    'remk': recoveryEncryptedMasterKey.toJson(),
    if (biometricEncryptedMasterKey != null)
      'bmk': biometricEncryptedMasterKey!.toJson(),
  };

  /// [toJson] çıktısından geri kurar. Eksik/yanlış tip/geçersiz base64 →
  /// [FormatException] (bozuk metadata'dan sessizce hatalı attrs üretmemek için).
  factory KeyAttributes.fromJson(Map<String, dynamic> json) {
    final saltStr = _asString(json['salt'], 'salt');
    final ops = _asInt(json['ops'], 'ops');
    final mem = _asInt(json['mem'], 'mem');
    final emk = _asMap(json['emk'], 'emk');
    final remk = _asMap(json['remk'], 'remk');
    if (saltStr == null ||
        ops == null ||
        mem == null ||
        emk == null ||
        remk == null) {
      throw const FormatException(
        'KeyAttributes.fromJson: zorunlu alan eksik (salt/ops/mem/emk/remk)',
      );
    }
    // bmk opsiyonel: yoksa null (eski/biyometrisiz vault). Doluysa EncryptedBlob.
    final bmk = _asMap(json['bmk'], 'bmk');
    final Uint8List salt;
    try {
      salt = base64Decode(saltStr);
    } on FormatException {
      throw const FormatException(
        'KeyAttributes.fromJson: salt geçersiz base64',
      );
    }
    return KeyAttributes(
      kdfSalt: salt,
      kdfOps: ops,
      kdfMem: mem,
      encryptedMasterKey: EncryptedBlob.fromJson(emk),
      recoveryEncryptedMasterKey: EncryptedBlob.fromJson(remk),
      biometricEncryptedMasterKey: bmk == null
          ? null
          : EncryptedBlob.fromJson(bmk),
      version: _asInt(json['v'], 'v') ?? supportedVersion,
    );
  }

  static String? _asString(Object? v, String name) {
    if (v == null) return null;
    if (v is String) return v;
    throw FormatException(
      'KeyAttributes.fromJson: "$name" String olmalı (${v.runtimeType})',
    );
  }

  /// Tamsayı bekler. `1.5` gibi kesirli `num` sessizce truncate EDİLMEZ → reddedilir.
  static int? _asInt(Object? v, String name) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) {
      if (v == v.roundToDouble()) {
        return v.toInt(); // tamsayı değerli double (JSON 3.0)
      }
      throw FormatException(
        'KeyAttributes.fromJson: "$name" tamsayı olmalı, kesirli ($v)',
      );
    }
    throw FormatException(
      'KeyAttributes.fromJson: "$name" sayı olmalı (${v.runtimeType})',
    );
  }

  static Map<String, dynamic>? _asMap(Object? v, String name) {
    if (v == null) return null;
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    throw FormatException(
      'KeyAttributes.fromJson: "$name" nesne olmalı (${v.runtimeType})',
    );
  }
}
