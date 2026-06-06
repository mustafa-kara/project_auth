/// VaultCubit testleri — id-bazlı silme/sayaç artırma doğruluğu.
///
/// Index yerine stabil `id` kullanımı, liste değiştiğinde yanlış öğeye
/// dokunulmamasını garanti eder (B1/B2 düzeltmesinin davranışsal kanıtı).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

OtpAccount _acc(String name, {OtpType type = OtpType.totp, int counter = 0}) =>
    OtpAccount(
      secret: 'JBSWY3DPEHPK3PXP',
      type: type,
      accountName: name,
      counter: counter,
    );

void main() {
  group('VaultCubit', () {
    test('add token listeye ekler ve stabil id atar', () {
      final cubit = VaultCubit();
      final a = _acc('a');
      cubit.add(a);
      expect(cubit.state.accounts.single.id, a.id);
    });

    test('removeById doğru token\'ı siler (index kaymasından etkilenmez)', () {
      final cubit = VaultCubit();
      final a = _acc('a'), b = _acc('b'), c = _acc('c');
      cubit
        ..add(a)
        ..add(b)
        ..add(c);
      // Ortadakini sil — id ile; kalanlar a ve c olmalı, sıra korunur.
      cubit.removeById(b.id);
      expect(cubit.state.accounts.map((e) => e.id), [a.id, c.id]);
    });

    test('removeById bilinmeyen id\'de state değiştirmez', () {
      final cubit = VaultCubit();
      final a = _acc('a');
      cubit.add(a);
      final before = cubit.state;
      cubit.removeById('yok-böyle-id');
      expect(cubit.state, same(before));
    });

    test('incrementCounter yalnız hedef HOTP token\'ın sayacını artırır', () {
      final cubit = VaultCubit();
      final h1 = _acc('h1', type: OtpType.hotp, counter: 0);
      final h2 = _acc('h2', type: OtpType.hotp, counter: 5);
      cubit
        ..add(h1)
        ..add(h2);
      cubit.incrementCounter(h2.id);
      final byId = {for (final a in cubit.state.accounts) a.id: a};
      expect(byId[h1.id]!.counter, 0); // dokunulmadı
      expect(byId[h2.id]!.counter, 6); // hedef arttı
    });

    test('incrementCounter TOTP\'ta no-op (HOTP değilse)', () {
      final cubit = VaultCubit();
      final t = _acc('t', type: OtpType.totp);
      cubit.add(t);
      cubit.incrementCounter(t.id);
      expect(cubit.state.accounts.single.counter, 0);
    });
  });
}
