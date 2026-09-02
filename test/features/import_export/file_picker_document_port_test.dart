/// `FilePickerDocumentPort` — picker cache temizliği (review takibi).
///
/// file_picker 11.0.3 seçilen dosyayı uygulamanın KENDİ cache'ine kopyalar
/// (iOS `NSTemporaryDirectory()`, Android `cacheDir/file_picker/`) ve SİLMEZ.
/// `withData: true` ile byte'lar zaten bellekte olduğundan bu kopya yalnız
/// gereksiz değil, kullanıcının secret'larının DÜZ METİN bir nüshasıdır →
/// `pickJson` her çıkışta `FilePicker.clearTemporaryFiles()` çağırmalı.
///
/// AYRICA (denetim C1): `saveFile` iOS'ta dosyayı önce
/// `NSDocumentDirectory/<fileName>` altına yazar, oradan DIŞA AKTARIR ve o
/// nüshayı hiçbir yolda silmez (`FilePickerPlugin.m` `saveFileWithName:`);
/// `clearTemporaryFiles` yalnız `NSTemporaryDirectory()`'yi gezdiği için o
/// dosya iCloud yedeğine girecek şekilde kalır → `saveJson` onu kendisi
/// sıfırlayıp siler. iOS tespiti ve dizin sağlayıcı enjekte edilebilir
/// olduğundan burada geçici bir dizinle doğrulanır.
///
/// Eklenti gerçek bir platform kanalına konuştuğu için kanal test binding'i ile
/// sahtelenir: `pickFiles` → `any` metodu, `clearTemporaryFiles` → `clear`.
library;

import 'dart:convert';
import 'dart:io';

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

  /// `save` çağrısının döndürdüğü yol; null → kullanıcı iptal etti.
  String? saveResponse;

  /// Set edilirse `save` çağrısı bu hatayla düşer.
  PlatformException? saveError;

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
    saveResponse = null;
    saveError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'clear':
          if (clearError != null) throw clearError!;
          return true;
        case 'save':
          if (saveError != null) throw saveError!;
          return saveResponse;
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

  group('saveJson — iOS artık dosyası', () {
    /// Eklentinin iOS'ta yazdığı nüshanın yerini taklit eden geçici dizin.
    late Directory docs;

    /// Gerçek eklenti dosyayı `save` çağrısı SIRASINDA yazar → mock handler
    /// içinden yazarak aynı sıralama kurulur.
    void seedLeftover(String fileName, List<int> bytes) {
      File('${docs.path}${Platform.pathSeparator}$fileName')
          .writeAsBytesSync(bytes);
    }

    FilePickerDocumentPort portFor({bool ios = true}) =>
        FilePickerDocumentPort(
          documentsDir: () async => docs,
          isIOS: () => ios,
        );

    setUp(() {
      docs = Directory.systemTemp.createTempSync('pa_docs_');
    });

    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    test('başarılı kayıttan sonra Documents nüshası SİLİNİR', () async {
      const name = 'projectauth-backup-20260902.json';
      saveResponse = '/private/var/mobile/Containers/.../iCloud~Docs/$name';
      seedLeftover(name, utf8.encode('{"v":1,"ct":"…"}'));

      final saved = await portFor().saveJson(
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode('{"v":1,"ct":"…"}')),
      );

      expect(saved, isTrue);
      expect(calls, ['save']);
      expect(
        File('${docs.path}${Platform.pathSeparator}$name').existsSync(),
        isFalse,
        reason: 'şifreli yedek Documents\'ta kalırsa iCloud yedeğine girer',
      );
    });

    test('kullanıcı iptal ettiğinde de nüsha silinir', () async {
      const name = 'iptal.json';
      saveResponse = null; // iptal
      seedLeftover(name, utf8.encode('gizli'));

      expect(
        await portFor()
            .saveJson(fileName: name, bytes: Uint8List.fromList([1, 2, 3])),
        isFalse,
      );
      expect(
        File('${docs.path}${Platform.pathSeparator}$name').existsSync(),
        isFalse,
      );
    });

    test('eklenti hata verirse de nüsha silinir', () async {
      const name = 'patlak.json';
      saveError = PlatformException(code: 'Failed to write file');
      seedLeftover(name, utf8.encode('gizli'));

      await expectLater(
        portFor().saveJson(fileName: name, bytes: Uint8List.fromList([1])),
        throwsA(isA<PlatformException>()),
      );
      expect(
        File('${docs.path}${Platform.pathSeparator}$name').existsSync(),
        isFalse,
      );
    });

    test('iOS DEĞİLKEN dosyaya dokunulmaz (Android/masaüstü)', () async {
      const name = 'android.json';
      saveResponse = '/storage/emulated/0/Download/$name';
      seedLeftover(name, utf8.encode('android SAF yolu ayrı'));

      expect(
        await portFor(ios: false)
            .saveJson(fileName: name, bytes: Uint8List.fromList([1])),
        isTrue,
      );
      expect(
        File('${docs.path}${Platform.pathSeparator}$name').existsSync(),
        isTrue,
        reason: 'yalnız iOS yolunda artık dosya var',
      );
    });

    test('kaydedilen yol artık dosyanın KENDİSİ ise silinmez', () async {
      const name = 'ayni.json';
      final leftoverPath = '${docs.path}${Platform.pathSeparator}$name';
      saveResponse = leftoverPath; // hipotetik: Documents Files\'ta görünür olsa
      seedLeftover(name, utf8.encode('kullanıcının yedeği'));

      expect(
        await portFor()
            .saveJson(fileName: name, bytes: Uint8List.fromList([1])),
        isTrue,
      );
      expect(File(leftoverPath).existsSync(), isTrue,
          reason: 'kullanıcının seçtiği dosya silinmemeli');
    });

    test('nüsha yoksa (temiz platform) hata çıkmaz', () async {
      saveResponse = '/tmp/yok.json';
      expect(
        await portFor()
            .saveJson(fileName: 'yok.json', bytes: Uint8List.fromList([1])),
        isTrue,
      );
    });

    test('dizin sağlayıcı patlarsa export DÜŞMEZ (best-effort)', () async {
      const name = 'saglayici.json';
      saveResponse = '/tmp/$name';
      seedLeftover(name, utf8.encode('gizli'));

      const port = FilePickerDocumentPort(
        documentsDir: _throwingDocumentsDir,
        isIOS: _alwaysIOS,
      );

      expect(
        await port.saveJson(
            fileName: name, bytes: Uint8List.fromList([1])),
        isTrue,
        reason: 'temizlik best-effort — export başarılı sayılır',
      );
    });
  });
}

Future<Directory> _throwingDocumentsDir() =>
    Future<Directory>.error(const FileSystemException('no plugin'));

bool _alwaysIOS() => true;
