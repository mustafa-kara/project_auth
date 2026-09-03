/// AAD kodlaması: `utf8.encode` ile `String.codeUnits` BAYT-BİREBİR aynı mı?
/// (Güvenlik denetimi P3-6.)
///
/// `KeyManager._aad` ve `EncryptedVaultRepository._aad` eskiden `codeUnits`
/// kullanıyordu. Bu, UTF-16 birimlerini 8 bite KIRPAR: ASCII olmayan tek bir
/// karakter sessizce yanlış (ve çakışabilir) bir AAD üretirdi. `utf8.encode`'a
/// geçiş yalnız uygulamanın ÜRETTİĞİ her AAD ASCII ise geriye dönük uyumludur —
/// aksi hâlde eski blob'lar çözülemez hâle gelirdi. Bu dosya tam olarak bunu
/// kanıtlar; kırmızıya dönerse geçiş GERİ ALINMALI ya da bir göç yazılmalıdır.
///
/// Uygulamanın ürettiği AAD'lerin TAMAMI:
///   1. `KeyManager.aadStrings` — üç sabit (masterkey-kek/recovery/biometric).
///   2. `EncryptedVaultRepository.aadPrefix` + token id → `token|1|<uuid v4>`.
///      Lokalde id'nin TEK üreticisi `OtpAccount`'un `Uuid().v4()` varsayılanıdır
///      (import parser'ları kaynak uuid'lerini kasıtlı olarak yeniden üretir);
///      sunucuda `tokens.id` Postgres `uuid` sütunudur, yani ASCII olmayan bir id
///      sync'ten de GEÇEMEZ.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';
import 'package:project_auth/features/vault/data/encrypted_vault_repository.dart';

/// uuid v4 (RFC 4122): yalnız hex + tire → tanım gereği ASCII.
final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void _expectSameBytes(String aad) {
  expect(
    utf8.encode(aad),
    aad.codeUnits,
    reason:
        '"$aad" iki kodlamada FARKLI bayt üretiyor → AAD değişimi blob\'ları '
        'çözülemez yapardı',
  );
  expect(
    aad.codeUnits.every((u) => u < 128),
    isTrue,
    reason: '"$aad" ASCII değil',
  );
}

void main() {
  test('KeyManager\'ın üç AAD sabiti: utf8.encode == codeUnits', () {
    expect(KeyManager.aadStrings, hasLength(3)); // yeni sabit eklenirse düşsün
    for (final s in KeyManager.aadStrings) {
      _expectSameBytes(s);
    }
  });

  test('token AAD prefix\'i ASCII', () {
    _expectSameBytes(EncryptedVaultRepository.aadPrefix);
  });

  test('token AAD (prefix + üretilen id): id uuid v4 + kodlamalar AYNI', () {
    for (var i = 0; i < 200; i++) {
      final id = OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        accountName: 'a@b.c',
      ).id;
      expect(
        _uuidV4.hasMatch(id),
        isTrue,
        reason:
            'üretilen token id\'si uuid v4 olmalı (ASCII garantisi) — "$id"',
      );
      _expectSameBytes('${EncryptedVaultRepository.aadPrefix}$id');
    }
  });

  test('KARŞI ÖRNEK: ASCII olmayan bir dizgede iki kodlama AYRIŞIR', () {
    // Testin gerçekten bir şey ölçtüğünün kanıtı — 'ş' UTF-8'de iki bayt,
    // codeUnits'te tek bir 16-bit birim (0x015F) olarak kalır.
    const nonAscii = 'token|1|şaşırtıcı';
    expect(utf8.encode(nonAscii), isNot(nonAscii.codeUnits));
  });
}
