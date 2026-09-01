/// `FilePickerDocumentPort` — picker cache temizliği (review takibi).
///
/// file_picker 11.0.3 seçilen dosyayı uygulamanın KENDİ cache'ine kopyalar
/// (iOS `NSTemporaryDirectory()`, Android `cacheDir/file_picker/`) ve SİLMEZ.
/// `withData: true` ile byte'lar zaten bellekte olduğundan bu kopya yalnız
/// gereksiz değil, kullanıcının secret'larının DÜZ METİN bir nüshasıdır →
/// `pickJson` her çıkışta `FilePicker.clearTemporaryFiles()` çağırmalı.
///
/// Eklenti gerçek bir platform kanalına konuştuğu için kanal test binding'i ile
/// sahtelenir: `pickFiles` → `any` metodu, `clearTemporaryFiles` → `clear`.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/import_export/data/file_picker_document_port.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  const port = FilePickerDocumentPort();

  /// Kanala gelen metot adları (sıralı).
  late List<String> calls;

  /// `any` (pickFiles) çağrısına verilecek yanıt; null → kullanıcı iptal etti.
  Object? pickResponse;

  /// Set edilirse `any` çağrısı bu hatayla düşer.
  PlatformException? pickError;

  /// `clear` çağrısı bu hatayla düşer (masaüstü/web'de UnimplementedError'a denk).
  PlatformException? clearError;

  List<Map<Object?, Object?>> onePick(String name, List<int> bytes) => [
        {
          'name': name,
          'size': bytes.length,
          'bytes': Uint8List.fromList(bytes),
          'path': null,
          'identifier': null,
        }
      ];

  setUp(() {
    calls = [];
    pickResponse = null;
    pickError = null;
    clearError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'clear':
          if (clearError != null) throw clearError!;
          return true;
        default:
          if (pickError != null) throw pickError!;
          return pickResponse;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('başarılı seçimden SONRA cache temizlenir', () async {
    pickResponse = onePick('yedek.json', utf8.encode('{"a":1}'));

    final doc = await port.pickJson(maxBytes: 1024);

    expect(doc, isNotNull);
    expect(doc!.name, 'yedek.json');
    expect(utf8.decode(doc.bytes), '{"a":1}');
    expect(calls, ['any', 'clear'],
        reason: 'byte\'lar alındıktan SONRA düz metin kopya silinmeli');
  });

  test('kullanıcı iptal ettiğinde de cache temizlenir', () async {
    pickResponse = null; // iptal

    expect(await port.pickJson(maxBytes: 1024), isNull);
    expect(calls, ['any', 'clear']);
  });

  test('boyut sınırı aşılınca (throw yolu) cache yine temizlenir', () async {
    pickResponse = onePick('kocaman.json', List<int>.filled(64, 0x7b));

    await expectLater(
      port.pickJson(maxBytes: 16),
      throwsA(isA<ImportFileTooLargeException>()),
    );
    expect(calls, ['any', 'clear'],
        reason: 'reddedilen dosyanın kopyası da diskte kalmamalı');
  });

  test('picker hata verirse de cache temizlenir', () async {
    pickError = PlatformException(code: 'unknown_path');

    await expectLater(port.pickJson(maxBytes: 1024), throwsA(anything));
    expect(calls, ['any', 'clear']);
  });

  test('temizlik hatası import\'u DÜŞÜRMEZ (masaüstü/web no-op)', () async {
    pickResponse = onePick('yedek.json', utf8.encode('{"a":1}'));
    clearError = PlatformException(code: 'unimplemented');

    final doc = await port.pickJson(maxBytes: 1024);

    expect(doc, isNotNull, reason: 'temizlik best-effort');
    expect(calls, ['any', 'clear']);
  });
}
