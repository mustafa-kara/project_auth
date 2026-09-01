// SupabaseConfig.validate: dart-define'lar eksik/bozuksa fail-fast.

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/config/supabase_config.dart';

const _validUrl = 'https://abcdefghijklmnop.supabase.co';
const _validKey = 'sb_publishable_AbCdEf0123456789_xYz';
// Legacy anon JWT (imza gerçek değil; yalnız şekil doğrulanır).
const _legacyAnonJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiJ9.c2lnbmF0dXJl';

void main() {
  group('SupabaseConfig.validate', () {
    test('geçerli url + publishable key kabul edilir', () {
      expect(
        () => SupabaseConfig.validate(url: _validUrl, publishableKey: _validKey),
        returnsNormally,
      );
    });

    test('legacy eyJ... anon JWT kabul edilir', () {
      expect(
        () => SupabaseConfig.validate(
            url: _validUrl, publishableKey: _legacyAnonJwt),
        returnsNormally,
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
    // `flutter test` normalde define'sız koşar → sabitler boş olmalı (kaynağa
    // gömülü fallback YOK). Define ile koşulursa (CI seçeneği) doğrulama geçer.
    test('define yoksa boş kalır ve ensureConfigured fırlatır', () {
      if (SupabaseConfig.url.isEmpty) {
        expect(SupabaseConfig.publishableKey, isEmpty);
        expect(SupabaseConfig.ensureConfigured, throwsA(isA<StateError>()));
      } else {
        expect(SupabaseConfig.ensureConfigured, returnsNormally);
      }
    });
  });
}
