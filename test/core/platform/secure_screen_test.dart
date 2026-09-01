/// SecureScreen ref-count birim testleri.
///
/// Native taraf sayaç tutmaz (Android addFlags/clearFlags, iOS bool) → iç içe
/// hassas ekranlarda korumanın erken kapanmaması Dart sayacına bağlı. Burada
/// MethodChannel mock'lanır ve `enable`/`disable` çağrı SIRASI doğrulanır.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/platform/secure_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.mustafakara.project_auth/secure_screen');
  late List<String> calls;

  setUp(() {
    calls = [];
    SecureScreen.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SecureScreen.debugReset();
  });

  /// Kanal çağrıları async → mikro-görevleri boşalt.
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('tek acquire → enable; tek release → disable', () async {
    SecureScreen.acquire();
    await flush();
    expect(calls, ['enable']);
    expect(SecureScreen.holderCount, 1);

    SecureScreen.release();
    await flush();
    expect(calls, ['enable', 'disable']);
    expect(SecureScreen.holderCount, 0);
  });

  test('iki acquire + bir release → koruma AÇIK kalır; ikinci release → kapanır',
      () async {
    SecureScreen.acquire(); // ör. vault
    SecureScreen.acquire(); // ör. üstüne açılan recovery ekranı
    await flush();
    // Yalnız 0→1 geçişi native'e gider (idempotent değil, gereksiz çağrı yok).
    expect(calls, ['enable']);
    expect(SecureScreen.holderCount, 2);

    SecureScreen.release(); // recovery kapandı — vault hâlâ görünür
    await flush();
    expect(calls, ['enable'], reason: 'disable ERKEN çağrılmamalı');
    expect(SecureScreen.holderCount, 1);

    SecureScreen.release(); // vault da kapandı
    await flush();
    expect(calls, ['enable', 'disable']);
    expect(SecureScreen.holderCount, 0);
  });

  test('fazla release sayacı negatife düşürmez (sonraki acquire yine açar)',
      () async {
    SecureScreen.acquire();
    SecureScreen.release();
    SecureScreen.release(); // eşleşmeyen fazla release → yok sayılır
    SecureScreen.release();
    await flush();
    expect(SecureScreen.holderCount, 0);
    expect(calls, ['enable', 'disable'], reason: 'tek disable yeter');

    SecureScreen.acquire();
    await flush();
    expect(calls, ['enable', 'disable', 'enable'],
        reason: '0→1 geçişi kaçmamalı');
  });

  test('native enable HATA verirse sonraki acquire yeniden dener (review [P2])',
      () async {
    // İlk `enable` PlatformException ile düşer → sayaç 1'de kalır. Naif kodda
    // 0→1 geçişi bir daha olmadığı için koruma sessizce KAPALI kalırdı.
    var failNext = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (failNext && call.method == 'enable') {
        failNext = false;
        throw PlatformException(code: 'ERR', message: 'native reddetti');
      }
      return null;
    });

    SecureScreen.acquire(); // ör. vault
    await flush();
    expect(calls, ['enable']);
    expect(SecureScreen.nativeOn, isFalse, reason: 'native açılmadı');

    SecureScreen.acquire(); // ör. üstüne açılan hassas ekran → RETRY
    await flush();
    expect(calls, ['enable', 'enable'], reason: 'başarısız enable tekrarlanmalı');
    expect(SecureScreen.nativeOn, isTrue);
    expect(SecureScreen.holderCount, 2);

    SecureScreen.acquire(); // artık native AÇIK → tekrar çağrı YOK
    await flush();
    expect(calls, ['enable', 'enable'],
        reason: 'başarılı enable sonrası gereksiz çağrı olmamalı');
    expect(SecureScreen.holderCount, 3);
  });

  testWidgets('SecureScreenScope: mount → enable, unmount → disable',
      (tester) async {
    await tester.pumpWidget(
        const SecureScreenScope(child: SizedBox.shrink()));
    await tester.pump();
    expect(calls, ['enable']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls, ['enable', 'disable']);
    expect(SecureScreen.holderCount, 0);
  });
}
