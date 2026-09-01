/// Shared import confirmation view: counts, the skipped-entry audit list and the
/// confirm button (plan §5).
///
/// Filled by W2, who moves `import_page.dart`'s `_buildPreview`/`_countLine`
/// here verbatim — the two entry points (file import and Google Authenticator
/// QR scan) must show identical wording, and the existing `import_page_test`
/// expectations are the contract for that wording.
///
/// Stateless and service-free: it renders an [ImportPreview] and calls back.
/// Applying the import stays with the caller, so nothing here can write to the
/// vault.
///
/// SECURITY: only `SkippedEntry.label`/`detail` and counts are rendered. No
/// secret reaches this widget tree; the caller is responsible for wrapping the
/// screen in `SecureScreenScope`.
library;

import 'package:flutter/material.dart';

import '../../domain/import_service.dart';

class ImportPreviewView extends StatelessWidget {
  const ImportPreviewView({
    super.key,
    required this.preview,
    required this.onConfirm,
    required this.headerLabel,
    this.headerDetail,
    this.error,
    this.busy = false,
    this.confirmLabel = 'İçe aktar',
  });

  /// What would be added and what would not.
  final ImportPreview preview;

  /// Invoked when the user confirms. Disabled while [busy] or when
  /// `preview.toAdd` is empty.
  final VoidCallback onConfirm;

  /// Badge text naming the source, e.g. `importSourceLabel(source)` for a file
  /// or 'Google Authenticator' for a scan.
  final String headerLabel;

  /// Secondary header line: the file name, or '{i}/{n} kod' for a scan. Hidden
  /// when null.
  final String? headerDetail;

  /// Turkish error text shown above the confirm button; null hides it.
  final String? error;

  /// True while the confirmed import is being applied.
  final bool busy;

  /// Confirm button label; overridden only when a flow needs different wording.
  final String confirmLabel;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
