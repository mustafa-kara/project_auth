/// BIP-39 mnemonic encode/decode — **kendi implementasyonumuz**.
///
/// Recovery key, uygulamanın ANA güvenlik yüzeylerinden biri olduğu için
/// kanonik `bip39` paketi (yıllardır bakımsız/unverified) güven sınırına
/// sokulmaz. Burada yalnızca **kodlama + checksum** yapılır (kripto rutini
/// DEĞİL): 256-bit entropy ↔ 24 kelime. SHA-256 için `crypto` paketi kullanılır.
///
/// Şema (BIP-39, yalnız 256-bit destekli — recovery key sabit 32 byte):
///   - entropy: 256 bit (32 byte)
///   - checksum: SHA-256(entropy)'nin ilk `256/32 = 8` biti
///   - toplam: 264 bit = 24 × 11 bit → her 11-bit grup bir kelime indeksi (0..2047)
///
/// `decode` checksum'u doğrular → yazım hatası / yanlış kelime yakalanır.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bip39_wordlist.dart';

/// BIP-39 24-kelime (256-bit) mnemonic kodlayıcı/çözücü.
abstract final class Bip39 {
  /// Recovery key entropy uzunluğu (byte). Yalnız 256-bit desteklenir.
  static const int entropyBytes = 32;

  /// Mnemonic kelime sayısı (256-bit + 8-bit checksum = 264 bit / 11).
  static const int wordCount = 24;

  static const int _checksumBits = 8; // 256 / 32

  /// 32-byte [entropy]'den 24-kelimelik mnemonic üretir.
  ///
  /// [entropy] uzunluğu 32 değilse [ArgumentError].
  static List<String> encode(Uint8List entropy) {
    if (entropy.length != entropyBytes) {
      throw ArgumentError.value(
        entropy.length,
        'entropy',
        'BIP39 entropy 32 byte olmalı (256-bit)',
      );
    }

    // entropy bit'leri + checksum bit'leri tek bir bit-dizisinde toplanır.
    final checksum = _checksum(entropy);
    // 264 bit: önce 256 entropy biti, sonra 8 checksum biti.
    final bits = <bool>[];
    for (final byte in entropy) {
      for (int i = 7; i >= 0; i--) {
        bits.add((byte >> i) & 1 == 1);
      }
    }
    // _checksumBits=8 → checksum'ın tamamı (ilk byte), MSB→LSB.
    for (int i = _checksumBits - 1; i >= 0; i--) {
      bits.add((checksum >> i) & 1 == 1);
    }

    assert(bits.length == wordCount * 11);

    final words = <String>[];
    for (int w = 0; w < wordCount; w++) {
      int index = 0;
      for (int b = 0; b < 11; b++) {
        index = (index << 1) | (bits[w * 11 + b] ? 1 : 0);
      }
      words.add(bip39Wordlist[index]);
    }
    return words;
  }

  /// 24-kelimelik mnemonic'ten 32-byte entropy'yi geri kurar.
  ///
  /// Normalize: trim + lowercase + tek-boşluk (giriş [words] zaten liste ise
  /// her eleman trim+lowercase edilir). Hatalar:
  ///   - kelime sayısı ≠ 24 → [FormatException]
  ///   - bilinmeyen kelime → [FormatException]
  ///   - checksum uyuşmazlığı (yazım hatası) → [FormatException]
  static Uint8List decode(List<String> words) {
    final normalized = words
        .map((w) => w.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toList(growable: false);

    if (normalized.length != wordCount) {
      throw FormatException(
        'BIP39: $wordCount kelime bekleniyor, ${normalized.length} verildi',
      );
    }

    // Kelime → indeks → 11-bit. Tüm bit dizisini topla.
    final bits = <bool>[];
    for (final word in normalized) {
      final index = bip39Wordlist.indexOf(word);
      if (index < 0) {
        throw FormatException('BIP39: bilinmeyen kelime "$word"');
      }
      for (int b = 10; b >= 0; b--) {
        bits.add((index >> b) & 1 == 1);
      }
    }

    assert(bits.length == wordCount * 11);

    const entropyBits = entropyBytes * 8; // 256
    // İlk 256 bit entropy.
    final entropy = Uint8List(entropyBytes);
    for (int i = 0; i < entropyBits; i++) {
      if (bits[i]) {
        entropy[i ~/ 8] |= 1 << (7 - (i % 8));
      }
    }

    // Son 8 bit: verilen checksum.
    int providedChecksum = 0;
    for (int i = 0; i < _checksumBits; i++) {
      providedChecksum =
          (providedChecksum << 1) | (bits[entropyBits + i] ? 1 : 0);
    }

    final expectedChecksum = _checksum(entropy);
    // _checksumBits=8 → tüm checksum byte'ı karşılaştırılır.
    if (providedChecksum != expectedChecksum) {
      throw const FormatException(
        'BIP39: checksum uyuşmuyor (yazım hatası veya bozuk mnemonic)',
      );
    }

    return entropy;
  }

  /// SHA-256(entropy)'nin ilk byte'ı (8-bit checksum için yeterli; 256-bit
  /// entropy → checksum 8 bit = ilk byte'ın tamamı).
  static int _checksum(Uint8List entropy) {
    final digest = sha256.convert(entropy).bytes;
    return digest[0];
  }
}
