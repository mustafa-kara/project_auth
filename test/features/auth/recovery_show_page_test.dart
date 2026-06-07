/// RecoveryShowPage — "Panoya kopyala" NUMARALI format üretir.
///
/// Eski davranış `words.join(' ')` numaraları atıyordu → yapıştırınca kullanıcı
/// hangi kelime kaçıncı bilemiyordu. Artık "1. lizard\n2. goddess ..." (sıra
/// korunur; RecoveryUnlockPage bu formatı geri ayıklar). libsodium GEREKMEZ.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/auth/presentation/pages/recovery_show_page.dart';

/// Sahte cubit — setupPending state'i sabit tutar, aksiyonlar no-op.
class _FakeLock extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLock(super.state);
  @override
  noSuchMethod(Invocation i) {}
}

void main() {
  testWidgets('Panoya kopyala → numaralı format (sıra korunur)',
      (tester) async {
    final words = List.generate(24, (i) => 'word$i');

    // Clipboard.setData'yı yakala (gerçek pano erişimi yok test ortamında).
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // Geniş viewport: 24-kelime grid + kopyala + checkbox + CTA hepsi sığsın
    // (default 800×600'de ListView içeriği fold altında kalıp overflow/clip olmaz).
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider<VaultLockCubit>.value(
          value: _FakeLock(VaultLockState.setupPending(mnemonic: words)),
          child: const RecoveryShowPage(),
        ),
      ),
    );
    await tester.pump();

    final copyBtn = find.text('Panoya kopyala');
    await tester.ensureVisible(copyBtn);
    await tester.pump();
    await tester.tap(copyBtn);
    await tester.pump();

    final expected = [
      for (var i = 0; i < words.length; i++) '${i + 1}. ${words[i]}',
    ].join('\n');
    expect(copied, expected);
    // İlk ve son satır numaralı (düz join değil).
    expect(copied, startsWith('1. word0'));
    expect(copied, endsWith('24. word23'));
  });

  testWidgets(
      'recovery grid textScaler 2.0 altında taşma/overflow yok (Design.md §5 '
      'dynamic-type test kapısı)', (tester) async {
    // Recovery, veri kaybı = kilitlenme olan TEK ekran → büyük metin ölçeğinde
    // 24 kelimelik grid clip/overflow etmemeli (SelectableText sarılır).
    final words = List.generate(24, (i) => 'kelime$i');
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: BlocProvider<VaultLockCubit>.value(
            value: _FakeLock(VaultLockState.setupPending(mnemonic: words)),
            child: const RecoveryShowPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // RenderFlex overflow vb. exception fırlatmamalı.
    expect(tester.takeException(), isNull);
    // 24 kelime de render edildi (kısaltma/atlama yok).
    for (final w in words) {
      expect(find.text(w), findsOneWidget);
    }
  });
}
