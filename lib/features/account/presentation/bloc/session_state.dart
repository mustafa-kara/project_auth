/// Supabase oturum durumu (Faz 3 Patch 1) — kimlik kapısı.
library;

import 'package:equatable/equatable.dart';

import '../../domain/auth_exceptions.dart';

enum SessionStatus {
  /// bootstrap bitmeden önceki ilk an → router `/splash` gösterir (redirect YOK).
  unknown,

  /// Oturum yok → `/auth/login`.
  signedOut,

  /// Kayıt yapıldı, e-posta onayı bekleniyor (kalıcı; persist edilir) → `/auth/confirm`.
  emailConfirmPending,

  /// Geçerli oturum → vault akışı (setup/unlock/vault).
  signedIn,
}

class SessionState extends Equatable {
  const SessionState({
    this.status = SessionStatus.unknown,
    this.email,
    this.error,
    this.linkRequired = false,
    this.busy = false,
  });

  final SessionStatus status;

  /// emailConfirmPending'de bekleyen e-posta (UI'da gösterilir).
  final String? email;

  /// Son işlem hatası (giriş/kayıt/çıkış) — UI inline gösterir; bir sonraki
  /// başarılı işlemde temizlenir.
  final AuthError? error;

  /// **HYDRATED senkron alan (reviewer [P2]):** signedIn + bu cihazda uid-siz Faz2
  /// vault var + bu uid için legacy kararı YOK → `/auth/link` gerekir. Router bu
  /// senkron bool'u okur (async storage'a guard içinde dokunmaz). SessionCubit
  /// bootstrap/account-switch/link-kararı sonrası yeniden hesaplayıp emit eder.
  final bool linkRequired;

  /// Async işlem (signIn/signUp/signOut) sürüyor mu → UI buton disabled + spinner.
  final bool busy;

  SessionState copyWith({
    SessionStatus? status,
    String? email,
    AuthError? error,
    bool clearError = false,
    bool? linkRequired,
    bool? busy,
  }) =>
      SessionState(
        status: status ?? this.status,
        email: email ?? this.email,
        error: clearError ? null : (error ?? this.error),
        linkRequired: linkRequired ?? this.linkRequired,
        busy: busy ?? this.busy,
      );

  @override
  List<Object?> get props => [status, email, error, linkRequired, busy];
}
