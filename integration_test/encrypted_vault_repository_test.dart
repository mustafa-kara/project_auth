/// EncryptedVaultRepository + VaultMigration integration testleri
/// (cihaz/simülatör — gerçek libsodium AEAD).
///
/// `flutter test integration_test/encrypted_vault_repository_test.dart -d <device>`
///
/// In-memory FlutterSecureStorage fake ile (gerçek Keychain'e dokunmaz) ama
/// gerçek CryptoService ile şifreleme/çözme kanıtlanır.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/crypto/key_handle.dart';
import 'package:project_auth/core/crypto/sodium_crypto_service.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/data/encrypted_vault_repository.dart';
import 'package:project_auth/features/vault/data/vault_migration.dart';

/// Bellek-içi FlutterSecureStorage (gerçek Keychain'e dokunmaz).
class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async =>
      data[key];

  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    data.remove(key);
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeSecureStorage: ${invocation.memberName}');
}

const _encKey = 'vault_encrypted_v1';
const _plainKey = 'vault_accounts_v1';
const _markerKey = 'vault_migration_v1';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SodiumCryptoService crypto;
  late KeyHandle masterKey;

  setUpAll(() async {
    crypto = SodiumCryptoService();
    await crypto.init();
    masterKey = crypto.generateMasterKey();
  });

  tearDownAll(() => masterKey.dispose());

  OtpAccount acc(String name,
          {OtpType type = OtpType.totp, int counter = 0, String? issuer}) =>
      OtpAccount(
          secret: 'JBSWY3DPEHPK3PXP',
          type: type,
          accountName: name,
          issuer: issuer,
          // Steam token'ı sabit 5 hane ister (OtpAccount.validate).
          digits: type == OtpType.steam ? 5 : 6,
          counter: counter);

  EncryptedVaultRepository repo(FakeSecureStorage s) =>
      EncryptedVaultRepository(masterKey: masterKey, crypto: crypto, storage: s);

  group('encrypted save → load', () {
    test('round-trip: tüm alanlar (Steam, HOTP counter) korunur', () async {
      final s = FakeSecureStorage();
      final r = repo(s);
      final accounts = [
        acc('totp', issuer: 'GitHub'),
        acc('steam', type: OtpType.steam),
        acc('hotp', type: OtpType.hotp, counter: 7),
      ];
      await r.save(accounts);

      final r2 = repo(s); // taze repo → bellek-içi cache yok, diskten oku
      final loaded = await r2.load();
      expect(loaded.corruptedCount, 0);
      expect(loaded.accounts.length, 3);
      final hotp = loaded.accounts.firstWhere((a) => a.accountName == 'hotp');
      expect(hotp.counter, 7);
      expect(hotp.type, OtpType.hotp);
    });

    test('raw storage güvenlik: secret/issuer/accountName plaintext geçmez',
        () async {
      final s = FakeSecureStorage();
      await repo(s).save([acc('octocat', issuer: 'GitHub')]);
      final raw = s.data[_encKey]!;
      expect(raw.contains('JBSWY3DPEHPK3PXP'), isFalse, reason: 'secret sızdı');
      expect(raw.contains('GitHub'), isFalse, reason: 'issuer sızdı');
      expect(raw.contains('octocat'), isFalse, reason: 'accountName sızdı');
      // id açık (AAD için gerekli) ama secret değil — kayıt id'si JSON'da olabilir.
    });
  });

  group('unchanged-blob koruması', () {
    test('aynı içerikle iki save → değişmeyen kayıt yeniden şifrelenmez', () async {
      final s = FakeSecureStorage();
      final r = repo(s);
      final a = acc('sabit');
      final b = acc('degisecek', type: OtpType.hotp, counter: 1);
      await r.save([a, b]);
      final raw1 = jsonDecode(s.data[_encKey]!) as List;
      final aRec1 = raw1.firstWhere((e) => e['id'] == a.id);

      // b'yi değiştir, a aynı kalsın
      final b2 = b.copyWith(counter: 2);
      await r.save([a, b2]);
      final raw2 = jsonDecode(s.data[_encKey]!) as List;
      final aRec2 = raw2.firstWhere((e) => e['id'] == a.id);
      final bRec1 = raw1.firstWhere((e) => e['id'] == b.id);
      final bRec2 = raw2.firstWhere((e) => e['id'] == b.id);

      // a: nonce + ciphertext AYNI (yeniden şifrelenmedi)
      expect(aRec2['n'], aRec1['n']);
      expect(aRec2['c'], aRec1['c']);
      // b: nonce DEĞİŞTİ (yeni şifreleme)
      expect(bRec2['n'], isNot(bRec1['n']));
    });
  });

  group('bozuk kayıt davranışı', () {
    /// Sağlam kayıtlar + sona elle bozuk bir record enjekte eder.
    Future<FakeSecureStorage> withCorrupted(List<OtpAccount> good) async {
      final s = FakeSecureStorage();
      await repo(s).save(good);
      final list = jsonDecode(s.data[_encKey]!) as List;
      list.add({
        'id': 'corrupt-1',
        'v': 1,
        'n': base64Encode(List.filled(24, 0)),
        'c': base64Encode(List.filled(32, 255)), // geçerli uzunluk ama çözülemez
        'updatedAt': 0,
        'deleted': false,
      });
      s.data[_encKey] = jsonEncode(list);
      return s;
    }

    test('bozuk tek record atlanır + corruptedCount==1, diğerleri yüklenir',
        () async {
      final s = await withCorrupted([acc('a'), acc('b')]);
      final loaded = await repo(s).load();
      expect(loaded.accounts.length, 2);
      expect(loaded.corruptedCount, 1);
    });

    test('bozuk kayıt korunur: yeni token eklense bile silinmez', () async {
      final s = await withCorrupted([acc('a'), acc('b')]);
      final r = repo(s);
      await r.load(); // bozuk raw belleğe alınır
      await r.save([acc('a'), acc('b'), acc('c')]); // kullanıcı yeni ekledi

      final list = jsonDecode(s.data[_encKey]!) as List;
      expect(list.any((e) => e['id'] == 'corrupt-1'), isTrue,
          reason: 'bozuk raw silinmemeli');
      expect(list.length, 4); // 3 sağlam + 1 bozuk
    });

    test('purgeCorrupted: bozuk silinir, sağlam+unchanged blob korunur', () async {
      final s = await withCorrupted([acc('a'), acc('b')]);
      final r = repo(s);
      final before = await r.load();
      expect(before.corruptedCount, 1);
      final listBefore = jsonDecode(s.data[_encKey]!) as List;
      final aBefore = listBefore.firstWhere((e) => e['id'] == before.accounts[0].id);

      await r.purgeCorrupted();

      final listAfter = jsonDecode(s.data[_encKey]!) as List;
      expect(listAfter.any((e) => e['id'] == 'corrupt-1'), isFalse,
          reason: 'bozuk silinmeli');
      expect(listAfter.length, 2);
      final aAfter = listAfter.firstWhere((e) => e['id'] == before.accounts[0].id);
      // sağlam kaydın blob'u DEĞİŞMEDİ (yeniden şifrelenmedi)
      expect(aAfter['c'], aBefore['c']);
      expect(aAfter['n'], aBefore['n']);

      // purge sonrası tekrar load → temiz
      final after = await repo(s).load();
      expect(after.corruptedCount, 0);
      expect(after.accounts.length, 2);
    });

    test('bozuk yokken purgeCorrupted → no-op', () async {
      final s = FakeSecureStorage();
      final r = repo(s);
      await r.save([acc('a')]);
      await r.load();
      final raw1 = s.data[_encKey];
      await r.purgeCorrupted();
      expect(s.data[_encKey], raw1); // dokunulmadı
    });

    test('non-map bozuk kayıt (scalar/null) korunur, save TypeError atmaz',
        () async {
      // review P2-1: map olmayan bozuk item save'de cast hatası vermemeli.
      final s = FakeSecureStorage();
      await repo(s).save([acc('a'), acc('b')]);
      final list = jsonDecode(s.data[_encKey]!) as List;
      list..add('bad-record-string')..add(42)..add(null);
      s.data[_encKey] = jsonEncode(list);

      final r = repo(s);
      final loaded = await r.load();
      expect(loaded.accounts.length, 2);
      expect(loaded.corruptedCount, 3); // string + sayı + null

      // Kullanıcı yeni token ekler → save TypeError atmamalı, scalar'lar korunmalı
      await r.save([acc('a'), acc('b'), acc('c')]);
      final after = jsonDecode(s.data[_encKey]!) as List;
      expect(after.contains('bad-record-string'), isTrue);
      expect(after.contains(42), isTrue);
      expect(after.contains(null), isTrue);
      expect(after.length, 6); // 3 sağlam + 3 bozuk scalar

      // purgeCorrupted → scalar'lar temizlenir, sağlamlar kalır
      await r.purgeCorrupted();
      final purged = jsonDecode(s.data[_encKey]!) as List;
      expect(purged.contains('bad-record-string'), isFalse);
      expect(purged.length, 3);
    });
  });

  group('bütünlük (sessiz veri kaybı yok)', () {
    test('top-level malformed JSON → VaultIntegrityException', () async {
      final s = FakeSecureStorage();
      s.data[_encKey] = 'bu json degil {{{';
      await expectLater(
          repo(s).load(), throwsA(isA<VaultIntegrityException>()));
    });

    test('top-level non-list → VaultIntegrityException', () async {
      final s = FakeSecureStorage();
      s.data[_encKey] = jsonEncode({'not': 'a list'});
      await expectLater(
          repo(s).load(), throwsA(isA<VaultIntegrityException>()));
    });

    test('tüm kayıtlar decrypt fail (yanlış masterKey) → VaultIntegrityException',
        () async {
      final s = FakeSecureStorage();
      await repo(s).save([acc('a'), acc('b')]);
      // farklı masterKey ile aç
      final wrongKey = crypto.generateMasterKey();
      final wrongRepo = EncryptedVaultRepository(
          masterKey: wrongKey, crypto: crypto, storage: s);
      await expectLater(
          wrongRepo.load(), throwsA(isA<VaultIntegrityException>()));
      wrongKey.dispose();
    });

    test('boş depo → boş sonuç (integrity DEĞİL)', () async {
      final s = FakeSecureStorage();
      final loaded = await repo(s).load();
      expect(loaded.accounts, isEmpty);
      expect(loaded.corruptedCount, 0);
    });
  });

  group('migration (Faz 1 plaintext → şifreli)', () {
    VaultMigration migration(FakeSecureStorage s) =>
        VaultMigration(crypto: crypto, storage: s);

    Future<void> seedPlaintext(FakeSecureStorage s, List<OtpAccount> accounts) async {
      s.data[_plainKey] = jsonEncode([for (final a in accounts) a.toJson()]);
    }

    test('plaintext → encrypted; plaintext silinir; marker committed; secret yok',
        () async {
      final s = FakeSecureStorage();
      await seedPlaintext(s, [acc('a', issuer: 'GitHub'), acc('b')]);

      await migration(s).migrateIfNeeded(masterKey: masterKey);

      expect(s.data[_plainKey], isNull, reason: 'plaintext silinmeli');
      expect(s.data[_markerKey], 'committed');
      expect(s.data[_encKey], isNotNull);
      expect(s.data[_encKey]!.contains('JBSWY3DPEHPK3PXP'), isFalse);
      expect(s.data[_encKey]!.contains('GitHub'), isFalse);

      final loaded = await repo(s).load();
      expect(loaded.accounts.length, 2);
    });

    test('marker committed iken plaintext\'e dokunmaz (no-op)', () async {
      final s = FakeSecureStorage();
      s.data[_markerKey] = 'committed';
      await seedPlaintext(s, [acc('eski')]);
      await migration(s).migrateIfNeeded(masterKey: masterKey);
      // committed → plaintext olduğu gibi kalır, encrypted yazılmaz
      expect(s.data[_plainKey], isNotNull);
      expect(s.data[_encKey], isNull);
    });

    test('plaintext yok → marker committed, no-op', () async {
      final s = FakeSecureStorage();
      await migration(s).migrateIfNeeded(masterKey: masterKey);
      expect(s.data[_markerKey], 'committed');
      expect(s.data[_encKey], isNull);
    });

    test('crash idempotency: encrypted yazıldı + plaintext duruyor + marker yok → tekrar çalışır, duplicate yok',
        () async {
      final s = FakeSecureStorage();
      await seedPlaintext(s, [acc('a'), acc('b')]);
      // İlk migration encrypted'i yazdı ama (crash simülasyonu) plaintext+marker
      // henüz yok varsayalım: önce normal migrate, sonra marker+plaintext'i geri koy.
      final accounts = [acc('a'), acc('b')];
      await seedPlaintext(s, accounts);
      // encrypted'i elle yaz (ilk yarım migration)
      await repo(s).save(accounts);
      s.data.remove(_markerKey); // marker yazılmadan crash
      // plaintext hâlâ duruyor (silinmeden crash)

      // İkinci açılış: migration tekrar çalışmalı, duplicate üretmemeli
      await migration(s).migrateIfNeeded(masterKey: masterKey);
      expect(s.data[_markerKey], 'committed');
      expect(s.data[_plainKey], isNull);
      final loaded = await repo(s).load();
      // id-bazlı upsert → her id tek kayıt (duplicate yok)
      final ids = loaded.accounts.map((a) => a.id).toSet();
      expect(ids.length, loaded.accounts.length);
      expect(loaded.accounts.length, 2);
    });

    test('upsert: encrypted\'te FARKLI kayıt varken migration onu EZMEZ (merge)',
        () async {
      // review P2-2: save() replace semantiği; migration önce load edip
      // birleştirmezse var olan şifreli kaydı siler.
      final s = FakeSecureStorage();
      // Yarım migration: encrypted'te zaten 'x' var (plaintext'te yok)
      final preExisting = acc('x', issuer: 'PreExisting');
      await repo(s).save([preExisting]);
      // Plaintext'te 'a' + 'b' bekliyor (marker yok)
      await seedPlaintext(s, [acc('a'), acc('b')]);

      await migration(s).migrateIfNeeded(masterKey: masterKey);

      final loaded = await repo(s).load();
      final names = loaded.accounts.map((a) => a.accountName).toSet();
      // 'x' EZİLMEDİ + 'a','b' eklendi
      expect(names, {'x', 'a', 'b'});
      expect(s.data[_markerKey], 'committed');
      expect(s.data[_plainKey], isNull);
    });

    test('upsert: çakışan id → mevcut şifreli kayıt korunur (duplicate yok)',
        () async {
      final s = FakeSecureStorage();
      final shared = acc('shared', issuer: 'Encrypted');
      await repo(s).save([shared]); // encrypted'te shared.id var
      // Plaintext aynı id'yi (farklı issuer) + yeni 'b' içeriyor
      final plaintextShared = shared.copyWith(issuer: 'Plaintext');
      await seedPlaintext(s, [plaintextShared, acc('b')]);

      await migration(s).migrateIfNeeded(masterKey: masterKey);

      final loaded = await repo(s).load();
      final ids = loaded.accounts.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate yok');
      // çakışan id'de MEVCUT şifreli kazanır (issuer Encrypted)
      final sharedLoaded = loaded.accounts.firstWhere((a) => a.id == shared.id);
      expect(sharedLoaded.issuer, 'Encrypted');
      expect(loaded.accounts.length, 2); // shared + b
    });
  });
}
