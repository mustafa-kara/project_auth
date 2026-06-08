/// Açılış splash'i (Faz 3 Patch 1) — SessionStatus.unknown boyunca gösterilir.
///
/// Bootstrap (Supabase oturum + vault kilit) tamamlanınca guard otomatik
/// yönlendirir. Vault `ShellRoute`'unun DIŞINDA (masterKey gerektirmez — reviewer [P1]).
library;

import 'package:flutter/material.dart';

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
