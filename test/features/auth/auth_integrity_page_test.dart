/// AuthIntegrityPage — "Yeniden dene" geri bildirimi (doğrulama NEW-3).
///
/// `retryBootstrap()` başarısız olduğunda cubit AYNI statüyü tekrar emit eder;
/// ayırt edici tek şey `VaultLockState.attempt` sayacıdır. Bu ekranın sözü:
/// deneme sürerken spinner, sayaç ilerlediyse "Hâlâ okunamıyor". Sayaç olmadan
/// bloc eşit state'i düşürürdü ve buton hiçbir şey yapmıyormuş gibi görünürdü.
/// libsodium GEREKMEZ: KeyManager fake'lenir, depo hatası enjekte edilir.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';
import 'package:project_auth/features/auth/domain/biometric_service.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/auth/presentation/pages/auth_integrity_page.dart';

class _NoBiometric implements BiometricService {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<void> enroll(Uint8List keyBytes) async {}
  @override
  Future<Uint8List> retrieve() async => Uint8List(0);
  @override
  Future<void> disable() async {}
}

class _FakeKeyManager implements KeyManager {
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

/// `read()` ya platform hatası fırlatır ya da (gate ile) askıda bekler —
/// spinner'ın gözlemlenebilmesi için okumanın SÜRMESİ gerekir.
class _FailingAttrsStore implements KeyAttributesStore {
  Future<void>? gate;
  int reads = 0;

  @override
  Future<KeyAttributes?> read() async {
    reads++;
    if (gate != null) await gate;
    throw PlatformException(code: 'Keystore', message: 'test');
  }

  @override
  Future<void> write(KeyAttributes attrs) async {}
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

void main() {
  late _FailingAttrsStore store;
  late VaultLockCubit cubit;

  setUp(() {
    store = _FailingAttrsStore();
    cubit = VaultLockCubit(
      keyManager: _FakeKeyManager(),
      attrsStore: store,
      biometric: _NoBiometric(),
      migrate: (_) async {},
      deleteKeys: (_) async {},
    );
  });

  tearDown(() => cubit.close());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: BlocProvider.value(value: cubit, child: const AuthIntegrityPage()),
    ),
  );

  testWidgets('deneme sürerken spinner, buton pasif', (tester) async {
    await cubit.bootstrap();
    await pump(tester);

    final gate = Completer<void>();
    store.gate = gate.future;
    await tester.tap(find.text('Yeniden dene'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Yeniden dene'), findsNothing);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
      reason: 'deneme sürerken sıfırlama da tıklanamaz',
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Yeniden dene'), findsOneWidget);
  });

  testWidgets('hata sürüyorsa "Hâlâ okunamıyor" gösterilir', (tester) async {
    await cubit.bootstrap();
    expect(cubit.state.status, VaultLockStatus.keyAttributesCorrupted);
    await pump(tester);
    expect(find.text('Hâlâ okunamıyor'), findsNothing);

    await tester.tap(find.text('Yeniden dene'));
    await tester.pumpAndSettle();

    expect(store.reads, 2, reason: 'okuma GERÇEKTEN tekrarlandı');
    expect(cubit.state.attempt, 2);
    expect(find.text('Hâlâ okunamıyor'), findsOneWidget);
  });
}
