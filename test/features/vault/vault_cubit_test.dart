/// VaultCubit testleri — id-bazlı silme/sayaç + kalıcılık (repository) davranışı.
///
/// Index yerine stabil `id` kullanımı, liste değiştiğinde yanlış öğeye
/// dokunulmamasını garanti eder. Ayrıca her mutasyonun repository'e
/// yazıldığı ve açılışta geri yüklendiği doğrulanır (Faz 1 kalıcılık).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

OtpAccount _acc(String name, {OtpType type = OtpType.totp, int counter = 0}) =>
    OtpAccount(
      secret: 'JBSWY3DPEHPK3PXP',
      type: type,
      accountName: name,
      counter: counter,
    );

/// Bellek-içi sahte repository — secure_storage olmadan kalıcılık davranışını test eder.
class _FakeRepo implements VaultRepository {
  List<OtpAccount> stored;
  int saveCount = 0;

  /// load()'ı geciktirmek için (yarış durumu testi). null ise anında döner.
  Completer<void>? loadGate;

  /// true ise save() exception fırlatır (yazma hatası testi).
  bool failSave = false;

  /// load()'ın corruptedCount değeri (banner testi için).
  int corruptedCount = 0;

  /// load()'ın atacağı hata (bütünlük hatası testi için). null ise normal yükler.
  Object? loadError;

  int purgeCount = 0;

  _FakeRepo([this.stored = const []]);

  @override
  Future<VaultLoadResult> load() async {
    // Gerçek depo gibi: okuma çağrı anında snapshot alınır; arada save() olsa
    // bile bu çağrı eski içeriği döndürür (yarış durumunu sadık modeller).
    final snapshot = List.of(stored);
    if (loadGate != null) await loadGate!.future;
    if (loadError != null) throw loadError!;
    return VaultLoadResult(accounts: snapshot, corruptedCount: corruptedCount);
  }

  @override
  Future<void> save(List<OtpAccount> accounts) async {
    if (failSave) throw Exception('disk dolu');
    saveCount++;
    stored = List.of(accounts);
  }

  @override
  Future<void> purgeCorrupted() async {
    purgeCount++;
    corruptedCount = 0;
  }
}

/// Çözülmüş plaintext'i bellekte tutan depo (gerçek [PlaintextCache] gibi) —
/// `wipe()`'ın gerçekten önbelleği bıraktığını gözlemlenebilir kılar.
class _FakeCachingRepo extends _FakeRepo implements PlaintextCache {
  _FakeCachingRepo([super.stored = const []]);

  /// `load()`'ın doldurduğu "çözülmüş kayıt" önbelleği (gerçekte `_lastById`).
  final List<OtpAccount> cache = [];
  int forgetCount = 0;

  @override
  Future<VaultLoadResult> load() async {
    final result = await super.load();
    cache
      ..clear()
      ..addAll(result.accounts);
    return result;
  }

  @override
  void forgetPlaintext() {
    forgetCount++;
    cache.clear();
  }
}

void main() {
  // Güvenlik denetimi P2-1 — plaintext'i anahtarla AYNI anda bırak.
  group('wipe (P2-1)', () {
    test('state\'i boşaltır ve depo önbelleğini bıraktırır', () async {
      final repo = _FakeCachingRepo([_acc('a'), _acc('b')]);
      final cubit = VaultCubit(repo);
      await cubit.load();
      expect(cubit.state.accounts, hasLength(2));
      expect(repo.cache, hasLength(2));

      cubit.wipe();

      expect(cubit.state, const VaultState()); // loaded:false + accounts boş
      expect(cubit.state.accounts, isEmpty);
      expect(repo.forgetCount, 1);
      expect(repo.cache, isEmpty);
    });

    test('SENKRON çalışır (frame/await beklemez)', () async {
      final repo = _FakeCachingRepo([_acc('a')]);
      final cubit = VaultCubit(repo);
      await cubit.load();
      cubit.wipe(); // await YOK
      expect(cubit.state.accounts, isEmpty);
      expect(repo.cache, isEmpty);
    });

    test(
      'PlaintextCache OLMAYAN depoda da state boşalır (no-op cache)',
      () async {
        final cubit = VaultCubit(_FakeRepo([_acc('a')]));
        await cubit.load();
        cubit.wipe();
        expect(cubit.state.accounts, isEmpty);
      },
    );

    test('kapalı cubit\'te emit ETMEZ ama depoyu YİNE unutturur', () async {
      final repo = _FakeCachingRepo([_acc('a')]);
      final cubit = VaultCubit(repo);
      await cubit.load();
      await cubit.close();
      cubit.wipe(); // emit_after_close fırlatmamalı
      expect(repo.forgetCount, 1);
    });

    test('idempotent (çift çağrı güvenli)', () async {
      final repo = _FakeCachingRepo([_acc('a')]);
      final cubit = VaultCubit(repo);
      await cubit.load();
      cubit
        ..wipe()
        ..wipe();
      expect(repo.forgetCount, 2);
      expect(cubit.state.accounts, isEmpty);
    });
  });

  group('VaultCubit', () {
    test('load depodaki token\'ları yükler ve loaded=true yapar', () async {
      final a = _acc('a');
      final cubit = VaultCubit(_FakeRepo([a]));
      expect(cubit.state.loaded, isFalse);
      await cubit.load();
      expect(cubit.state.loaded, isTrue);
      expect(cubit.state.accounts.single.id, a.id);
    });

    test('add token listeye ekler, stabil id atar ve depoya yazar', () async {
      final repo = _FakeRepo();
      final cubit = VaultCubit(repo);
      final a = _acc('a');
      await cubit.add(a);
      expect(cubit.state.accounts.single.id, a.id);
      expect(repo.stored.single.id, a.id); // kalıcı
    });

    test(
      'removeById doğru token\'ı siler (index kaymasından etkilenmez)',
      () async {
        final repo = _FakeRepo();
        final cubit = VaultCubit(repo);
        final a = _acc('a'), b = _acc('b'), c = _acc('c');
        await cubit.add(a);
        await cubit.add(b);
        await cubit.add(c);
        await cubit.removeById(b.id);
        expect(cubit.state.accounts.map((e) => e.id), [a.id, c.id]);
        expect(repo.stored.map((e) => e.id), [a.id, c.id]); // kalıcı
      },
    );

    test('removeById bilinmeyen id\'de state ve depoyu değiştirmez', () async {
      final repo = _FakeRepo();
      final cubit = VaultCubit(repo);
      final a = _acc('a');
      await cubit.add(a);
      final before = cubit.state;
      final savesBefore = repo.saveCount;
      await cubit.removeById('yok-böyle-id');
      expect(cubit.state, same(before));
      expect(repo.saveCount, savesBefore); // gereksiz yazma yok
    });

    test(
      'incrementCounter yalnız hedef HOTP token\'ın sayacını artırır',
      () async {
        final repo = _FakeRepo();
        final cubit = VaultCubit(repo);
        final h1 = _acc('h1', type: OtpType.hotp, counter: 0);
        final h2 = _acc('h2', type: OtpType.hotp, counter: 5);
        await cubit.add(h1);
        await cubit.add(h2);
        await cubit.incrementCounter(h2.id);
        final byId = {for (final a in cubit.state.accounts) a.id: a};
        expect(byId[h1.id]!.counter, 0); // dokunulmadı
        expect(byId[h2.id]!.counter, 6); // hedef arttı
        expect(
          repo.stored.firstWhere((a) => a.id == h2.id).counter,
          6,
        ); // kalıcı
      },
    );

    test('incrementCounter TOTP\'ta no-op (yazma yapmaz)', () async {
      final repo = _FakeRepo();
      final cubit = VaultCubit(repo);
      final t = _acc('t', type: OtpType.totp);
      await cubit.add(t);
      final savesBefore = repo.saveCount;
      await cubit.incrementCounter(t.id);
      expect(cubit.state.accounts.single.counter, 0);
      expect(repo.saveCount, savesBefore); // no-op → yazma yok
    });

    test('save hatası add()\'ten yukarı fırlar (UI yakalayabilsin)', () async {
      final repo = _FakeRepo()..failSave = true;
      final cubit = VaultCubit(repo);
      await expectLater(cubit.add(_acc('a')), throwsException);
      // Bellek-içi state yine de güncel (kullanıcı görür); kalıcılık başarısız.
      expect(cubit.state.accounts.single.accountName, 'a');
    });

    test(
      'save hatası removeById ve incrementCounter\'dan da yukarı fırlar',
      () async {
        final repo = _FakeRepo();
        final cubit = VaultCubit(repo);
        final h = _acc('h', type: OtpType.hotp);
        final t = _acc('t');
        await cubit.add(h);
        await cubit.add(t);
        // Şimdi save'i bozalım; mutasyon hatası yukarı fırlamalı (UI SnackBar göstersin).
        repo.failSave = true;
        await expectLater(cubit.incrementCounter(h.id), throwsException);
        await expectLater(cubit.removeById(t.id), throwsException);
      },
    );

    test('yarış: load bitmeden başlatılan add, load tamamlanınca uygulanır '
        '(depo kaydı EZİLMEZ — review P1)', () async {
      // Depoda eski bir kayıt var; load gate ile geciktiriliyor.
      final stale = _acc('eski-depo-kaydı');
      final repo = _FakeRepo([stale])..loadGate = Completer<void>();
      final cubit = VaultCubit(repo);

      final loadFuture = cubit.load(); // beklemede (gate kapalı)
      // Kullanıcı load bitmeden ekleme başlatıyor → mutasyon load'ı BEKLER
      // (await ETME, çünkü load gate'e takılı; gerçek UI'da da ekleme load
      // bitene kadar tamamlanmaz).
      final fresh = _acc('kullanıcı-ekledi');
      final addFuture = cubit.add(fresh);

      // load henüz bitmeden add tamamlanmamalı (depoyu erken ezmez).
      var addDone = false;
      unawaited(addFuture.then((_) => addDone = true));
      await pumpEventQueue();
      expect(addDone, isFalse, reason: 'add load bitmeden uygulanmamalı');
      expect(repo.saveCount, 0, reason: 'load bitmeden save edilmemeli');

      // Şimdi load tamamlansın → add sonra uygulanır.
      repo.loadGate!.complete();
      await Future.wait([loadFuture, addFuture]);

      final names = cubit.state.accounts.map((a) => a.accountName).toSet();
      // Kullanıcının eklediği VE depo kaydı birlikte (depo ezilmedi).
      expect(names, containsAll(['kullanıcı-ekledi', 'eski-depo-kaydı']));
      // add load SONRASI save etti → depoda da ikisi var.
      expect(
        repo.stored.map((a) => a.accountName).toSet(),
        containsAll(['kullanıcı-ekledi', 'eski-depo-kaydı']),
      );
    });

    test('bütünlük hatası state\'inde add/remove/increment REDDEDİLİR — depo '
        'EZİLMEZ (review P1)', () async {
      // load top-level integrity hatası atar → state.error set, accounts boş,
      // repo cache boş. Bu state'te bir save diskteki ham vault'u onaysız ezerdi.
      final repo = _FakeRepo()..loadError = StateError('top-level bozuk');
      final cubit = VaultCubit(repo);
      await cubit.load();
      expect(cubit.state.error, isNotNull);
      expect(cubit.state.accounts, isEmpty);

      // Üç mutasyon da fırlar (UI SnackBar gösterir) ve ASLA save etmez.
      await expectLater(cubit.add(_acc('yeni')), throwsStateError);
      await expectLater(cubit.removeById('herhangi'), throwsStateError);
      await expectLater(cubit.incrementCounter('herhangi'), throwsStateError);
      expect(repo.saveCount, 0, reason: 'integrity state\'te save edilmemeli');
    });

    // --- Faz 5 Patch 1: addAll (toplu import) ---

    test(
      'addAll TEK save ile yazar (add\'e delege etmez — plan §3.6/D7)',
      () async {
        final repo = _FakeRepo();
        final cubit = VaultCubit(repo);
        await cubit.load();
        final savesBefore = repo.saveCount;

        await cubit.addAll([_acc('a'), _acc('b'), _acc('c')]);

        expect(
          repo.saveCount - savesBefore,
          1,
          reason: '3 token için 3 değil TEK persist olmalı',
        );
        expect(cubit.state.accounts.length, 3);
      },
    );

    test(
      'addAll listenin SIRASINI korur ve mevcutların SONUNA ekler',
      () async {
        final repo = _FakeRepo();
        final cubit = VaultCubit(repo);
        final vardi = _acc('vardi');
        await cubit.add(vardi);

        final a = _acc('a'), b = _acc('b'), c = _acc('c');
        await cubit.addAll([a, b, c]);

        expect(cubit.state.accounts.map((e) => e.accountName), [
          'vardi',
          'a',
          'b',
          'c',
        ]);
        expect(repo.stored.map((e) => e.id), [vardi.id, a.id, b.id, c.id]);
      },
    );

    test('addAll boş liste → no-op (save YOK, state DEĞİŞMEZ)', () async {
      final repo = _FakeRepo();
      final cubit = VaultCubit(repo);
      await cubit.add(_acc('a'));
      final before = cubit.state;
      final savesBefore = repo.saveCount;

      await cubit.addAll(const []);

      expect(repo.saveCount, savesBefore, reason: 'gereksiz yazma yok');
      expect(cubit.state, same(before));
    });

    test(
      'addAll aynı id\'yi ELER (önizleme ile onay arası vault değişebilir)',
      () async {
        // Önizleme alındıktan sonra sync pull/başka bir yol aynı satırı vault'a
        // eklemiş olabilir → aynı id iki kez listeye girmemeli (review takibi).
        final vardi = OtpAccount(
          id: 'sabit-id',
          secret: 'JBSWY3DPEHPK3PXP',
          type: OtpType.totp,
          accountName: 'vardi',
        );
        final ayniId = OtpAccount(
          id: 'sabit-id',
          secret: 'GEZDGNBVGY3TQOJQ',
          type: OtpType.totp,
          accountName: 'kopya',
        );
        final repo = _FakeRepo();
        final cubit = VaultCubit(repo);
        await cubit.add(vardi);
        final yeni = _acc('yeni');

        await cubit.addAll([ayniId, yeni]);

        expect(cubit.state.accounts.map((e) => e.id), ['sabit-id', yeni.id]);
        expect(
          cubit.state.accounts.map((e) => e.accountName),
          ['vardi', 'yeni'],
          reason: 'mevcut satır korunur, kopya düşer',
        );
      },
    );

    // --- Denetim A6: id DIŞINDA içerik elemesi (önizleme–onay arası pull) ---
    test('addAll AYNI içeriği FARKLI id ile getiren satırı eler', () async {
      // Önizleme alındıktan sonra sync pull aynı token'ı BAŞKA bir id ile
      // getirmiş olabilir (başka cihazda eklenmiş satır) → id kontrolü bunu
      // yakalamaz, içerik anahtarı yakalar.
      final vardi = OtpAccount(
        id: 'sunucudan-gelen',
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        accountName: 'a',
      );
      final ayniIcerik = OtpAccount(
        id: 'onizlemeden-gelen',
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        accountName: 'a',
      );
      final repo = _FakeRepo();
      final cubit = VaultCubit(repo);
      await cubit.add(vardi);
      final savesBefore = repo.saveCount;

      await cubit.addAll([ayniIcerik]);

      expect(cubit.state.accounts.map((e) => e.id), ['sunucudan-gelen']);
      expect(repo.saveCount, savesBefore, reason: 'yazma da push da yok');
    });

    test(
      'addAll listenin İÇİNDEKİ içerik kopyasını da eler (ilk kazanır)',
      () async {
        final repo = _FakeRepo();
        final cubit = VaultCubit(repo);
        await cubit.load();

        await cubit.addAll([_acc('a'), _acc('a'), _acc('b')]);

        expect(cubit.state.accounts.map((e) => e.accountName), ['a', 'b']);
      },
    );

    test('addAll keyOf: null → içerik elemesi YOK (eski davranış)', () async {
      final repo = _FakeRepo();
      final cubit = VaultCubit(repo);
      await cubit.load();

      await cubit.addAll([_acc('a'), _acc('a')], keyOf: null);

      expect(cubit.state.accounts.length, 2);
    });

    test('addAll FARKLI içerik (secret) aynı isimle eklenebilir', () async {
      final repo = _FakeRepo();
      final cubit = VaultCubit(repo);
      await cubit.add(_acc('a'));

      await cubit.addAll([
        OtpAccount(
          secret: 'GEZDGNBVGY3TQOJQ',
          type: OtpType.totp,
          accountName: 'a',
        ),
      ]);

      expect(
        cubit.state.accounts.length,
        2,
        reason: 'anahtar secret\'i İÇERİR → farklı token ayrı kalır',
      );
    });

    test('addAll TAMAMI kopya id ise no-op (save YOK)', () async {
      final vardi = OtpAccount(
        id: 'sabit-id',
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        accountName: 'vardi',
      );
      final repo = _FakeRepo();
      final cubit = VaultCubit(repo);
      await cubit.add(vardi);
      final savesBefore = repo.saveCount;

      await cubit.addAll([vardi]);

      expect(repo.saveCount, savesBefore, reason: 'gereksiz yazma/push yok');
      expect(cubit.state.accounts, hasLength(1));
    });

    test(
      'addAll bütünlük hatası state\'inde REDDEDİLİR (depo EZİLMEZ)',
      () async {
        final repo = _FakeRepo()..loadError = StateError('top-level bozuk');
        final cubit = VaultCubit(repo);
        await cubit.load();
        expect(cubit.state.error, isNotNull);

        await expectLater(cubit.addAll([_acc('yeni')]), throwsStateError);
        expect(
          repo.saveCount,
          0,
          reason: 'integrity state\'te save edilmemeli',
        );
      },
    );

    test('load idempotent (ikinci çağrı reload etmez)', () async {
      final repo = _FakeRepo([_acc('a')]);
      final cubit = VaultCubit(repo);
      await cubit.load();
      // Depo değişse bile ikinci load() no-op (ilk-yükleme tek sefer).
      repo.stored = [_acc('a'), _acc('b')];
      await cubit.load();
      expect(cubit.state.accounts.length, 1); // reload olmadı
    });
  });
}
