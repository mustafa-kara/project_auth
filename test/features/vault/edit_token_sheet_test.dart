/// Faz 5 Patch 3 — `EditTokenSheet` (servis / hesap / etiketler).
///
/// EN KRİTİK KAPI: secret HİÇBİR biçimde render edilmez. Düzenleme ekranı
/// secret'i (ve type/algorithm/digits/period/counter'ı) ne gösterir ne de
/// yazabilir — `VaultCubit.editMetadata` onları parametre olarak bile almaz.
///
/// libsodium GEREKMEZ. Etiket mutasyonları W1'de dolduruluyor → VaultCubit alt
/// sınıfı ile taklit edilir (`allTags` GERÇEK).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/widgets/edit_token_sheet.dart';

const _secret = 'JBSWY3DPEHPK3PXP';

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

class _EditCubit extends VaultCubit {
  _EditCubit(super.repo, {this.failWith});

  /// Set → `editMetadata` bu hatayı fırlatır (kalıcılık hatası senaryosu).
  final Object? failWith;

  String? lastId;
  String? lastIssuer;
  String? lastAccountName;
  List<String>? lastTags;
  int calls = 0;

  @override
  Future<void> editMetadata({
    required String id,
    String? issuer,
    String? accountName,
    List<String>? tags,
  }) async {
    calls++;
    lastId = id;
    lastIssuer = issuer;
    lastAccountName = accountName;
    lastTags = tags;
    if (failWith != null) throw failWith!;
  }
}

OtpAccount _acc({
  String? issuer = 'GitHub',
  String name = 'octocat@example.com',
  List<String> tags = const [],
}) =>
    OtpAccount(
      secret: _secret,
      type: OtpType.totp,
      issuer: issuer,
      accountName: name,
      tags: tags,
    );

final Finder _tagField = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == 'Etiket');

/// Sheet'i gerçek bir modal route içinde açar (pop davranışı test edilebilsin).
Future<void> _open(
  WidgetTester tester,
  VaultCubit cubit,
  OtpAccount account, {
  bool focusTags = false,
}) async {
  await tester.pumpWidget(MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                isScrollControlled: true,
                builder: (_) => EditTokenSheet(
                  account: account,
                  cubit: cubit,
                  focusTags: focusTags,
                ),
              ),
              child: const Text('aç'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('aç'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('secret HİÇBİR YERDE render edilmez', (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit, _acc(tags: ['İş']));

    expect(find.textContaining(_secret), findsNothing);
    // Kısmi sızıntı da olmasın (ör. maskeli/kırpılmış gösterim).
    expect(find.textContaining(_secret.substring(0, 6)), findsNothing);
  });

  testWidgets('mevcut servis / hesap / etiketler doldurulur', (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit, _acc(tags: ['İş', 'Bankacılık']));

    expect(find.text('Kodu düzenle'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('octocat@example.com'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'İş'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Bankacılık'), findsOneWidget);
  });

  testWidgets('etiket eklenir ve kaldırılır', (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit, _acc());

    await tester.enterText(_tagField, '  İş  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    // Model normalize eder (trim) → çipte kırpılmış hâli görünür.
    expect(find.widgetWithText(InputChip, 'İş'), findsOneWidget);

    await tester.tap(find.byTooltip('Etiketi kaldır'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'İş'), findsNothing);
  });

  testWidgets('aynı etiket iki kez eklenemez (model tekilleştirir)',
      (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit, _acc(tags: ['İş']));

    await tester.enterText(_tagField, 'İş');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'İş'), findsOneWidget);
  });

  testWidgets('8 tavanında alan DEVRE DIŞI + yardımcı metin', (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(
      tester,
      cubit,
      _acc(tags: const ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']),
    );

    expect(tester.widget<TextField>(_tagField).enabled, isFalse);
    expect(find.text('En fazla 8 etiket ekleyebilirsin.'), findsOneWidget);
  });

  testWidgets('etiket alanı maxLength 32 (model tavanıyla aynı)',
      (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit, _acc());

    expect(tester.widget<TextField>(_tagField).maxLength,
        OtpAccount.maxTagRunes);
  });

  testWidgets('öneri çipleri allTags\'ten gelir; ekli olan önerilmez',
      (tester) async {
    final repo = _FakeRepo([
      _acc(name: 'a@example.com', tags: ['İş']),
      _acc(name: 'b@example.com', tags: ['Kişisel']),
    ]);
    final cubit = _EditCubit(repo)..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit, _acc(name: 'c@example.com', tags: ['İş']));

    expect(find.text('Öneriler'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Kişisel'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'İş'), findsNothing);

    await tester.tap(find.widgetWithText(ActionChip, 'Kişisel'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Kişisel'), findsOneWidget);
  });

  testWidgets('Kaydet → editMetadata (secret DEĞİL) + sheet kapanır',
      (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    final account = _acc(tags: ['İş']);
    await _open(tester, cubit, account);

    await tester.enterText(find.widgetWithText(TextFormField, 'GitHub'),
        'GitHub Inc');
    await tester.enterText(_tagField, 'Ofis');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();

    expect(cubit.calls, 1);
    expect(cubit.lastId, account.id);
    expect(cubit.lastIssuer, 'GitHub Inc');
    expect(cubit.lastAccountName, 'octocat@example.com');
    expect(cubit.lastTags, ['İş', 'Ofis']);
    expect(find.text('Kodu düzenle'), findsNothing, reason: 'sheet kapanmalı');
  });

  // Sheet issuer'ı olmayan bir token için BOŞ metin alanı gösterir, dolayısıyla
  // dokunulmadan kaydedince `issuer: ''` gönderir. Bu SÖZLEŞME: `''`'i "issuer
  // yok" olarak okuyup no-op'a çevirmek `VaultCubit.editMetadata`'nın işi
  // (bkz. vault_cubit_tags_test.dart) — sheet'in kendi normalizasyonu yok.
  testWidgets('issuer\'sız hesap: dokunmadan Kaydet → issuer boş string gider',
      (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    final account = _acc(issuer: null);
    await _open(tester, cubit, account);

    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();

    expect(cubit.calls, 1);
    expect(cubit.lastIssuer, '');
    expect(cubit.lastAccountName, 'octocat@example.com');
    expect(cubit.lastTags, isEmpty);
  });

  testWidgets('yazma hatası → "Kaydedilemedi: ..." + sheet AÇIK kalır',
      (tester) async {
    final cubit = _EditCubit(_FakeRepo([]), failWith: StateError('disk dolu'))
      ..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit, _acc());

    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Kaydedilemedi:'), findsOneWidget);
    expect(find.text('Kodu düzenle'), findsOneWidget, reason: 'sheet açık');
  });

  testWidgets('hesap adı boşaltılırsa Kaydet devre dışı', (tester) async {
    final cubit = _EditCubit(_FakeRepo([]))..load();
    addTearDown(cubit.close);
    await tester.pumpAndSettle();
    await _open(tester, cubit, _acc());

    await tester.enterText(
        find.widgetWithText(TextFormField, 'octocat@example.com'), '   ');
    await tester.pumpAndSettle();

    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Kaydet'))
          .onPressed,
      isNull,
    );
    expect(find.text('Hesap adı boş olamaz.'), findsOneWidget);
  });
}
