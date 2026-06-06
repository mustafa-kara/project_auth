import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/di/locator.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/vault/presentation/bloc/vault_cubit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();
  // Faz 3: await Supabase.initialize(url:, publishableKey:) burada eklenecek.
  runApp(const AuthenticatorApp());
}

class AuthenticatorApp extends StatelessWidget {
  const AuthenticatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => VaultCubit(),
      child: MaterialApp.router(
        title: 'Authenticator',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: appRouter,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
