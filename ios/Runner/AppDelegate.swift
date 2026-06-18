import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Hassas ekran koruması (SecureScreen). iOS'ta FLAG_SECURE yoktur → uygulama
  // arka plana alınınca (resign active) opak overlay ile recents snapshot'ı
  // gizlenir; yalnız hassas ekran açıkken (Dart enable/disable) uygulanır.
  private var secureScreenEnabled = false
  private var privacyOverlay: UIView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "dev.mustafakara.project_auth/secure_screen",
        binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "enable":
          self?.secureScreenEnabled = true
          result(nil)
        case "disable":
          self?.secureScreenEnabled = false
          self?.removePrivacyOverlay()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard secureScreenEnabled, let window = window, privacyOverlay == nil else { return }
    let overlay = UIView(frame: window.bounds)
    overlay.backgroundColor = .black
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(overlay)
    privacyOverlay = overlay
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    removePrivacyOverlay()
  }

  private func removePrivacyOverlay() {
    privacyOverlay?.removeFromSuperview()
    privacyOverlay = nil
  }
}
