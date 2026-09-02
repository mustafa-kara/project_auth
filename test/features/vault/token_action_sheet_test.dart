/// Faz 5 Patch 3 — uzun basış eylem sheet'i.
///
/// Sheet'in TEK işi seçimi bildirmek: hiçbir mutasyon yapmaz, secret göstermez
/// ve kapatılınca (barrier) `null` döner → çağıran hiçbir şey yapmaz.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/presentation/widgets/token_action_sheet.dart';

const _secret = 'JBSWY3DPEHPK3PXP';

OtpAccount _acc() => OtpAccount(
      secret: _secret,
      type: OtpType.totp,
      issuer: 'GitHub',
      accountName: 'octocat@example.com',
    );

/// Sheet'i açar; kapanınca seçilen değeri [captured]'a yazar.
Future<List<TokenAction?>> _open(WidgetTester tester) async {
  final captured = <TokenAction?>[];
  await tester.pumpWidget(MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async => captured
                  .add(await TokenActionSheet.show(ctx, account: _acc())),
              child: const Text('aç'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('aç'));
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('üç eylem + hesap başlığı; secret YOK', (tester) async {
    await _open(tester);
    expect(find.text('GitHub (octocat@example.com)'), findsOneWidget);
    expect(find.text('Kodu düzenle'), findsOneWidget);
    expect(find.text('Etiketleri düzenle'), findsOneWidget);
    expect(find.text('Sil'), findsOneWidget);
    expect(find.textContaining(_secret), findsNothing);
  });

  testWidgets('"Kodu düzenle" → TokenAction.edit', (tester) async {
    final captured = await _open(tester);
    await tester.tap(find.text('Kodu düzenle'));
    await tester.pumpAndSettle();
    expect(captured, [TokenAction.edit]);
  });

  testWidgets('"Etiketleri düzenle" → TokenAction.tags', (tester) async {
    final captured = await _open(tester);
    await tester.tap(find.text('Etiketleri düzenle'));
    await tester.pumpAndSettle();
    expect(captured, [TokenAction.tags]);
  });

  testWidgets('"Sil" → TokenAction.delete (sheet SİLMEZ, yalnız bildirir)',
      (tester) async {
    final captured = await _open(tester);
    await tester.tap(find.text('Sil'));
    await tester.pumpAndSettle();
    expect(captured, [TokenAction.delete]);
  });

  testWidgets('barrier ile kapatılırsa null → hiçbir şey yapılmaz',
      (tester) async {
    final captured = await _open(tester);
    await tester.tapAt(const Offset(400, 20)); // sheet dışı
    await tester.pumpAndSettle();
    expect(captured, [null]);
  });
}
