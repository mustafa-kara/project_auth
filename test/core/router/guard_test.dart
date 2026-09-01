/// Router redirect guard testleri — kilit durumuna göre yönlendirme (saf fonksiyon).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/router/app_router.dart';
import 'package:project_auth/features/account/presentation/bloc/session_state.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';

void main() {
  group('guardRedirect', () {
    test('uninitialized → /setup (zaten setup\'taysa null)', () {
      const s = VaultLockState.uninitialized();
      expect(guardRedirect(s, Routes.vault), Routes.setup);
      expect(guardRedirect(s, Routes.unlock), Routes.setup);
      expect(guardRedirect(s, Routes.setup), isNull);
    });

    test('uninitialized → setup ALT rotaları engellenir (mnemonic yok, review P1)',
        () {
      // mnemonic henüz üretilmedi (setupPending değiliz) → recovery-show/verify
      // boş listede RangeError'a yol açardı. Guard /setup'a geri yollar.
      const s = VaultLockState.uninitialized();
      expect(guardRedirect(s, Routes.recoveryShow), Routes.setup); // /setup/recovery
      expect(guardRedirect(s, Routes.recoveryVerify), Routes.setup); // /setup/verify
    });

    test('setupPending → yalnız setup alt-ağacı; verify /setup\'a zıplatılmaz', () {
      const s = VaultLockState.setupPending(mnemonic: []);
      expect(guardRedirect(s, Routes.vault), Routes.setup);
      expect(guardRedirect(s, Routes.unlock), Routes.setup);
      expect(guardRedirect(s, Routes.setup), isNull);
      expect(guardRedirect(s, Routes.recoveryShow), isNull); // /setup/recovery
      expect(guardRedirect(s, Routes.recoveryVerify), isNull); // /setup/verify
    });

    test('locked → /unlock; recovery ekranına izin', () {
      const s = VaultLockState.locked();
      expect(guardRedirect(s, Routes.vault), Routes.unlock);
      expect(guardRedirect(s, Routes.scan), Routes.unlock);
      expect(guardRedirect(s, Routes.unlock), isNull);
      expect(guardRedirect(s, Routes.recovery), isNull);
    });

    test('locking → locked gibi → /unlock (vault/scan kapanır)', () {
      const s = VaultLockState.locking();
      expect(guardRedirect(s, Routes.vault), Routes.unlock);
      expect(guardRedirect(s, Routes.scan), Routes.unlock);
      expect(guardRedirect(s, Routes.unlock), isNull);
    });

    test('unlocked → vault + scan + settings serbest; auth ekranlarından vault\'a dön',
        () {
      const s = VaultLockState.unlocked();
      expect(guardRedirect(s, Routes.vault), isNull);
      expect(guardRedirect(s, Routes.scan), isNull);
      expect(guardRedirect(s, Routes.settings), isNull); // Patch 5
      expect(guardRedirect(s, Routes.unlock), Routes.vault);
      expect(guardRedirect(s, Routes.setup), Routes.vault);
    });

    test('locked → /settings engellenir → /unlock (Patch 5)', () {
      const s = VaultLockState.locked();
      expect(guardRedirect(s, Routes.settings), Routes.unlock);
    });

    test('unlocked → /import + /export serbest (Faz 5 Patch 1)', () {
      const s = VaultLockState.unlocked();
      expect(guardRedirect(s, Routes.importData), isNull);
      expect(guardRedirect(s, Routes.exportData), isNull);
    });

    test('locked/locking → /import + /export engellenir → /unlock', () {
      // Token listesi ve şifreleme masterKey ister → kilitliyken açılmamalı.
      for (final s in const [
        VaultLockState.locked(),
        VaultLockState.locking(),
      ]) {
        expect(guardRedirect(s, Routes.importData), Routes.unlock);
        expect(guardRedirect(s, Routes.exportData), Routes.unlock);
      }
    });

    test('uninitialized → /import + /export → /setup', () {
      const s = VaultLockState.uninitialized();
      expect(guardRedirect(s, Routes.importData), Routes.setup);
      expect(guardRedirect(s, Routes.exportData), Routes.setup);
    });

    test('keyAttributesCorrupted → /auth-integrity', () {
      const s = VaultLockState.keyAttributesCorrupted();
      expect(guardRedirect(s, Routes.vault), Routes.authIntegrity);
      expect(guardRedirect(s, Routes.unlock), Routes.authIntegrity);
      expect(guardRedirect(s, Routes.authIntegrity), isNull);
    });

    test('restoring → /splash (ASLA /setup — review [P1] #1) + hedefte null', () {
      const s = VaultLockState.restoring();
      expect(guardRedirect(s, Routes.vault), Routes.splash);
      expect(guardRedirect(s, Routes.setup), Routes.splash); // setup'a DÜŞMEZ
      expect(guardRedirect(s, Routes.splash), isNull); // döngü yok
    });

    test('restoreFailed → /auth/restore-failed + hedefte null', () {
      const s = VaultLockState.restoreFailed();
      expect(guardRedirect(s, Routes.vault), Routes.authRestoreFailed);
      expect(guardRedirect(s, Routes.authRestoreFailed), isNull); // döngü yok
    });
  });

  group('sessionGuard (Faz 3 Patch 1 — kimlik kapısı)', () {
    const lockedVault = VaultLockState.locked();
    const unlockedVault = VaultLockState.unlocked();

    SessionState session(SessionStatus status, {bool linkRequired = false}) =>
        SessionState(status: status, linkRequired: linkRequired);

    test('unknown → /splash (vault shell\'e GİRMEZ, reviewer [P1])', () {
      final s = session(SessionStatus.unknown);
      expect(sessionGuard(s, lockedVault, Routes.vault), Routes.splash);
      expect(sessionGuard(s, lockedVault, Routes.authLogin), Routes.splash);
      expect(sessionGuard(s, lockedVault, Routes.splash), isNull);
    });

    test('signedOut → /auth/login (her korunan rota)', () {
      final s = session(SessionStatus.signedOut);
      expect(sessionGuard(s, lockedVault, Routes.vault), Routes.authLogin);
      expect(sessionGuard(s, lockedVault, Routes.unlock), Routes.authLogin);
      expect(sessionGuard(s, lockedVault, Routes.authLogin), isNull);
      expect(sessionGuard(s, lockedVault, Routes.authRegister), isNull);
      expect(sessionGuard(s, lockedVault, Routes.authConfirm), isNull);
    });

    test('signedOut + /auth/link → /auth/login (link public DEĞİL, reviewer [P2])',
        () {
      final s = session(SessionStatus.signedOut);
      expect(sessionGuard(s, lockedVault, Routes.authLink), Routes.authLogin);
    });

    test('emailConfirmPending → /auth/confirm (trap; login geri atılır)', () {
      final s = session(SessionStatus.emailConfirmPending);
      expect(sessionGuard(s, lockedVault, Routes.authConfirm), isNull);
      expect(sessionGuard(s, lockedVault, Routes.authLogin), Routes.authConfirm);
      expect(sessionGuard(s, lockedVault, Routes.vault), Routes.authConfirm);
    });

    test('signedIn + linkRequired → /auth/link (vault guard\'dan ÖNCE, bypass yok)',
        () {
      final s = session(SessionStatus.signedIn, linkRequired: true);
      expect(sessionGuard(s, unlockedVault, Routes.vault), Routes.authLink);
      expect(sessionGuard(s, unlockedVault, Routes.authLink), isNull);
      // /auth/link de isAuthRoute ama bypass edilmez (reviewer [P1]).
      expect(sessionGuard(s, lockedVault, Routes.authLogin), Routes.authLink);
    });

    test('signedIn + locked → /unlock (vault guard çalışır)', () {
      final s = session(SessionStatus.signedIn);
      expect(sessionGuard(s, lockedVault, Routes.vault), Routes.unlock);
      expect(sessionGuard(s, lockedVault, Routes.unlock), isNull);
    });

    test('signedIn + unlocked + /auth|/splash → vault (lock\'un istediği başlangıç)',
        () {
      final s = session(SessionStatus.signedIn);
      expect(sessionGuard(s, unlockedVault, Routes.vault), isNull);
      expect(sessionGuard(s, unlockedVault, Routes.authLogin), Routes.vault);
      expect(sessionGuard(s, unlockedVault, Routes.splash), Routes.vault);
    });

    // --- Faz 3 Patch 2: özel vault statüleri sessionGuard'da GERÇEK location'la
    // ele alınır → hedefteyken null (review [P1] location-kaybı; redirect-loop yok). ---
    group('Patch 2 — restoring/restoreFailed (location korunur)', () {
      const restoring = VaultLockState.restoring();
      const restoreFailed = VaultLockState.restoreFailed();
      const corrupted = VaultLockState.keyAttributesCorrupted();

      test('signedIn + restoring → /splash, hedefte null (ASLA /setup)', () {
        final s = session(SessionStatus.signedIn);
        expect(sessionGuard(s, restoring, Routes.vault), Routes.splash);
        expect(sessionGuard(s, restoring, Routes.setup), Routes.splash);
        // KRİTİK: /splash hedefindeyken null (yoksa rewrite loop yapardı).
        expect(sessionGuard(s, restoring, Routes.splash), isNull);
      });

      test('signedIn + restoreFailed → /auth/restore-failed, HEDEFTE NULL (loop yok)',
          () {
        final s = session(SessionStatus.signedIn);
        expect(sessionGuard(s, restoreFailed, Routes.vault),
            Routes.authRestoreFailed);
        expect(sessionGuard(s, restoreFailed, Routes.authLogin),
            Routes.authRestoreFailed);
        // KRİTİK (review [P1]): /auth/restore-failed auth route → eski kodda rewrite
        // gerçek location'ı kaybedip burada da hedef döndürürdü = loop. Artık null.
        expect(sessionGuard(s, restoreFailed, Routes.authRestoreFailed), isNull);
      });

      test('signedIn + keyAttributesCorrupted → /auth-integrity, HEDEFTE NULL (regresyon)',
          () {
        final s = session(SessionStatus.signedIn);
        expect(sessionGuard(s, corrupted, Routes.vault), Routes.authIntegrity);
        // /auth-integrity de "/auth" ile başlar → aynı location-kaybı bug'ı kapandı.
        expect(sessionGuard(s, corrupted, Routes.authIntegrity), isNull);
      });
    });
  });
}
