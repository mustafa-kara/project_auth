/// Hassas ekranlarda ekran görüntüsü / ekran kaydı / recents önizleme koruması.
///
/// **Android:** `WindowManager.LayoutParams.FLAG_SECURE` — screenshot/recording
/// engellenir, recents'te içerik karartılır.
/// **iOS:** FLAG_SECURE karşılığı yok → uygulama arka plana alınınca (resign
/// active) opak overlay ile recents snapshot'ı gizlenir; aktif olunca kaldırılır.
///
/// Yalnız HASSAS ekranlarda kullanılır (ör. recovery key gösterimi/doğrulaması) —
/// uygulama geneline uygulanmaz. `enable()` ekran açılırken (initState),
/// `disable()` kapanırken (dispose) çağrılır. Kapsam dışı platformlarda (test,
/// desktop) sessizce no-op.
library;

import 'package:flutter/services.dart';

abstract final class SecureScreen {
  static const MethodChannel _channel =
      MethodChannel('dev.mustafakara.project_auth/secure_screen');

  /// Koruma aç. Hata/desteklenmeyen platform → sessiz (UX'i engellemez).
  static Future<void> enable() => _invoke('enable');

  /// Koruma kapat.
  static Future<void> disable() => _invoke('disable');

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Test ortamı / desteklenmeyen platform → no-op.
    } on PlatformException {
      // Native taraf reddetti (ör. desktop) → koruma yoksa ekran yine çalışsın.
    }
  }
}
