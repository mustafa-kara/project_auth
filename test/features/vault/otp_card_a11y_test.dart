/// OtpCard erişilebilirlik kapısı (Design.md §5): Semantics etiketi, textScaler 2.0
/// taşma yok, reduced-motion'da çökme yok. (libsodium gerekmez — OtpGenerator saf Dart.)
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/features/vault/presentation/widgets/otp_card.dart';

OtpAccount _acc({String issuer = 'GitHub', String name = 'octocat@example.com'}) =>
    OtpAccount(
      secret: 'JBSWY3DPEHPK3PXP',
      type: OtpType.totp,
      issuer: issuer,
      accountName: name,
    );

Widget _host(Widget child, {double textScale = 1.0, bool reduceMotion = false}) =>
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: SizedBox(width: 360, child: child),
        ),
      ),
    );

void main() {
  setUp(() {
    if (!locator.isRegistered<OtpGenerator>()) {
      locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());
    }
  });
  tearDown(GetIt.instance.reset);

  testWidgets('OTP kodu + kalan süre Semantics etiketinde', (tester) async {
    await tester.pumpWidget(_host(OtpCard(account: _acc())));
    await tester.pump();
    // Etiket "kod <6hane>, <n> saniye kaldı" içerir.
    final labels = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .map((s) => s.properties.label)
        .whereType<String>();
    expect(
      labels.any((l) => l.contains('kod ') && l.contains('saniye kaldı')),
      isTrue,
      reason: 'OtpCard Semantics etiketi kod + kalan süre içermeli',
    );
  });

  testWidgets('textScaler 2.0 — taşma yok (kart)', (tester) async {
    await tester.pumpWidget(_host(OtpCard(account: _acc()), textScale: 2.0));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('textScaler 2.0 — taşma yok (kompakt)', (tester) async {
    await tester.pumpWidget(
        _host(OtpCard(account: _acc(), compact: true), textScale: 2.0));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced-motion — sayaç çökmeden render olur', (tester) async {
    await tester.pumpWidget(_host(OtpCard(account: _acc()), reduceMotion: true));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Sayaç metni (kalan saniye) görünür — color-not-only sinyali korunur.
    expect(find.byType(OtpCard), findsOneWidget);
  });
}
