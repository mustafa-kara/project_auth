import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/base32.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/core/otp/otp_generator.dart';

void main() {
  const gen = OtpGenerator();

  group('HOTP — RFC 4226 Appendix D test vektörleri', () {
    // Secret = ASCII "12345678901234567890" (20 byte).
    final secret = Uint8List.fromList(ascii.encode('12345678901234567890'));

    // RFC 4226 Appendix D, Table 1 — counter 0..9, 6 hane.
    const expected = <int, String>{
      0: '755224',
      1: '287082',
      2: '359152',
      3: '969429',
      4: '338314',
      5: '254676',
      6: '287922',
      7: '162583',
      8: '399871',
      9: '520489',
    };

    expected.forEach((counter, code) {
      test('counter=$counter → $code', () {
        expect(gen.hotp(secret: secret, counter: counter), code);
      });
    });
  });

  group('TOTP — RFC 6238 Appendix B test vektörleri', () {
    // Her algoritmanın kendi secret'ı (RFC: SHA1=20B, SHA256=32B, SHA512=64B);
    // tümü "12345678901234567890" deseninin tekrarı (ASCII).
    final secretSha1 = Uint8List.fromList(ascii.encode('12345678901234567890'));
    final secretSha256 = Uint8List.fromList(
      ascii.encode('12345678901234567890123456789012'),
    );
    final secretSha512 = Uint8List.fromList(
      ascii.encode(
        '1234567890123456789012345678901234567890123456789012345678901234',
      ),
    );

    // RFC 6238 Appendix B tablosu (8 haneli), period=30.
    // (unixTime saniye, algoritma, beklenen 8 haneli kod)
    final cases = <(int, OtpAlgorithm, Uint8List, String)>[
      (59, OtpAlgorithm.sha1, secretSha1, '94287082'),
      (59, OtpAlgorithm.sha256, secretSha256, '46119246'),
      (59, OtpAlgorithm.sha512, secretSha512, '90693936'),
      (1111111109, OtpAlgorithm.sha1, secretSha1, '07081804'),
      (1111111109, OtpAlgorithm.sha256, secretSha256, '68084774'),
      (1111111109, OtpAlgorithm.sha512, secretSha512, '25091201'),
      (1111111111, OtpAlgorithm.sha1, secretSha1, '14050471'),
      (1234567890, OtpAlgorithm.sha1, secretSha1, '89005924'),
      (2000000000, OtpAlgorithm.sha1, secretSha1, '69279037'),
      (20000000000, OtpAlgorithm.sha1, secretSha1, '65353130'),
    ];

    for (final (unixTime, algo, secret, code) in cases) {
      test('t=$unixTime ${algo.uriName} → $code', () {
        final time = DateTime.fromMillisecondsSinceEpoch(
          unixTime * 1000,
          isUtc: true,
        );
        expect(
          gen.totp(secret: secret, time: time, digits: 8, algorithm: algo),
          code,
        );
      });
    }
  });

  group('TOTP sayaç & geri sayım', () {
    test('counter floor(unix/period)', () {
      final t = DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true);
      expect(gen.totpCounter(time: t), 1); // 59 / 30 = 1
    });

    test('secondsRemaining doğru', () {
      // t=59 → 59 % 30 = 29 → kalan 1 sn
      final t = DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true);
      expect(gen.secondsRemaining(time: t), 1);
    });
  });

  group('Steam Guard', () {
    test('5 karakter ve Steam alfabesinden üretir', () {
      final secret = Base32.decode('JBSWY3DPEHPK3PXP');
      final code = gen.steam(
        secret: secret,
        time: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      expect(code.length, 5);
      expect(
        RegExp(r'^[23456789BCDFGHJKMNPQRTVWXY]{5}$').hasMatch(code),
        isTrue,
      );
    });
  });

  group('Base32', () {
    test('bilinen vektör "JBSWY3DP" → "Hello"', () {
      expect(ascii.decode(Base32.decode('JBSWY3DP')), 'Hello');
    });

    test('küçük harf, boşluk, padding tolere edilir', () {
      final a = Base32.decode('JBSW Y3DP');
      final b = Base32.decode('jbswy3dp');
      expect(a, equals(b));
    });

    test('geçersiz karakter FormatException', () {
      expect(() => Base32.decode('JBSW0189!'), throwsFormatException);
    });

    test('round-trip encode/decode', () {
      final bytes = Uint8List.fromList([0, 1, 2, 250, 255, 128, 64]);
      expect(Base32.decode(Base32.encode(bytes)), equals(bytes));
    });
  });
}
