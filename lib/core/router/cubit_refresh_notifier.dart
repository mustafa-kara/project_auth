/// Bloc/Cubit `Stream`'ini go_router `refreshListenable` için bir [Listenable]'a
/// köprüler.
///
/// **Neden gerekli:** `Cubit` doğrudan `Listenable` DEĞİL; go_router
/// `refreshListenable: Listenable?` bekler. Paketin eski `GoRouterRefreshStream`
/// yardımcısı **go_router 17.x'te kaldırıldı** (CHANGELOG "Removes
/// GoRouterRefreshStream") → kendi ~15 satırlık adapter'ımız.
///
/// **Sahiplik:** go_router refreshListenable'ı dispose ETMEZ (yalnız add/remove
/// Listener). Bu yüzden [dispose] çağrısı ÇAĞIRANIN sorumluluğundadır (router'ı
/// tutan kök widget; bkz. `AppRouterBundle`).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

class CubitRefreshNotifier extends ChangeNotifier {
  late final StreamSubscription<dynamic> _sub;

  CubitRefreshNotifier(Stream<dynamic> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
