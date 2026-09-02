/// QR tarama ekranı — `mobile_scanner` ile kamera taraması, iki mod:
///
/// - **Tek token:** ilk geçerli `otpauth://` QR'ı yakalandığında token vault'a
///   eklenir ve ekran kapanır.
/// - **Google Authenticator aktarımı (Faz 5 Patch 2):** `otpauth-migration://`
///   şeması görülür görülmez ekran migration moduna geçer; çok parçalı bir
///   dışa aktarmanın QR'ları sırayla toplanır, sonra ortak içe aktarma
///   önizlemesi onaya sunulur. Yeni rota YOK — mod şemadan anlaşılır.
///
/// Faz 5 Patch 3: AppBar'daki "Görüntüden oku" aksiyonu KAYITLI bir görüntüden
/// (ekran görüntüsü, kaydedilmiş QR fotoğrafı) okur. Kamera yolundan tek farkı
/// ham metnin nereden geldiğidir — çözülen her QR aynı [_handleRaw]'a girer, o
/// yüzden iki mod da görüntüden çalışır.
///
/// SECURITY:
/// - Sayfa [SecureScreenScope] ile sarılıdır: kamera önizlemesi QR'ın KENDİSİNİ
///   (yani düz secret'ları) gösterir, önizleme adımı da issuer/hesap listesi.
/// - Ham QR metni parse edildikten sonra TUTULMAZ; panoya hiçbir şey yazılmaz;
///   secret hiçbir mesaja/loga girmez (hata metinleri sabit).
/// - Toplanan hesaplar yalnız controller'ın içinde yaşar; `dispose`'ta reset.
/// - Görüntü yolunda seçicinin bıraktığı DÜZ nüsha (canlı bir secret'ın
///   resmidir) her çıkışta sıfırlanıp silinir; kullanıcının galerideki
///   ORİJİNALİNE dokunulmaz (bkz. [_ScanPageState._pickFromImage]).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/di/locator.dart';
import '../../../core/router/app_router.dart';
import '../../../core/otp/otp_account.dart';
import '../../../core/otp/otpauth_uri.dart';
import '../../../core/platform/secure_screen.dart';
import '../../../core/ui/tokens.dart';
import '../../../core/ui/widgets/empty_state.dart';
import '../../auth/presentation/bloc/vault_lock_cubit.dart';
import '../../import_export/data/file_picker_document_port.dart';
import '../../import_export/data/google_auth_parser.dart';
import '../../import_export/data/mobile_scanner_qr_decoder.dart';
import '../../import_export/domain/file_port.dart';
import '../../import_export/domain/import_exceptions.dart';
import '../../import_export/domain/import_service.dart';
import '../../import_export/domain/qr_image_decoder.dart';
import '../../import_export/presentation/widgets/import_preview_view.dart';
import '../../import_export/presentation/widgets/migration_progress_band.dart';
import '../../vault/presentation/bloc/vault_cubit.dart';
import 'migration_scan_controller.dart';

/// Kamera widget'ının yerine geçen test kurucusu: [onDetect]'i çağırmak, bir
/// kameranın kare yayınlamasıyla birebir aynı yola girer — tek karede birden
/// çok barkod taşıyan `BarcodeCapture` dâhil.
typedef ScannerBuilder = Widget Function(
    BuildContext context, void Function(BarcodeCapture capture) onDetect);

/// Kameranın `stop()`/`start()` çağrılarının test tohumu. İkisi AYRI alan:
/// test ikisini ayrı sayabilmeli ve yalnız `stop()`'u hatalandırabilmeli
/// (bkz. [_ScanPageState._restartCamera]).
typedef CameraControls = ({
  Future<void> Function() stop,
  Future<void> Function() start,
});

class ScanPage extends StatefulWidget {
  const ScanPage({
    super.key,
    this.debugMigration,
    this.debugScannerBuilder,
    this.debugCamera,
    this.debugNow,
    this.debugScannerState,
    this.debugQrDecoder,
    this.debugDocuments,
  });

  /// Aynı hata mesajının yeniden SnackBar'a dönmesi için geçmesi gereken süre
  /// (bkz. [_ScanPageState._showError]).
  @visibleForTesting
  static const Duration errorRepeatWindow = Duration(seconds: 2);

  /// Test tohumu: migration beynini enjekte eder. Prod'da `null` → DI'daki
  /// [ImportService] ile gerçek [MigrationScanController] kurulur.
  @visibleForTesting
  final MigrationScanController? debugMigration;

  /// Test tohumu: [MobileScanner] host VM'de kamera/plugin ister → widget
  /// testinde yerine bu kurucunun döndürdüğü yer tutucu render edilir.
  @visibleForTesting
  final ScannerBuilder? debugScannerBuilder;

  /// Test tohumu: gerçek kamera kontrollerinin yerine geçer.
  @visibleForTesting
  final CameraControls? debugCamera;

  /// Test tohumu: [_ScanPageState._showError] throttle'ının saati. Prod'da
  /// `null` → [DateTime.now].
  @visibleForTesting
  final DateTime Function()? debugNow;

  /// Test tohumu: AppBar aksiyonlarının dinlediği kamera durumu. Prod'da
  /// `null` → gerçek [MobileScannerController] (kendisi bir
  /// `ValueNotifier<MobileScannerState>`).
  @visibleForTesting
  final ValueListenable<MobileScannerState>? debugScannerState;

  /// Test tohumu: görüntüden QR çözücü. Prod'da `null` →
  /// [MobileScannerQrDecoder]. Gerçek çözücü platform kanalına gider, yani host
  /// VM'de her zaman patlar; testte kapanışla değiştirilir.
  @visibleForTesting
  final QrImageDecoder? debugQrDecoder;

  /// Test tohumu: görüntü seçici portu. Prod'da `null` → DI'daki
  /// [DocumentPort]. TEMBEL çözülür: görüntü aksiyonuna basılmadıkça locator'a
  /// dokunulmaz (locator'sız mevcut tarama testleri bozulmasın).
  @visibleForTesting
  final DocumentPort? debugDocuments;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  /// Migration beyni. Tembel kurulur: tek-token taraması DI'ya HİÇ dokunmaz
  /// (locator'sız widget testleri bozulmasın).
  MigrationScanController? _migration;
  MigrationScanController get _migrationController =>
      _migration ??= MigrationScanController(locator<ImportService>());

  /// İlk başarılı yakalamadan sonra tekrar işlemeyi (ve çift ekleme/çift pop'u)
  /// engeller. Kamera akışı birden çok kare yollayabilir. Migration modunda
  /// KİLİTLEMEZ — orada birden çok QR okunması işin ta kendisi.
  bool _handled = false;

  /// Migration sayaçları. [_total] > 0 ise ekran migration modundadır.
  int _scanned = 0;
  int _total = 0;

  /// Onaya sunulan önizleme; doluysa kamera yerine önizleme render edilir.
  ImportPreview? _preview;

  /// Önizleme İSTENDİ ama henüz atanmadı. [_preview] ancak `stop()` bittikten
  /// sonra dolar; bu bayrak o await penceresinde gelen kareyi de eler (iOS'ta
  /// kadrajda duran QR her karede yeniden gelir — aşağıdaki nota bak).
  bool _previewing = false;

  /// Görüntüden okuma sürüyor ([_previewing] disipliniyle aynı iş): sistem
  /// seçicisi açıkken ya da çözüm sürerken gelen bir kamera karesi araya
  /// girmesin, aksiyona ikinci kez basılamasın.
  bool _pickingImage = false;

  /// Görüntü seçici portu ve kilit cubit'i — ilk kullanımda çözülür.
  ///
  /// `dispose` içinde `context.read` GÜVENLİ DEĞİL, bu yüzden cubit ağaçtayken
  /// yakalanır; `didChangeDependencies` yerine ilk kullanımda yakalanmasının
  /// sebebi ise bu ekranın kilit cubit'i OLMADAN da pump edilebilmesi (mevcut
  /// tarama testleri kamera yolunu sürüyor, kilidi hiç sağlamıyor).
  DocumentPort? _documentsPort;
  VaultLockCubit? _lock;

  DocumentPort get _documents =>
      _documentsPort ??= widget.debugDocuments ?? locator<DocumentPort>();

  QrImageDecoder get _decoder =>
      widget.debugQrDecoder ?? const MobileScannerQrDecoder().call;

  bool _busy = false;
  String? _importError;

  /// Aynı QR'ın arka arkaya gelen kareleri diyalogları üst üste yığmasın
  /// (iOS'ta `noDuplicates` payload karşılaştırması YAPMAZ — aşağıdaki nota bak).
  bool _dialogOpen = false;

  /// [_showError] throttle'ının durumu: en son gösterilen mesaj ve zamanı.
  String? _lastError;
  DateTime? _lastErrorAt;

  bool get _isComplete => _total > 0 && _scanned >= _total;

  @override
  void initState() {
    super.initState();
    _migration = widget.debugMigration;
  }

  @override
  void dispose() {
    // Sayfa, sistem seçicisi AÇIKKEN sökülebilir (geri hareketi, rota
    // değişimi). O durumda [_pickFromImage]'in `finally`'si henüz çalışmamıştır
    // ve kilit muafiyeti bütçesi dolana kadar açık kalırdı → burada kapatılır.
    // `endSystemFileFlow` idempotent (docs/CRYPTO.md §17 "screen dispose").
    final lock = _lock;
    if (lock != null && lock.systemFileFlowActive) lock.endSystemFileFlow();
    // Toplanan hesaplar canlı secret taşır → ekran kapanırken düşür.
    _migration?.reset();
    _controller.dispose();
    super.dispose();
  }

  /// Bir kamera karesi → bir veya daha çok ham QR metni.
  ///
  /// Migration modunda karedeki TÜM barkodlar sırayla işlenir: kullanıcı iki
  /// aktarım QR'ını yan yana tutabilir ve Android'de `noDuplicates` belleği
  /// (`MobileScanner.kt`'nin `lastScanned` alanı) karenin tamamını yazar —
  /// yalnız ilkini alsaydık ikinci QR bir daha HİÇ yayınlanmaz, kullanıcı da
  /// okunmayan kodu tekrar tekrar göstermeye çalışırdı. Tek-token modunda
  /// ilk geçerli değer yeterli: orada ilk başarılı okuma zaten ekranı kapatır.
  Future<void> _onDetect(BarcodeCapture capture) async {
    // Görüntüden okuma sürerken kamera zaten durdurulmuştur; gecikmiş bir kare
    // araya girip sayaçları oynatmasın ([_previewing] ile aynı disiplin).
    if (_pickingImage) return;
    final raws = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .where((v) => v.isNotEmpty)
        .toList(growable: false);
    if (raws.isEmpty) return;
    if (_total == 0) {
      await _handleRaw(raws.first);
      return;
    }
    for (final raw in raws) {
      await _handleRaw(raw);
    }
  }

  /// Tek giriş noktası: hem kameradan hem test tohumundan buraya gelinir.
  Future<void> _handleRaw(String raw) async {
    // Önizleme açıkken (ya da açılmak üzereyken) kamera durduruluyordur;
    // gecikmiş bir kare onay ekranının altını oymasın.
    if (_previewing || _preview != null) return;

    if (GoogleAuthParser.looksLikeMigrationUri(raw)) {
      _handleMigration(raw);
      return;
    }

    // Migration yarıdayken araya giren tek-token QR'ı sessizce EKLEMEZ: aksi
    // hâlde toplanan parçalar kaybolur ve ekran habersiz kapanırdı. Geçerli bir
    // `otpauth://` QR'ı ile bozuk/alakasız bir QR AYRI mesaj alır: ilkinde
    // kullanıcı doğru bir kod göstermiştir, ona ne yapması gerektiği söylenir.
    if (_total > 0) {
      _showError(
        _looksLikeOtpAuth(raw)
            ? 'Aktarım sürüyor — önce kalan kodları okut ya da Baştan başla.'
            : 'Bu QR bir Google Authenticator aktarım kodu değil ya da bozuk.',
      );
      return;
    }

    if (_handled) return;

    final OtpAccount account;
    try {
      account = OtpAuthUri.parse(raw);
    } on FormatException catch (e) {
      // Geçersiz/QR-değil — kullanıcıyı bilgilendir, taramaya devam et.
      _showError('Geçersiz QR: ${e.message}');
      return;
    }

    _handled = true; // yalnızca geçerli QR'da kilitle — geçersizde taramaya devam
    try {
      // Kalıcılığı BEKLE: yazma başarılıysa kapat. Hata olursa kullanıcı token
      // eklenmiş sanmasın → hatayı göster ve yeniden taramaya izin ver.
      await context.read<VaultCubit>().add(account);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _handled = false;
      _showError('Kaydedilemedi: $e');
    }
  }

  /// Ham metin tek-token bir `otpauth://` QR'ı gibi mi duruyor?
  ///
  /// Yalnız şemaya bakar — [OtpAuthUri.parse] çağrılmaz, çünkü tek amaç hangi
  /// UYARI metninin gösterileceğine karar vermek ve bunun için secret'ı
  /// belleğe çıkarmaya gerek yok.
  static bool _looksLikeOtpAuth(String raw) =>
      raw.trimLeft().toLowerCase().startsWith('otpauth://');

  /// Migration QR'ı → controller olayı → UI. Ham metin burada tüketilir ve
  /// hiçbir alana yazılmaz.
  void _handleMigration(String raw) {
    final event = _migrationController.handleRaw(raw);
    switch (event) {
      case MigrationBatchAdded(:final scanned, :final total) ||
            MigrationScanComplete(:final scanned, :final total):
        setState(() {
          _scanned = scanned;
          _total = total;
        });
      case MigrationDuplicateScan():
        _showError('Bu kod zaten okundu');
      case MigrationDifferentBatch():
        unawaited(_askRestart());
      case MigrationInvalidBatch() || MigrationMalformedQr():
        // Neden ayrımı KASITLI olarak gösterilmez (secret'tan türer).
        _showError('Bu QR bir Google Authenticator aktarım kodu değil ya da bozuk.');
      case MigrationScanFull():
        _showError('Bu aktarımda çok fazla hesap var.');
    }
  }

  /// Başka bir dışa aktarmanın QR'ı okundu: birleştirme YAPILMAZ, kullanıcıya
  /// baştan başlamak isteyip istemediği sorulur.
  Future<void> _askRestart() async {
    if (_dialogOpen) {
      // Diyalog zaten açık (iOS'ta aynı QR her karede yeniden gelir). Sessiz
      // kalmak yerine kısa bir not: kullanıcı kodu tekrar tekrar göstermesin.
      _showError('Bu kod için soru zaten açık.');
      return;
    }
    _dialogOpen = true;
    final bool? restart;
    try {
      restart = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text(
              'Bu QR farklı bir dışa aktarmaya ait. Baştan başlansın mı?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Vazgeç'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Baştan başla'),
            ),
          ],
        ),
      );
    } finally {
      // `showDialog` atarsa (ör. Navigator kilitli) bayrak takılı kalmamalı:
      // aksi hâlde bu diyalog bir daha HİÇ açılmaz.
      _dialogOpen = false;
    }
    if (restart == true && mounted) await _restart();
  }

  Future<void> _restart() async {
    _migration?.reset();
    if (mounted) {
      setState(() {
        _scanned = 0;
        _total = 0;
        _preview = null;
        _previewing = false;
        _importError = null;
      });
    }
    await _restartCamera();
  }

  /// Kamerayı durdurup yeniden başlatır.
  ///
  /// GEREKLİ, sadece kozmetik değil: `DetectionSpeed.noDuplicates` Android
  /// tarafında son yayınlanan payload'ı `lastScanned` alanında tutar ve aynı
  /// değeri bir daha yollamaz (mobile_scanner 7.4,
  /// `android/.../MobileScanner.kt`). Bu alan YALNIZCA `start()` ve `stop()`
  /// içinde `null`'lanır → "Baştan başla" sonrası kullanıcı ilk QR'ı yeniden
  /// gösterse tarayıcı onu yutardı. (iOS/macOS tarafında payload
  /// karşılaştırması hiç yok: `noDuplicates` orada yalnız kare hızını kısar
  /// — `MobileScannerPlugin.swift` timeout'u 0'a çeker — bu yüzden aynı QR
  /// tekrar tekrar gelir. Buna karşı üç koruma var: diyaloglar [_dialogOpen],
  /// önizlemenin await penceresi [_previewing], hata mesajları da
  /// [_showError] throttle'ı.)
  ///
  /// `stop()` ile `start()` AYRI çağrılar: durdurma hata verse bile kamera
  /// yeniden başlatılmalı, yoksa "Baştan başla" sonrası ekran ölü kalırdı.
  Future<void> _restartCamera() async {
    await _stopCamera();
    if (!mounted) return;
    await _startCamera();
  }

  Future<void> _stopCamera() async {
    final stop = widget.debugCamera?.stop ?? _controller.stop;
    try {
      await stop();
    } catch (_) {
      // Kamera olmayan platform / geçici hata: durdurma best-effort. Gerçek
      // kamera hatası `errorBuilder` ile zaten görünür.
    }
  }

  Future<void> _startCamera() async {
    final start = widget.debugCamera?.start ?? (() => _controller.start());
    try {
      await start();
    } catch (_) {
      // Aynı gerekçe: başlatma best-effort.
    }
  }

  /// Kaydedilmiş bir görüntüden QR okur (plan §5 D5).
  ///
  /// Kamera yolundan tek farkı ham metnin kaynağıdır: çözülen her QR aynı
  /// [_handleRaw]'a girer, yani hem tek-token hem aktarım modu görüntüden de
  /// çalışır (bir aktarımın iki QR'ı tek ekran görüntüsünde olabilir).
  ///
  /// Üç ayrı `finally` üç ayrı sözü tutar:
  /// 1. `endSystemFileFlow` — sistem seçicisi app'i arka plana atar ve kilit
  ///    muafiyeti iptal/hata/başarı fark etmeksizin KAPANMALI (plan §3.2).
  /// 2. Seçilen nüshanın sıfırlanıp silinmesi + picker cache temizliği — nüsha
  ///    canlı bir secret'ın DÜZ resmidir. Önce hedefli shred (üzerine yazıp
  ///    sil), sonra genel temizlik: sırası ters olsaydı `clearPickerCache`
  ///    dosyayı üzerine yazılmadan unlink ederdi. Kullanıcının galerideki
  ///    ORİJİNALİNE dokunulmaz — eklenti zaten o yolu vermez.
  /// 3. [_pickingImage] düşer ve kamera geri açılır (yeni bir ekrana
  ///    geçilmediyse).
  Future<void> _pickFromImage() async {
    if (_pickingImage || _previewing || _preview != null) return;
    // Cubit ağaçtayken yakalanır: `dispose` muafiyeti kapatmak için buna bakar.
    final lock = _lock ??= context.read<VaultLockCubit>();
    setState(() => _pickingImage = true);
    await _stopCamera();

    PickedImage? picked;
    try {
      lock.beginSystemFileFlow();
      try {
        picked = await _documents.pickImage(maxBytes: QrImageLimits.maxBytes);
      } finally {
        lock.endSystemFileFlow();
      }
      if (picked == null) return; // kullanıcı iptal etti → kamera geri gelir

      final raws = await _decoder(picked.path);
      if (raws.isEmpty) {
        _showError('Bu görüntüde QR kod bulunamadı.');
        return;
      }
      for (final raw in raws) {
        if (!mounted) return;
        await _handleRaw(raw);
      }
    } on ImportFileTooLargeException {
      // Boyut kapısı çözümden ÖNCE, bildirilen boyuttan: devasa bir "görüntü"
      // platform çözücüsüne hiç verilmez.
      _showError('Görüntü çok büyük (en fazla 16 MB).');
    } on QrImageUnsupportedException {
      // iOS Simulator / web: başka bir görüntü denemek DE işe yaramaz.
      _showError('Bu cihazda görüntüden okuma desteklenmiyor.');
    } on QrImageUnreadableException {
      _showError('Görüntü okunamadı.');
    } catch (_) {
      // Çözülemedi ya da seçici patladı. Neden gösterilmez: platform mesajı
      // dosya adı/içeriği alıntılayabilir.
      _showError('Görüntü okunamadı.');
    } finally {
      final path = picked?.path;
      if (path != null) FilePickerDocumentPort.shredCachedCopy(path);
      await _documents.clearPickerCache();
      if (mounted) {
        setState(() => _pickingImage = false);
        // Token eklenip sayfa pop'landıysa ([_handled]) ya da önizlemeye
        // geçildiyse kamerayı geri açma.
        if (!_handled && !_previewing && _preview == null) {
          await _startCamera();
        }
      }
    }
  }

  /// Toplananları önizlemeye çevirir.
  ///
  /// [_previewing] daha İLK await'ten önce set edilir: kamera durdurulurken
  /// gelen bir kare, önizlemenin hesaplandığı koleksiyonu değiştirmemeli.
  /// Önizleme açılmazsa (içe aktarılacak hiçbir şey yok) bayrak düşer ve
  /// kamera geri açılır — kullanıcı taramaya kaldığı yerden devam eder.
  Future<void> _showPreview() async {
    if (_previewing || _preview != null) return;
    final existing = context.read<VaultCubit>().state.accounts;
    _previewing = true;
    await _stopCamera();
    final ImportPreview preview;
    try {
      preview = _migrationController.preview(existing: existing);
    } on EmptyImportException {
      _previewing = false;
      _showError('Bu kodlarda içe aktarılacak token bulunamadı.');
      await _startCamera();
      return;
    }
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _importError = null;
    });
  }

  /// "Bu kadar yeter": eksik tarama meşru bir sonuç, ama sonucu açıkça söyle.
  Future<void> _confirmPartial() async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    final bool? go;
    try {
      go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Bu kadar yeter'),
          content:
              const Text('Yalnız taradığın kodlardaki hesaplar aktarılacak.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Vazgeç'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Devam'),
            ),
          ],
        ),
      );
    } finally {
      // Bkz. [_askRestart]: atan bir `showDialog` bayrağı takılı bırakmasın.
      _dialogOpen = false;
    }
    if (go == true && mounted) await _showPreview();
  }

  /// Onay: hepsi TEK `addAll` ile eklenir (tek persist + tek push).
  Future<void> _confirmImport() async {
    final preview = _preview;
    if (preview == null || preview.toAdd.isEmpty) return;
    final vault = context.read<VaultCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // null in widget tests, where the page is pumped without a GoRouter.
    final router = GoRouter.maybeOf(context);
    setState(() {
      _busy = true;
      _importError = null;
    });
    try {
      await vault.addAll(preview.toAdd);
      _migration?.reset(); // secret'lar artık vault'ta → bellekte tutma
      messenger.showSnackBar(
        SnackBar(content: Text('${preview.addCount} token eklendi')),
      );
      if (mounted) {
        // `ImportPage._confirmImport` ile SİMETRİK: `/scan`'e deep-link ile
        // doğrudan girildiyse geri dönülecek kayıt yoktur → `maybePop` sessizce
        // false döner ve kullanıcı tüketilmiş bir önizlemede kalırdı.
        // [_preview] burada BOŞALTILMAZ (ImportPage'den tek farkı): sayfa
        // kapanana kadar önizleme render edilmeye devam ediyor, boşaltmak
        // pop'un bir karesinde kamerayı geri getirirdi. Sökülünce düşer.
        final popped = await navigator.maybePop();
        if (!popped) router?.go(Routes.vault);
      }
    } catch (_) {
      // Kaydedilemedi → sayfa KAPANMAZ, kullanıcı tekrar deneyebilir.
      if (mounted) {
        setState(() => _importError = 'Tokenlar kaydedilemedi — tekrar dene.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Hata SnackBar'ı — AYNI mesaj [ScanPage.errorRepeatWindow] içinde bir kez.
  ///
  /// Throttle şart: iOS/macOS'ta `DetectionSpeed.noDuplicates` payload
  /// karşılaştırması YAPMAZ (`MobileScannerPlugin.swift` yalnız kare
  /// timeout'unu 0'a çeker), yani kadrajda duran tek bir tekrarlı/bozuk QR her
  /// karede bir olay üretir. Throttle olmadan `clearSnackBars()` +
  /// `showSnackBar()` her karede tekrarlanır: sürekli yanıp sönen, alt bandı
  /// örten bir şerit. Farklı bir mesaj pencereyi beklemeden gösterilir.
  void _showError(String message) {
    // Async save hatası sonrası kullanıcı ekrandan ayrılmış olabilir → disposed
    // context'e dokunma (add sheet'teki mounted korumasıyla tutarlı).
    if (!mounted) return;
    final now = (widget.debugNow ?? DateTime.now)();
    final lastAt = _lastErrorAt;
    if (_lastError == message &&
        lastAt != null &&
        now.difference(lastAt) < ScanPage.errorRepeatWindow) {
      return;
    }
    _lastError = message;
    _lastErrorAt = now;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        // Bant `bottomNavigationBar`'da duruyor; floating SnackBar Scaffold'un
        // alt widget'larının ÜSTÜNE yerleşir (`_ScaffoldLayout` floating için
        // `contentBottom` kullanır) → ilerleme ve aksiyonlar örtülmez.
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final inPreview = _preview != null;
    final inMigration = _total > 0;
    final page = Scaffold(
      appBar: AppBar(
        title: Text(_total > 0 ? 'Google Authenticator kodunu tara' : 'QR Tara'),
        // Önizleme adımında kamera zaten durdurulmuştur → aksiyonlar gizlenir.
        actions: inPreview
            ? null
            : [
                IconButton(
                  tooltip: 'Görüntüden oku',
                  icon: const Icon(Icons.image_outlined),
                  // Kamera durumundan BAĞIMSIZ: `analyzeImage` kamerayı ya da
                  // kamera iznini gerektirmez (mobile_scanner 7.4), yani izin
                  // reddedilmiş bir cihazda bile tek çalışan yol budur.
                  onPressed: _pickingImage ? null : _pickFromImage,
                ),
                _cameraActions(),
              ],
      ),
      body: SafeArea(
        child: inPreview ? _buildPreview(context) : _buildCamera(context),
      ),
      // Bant gövdede DEĞİL, `bottomNavigationBar` yuvasında: floating bir
      // SnackBar Scaffold'un alt widget'larının üstüne yerleşir, böylece hata
      // mesajı ilerlemeyi ve üç çıkış yolunu örtmez (bkz. [_showError]).
      bottomNavigationBar: inPreview || !inMigration
          ? null
          : MigrationProgressBand(
              scanned: _scanned,
              total: _total,
              complete: _isComplete,
              onContinue: _showPreview,
              onStopEarly: _confirmPartial,
              onRestart: _restart,
            ),
    );

    // Kamera önizlemesi QR'ın kendisini (secret) gösterir, onay adımı da hesap
    // listesini → hassas ekran.
    return SecureScreenScope(child: page);
  }

  /// Flaş / kamera değiştir aksiyonları.
  ///
  /// Kamera hazır DEĞİLKEN devre dışı: `MobileScannerController.toggleTorch`
  /// ve `switchCamera` ilk iş olarak `_throwIfNotInitialized()` çağırır
  /// (mobile_scanner 7.4) → izin reddi ya da açılış hatasından sonra basılan
  /// buton yakalanmamış bir [MobileScannerException] fırlatırdı. Flaşı olmayan
  /// cihazda (`TorchState.unavailable`) düğme hiç gösterilmez: eklenti orada
  /// sessizce hiçbir şey yapmıyor, yani buton yalanmış olurdu.
  Widget _cameraActions() => ValueListenableBuilder<MobileScannerState>(
        valueListenable: widget.debugScannerState ?? _controller,
        builder: (context, state, _) {
          final ready = state.isInitialized;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.torchState != TorchState.unavailable)
                IconButton(
                  tooltip: 'Flaş',
                  icon: const Icon(Icons.flash_on),
                  onPressed: ready ? _toggleTorch : null,
                ),
              IconButton(
                tooltip: 'Kamera değiştir',
                icon: const Icon(Icons.cameraswitch),
                onPressed: ready ? _switchCamera : null,
              ),
            ],
          );
        },
      );

  /// Kamera kontrolü çağrıları best-effort: hata kullanıcıya SnackBar olarak
  /// döner, ekran çalışmaya devam eder (bkz. [_stopCamera]/[_startCamera]).
  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } on MobileScannerException {
      _showError('Flaş açılamadı.');
    }
  }

  Future<void> _switchCamera() async {
    try {
      await _controller.switchCamera();
    } on MobileScannerException {
      _showError('Kamera değiştirilemedi.');
    }
  }

  Widget _buildPreview(BuildContext context) => ImportPreviewView(
        preview: _preview!,
        headerLabel: 'Google Authenticator',
        headerDetail: '$_scanned/$_total kod',
        error: _importError,
        busy: _busy,
        onConfirm: _confirmImport,
      );

  Widget _buildCamera(BuildContext context) =>
      widget.debugScannerBuilder?.call(context, _onDetect) ??
      MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        onDetectError: (error, _) => _showError('Tarama hatası: $error'),
        errorBuilder: (context, error) => _ScanError(error: error),
        overlayBuilder: (context, _) => const _ScanReticle(),
      );
}

/// Kamera izni reddi / başlatma hatası için kullanıcı dostu durum (EmptyState,
/// Design.md §14.11 — ekrana özgü metin).
class _ScanError extends StatelessWidget {
  final MobileScannerException error;
  const _ScanError({required this.error});

  @override
  Widget build(BuildContext context) {
    final isPermission =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return EmptyState(
      icon: Icons.no_photography_outlined,
      title: isPermission ? 'Kamera izni gerekli' : 'Kamera başlatılamadı',
      description: isPermission
          ? 'QR taramak için cihaz ayarlarından kamera iznini etkinleştirin.'
          : 'Kamera açılamadı (${error.errorCode.name}). Lütfen tekrar deneyin.',
    );
  }
}

/// Köşe-rehberli nişangah + yönerge (Design.md: marka rengi, net affordance).
class _ScanReticle extends StatelessWidget {
  const _ScanReticle();

  /// Nişangah çerçeve kenarı.
  static const _frameSize = 240.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: _frameSize,
            height: _frameSize,
            child: CustomPaint(painter: _CornerPainter(scheme.primary)),
          ),
          const SizedBox(height: Gap.xl),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.lg, vertical: Gap.sm),
            decoration: BoxDecoration(
              // Kamera üstünde okunabilirlik: scrim karartma (Design.md §4 scrim
              // kuralı — scan ekranı tek izinli yüksek-kontrast istisnası §1.2).
              color: scheme.scrim.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: const Text(
              'QR kodu çerçeveye hizala',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dört köşeye L-şeklinde marka renkli rehber çizer.
class _CornerPainter extends CustomPainter {
  final Color color;
  _CornerPainter(this.color);

  /// Köşe L-rehberinin kol uzunluğu / kalınlığı.
  static const _cornerLen = 32.0;
  static const _cornerStroke = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    const len = _cornerLen;
    final paint = Paint()
      ..color = color
      ..strokeWidth = _cornerStroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final w = size.width, h = size.height;
    // Sol üst
    canvas.drawLine(const Offset(0, len), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(len, 0), paint);
    // Sağ üst
    canvas.drawLine(Offset(w - len, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, len), paint);
    // Sol alt
    canvas.drawLine(Offset(0, h - len), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(len, h), paint);
    // Sağ alt
    canvas.drawLine(Offset(w - len, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - len), paint);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.color != color;
}
