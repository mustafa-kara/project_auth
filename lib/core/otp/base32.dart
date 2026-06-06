/// RFC 4648 Base32 decode/encode (padding opsiyonel).
///
/// `otpauth://` secret'ları Base32 ile kodlanır (büyük/küçük harf duyarsız,
/// `=` padding ve boşluklar göz ardı edilir). TOTP/HOTP secret'larını ham
/// byte'lara çevirmek için kullanılır.
library;

import 'dart:typed_data';

const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// Base32 ters arama tablosu (geçersiz karakter = -1).
final List<int> _decodeTable = _buildDecodeTable();

List<int> _buildDecodeTable() {
  final table = List<int>.filled(128, -1);
  for (var i = 0; i < _alphabet.length; i++) {
    table[_alphabet.codeUnitAt(i)] = i;
  }
  return table;
}

class Base32 {
  const Base32._();

  /// Base32 string'i byte dizisine çevirir.
  ///
  /// Boşluk/tire/padding (`=`) yok sayılır; küçük harf kabul edilir.
  /// Geçersiz karakterde [FormatException] fırlatır.
  static Uint8List decode(String input) {
    final cleaned = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]'), '')
        .replaceAll('=', '');
    if (cleaned.isEmpty) return Uint8List(0);

    final output = <int>[];
    var buffer = 0;
    var bitsLeft = 0;

    for (var i = 0; i < cleaned.length; i++) {
      final c = cleaned.codeUnitAt(i);
      final value = (c < 128) ? _decodeTable[c] : -1;
      if (value < 0) {
        throw FormatException('Geçersiz Base32 karakteri: "${cleaned[i]}"');
      }
      buffer = (buffer << 5) | value;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        output.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return Uint8List.fromList(output);
  }

  /// Byte dizisini Base32 string'e çevirir (padding'siz, büyük harf).
  static String encode(List<int> bytes) {
    if (bytes.isEmpty) return '';
    final sb = StringBuffer();
    var buffer = 0;
    var bitsLeft = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | (b & 0xFF);
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        sb.write(_alphabet[(buffer >> bitsLeft) & 0x1F]);
      }
    }
    if (bitsLeft > 0) {
      sb.write(_alphabet[(buffer << (5 - bitsLeft)) & 0x1F]);
    }
    return sb.toString();
  }
}
