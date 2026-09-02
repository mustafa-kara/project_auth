# project_auth — Architecture (architecture.md)

> Version 2.0 · Flutter authenticator · client UI/state architecture
> Design system & screen specs: kept local (not published) · Crypto: [CRYPTO.md](CRYPTO.md) · OTP: [OTP_ENGINE.md](OTP_ENGINE.md)
>
> This file documents the **client-side UI + state + navigation** architecture. The high-level backend/DB schema, RLS, and phase plan live in the root [../ARCHITECTURE.md](../ARCHITECTURE.md). Crypto/key hierarchy is in [CRYPTO.md](CRYPTO.md).

---

## 1. Overview

Flutter client; **Feature-First** folder layout, **BLoC/Cubit** state management, **GoRouter** navigation (two-layer guard). **Offline-first + E2E:** vault tokens are encrypted on-device with the `masterKey`; Phase 3 added **opaque** sync via Supabase (the server never sees plaintext). Identity (Supabase session) and vault lock (master password) are **two independent layers**.

```
lib/
├── main.dart                  # Supabase init (PKCE) + DI + AuthenticatorApp (lifecycle, cubit wiring)
├── core/
│   ├── theme/app_theme.dart   # code equivalent of design.md tokens (ColorScheme + mono styles)
│   ├── ui/
│   │   ├── tokens.dart         # Gap / Radii / Motion / CountdownColors
│   │   └── widgets/            # design.md §14 shared components
│   ├── router/
│   │   ├── app_router.dart           # createAppRouter → AppRouterBundle; Routes constants; two-layer guard
│   │   └── cubit_refresh_notifier.dart  # Cubit stream → Listenable (go_router 17.x has no GoRouterRefreshStream)
│   ├── crypto/                 # CryptoService, KeyManager, BIP39 (CRYPTO.md)
│   ├── otp/                    # TOTP/HOTP/Steam, Base32, otpauth:// (OTP_ENGINE.md)
│   └── di/locator.dart         # get_it composition root
└── features/
    ├── account/   # Supabase identity layer
    │   ├── domain/      # auth_repository, account_vault_manager, device_registrar, *_exceptions, feature_flags_service, announcements_repository
    │   └── presentation/{bloc/session_cubit, pages/*}
    ├── auth/      # vault lock layer
    │   ├── domain/      # key_manager, biometric_service
    │   ├── data/        # key_attributes_store, biometric_service_impl
    │   └── presentation/{bloc/vault_lock_cubit, pages/*}
    ├── vault/     # main screen + token sync
    │   ├── domain/      # token_sync_service, remote_token_repository, raw_token_record, issuer_catalog, catalog_repository
    │   ├── data/        # encrypted_vault_repository, vault_migration, supabase_token_repository, *_store
    │   └── presentation/{bloc/vault_cubit, pages/vault_page,
    │                     widgets/{otp_card, add_token_sheet, edit_token_sheet, token_action_sheet,
    │                              tag_chips_bar, tag_manager_sheet}}   # son beşi Faz 5 Patch 3
    ├── scan/      # QR scanning (scan_page → VaultCubit.add; migration modu → VaultCubit.addAll)
    │   └── presentation/  # scan_page (kamera + "Görüntüden oku"), migration_scan_controller (kamerasız migration beyni)
    ├── import_export/  # Faz 5 Patch 1–3 — Aegis/2FAS/Google Authenticator import + encrypted backup
    │   ├── domain/      # import_service, backup_service, backup_envelope, import_format_detector, dedupe, file_port (DocumentPort + PickedImage), import_models, import_exceptions, google_migration (MigrationBatch + GoogleMigrationCollector), qr_image_decoder (QrImageDecoder seam + QrImageLimits)
    │   ├── data/        # aegis_parser, twofas_parser, protobuf_wire (ProtobufReader), google_auth_parser, file_picker_document_port, mobile_scanner_qr_decoder
    │   └── presentation/  # pages/{import_page, export_page}, widgets/{import_preview_view, migration_progress_band}
    └── settings/  # settings_page (biometrics / live-sync / announcements / backup & transfer)
```

## 2. Feature → Screen → State Map

| Feature | Screens | State source |
|---|---|---|
| `account` | splash, login, register, email_confirm, account_link, restore_failed | `SessionCubit` (Supabase identity) + `AccountVaultManager`, `DeviceRegistrar` |
| `auth` | setup_password, recovery_show, recovery_verify, unlock, recovery_unlock, auth_integrity | `VaultLockCubit` (vault lock) + `KeyManager` |
| `vault` | vault, settings | `VaultCubit` + `TokenSyncService`, `FeatureFlagsService`, `AnnouncementsRepository`. Faz 5 Patch 3 sheet'leri (ekle / düzenle / eylem / etiket yöneticisi) aynı `VaultCubit`'i alır: `add`, `editMetadata`, `renameTag`, `deleteTag`, türetilmiş `allTags`. Etiket filtresi cubit'te DEĞİL — arama gibi `VaultPage` state'i, oturum içi |
| `scan` | scan | `VaultCubit.add()`; migration modunda `MigrationScanController` (collector + `ImportService.previewParsed`) → `VaultCubit.addAll()`. "Görüntüden oku" (Patch 3): `DocumentPort.pickImage` + `QrImageDecoder` → aynı `_handleRaw` |
| `import_export` | import, export | `ImportService` / `BackupService` + `VaultCubit.addAll()`, `DocumentPort` |

Navigation is **state-driven**: screens never force routing with `context.go`; when cubit state changes the guard redirects (`refreshListenable`).

## 3. State Management — Two Independent Layers

### 3.1 `SessionCubit` — Supabase identity (`SessionStatus`)

| State | Meaning | Router |
|---|---|---|
| `unknown` | Bootstrap (before decision) | `/splash` |
| `signedOut` | No Supabase token | `/auth/login` |
| `emailConfirmPending` | Signed up, awaiting email confirmation | `/auth/confirm` (trap; exit via "use a different email") |
| `signedIn` | Valid session + confirmed email | → vault layer (checks `linkRequired` first) |

Transitions: `bootstrap()` (existing session → signedIn + `linkRequired` hydration; persistent pending → emailConfirmPending; none → signedOut) · `signUp` · `signIn` · `resend` · `cancelPendingConfirmation` (exit the trap) · `signOut` (local token is always deleted — no stuck intermediate state; triggers vault teardown) · `authStateChanges` (Supabase stream) · `refreshLinkRequired` (after the link decision).
- **Email confirmation persistence:** if the app closes during the confirmation window, the email is stored in `PendingConfirmationStore` → on launch the confirm screen shows it pre-filled.
- **Account-link gate:** `signedIn` + a uid-less (Phase 2) vault exists on the device + no decision for this uid → `linkRequired=true` → `/auth/link` is mandatory.

### 3.2 `VaultLockCubit` — vault lock (`VaultLockStatus`)

| Status | Meaning | User sees | Vault mutation |
|---|---|---|---|
| `uninitialized` | No vault; no key_attributes | Setup password screen | No |
| `setupPending` | Password entered, recovery being shown/verified | Recovery show/verify | No (commit is atomic) |
| `locked` | Vault exists, masterKey not in memory | Unlock (password/biometrics) | No |
| `unlocked` | masterKey in memory | Vault list | **YES** |
| `locking` | Teardown transition | Spinner/empty | No |
| `keyAttributesCorrupted` | key_attributes unreadable (parse error) | `/auth-integrity` | No |
| `restoring` | **[Phase 3.2]** key_attributes being fetched from cloud | `/splash` spinner (NEVER `/setup`) | No |
| `restoreFailed` | **[Phase 3.2]** Cloud fetch network/RLS/format error | `/auth/restore-failed` | No |

Key transitions: `bootstrap`, `beginSetup`, `commitSetup`, `cancelSetup`, `unlock`, `biometricUnlock`, `recoverWithNewPassword`, `resetVault`, `enableBiometric`/`disableBiometric`, `retryRestore`/`retryBootstrap`, `onAppBackgrounded`, `onAuthSignedOut`. Details in §4.

### 3.3 `VaultCubit` + `TokenSyncService` (unlocked subtree)
- `VaultCubit`: vault contents (`accounts`, `corruptedCount`, `error`, `syncState`), mutations (`add`/`removeById`/`incrementCounter`/`purgeCorrupted`), initial `load()` (idempotent; mutations wait until load completes). The `_opChain` sequencer ensures a user mutation never races with a remote merge.
- `TokenSyncService`: lifetime bound to `VaultCubit` (created on unlock, disposed on lock/signOut). Gated by the `token_sync_enabled` flag. Push/pull + LWW merge + cursor (`last_sync`). Live (Realtime) toggle. Details in §4.

## 4. Critical Flows

**Bootstrap → guard chain:** `SessionCubit.bootstrap()` + `VaultLockCubit.bootstrap()` run in parallel; the GoRouter `redirect` reads both. Redirect matrix in §6.

**VaultLock bootstrap:** local key_attributes present + valid → `locked`. Otherwise: [Phase 3.2] if uid + remoteRepo exist → `restoring` → cloud fetch (row exists → write locally + `locked`; 0 rows = genuinely new → `uninitialized`; network/RLS/format error → `restoreFailed`, NEVER uninitialized → prevents the second-vault race). Parse error → `keyAttributesCorrupted`. Legacy/uid-less → `uninitialized`.

**Setup:** `beginSetup(pwd)` → KeyManager produces masterKey + 24-word mnemonic + key_attributes (in memory, NOT persisted) → `setupPending`. Show recovery → verify spot-check → `commitSetup()`: (1) write key_attributes to disk (FIRST commit point), (2) vault migration, (3) [Phase 3.2] best-effort backfill → `unlocked`. Recovery fail/cancel → dispose key → `uninitialized`. Background abort: if `paused` during setup → dispose key (no persist); if a commit is in-flight, the commit finishes (attrs written → `locked`).

**Unlock:** `unlock(pwd)` → read key_attributes → derive masterKey via Argon2id (wrong password → `WrongPasswordException` → `locked`+error) → migration (idempotent) → `unlocked` → `VaultCubit.load()` → flag check → `TokenSyncService.start(live:)`. Background abort: if `paused` during Argon2/migration → dispose key → `locked`. [Phase 3.2] best-effort attrs backfill (server-wins). [Phase 3.3] dirty replay (a prior changePassword sync error → retried now).

**Biometric unlock:** `biometricUnlock()` uses the same ownership/abort guard. Error paths: `BiometricCanceled` → silent `locked`; `BiometricLockout` → `locked`+error; `BiometricKeyMissing` (OS enrollment lost) → PERSIST-clear `attrs.bmk` + `biometricEnrolled=false` (unlock with password + re-enroll). `_biometricPromptInFlight` → the `inactive` produced by the system prompt does not abort the unlock.

**Recovery + new password (atomic):** `recoverWithNewPassword(words, pwd)` → recoverUnlock + changePassword + persist in a single call (no intermediate state). An attrs-write SyncError → dirty-replay marker. [Phase 3.3] sync is best-effort.

**Reset:** `resetVault()` → dispose key + pending, delete biometric OS key, delete ALL vault storage keys (encrypted/plaintext/migration marker/sync cursor/live-sync pref/dirty marker) → `uninitialized`. Does NOT touch a uid-less legacy vault (separate namespace).

**Account-link (`AccountVaultManager` + `/auth/link`):** Scenario — a uid-less Phase 2 vault exists on the device and the user signs in with a NEW Supabase account. (a) **Link** (`linkLegacyToUser`): copy attrs/encrypted/view_mode/marker from uid-less → uid-namespace (plaintext unchanged), disable biometrics (the OS key does not move across namespaces → re-enroll), delete the uid-less keys, write `active_account`/`legacy_link_decided`. (b) **Start fresh** (`startFreshVault`): mark the decision, leave the uid-less vault untouched (another account can link it later). Then `refreshLinkRequired()` → `linkRequired=false`.

**Token sync (`TokenSyncService`):** `start(live)` → if live, subscribe to Realtime + immediately `syncOnce()`. `syncOnce()`: read cursor → push dirty (best-effort) → pull remote rows since cursor → `VaultCubit.applyRemoteMerge` (sequencer; if the vault is closed returns null → cursor does not advance, safe replay) → advance cursor → emit sync status. **LWW** by `updated_at` (on a tie, local wins). **Soft-delete** (tombstone): while sync is active, `removeById` → `markDeleted` → push → the next pull turns the tombstone into a hard-delete. A malformed remote row → quarantine + `malformedCount` (the vault continues).

**Lifecycle lock (`main.dart`):** `paused` → `onAppBackgrounded(paused:true)` → if unlocked, `lock(immediate:true)` (synchronous key dispose). `inactive` → `onAppBackgrounded(paused:false)` (biometric prompt-in-flight exemption). `resumed` → device heartbeat + flag cache refresh. `signOut` → `onAuthSignedOut` (vault teardown, before the session changes).

## 5. Feature Flags, Catalog, Announcements, Device (Phase 3.4)

- **`FeatureFlagsService`:** `token_sync_enabled` kill-switch (default true; offline fallback true). `load()` waits until the flag resolves (3s timeout) → decision made before sync starts. `listenable` → the Settings live-sync tile updates when the flag changes.
- **`IssuerCatalog`:** issuer name normalization (`github` → `GitHub`). Runs `_canonicalize` during `add()`; if there is no match, leaves it untouched. On-demand fetch + secure-storage cache; offline → empty catalog (no-op). Flag-independent.
- **`AnnouncementsRepository` + cache:** the "What's new" feed in Settings; cache-first (offline) + best-effort fetch; client-side platform filter; if empty/unreachable the section is hidden.
- **`DeviceRegistrar`:** signedIn → stable device id (UUID4) + `register`; resumed → `touchLastSeen` (0 rows → register-fallback). Best-effort (retries on the next resume after a network error).

## 6. Route Table (GoRouter) + Guard Matrix

`createAppRouter` → `AppRouterBundle`. `refreshListenable` = `SessionCubit` ⊕ `VaultLockCubit` (both via `CubitRefreshNotifier`). The guard `redirect` is location-aware (no-op if already at the target). The `ShellRoute` covers only the `unlocked` subtree.

| Path | Route name | Screen file | Shell | Notes |
|---|---|---|---|---|
| `/splash` | `splash` | account/splash | outside | Bootstrap loading; also shown during `restoring` |
| `/auth/login` | `authLogin` | account/login | outside | Supabase email/password |
| `/auth/register` | `authRegister` | account/register | outside | Sign-up (≥8 chars, match — client validation) |
| `/auth/confirm` | `authConfirm` | account/email_confirm | outside | Email confirmation trap; resend / use different email |
| `/auth/link` | `authLink` | account/account_link | outside | Link legacy vault / start fresh (mandatory choice) |
| `/auth/restore-failed` | `authRestoreFailed` | account/restore_failed | outside | Cloud attrs fetch error; retry / sign out |
| `/setup` | `setup` | auth/setup_password | outside | Create master password |
| `/setup/recovery` | `recoveryShow` | auth/recovery_show | outside | Show 24 words + backup confirmation |
| `/setup/verify` | `recoveryVerify` | auth/recovery_verify | outside | Spot-check (3 words, 3 attempts) → commit |
| `/unlock` | `unlock` | auth/unlock | outside | Unlock with password / biometrics |
| `/recovery` | `recovery` | auth/recovery_unlock | outside | Recovery key + new password (atomic) |
| `/auth-integrity` | `authIntegrity` | auth/auth_integrity | outside | key_attributes corrupted; retry / reset |
| `/` | `vault` | vault/vault | **inside** | Main screen (token list/grid + sync) |
| `/scan` | `scan` | scan/scan | **inside** | QR scan (push; returns via pop) |
| `/settings` | `settings` | settings/settings | **inside** | Biometrics / live-sync / announcements (push) |
| `/import` | `importData` | import_export/import | **inside** | Aegis / 2FAS / own-backup file import (push) |
| `/export` | `exportData` | import_export/export | **inside** | Password-encrypted backup export (push) |

**Guard matrix (summary):**
1. `unknown` → `/splash`
2. `signedOut` → `/auth/login` (only the public auth routes; `/auth/link` is blocked)
3. `emailConfirmPending` → `/auth/confirm`
4. `signedIn`: `linkRequired` → `/auth/link`; otherwise by VaultLock:
   `uninitialized`→`/setup` · `setupPending`→`/setup/recovery|verify` · `locked`/`locking`→`/unlock` (user may choose `/recovery`) · `unlocked`→`/` · `restoring`→`/splash` · `restoreFailed`→`/auth/restore-failed` · `keyAttributesCorrupted`→`/auth-integrity`.

## 7. Data Layer — Repository Seam + Opaque Sync

- **Local (offline core):** `EncryptedVaultRepository` (per-token encrypted record, `masterKey` + XChaCha20-Poly1305, AAD `token|1|<id>`), `VaultMigration` (Phase 1 plaintext → encrypted, idempotent via commit-marker), `KeyAttributesStore`. See [CRYPTO.md §9].
- **Remote (Phase 3, opaque):** `SupabaseTokenRepository` (push/pull of encrypted blobs — the server never sees plaintext), the `RemoteTokenRepository` interface, `key_attributes` upload/restore, and the `catalog`/`feature_flags`/`announcements` repos. All best-effort + offline fallback (offline-first is never broken).
- **Kill-switch:** `token_sync_enabled=false` → sync is skipped entirely; the vault works fully offline. Turning it
  back on (false→true) runs a catch-up `syncOnce`: everything that happened during the closed window is invisible to
  Realtime, which only announces later changes.
- **`postgrest 2.9` retries reads by itself.** Since 2.9.0 the transitive `postgrest` client ships automatic retries
  enabled by default: **GET/HEAD only**, 3 attempts, on a network error or HTTP 503/520. Writes are never retried, so
  `pushUpsert` cannot be duplicated behind our back — but a `pullSince` that looks like one slow call may in fact be
  four, which matters when reading timings or logs. `TokenSyncService`'s own best-effort/`SyncError` handling still
  sees only the final outcome.

## 8. Dependencies

`flutter_bloc` · `go_router 17.x` (custom `CubitRefreshNotifier` — no `GoRouterRefreshStream`) · `get_it` (**hand-written composition root — no `injectable`/codegen**; aynı kural gereği Google Authenticator aktarım QR'ının protobuf yükü de `protobuf` paketi + `build_runner` yerine elle yazılmış `protobuf_wire.dart` ile çözülür — üstelik proto3 **alan mevcudiyeti**ni yalnız elle decoder görebilir, sayaçsız HOTP kaydının 0 varsayılarak içeri alınmasını bu engeller) · `supabase_flutter` (PKCE) · `sodium`/`sodium_libs` (libsodium — Argon2id/XChaCha20) · `flutter_secure_storage` · `mobile_scanner` · `local_auth` + `device_info_plus` · `flutter_svg` (issuer SVG) · `equatable` · `uuid` · `crypto`. Design: embedded Geist/GeistMono (NO google_fonts), simple-icons CC0. Tests: `flutter_test` + `mocktail`.

**No code generation anywhere.** JSON (`fromJson`/`toJson`) and state classes are hand-written; on 2026-09-01
`injectable`, `injectable_generator`, `freezed`, `freezed_annotation`, `json_annotation`, `json_serializable`,
`build_runner` and `bloc_test` were removed from `pubspec.yaml` because nothing imported them and no generated
`*.g.dart` / `*.freezed.dart` / `*.config.dart` file exists.

**Config:** `SupabaseConfig` reads the URL/publishable key **only** from `--dart-define`; `ensureConfigured()` runs in
`main.dart` before `Supabase.initialize` and throws in debug and release alike. Run with
`--dart-define-from-file=env/dev.json` (see the README).

**Screen-capture protection:** sensitive pages wrap their `build` in `SecureScreenScope` — 11 of them today:
vault, unlock, setup_password, recovery_unlock, recovery_show, recovery_verify, login, register, scan, import, export
(`grep -rn "SecureScreenScope(" lib/` is the authoritative list). The ref count lives in Dart because
the native flag is last-caller-wins — see [CRYPTO.md §15](CRYPTO.md). **Faz 5 Patch 3 did not change this
list:** its new surfaces are all modal sheets and dialogs rendered inside pages that already hold a scope
(vault, scan), and a scope is a page-level wrapper — a sheet opened over a protected page is already covered.

## 8.1 Import / Export (Faz 5 Patch 1–3)

`features/import_export/` is layered like the rest: `domain/` is pure Dart (parsers are driven through the
`ImportParser` interface, `DocumentPort` abstracts file access), `data/` holds the concrete parsers and the
`file_picker` adapter, `presentation/` the two pages.

- **`DocumentPort`** (`domain/file_port.dart`) — `pickJson({maxBytes})` / `saveJson({fileName, bytes})`. The only
  seam onto the platform file picker, so the pages stay testable without a plugin.
- **`file_picker ^12.0.0`** (resolved 12.1.3) — raised on 2026-09-02 together with **`device_info_plus ^13.0.0`**
  (13.2.0), because that was the only way either could move: `file_picker >=12.1.3` pulls `windows_file_picker` →
  `win32 ^6.3.0`, while `device_info_plus ^12.1.0` (the Android SDK gate) required `win32 ^5.11.0`. Both wins land
  on iOS: 12.x splits Apple platforms into the federated `file_picker_darwin`, whose podspec depends on Flutter
  alone, so `DKImagePickerController/PhotoGallery` (→ `SDWebImage`, `SwiftyGif`) is gone from `ios/Podfile.lock`
  — no photo-library API linked into a document-only build, and no `NSPhotoLibraryUsageDescription` question at
  review; and its iOS `saveFile` stages the export in `NSTemporaryDirectory()` rather than the app's Documents
  directory, so the copy no longer lands in the iCloud backup. The one cost is the iOS deployment target moving
  13.0 → 14.0 (`file_picker_darwin` podspec), which loses no devices — iOS 14 runs on the same hardware as iOS 13.
- **12.x API shape.** `pickFile()` returns a `PlatformFile` whose bytes are read on demand with `readAsBytes()`
  (`withData` and the `FilePickerResult` wrapper are gone), and `saveFile()` returns a `Uri?` instead of a path
  string. The facade dispatches everything through `FilePickerPlatform.instance`, so the port's unit tests fake
  that platform interface rather than the `miguelruivo.flutter.plugins.filepicker` method channel (the channel
  name itself is unchanged, but a host-VM test never reaches it).
- **`VaultCubit.addAll(List<OtpAccount>)`** — bulk insert with exactly one persist and one push, instead of N
  round trips through `add()`. Callers de-duplicate beforehand.
- **Routes** `/import` and `/export` are children of the unlocked ShellRoute and are on the guard's unlocked
  allow-list (`app_router.dart`), so a deep link into them while locked still redirects to unlock.
- **Lock exemption** — both flows wrap the picker in `VaultLockCubit.beginSystemFileFlow()` /
  `endSystemFileFlow()`; a budgeted, deliberate concession documented in [CRYPTO.md §17](CRYPTO.md).

**Patch 2 — Google Authenticator aktarım QR'ı.** Dışa aktarım bir `otpauth://` URI'si değil,
`otpauth-migration://offline?data=…` içinde base64'lenmiş protobuf; bu yüzden dosya seçici yerine kameradan girer:

- **`data/protobuf_wire.dart`** — `ProtobufReader` (tag / varint / length-delimited / skip) ve sert sınırlar
  (8 KiB URI, 64 KiB payload, kod başına 256 kayıt, 1024 hesap, 10 byte varint). Codegen yok (§7 paket notu).
- **`data/google_auth_parser.dart`** — `looksLikeMigrationUri` / `parseUri`: query elle ayrıştırılır
  (`Uri.queryParameters` base64'teki `+`'yı boşluğa çevirirdi), ardından `OtpAccount` eşlemesi; eşlenemeyen her
  kayıt kodu düşürmek yerine `SkippedEntry` olur.
- **`domain/google_migration.dart`** — `MigrationBatch` + `GoogleMigrationCollector`: çok QR'lı bir dışa aktarımı
  sırasız taramaya rağmen birleştirir (ilk kodun `batch_id`/`batch_size` değerlerine sabitlenir); başka bir
  dışa aktarımın kodu asla karıştırılmaz, kısmi içe aktarma meşru bir sonuçtur.
- **`features/scan/presentation/migration_scan_controller.dart`** — akışın kamerasız beyni (collector +
  `ImportService.previewParsed`); `ScanPage` yalnızca döneni render eder, kural kümesi bu sayede kamerasız test
  edilir. `ScanPage` migration moduna şema algılamayla geçer (**yeni rota yok, guard/DI değişmez**) ve artık
  `SecureScreenScope` ile sarılıdır.
- **`presentation/widgets/import_preview_view.dart`** — onay önizlemesi; dosyadan ve QR'dan içe aktarma aynı
  widget'ı ve aynı metinleri paylaşır.

**Patch 3 — etiketler, yapıştırılan aktarım bağlantısı, görüntüden QR.** Patch 2'nin yalnız canlı kamerayla
yapılabilen işine iki alternatif giriş, artı içe aktarılan grupların korunması.

- **`OtpAccount.tags`** — şifreli blob'un İÇİNDE; kayıt `v`'si, AAD'si ve yedek zarfının `version`'ı
  DEĞİŞMEZ, liste boşken anahtar hiç yazılmaz (etiketsiz vault byte-aynı serialize olur → yükseltmede
  yeniden şifreleme/push dalgası yok). Gerekçeler: [CRYPTO.md §9](CRYPTO.md).
- **`VaultCubit`** — `editMetadata` (yalnız issuer/hesap adı/etiket; secret ve kod geometrisi parametre
  olarak dahi alınmaz), `renameTag`, `deleteTag`, türetilmiş `allTags`. Üçü de `addAll` kalıbını izler: tüm
  süpürme için TEK persist + TEK push, no-op'ta hiçbir yazma ve hiçbir push yok. `editMetadata`'da BOŞ issuer
  "issuer yok" demektir (sonuç `null`, `""` değil): düzenleme sheet'i issuer'sız token için boş alan gösterip
  o boşluğu geri yollar, aksi hâlde hiç dokunulmamış token yeniden şifrelenir ve push edilirdi.
- **`presentation/widgets/tag_chips_bar.dart`** — arama alanının altında yatay çip şeridi. **Tek seçim ve
  oturum içi**: filtre kalıcı DEĞİL, çünkü yeniden açılışta hayatta kalan bir filtre kullanıcının "token'ım
  kayboldu" sanmasının klasik yoludur. Vault'ta hiç etiket yoksa şerit hiç render edilmez. Filtre `VaultCubit`
  değil `VaultPage` state'i (aramayla aynı yerde), ve arama ile AND'lenir. Çip **tam eşleşme** testidir
  ("iş", "işlem"i getirmez); arama ise etiket metnine de bakar.
- **`token_action_sheet.dart` / `edit_token_sheet.dart` / `tag_manager_sheet.dart`** — uzun basış artık
  eylem sheet'i açar (Düzenle / Etiketler / Sil), silme her yolda onaylıdır. Düzenleme sheet'i secret'a
  hiç dokunmaz. Etiket yöneticisi yeniden adlandırma/silmeyi tüm vault'a uygular ve kaç kodu etkilediğini
  önden söyler; silinen yalnızca ETİKETtir, token değil.
- **`OtpCard` sözleşmesi genişledi.** Yeni iki opsiyonel callback:
  - `onLongPress` — `VaultPage` bunu eylem sheet'ine bağlar, yani üründe uzun basış artık doğrudan
    silmez. Verilmezse uzun basış HİÇBİR ŞEY yapmaz: `onDelete`'e geri düşüş YOK, böylece onaysız silme
    yolu handler'ı unutan bir çağrı yerinden geri sızamaz.
  - `onEdit` — düzenleme sheet'ini açar. `onLongPress`'in içine katlanmamasının sebebi erişilebilirlik:
    ekran okuyucu kullanıcısı "uzun basamaz", bu yüzden 'Düzenle' ve 'Sil'
    `customSemanticsActions` olarak da yayınlanır. Kartın birincil `label`'ı ve tek-tap "kodu kopyala"
    davranışı değişmedi — yalnız aksiyon EKLENDİ.
- **`ScanPage` "Görüntüden oku"** — `DocumentPort.pickImage` + `QrImageDecoder`; çözülen her metin mevcut
  `_handleRaw`'a girer, yani tek-token ve aktarım modu görüntüden de çalışır. Dosya akışlarıyla aynı
  bütçeli kilit muafiyeti, artık üç akışlı ([CRYPTO.md §17](CRYPTO.md)); seçicinin bıraktığı düz nüshanın
  temizlik SIRASI kritiktir ([CRYPTO.md §16.5](CRYPTO.md)).
- **`AddTokenSheet` yapıştırma yolu** — `otpauth-migration://` bağlantısı sheet'in kendi
  `MigrationScanController`'ına gider; eksik batch'te `MigrationProgressBand`, tamamlanınca sheet içinde
  `ImportPreviewView`. Pano PROGRAMATİK okunmaz. `ImportPage` rehberi yalnızca bu yolu işaret eden tek bir
  cümle kazandı — oraya ikinci bir giriş alanı KONMADI.

## 9. Document Map
- This file: client UI/state architecture.
- Design system, screen index/flow map, and `screens/<feature>/<screen>.md` (10-section screen specs): kept local, not published.
- [CRYPTO.md](CRYPTO.md) / [OTP_ENGINE.md](OTP_ENGINE.md): crypto + OTP core.
- [../ARCHITECTURE.md](../ARCHITECTURE.md): high-level backend/DB + phase plan.
