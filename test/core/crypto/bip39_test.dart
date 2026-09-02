/// BIP-39 saf-Dart testleri (libsodium gerektirmez → plain `flutter test`).
///
/// Recovery key ANA güvenlik yüzeyi → geniş kapsam: wordlist bütünlüğü,
/// round-trip, resmi Trezor test vektörleri, checksum/normalize/hata yolları.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/bip39.dart';
import 'package:project_auth/core/crypto/bip39_wordlist.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('wordlist bütünlüğü', () {
    test('tam 2048 kelime', () {
      expect(bip39Wordlist.length, 2048);
    });
    test('duplicate yok', () {
      expect(bip39Wordlist.toSet().length, 2048);
    });
    test('sınır kelimeleri doğru (resmi liste)', () {
      expect(bip39Wordlist.first, 'abandon');
      expect(bip39Wordlist.last, 'zoo');
    });
    test('hepsi lowercase + boşluksuz', () {
      for (final w in bip39Wordlist) {
        expect(w, w.toLowerCase());
        expect(w.contains(' '), isFalse);
        expect(w.isNotEmpty, isTrue);
      }
    });
  });

  group('resmi Trezor test vektörleri (256-bit)', () {
    // bitcoin/bips + trezor/python-mnemonic vectors.json (English, 32-byte).
    const vectors = <(String, String)>[
      (
        '0000000000000000000000000000000000000000000000000000000000000000',
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art',
      ),
      (
        '7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f',
        'legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title',
      ),
      (
        '8080808080808080808080808080808080808080808080808080808080808080',
        'letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless',
      ),
      (
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote',
      ),
      (
        '066dca1a2bb7e8a1db2832148ce9933eea0f3ac9548d793112d9a95c9407efad',
        'all hour make first leader extend hole alien behind guard gospel lava path output census museum junior mass reopen famous sing advance salt reform',
      ),
      (
        'f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f',
        'void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold',
      ),
    ];

    for (final (entropyHex, mnemonic) in vectors) {
      test('encode: ${entropyHex.substring(0, 8)}…', () {
        expect(Bip39.encode(_hex(entropyHex)).join(' '), mnemonic);
      });
      test('decode: ${entropyHex.substring(0, 8)}…', () {
        expect(Bip39.decode(mnemonic.split(' ')), _hex(entropyHex));
      });
    }
  });

  group('round-trip (deterministik üretilmiş entropy)', () {
    test('çok sayıda entropy: encode→decode kimliği korur', () {
      for (int seed = 0; seed < 50; seed++) {
        final entropy = Uint8List(32);
        // Math.random kullanılmaz (test deterministik) — basit doğrusal üretim.
        for (int i = 0; i < 32; i++) {
          entropy[i] = (seed * 31 + i * 7 + (seed ^ i)) & 0xff;
        }
        final words = Bip39.encode(entropy);
        expect(words.length, 24);
        expect(Bip39.decode(words), entropy);
      }
    });
  });

  group('hata yolları', () {
    test('encode: 32 byte değilse ArgumentError', () {
      expect(() => Bip39.encode(Uint8List(16)), throwsArgumentError);
      expect(() => Bip39.encode(Uint8List(31)), throwsArgumentError);
    });

    test('checksum hatası: tek kelime değiştir → FormatException', () {
      final words = Bip39.encode(
        _hex(
          '0000000000000000000000000000000000000000000000000000000000000000',
        ),
      );
      // son kelime 'art' → checksum'ı bozan başka bir kelime
      final broken = [...words]..[23] = 'zoo';
      expect(() => Bip39.decode(broken), throwsFormatException);
    });

    test('bilinmeyen kelime → FormatException', () {
      final words = Bip39.encode(
        _hex(
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        ),
      );
      final broken = [...words]..[0] = 'notaword';
      expect(() => Bip39.decode(broken), throwsFormatException);
    });

    test('yanlış kelime sayısı (23/25) → FormatException', () {
      final words = Bip39.encode(
        _hex(
          '8080808080808080808080808080808080808080808080808080808080808080',
        ),
      );
      expect(() => Bip39.decode(words.sublist(0, 23)), throwsFormatException);
      expect(() => Bip39.decode([...words, words.last]), throwsFormatException);
    });

    test('normalize: büyük harf + fazla/baş-son boşluk toleranslı', () {
      final entropy = _hex(
        '066dca1a2bb7e8a1db2832148ce9933eea0f3ac9548d793112d9a95c9407efad',
      );
      final words = Bip39.encode(entropy);
      // UPPER + baş/son boşluk + araya boş eleman karışımı
      final messy = words.map((w) => '  ${w.toUpperCase()}  ').toList()
        ..insert(0, '   ')
        ..add('');
      expect(Bip39.decode(messy), entropy);
    });
  });
}
