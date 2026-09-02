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

    test('normalizeTags çıktısı da DEĞİŞTİRİLEMEZ', () {
      // Çağıran döneni saklayıp sonradan 9. etiketi itemesin.
      expect(() => OtpAccount.normalizeTags(['iş']).add('ev'),
          throwsUnsupportedError);
    });

    test('normalizeTags: kullanıcı SIRASI korunur (alfabetik sıralama YOK)', () {
      expect(OtpAccount.normalizeTags(['zeta', 'alfa', 'beta']),
          ['zeta', 'alfa', 'beta']);
    });

    test('normalizeTags: 8 tavanı DOLDUKTAN sonrası düşer, ilk 8 kalır', () {
      final many = List.generate(12, (i) => 'e$i');
      expect(OtpAccount.normalizeTags(many),
          [for (var i = 0; i < OtpAccount.maxTags; i++) 'e$i']);
    });

    test('normalizeTags: tekrarlar tavana SAYILMAZ (8 FARKLI etiket geçer)', () {
      // 'e0' üç kez yazılmış bir import dosyası 8 etiketin 6'sını harcamamalı.
      final raw = <String>['e0', 'e0', 'e0', for (var i = 1; i < 8; i++) 'e$i'];
      expect(OtpAccount.normalizeTags(raw), hasLength(OtpAccount.maxTags));
    });

    test('ctor: 40 karakterlik etiket 32 rune\'a kırpılır (import grup adı)', () {
      final a = account().copyWith(tags: ['g' * 40]);
      expect(a.tags.single, 'g' * OtpAccount.maxTagRunes);
    });

    test('ctor: emoji/birleşik karakter YARIDAN kesilmez (rune sayımı)', () {
      // 33 emoji → 32 emoji; UTF-16 birimiyle sayılsaydı son çift bozulurdu.
      final a = account().copyWith(tags: ['🔐' * 33]);
      expect(a.tags.single.runes.length, OtpAccount.maxTagRunes);
      expect(a.tags.single, '🔐' * OtpAccount.maxTagRunes);
    });

    test('fromJson: depodaki KİRLİ etiket listesi normalize edilir, atılmaz',
        () {
      // Eski/başka bir istemcinin yazdığı boşluklu-tekrarlı-uzun liste tek bir
      // bozuk kayıt yüzünden token'ı düşürmemeli (K4).
      final json = account().toJson()
        ..['tags'] = ['  iş ', 'iş', '', 'ev', 'g' * 40];
      final restored = OtpAccount.fromJson(json);
      expect(restored.tags, ['iş', 'ev', 'g' * OtpAccount.maxTagRunes]);
    });

    test('toJson: etiket SIRASI yazıldığı gibi korunur', () {
      final a = account().copyWith(tags: ['zeta', 'alfa']);
      expect(a.toJson()['tags'], ['zeta', 'alfa']);
      expect(OtpAccount.fromJson(a.toJson()).tags, ['zeta', 'alfa']);
    });

    test('props: etiket SIRASI da eşitliğe girer (liste derin karşılaştırma)',
        () {
      expect(account().copyWith(tags: ['iş', 'ev']),
          isNot(account().copyWith(tags: ['ev', 'iş'])));
    });

    test('tags DIŞINDA hiçbir alan etkilenmez (copyWith izolasyonu)', () {
      final tagged = account().copyWith(tags: ['iş']);
      expect(tagged.id, account().id);
      expect(tagged.secret, account().secret);
      expect(tagged.issuer, account().issuer);
      expect(tagged.accountName, account().accountName);
      expect(tagged.counter, account().counter);
    });
  });
}
