/// OTP üretiminde kullanılan HMAC hash algoritması.
library;

import 'package:crypto/crypto.dart' as crypto;

enum OtpAlgorithm {
  sha1,
  sha256,
  sha512;

  /// `otpauth://` URI'sindeki `algorithm` parametresinden parse eder.
  ///
  /// - **Eksik/boş** → SHA1 (RFC 6238 ve çoğu servis varsayılanı).
  /// - **Geçerli** (SHA1/SHA256/SHA512, tire ve büyük/küçük harf toleranslı) → ilgili enum.
  /// - **Verilmiş ama bilinmeyen** (typo / desteklenmeyen algoritma) → [FormatException].
  ///
  /// Eski davranış bilinmeyeni sessizce SHA1'e düşürüyordu → yanlış kod üretebilirdi.
  /// `digits`/`period` ile aynı prensip: "verilmişse doğrula, geçersizse reddet".
  static OtpAlgorithm fromName(String? name) {
    if (name == null || name.isEmpty) return OtpAlgorithm.sha1;
    switch (name.toUpperCase().replaceAll('-', '')) {
      case 'SHA1':
        return OtpAlgorithm.sha1;
      case 'SHA256':
        return OtpAlgorithm.sha256;
      case 'SHA512':
        return OtpAlgorithm.sha512;
      default:
        throw FormatException(
          'otpauth URI: desteklenmeyen "algorithm": "$name" '
          '(beklenen SHA1/SHA256/SHA512)',
        );
    }
  }

  /// `otpauth://` URI'sinde kullanılacak kanonik ad.
  String get uriName => switch (this) {
    OtpAlgorithm.sha1 => 'SHA1',
    OtpAlgorithm.sha256 => 'SHA256',
    OtpAlgorithm.sha512 => 'SHA512',
  };

  /// crypto paketinin ilgili [crypto.Hash] nesnesi (HMAC için).
  crypto.Hash get hash => switch (this) {
    OtpAlgorithm.sha1 => crypto.sha1,
    OtpAlgorithm.sha256 => crypto.sha256,
    OtpAlgorithm.sha512 => crypto.sha512,
  };
}
