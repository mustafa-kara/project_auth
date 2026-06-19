/// Supabase istemci yapılandırması (Faz 3 Patch 1).
///
/// **Anahtar gömme politikası (`PROJECT_INFO.md` ile hizalı):** değerler
/// `--dart-define` ile geçilir; geliştirme kolaylığı için canlı `authenticator-dev`
/// dev değerleri fallback olarak gömülüdür. `publishableKey` düşük yetkili (anon/public,
/// RLS arkasında) olduğu için gömülebilir; **`sb_secret_...` ASLA client'a konmaz**
/// (yalnız backend / Edge Function).
///
/// Prod/CI build:
/// ```
/// flutter build apk --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
/// ```
library;

import 'package:flutter/foundation.dart' show kReleaseMode;

abstract final class SupabaseConfig {
  // The dev `authenticator-dev` fallbacks are convenience for debug/profile only.
  // In RELEASE builds the fallback is EMPTY so a forgotten `--dart-define` fails
  // loudly (Supabase.initialize throws on an empty URL) instead of silently
  // routing real users' auth/data traffic to the dev project.
  static const String _devUrl = 'https://vfyqokvgtdxxurroqbtj.supabase.co';
  static const String _devPublishableKey =
      'sb_publishable_rxrL2mVbh1XgojMexy1cMw_Og8wE3xI';

  /// Supabase REST/Realtime/Auth API URL.
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: kReleaseMode ? '' : _devUrl,
  );

  /// Publishable (anon/public) key. Low-privilege; protected by RLS.
  /// The legacy `anonKey` is `@Deprecated` in 2.14.1 → use `publishableKey`.
  static const String publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: kReleaseMode ? '' : _devPublishableKey,
  );

  /// E-posta onayı (PKCE) deep-link callback'i. Native intent-filter / URL scheme
  /// ile eşleşir; Supabase Dashboard → Auth → Redirect URLs'e eklenir.
  static const String authCallbackUrl =
      'dev.mustafakara.projectauth://login-callback';

  /// Deep-link custom scheme (native config ile aynı olmalı).
  static const String deepLinkScheme = 'dev.mustafakara.projectauth';

  /// Deep-link host (callback path bileşeni).
  static const String deepLinkHost = 'login-callback';
}
