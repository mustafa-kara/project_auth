package dev.mustafakara.project_auth

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
    }
}
