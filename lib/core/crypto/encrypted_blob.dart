/// AEAD şifreleme çıktısı: nonce + ciphertext (+ şema versiyonu).
///
/// XChaCha20-Poly1305 IETF: nonce her şifrelemede rastgele üretilir ve
/// ciphertext ile birlikte saklanır (192-bit nonce → rastgele güvenli).
/// `ciphertext` Poly1305 etiketini (MAC) içerir (combined mode).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Değişmez şifreli blob. `Uint8List` alanlar **defensive copy** ile korunur:
/// ctor/fromJson kopyalar, getter'lar değiştirilemez görünüm döndürür →
/// çağıran kod nonce/ciphertext buffer'ını kazara mutate edemez.
///
/// **Sıkı validasyon (review P2):** bozuk/ileri-sürüm metadata, sodium'a
/// ulaşmadan ERKENDEN reddedilir — yoksa sodium hatası "yanlış parola" gibi
/// görünür ya da ileri şema yanlış yorumlanır. nonce/ciphertext uzunluğu ve
/// `version` ctor + `fromJson`'da doğrulanır.
class EncryptedBlob {
  /// Desteklenen en yüksek şema versiyonu. İleri sürüm → [FormatException].
  static const int supportedVersion = 1;

  /// XChaCha20-Poly1305 IETF nonce uzunluğu (sabit, kanonik).
  static const int nonceBytes = 24;

  /// Poly1305 AEAD etiketi (MAC) uzunluğu — ciphertext en az bu kadar olmalı
  /// (combined mode: ciphertext = şifreli veri + 16-byte tag).
  static const int minCiphertextBytes = 16;

  final Uint8List _nonce;
  final Uint8List _ciphertext;
  final int version;

  EncryptedBlob({
    required Uint8List nonce,
    required Uint8List ciphertext,
    this.version = supportedVersion,
  }) : _nonce = Uint8List.fromList(nonce),
       _ciphertext = Uint8List.fromList(ciphertext) {
    _validate(version, _nonce, _ciphertext);
  }

  /// Ctor + fromJson ortak doğrulaması. Geçersizse [FormatException].
  static void _validate(int version, Uint8List nonce, Uint8List ciphertext) {
    if (version < 1 || version > supportedVersion) {
      throw FormatException(
        'EncryptedBlob: desteklenmeyen version $version (beklenen 1..$supportedVersion)',
      );
    }
    if (nonce.length != nonceBytes) {
      throw FormatException(
        'EncryptedBlob: nonce $nonceBytes byte olmalı (${nonce.length})',
      );
    }
    if (ciphertext.length < minCiphertextBytes) {
      throw FormatException(
        'EncryptedBlob: ciphertext en az $minCiphertextBytes byte olmalı (${ciphertext.length})',
      );
    }
  }

  /// Defensive copy döndürür — çağıran kod iç buffer'ı mutate edemez.
  /// (nonce ~24B, token/anahtar ciphertext'i küçük → kopya maliyeti ihmal edilebilir.)
  Uint8List get nonce => Uint8List.fromList(_nonce);
  Uint8List get ciphertext => Uint8List.fromList(_ciphertext);

  /// base64 ile JSON (storage için).
  Map<String, dynamic> toJson() => {
    'v': version,
    'n': base64Encode(_nonce),
    'c': base64Encode(_ciphertext),
  };

  /// [toJson] çıktısından geri kurar. Yanlış tip / geçersiz base64 →
  /// [FormatException] (bozuk depodan sessizce hatalı blob üretmemek için).
  factory EncryptedBlob.fromJson(Map<String, dynamic> json) {
    final n = _asString(json['n'], 'n');
    final c = _asString(json['c'], 'c');
    if (n == null || c == null) {
      throw const FormatException('EncryptedBlob.fromJson: "n"/"c" zorunlu');
    }
    final Uint8List nonce;
    final Uint8List ciphertext;
    try {
      nonce = base64Decode(n);
      ciphertext = base64Decode(c);
    } on FormatException {
      throw const FormatException('EncryptedBlob.fromJson: geçersiz base64');
    }
    return EncryptedBlob(
      nonce: nonce,
      ciphertext: ciphertext,
      version: _asInt(json['v'], 'v') ?? supportedVersion,
    );
  }

  static String? _asString(Object? v, String name) {
    if (v == null) return null;
    if (v is String) return v;
    throw FormatException(
      'EncryptedBlob.fromJson: "$name" String olmalı (${v.runtimeType})',
    );
  }

  /// Tamsayı bekler. `1.5` gibi kesirli `num` sessizce truncate EDİLMEZ.
  static int? _asInt(Object? v, String name) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) {
      if (v == v.roundToDouble()) return v.toInt();
      throw FormatException(
        'EncryptedBlob.fromJson: "$name" tamsayı olmalı, kesirli ($v)',
      );
    }
    throw FormatException(
      'EncryptedBlob.fromJson: "$name" sayı olmalı (${v.runtimeType})',
    );
  }
}
