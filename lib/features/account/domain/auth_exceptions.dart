/// Kimlik (Supabase) katmanı domain hataları (Faz 3 Patch 1).
///
/// `SupabaseAuthRepository` Supabase `AuthException` (`code`/`statusCode`/`message`)
/// ve ağ hatalarını bu tiplere eşler — UI yalnız domain hatalarını tanır, doğrudan
/// Supabase tiplerine bağımlı kalmaz.
///
/// ⚠️ Hata KODLARI gotrue 2.21.0 `error_code.dart` kaynağından alındı
/// (`email_not_confirmed`, `email_exists`, `user_already_exists`, `weak_password`,
/// `invalid_credentials`). Gerçek davranış implementasyonda cihaz/gerçek Supabase
/// ile teyit edilmeli (tahmine sabitlenmez).
library;

sealed class AuthError implements Exception {
  const AuthError(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// E-posta/parola eşleşmedi (`invalid_credentials`).
class AuthInvalidCredentials extends AuthError {
  const AuthInvalidCredentials([super.message = 'E-posta veya parola hatalı.']);
}

/// Hesap var ama e-posta onaylanmamış (`email_not_confirmed`).
class AuthEmailNotConfirmed extends AuthError {
  const AuthEmailNotConfirmed(
      [super.message = 'E-posta adresin henüz onaylanmadı.']);
}

/// Bu e-posta zaten kayıtlı (`email_exists` / `user_already_exists`).
class AuthEmailAlreadyInUse extends AuthError {
  const AuthEmailAlreadyInUse(
      [super.message = 'Bu e-posta zaten kayıtlı.']);
}

/// Parola politikası karşılanmadı (`weak_password`).
class AuthWeakPassword extends AuthError {
  const AuthWeakPassword([super.message = 'Parola çok zayıf.']);
}

/// Ağ/bağlantı hatası (`AuthRetryableFetchException` veya stream error).
class AuthNetworkError extends AuthError {
  const AuthNetworkError(
      [super.message = 'Bağlantı hatası. İnternetini kontrol et.']);
}

/// Eşleştirilemeyen diğer hatalar.
class AuthUnknownError extends AuthError {
  const AuthUnknownError([super.message = 'Beklenmeyen bir hata oluştu.']);
}
