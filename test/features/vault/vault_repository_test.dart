/// OtpAccount JSON round-trip + SecureStorageVaultRepository dayanıklılık testleri.
///
/// JSON, kalıcılığın (Faz 1 secure_storage, Faz 2 E2E) serileştirme temelidir:
/// `otpauth://` URI'den farklı olarak `id` ve `counter` gibi yerel alanları korur.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';

class _MockStorage extends Mock implements FlutterSecureStorage {}

void main() {
  group('OtpAccount JSON round-trip', () {
    test('tüm alanlar (id ve counter dahil) korunur', () {
      final original = OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.hotp,
        issuer: 'GitHub',
        accountName: 'octocat',
        algorithm: OtpAlgorithm.sha256,
        digits: 8,
        period: 60,
        counter: 42,
      );
      final restored = OtpAccount.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored, original); // id dahil tüm props eşit (Equatable)
    });

    test('issuer null ise round-trip\'te null kalır', () {
      final original = OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        accountName: 'no-issuer',
      );
      final restored = OtpAccount.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored.issuer, isNull);
      expect(restored, original);
    });

    test('Steam tipi korunur', () {
      final original = OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.steam,
        issuer: 'Steam',
        accountName: 'gaben',
        digits: 5,
      );
      final restored = OtpAccount.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored.type, OtpType.steam);
      expect(restored, original);
    });

    test('id eksikse yeni id üretilir (geriye dönük güvenli)', () {
      final json = {
        'secret': 'JBSWY3DPEHPK3PXP',
        'type': 'totp',
        'accountName': 'legacy',
      };
      final restored = OtpAccount.fromJson(json);
      expect(restored.id, isNotEmpty);
    });

    test('geçersiz type FormatException fırlatır', () {
      expect(
        () => OtpAccount.fromJson({
          'secret': 'JBSWY3DPEHPK3PXP',
          'type': 'wat',
          'accountName': 'x',
        }),
        throwsFormatException,
      );
    });

    test('secret eksik FormatException fırlatır', () {
      expect(
        () => OtpAccount.fromJson({'type': 'totp', 'accountName': 'x'}),
        throwsFormatException,
      );
    });

    test('geçersiz Base32 secret FormatException fırlatır (kart crash önlenir)',
        () {
      expect(
        () => OtpAccount.fromJson({
          'secret': '0118!!!', // Base32'de geçersiz karakter
          'type': 'totp',
          'accountName': 'x',
        }),
        throwsFormatException,
      );
    });

    test('aralık dışı period FormatException fırlatır (period=0 bölme önlenir)',
        () {
      expect(
        () => OtpAccount.fromJson({
          'secret': 'JBSWY3DPEHPK3PXP',
          'type': 'totp',
          'accountName': 'x',
          'period': 0,
        }),
        throwsFormatException,
      );
    });

    test('aralık dışı digits FormatException fırlatır', () {
      expect(
        () => OtpAccount.fromJson({
          'secret': 'JBSWY3DPEHPK3PXP',
          'type': 'totp',
          'accountName': 'x',
          'digits': 12,
        }),
        throwsFormatException,
      );
    });

    test('yanlış tipli "type" (sayı) FormatException fırlatır (TypeError değil)',
        () {
      expect(
        () => OtpAccount.fromJson({
          'secret': 'JBSWY3DPEHPK3PXP',
          'type': 123, // String beklenir
          'accountName': 'x',
        }),
        throwsFormatException,
      );
    });

    test('yanlış tipli "digits" (liste) FormatException fırlatır (TypeError değil)',
        () {
      expect(
        () => OtpAccount.fromJson({
          'secret': 'JBSWY3DPEHPK3PXP',
          'type': 'totp',
          'accountName': 'x',
          'digits': [6], // num/String beklenir
        }),
        throwsFormatException,
      );
    });

    test('sayısal String "digits" tolere edilir (esnek geri okuma)', () {
      final a = OtpAccount.fromJson({
        'secret': 'JBSWY3DPEHPK3PXP',
        'type': 'totp',
        'accountName': 'x',
        'digits': '8',
      });
      expect(a.digits, 8);
    });

    // Security review finding 4: fractional numeric fields must be REJECTED, not
    // silently truncated (consistency with KeyAttributes strict policy, CRYPTO.md §8).
    test('fractional "digits" (6.9) → FormatException (not truncated to 6)', () {
      expect(
        () => OtpAccount.fromJson({
          'secret': 'JBSWY3DPEHPK3PXP',
          'type': 'totp',
          'accountName': 'x',
          'digits': 6.9,
        }),
        throwsFormatException,
      );
    });

    test('fractional "counter" (1.5) → FormatException (not truncated to 1)', () {
      expect(
        () => OtpAccount.fromJson({
          'secret': 'JBSWY3DPEHPK3PXP',
          'type': 'hotp',
          'accountName': 'x',
          'counter': 1.5,
        }),
        throwsFormatException,
      );
    });

    test('integer-valued double "digits" (8.0) accepted (JSON round-trip safe)', () {
      final a = OtpAccount.fromJson({
        'secret': 'JBSWY3DPEHPK3PXP',
        'type': 'totp',
        'accountName': 'x',
        'digits': 8.0,
      });
      expect(a.digits, 8);
    });
  });

  group('SecureStorageVaultRepository.load dayanıklılık', () {
    test('bozuk üst-düzey JSON crash etmez, boş liste döner', () async {
      final storage = _MockStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => 'bu geçerli json değil {{{');
      final repo = SecureStorageVaultRepository(storage: storage);
      expect((await repo.load()).accounts, isEmpty);
    });

    test('bozuk TEK kayıt atlanır, sağlamlar yüklenir + corruptedCount', () async {
      final good = OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        accountName: 'good',
      );
      final raw = jsonEncode([
        good.toJson(),
        {'secret': '!!!bozuk', 'type': 'totp', 'accountName': 'bad'}, // geçersiz secret
        {'secret': 'JBSWY3DPEHPK3PXP', 'type': 99, 'accountName': 'tip'}, // yanlış tip → TypeError değil
        {'secret': 'JBSWY3DPEHPK3PXP', 'type': 'totp', 'accountName': 'x', 'period': 'çok'}, // yanlış tip
        {'foo': 'bar'}, // tamamen alakasız
      ]);
      final storage = _MockStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => raw);
      final repo = SecureStorageVaultRepository(storage: storage);
      final loaded = await repo.load();
      expect(loaded.accounts.map((a) => a.accountName), ['good']);
      expect(loaded.corruptedCount, 4); // 4 bozuk kayıt atlandı + sayıldı
    });

    test('depo boşsa boş liste döner', () async {
      final storage = _MockStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      final repo = SecureStorageVaultRepository(storage: storage);
      expect((await repo.load()).accounts, isEmpty);
    });
  });
}
