/// İçe aktarma ekranı (Faz 5 Patch 1, plan §5.3) — tek sayfa, üç adım:
/// dosya seç → (kendi şifreli yedeğimizse) parola → önizleme → onay.
///
/// SECURITY (plan §4.6):
/// - Sayfa [SecureScreenScope] ile sarılıdır: dosya adı, issuer/hesap listesi ve
///   parola alanı ekran görüntüsü / kayıt / recents önizlemesine düşmez.
/// - Seçilen dosyanın DÜZ METNİ (secret'lar dahil) onay anına kadar bellekte
///   tutulmak zorunda; `dispose`'ta ve import biter bitmez temizlenir.
/// - Panoya HİÇBİR ŞEY yazılmaz ve hiçbir secret ekrana/loga çıkmaz — atlanan
///   girdiler yalnız `SkippedEntry.label` (issuer/hesap) ile gösterilir.
/// - Sistem dosya seçicisi app'i arka plana attığı için çağrı
///   `VaultLockCubit.beginSystemFileFlow()` / `finally endSystemFileFlow()` ile
///   sarmalanır (plan §3.2 — bilinçli, bütçeli kilit muafiyeti).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/locator.dart';
import '../../../../core/platform/secure_screen.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_banner.dart';
import '../../../../core/ui/widgets/app_text_field.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/empty_state.dart';
import '../../../../core/ui/widgets/status_badge.dart';
import '../../../auth/presentation/bloc/vault_lock_cubit.dart';
import '../../../vault/presentation/bloc/vault_cubit.dart';
import '../../domain/file_port.dart';
import '../../domain/import_exceptions.dart';
import '../../domain/import_models.dart';
import '../../domain/import_service.dart';
import '../widgets/import_preview_view.dart';

/// Kaynak biçiminin kullanıcıya gösterilen adı.
String importSourceLabel(ImportSource source) => switch (source) {
      ImportSource.aegis => 'Aegis',
      ImportSource.twofas => '2FAS',
      ImportSource.googleAuth => 'Google Authenticator',
      ImportSource.projectauthBackup => 'Şifreli yedek',
      ImportSource.unknown => 'Bilinmeyen biçim',
    };

/// Dosya seviyesi hataların Türkçe karşılıkları (plan §3.8). Beklenmeyen hata
/// tipleri jenerik mesaja düşer — teknik detay kullanıcıya gösterilmez.
String importErrorMessage(Object error) => switch (error) {
      ImportFileTooLargeException() => 'Dosya çok büyük (max 8 MB).',
      MalformedImportFileException() =>
        'Dosya okunamadı — geçerli bir JSON yedeği değil.',
      UnsupportedImportFormatException() =>
        'Bu dosya biçimi desteklenmiyor. Aegis (düz JSON), 2FAS veya bu '
            'uygulamanın yedeği olmalı.',
      EncryptedSourceException(source: final s) => switch (s) {
          ImportSource.aegis =>
            'Bu Aegis yedeği parolayla şifrelenmiş. Aegis\'te "Dışa aktar" '
                'ekranından şifrelemeyi kapatıp yeniden dışa aktar.',
          ImportSource.twofas =>
            'Bu 2FAS yedeği parolayla şifrelenmiş. 2FAS\'ta yedeği parolasız '
                'dışa aktarıp tekrar dene.',
          _ => 'Bu yedek parolayla şifrelenmiş — şifresiz olarak yeniden '
              'dışa aktar.',
        },
      ImportTooManyEntriesException() =>
        'Dosyada çok fazla kayıt var (en fazla 1024).',
      EmptyImportException() =>
        'Dosyada içe aktarılacak token bulunamadı.',
      WrongBackupPasswordException() =>
        'Parola yanlış ya da dosya bozulmuş.',
      UnsupportedBackupVersionException() =>
        'Bu yedek daha yeni bir sürümle oluşturulmuş. Uygulamayı güncelle.',
      _ => 'İçe aktarma başarısız — tekrar dene.',
    };

/// Sayfanın hangi adımda olduğu.
enum _Step { pick, password, preview }

class ImportPage extends StatefulWidget {
  /// Servisler testte sahtelenebilsin diye opsiyonel; prod'da DI'dan çözülür.
  const ImportPage({super.key, this.service, this.documents});

  /// Test tohumu: prod'da `null` → DI'dan çözülür.
  @visibleForTesting
  final ImportService? service;

  /// Test tohumu: prod'da `null` → DI'dan çözülür.
  @visibleForTesting
  final DocumentPort? documents;

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  late final ImportService _service = widget.service ?? locator<ImportService>();
  late final DocumentPort _documents =
      widget.documents ?? locator<DocumentPort>();

  final _passwordCtrl = TextEditingController();

  _Step _step = _Step.pick;
  bool _busy = false;
  String? _error;

  /// Seçilen dosyanın düz metni — onay/iptal anında temizlenir (secret taşır).
  String? _raw;
  String? _fileName;
  ImportSource? _source;
  ImportPreview? _preview;

  /// Kilit cubit'i, element hâlâ ağaçtayken yakalanır — `dispose` içinde
  /// `context.read` GÜVENLİ DEĞİL (review takibi).
  VaultLockCubit? _lock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lock = context.read<VaultLockCubit>();
  }

  @override
  void dispose() {
    // Sayfa, sistem seçicisi AÇIKKEN sökülebilir (router redirect, geri hareketi,
    // kilit). O durumda `_pickFile`'ın `finally`'si henüz çalışmamıştır ve muafiyet
    // bütçesi dolana kadar açık kalırdı → burada kapatılır. `endSystemFileFlow`
    // idempotent (docs/CRYPTO.md §17 "screen dispose").
    final lock = _lock;
    if (lock != null && lock.systemFileFlowActive) lock.endSystemFileFlow();
    _passwordCtrl
      ..clear()
      ..dispose();
    _raw = null; // düz metni referanssız bırak (secret taşıyordu)
    super.dispose();
  }

  /// Sistem dosya seçicisini açar. Picker app'i arka plana attığı için kilit
  /// muafiyeti `finally` ile GARANTİ kapatılır (iptal/hata/başarı fark etmez).
  Future<void> _pickFile() async {
    if (_busy) return;
    final lock = context.read<VaultLockCubit>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final PickedDocument? doc;
      lock.beginSystemFileFlow();
      try {
        doc = await _documents.pickJson(maxBytes: ImportService.maxBytes);
      } finally {
        lock.endSystemFileFlow();
      }
      if (doc == null) return; // kullanıcı iptal etti → adım değişmez
      final picked = doc;

      final String raw;
      try {
        raw = utf8.decode(picked.bytes);
      } on FormatException {
        throw const MalformedImportFileException('not valid UTF-8');
      }
      final source = _service.detect(raw);
      if (!mounted) return;
      setState(() {
        _raw = raw;
        _fileName = picked.name;
        _source = source;
      });
      if (source == ImportSource.projectauthBackup) {
        setState(() => _step = _Step.password); // kendi yedeğimiz → parola sor
      } else {
        await _runPreview();
      }
    } catch (e) {
      if (mounted) setState(() => _error = importErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Parse + dedupe → önizleme. Vault'taki mevcut tokenlar dedupe girdisi.
  Future<void> _runPreview({String? password}) async {
    final raw = _raw;
    if (raw == null) return;
    final existing = context.read<VaultCubit>().state.accounts;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await _service.preview(
        raw: raw,
        existing: existing,
        backupPassword: password,
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _step = _Step.preview;
      });
    } catch (e) {
      if (mounted) setState(() => _error = importErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitPassword() async {
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Yedek parolasını gir.');
      return;
    }
    await _runPreview(password: _passwordCtrl.text);
    if (mounted && _step == _Step.preview) _passwordCtrl.clear();
  }

  /// Onay: hepsi TEK `addAll` ile eklenir (tek persist + tek push — plan §3.6).
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
      _error = null;
    });
    try {
      await vault.addAll(preview.toAdd);
      // Düz metin ve tüketilmiş önizleme artık gereksiz → bellekte TUTMA.
      // `_preview` de secret taşır (`toAdd` canlı `OtpAccount`'lar): pop
      // başarısız olup kullanıcı sayfada kalırsa da elde kalmasın.
      _raw = null;
      _preview = null;
      messenger.showSnackBar(
        SnackBar(content: Text('${preview.addCount} token eklendi')),
      );
      if (mounted) {
        // Deep-link ile doğrudan /import'a girildiyse geri dönülecek bir kayıt
        // yoktur → `maybePop` sessizce false döner ve kullanıcı tüketilmiş bir
        // önizlemede kalır. Bu durumda vault'a yönlendir.
        final popped = await navigator.maybePop();
        if (!popped) router?.go(Routes.vault);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Tokenlar kaydedilemedi — tekrar dene.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Dosya seçimi adımına döner ve seçilen dosyanın izlerini düşürür.
  void _restartPick() {
    _passwordCtrl.clear();
    setState(() {
      _step = _Step.pick;
      _raw = null; // düz metin (secret taşıyordu)
      _fileName = null;
      _source = null;
      _preview = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      appBar: AppBar(
        title: const Text('İçe aktar'),
        // Yanlış dosyayı seçen kullanıcının tek çıkışı geri tuşuyla ekranı
        // TERK ETMEK olmasın: parola ve önizleme adımlarından dosya seçimine
        // dönülebilir (seçilen dosyanın düz metni de böylece düşer).
        actions: _step == _Step.pick
            ? null
            : [
                TextButton(
                  onPressed: _busy ? null : _restartPick,
                  child: const Text('Başka dosya seç'),
                ),
              ],
      ),
      body: SafeArea(
        child: switch (_step) {
          // `_preview` onaydan sonra boşaltılır ([_confirmImport]); pop'un
          // tamamlanmasını bekleyen karede eski önizlemeyi değil boş bir
          // gövdeyi göster.
          _Step.preview when _preview != null => _buildPreview(context),
          _Step.pick || _Step.preview => _buildPick(context),
          _Step.password => _buildPassword(context),
        },
      ),
    );

    // Token listesi + yedek parolası ekranda → hassas ekran (plan §4.6 / D6).
    return SecureScreenScope(child: page);
  }

  Widget _buildPick(BuildContext context) => Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
              child: AppBanner(
                kind: StatusKind.critical,
                icon: Icons.error_outline,
                message: _error!,
              ),
            ),
          Expanded(
            child: EmptyState(
              icon: Icons.file_open_outlined,
              title: 'Yedek dosyası seç',
              description:
                  'Aegis veya 2FAS\'ın şifresiz JSON yedeğini ya da bu '
                  'uygulamayla aldığın şifreli yedeği seç. Dosya cihazından '
                  'çıkmaz — her şey burada çözülür.',
              actionLabel: _busy ? 'Açılıyor…' : 'Dosya seç',
              onAction: _pickFile, // _busy iken metot başında no-op
              primaryAction: true,
            ),
          ),
          // Google Authenticator dosya DEĞİL, QR üretir (plan §5b) → ikinci
          // aksiyon kamerayı açar. `EmptyState` tek CTA taşır, bu yüzden ayrı.
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _showGoogleGuide,
              icon: const Icon(Icons.qr_code_scanner_outlined),
              label: const Text('Google Authenticator (QR)'),
            ),
          ),
        ],
      );

  /// Kısa yönerge: kullanıcı Google Authenticator'da aktarım QR'ını nerede
  /// bulacağını bilmiyor. Sheet kapanınca tarama ekranı açılır.
  void _showGoogleGuide() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Google Authenticator\'dan aktar',
                style: Theme.of(sheetCtx).textTheme.titleMedium,
              ),
              const SizedBox(height: Gap.sm),
              Text(
                'Google Authenticator → ⋮ → Hesapları aktar → Hesapları dışa '
                'aktar → QR\'ı bu kameraya göster. Birden fazla QR çıkarsa '
                'hepsini sırayla okut.',
                style: Theme.of(sheetCtx).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(sheetCtx).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: Gap.xl),
              FilledButton(
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  // Sheet kapanırken sayfa da sökülmüş olabilir (geri tuşu,
                  // rota değişimi) → disposed context'le push etme.
                  if (!mounted) return;
                  // Testlerde sayfa GoRouter'sız pump edilebiliyor (mevcut
                  // önizleme testleri) → `maybeOf` ile sessiz kal.
                  GoRouter.maybeOf(context)?.push(Routes.scan);
                },
                child: const Text('Kamerayı aç'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPassword(BuildContext context) => ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text(
            'Bu dosya şifreli bir yedek',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: Gap.sm),
          Text(
            'Yedeği oluştururken belirlediğin parolayı gir. Bu parola master '
            'parolandan farklı olabilir.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: Gap.xl),
          AppTextField(
            controller: _passwordCtrl,
            label: 'Yedek parolası',
            obscure: true,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) {
              if (!_busy) _submitPassword();
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: Gap.md),
            AuthErrorText(_error!),
          ],
          const SizedBox(height: Gap.xl),
          FilledButton(
            onPressed: _busy ? null : _submitPassword,
            child: _busy ? const BtnSpinner() : const Text('Devam'),
          ),
        ],
      );

  /// Önizleme, QR tarama akışıyla ORTAK widget'a delege edilir — iki giriş
  /// noktasının sayı/atlanan listesi ve metinleri birebir aynı kalsın diye.
  Widget _buildPreview(BuildContext context) => ImportPreviewView(
        preview: _preview!,
        headerLabel: importSourceLabel(_source ?? ImportSource.unknown),
        headerDetail: _fileName,
        error: _error,
        busy: _busy,
        onConfirm: _confirmImport,
      );
}
