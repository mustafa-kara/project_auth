/// SensitiveClipboard birim testleri (review [P2-4]).
///
/// Kanalın GERÇEKTEN çağrıldığı + argüman sözleşmesinin (`text`, `expiresInMs`)
/// native tarafın okuduğu adlarla eşleştiği burada pinlenir — native taraf Dart
/// analizinin göremediği yer olduğu için argüman adı sessizce kaymamalı.
/// Ayrıca kanal YOKKEN (host VM / web / desktop) düz `Clipboard.setData`'ya
/// düşüldüğü doğrulanır: kopyalama hiçbir platformda bozulmamalı.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/platform/sensitive_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'dev.mustafakara.project_auth/sensitive_clipboard',
  );
  // `Clipboard.setData` `flutter/platform` üzerinden gider ve o kanal
  // StandardMethodCodec DEĞİL JSONMethodCodec kullanır — mock kanalı aynı
  // codec'le kurulmazsa mesaj çözülemez ("Message corrupted").
  const platformChannel = MethodChannel('flutter/platform', JSONMethodCodec());

  late List<MethodCall> calls;
  late List<MethodCall> platformCalls;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls = [];
    platformCalls = [];
    // `Clipboard.setData` fallback'ini gözlemek için flutter/platform'u da mock'la.
    messenger.setMockMethodCallHandler(platformChannel, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(platformChannel, null);
  });

  void mockChannel({Object? Function(MethodCall call)? onCall}) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return onCall?.call(call);
    });
  }

  group('kanal varken', () {
    test('setText → metin + expiresInMs kanala geçer', () async {
      mockChannel();

      await SensitiveClipboard.setText(
        'correct horse battery staple',
        expiresIn: const Duration(seconds: 60),
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'setText');
      expect(calls.single.arguments, {
        'text': 'correct horse battery staple',
        'expiresInMs': 60000,
      });
      expect(
        platformCalls,
        isEmpty,
        reason: 'kanal başarılıysa düz Clipboard.setData ÇAĞRILMAMALI',
      );
    });

    test('expiresIn verilmezse expiresInMs anahtarı HİÇ gönderilmez', () async {
      mockChannel();

      await SensitiveClipboard.setText('123456');

      expect(calls.single.arguments, {'text': '123456'});
      expect(
        (calls.single.arguments as Map).containsKey('expiresInMs'),
        isFalse,
      );
    });

    test('45 sn → 45000 ms (Duration ms cinsinden serileşir)', () async {
      mockChannel();

      await SensitiveClipboard.setText(
        'x',
        expiresIn: const Duration(seconds: 45),
      );

      expect((calls.single.arguments as Map)['expiresInMs'], 45000);
    });
  });

  group('fallback', () {
    test(
      'MissingPluginException (host VM/web/desktop) → Clipboard.setData',
      () async {
        // Kanala HİÇ handler kurulmaz → MissingPluginException.
        await SensitiveClipboard.setText(
          'fallback words',
          expiresIn: const Duration(seconds: 60),
        );

        expect(calls, isEmpty);
        expect(platformCalls, hasLength(1));
        expect(platformCalls.single.method, 'Clipboard.setData');
        expect(
          (platformCalls.single.arguments as Map)['text'],
          'fallback words',
        );
      },
    );

    test(
      'native PlatformException → yine de kopyalanır (sessiz kayıp yok)',
      () async {
        mockChannel(onCall: (_) => throw PlatformException(code: 'bad_args'));

        await SensitiveClipboard.setText('still copied');

        expect(calls, hasLength(1));
        expect(platformCalls, hasLength(1));
        expect(platformCalls.single.method, 'Clipboard.setData');
        expect((platformCalls.single.arguments as Map)['text'], 'still copied');
      },
    );
  });
}
