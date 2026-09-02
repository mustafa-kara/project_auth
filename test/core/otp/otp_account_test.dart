/// `OtpAccount`'un secret sızdırmayan `toString()` sözleşmesi (review takibi)
/// + Faz 5 Patch 3 `tags` sözleşmesinin temel kuralları (W1 genişletir).
///
/// Equatable'ın `stringify` alanı DEBUG derlemelerinde varsayılan olarak AÇIKtır
/// ve tüm `props`'u basar — `secret` dahil. Testler, widget ağacı dökümleri ve
/// assertion mesajları debug modda çalıştığı için bu, TOTP tohumunu CI log'una
/// düşürürdü. `stringify => false` bunu keser.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';

void main() {
  const secret = 'JBSWY3DPEHPK3PXP';

  OtpAccount account() => OtpAccount(
        id: 'tok-1',
        secret: secret,
        type: OtpType.totp,
        issuer: 'GitHub',
        accountName: 'alice@example.com',
      );

  test('toString() secret BASMAZ', () {
    expect(account().toString(), isNot(contains(secret)));
  });

  test('toString() bir liste/koleksiyon içinde de secret BASMAZ', () {
    // Bir hesap listesi interpolasyona girdiğinde her eleman toString()'e düşer.
    expect('${[account(), account()]}', isNot(contains(secret)));
  });

  test('eşitlik ve hashCode DEĞİŞMEZ (stringify yalnız toString\'i etkiler)',
      () {
    expect(account(), account());
    expect(account().hashCode, account().hashCode);
    expect(account(), isNot(account().copyWith(secret: 'GEZDGNBVGY3TQOJQ')));
  });

  group('tags (Faz 5 Patch 3)', () {
    test('varsayılan boş ve DEĞİŞTİRİLEMEZ', () {
      final a = account();
      expect(a.tags, isEmpty);
      expect(() => a.tags.add('iş'), throwsUnsupportedError);
    });

    test('normalizeTags: trim → boş at → 32 rune kırp → tekilleştir → ilk 8',
        () {
      // trim + boş atma
      expect(OtpAccount.normalizeTags(['  iş  ', '', '   ', 'ev']),
          ['iş', 'ev']);
      // tekilleştirme: İLK yazım kazanır, kullanıcı sırası korunur
      expect(OtpAccount.normalizeTags(['iş', 'ev', 'iş']), ['iş', 'ev']);
      // tavan: fazlası DÜŞER, fırlatmaz
      expect(
        OtpAccount.normalizeTags(
            List.generate(12, (i) => 'etiket$i')).length,
        OtpAccount.maxTags,
      );
      // 32 rune kırpma
      final long = 'a' * 40;
      expect(OtpAccount.normalizeTags([long]).single.runes.length,
          OtpAccount.maxTagRunes);
      // R12: kırpma sonrası eşitlenen iki etiket BİRLEŞİR (çift kayıt olmaz)
      expect(OtpAccount.normalizeTags(['${'a' * 32}bir', '${'a' * 32}iki']),
          ['a' * 32]);
      // R9: Türkçe İ/i tam eşleşme → ayrı etiketler
      expect(OtpAccount.normalizeTags(['İş', 'iş']), ['İş', 'iş']);
    });

    test('ctor normalize eder (asla fırlatmaz)', () {
      final a = OtpAccount(
        secret: secret,
        type: OtpType.totp,
        accountName: 'a@b.c',
        tags: ['  iş ', '', 'iş', 'ev'],
      );
      expect(a.tags, ['iş', 'ev']);
    });

    test('copyWith(tags:) değiştirir, const [] TEMİZLER', () {
      final tagged = account().copyWith(tags: ['iş']);
      expect(tagged.tags, ['iş']);
      expect(tagged.copyWith().tags, ['iş']); // null → korunur
      expect(tagged.copyWith(tags: const []).tags, isEmpty);
    });

    test('toJson: etiket yoksa "tags" anahtarı HİÇ yazılmaz (K2)', () {
      expect(account().toJson().containsKey('tags'), isFalse);
      expect(account().copyWith(tags: ['iş']).toJson()['tags'], ['iş']);
    });

    test('fromJson: eksik "tags" → boş liste, round-trip korunur', () {
      final json = account().toJson()..remove('tags');
      expect(OtpAccount.fromJson(json).tags, isEmpty);

      final tagged = account().copyWith(tags: ['iş', 'ev']);
      expect(OtpAccount.fromJson(tagged.toJson()), tagged);
    });

    test('fromJson: "tags" List değil / eleman String değil → FormatException',
        () {
      expect(
        () => OtpAccount.fromJson(account().toJson()..['tags'] = 'iş'),
        throwsFormatException,
      );
      expect(
        () => OtpAccount.fromJson(account().toJson()..['tags'] = [1, 2]),
        throwsFormatException,
      );
    });

    test('props: yalnız tags farkı EŞİTSİZLİK üretir (K3 / R2)', () {
      // Depo "değişmemiş blob" kısayolu buna dayanır
      // (encrypted_vault_repository.dart:219) — eşit sayılsalardı yalnız etiket
      // değiştiren bir düzenleme hiç şifrelenmez ve sessizce kaybolurdu.
      expect(account().copyWith(tags: ['iş']), isNot(account()));
      expect(account().copyWith(tags: ['iş']),
          account().copyWith(tags: ['iş']));
      expect(account().copyWith(tags: ['iş']),
          isNot(account().copyWith(tags: ['ev'])));
    });

    test('toString() etiketleri de BASMAZ (stringify kapalı)', () {
      expect(account().copyWith(tags: ['iş']).toString(), isNot(contains('iş')));
    });
  });
}
