/// SupabaseTokenRepository mapping testleri (Faz 3 Patch 3).
///
/// Gerçek ağ GEREKMEZ — `toRow`/`tryParseRow` saf statik dönüşümler test edilir
/// (RawTokenRecord ↔ sunucu satırı round-trip KAYIPSIZ; bozuk satır → null karantina).
/// Gerçek Supabase ağı + Realtime = manuel/integration checklist.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/features/account/data/bytea_codec.dart';
import 'package:project_auth/features/vault/data/supabase_token_repository.dart';
import 'package:project_auth/features/vault/domain/raw_token_record.dart';

EncryptedBlob _blob(int seed) => EncryptedBlob(
      nonce: Uint8List.fromList(
          List.generate(EncryptedBlob.nonceBytes, (i) => (i + seed) & 0xff)),
      ciphertext: Uint8List.fromList(
          List.generate(48, (i) => (i * 7 + seed) & 0xff)),
    );

RawTokenRecord _rec(String id, {bool deleted = false}) => RawTokenRecord(
      id: id,
      blob: _blob(5),
      updatedAtMs: 1000,
      version: 1,
      deleted: deleted,
    );

void main() {
  group('toRow', () {
    test('6 kolon; updated_at/created_at/user_id-secret GÖNDERİLMEZ', () {
      final row = SupabaseTokenRepository.toRow('uid-A', _rec('t1'));
      expect(row.keys, containsAll(<String>{
        'id',
        'user_id',
        'ciphertext',
        'nonce',
        'version',
        'deleted',
      }));
      expect(row.containsKey('updated_at'), isFalse);
      expect(row.containsKey('created_at'), isFalse);
      // bytea \x+hex formatı.
      expect(row['ciphertext'], startsWith(r'\x'));
      expect(row['nonce'], startsWith(r'\x'));
    });

    test('deleted bayrağı taşınır (tombstone push)', () {
      final row = SupabaseTokenRepository.toRow('uid-A', _rec('t1', deleted: true));
      expect(row['deleted'], isTrue);
    });
  });

  group('tryParseRow', () {
    test('round-trip KAYIPSIZ (toRow → satır → tryParseRow)', () {
      final rec = _rec('t1');
      final row = SupabaseTokenRepository.toRow('uid-A', rec);
      // Sunucu döndürürken updated_at ekler.
      row['updated_at'] = '2026-06-09T10:00:00Z';
      final parsed = SupabaseTokenRepository.tryParseRow(row)!;
      expect(parsed.id, 't1');
      expect(parsed.version, 1);
      expect(parsed.deleted, isFalse);
      expect(parsed.serverUpdatedAtIso, '2026-06-09T10:00:00.000Z');
      // blob birebir.
      expect(parsed.blob.ciphertext, rec.blob.ciphertext);
      expect(parsed.blob.nonce, rec.blob.nonce);
    });

    test('bozuk bytea (geçersiz hex) → null (karantina)', () {
      final parsed = SupabaseTokenRepository.tryParseRow({
        'id': 'bad',
        'ciphertext': r'\xZZZZ', // geçersiz hex
        'nonce': ByteaCodec.encode(Uint8List(24)),
        'version': 1,
        'deleted': false,
        'updated_at': '2026-06-09T10:00:00Z',
      });
      expect(parsed, isNull);
    });

    test('nonce uzunluğu yanlış → null (EncryptedBlob reddi)', () {
      final parsed = SupabaseTokenRepository.tryParseRow({
        'id': 'bad',
        'ciphertext': ByteaCodec.encode(Uint8List(16)),
        'nonce': ByteaCodec.encode(Uint8List(8)), // 24 olmalı
        'version': 1,
        'deleted': false,
        'updated_at': '2026-06-09T10:00:00Z',
      });
      expect(parsed, isNull);
    });

    test('eksik updated_at → null', () {
      final parsed = SupabaseTokenRepository.tryParseRow({
        'id': 'x',
        'ciphertext': ByteaCodec.encode(Uint8List(16)),
        'nonce': ByteaCodec.encode(Uint8List(24)),
        'version': 1,
        'deleted': false,
        // updated_at YOK
      });
      expect(parsed, isNull);
    });

    test('id String değil → null', () {
      final parsed = SupabaseTokenRepository.tryParseRow({
        'id': 123,
        'ciphertext': ByteaCodec.encode(Uint8List(16)),
        'nonce': ByteaCodec.encode(Uint8List(24)),
        'version': 1,
        'deleted': false,
        'updated_at': '2026-06-09T10:00:00Z',
      });
      expect(parsed, isNull);
    });
  });
}
