/// PostgreSQL `bytea` ↔ Dart `Uint8List` dönüşümü — TEK NOKTA (Faz 3 Patch 2).
///
/// **Neden tek dosya:** PostgREST `bytea`'yı SELECT'te `\x<hex>` string döndürür;
/// INSERT'te JSON gövdesinde kabul ettiği format **cihazda doğrulanacak açık risk**
/// (hex `\x...` literal mı, başka mı). Tüm bytea<->byte dönüşümü burada toplanır →
/// gerçek Supabase davranışı farklıysa TEK noktadan düzeltilir, repository değişmez.
///
/// Şema/kripto özü ETKİLENMEZ: bu yalnız transport kodlaması. masterKey/KEK/secret
/// asla buraya düz gelmez — yalnız zaten-şifreli `bytea` alanlar geçer.
library;

import 'dart:typed_data';

/// `bytea` hex codec. Postgres kanonik hex formatı: `\x` prefix + çift-haneli hex.
abstract final class ByteaCodec {
  /// `Uint8List` → `'\x'` + küçük-harf hex (Postgres `bytea` literal).
  /// Boş liste → `'\x'` (geçerli boş bytea).
  static String encode(Uint8List bytes) {
    final sb = StringBuffer(r'\x');
    for (final b in bytes) {
      sb.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// PostgREST'ten gelen `bytea` string → `Uint8List`.
  ///
  /// `\x<hex>` (kanonik) kabul edilir; `\x` prefix toleranslı (varsa atılır).
  /// Tek-haneli/geçersiz hex → [FormatException] (bozuk sunucu verisinden sessizce
  /// hatalı byte üretmemek için — `EncryptedBlob`/`KeyAttributes` erken-validasyon disiplini).
  static Uint8List decode(String value) {
    var hex = value;
    if (hex.startsWith(r'\x') || hex.startsWith(r'\X')) {
      hex = hex.substring(2);
    }
    if (hex.length.isOdd) {
      throw FormatException(
        'ByteaCodec.decode: hex uzunluğu çift olmalı (${hex.length})',
      );
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw FormatException(
          'ByteaCodec.decode: geçersiz hex çifti "${hex.substring(i * 2, i * 2 + 2)}"',
        );
      }
      out[i] = byte;
    }
    return out;
  }
}
