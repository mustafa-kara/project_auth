/// Faz 3 Patch 3 — EncryptedVaultRepository'nin RawTokenStore yüzü + merge testleri.
///
/// Decrypt edilmemiş ham port: exportRaw / importRemote(LWW) / markDeleted (tombstone).
/// Gerçek libsodium yerine round-trip yapan paylaşılan `FakeCrypto`
/// (`test/support/fake_crypto.dart`) kullanılır (host VM'de plugin yok).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/data/encrypted_vault_repository.dart';
import 'package:project_auth/features/vault/domain/remote_token_repository.dart';

import '../../support/fake_crypto.dart';

// --- Fakes ---

class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read(
          {required String key,
          dynamic iOptions,
          dynamic aOptions,
          dynamic lOptions,
          dynamic webOptions,
          dynamic mOptions,
          dynamic wOptions}) async =>
      data[key];
  @override
  Future<void> write(
      {required String key,
      required String? value,
      dynamic iOptions,
      dynamic aOptions,
      dynamic lOptions,
      dynamic webOptions,
      dynamic mOptions,
      dynamic wOptions}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete(
      {required String key,
      dynamic iOptions,
      dynamic aOptions,
      dynamic lOptions,
      dynamic webOptions,
      dynamic mOptions,
      dynamic wOptions}) async {
    data.remove(key);
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

EncryptedVaultRepository _repo(FakeSecureStorage storage) =>
    EncryptedVaultRepository(
      masterKey: FakeKeyHandle(),
      crypto: FakeCrypto(),
      storage: storage,
    );

OtpAccount _acc(String name) =>
    OtpAccount(secret: 'JBSWY3DPEHPK3PXP', type: OtpType.totp, accountName: name);

RemoteTokenRow _row(String id, {required String iso, bool deleted = false}) =>
    RemoteTokenRow(
      id: id,
      blob: EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16)),
      version: 1,
      serverUpdatedAt: DateTime.parse(iso),
      deleted: deleted,
    );

void main() {
  group('RawTokenStore — markDeleted + tombstone', () {
    test('markDeleted → tombstone diskte, load() accounts dışı, exportRaw deleted=true',
        () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      await repo.save([_acc('a'), _acc('b')]);
      final ids = (await repo.exportRaw()).map((r) => r.id).toList();
      expect(ids.length, 2);

      final targetId = (await repo.load()).accounts.first.id;
      await repo.markDeleted(targetId);

      final after = await repo.load();
      expect(after.accounts.any((a) => a.id == targetId), isFalse,
          reason: 'tombstone load() accounts\'ta görünmez');
      expect(after.accounts.length, 1);

      final raw = await repo.exportRaw();
      final tomb = raw.firstWhere((r) => r.id == targetId);
      expect(tomb.deleted, isTrue);
      expect(tomb.isDirty, isTrue, reason: 'tombstone sv=null → push edilecek');
      // Tombstone GEÇERLİ blob taşır (24B nonce / >=16B ct).
      expect(tomb.blob.nonce.length, 24);
    });

    test('markDeleted sonrası save() tombstone\'u diriltmez', () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      await repo.save([_acc('a'), _acc('b')]);
      final delId = (await repo.load()).accounts.first.id;
      await repo.markDeleted(delId);

      // Kullanıcı başka token ekler → save (tombstone korunmalı).
      final survivors = (await repo.load()).accounts;
      await repo.save([...survivors, _acc('c')]);

      final raw = await repo.exportRaw();
      expect(raw.firstWhere((r) => r.id == delId).deleted, isTrue,
          reason: 'tombstone save() sonrası hayatta');
    });
  });

  // --- Denetim A1: tombstone diriltme (id koruyan yedek geri yüklemesi) ---
  group('A1 — canlı kayıt kendi tombstone\'unu düşürür', () {
    test('sil → yedekten AYNI id ile geri yükle → TEK kayıt, deleted=false',
        () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      await repo.save([_acc('a'), _acc('b')]);

      final restored = (await repo.load()).accounts.first;
      await repo.markDeleted(restored.id);
      expect((await repo.exportRaw()).firstWhere((r) => r.id == restored.id).deleted,
          isTrue);

      // Yedek geri yükleme: AYNI id ile canlı kayıt tekrar yazılır.
      final survivors = (await repo.load()).accounts;
      await repo.save([...survivors, restored]);

      final raw = await repo.exportRaw();
      expect(raw.where((r) => r.id == restored.id), hasLength(1),
          reason: 'canlı + tombstone AYNI id ile diske yazılamaz — '
              'push onConflict:id ile 21000 verirdi');
      expect(raw.firstWhere((r) => r.id == restored.id).deleted, isFalse,
          reason: 'bilinçli diriltme: canlı kazanır');
      expect(raw.firstWhere((r) => r.id == restored.id).isDirty, isTrue,
          reason: 'sv=null → push sunucuyu deleted=false yapar');
      expect((await repo.load()).accounts.map((a) => a.id), contains(restored.id));
    });

    test('diskte canlı + tombstone (aynı id) → load canlıyı seçer, '
        'importRemote diski ONARIR', () async {
      final storage = FakeSecureStorage();
      final account = _acc('resurrected');
      final blob = FakeCrypto().encrypt(
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(account.toJson()))),
        key: FakeKeyHandle(),
        aad: Uint8List.fromList('token|1|${account.id}'.codeUnits),
      );
      final record = {
        'id': account.id,
        'v': 1,
        'n': base64Encode(blob.nonce),
        'c': base64Encode(blob.ciphertext),
        'updatedAt': 5,
        'deleted': false,
      };
      // Tombstone ÖNCE yazılır → canlı kayıt sonradan görülse bile kazanmalı.
      storage.data['vault_encrypted_v1'] = jsonEncode([
        {...record, 'deleted': true, 'updatedAt': 9},
        record,
      ]);

      final repo = _repo(storage);
      final loaded = await repo.load();
      expect(loaded.accounts.map((a) => a.id), [account.id],
          reason: 'canlı kayıt tombstone\'a rağmen gösterilir');
      expect(loaded.corruptedCount, 0);

      // Boş pull bile diski onarır (mükerrer id bir sonraki push\'a taşınmaz).
      final outcome = await repo.importRemote(const [], pullCursorIso: null);
      expect(outcome.changed, isTrue);
      expect(outcome.appliedCount, 0);
      final raw = await repo.exportRaw();
      expect(raw, hasLength(1));
      expect(raw.single.deleted, isFalse);
    });
  });

  group('importRemote — LWW merge', () {
    test('remote-only → kabul (yeni cihaz restore)', () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      final out = await repo.importRemote(
        [_row('x', iso: '2026-06-09T10:00:00Z')],
        pullCursorIso: null,
      );
      expect(out.changed, isTrue);
      expect(out.appliedCount, 1);
      final raw = await repo.exportRaw();
      expect(raw.single.id, 'x');
      expect(raw.single.serverUpdatedAtIso, isNotNull);
    });

    test('sv\'li lokal + daha yeni server → server kazanır', () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      // Önce server'dan x'i al (sv set olur).
      await repo.importRemote([_row('x', iso: '2026-06-09T10:00:00Z')],
          pullCursorIso: null);
      // Daha yeni server sürümü gelir.
      final out = await repo.importRemote(
          [_row('x', iso: '2026-06-09T11:00:00Z')],
          pullCursorIso: '2026-06-09T10:00:00Z');
      expect(out.changed, isTrue);
      final raw = await repo.exportRaw();
      expect(raw.single.serverUpdatedAtIso, '2026-06-09T11:00:00.000Z');
    });

    test('sv\'li lokal + STALE server → no-op (idempotent)', () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      await repo.importRemote([_row('x', iso: '2026-06-09T11:00:00Z')],
          pullCursorIso: null);
      // Eski sürüm tekrar gelir (stale/duplicate pull).
      final out = await repo.importRemote(
          [_row('x', iso: '2026-06-09T10:00:00Z')],
          pullCursorIso: '2026-06-09T11:00:00Z');
      expect(out.changed, isFalse, reason: 'idempotent: zaten yeni sürümdeyiz');
    });

    test('lokal dirty + cursor-SONRASI server değişikliği → server kazanır',
        () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      await repo.save([_acc('a')]); // lokal dirty (sv=null)
      final id = (await repo.load()).accounts.single.id;
      // Başka cihaz aynı id'yi cursor'dan SONRA değiştirmiş.
      final out = await repo.importRemote(
          [_row(id, iso: '2026-06-09T12:00:00Z')],
          pullCursorIso: '2026-06-09T11:00:00Z');
      expect(out.changed, isTrue, reason: 'cursor-sonrası → başka cihaz kazanır');
    });

    test('lokal dirty + cursor-ÖNCESİ server (kendi echo) → local korunur',
        () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      await repo.save([_acc('a')]); // dirty
      final id = (await repo.load()).accounts.single.id;
      final out = await repo.importRemote(
          [_row(id, iso: '2026-06-09T09:00:00Z')],
          pullCursorIso: '2026-06-09T11:00:00Z');
      expect(out.changed, isFalse, reason: 'echo → lokal push beklemede, korunur');
      final raw = await repo.exportRaw();
      expect(raw.single.isDirty, isTrue);
    });

    test('remote deleted=true daha yeni → lokal canlı tombstone olur', () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      await repo.importRemote([_row('x', iso: '2026-06-09T10:00:00Z')],
          pullCursorIso: null);
      final out = await repo.importRemote(
          [_row('x', iso: '2026-06-09T11:00:00Z', deleted: true)],
          pullCursorIso: '2026-06-09T10:00:00Z');
      expect(out.changed, isTrue);
      final raw = await repo.exportRaw();
      expect(raw.single.deleted, isTrue, reason: 'delete LWW ile kazandı');
    });

    test('çift pull (aynı row 2x) → tek sonuç, ikincisi no-op (idempotent)',
        () async {
      final storage = FakeSecureStorage();
      final repo = _repo(storage);
      await repo.load();
      final r = _row('x', iso: '2026-06-09T10:00:00Z');
      final out1 = await repo.importRemote([r], pullCursorIso: null);
      expect(out1.changed, isTrue);
      final out2 = await repo.importRemote([r], pullCursorIso: '2026-06-09T10:00:00Z');
      expect(out2.changed, isFalse);
      expect((await repo.exportRaw()).length, 1);
    });

    test('import sonrası reload → remote token decrypt edilebilir (aynı masterKey)',
        () async {
      final storage = FakeSecureStorage();
      // Cihaz A: token üretip ham blob'unu "sunucuya" taşı.
      final repoA = _repo(storage);
      await repoA.load();
      await repoA.save([_acc('shared')]);
      final rawA = (await repoA.exportRaw()).single;

      // Cihaz B: temiz storage, aynı (fake) masterKey. A'nın blob'unu import et.
      final storageB = FakeSecureStorage();
      final repoB = _repo(storageB);
      await repoB.load();
      await repoB.importRemote([
        RemoteTokenRow(
          id: rawA.id,
          blob: rawA.blob,
          version: rawA.version,
          serverUpdatedAt: DateTime.parse('2026-06-09T10:00:00Z'),
          deleted: false,
        )
      ], pullCursorIso: null);
      // reload → decrypt çalışır (FakeCrypto AAD token|1|<id> eşleşir).
      final loaded = await repoB.load();
      expect(loaded.accounts.single.accountName, 'shared');
    });
  });

  test('sv geriye-uyum: eski (sv\'siz) kayıt parse edilir', () async {
    final storage = FakeSecureStorage();
    // Elle eski-format kayıt yaz (sv alanı YOK).
    final blob = FakeCrypto()
        .encrypt(
            plaintext: Uint8List.fromList(utf8.encode(jsonEncode(_acc('old').toJson()))),
            key: FakeKeyHandle(),
            aad: Uint8List.fromList('token|1|oldid'.codeUnits))
        ;
    storage.data['vault_encrypted_v1'] = jsonEncode([
      {
        'id': 'oldid',
        'v': 1,
        'n': base64Encode(blob.nonce),
        'c': base64Encode(blob.ciphertext),
        'updatedAt': 123,
        'deleted': false,
        // 'sv' YOK
      }
    ]);
    final repo = _repo(storage);
    final raw = await repo.exportRaw();
    expect(raw.single.serverUpdatedAtIso, isNull);
    expect(raw.single.isDirty, isTrue);
  });
}
