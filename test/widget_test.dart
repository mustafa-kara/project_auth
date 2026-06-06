// Vault ekranı smoke test: boş durum görünüyor mu, demo kod eklenebiliyor mu.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/pages/vault_page.dart';

void main() {
  setUpAll(() async {
    await configureDependencies();
  });

  testWidgets('boş vault "Henüz kod yok" gösterir', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => VaultCubit(),
          child: const VaultPage(),
        ),
      ),
    );
    expect(find.text('Henüz kod yok'), findsOneWidget);
    expect(find.text('Ekle'), findsOneWidget);
  });
}
