/// [AuthRepository]'nin Supabase implementasyonu (Faz 3 Patch 1).
///
/// Supabase `AuthException` / ağ hatalarını domain [AuthError]'lara map'ler.
/// `onAuthStateChange` STREAM ERROR fırlatabilir (gotrue 2.21.0 `gotrue_client.dart:79`)
/// → `authStateChanges()` `handleError` ile bunu yakalayıp [AuthNetworkError] olarak
/// iletir (UI'da `onError` ile crash önlenir).
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../domain/auth_exceptions.dart';
import '../domain/auth_repository.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  @override
  AuthSessionState get current => _auth.currentSession != null
      ? AuthSessionState.signedIn
      : AuthSessionState.signedOut;

  @override
  String? get currentUserId => _auth.currentUser?.id;

  @override
  Stream<AuthSessionState> authStateChanges() {
    return _auth.onAuthStateChange
        .map(
          (state) => state.session != null
              ? AuthSessionState.signedIn
              : AuthSessionState.signedOut,
        )
        // Ağ hatası stream error olarak gelir; domain hatasına çevirip iletilir.
        // Dinleyen (SessionCubit) `onError` vermeli — yine de burada da map'lenir.
        .handleError((Object e) {
          throw _mapError(e);
        });
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
  }) async {
    try {
      final res = await _auth.signUp(
        email: email,
        password: password,
        emailRedirectTo: SupabaseConfig.authCallbackUrl,
      );
      // E-posta onayı açıkken session=null → onay bekliyor.
      return res.session != null
          ? SignUpOutcome.signedIn
          : SignUpOutcome.confirmPending;
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    try {
      await _auth.signInWithPassword(email: email, password: password);
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<void> signOut() async {
    // Kullanıcı kararı: GLOBAL revoke — sunucuda tüm cihazların refresh-token'ları
    // geçersiz kılınır ("tüm cihazlardan çıkış"). gotrue yine de lokal accessToken'ı
    // network çağrısından ÖNCE siler → ağ hatası fırlatsa bile oturum LOKALDE gitmiştir
    // (offline garantisi korunur). Hata domain'e map'lenip iletilir; SessionCubit
    // `signedOut`'u HER durumda garanti eder (revoke gerçekleşmese de cihaz çıkış yapar).
    try {
      await _auth.signOut(scope: SignOutScope.global);
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<void> resendConfirmation(String email) async {
    try {
      await _auth.resend(
        type: OtpType.signup,
        email: email,
        emailRedirectTo: SupabaseConfig.authCallbackUrl,
      );
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// Supabase/ağ hatasını domain [AuthError]'a eşler.
  ///
  /// ⚠️ Kodlar gotrue 2.21.0 `error_code.dart`'tan; gerçek davranış cihazda teyit
  /// edilmeli. Tanınmayan kod → mesaj-temelli kaba eşleme → son çare [AuthUnknownError].
  AuthError _mapError(Object e) {
    if (e is AuthError) return e; // zaten map'lenmiş
    if (e is AuthRetryableFetchException) {
      return const AuthNetworkError();
    }
    if (e is AuthException) {
      // AuthApiException dahil tüm alt tipler buraya düşer (extends AuthException).
      final ex = e;
      switch (ex.code) {
        case 'email_not_confirmed':
          return const AuthEmailNotConfirmed();
        case 'invalid_credentials':
          return const AuthInvalidCredentials();
        case 'email_exists':
        case 'user_already_exists':
          return const AuthEmailAlreadyInUse();
        case 'weak_password':
          return const AuthWeakPassword();
      }
      // Kod yoksa/tanınmıyorsa mesaja bak (server bazen yalnız mesaj döndürür).
      final msg = ex.message.toLowerCase();
      if (msg.contains('not confirmed') || msg.contains('not been confirmed')) {
        return const AuthEmailNotConfirmed();
      }
      if (msg.contains('already registered') ||
          msg.contains('already exists')) {
        return const AuthEmailAlreadyInUse();
      }
      if (msg.contains('invalid login') ||
          msg.contains('invalid credentials')) {
        return const AuthInvalidCredentials();
      }
      return AuthUnknownError(ex.message);
    }
    return const AuthUnknownError();
  }
}
