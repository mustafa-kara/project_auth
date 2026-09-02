/// SupabaseKeyAttributesRepository mapping testleri (Faz 3 Patch 2).
///
/// Gerçek ağ GEREKMEZ — `toRow`/`fromRow` saf statik dönüşümler test edilir
/// (KeyAttributes ↔ sunucu satırı round-trip KAYIPSIZ; bmk gönderilmez/restore null).
/// Gerçek Supabase ağı = manuel/integration checklist (bytea INSERT format teyidi).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/features/account/data/bytea_codec.dart';
import 'package:project_auth/features/account/data/supabase_key_attributes_repository.dart';

EncryptedBlob _blob(int seed) => EncryptedBlob(
  nonce: Uint8List.fromList(
    List.generate(EncryptedBlob.nonceBytes, (i) => (i + seed) & 0xff),
  ),
  ciphertext: Uint8List.fromList(
    List.generate(48, (i) => (i * 7 + seed) & 0xff),
  ),
);

KeyAttributes _attrs({EncryptedBlob? bmk}) => KeyAttributes(
  kdfSalt: Uint8List.fromList(
    List.generate(KeyAttributes.saltBytes, (i) => (i * 3 + 1) & 0xff),
  ),
  kdfOps: 4,
  kdfMem: 65536,
  encryptedMasterKey: _blob(10),
  recoveryEncryptedMasterKey: _blob(99),
  biometricEncryptedMasterKey: bmk,
);

void main() {
  group('SupabaseKeyAttributesRepository mapping', () {
    test('toRow: 7 veri kolonu; bmk/version GÖNDERİLMEZ', () {
      final row = SupabaseKeyAttributesRepository.toRow('uid-A', _attrs());
      expect(
        row.keys,
        containsAll(<String>{
          'user_id',
          'kdf_salt',
          'kdf_ops',
          'kdf_mem',
          'encrypted_master_key',
          'master_key_nonce',
          'recovery_encrypted_master_key',
          'recovery_nonce',
        }),
      );
      // bmk ve blob version sunucuya GİTMEZ (sunucuda kolon yok).
      expect(row.containsKey('bmk'), isFalse);
      expect(row.containsKey('biometric_encrypted_master_key'), isFalse);
      expect(row.containsKey('version'), isFalse);
      expect(row['user_id'], 'uid-A');
      expect(row['kdf_ops'], 4);
      expect(row['kdf_mem'], 65536);
      // bytea alanları \x hex.
      expect(row['kdf_salt'], startsWith(r'\x'));
    });

    test(
      'toRow → fromRow round-trip KAYIPSIZ (salt/ops/mem/emk/remk birebir)',
      () {
        final original = _attrs(bmk: _blob(200)); // bmk dolu olsa bile
        final row = SupabaseKeyAttributesRepository.toRow('uid-A', original);
        final restored = SupabaseKeyAttributesRepository.fromRow(
          Map<String, dynamic>.from(row),
        );

        expect(restored.kdfSalt, original.kdfSalt);
        expect(restored.kdfOps, original.kdfOps);
        expect(restored.kdfMem, original.kdfMem);
        expect(
          restored.encryptedMasterKey.nonce,
          original.encryptedMasterKey.nonce,
        );
        expect(
          restored.encryptedMasterKey.ciphertext,
          original.encryptedMasterKey.ciphertext,
        );
        expect(
          restored.recoveryEncryptedMasterKey.nonce,
          original.recoveryEncryptedMasterKey.nonce,
        );
        expect(
          restored.recoveryEncryptedMasterKey.ciphertext,
          original.recoveryEncryptedMasterKey.ciphertext,
        );
        // bmk restore'da ASLA gelmez (sunucuda yok) → null.
        expect(restored.biometricEncryptedMasterKey, isNull);
      },
    );

    test(
      'fromRow: eksik kolon → FormatException (fetch SyncMalformedRemote yapar)',
      () {
        final row = SupabaseKeyAttributesRepository.toRow('uid-A', _attrs());
        row.remove('recovery_nonce');
        expect(
          () => SupabaseKeyAttributesRepository.fromRow(row),
          throwsFormatException,
        );
      },
    );

    test('fromRow: geçersiz bytea → FormatException', () {
      final row = SupabaseKeyAttributesRepository.toRow('uid-A', _attrs());
      row['kdf_salt'] = r'\xZZZZ';
      expect(
        () => SupabaseKeyAttributesRepository.fromRow(row),
        throwsFormatException,
      );
    });

    test('fromRow: kdf_ops yanlış tip → FormatException', () {
      final row = SupabaseKeyAttributesRepository.toRow('uid-A', _attrs());
      row['kdf_ops'] = 'dört';
      expect(
        () => SupabaseKeyAttributesRepository.fromRow(row),
        throwsFormatException,
      );
    });

    test('bytea kolonları decode edilebilir (toRow çıktısı geçerli hex)', () {
      final row = SupabaseKeyAttributesRepository.toRow('uid-A', _attrs());
      // Her bytea kolonu ByteaCodec ile decode edilebilmeli.
      for (final k in [
        'kdf_salt',
        'encrypted_master_key',
        'master_key_nonce',
        'recovery_encrypted_master_key',
        'recovery_nonce',
      ]) {
        expect(
          () => ByteaCodec.decode(row[k] as String),
          returnsNormally,
          reason: '$k geçerli hex olmalı',
        );
      }
    });
  });
}
