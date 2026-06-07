package dev.mustafakara.project_auth

import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth (Patch 5) biyometri prompt'u için FlutterFragmentActivity zorunlu
// (local_auth_android README). Düz FlutterActivity ile biyometri dialog'u crash eder.
class MainActivity : FlutterFragmentActivity()
