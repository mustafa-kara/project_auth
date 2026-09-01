// SupabaseConfig.validate: dart-define'lar eksik/bozuksa fail-fast.

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/config/supabase_config.dart';

const _validUrl = 'https://abcdefghijklmnop.supabase.co';
const _validKey = 'sb_publishable_AbCdEf0123456789_xYz';
// Legacy anon JWT (imza gerçek değil; yalnız şekil doğrulanır).
const _legacyAnonJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiJ9.c2lnbmF0dXJl';
// Legacy service_role JWT — anon JWT ile ŞEKLEN aynı (eyJ + 3 segment).
const _legacyServiceRoleJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.c2ln';

void main() {
  group('SupabaseConfig.validate', () {
    test('geçerli url + publishable key kabul edilir', () {
      expect(
        () => SupabaseConfig.validate(url: _validUrl, publishableKey: _validKey),
        returnsNormally,
      );
    });

    test('legacy eyJ... JWT reddedilir (anon ve service_role ayırt edilemez)',
        () {
      // Şekil kontrolü (eyJ + 3 segment) service_role anahtarını da geçirirdi →
      // istemci build'ine tam yetkili sır sızabilirdi. Yalnız publishable geçerli.
      expect(
        () => SupabaseConfig.validate(
            url: _validUrl, publishableKey: _legacyAnonJwt),
        throwsA(isA<StateError>()),
      );
      expect(
        () => SupabaseConfig.validate(
            url: _validUrl, publishableKey: _legacyServiceRoleJwt),
        throwsA(isA<StateError>()),
      );
    });

    test('boş URL reddedilir', () {
      expect(
        () => SupabaseConfig.validate(url: '', publishableKey: _validKey),
        throwsA(isA<StateError>()),
      );
    });

    test('http:// URL reddedilir', () {
      expect(
        () => SupabaseConfig.validate(
            url: 'http://abcdefghijklmnop.supabase.co',
            publishableKey: _validKey),
        throwsA(isA<StateError>()),
      );
    });

    test('boş key reddedilir', () {
      expect(
        () => SupabaseConfig.validate(url: _validUrl, publishableKey: ''),
        throwsA(isA<StateError>()),
      );
    });

    test('yanlış prefix key reddedilir (secret key dahil)', () {
      expect(
        () => SupabaseConfig.validate(
            url: _validUrl, publishableKey: 'sb_secret_AbCdEf0123456789'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => SupabaseConfig.validate(
            url: _validUrl, publishableKey: 'not-a-key'),
        throwsA(isA<StateError>()),
      );
    });

    test('hata mesajı dart-define kullanımını anlatır', () {
      Object? caught;
      try {
        SupabaseConfig.validate(url: '', publishableKey: '');
      } catch (e) {
        caught = e;
      }
      final message = (caught! as StateError).message;
      expect(message, contains('--dart-define-from-file=env/dev.json'));
      expect(message, contains('--dart-define=SUPABASE_URL='));
      expect(message, contains('SUPABASE_PUBLISHABLE_KEY'));
    });
  });

  group('SupabaseConfig defaults', () {
    // Kaynağa gömülü fallback YOK: define'sız koşuda sabitler BOŞ kalmalı ve
    // ensureConfigured fail-fast etmeli. Suite define ile koşulursa (opsiyonel
    // mod) iddia geçersizleşir → dallanma yerine testi atla.
    const definesPresent = bool.hasEnvironment('SUPABASE_URL');
    test(
      'kaynağa gömülü fallback yok: sabitler boş, ensureConfigured fırlatır',
      () {
        expect(SupabaseConfig.url, isEmpty);
        expect(SupabaseConfig.publishableKey, isEmpty);
        expect(SupabaseConfig.ensureConfigured, throwsA(isA<StateError>()));
      },
      skip: definesPresent
          ? 'SUPABASE_* dart-define ile koşuluyor → boşluk iddiası geçersiz'
          : null,
    );
  });
}
