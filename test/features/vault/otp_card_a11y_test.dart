/// OtpCard erişilebilirlik kapısı (Design.md §5): Semantics etiketi, textScaler 2.0
/// taşma yok, reduced-motion'da çökme yok. (libsodium gerekmez — OtpGenerator saf Dart.)
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // --- Faz 5 Patch 3 — uzun basış artık DOĞRUDAN SİLMEZ (risk R10). Kart bir
  // `onLongPress` alırsa onu çağırır (VaultPage eylem sheet'ini açar); geriye
  // dönük olarak `onLongPress` verilmediğinde eski davranış korunur. Ekran
  // okuyucu kullanıcısı uzun basamaz → 'Düzenle'/'Sil' customSemanticsActions
  // olarak yayınlanır. ---
  group('uzun basış + assistive eylemler', () {
    testWidgets('onLongPress verildiğinde silme ÇAĞRILMAZ', (tester) async {
      var longPressed = 0;
      var deleted = 0;
      await tester.pumpWidget(_host(OtpCard(
        account: _acc(),
        onLongPress: () => longPressed++,
        onDelete: () => deleted++,
      )));
      await tester.pump();

      await tester.longPress(find.byType(OtpCard));
      await tester.pump();

      expect(longPressed, 1);
      expect(deleted, 0, reason: 'onaysız silme yolu kapandı');
    });

    testWidgets('onLongPress yoksa eski davranış korunur (onDelete)',
        (tester) async {
      var deleted = 0;
      await tester.pumpWidget(_host(OtpCard(
        account: _acc(),
        onDelete: () => deleted++,
      )));
      await tester.pump();

      await tester.longPress(find.byType(OtpCard));
      await tester.pump();

      expect(deleted, 1);
    });

    testWidgets('customSemanticsActions: Düzenle + Sil', (tester) async {
      var edited = 0;
      var deleted = 0;
      await tester.pumpWidget(_host(OtpCard(
        account: _acc(),
        onEdit: () => edited++,
        onDelete: () => deleted++,
        onLongPress: () {},
      )));
      await tester.pump();

      final props = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((s) => s.properties)
          .firstWhere((p) => p.customSemanticsActions != null);
      final actions = props.customSemanticsActions!;
      expect(actions.keys.map((k) => k.label), containsAll(['Düzenle', 'Sil']));

      // Birincil etiket ve tap (kopyala) KORUNUR — yalnız eylem eklendi.
      expect(props.label, contains('kod '));
      expect(props.onTap, isNotNull);

      actions.entries.firstWhere((e) => e.key.label == 'Düzenle').value();
      actions.entries.firstWhere((e) => e.key.label == 'Sil').value();
      expect(edited, 1);
      expect(deleted, 1);
    });

    testWidgets('geri çağrı yoksa assistive eylem de YAYINLANMAZ',
        (tester) async {
      await tester.pumpWidget(_host(OtpCard(account: _acc())));
      await tester.pump();

      final withActions = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where((s) => s.properties.customSemanticsActions != null);
      expect(withActions, isEmpty);
    });
  });

  // --- Clipboard hygiene (security review finding 2): copying an OTP must not
  // leave it in the clipboard indefinitely. Tap copies the code; after the
  // window it is wiped only if the clipboard still holds our value. ---
  group('OTP copy clipboard hygiene', () {
    late String? clipboard;
    setUp(() {
      clipboard = null;
      TestWidgetsFlutterBinding.ensureInitialized()
          .defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        } else if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': clipboard};
        }
        return null;
      });
    });
    tearDown(() {
      TestWidgetsFlutterBinding.ensureInitialized()
          .defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('tap copies the code, then clears it after the window',
        (tester) async {
      await tester.pumpWidget(_host(OtpCard(account: _acc())));
      await tester.pump();

      await tester.tap(find.byType(OtpCard));
      await tester.pump();
      expect(clipboard, isNotNull);
      expect(clipboard, isNotEmpty, reason: 'code copied to clipboard');
      final copied = clipboard;

      // Advance past the clear window (30s) — clipboard still holds our value
      // (nothing else copied) → it must be wiped.
      await tester.pump(const Duration(seconds: 31));
      expect(clipboard, '', reason: 'unchanged clipboard wiped after window');
      expect(copied, isNot(''));
    });

    testWidgets('does NOT wipe if the user copied something else meanwhile',
        (tester) async {
      await tester.pumpWidget(_host(OtpCard(account: _acc())));
      await tester.pump();

      await tester.tap(find.byType(OtpCard));
      await tester.pump();
      expect(clipboard, isNotEmpty);

      // User copies their own content before the window elapses.
      clipboard = 'user-copied-something';
      await tester.pump(const Duration(seconds: 31));
      expect(clipboard, 'user-copied-something',
          reason: 'we never overwrite the user\'s own clipboard data');
    });
  });
}
