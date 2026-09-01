/// Hassas ekranlarda ekran görüntüsü / ekran kaydı / recents önizleme koruması.
///
/// **Android:** `WindowManager.LayoutParams.FLAG_SECURE` — screenshot/recording
/// engellenir, recents'te içerik karartılır.
/// **iOS:** FLAG_SECURE karşılığı yok → uygulama arka plana alınınca (resign
/// active) opak overlay ile recents snapshot'ı gizlenir; aktif olunca kaldırılır.
///
/// Yalnız HASSAS ekranlarda kullanılır (canlı OTP kodları, master parola girişi,
/// recovery key gösterimi/doğrulaması) — uygulama geneline uygulanmaz. Kapsam
/// dışı platformlarda (test, desktop) sessizce no-op.
///
/// ## Neden ref-count?
/// Native taraf sayaç TUTMAZ: Android `addFlags`/`clearFlags`, iOS bool bayrak →
/// **son çağıran kazanır**. Hassas ekranlar iç içe girebildiği için (ör. vault
/// üstünde recovery ekranı açılıp kapanır; vault hâlâ stack'te ve GÖRÜNÜR ama
/// dispose olmadığı için yeniden `enable` etmez) naif `initState`→enable /
/// `dispose`→disable kalıbı korumayı erken KAPATIR. Bu yüzden sayaç Dart
/// tarafında tutulur: yalnız 0→1 geçişinde native `enable`, yalnız 1→0
/// geçişinde native `disable` çağrılır. Native taraf değişmez.
///
/// Kullanım: sayfa ağacını [SecureScreenScope] ile sar — acquire/release
/// widget yaşam döngüsüne bağlanır, elle eşleştirme hatası olmaz.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract final class SecureScreen {
  static const MethodChannel _channel =
      MethodChannel('dev.mustafakara.project_auth/secure_screen');

  /// Şu an korumayı tutan aktif hassas ekran sayısı.
  static int _holders = 0;

  /// Native korumanın AÇIK olduğuna inandığımız durum. `enable` gönderilirken
  /// iyimser biçimde true yapılır; native çağrı [PlatformException] ile
  /// başarısız olursa false'a düşer. Sayaçtan ayrı tutulur çünkü tek başına
  /// sayaç 0→1 geçişi başarısız bir `enable`'dan sonra bir daha OLUŞMAZ →
  /// koruma sessizce kapalı kalırdı (review [P2]).
  static bool _nativeOn = false;

  /// Aktif tutucu sayısı (yalnız test/doğrulama için).
  @visibleForTesting
  static int get holderCount => _holders;

  /// Native korumanın açık kabul edilip edilmediği (yalnız test için).
  @visibleForTesting
  static bool get nativeOn => _nativeOn;

  /// Test izolasyonu: sayaçları sıfırla (native çağrısı YAPMAZ).
  ///
  /// Yalnız debug: release build'de koruma muhasebesi dışarıdan sıfırlanamaz.
  @visibleForTesting
  static void debugReset() {
    assert(kDebugMode, 'SecureScreen.debugReset() yalnız debug içindir');
    if (!kDebugMode) return;
    _holders = 0;
    _nativeOn = false;
  }

  /// Hassas ekran açıldı. İlk tutucuda (0→1) native koruma açılır.
  ///
  /// Ayrıca koruma AÇIK DEĞİLSE (önceki `enable` native tarafta hata aldı)
  /// sayaç 0→1 geçişi olmasa bile yeniden denenir — aksi hâlde ilk hata
  /// korumayı ekran ömrü boyunca kapalı bırakırdı.
  static void acquire() {
    _holders++;
    if (_holders == 1 || !_nativeOn) {
      // İyimser: aynı mikro-görevde arka arkaya gelen acquire'lar gereksiz
      // ikinci bir `enable` göndermesin (çağrı asenkron tamamlanır).
      _nativeOn = true;
      unawaited(_invoke('enable'));
    }
  }

  /// Hassas ekran kapandı. Son tutucu çıkınca (1→0) native koruma kapanır.
  ///
  /// Eşleşmeyen fazla `release` yok sayılır — sayaç negatife DÜŞMEZ (aksi hâlde
  /// sonraki `acquire` 0→1 geçişini kaçırıp korumayı hiç açmazdı).
  static void release() {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) {
      _nativeOn = false;
      unawaited(_invoke('disable'));
    }
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Test ortamı / desteklenmeyen platform → no-op. Kanal HİÇ yok; iyimser
      // durum korunur, yoksa her acquire boşuna yeniden denerdi.
    } on PlatformException {
      // Native taraf reddetti → koruma yoksa ekran yine çalışsın, ama durumu
      // "kapalı" işaretle ki sonraki acquire yeniden denesin.
      if (method == 'enable') _nativeOn = false;
    }
  }
}

/// Alt ağacı "hassas ekran" olarak işaretler: mount olunca [SecureScreen.acquire],
/// unmount olunca [SecureScreen.release] çağrılır.
///
/// Sayfanın `build`'inin EN DIŞINA konur; böylece koruma sayfanın tüm yaşam
/// döngüsü boyunca (üstüne başka route push edilse bile) açık kalır.
class SecureScreenScope extends StatefulWidget {
  const SecureScreenScope({super.key, required this.child});

  final Widget child;

  @override
  State<SecureScreenScope> createState() => _SecureScreenScopeState();
}

class _SecureScreenScopeState extends State<SecureScreenScope> {
  @override
  void initState() {
    super.initState();
    SecureScreen.acquire();
  }

  @override
  void dispose() {
    SecureScreen.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
