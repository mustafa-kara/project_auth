// Vault ekranı smoke test: yükleme sonrası boş durum görünüyor mu.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/pages/vault_page.dart';

/// Boş bellek-içi repository (widget testinde secure_storage'a dokunmaz).
class _EmptyRepo implements VaultRepository {
  @override
  Future<VaultLoadResult> load() async => VaultLoadResult.empty;
  @override
  Future<void> save(List<OtpAccount> accounts) async {}
  @override
  Future<void> purgeCorrupted() async {}
}

class _MemStorage implements FlutterSecureStorage {
  final Map<String, String> _d = {};
  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => _d[key];
  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) { _d.remove(key); } else { _d[key] = value; }
  }
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError();
}

void main() {
  setUp(() {
    locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());
    locator.registerLazySingleton<ViewModeStore>(
        () => ViewModeStore(storage: _MemStorage()));
  });
  tearDown(GetIt.instance.reset);

  testWidgets('yükleme sonrası boş vault "Henüz kod yok" gösterir',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => VaultCubit(_EmptyRepo())..load(),
          child: const VaultPage(),
        ),
      ),
    );
    await tester.pumpAndSettle(); // load() async → boş durum yerleşsin
    expect(find.text('Henüz kod yok'), findsOneWidget);
    expect(find.text('Ekle'), findsOneWidget);
  });
}
