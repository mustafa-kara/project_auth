/// Faz 5 Patch 3 — `TagManagerSheet` (yeniden adlandır / kaldır).
///
/// Silme diyaloğu ETİKETİ kaldırır, KODLARI DEĞİL: metin bunu açıkça söyler ve
/// test `removeById` benzeri bir token silme çağrısının olmadığını sabitler.
///
/// libsodium GEREKMEZ. `renameTag`/`deleteTag` W1'de dolduruluyor → VaultCubit
/// alt sınıfı ile taklit edilir (`allTags` GERÇEK).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/widgets/tag_manager_sheet.dart';

class _FakeRepo implements VaultRepository {
  List<OtpAccount> accounts;
  _FakeRepo(this.accounts);
  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(accounts));
  @override
  Future<void> save(List<OtpAccount> a) async => accounts = List.of(a);
  @override
  Future<void> purgeCorrupted() async {}
}

class _TagCubit extends VaultCubit {
  _TagCubit(super.repo, {this.failWith});

  final Object? failWith;
  final List<String> calls = [];

  @override
  Future<void> renameTag(String from, String to) async {
    calls.add('rename:$from>$to');
    if (failWith != null) throw failWith!;
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
    if (failWith != null) throw failWith!;
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

OtpAccount _acc(String name, {List<String> tags = const []}) => OtpAccount(
  secret: 'JBSWY3DPEHPK3PXP',
  type: OtpType.totp,
  accountName: name,
  tags: tags,
);

Future<void> _open(
  WidgetTester tester,
  VaultCubit cubit, {
  void Function(String from, String to)? onRenamed,
  void Function(String tag)? onDeleted,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: ctx,
                  isScrollControlled: true,
                  builder: (_) => TagManagerSheet(
                    cubit: cubit,
                    onRenamed: onRenamed,
                    onDeleted: onDeleted,
                  ),
                ),
                child: const Text('aç'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('aç'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('satırlar "etiket · n kod" biçiminde ve kullanım sırasında', (
    tester,
  ) async {
    final cubit = _TagCubit(
      _FakeRepo([
        _acc('a@example.com', tags: ['İş', 'Kişisel']),
        _acc('b@example.com', tags: ['İş']),
      ]),
    )..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit);

    expect(find.text('İş · 2 kod'), findsOneWidget);
    expect(find.text('Kişisel · 1 kod'), findsOneWidget);
    // Kullanım sıklığına göre azalan: 'İş' (2) önce.
    final iy = tester.getTopLeft(find.text('İş · 2 kod')).dy;
    final ky = tester.getTopLeft(find.text('Kişisel · 1 kod')).dy;
    expect(iy, lessThan(ky));
  });

  testWidgets(
    'yeniden adlandır → renameTag + onRenamed + "n kod güncellendi"',
    (tester) async {
      final cubit = _TagCubit(
        _FakeRepo([
          _acc('a@example.com', tags: ['İş']),
          _acc('b@example.com', tags: ['İş']),
        ]),
      )..load();
      addTearDown(cubit.close);
      await tester.pumpAndSettle();
      final renamed = <String>[];
      await _open(
        tester,
        cubit,
        onRenamed: (from, to) => renamed.add('$from>$to'),
      );

      await tester.tap(find.byTooltip('Etiketi yeniden adlandır'));
      await tester.pumpAndSettle();
      expect(find.text('Etiketi yeniden adlandır'), findsWidgets);
      expect(find.text('Yeni ad'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '  Ofis  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
      await tester.pumpAndSettle();

      // Normalize edilmiş ad hem cubit'e hem geri çağrıya gider (trim).
      expect(cubit.calls, ['rename:İş>Ofis']);
      expect(renamed, ['İş>Ofis']);
      expect(find.text('2 kod güncellendi'), findsOneWidget);
      expect(find.text('Ofis · 2 kod'), findsOneWidget);
    },
  );

  testWidgets('"Vazgeç" → renameTag ÇAĞRILMAZ', (tester) async {
    final cubit = _TagCubit(
      _FakeRepo([
        _acc('a@example.com', tags: ['İş']),
      ]),
    )..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit);

    await tester.tap(find.byTooltip('Etiketi yeniden adlandır'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Ofis');
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(cubit.calls, isEmpty);
  });

  testWidgets('aynı ada yeniden adlandırma no-op (yazma YOK)', (tester) async {
    final cubit = _TagCubit(
      _FakeRepo([
        _acc('a@example.com', tags: ['İş']),
      ]),
    )..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit);

    await tester.tap(find.byTooltip('Etiketi yeniden adlandır'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '  İş ');
    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();

    expect(cubit.calls, isEmpty);
  });

  testWidgets('silme onayı ETİKETİ kaldırır, KODLARI silmez', (tester) async {
    final cubit = _TagCubit(
      _FakeRepo([
        _acc('a@example.com', tags: ['İş']),
        _acc('b@example.com', tags: ['İş']),
      ]),
    )..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    final deleted = <String>[];
    await _open(tester, cubit, onDeleted: deleted.add);

    await tester.tap(find.byTooltip('Etiketi sil'));
    await tester.pumpAndSettle();
    expect(find.text('Etiketi sil?'), findsOneWidget);
    expect(
      find.text(
        '« İş » etiketi 2 koddan kaldırılacak. '
        'Kodların kendisi SİLİNMEZ.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Kaldır'));
    await tester.pumpAndSettle();

    expect(cubit.calls, ['delete:İş']);
    expect(deleted, ['İş']);
    expect(find.text('2 kod güncellendi'), findsOneWidget);
    // Token'lar duruyor — yalnız etiket gitti.
    expect(cubit.state.accounts.length, 2);
    expect(cubit.allTags, isEmpty);
  });

  testWidgets('silme "Vazgeç" → deleteTag ÇAĞRILMAZ', (tester) async {
    final cubit = _TagCubit(
      _FakeRepo([
        _acc('a@example.com', tags: ['İş']),
      ]),
    )..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit);

    await tester.tap(find.byTooltip('Etiketi sil'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(cubit.calls, isEmpty);
  });

  testWidgets('yazma hatası sessiz geçmez → "Kaydedilemedi: ..."', (
    tester,
  ) async {
    final cubit = _TagCubit(
      _FakeRepo([
        _acc('a@example.com', tags: ['İş']),
      ]),
      failWith: StateError('disk dolu'),
    )..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit);

    await tester.tap(find.byTooltip('Etiketi sil'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Kaldır'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Kaydedilemedi:'), findsOneWidget);
  });
}
