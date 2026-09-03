/// `OtpCard`'ın çözülmüş TOTP tohumunu nasıl tuttuğu (güvenlik denetimi P3-3).
///
/// `OtpAccount.secretBytes` bir GETTER'dır: her çağrıda `Base32.decode` çalışır ve
/// hem büyüyebilir bir `List<int>` hem de bir `Uint8List` kopyası üretir — hiçbiri
/// sıfırlanmadan. Kart saniyede bir yeniden hesapladığı için bu, ham tohumun
/// binlerce temizlenmemiş kopyasını yığına saçıyordu. Kart artık BİR KEZ çözer,
/// hesap değişince yeniler ve `dispose`'ta tamponu sıfırlar.
///
/// (libsodium gerekmez — `OtpGenerator` saf Dart.)
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/features/vault/presentation/widgets/otp_card.dart';

/// Karta verilen tohum tamponunun KİMLİĞİNİ kaydeden generator (gerçek hesabı
/// yapması gerekmez — test yalnız "hangi tampon geçildi"yi sorar).
class _RecordingGenerator extends OtpGenerator {
  _RecordingGenerator();

  final List<Uint8List> seen = [];

  @override
  String totp({
    required Uint8List secret,
    DateTime? time,
    int period = 30,
    int digits = 6,
    OtpAlgorithm algorithm = OtpAlgorithm.sha1,
  }) {
    seen.add(secret);
    return '123456';
  }

  @override
  String hotp({
    required Uint8List secret,
    required int counter,
    int digits = 6,
    OtpAlgorithm algorithm = OtpAlgorithm.sha1,
  }) {
    seen.add(secret);
    return '123456';
  }

  @override
  String steam({required Uint8List secret, DateTime? time, int period = 30}) {
    seen.add(secret);
    return 'ABCDE';
  }

  @override
  int secondsRemaining({DateTime? time, int period = 30}) => 17;
}

OtpAccount _acc(String secret) => OtpAccount(
  secret: secret,
  type: OtpType.totp,
  issuer: 'GitHub',
  accountName: 'octocat@example.com',
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 360, child: child)),
);

void main() {
  late _RecordingGenerator gen;

  setUp(() {
    gen = _RecordingGenerator();
    locator.registerSingleton<OtpGenerator>(gen);
  });
  tearDown(GetIt.instance.reset);

  testWidgets('tohum BİR KEZ çözülür — her tick AYNI tamponu kullanır', (
    tester,
  ) async {
    await tester.pumpWidget(_host(OtpCard(account: _acc('JBSWY3DPEHPK3PXP'))));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(
      gen.seen.length,
      greaterThanOrEqualTo(3),
      reason: 'initState + iki tick beklenir',
    );
    for (final buf in gen.seen) {
      expect(
        identical(buf, gen.seen.first),
        isTrue,
        reason: 'her tick yeniden decode ediyor (P3-3 gerilemesi)',
      );
    }

    // Test bitmeden timer'ı durdur.
    await tester.pumpWidget(_host(const SizedBox.shrink()));
  });

  testWidgets('hesap değişince YENİ tampon çözülür ve ESKİSİ sıfırlanır', (
    tester,
  ) async {
    await tester.pumpWidget(_host(OtpCard(account: _acc('JBSWY3DPEHPK3PXP'))));
    final first = gen.seen.first;
    expect(first.any((b) => b != 0), isTrue); // gerçekten dolu

    await tester.pumpWidget(_host(OtpCard(account: _acc('GEZDGNBVGY3TQOJQ'))));
    await tester.pump();

    expect(identical(gen.seen.last, first), isFalse); // yeni tampon
    expect(
      first.every((b) => b == 0),
      isTrue,
      reason: 'eski tohum tamponu sıfırlanmalı',
    );

    await tester.pumpWidget(_host(const SizedBox.shrink()));
  });

  testWidgets('dispose tamponu SIFIRLAR', (tester) async {
    await tester.pumpWidget(_host(OtpCard(account: _acc('JBSWY3DPEHPK3PXP'))));
    final buf = gen.seen.first;
    expect(buf.any((b) => b != 0), isTrue);

    await tester.pumpWidget(_host(const SizedBox.shrink())); // kart sökülür
    await tester.pump();

    expect(buf.every((b) => b == 0), isTrue);
  });
}
