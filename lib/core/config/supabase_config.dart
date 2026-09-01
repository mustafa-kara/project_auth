/// Supabase client configuration (Phase 3 Patch 1).
///
/// **Key policy (aligned with `supabase/PROJECT_INFO.md`):** the project URL and
/// the publishable key are supplied ONLY through `--dart-define`. Nothing is
/// embedded in the source — not even the dev project — so a build with missing
/// defines can never silently talk to the wrong Supabase project.
///
/// Run/build (debug and release alike):
/// ```
/// flutter run --dart-define-from-file=env/dev.json
/// flutter build apk --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
/// ```
/// See `env/dev.example.json` for the file shape.
///
/// The publishable key is low-privilege (public, protected by RLS) so shipping
/// it inside a build artifact is fine; **`sb_secret_...` is NEVER placed in the
/// client** (backend / Edge Function only).
library;

abstract final class SupabaseConfig {
  /// Supabase REST/Realtime/Auth API URL. Empty when the define is missing.
  static const String url = String.fromEnvironment('SUPABASE_URL');

  /// Publishable (public) key. Low-privilege; protected by RLS.
  /// The legacy `anonKey` is `@Deprecated` in 2.14.1 → use `publishableKey`.
  static const String publishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// Email confirmation (PKCE) deep-link callback. Matches the native
  /// intent-filter / URL scheme; registered in Supabase Dashboard → Auth →
  /// Redirect URLs.
  static const String authCallbackUrl =
      'dev.mustafakara.projectauth://login-callback';

  /// Deep-link custom scheme (must match the native config).
  static const String deepLinkScheme = 'dev.mustafakara.projectauth';

  /// Deep-link host (callback path component).
  static const String deepLinkHost = 'login-callback';

  /// Prefix of the current-generation publishable (public) API key.
  static const String publishableKeyPrefix = 'sb_publishable_';

  /// Fails fast when [url] / [publishableKey] were not passed as dart-defines.
  ///
  /// Called from `main()` BEFORE `Supabase.initialize`. Throws in debug as well
  /// as release: a debug build with no defines must not fall back to some
  /// developer's project.
  static void ensureConfigured() =>
      validate(url: url, publishableKey: publishableKey);

  /// Pure validator — no static state, so it is unit-testable.
  ///
  /// Throws a developer-facing [StateError] when a value is missing or
  /// malformed. ONLY the current `sb_publishable_...` key is accepted: legacy
  /// `eyJ...` JWTs are rejected because their shape (`eyJ` + three dot-separated
  /// segments) is identical for the anon key and the all-powerful `service_role`
  /// key — accepting it would let a service_role secret be shipped inside a
  /// client build. This project is publishable-key based (see
  /// `supabase/PROJECT_INFO.md`).
  static void validate({
    required String url,
    required String publishableKey,
  }) {
    if (url.isEmpty) {
      throw StateError(_message('SUPABASE_URL is missing'));
    }
    if (!url.startsWith('https://')) {
      throw StateError(
        _message('SUPABASE_URL must start with "https://" (got: "$url")'),
      );
    }
    if (publishableKey.isEmpty) {
      throw StateError(_message('SUPABASE_PUBLISHABLE_KEY is missing'));
    }
    if (!publishableKey.startsWith(publishableKeyPrefix)) {
      throw StateError(
        _message(
          'SUPABASE_PUBLISHABLE_KEY must start with "$publishableKeyPrefix" '
          '(legacy "eyJ..." JWT keys are rejected: an anon JWT and a '
          'service_role JWT are indistinguishable by shape)',
        ),
      );
    }
  }

  static String _message(String reason) =>
      'Supabase configuration error: $reason.\n'
      'Supabase credentials are not embedded in the source; pass them at '
      'build/run time:\n'
      '  flutter run --dart-define-from-file=env/dev.json\n'
      'or:\n'
      '  flutter run --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co '
      '--dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_...\n'
      'Copy env/dev.example.json to env/dev.json (git-ignored) and fill in the '
      'values from supabase/PROJECT_INFO.md.';
}
