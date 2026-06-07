/// Router redirect guard testleri — kilit durumuna göre yönlendirme (saf fonksiyon).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/router/app_router.dart';
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

    test('keyAttributesCorrupted → /auth-integrity', () {
      const s = VaultLockState.keyAttributesCorrupted();
      expect(guardRedirect(s, Routes.vault), Routes.authIntegrity);
      expect(guardRedirect(s, Routes.unlock), Routes.authIntegrity);
      expect(guardRedirect(s, Routes.authIntegrity), isNull);
    });
  });
}
