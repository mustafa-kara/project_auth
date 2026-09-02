/// Faz 5 Patch 3 — VaultPage etiket filtresi + uzun basış eylem sheet'i.
///
/// Kapsam: çip şeridi (render/tek seçim/toggle), arama ∧ etiket AND, aramanın
/// etiket metnine de bakması, boş-filtre EmptyState'i, a11y (şerit etiketi,
/// `selected` semantics, 48dp dokunma hedefi, seçilide onay ikonu) ve
/// **onaysız silmenin kalkması** (uzun basış artık sheet açar).
///
/// libsodium GEREKMEZ: fake VaultRepository + fake VaultLockCubit. Etiket
/// mutasyonları (`editMetadata`/`renameTag`/`deleteTag`) W1'de dolduruluyor →
/// burada VaultCubit alt sınıfı ile taklit edilir (`allTags` GERÇEK).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/pages/vault_page.dart';
import 'package:project_auth/features/vault/presentation/widgets/otp_card.dart';
import 'package:project_auth/features/vault/presentation/widgets/tag_chips_bar.dart';

class _MemStorage implements FlutterSecureStorage {
  final Map<String, String> _d = {};
  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async => _d[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    if (value == null) {
      _d.remove(key);
    } else {
      _d[key] = value;
    }
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _FakeRepo implements VaultRepository {
  List<OtpAccount> accounts;
  int saves = 0;
  _FakeRepo(this.accounts);

  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(accounts));
  @override
  Future<void> save(List<OtpAccount> a) async {
    saves++;
    accounts = List.of(a);
  }

  @override
  Future<void> purgeCorrupted() async {}
}

/// Etiket mutasyonları W1'de doldurulacak (`UnimplementedError`); UI testleri
/// onları beklemesin diye burada in-memory taklit edilir. `allTags` override
/// EDİLMEZ — sözleşmedeki gerçek türetim kullanılır.
class _TagCubit extends VaultCubit {
  _TagCubit(super.repo);

  final List<String> calls = [];

  @override
  Future<void> editMetadata({
    required String id,
    String? issuer,
    String? accountName,
    List<String>? tags,
  }) async {
    calls.add('edit:$id');
    emit(
      state.copyWith(
        accounts: [
          for (final a in state.accounts)
            if (a.id == id)
              a.copyWith(issuer: issuer, accountName: accountName, tags: tags)
            else
              a,
        ],
      ),
    );
  }

  @override
  Future<void> renameTag(String from, String to) async {
    calls.add('rename:$from>$to');
    emit(
      state.copyWith(
        accounts: [
          for (final a in state.accounts)
            a.tags.contains(from)
                ? a.copyWith(tags: [for (final t in a.tags) t == from ? to : t])
                : a,
        ],
      ),
    );
  }

  @override
  Future<void> deleteTag(String tag) async {
    calls.add('delete:$tag');
    emit(
      state.copyWith(
        accounts: [
          for (final a in state.accounts)
            a.tags.contains(tag)
                ? a.copyWith(tags: a.tags.where((t) => t != tag).toList())
                : a,
        ],
      ),
    );
  }
}

class _FakeLockCubit extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLockCubit() : super(const VaultLockState.unlocked());
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

OtpAccount _acc(String name, {List<String> tags = const []}) => OtpAccount(
  secret: 'JBSWY3DPEHPK3PXP',
  type: OtpType.totp,
  accountName: name,
  tags: tags,
);

Future<_TagCubit> _pump(WidgetTester tester, List<OtpAccount> accounts) async {
  final vault = _TagCubit(_FakeRepo(accounts))..load();
  addTearDown(vault.close);
  final lock = _FakeLockCubit();
  addTearDown(lock.close);
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<VaultCubit>.value(value: vault),
        BlocProvider<VaultLockCubit>.value(value: lock),
      ],
      child: const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: VaultPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return vault;
}

final Finder _searchField = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == 'Ara (issuer / hesap)',
);

void main() {
  setUp(() {
    if (!locator.isRegistered<OtpGenerator>()) {
      locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());
    }
    if (!locator.isRegistered<ViewModeStore>()) {
      locator.registerLazySingleton<ViewModeStore>(
        () => ViewModeStore(storage: _MemStorage()),
      );
    }
  });
  tearDown(GetIt.instance.reset);

  group('etiket çip şeridi', () {
    testWidgets('etiket yoksa şerit RENDER EDİLMEZ (dikey alan yenmez)', (
      tester,
    ) async {
      await _pump(tester, [_acc('alice@example.com')]);
      expect(find.byType(TagChipsBar), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.text('Etiketleri yönet'), findsNothing);
    });

    testWidgets('etiketler kullanım sırasıyla çip olur + "Etiketleri yönet"', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
        _acc('bob@example.com', tags: ['İş', 'Kişisel']),
      ]);
      expect(find.widgetWithText(FilterChip, 'İş'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Kişisel'), findsOneWidget);
      expect(find.text('Etiketleri yönet'), findsOneWidget);
    });

    testWidgets('çipe basınca liste filtrelenir, tekrar basınca temizlenir', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
        _acc('bob@example.com'),
      ]);
      expect(find.byType(OtpCard), findsNWidgets(2));

      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsNWidgets(2));
    });

    testWidgets('arama ∧ etiket AND uygulanır', (tester) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
        _acc('bob@example.com', tags: ['İş']),
      ]);
      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsNWidgets(2));

      await tester.enterText(_searchField, 'alice');
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);
    });

    testWidgets('arama etiket metnine de bakar', (tester) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['Bankacılık']),
        _acc('bob@example.com'),
      ]);
      await tester.enterText(_searchField, 'bankacı');
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);
    });

    testWidgets('etiket filtresi boş sonuç → "Bu etikette kod yok" + temizle', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
        _acc('bob@example.com'),
      ]);
      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();
      await tester.enterText(_searchField, 'zzzz');
      await tester.pumpAndSettle();

      expect(find.text('Bu etikette kod yok'), findsOneWidget);
      expect(
        find.text('« İş » etiketiyle eşleşen kod bulunamadı.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Filtreyi temizle'));
      await tester.pumpAndSettle();
      // Hem arama hem etiket sıfırlanır → tüm kodlar geri gelir.
      expect(find.byType(OtpCard), findsNWidgets(2));
    });

    testWidgets('arama-yalnız boş sonuç eski EmptyState\'i korur', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
      ]);
      await tester.enterText(_searchField, 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('Aramayla eşleşen kod yok'), findsOneWidget);
      expect(find.text('Aramayı temizle'), findsWidgets);
    });

    testWidgets(
      'seçili etiketi taşıyan son kod silinince filtre kendini siler',
      (tester) async {
        await _pump(tester, [
          _acc('alice@example.com', tags: ['İş']),
          _acc('bob@example.com'),
        ]);
        await tester.tap(find.widgetWithText(FilterChip, 'İş'));
        await tester.pumpAndSettle();
        expect(find.byType(OtpCard), findsOneWidget);

        await tester.longPress(find.byType(OtpCard));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sil'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Sil'));
        await tester.pumpAndSettle();

        // Etiket artık hiçbir kayıtta yok → şerit boşalır, filtre düşer, kalan
        // kod gizli KALMAZ.
        expect(find.byType(FilterChip), findsNothing);
        expect(find.byType(OtpCard), findsOneWidget);
        expect(find.text('bob@example.com'), findsOneWidget);
      },
    );

    testWidgets('kaybolan etiket geri gelirse filtre KENDİLİĞİNDEN dönmez', (
      tester,
    ) async {
      final vault = await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
        _acc('bob@example.com'),
      ]);
      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsOneWidget);

      // Etiket başka bir cihazda yeniden adlandırıldı → seçim artık yok.
      await vault.renameTag('İş', 'Ofis');
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsNWidgets(2));

      // ...ve geri alındı. Seçim yalnız BUILD'de doğrulanıp alanda bayat
      // kalsaydı 'İş' burada kendiliğinden yeniden seçilir ve kullanıcının
      // baktığı kodlar sessizce yine gizlenirdi.
      await vault.renameTag('Ofis', 'İş');
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsNWidgets(2));
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'İş'))
            .selected,
        isFalse,
      );
    });
  });

  group('a11y', () {
    testWidgets('şerit "Etiket filtresi" etiketli, çipler button + selected', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
      ]);

      final labels = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((s) => s.properties.label)
          .whereType<String>();
      expect(labels, contains('Etiket filtresi'));

      Semantics chipSemantics() => tester
          .widgetList<Semantics>(find.byType(Semantics))
          .firstWhere((s) => s.properties.label == 'İş');

      expect(chipSemantics().properties.button, isTrue);
      expect(chipSemantics().properties.selected, isFalse);

      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();
      expect(chipSemantics().properties.selected, isTrue);
    });

    testWidgets('çip dokunma hedefi ≥48dp ve seçilide onay İKONU var', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
      ]);
      expect(
        tester.getSize(find.widgetWithText(FilterChip, 'İş')).height,
        greaterThanOrEqualTo(TagChipsBar.minTouchTarget),
      );
      // Renk tek sinyal değil: seçilmeden onay ikonu YOK, seçilince VAR.
      expect(find.byIcon(Icons.check), findsNothing);
      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('uzun basış → eylem sheet\'i (onaysız silme KALKTI)', () {
    testWidgets('uzun basış SİLMEZ, sheet açar', (tester) async {
      final vault = await _pump(tester, [_acc('alice@example.com')]);

      await tester.longPress(find.byType(OtpCard));
      await tester.pumpAndSettle();

      expect(find.text('Kodu düzenle'), findsOneWidget);
      expect(find.text('Etiketleri düzenle'), findsOneWidget);
      expect(find.text('Sil'), findsOneWidget);
      expect(vault.state.accounts.length, 1, reason: 'hiçbir şey silinmedi');
    });

    testWidgets('"Sil" → onay diyaloğu; "Vazgeç" → kayıt DURUR', (
      tester,
    ) async {
      final vault = await _pump(tester, [_acc('alice@example.com')]);

      await tester.longPress(find.byType(OtpCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sil'));
      await tester.pumpAndSettle();

      expect(find.text('Kodu sil?'), findsOneWidget);
      expect(find.textContaining('geri alınamaz'), findsOneWidget);

      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(vault.state.accounts.length, 1);
    });

    testWidgets('"Sil" → onaylanınca kayıt gider', (tester) async {
      final vault = await _pump(tester, [_acc('alice@example.com')]);

      await tester.longPress(find.byType(OtpCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sil'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sil'));
      await tester.pumpAndSettle();

      expect(vault.state.accounts, isEmpty);
    });

    testWidgets('"Kodu düzenle" → EditTokenSheet açılır (secret YOK)', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
      ]);

      await tester.longPress(find.byType(OtpCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kodu düzenle'));
      await tester.pumpAndSettle();

      expect(find.text('Kodu düzenle'), findsOneWidget); // sheet başlığı
      expect(find.text('Servis'), findsOneWidget);
      expect(find.text('Hesap'), findsOneWidget);
      expect(find.textContaining('JBSWY3DPEHPK3PXP'), findsNothing);
    });
  });

  group('etiket yöneticisi', () {
    testWidgets('"Etiketleri yönet" → satırlar "etiket · n kod"', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
        _acc('bob@example.com', tags: ['İş']),
      ]);
      await tester.tap(find.text('Etiketleri yönet'));
      await tester.pumpAndSettle();
      expect(find.text('İş · 2 kod'), findsOneWidget);
    });

    testWidgets('yeniden adlandırma aktif filtreyi YENİ ada taşır', (
      tester,
    ) async {
      await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
      ]);
      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Etiketleri yönet'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Etiketi yeniden adlandır'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Ofis');
      await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
      await tester.pumpAndSettle();

      // Sheet açık kalsa da arkadaki sayfa ağaçta: filtre yeni ada taşındı →
      // kod gizlenmedi.
      expect(find.byType(OtpCard), findsOneWidget);
      final chip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Ofis'),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('etiket silinince aktif filtre temizlenir', (tester) async {
      final vault = await _pump(tester, [
        _acc('alice@example.com', tags: ['İş']),
        _acc('bob@example.com'),
      ]);
      await tester.tap(find.widgetWithText(FilterChip, 'İş'));
      await tester.pumpAndSettle();
      expect(find.byType(OtpCard), findsOneWidget);

      await tester.tap(find.text('Etiketleri yönet'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Etiketi sil'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Kaldır'));
      await tester.pumpAndSettle();

      expect(vault.calls, contains('delete:İş'));
      expect(find.text('1 kod güncellendi'), findsOneWidget);
    });
  });
}
