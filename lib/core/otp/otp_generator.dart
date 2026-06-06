/// RFC 4226 (HOTP) + RFC 6238 (TOTP) + Steam Guard kod üretimi.
///
/// Saf hesaplama — ağ/IO yok, test edilebilir. Tüm fonksiyonlar deterministik.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'otp_algorithm.dart';

/// Steam Guard kodlarında kullanılan 26 karakterlik alfabe.
const String _steamAlphabet = '23456789BCDFGHJKMNPQRTVWXY';

class OtpGenerator {
  const OtpGenerator();

  /// RFC 4226 HOTP — verilen sayaç [counter] için OTP üretir.
  ///
  /// [secret] ham (decode edilmiş) anahtar byte'larıdır.
  /// [digits] genelde 6 (bazı servisler 7/8).
  String hotp({
    required Uint8List secret,
    required int counter,
    int digits = 6,
    OtpAlgorithm algorithm = OtpAlgorithm.sha1,
  }) {
    final dt = _truncate(_hmac(secret, counter, algorithm));
    final mod = _pow10(digits);
    return (dt % mod).toString().padLeft(digits, '0');
  }

  /// RFC 6238 TOTP — [time] anındaki zaman-bazlı OTP üretir.
  ///
  /// [period] saniye cinsinden adım (genelde 30). [time] verilmezse
  /// çağıran tarafın saatini geçmesi beklenir (saf tutmak için zorunlu değil —
  /// burada opsiyonel; null ise DateTime.now() kullanılır).
  String totp({
    required Uint8List secret,
    DateTime? time,
    int period = 30,
    int digits = 6,
    OtpAlgorithm algorithm = OtpAlgorithm.sha1,
  }) {
    final t = time ?? DateTime.now();
    final counter = totpCounter(time: t, period: period);
    return hotp(
      secret: secret,
      counter: counter,
      digits: digits,
      algorithm: algorithm,
    );
  }

  /// Steam Guard kodu — TOTP'nin Steam'e özgü 5 karakterlik varyantı.
  ///
  /// SHA1, period=30, ama digit yerine 26-harfli alfabeden 5 sembol üretir.
  String steam({
    required Uint8List secret,
    DateTime? time,
    int period = 30,
  }) {
    final t = time ?? DateTime.now();
    final counter = totpCounter(time: t, period: period);
    var value = _truncate(_hmac(secret, counter, OtpAlgorithm.sha1));
    final sb = StringBuffer();
    for (var i = 0; i < 5; i++) {
      sb.write(_steamAlphabet[value % _steamAlphabet.length]);
      value ~/= _steamAlphabet.length;
    }
    return sb.toString();
  }

  /// Belirli bir [time] için TOTP sayacı: floor(unixSeconds / period).
  int totpCounter({required DateTime time, int period = 30}) {
    final seconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
    return seconds ~/ period;
  }

  /// Geçerli TOTP adımının bitmesine kalan saniye (geri sayım halkası için).
  int secondsRemaining({DateTime? time, int period = 30}) {
    final t = (time ?? DateTime.now()).toUtc();
    final seconds = t.millisecondsSinceEpoch ~/ 1000;
    return period - (seconds % period);
  }

  // --- iç yardımcılar ---

  /// HMAC(secret, counter_big_endian_8_bytes).
  List<int> _hmac(Uint8List secret, int counter, OtpAlgorithm algorithm) {
    final msg = _counterBytes(counter);
    return crypto.Hmac(algorithm.hash, secret).convert(msg).bytes;
  }

  /// Sayacı 8 byte'lık big-endian diziye çevirir (RFC 4226 §5.1).
  Uint8List _counterBytes(int counter) {
    final bytes = Uint8List(8);
    var c = counter;
    for (var i = 7; i >= 0; i--) {
      bytes[i] = c & 0xFF;
      c >>= 8;
    }
    return bytes;
  }

  /// RFC 4226 §5.3 dynamic truncation → 31-bit pozitif tamsayı.
  int _truncate(List<int> hmac) {
    final offset = hmac[hmac.length - 1] & 0x0F;
    return ((hmac[offset] & 0x7F) << 24) |
        ((hmac[offset + 1] & 0xFF) << 16) |
        ((hmac[offset + 2] & 0xFF) << 8) |
        (hmac[offset + 3] & 0xFF);
  }

  int _pow10(int n) {
    var r = 1;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}
