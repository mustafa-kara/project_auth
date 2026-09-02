/// Faz 5 Patch 3 — `VaultCubit.editMetadata` / `renameTag` / `deleteTag` /
/// `allTags`.
///
/// Bu testlerin ASIL konusu davranış değil, MALİYET: her metot `addAll`
/// kalıbını izler (tek `_emitAndPersist` + tek `_pushAfterMutation`) ve
/// değişiklik yoksa NE yazar NE push eder (risk R4). Bir etiketi yeniden
/// adlandırmak vault'taki her token'a dokunabilir; kayıt başına bir save +
/// bir push, N token için N şifreleme ve N sync turu demek olurdu.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/domain/catalog_repository.dart';
import 'package:project_auth/features/vault/domain/issuer_catalog.dart';
import 'package:project_auth/features/vault/domain/token_sync_service.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

class _FakeRepo implements VaultRepository {
  List<OtpAccount> stored;
  int saveCount = 0;

  /// true ise `save()` fırlatır (hata yolu testi).
  bool failSave = false;

  _FakeRepo([this.stored = const []]);

  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(stored));

  @override
  Future<void> save(List<OtpAccount> accounts) async {
    if (failSave) throw Exception('disk dolu');
    saveCount++;
    stored = List.of(accounts);
  }

  @override
  Future<void> purgeCorrupted() async {}
}

/// Yalnız `pushChanged` sayımı için — `start`/`dispose` no-op, başka hiçbir
/// sync davranışı yok. "Tek push" iddiası bu sayaçla ölçülür.
class _CountingSync implements TokenSyncService {
  int pushCount = 0;

  @override
  Future<void> pushChanged() async => pushCount++;

  @override
  Future<void> start({required bool live}) async {}

  @override
  Future<void> dispose() async {}

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

OtpAccount _acc(
  String id, {
  String? issuer,
  String name = 'me@example.com',
  List<String> tags = const [],
}) => OtpAccount(
  id: id,
  secret: 'JBSWY3DPEHPK3PXP',
  type: OtpType.totp,
  issuer: issuer,
  accountName: name,
  tags: tags,
);

List<String> _tagsOf(VaultCubit c, String id) =>
    c.state.accounts.firstWhere((a) => a.id == id).tags;

void main() {
  late _FakeRepo repo;
  late _CountingSync sync;

  VaultCubit build(List<OtpAccount> seed, {IssuerCatalog? catalog}) {
    repo = _FakeRepo(seed);
    sync = _CountingSync();
    return VaultCubit(
      repo,
      sync: sync,
      issuerCatalogResolver: catalog == null ? null : () => catalog,
    );
  }

  group('editMetadata', () {
    test('tek save + tek push ile issuer/hesap/etiket günceller', () async {
      final cubit = build([_acc('t1', issuer: 'GitHub')]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.editMetadata(
        id: 't1',
        issuer: 'GitHub Inc',
        accountName: 'yeni@example.com',
        tags: ['iş', 'ev'],
      );

      expect(repo.saveCount, 1);
      expect(sync.pushCount, 1);
      final stored = repo.stored.single;
      expect(stored.issuer, 'GitHub Inc');
      expect(stored.accountName, 'yeni@example.com');
      expect(stored.tags, ['iş', 'ev']);
      // Kimlik ve secret ASLA parametre değil → dokunulmadan kalır.
      expect(stored.id, 't1');
      expect(stored.secret, 'JBSWY3DPEHPK3PXP');
      expect(cubit.state.accounts.single, stored);
    });

    test('null argüman ilgili alanı DEĞİŞTİRMEZ', () async {
      final cubit = build([
        _acc('t1', issuer: 'GitHub', tags: ['iş']),
      ]);
      await cubit.load();

      await cubit.editMetadata(id: 't1', accountName: 'yeni@example.com');

      expect(repo.stored.single.issuer, 'GitHub');
      expect(repo.stored.single.tags, ['iş']);
    });

    test('tags: const [] etiketleri TEMİZLER', () async {
      final cubit = build([
        _acc('t1', tags: ['iş', 'ev']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.editMetadata(id: 't1', tags: const []);

      expect(repo.saveCount, 1);
      expect(repo.stored.single.tags, isEmpty);
      // K2: temizlenince "tags" anahtarı JSON'dan tamamen çıkar.
      expect(repo.stored.single.toJson().containsKey('tags'), isFalse);
    });

    test('etiketler normalize edilir (kırpma/tekilleştirme/tavan)', () async {
      final cubit = build([_acc('t1')]);
      await cubit.load();

      await cubit.editMetadata(
        id: 't1',
        tags: ['  iş ', 'iş', '', 'ev', 'g' * 40],
      );

      expect(repo.stored.single.tags, [
        'iş',
        'ev',
        'g' * OtpAccount.maxTagRunes,
      ]);
    });

    test('issuer `add` ile AYNI kanonikleştirmeden geçer (A2)', () async {
      final catalog = IssuerCatalog(const [
        CatalogService(
          id: '1',
          name: 'GitHub',
          issuer: 'github',
          logoUrl: null,
        ),
      ]);
      final cubit = build([_acc('t1', issuer: 'MyBank')], catalog: catalog);
      await cubit.load();

      await cubit.editMetadata(id: 't1', issuer: 'github');

      // slug 'github' → katalog kanonik adı 'GitHub'
      expect(repo.stored.single.issuer, 'GitHub');
    });

    test('bilinmeyen id → NE yazma NE push (no-op)', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.editMetadata(id: 'yok', issuer: 'X', tags: ['ev']);

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
      expect(repo.stored.single.tags, ['iş']);
    });

    test(
      'değişiklik yok → NE yazma NE push (normalize sonrası eşit)',
      () async {
        final cubit = build([
          _acc('t1', issuer: 'GitHub', tags: ['iş', 'ev']),
        ]);
        await cubit.load();
        repo.saveCount = 0;

        // Aynı değerler, yalnız kirli yazımla: normalize sonrası birebir aynı.
        await cubit.editMetadata(
          id: 't1',
          issuer: 'GitHub',
          accountName: 'me@example.com',
          tags: ['  iş  ', 'ev', 'iş'],
        );

        expect(repo.saveCount, 0);
        expect(sync.pushCount, 0);
      },
    );

    // Düzenleme sheet'i issuer'ı olmayan bir token için BOŞ "Servis" alanı
    // gösterir ve Kaydet'te o boşluğu `''` olarak geri yollar. `''` bir değer
    // değil, "issuer yok" demektir: aksi hâlde `null != ''` yüzünden hiç
    // dokunulmamış token yeniden şifrelenir, push edilir ve blob'a
    // `"issuer": ""` yazılırdı (review P2).
    test('issuer\'sız token\'a boş issuer → NE yazma NE push', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.editMetadata(
        id: 't1',
        issuer: '',
        accountName: 'me@example.com',
        tags: ['iş'],
      );

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
      expect(repo.stored.single.issuer, isNull);
    });

    test('yalnız boşluktan ibaret issuer da no-op sayılır', () async {
      final cubit = build([_acc('t1')]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.editMetadata(id: 't1', issuer: '   ');

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
    });

    test(
      'boş issuer VAR OLAN issuer\'ı temizler (sonuç null, "" değil)',
      () async {
        final cubit = build([_acc('t1', issuer: 'GitHub')]);
        await cubit.load();
        repo.saveCount = 0;

        await cubit.editMetadata(id: 't1', issuer: '');

        expect(repo.saveCount, 1);
        expect(sync.pushCount, 1);
        final stored = repo.stored.single;
        expect(stored.issuer, isNull);
        // K2 ile aynı kural: temizlenen alan JSON'a HİÇ yazılmaz.
        expect(stored.toJson().containsKey('issuer'), isFalse);
        // Temizleme başka hiçbir alanı düşürmez.
        expect(stored.id, 't1');
        expect(stored.secret, 'JBSWY3DPEHPK3PXP');
        expect(stored.accountName, 'me@example.com');
      },
    );

    test('issuer temizlenirken etiketler ve diğer alanlar korunur', () async {
      final cubit = build([
        _acc('t1', issuer: 'GitHub', tags: ['iş', 'ev']),
      ]);
      await cubit.load();

      await cubit.editMetadata(id: 't1', issuer: '  ');

      expect(repo.stored.single.issuer, isNull);
      expect(repo.stored.single.tags, ['iş', 'ev']);
    });

    test('hiçbir argüman verilmezse de no-op', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.editMetadata(id: 't1');

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
    });

    test('yalnız DİĞER token\'lar etkilenmez', () async {
      final cubit = build([
        _acc('t1', name: 'a@x.com', tags: ['iş']),
        _acc('t2', name: 'b@x.com', tags: ['iş']),
      ]);
      await cubit.load();

      await cubit.editMetadata(id: 't1', tags: ['ev']);

      expect(_tagsOf(cubit, 't1'), ['ev']);
      expect(_tagsOf(cubit, 't2'), ['iş']);
      // Liste sırası korunur (UI reorder yaşamaz).
      expect(cubit.state.accounts.map((a) => a.id), ['t1', 't2']);
    });

    test('bütünlük hatası state\'inde StateError fırlatır', () async {
      final failing = VaultCubit(_ErroringRepo());
      await failing.load();
      expect(failing.state.error, isNotNull);

      // Üçü de aynı `_guardIntegrity` kapısından geçer.
      await expectLater(
        failing.editMetadata(id: 't1', tags: ['iş']),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        failing.renameTag('iş', 'ofis'),
        throwsA(isA<StateError>()),
      );
      await expectLater(failing.deleteTag('iş'), throwsA(isA<StateError>()));
    });

    test('save hatası çağırana FIRLAR (UI SnackBar gösterebilsin)', () async {
      final cubit = build([_acc('t1')]);
      await cubit.load();
      repo.failSave = true;

      await expectLater(
        cubit.editMetadata(id: 't1', tags: ['iş']),
        throwsA(isA<Exception>()),
      );
      // Optimistic: state güncellendi ama disk yazılamadı (mevcut sözleşme).
      expect(_tagsOf(cubit, 't1'), ['iş']);
    });
  });

  group('renameTag', () {
    test('N kayıtta TEK save + TEK push', () async {
      final cubit = build([
        _acc('t1', name: 'a@x.com', tags: ['iş']),
        _acc('t2', name: 'b@x.com', tags: ['ev', 'iş']),
        _acc('t3', name: 'c@x.com', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.renameTag('iş', 'ofis');

      expect(repo.saveCount, 1, reason: 'kayıt başına bir save OLMAMALI');
      expect(sync.pushCount, 1, reason: 'kayıt başına bir push OLMAMALI');
      expect(_tagsOf(cubit, 't1'), ['ofis']);
      expect(_tagsOf(cubit, 't2'), ['ev', 'ofis']);
      expect(_tagsOf(cubit, 't3'), ['ofis']);
    });

    test('çakışma BİRLEŞTİRİR ve eski sırayı korur', () async {
      final cubit = build([
        _acc('t1', name: 'a@x.com', tags: ['ev', 'iş']),
        _acc('t2', name: 'b@x.com', tags: ['iş', 'ev']),
      ]);
      await cubit.load();

      await cubit.renameTag('iş', 'ev');

      // Her iki kayıtta da tek 'ev' kalır; İLK yazım kazandığı için 'ev'in
      // kendi konumu değişmez.
      expect(_tagsOf(cubit, 't1'), ['ev']);
      expect(_tagsOf(cubit, 't2'), ['ev']);
    });

    test('etiketi taşımayan kayıtlar aynen kalır', () async {
      final cubit = build([
        _acc('t1', name: 'a@x.com', tags: ['iş']),
        _acc('t2', name: 'b@x.com', tags: ['ev']),
      ]);
      await cubit.load();

      await cubit.renameTag('iş', 'ofis');

      expect(_tagsOf(cubit, 't2'), ['ev']);
    });

    test('hiçbir kayıt taşımıyorsa → NE yazma NE push', () async {
      final cubit = build([
        _acc('t1', tags: ['ev']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.renameTag('iş', 'ofis');

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
    });

    test('from == to (normalize sonrası) → no-op', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.renameTag('  iş ', 'iş');

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
    });

    test('to boş/boşluk → no-op (etiket SİLİNMEZ)', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.renameTag('iş', '   ');

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
      expect(_tagsOf(cubit, 't1'), ['iş']);
    });

    test('from boş → no-op', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.renameTag('', 'ofis');

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
    });

    test('yeni ad normalize edilir (32 rune kırpma)', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();

      await cubit.renameTag('iş', '  ${'g' * 40}  ');

      expect(_tagsOf(cubit, 't1').single, 'g' * OtpAccount.maxTagRunes);
    });

    test(
      'R9: İ/i AYRI etiketlerdir — yalnız tam eşleşen yeniden adlandırılır',
      () async {
        final cubit = build([
          _acc('t1', name: 'a@x.com', tags: ['İş']),
          _acc('t2', name: 'b@x.com', tags: ['iş']),
        ]);
        await cubit.load();

        await cubit.renameTag('iş', 'ofis');

        expect(_tagsOf(cubit, 't1'), ['İş']);
        expect(_tagsOf(cubit, 't2'), ['ofis']);
      },
    );
  });

  group('deleteTag', () {
    test('N kayıttan kaldırır: TEK save + TEK push, token SİLİNMEZ', () async {
      final cubit = build([
        _acc('t1', name: 'a@x.com', tags: ['iş']),
        _acc('t2', name: 'b@x.com', tags: ['ev', 'iş']),
        _acc('t3', name: 'c@x.com', tags: ['ev']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.deleteTag('iş');

      expect(repo.saveCount, 1);
      expect(sync.pushCount, 1);
      expect(cubit.state.accounts, hasLength(3), reason: 'token silinmemeli');
      expect(_tagsOf(cubit, 't1'), isEmpty);
      expect(_tagsOf(cubit, 't2'), ['ev']);
      expect(_tagsOf(cubit, 't3'), ['ev']);
    });

    test('hiçbir kayıt taşımıyorsa → NE yazma NE push', () async {
      final cubit = build([
        _acc('t1', tags: ['ev']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.deleteTag('iş');

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
    });

    test('boş etiket → no-op', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      await cubit.deleteTag('  ');

      expect(repo.saveCount, 0);
      expect(sync.pushCount, 0);
      expect(_tagsOf(cubit, 't1'), ['iş']);
    });

    test(
      'son etiket kalkınca JSON\'dan "tags" anahtarı da çıkar (K2)',
      () async {
        final cubit = build([
          _acc('t1', tags: ['iş']),
        ]);
        await cubit.load();

        await cubit.deleteTag('iş');

        expect(repo.stored.single.toJson().containsKey('tags'), isFalse);
      },
    );
  });

  group('allTags', () {
    test('kullanım sayısı AZALAN sırada', () async {
      final cubit = build([
        _acc('t1', name: 'a@x.com', tags: ['ev', 'iş']),
        _acc('t2', name: 'b@x.com', tags: ['iş']),
        _acc('t3', name: 'c@x.com', tags: ['iş', 'seyahat']),
      ]);
      await cubit.load();

      expect(cubit.allTags, ['iş', 'ev', 'seyahat']);
    });

    test('eşitlikte case-insensitive alfabetik', () async {
      final cubit = build([
        _acc('t1', name: 'a@x.com', tags: ['Zebra', 'alfa', 'Beta']),
      ]);
      await cubit.load();

      expect(cubit.allTags, ['alfa', 'Beta', 'Zebra']);
    });

    test('etiket yoksa boş, dönen liste DEĞİŞTİRİLEMEZ', () async {
      final cubit = build([_acc('t1')]);
      await cubit.load();

      expect(cubit.allTags, isEmpty);
      expect(() => cubit.allTags.add('x'), throwsUnsupportedError);
    });

    test('mutasyonlardan sonra ANINDA güncellenir (cache yok)', () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      expect(cubit.allTags, ['iş']);

      await cubit.renameTag('iş', 'ofis');
      expect(cubit.allTags, ['ofis']);

      await cubit.deleteTag('ofis');
      expect(cubit.allTags, isEmpty);
    });
  });

  test(
    'etiket mutasyonları add/remove ile SERİLEŞİR (tek yazma kuyruğu)',
    () async {
      final cubit = build([
        _acc('t1', tags: ['iş']),
      ]);
      await cubit.load();
      repo.saveCount = 0;

      // Beklemeden arka arkaya: _opChain sırayı korumalı.
      final ops = <Future<void>>[
        cubit.add(_acc('t2', name: 'b@x.com', tags: ['iş'])),
        cubit.renameTag('iş', 'ofis'),
        cubit.deleteTag('ofis'),
      ];
      await Future.wait(ops);

      expect(repo.stored.map((a) => a.id), ['t1', 't2']);
      expect(repo.stored.every((a) => a.tags.isEmpty), isTrue);
      expect(repo.saveCount, 3);
    },
  );
}

/// `load()`'da patlayan depo — bütünlük hatası state'i kurmak için.
class _ErroringRepo implements VaultRepository {
  @override
  Future<VaultLoadResult> load() async => throw StateError('bozuk');
  @override
  Future<void> save(List<OtpAccount> accounts) async {}
  @override
  Future<void> purgeCorrupted() async {}
}
