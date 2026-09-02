/// BackupService integration tests (device/simulator — real libsodium:
/// Argon2id + XChaCha20-Poly1305 IETF).
///
/// `flutter test integration_test/backup_service_test.dart -d <device>`
///
/// The host tests (`test/features/import_export/backup_service_test.dart`) prove
/// the same behaviour against a fake AEAD; these prove it against the primitives
/// we actually ship — in particular that the AAD really does bind the KDF cost
/// parameters, which a fake can only simulate.
///
/// Argon2id at the production cost is slow, so every test is generous with its
/// timeout and the suite deliberately stays small.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/crypto/sodium_crypto_service.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/features/import_export/domain/backup_envelope.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';

const _password = 'Yedek-Parola12!';
const _secret = 'JBSWY3DPEHPK3PXP';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SodiumCryptoService crypto;
  late BackupService service;

  setUpAll(() async {
    crypto = SodiumCryptoService();
    await crypto.init();
    service = BackupService(crypto);
  });

  final accounts = <OtpAccount>[
    OtpAccount(
      secret: _secret,
      type: OtpType.totp,
      accountName: 'user@example.com',
      issuer: 'GitHub',
    ),
    OtpAccount(
      secret: _secret,
      type: OtpType.hotp,
      accountName: 'counter@example.com',
      issuer: 'Bank',
      algorithm: OtpAlgorithm.sha512,
      digits: 8,
      counter: 7,
    ),
    OtpAccount(
      secret: _secret,
      type: OtpType.steam,
      accountName: 'gamer',
      issuer: 'Steam',
      digits: 5,
    ),
  ];

  /// One export shared by the read-side tests — Argon2id is expensive.
  late String backupJson;

  setUpAll(() async {
    backupJson = await service.export(accounts: accounts, password: _password);
  });

  Map<String, dynamic> envelopeJson() =>
      jsonDecode(backupJson) as Map<String, dynamic>;

  testWidgets('export → import round-trip preserves every field, id included', (
    _,
  ) async {
    final restored = await service.import(
      json: backupJson,
      password: _password,
    );

    expect(restored, hasLength(accounts.length));
    for (var i = 0; i < accounts.length; i++) {
      expect(restored[i].id, accounts[i].id, reason: 'stable id survives');
      expect(restored[i], accounts[i]);
    }
  });

  testWidgets(
    'the envelope carries production KDF parameters and no plaintext',
    (_) async {
      final json = envelopeJson();
      final params = crypto.defaultKdfParams();

      expect(json['format'], BackupService.formatId);
      expect(json['version'], BackupService.supportedVersion);
      expect((json['kdf'] as Map)['alg'], BackupEnvelope.kdfAlgArgon2id);
      expect((json['kdf'] as Map)['opslimit'], params.opsLimit);
      expect((json['kdf'] as Map)['memlimit'], params.memLimit);
      expect(
        base64Decode((json['kdf'] as Map)['salt'] as String).length,
        BackupEnvelope.saltBytes,
      );
      expect((json['cipher'] as Map)['alg'], BackupEnvelope.cipherAlgXChaCha20);
      expect(
        base64Decode((json['cipher'] as Map)['nonce'] as String).length,
        24,
      );
      expect(
        json.containsKey('aad'),
        isFalse,
        reason: 'the AAD is derived, never stored',
      );

      expect(backupJson.contains(_secret), isFalse);
      expect(backupJson.contains('user@example.com'), isFalse);
      expect(backupJson.contains(_password), isFalse);
    },
  );

  testWidgets('wrong password → WrongBackupPasswordException', (_) async {
    await expectLater(
      service.import(json: backupJson, password: 'Baska-Parola12!'),
      throwsA(isA<WrongBackupPasswordException>()),
    );
  });

  testWidgets('tampered ciphertext → WrongBackupPasswordException', (_) async {
    final json = envelopeJson();
    final ct = base64Decode(json['ciphertext'] as String);
    ct[ct.length ~/ 2] ^= 0xff;
    json['ciphertext'] = base64Encode(ct);

    await expectLater(
      service.import(json: jsonEncode(json), password: _password),
      throwsA(isA<WrongBackupPasswordException>()),
    );
  });

  testWidgets('tampered nonce → WrongBackupPasswordException', (_) async {
    final json = envelopeJson();
    final nonce = base64Decode((json['cipher'] as Map)['nonce'] as String);
    nonce[0] ^= 0xff;
    (json['cipher'] as Map)['nonce'] = base64Encode(nonce);

    await expectLater(
      service.import(json: jsonEncode(json), password: _password),
      throwsA(isA<WrongBackupPasswordException>()),
    );
  });

  testWidgets('opslimit downgrade → decrypt fails: the AAD binds the KDF cost', (
    _,
  ) async {
    final json = envelopeJson();
    final original = (json['kdf'] as Map)['opslimit'] as int;
    final weakened = original - 1;
    // The point of the test: the weakened value is still inside the accepted
    // range, so the failure below comes from the AEAD tag, not from validation.
    expect(weakened, greaterThanOrEqualTo(BackupEnvelope.minOpsLimit));
    (json['kdf'] as Map)['opslimit'] = weakened;

    await expectLater(
      service.import(json: jsonEncode(json), password: _password),
      throwsA(isA<WrongBackupPasswordException>()),
    );
  });

  testWidgets('memlimit downgrade → decrypt fails for the same reason', (
    _,
  ) async {
    final json = envelopeJson();
    (json['kdf'] as Map)['memlimit'] = BackupEnvelope.minMemLimit;

    await expectLater(
      service.import(json: jsonEncode(json), password: _password),
      throwsA(isA<WrongBackupPasswordException>()),
    );
  });

  testWidgets('a swapped salt → decrypt fails (salt is authenticated)', (
    _,
  ) async {
    final json = envelopeJson();
    (json['kdf'] as Map)['salt'] = base64Encode(
      crypto.randomBytes(BackupEnvelope.saltBytes),
    );

    await expectLater(
      service.import(json: jsonEncode(json), password: _password),
      throwsA(isA<WrongBackupPasswordException>()),
    );
  });

  testWidgets('out-of-range parameters are rejected before the KDF runs', (
    _,
  ) async {
    final json = envelopeJson();
    (json['kdf'] as Map)['opslimit'] = BackupEnvelope.maxOpsLimit + 1;

    final started = DateTime.now();
    await expectLater(
      service.import(json: jsonEncode(json), password: _password),
      throwsA(isA<FormatException>()),
    );
    expect(
      DateTime.now().difference(started).inSeconds,
      lessThan(2),
      reason: 'no Argon2id work should have been done',
    );
  });

  testWidgets('a newer envelope version → UnsupportedBackupVersionException', (
    _,
  ) async {
    final json = envelopeJson();
    json['version'] = BackupService.supportedVersion + 1;

    await expectLater(
      service.import(json: jsonEncode(json), password: _password),
      throwsA(isA<UnsupportedBackupVersionException>()),
    );
  });

  testWidgets('a weak backup password is rejected', (_) async {
    await expectLater(
      service.export(accounts: accounts, password: 'kisa1!'),
      throwsA(isA<WeakPasswordException>()),
    );
  });

  testWidgets('two exports of the same vault differ (fresh salt + nonce)', (
    _,
  ) async {
    final second = await service.export(
      accounts: accounts,
      password: _password,
    );
    expect(second, isNot(backupJson));

    final a = envelopeJson();
    final b = jsonDecode(second) as Map<String, dynamic>;
    expect((a['kdf'] as Map)['salt'], isNot((b['kdf'] as Map)['salt']));
    expect((a['cipher'] as Map)['nonce'], isNot((b['cipher'] as Map)['nonce']));

    // Both still open with the same password.
    expect(
      await service.import(json: second, password: _password),
      hasLength(accounts.length),
    );
  });
}
