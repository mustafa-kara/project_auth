package dev.mustafakara.project_auth

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth (Patch 5) biyometri prompt'u için FlutterFragmentActivity zorunlu
// (local_auth_android README). Düz FlutterActivity ile biyometri dialog'u crash eder.
class MainActivity : FlutterFragmentActivity() {

    // Hassas ekran koruması (SecureScreen): FLAG_SECURE → screenshot/recording
    // engellenir, recents'te içerik karartılır. Yalnız hassas ekranlarda açılır.
    private val secureChannel = "dev.mustafakara.project_auth/secure_screen"

    // Hassas pano yazımı (SensitiveClipboard, review [P2-4]): clip'i
    // EXTRA_IS_SENSITIVE ile işaretler → Android 13+ pano önizleme balonu
    // içeriği EKRANDA GÖSTERMEZ. Flutter'ın kendi Clipboard'ı bunu kurmaz.
    private val clipboardChannel = "dev.mustafakara.project_auth/sensitive_clipboard"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> {
                        runOnUiThread {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "disable" -> {
                        runOnUiThread {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, clipboardChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setText" -> {
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("bad_args", "text is required", null)
                        } else {
                            // NOT: `expiresInMs` Android'de YOK SAYILIR — OS
                            // düzeyinde pano süre sonu API'si yoktur (iOS'ta
                            // UIPasteboard.expirationDate var). Süreye bağlı
                            // temizlik Dart tarafındaki koşullu timer'da kalır.
                            setSensitiveClip(text)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun setSensitiveClip(text: String) {
        // Etiket boş: ClipDescription.label bazı launcher/IME önizlemelerinde
        // gösterilir; içeriğe dair hiçbir ipucu vermeyelim.
        val clip = ClipData.newPlainText("", text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        manager.setPrimaryClip(clip)
    }
}
