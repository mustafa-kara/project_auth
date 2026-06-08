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

abstract final class SupabaseConfig {
  /// Supabase REST/Realtime/Auth API URL'i.
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://vfyqokvgtdxxurroqbtj.supabase.co',
  );

  /// Publishable (anon/public) anahtar. Düşük yetkili; RLS koruması var.
  /// Eski `anonKey` 2.14.1'de `@Deprecated` → `publishableKey` kullanılır.
  static const String publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_rxrL2mVbh1XgojMexy1cMw_Og8wE3xI',
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
