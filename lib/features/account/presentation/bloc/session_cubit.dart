/// Supabase oturum durum makinesi (Faz 3 Patch 1) — kimlik kapısı.
///
/// **Vault'a dokunmaz** (ayrı kapı) — yalnız signOut'ta `onAuthSignedOut` callback'i
/// ile VaultLockCubit'in volatile state'ini temizletir. İki parola birbirini türetmez.
library;

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/pending_confirmation_store.dart';
import '../../domain/auth_exceptions.dart';
import '../../domain/auth_repository.dart';
import 'session_state.dart';

/// signedIn iken `SessionState.linkRequired`'ı hesaplayan kanca (Adım 3b doldurur).
/// `uid` = oturum kullanıcı id'si. Lokal storage'a bakar (legacy uid-siz vault var mı
/// + bu uid için karar verilmiş mi). Bootstrap/account-switch/link-kararı sonrası
/// çağrılıp senkron `SessionState.linkRequired`'a yazılır (reviewer [P2]).
typedef LinkRequiredResolver = Future<bool> Function(String uid);

class SessionCubit extends Cubit<SessionState> {
  SessionCubit({
    required AuthRepository auth,
    required PendingConfirmationStore pendingStore,
    LinkRequiredResolver? linkRequiredResolver,
    this.onAuthSignedOut,
  })  : _auth = auth,
        _pending = pendingStore,
        _linkRequiredResolver = linkRequiredResolver,
        super(const SessionState());

  final AuthRepository _auth;
  final PendingConfirmationStore _pending;
  final LinkRequiredResolver? _linkRequiredResolver;

  /// signOut'ta VaultLockCubit'i temizleten gevşek bağ (main.dart `_lock.onAuthSignedOut`).
  final void Function()? onAuthSignedOut;

  /// Geçerli oturumun uid'i (account-link ekranı için).
  String? get currentUid => _auth.currentUserId;

  StreamSubscription<AuthSessionState>? _sub;

  Future<void> bootstrap() async {
    // SIRA (reviewer [P2] — signedIn pending'i gölgelemesin): ÖNCE gerçek oturum.
    if (_auth.current == AuthSessionState.signedIn) {
      // Deep-link sonrası persist olmuş ama pending temizlenmeden kapanmış olabilir.
      await _pending.clear();
      await _emitSignedIn();
    } else {
      final pendingEmail = await _pending.read();
      if (pendingEmail != null && pendingEmail.isNotEmpty) {
        emit(SessionState(
            status: SessionStatus.emailConfirmPending, email: pendingEmail));
      } else {
        emit(const SessionState(status: SessionStatus.signedOut));
      }
    }

    // `onError` ZORUNLU (gotrue stream error → crash). Domain hatasına çevrilip
    // state'e yansır; oturum durumu korunur (hata transient).
    _sub = _auth.authStateChanges().listen(
      (s) async {
        if (s == AuthSessionState.signedIn) {
          await _pending.clear();
          await _emitSignedIn();
        } else {
          emit(state.copyWith(
              status: SessionStatus.signedOut,
              linkRequired: false,
              clearError: true,
              busy: false));
        }
      },
      onError: (Object e) {
        emit(state.copyWith(error: _asAuthError(e), busy: false));
      },
    );
  }

  Future<void> signUp({required String email, required String password}) async {
    emit(state.copyWith(busy: true, clearError: true));
    try {
      final outcome = await _auth.signUp(email: email, password: password);
      if (outcome == SignUpOutcome.confirmPending) {
        await _pending.write(email);
        emit(SessionState(
            status: SessionStatus.emailConfirmPending, email: email));
      } else {
        await _emitSignedIn();
      }
    } catch (e) {
      emit(state.copyWith(error: _asAuthError(e), busy: false));
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _auth.signIn(email: email, password: password);
      // signedIn `authStateChanges` üzerinden de gelir; yine de doğrudan emit.
      await _pending.clear();
      await _emitSignedIn();
    } catch (e) {
      final err = _asAuthError(e);
      // Onaysız e-posta ile giriş (reviewer [P2]): pending email'i PERSIST et +
      // emailConfirmPending'e geç → /auth/confirm ekranında email dolu olur ve
      // resend çalışır (yoksa email=null → resend no-op + kullanıcı sıkışırdı).
      if (err is AuthEmailNotConfirmed) {
        await _pending.write(email);
        emit(SessionState(
            status: SessionStatus.emailConfirmPending,
            email: email,
            error: err));
        return;
      }
      emit(state.copyWith(error: err, busy: false));
    }
  }

  Future<void> resend() async {
    final email = state.email;
    if (email == null) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _auth.resendConfirmation(email);
      emit(state.copyWith(busy: false));
    } catch (e) {
      emit(state.copyWith(error: _asAuthError(e), busy: false));
    }
  }

  /// "Farklı e-posta kullan" (reviewer [P2] — confirm trap çıkışı): pending'i
  /// temizle + signedOut → kullanıcı `/auth/login`'e döner.
  Future<void> cancelPendingConfirmation() async {
    await _pending.clear();
    emit(const SessionState(status: SessionStatus.signedOut));
  }

  /// Çıkış. Lokal vault temizliği (onAuthSignedOut) network signOut'tan ÖNCE; ağ
  /// hatası fırlatsa BİLE lokal oturum gitmiştir (gotrue local token'ı önce siler →
  /// #683) → HER durumda `signedOut` (asla `signedIn`'de kalma).
  Future<void> signOut() async {
    emit(state.copyWith(busy: true, clearError: true));
    onAuthSignedOut?.call(); // vault volatile temizliği ÖNCE
    AuthError? netError;
    try {
      await _auth.signOut();
    } catch (e) {
      netError = _asAuthError(e); // gösterilebilir; oturum yine de kapanır
    }
    await _pending.clear();
    emit(SessionState(status: SessionStatus.signedOut, error: netError));
  }

  /// signedIn emit + `linkRequired` hydrate (uid'e göre; resolver yoksa false).
  Future<void> _emitSignedIn() async {
    var link = false;
    final resolver = _linkRequiredResolver;
    final uid = _auth.currentUserId;
    if (resolver != null && uid != null) {
      try {
        link = await resolver(uid);
      } catch (_) {
        link = false; // resolver hatası login'i bloklamasın
      }
    }
    emit(SessionState(
        status: SessionStatus.signedIn, linkRequired: link, busy: false));
  }

  /// account-link kararı verildi (Adım 3b UI çağırır): `linkRequired` yeniden
  /// hesaplanır (artık false olmalı) → router refresh (reviewer [P3] köprü).
  Future<void> refreshLinkRequired() async {
    if (state.status != SessionStatus.signedIn) return;
    await _emitSignedIn();
  }

  AuthError _asAuthError(Object e) =>
      e is AuthError ? e : const AuthUnknownError();

  @override
  Future<void> close() {
    _sub?.cancel();
    return super.close();
  }
}
