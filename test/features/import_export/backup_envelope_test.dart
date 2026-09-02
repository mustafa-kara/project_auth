/// Phase 5 Patch 1 — encrypted backup envelope: JSON shape, AAD derivation and
/// the strict validation that runs before anything reaches sodium.
///
/// Pure Dart (no libsodium): the envelope only carries metadata + base64 blobs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/features/import_export/domain/backup_envelope.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';

void main() {
  final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));
  final nonce = Uint8List.fromList(List<int>.generate(24, (i) => 100 + i));
  final ciphertext = Uint8List.fromList(List<int>.generate(32, (i) => i * 3));

  BackupEnvelope envelope() => BackupEnvelope(
    createdAt: DateTime.utc(2026, 9, 2, 10, 11, 12),
    opsLimit: 3,
    memLimit: 268435456,
    salt: salt,
    blob: EncryptedBlob(nonce: nonce, ciphertext: ciphertext),
  );

  /// A valid envelope map that individual tests corrupt one field at a time.
  Map<String, dynamic> validJson() =>
      jsonDecode(jsonEncode(envelope().toJson())) as Map<String, dynamic>;

  group('shape', () {
    test('toJson writes the documented envelope fields', () {
      final json = envelope().toJson();
      expect(json['format'], 'projectauth-backup');
      expect(json['version'], 1);
      expect(json['createdAt'], '2026-09-02T10:11:12.000Z');
      expect((json['kdf'] as Map)['alg'], 'argon2id');
      expect((json['kdf'] as Map)['opslimit'], 3);
      expect((json['kdf'] as Map)['memlimit'], 268435456);
      expect((json['kdf'] as Map)['salt'], base64Encode(salt));
      expect((json['cipher'] as Map)['alg'], 'xchacha20poly1305-ietf');
      expect((json['cipher'] as Map)['nonce'], base64Encode(nonce));
      expect(json['ciphertext'], base64Encode(ciphertext));
    });

    test('the envelope carries NO "aad" field — it is always recomputed', () {
      expect(envelope().toJson().containsKey('aad'), isFalse);
    });

    test('BackupService reuses the envelope constants (single source)', () {
      expect(BackupService.formatId, BackupEnvelope.formatId);
      expect(BackupService.supportedVersion, BackupEnvelope.supportedVersion);
    });

    test('fromJson round-trips every field', () {
      final restored = BackupEnvelope.fromJson(validJson());
      expect(restored.version, 1);
      expect(restored.createdAt, DateTime.utc(2026, 9, 2, 10, 11, 12));
      expect(restored.kdfAlg, 'argon2id');
      expect(restored.opsLimit, 3);
      expect(restored.memLimit, 268435456);
      expect(restored.salt, salt);
      expect(restored.cipherAlg, 'xchacha20poly1305-ietf');
      expect(restored.blob.nonce, nonce);
      expect(restored.blob.ciphertext, ciphertext);
      expect(restored.aad, envelope().aad);
    });

    test('salt getter is a defensive copy', () {
      final env = envelope();
      env.salt[0] = 0xff;
      expect(env.salt[0], salt[0]);
    });
  });

  group('AAD derivation', () {
    test('exact documented layout', () {
      expect(
        utf8.decode(envelope().aad),
        'backup|1|argon2id|3|268435456|${base64Encode(salt)}|xchacha20poly1305-ietf',
      );
    });

    test('lowering opslimit changes the AAD (downgrade is detectable)', () {
      final weakened = BackupEnvelope.aadFor(
        kdfAlg: 'argon2id',
        opsLimit: 1,
        memLimit: 268435456,
        salt: salt,
        cipherAlg: 'xchacha20poly1305-ietf',
      );
      expect(weakened, isNot(envelope().aad));
    });

    test('lowering memlimit changes the AAD', () {
      final weakened = BackupEnvelope.aadFor(
        kdfAlg: 'argon2id',
        opsLimit: 3,
        memLimit: 8 * 1024 * 1024,
        salt: salt,
        cipherAlg: 'xchacha20poly1305-ietf',
      );
      expect(weakened, isNot(envelope().aad));
    });

    test('a different salt changes the AAD', () {
      final other = Uint8List(16);
      expect(
        BackupEnvelope.aadFor(
          kdfAlg: 'argon2id',
          opsLimit: 3,
          memLimit: 268435456,
          salt: other,
          cipherAlg: 'xchacha20poly1305-ietf',
        ),
        isNot(envelope().aad),
      );
    });

    test('the AAD uses the canonical base64 of the decoded salt bytes', () {
      final restored = BackupEnvelope.fromJson(validJson());
      expect(restored.saltBase64, base64Encode(salt));
      expect(utf8.decode(restored.aad).contains(base64Encode(salt)), isTrue);
    });
  });

  group('strict validation', () {
    Matcher throwsFormat() => throwsA(isA<FormatException>());

    void rejects(String name, void Function(Map<String, dynamic> json) mutate) {
      test(name, () {
        final json = validJson();
        mutate(json);
        expect(() => BackupEnvelope.fromJson(json), throwsFormat());
      });
    }

    rejects('foreign "format"', (j) => j['format'] = 'aegis-backup');
    rejects('missing "format"', (j) => j.remove('format'));
    rejects('non-String "format"', (j) => j['format'] = 7);
    rejects('version 0', (j) => j['version'] = 0);
    rejects('missing version', (j) => j.remove('version'));
    rejects('fractional version', (j) => j['version'] = 1.5);
    rejects('missing createdAt', (j) => j.remove('createdAt'));
    rejects('unparseable createdAt', (j) => j['createdAt'] = 'yesterday');
    rejects('kdf not an object', (j) => j['kdf'] = 'argon2id');
    rejects('foreign kdf.alg', (j) => (j['kdf'] as Map)['alg'] = 'scrypt');
    rejects(
      'missing kdf.opslimit',
      (j) => (j['kdf'] as Map).remove('opslimit'),
    );
    rejects(
      'fractional kdf.opslimit',
      (j) => (j['kdf'] as Map)['opslimit'] = 2.5,
    );
    rejects(
      'opslimit below the floor',
      (j) => (j['kdf'] as Map)['opslimit'] = 0,
    );
    rejects(
      'opslimit above the ceiling',
      (j) => (j['kdf'] as Map)['opslimit'] = 11,
    );
    rejects(
      'memlimit below 8 MiB',
      (j) => (j['kdf'] as Map)['memlimit'] = 8 * 1024 * 1024 - 1,
    );
    rejects(
      'memlimit above 512 MiB',
      (j) => (j['kdf'] as Map)['memlimit'] = 512 * 1024 * 1024 + 1,
    );
    rejects(
      'salt shorter than 16 bytes',
      (j) => (j['kdf'] as Map)['salt'] = base64Encode(Uint8List(15)),
    );
    rejects(
      'salt longer than 16 bytes',
      (j) => (j['kdf'] as Map)['salt'] = base64Encode(Uint8List(17)),
    );
    rejects(
      'salt is not base64',
      (j) => (j['kdf'] as Map)['salt'] = 'not base64!!',
    );
    rejects('missing salt', (j) => (j['kdf'] as Map).remove('salt'));
    rejects(
      'foreign cipher.alg',
      (j) => (j['cipher'] as Map)['alg'] = 'aes-gcm',
    );
    rejects(
      'nonce is not 24 bytes',
      (j) => (j['cipher'] as Map)['nonce'] = base64Encode(Uint8List(23)),
    );
    rejects('missing nonce', (j) => (j['cipher'] as Map).remove('nonce'));
    rejects(
      'ciphertext shorter than the Poly1305 tag',
      (j) => j['ciphertext'] = base64Encode(Uint8List(15)),
    );
    rejects('missing ciphertext', (j) => j.remove('ciphertext'));

    test('boundary values are accepted', () {
      final low = validJson();
      (low['kdf'] as Map)['opslimit'] = 1;
      (low['kdf'] as Map)['memlimit'] = 8 * 1024 * 1024;
      expect(BackupEnvelope.fromJson(low).opsLimit, 1);

      final high = validJson();
      (high['kdf'] as Map)['opslimit'] = 10;
      (high['kdf'] as Map)['memlimit'] = 512 * 1024 * 1024;
      expect(BackupEnvelope.fromJson(high).memLimit, 512 * 1024 * 1024);
      expect(
        BackupEnvelope.maxMemLimit,
        512 * 1024 * 1024,
        reason: 'mobil OOM sigortası — docs/CRYPTO.md §16 tablosu',
      );
    });

    test('integer-valued doubles are accepted (JSON has no int type)', () {
      final json = validJson();
      (json['kdf'] as Map)['opslimit'] = 3.0;
      expect(BackupEnvelope.fromJson(json).opsLimit, 3);
    });

    test(
      'a newer version calls onUnsupportedVersion instead of FormatException',
      () {
        final json = validJson();
        json['version'] = 2;
        expect(
          () => BackupEnvelope.fromJson(
            json,
            onUnsupportedVersion: (v) => throw StateError('too new: $v'),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('a newer version without a callback is still a FormatException', () {
      final json = validJson();
      json['version'] = 99;
      expect(() => BackupEnvelope.fromJson(json), throwsFormat());
    });

    test('the constructor validates too (not just fromJson)', () {
      expect(
        () => BackupEnvelope(
          createdAt: DateTime.utc(2026),
          opsLimit: 3,
          memLimit: 268435456,
          salt: Uint8List(8),
          blob: EncryptedBlob(nonce: nonce, ciphertext: ciphertext),
        ),
        throwsFormat(),
      );
    });
  });
}
