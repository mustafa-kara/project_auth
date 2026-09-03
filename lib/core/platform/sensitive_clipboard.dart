/// Hassas metinler için sertleştirilmiş pano yazımı (review [P2-4]).
///
/// `Clipboard.setData` platform tarafında **çıplak** genel panoya yazar:
///
/// **iOS:** `UIPasteboard.general` varsayılan olarak *Universal Clipboard*'a
/// katılır → kopyalanan değer aynı iCloud hesabındaki diğer Mac/iPad/iPhone'a
/// saniyeler içinde havadan geçer. 24 kelimelik recovery key için bu, cihazdan
/// çıkış demektir. `setItems(_:options:)` ile:
///   * `UIPasteboard.OptionsKey.localOnly` (Değer: NSNumber bool, iOS 10+) →
///     öge YALNIZ bu cihazda kalır, Universal Clipboard'a verilmez.
///   * `UIPasteboard.OptionsKey.expirationDate` (Değer: NSDate, iOS 10+) → OS
///     ögeyi bu tarihte kendisi düşürür; süreç öldürülse/donsa bile geçerlidir.
///  (Doğrulama: iPhoneSimulator SDK `UIKit/UIPasteboard.h` — `UIPasteboardOption`
///   NS_TYPED_ENUM, `NS_SWIFT_NAME(UIPasteboardOption.localOnly/.expirationDate)`.)
///
/// **Android:** birincil clip'i ön plandaki uygulama okuyabilir ve Android 13
/// (API 33) clipboard önizleme balonu içeriği EKRANDA gösterir. Önizlemeyi
/// gizleyen bayrak `ClipDescription.EXTRA_IS_SENSITIVE`
/// (= `"android.content.extra.IS_SENSITIVE"`, tip boolean, API 33+ —
/// doğrulama: Android SDK kaynağı `android/content/ClipDescription.java`).
/// Flutter'ın kendi `Clipboard` implementasyonu bunu KURMAZ. Android'de OS
/// düzeyinde pano süre sonu API'si YOKTUR → [expiresIn] orada yok sayılır;
/// süreye bağlı temizlik Dart tarafındaki koşullu timer'ın işidir
/// (`recovery_show_page.dart`, `otp_card.dart`).
///
/// Bu yüzden bu iki bayrak `SecureScreen` ile aynı kalıpta küçük bir platform
/// kanalına taşındı. Kanal yoksa (host VM testi, web, desktop) davranış ESKİYE
/// döner: düz `Clipboard.setData` — kopyalama hiçbir platformda BOZULMAZ.
///
/// ## Kapsam (dürüst sınır)
/// Bu, panoyu güvenli yapmaz. Ön plandaki uygulama Android'de birincil clip'i
/// hâlâ okuyabilir, iOS'ta yapıştırma hâlâ serbesttir ve panonun kendi
/// depolaması süreç dışındadır (CRYPTO.md §16.5 "OS kopyaları"). Kazanılan tek
/// şey **cihazdan çıkışın** (Universal Clipboard) ve **önizleme sızıntısının**
/// kapatılması, artı OS'un kendi zamanlayıcısıyla süre sonu — ki bu, süreç
/// öldüğünde çalışmayan Dart timer'ının tam olarak kaçırdığı durumdur.
library;

import 'package:flutter/services.dart';

abstract final class SensitiveClipboard {
  static const MethodChannel _channel = MethodChannel(
    'dev.mustafakara.project_auth/sensitive_clipboard',
  );

  /// [text]'i panoya yazar; mümkün olan platformlarda cihaz-yerel ve süreli.
  ///
  /// [expiresIn] verilirse iOS ögeye bir `expirationDate` iliştirir (OS kendi
  /// düşürür). Android'de karşılığı yoktur, yok sayılır — çağıranlar zaten
  /// kendi koşullu temizleme timer'larını KORUR, bu OS süre sonu onun yerine
  /// değil, ÜSTÜNE gelen ikinci bir savunmadır.
  static Future<void> setText(String text, {Duration? expiresIn}) async {
    try {
      await _channel.invokeMethod<void>('setText', <String, Object?>{
        'text': text,
        if (expiresIn != null) 'expiresInMs': expiresIn.inMilliseconds,
      });
    } on MissingPluginException {
      // Kanal HİÇ yok (host VM testi / web / desktop) → eski davranış.
      await _fallback(text);
    } on PlatformException {
      // Native taraf reddetti. Kullanıcı "kopyala"ya bastı; sessizce hiçbir şey
      // kopyalamamak sertleştirilmemiş kopyalamaktan DAHA kötü bir sürpriz olur
      // (kullanıcı yapıştırmayı dener, boş bulur, kelimeleri elle yazar).
      // Korumasız da olsa kopyala; çağıranın timer'ı yine temizler.
      await _fallback(text);
    }
  }

  static Future<void> _fallback(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
