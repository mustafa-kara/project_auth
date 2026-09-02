/// `FilePickerDocumentPort` — picker cache temizliği (review takibi).
///
/// file_picker seçilen dosyayı uygulamanın KENDİ cache'ine kopyalar
/// (iOS `NSTemporaryDirectory()`, Android `cacheDir/file_picker/`) ve SİLMEZ;
/// 12.x'te `PlatformFile.readAsBytes()` de byte'ları O kopyadan okur. Byte'lar
/// bellekte olduktan sonra kopya yalnız gereksiz değil, kullanıcının
/// secret'larının DÜZ METİN bir nüshasıdır → `pickJson` her çıkışta
/// `FilePicker.clearTemporaryFiles()` çağırmalı.
///
/// AYRICA (denetim C1): `saveFile` iOS'ta dosyayı önce bir ara dizine yazar,
/// oradan DIŞA AKTARIR ve o nüshayı hiçbir yolda silmez. file_picker 11.0.3'te
/// bu dizin `NSDocumentDirectory` idi → nüsha iCloud yedeğine girerdi;
/// `file_picker_darwin` 1.0.4'te `NSTemporaryDirectory()`'ye taşındı (yedeğe
/// girmez) ama `saveJson`'ın shred'i SAVUNMA amaçlı korunur: hedef yeniden
/// değişirse tek yakalayan o. iOS tespiti ve dizin sağlayıcı enjekte edilebilir
/// olduğundan burada geçici bir dizinle doğrulanır.
///
/// file_picker 12 federated olduğu için facade `FilePickerPlatform.instance`'a
/// dağıtır — MethodChannel sahtelemek artık facade'e ULAŞMAZ (host testte
/// varsayılan instance `MethodChannelFilePicker`'dır ve `pickFile`/`saveFile`
/// `UnimplementedError` atar). Bu yüzden seam olarak platform arayüzü sahtelenir.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/import_export/data/file_picker_document_port.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';

void main() {
  late _FakeFilePickerPlatform platform;
  late FilePickerPlatform original;

  const port = FilePickerDocumentPort();

  setUpAll(() => original = FilePickerPlatform.instance);
  tearDownAll(() => FilePickerPlatform.instance = original);

  setUp(() {
    platform = _FakeFilePickerPlatform();
    FilePickerPlatform.instance = platform;
  });

  /// Platforma gelen çağrı adları (sıralı).
  List<String> calls() => platform.calls;

  _FakePlatformFile onePick(String name, List<int> bytes) =>
      _FakePlatformFile(name: name, bytes: Uint8List.fromList(bytes));

  test('başarılı seçimden SONRA cache temizlenir', () async {
    platform.pickResponse = onePick('yedek.json', utf8.encode('{"a":1}'));

    final doc = await port.pickJson(maxBytes: 1024);

    expect(doc, isNotNull);
    expect(doc!.name, 'yedek.json');
    expect(utf8.decode(doc.bytes), '{"a":1}');
    expect(calls(), ['pickFile', 'clear'],
        reason: 'byte\'lar alındıktan SONRA düz metin kopya silinmeli');
  });

  test('tek dosya seçilir ve tür filtresi uygulanmaz', () async {
    platform.pickResponse = onePick('yedek.json', utf8.encode('{}'));

    await port.pickJson(maxBytes: 1024);

    expect(platform.pickedType, FileType.any,
        reason: 'uzantı filtresi kullanıcının dosyasını gizler; format '
            'içerikten doğrulanır');
  });

  test('kullanıcı iptal ettiğinde de cache temizlenir', () async {
    platform.pickResponse = null; // iptal

    expect(await port.pickJson(maxBytes: 1024), isNull);
    expect(calls(), ['pickFile', 'clear']);
  });

  test('boyut sınırı aşılınca (throw yolu) cache yine temizlenir', () async {
    platform.pickResponse = onePick('kocaman.json', List<int>.filled(64, 0x7b));

    await expectLater(
      port.pickJson(maxBytes: 16),
      throwsA(isA<ImportFileTooLargeException>()),
    );
    expect(calls(), ['pickFile', 'clear'],
        reason: 'reddedilen dosyanın kopyası da diskte kalmamalı');
  });

  test('bildirilen boyut aşarsa byte\'lar HİÇ okunmaz', () async {
    final file = onePick('kocaman.json', List<int>.filled(4, 0x7b))
      ..reportedSize = 1 << 30;
    platform.pickResponse = file;

    await expectLater(
      port.pickJson(maxBytes: 16),
      throwsA(isA<ImportFileTooLargeException>()),
    );
    expect(file.readCount, 0,
        reason: 'devasa dosya belleğe alınmadan reddedilmeli');
  });

  test('byte\'lar okunamazsa malformed hatası verilir', () async {
    platform.pickResponse = onePick('bozuk.json', utf8.encode('{}'))
      ..readError = const FileSystemException('cache reclaimed');

    await expectLater(
      port.pickJson(maxBytes: 1024),
      throwsA(isA<MalformedImportFileException>()),
    );
    expect(calls(), ['pickFile', 'clear']);
  });

  test('picker hata verirse de cache temizlenir', () async {
    platform.pickError = PlatformException(code: 'unknown_path');

    await expectLater(port.pickJson(maxBytes: 1024), throwsA(anything));
    expect(calls(), ['pickFile', 'clear']);
  });

  test('temizlik hatası import\'u DÜŞÜRMEZ (masaüstü/web no-op)', () async {
    platform.pickResponse = onePick('yedek.json', utf8.encode('{"a":1}'));
    platform.clearError = PlatformException(code: 'unimplemented');

    final doc = await port.pickJson(maxBytes: 1024);

    expect(doc, isNotNull, reason: 'temizlik best-effort');
    expect(calls(), ['pickFile', 'clear']);
  });

  group('saveJson — iOS artık dosyası', () {
    /// Eklentinin iOS'ta yazdığı nüshanın yerini taklit eden geçici dizin.
    late Directory docs;

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
      platform.saveResponse =
          Uri.file('/private/var/mobile/Containers/iCloudDocs/$name');
      seedLeftover(name, utf8.encode('{"v":1,"ct":"…"}'));

      final saved = await portFor().saveJson(
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode('{"v":1,"ct":"…"}')),
      );

      expect(saved, isTrue);
      expect(calls(), ['save']);
      expect(
        File('${docs.path}${Platform.pathSeparator}$name').existsSync(),
        isFalse,
        reason: 'şifreli yedek Documents\'ta kalırsa iCloud yedeğine girer',
      );
    });

    test('kullanıcı iptal ettiğinde de nüsha silinir', () async {
      const name = 'iptal.json';
      platform.saveResponse = null; // iptal
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
      platform.saveError = PlatformException(code: 'Failed to write file');
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

    test('dosya olmayan URI (SAF content:) çözümlemeyi DÜŞÜRMEZ', () async {
      const name = 'saf.json';
      platform.saveResponse =
          Uri.parse('content://com.android.providers.downloads/42');
      seedLeftover(name, utf8.encode('gizli'));

      expect(
        await portFor().saveJson(fileName: name, bytes: Uint8List.fromList([1])),
        isTrue,
        reason: 'Uri.toFilePath() file: olmayan şemada fırlatır',
      );
      expect(
        File('${docs.path}${Platform.pathSeparator}$name').existsSync(),
        isFalse,
      );
    });

    test('iOS DEĞİLKEN dosyaya dokunulmaz (Android/masaüstü)', () async {
      const name = 'android.json';
      platform.saveResponse = Uri.file('/storage/emulated/0/Download/$name');
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
      // Hipotetik: Documents Files'ta görünür olsaydı kullanıcı onu seçebilirdi.
      platform.saveResponse = Uri.file(leftoverPath);
      seedLeftover(name, utf8.encode('kullanıcının yedeği'));

      expect(
        await portFor().saveJson(fileName: name, bytes: Uint8List.fromList([1])),
        isTrue,
      );
      expect(File(leftoverPath).existsSync(), isTrue,
          reason: 'kullanıcının seçtiği dosya silinmemeli');
    });

    test('nüsha yoksa (temiz platform) hata çıkmaz', () async {
      platform.saveResponse = Uri.file('/tmp/yok.json');
      expect(
        await portFor()
            .saveJson(fileName: 'yok.json', bytes: Uint8List.fromList([1])),
        isTrue,
      );
    });

    test('dizin sağlayıcı patlarsa export DÜŞMEZ (best-effort)', () async {
      const name = 'saglayici.json';
      platform.saveResponse = Uri.file('/tmp/$name');
      seedLeftover(name, utf8.encode('gizli'));

      const port = FilePickerDocumentPort(
        documentsDir: _throwingDocumentsDir,
        isIOS: _alwaysIOS,
      );

      expect(
        await port.saveJson(fileName: name, bytes: Uint8List.fromList([1])),
        isTrue,
        reason: 'temizlik best-effort — export başarılı sayılır',
      );
    });
  });
}

Future<Directory> _throwingDocumentsDir() =>
    Future<Directory>.error(const FileSystemException('no plugin'));

bool _alwaysIOS() => true;

/// Federated seam: facade her çağrıyı `FilePickerPlatform.instance`'a dağıtır.
final class _FakeFilePickerPlatform extends FilePickerPlatform {
  final List<String> calls = [];

  PlatformFile? pickResponse;
  Object? pickError;
  Object? clearError;
  Uri? saveResponse;
  Object? saveError;

  /// Port'un istediği tür filtresi.
  FileType? pickedType;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls.add('pickFile');
    pickedType = type;
    if (pickError != null) throw pickError!;
    return pickResponse;
  }

  @override
  Future<void> clearTemporaryFiles() async {
    calls.add('clear');
    if (clearError != null) throw clearError!;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls.add('save');
    if (saveError != null) throw saveError!;
    return saveResponse;
  }
}

/// Seçilen dosyanın port'un TÜKETTİĞİ yüzeyi: `name`, `length()`,
/// `readAsBytes()`. Gerçek implementasyonlarda byte'lar eklentinin disk
/// üzerindeki cache nüshasından okunur; [readError] o okumanın patlamasını
/// (nüsha geri alınmış, URI iptal edilmiş) taklit eder.
final class _FakePlatformFile extends PlatformFile {
  _FakePlatformFile({required this.name, required Uint8List bytes})
      : _bytes = bytes;

  @override
  final String name;

  final Uint8List _bytes;

  /// Platformun bildirdiği boyut; varsayılan gerçek uzunluk.
  int? reportedSize;

  /// Set edilirse [readAsBytes] bu hatayla düşer.
  Object? readError;

  /// [readAsBytes] kaç kez çağrıldı (boyut kapısının erken durduğunu kanıtlar).
  int readCount = 0;

  @override
  Uri get uri => Uri.file('/cache/file_picker/$name');

  // `Never` is a subtype of `XFile`, so the override is legal without importing
  // `cross_file` (a transitive dependency the app does not depend on directly).
  @override
  Never get xFile => throw UnimplementedError('port xFile kullanmaz');

  @override
  Future<int> length() async => reportedSize ?? _bytes.lengthInBytes;

  @override
  Future<Uint8List> readAsBytes() async {
    readCount++;
    if (readError != null) throw readError!;
    return _bytes;
  }

  @override
  Stream<Uint8List> readAsByteStream() => Stream<Uint8List>.value(_bytes);
}
