import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/core/otp/otpauth_uri.dart';

void main() {
  group('OtpAuthUri.parse', () {
    test('standart TOTP — issuer:account label + query', () {
      final a = OtpAuthUri.parse(
          'otpauth://totp/GitHub:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&period=30&digits=6');
      expect(a.type, OtpType.totp);
      expect(a.issuer, 'GitHub');
      expect(a.accountName, 'alice@example.com');
      expect(a.secret, 'JBSWY3DPEHPK3PXP');
      expect(a.digits, 6);
      expect(a.period, 30);
      expect(a.algorithm, OtpAlgorithm.sha1);
    });

    test('issuer yalnız label\'da', () {
      final a = OtpAuthUri.parse(
          'otpauth://totp/ACME:bob?secret=JBSWY3DPEHPK3PXP');
      expect(a.issuer, 'ACME');
      expect(a.accountName, 'bob');
    });

    test('query issuer label issuer\'ı geçersiz kılar', () {
      final a = OtpAuthUri.parse(
          'otpauth://totp/Old:bob?secret=JBSWY3DPEHPK3PXP&issuer=New');
      expect(a.issuer, 'New');
    });

    test('HOTP counter parse edilir', () {
      final a = OtpAuthUri.parse(
          'otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=42');
      expect(a.type, OtpType.hotp);
      expect(a.counter, 42);
    });

    test('SHA256/8 hane', () {
      final a = OtpAuthUri.parse(
          'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=SHA256&digits=8');
      expect(a.algorithm, OtpAlgorithm.sha256);
      expect(a.digits, 8);
    });

    test('Steam (issuer=Steam + totp) → OtpType.steam', () {
      final a = OtpAuthUri.parse(
          'otpauth://totp/Steam:player?secret=JBSWY3DPEHPK3PXP&issuer=Steam');
      expect(a.type, OtpType.steam);
    });

    test('URL-encoded label çözülür', () {
      final a = OtpAuthUri.parse(
          'otpauth://totp/Big%20Co%3Auser%40mail.com?secret=JBSWY3DPEHPK3PXP');
      expect(a.issuer, 'Big Co');
      expect(a.accountName, 'user@mail.com');
    });

    test('secret yoksa FormatException', () {
      expect(() => OtpAuthUri.parse('otpauth://totp/x?issuer=Y'),
          throwsFormatException);
    });

    test('yanlış şema FormatException', () {
      expect(() => OtpAuthUri.parse('https://totp/x?secret=ABC'),
          throwsFormatException);
    });
  });

  group('parse — input validasyonu (malformed → FormatException, crash değil)', () {
    test('geçersiz Base32 secret reddedilir (parse anında)', () {
      // Eski davranış: parse geçer, secretBytes (kart render) patlardı → UI crash.
      expect(() => OtpAuthUri.parse('otpauth://totp/x?secret=10101010'),
          throwsFormatException);
    });

    test('period=0 reddedilir (sıfıra bölme önlenir)', () {
      expect(
          () => OtpAuthUri.parse(
              'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=0'),
          throwsFormatException);
    });

    test('digits=0 reddedilir', () {
      expect(
          () => OtpAuthUri.parse(
              'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=0'),
          throwsFormatException);
    });

    test('digits=20 (aralık dışı) reddedilir', () {
      expect(
          () => OtpAuthUri.parse(
              'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=20'),
          throwsFormatException);
    });

    test('sayısal olmayan period reddedilir', () {
      expect(
          () => OtpAuthUri.parse(
              'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=abc'),
          throwsFormatException);
    });

    test('negatif counter reddedilir', () {
      expect(
          () => OtpAuthUri.parse(
              'otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=-1'),
          throwsFormatException);
    });

    test('HOTP counter eksikse reddedilir (Key URI Format: zorunlu)', () {
      // Eksik counter'ı 0 varsaymak yanlış sayaçla token ekletirdi.
      expect(
          () => OtpAuthUri.parse(
              'otpauth://hotp/Acme:alice?secret=JBSWY3DPEHPK3PXP'),
          throwsFormatException);
    });

    test('HOTP counter verilirse kabul (0 dahil açıkça verilmiş)', () {
      expect(
          OtpAuthUri.parse(
                  'otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=0')
              .counter,
          0);
      expect(
          OtpAuthUri.parse(
                  'otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=42')
              .counter,
          42);
    });

    test('TOTP/Steam counter eksikliği sorun değil (kullanılmaz → 0)', () {
      expect(
          OtpAuthUri.parse('otpauth://totp/x?secret=JBSWY3DPEHPK3PXP').counter,
          0);
      expect(
          OtpAuthUri.parse('otpauth://steam/x?secret=JBSWY3DPEHPK3PXP').counter,
          0);
    });

    test('bilinmeyen algorithm reddedilir (sessizce SHA1\'e düşmez)', () {
      expect(
          () => OtpAuthUri.parse(
              'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=SHA3'),
          throwsFormatException);
      expect(
          () => OtpAuthUri.parse(
              'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=md5'),
          throwsFormatException);
    });

    test('geçerli algorithm değerleri kabul (tire/harf toleransı)', () {
      expect(
          OtpAuthUri.parse(
                  'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=sha-256')
              .algorithm,
          OtpAlgorithm.sha256);
      expect(
          OtpAuthUri.parse(
                  'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=SHA512')
              .algorithm,
          OtpAlgorithm.sha512);
    });

    test('eksik/boş algorithm → SHA1 varsayılan (kabul)', () {
      expect(
          OtpAuthUri.parse('otpauth://totp/x?secret=JBSWY3DPEHPK3PXP')
              .algorithm,
          OtpAlgorithm.sha1);
      expect(
          OtpAuthUri.parse(
                  'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=')
              .algorithm,
          OtpAlgorithm.sha1);
    });

    test('parse edilen her hesap stabil benzersiz id taşır', () {
      final a = OtpAuthUri.parse('otpauth://totp/x?secret=JBSWY3DPEHPK3PXP');
      final b = OtpAuthUri.parse('otpauth://totp/x?secret=JBSWY3DPEHPK3PXP');
      expect(a.id, isNotEmpty);
      expect(a.id, isNot(b.id)); // her parse ayrı kimlik üretir
    });

    test('geçerli sınır değerleri kabul (digits 6/7/8, period 30)', () {
      for (final d in [6, 7, 8]) {
        final a = OtpAuthUri.parse(
            'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=$d');
        expect(a.digits, d);
      }
    });

    test('Steam digits=5 kabul (özel izinli değer)', () {
      final a = OtpAuthUri.parse(
          'otpauth://steam/x?secret=JBSWY3DPEHPK3PXP&digits=5');
      expect(a.digits, 5);
      expect(a.type, OtpType.steam);
    });

    test('parse edilen hesabın secretBytes\'ı her zaman güvenli decode olur', () {
      final a =
          OtpAuthUri.parse('otpauth://totp/x?secret=JBSWY3DPEHPK3PXP');
      expect(a.secretBytes.isNotEmpty, isTrue); // crash yok
    });
  });

  group('serialize → parse round-trip', () {
    test('TOTP round-trip alanları korur', () {
      final original = OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        issuer: 'GitHub',
        accountName: 'alice@example.com',
        algorithm: OtpAlgorithm.sha256,
        digits: 8,
        period: 60,
      );
      final reparsed = OtpAuthUri.parse(OtpAuthUri.serialize(original));
      // `id` lokal bir kavramdır ve otpauth:// URI'de taşınmaz → reparsed yeni id alır.
      // Eşitliği id'den bağımsız doğrula (original'in id'sini kopyalayarak).
      expect(reparsed.copyWith(id: original.id), original);
    });

    test('HOTP round-trip counter korur', () {
      final original = OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.hotp,
        accountName: 'svc',
        counter: 7,
      );
      final reparsed = OtpAuthUri.parse(OtpAuthUri.serialize(original));
      expect(reparsed.type, OtpType.hotp);
      expect(reparsed.counter, 7);
      expect(reparsed.accountName, 'svc');
    });
  });
}
