/// Kimlik (Supabase email/parola) repository arayüzü (Faz 3 Patch 1).
///
/// **iki kapı modeli:** bu katman YALNIZ Supabase oturumu (kimlik + sync taşıyıcı)
/// yönetir. Master parola / E2E vault kilidi AYRI (`VaultLockCubit`). İki parola
/// birbirini türetmez.
///
/// Güvenlik: `authStateChanges()` YALNIZ gerçek signedIn/signedOut taşır;
/// `emailConfirmPending` kalıcı oturum DEĞİL → `signUp` SONUCUNDAN (`SignUpOutcome`)
/// üretilir, stream'den değil (bkz. plan reviewer [P2]).
library;

/// `authStateChanges()` ve `current`'ın taşıdığı oturum durumu (gerçek oturum).
enum AuthSessionState {
  /// Geçerli Supabase oturumu var (e-posta onaylı + giriş yapılmış).
  signedIn,

  /// Oturum yok.
  signedOut,
}

/// `signUp` sonucu — e-posta onayı AÇIK iken `session=null` → [confirmPending].
enum SignUpOutcome {
  /// Onay maili gönderildi; kullanıcı linke tıklamalı (oturum henüz yok).
  confirmPending,

  /// Onay kapalıysa anında oturum açıldı.
  signedIn,
}

abstract interface class AuthRepository {
  /// Gerçek oturum değişimleri (signedIn/signedOut). **Ağ hataları stream ERROR
  /// olarak gelir; dinleyen `onError` VERMELİ** (gotrue 2.21.0 — yoksa app crash).
  /// Bu repo ağ hatasını [AuthNetworkError]'a map'leyip stream'e iletir.
  Stream<AuthSessionState> authStateChanges();

  /// Senkron ilk durum (`Supabase.instance.client.auth.currentSession`).
  AuthSessionState get current;

  /// Geçerli oturumun kullanıcı id'si (uid); oturum yoksa null. Multi-vault
  /// namespace + `linkRequired` hesabı için (Adım 3b).
  String? get currentUserId;

  /// Kayıt — e-posta onayı açıkken onay maili gönderir, [SignUpOutcome] döner.
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
  });

  /// Giriş — başarılıysa oturum açılır (`authStateChanges` signedIn yayar).
  Future<void> signIn({required String email, required String password});

  /// Çıkış — lokal oturum HER durumda temizlenir (ağ hatasında bile; gotrue local
  /// token'ı network çağrısından önce siler).
  Future<void> signOut();

  /// Onay mailini tekrar gönder.
  Future<void> resendConfirmation(String email);
}
