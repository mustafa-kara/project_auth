# Changelog

Project progress log. Newest at the top.

## 2026-09-01 (Phase 3.5 — CI, dependency cleanup, screen-capture protection, config fail-fast)

Three infrastructure/hardening changes on top of Phase 3. **NO crypto routine, NO server schema, NO sync-protocol change.**
host **436/436 → 454/454**, `flutter analyze --fatal-infos` clean.

### Dependency cleanup + minor upgrades + GitHub Actions CI (`467a63a`)

- **8 unused packages removed** (verified with grep over `lib/`, `test/`, `integration_test/`: zero imports, no generated
  `*.g.dart` / `*.freezed.dart` / `*.config.dart`, no `build.yaml`): dependencies `injectable`, `freezed_annotation`,
  `json_annotation`; dev_dependencies `build_runner`, `freezed`, `bloc_test`, `json_serializable`, `injectable_generator`.
  **DI stays a HAND-WRITTEN `get_it` composition root** (`lib/core/di/locator.dart`) and **JSON stays hand-written**
  (`fromJson`/`toJson` with type-safe helpers) — that was already the reality; the codegen packages were dead weight.
  `mocktail` is KEPT (the only mock library in use).
- **Minor/patch upgrades only:** `supabase_flutter` ^2.14.1 → ^2.17.2, `mobile_scanner` ^7.2.0 → ^7.4.0,
  `local_auth` ^3.0.1 → ^3.0.2, `equatable` ^2.0.8 → ^2.1.0, `uuid` ^4.5.3 → ^4.6.0.
  **Deliberately untouched:** `sodium`/`sodium_libs` (3.x **pin** — 4.x needs Dart 3.11+), and `go_router` 18,
  `flutter_secure_storage` 11, `device_info_plus` 13 (major bumps **deferred**, not pinned — each needs its own migration).
- **`.github/workflows/ci.yml` added:** `push` on `main` + `pull_request`, `ubuntu-latest`,
  `subosito/flutter-action@v2` pinned to Flutter **3.38.6** stable with cache → `flutter pub get`,
  `flutter analyze --fatal-infos`, `flutter test`. A concurrency group cancels superseded runs.
  **Deliberately excluded:** integration tests (need a device/simulator — `sodium_libs` is not registered in the plain
  `flutter test` VM host) and a `dart format` gate (**known debt:** most of the tree is not `dart format`-clean, so
  turning the gate on today would be a repo-wide reformat commit).

### Supabase config fail-fast — embedded fallbacks removed (`ccc5a8f`)

- **`SupabaseConfig` no longer embeds the live `authenticator-dev` URL/publishable key** as a debug fallback. This
  contradicted PROJECT_INFO.md ("do not hardcode the key into the code") and let a mis-built app silently talk to the
  dev project. `url`/`publishableKey` now come ONLY from `--dart-define`.
- **`SupabaseConfig.validate({url, publishableKey})`** (pure, testable) + **`ensureConfigured()`**, called in `main.dart`
  **before `Supabase.initialize`** → a missing/invalid define throws a developer-facing `StateError` **in debug AND
  release alike** (previously release fell back silently, then — after `3b3653f` — to an empty string).
  Rejects empty/non-https URLs and empty/wrong-prefix keys; accepts both `sb_publishable_...` and a legacy `eyJ...` anon JWT.
- **`env/dev.example.json` is committed** (placeholders only); **`env/*.json` is gitignored** so the real `env/dev.json`
  never lands in git. Run with `flutter run --dart-define-from-file=env/dev.json`.
  **`flutter test` needs no defines** (it does not initialize Supabase). Android Studio / IntelliJ:
  Run → Edit Configurations → *Additional run args* (`.idea/` is ignored, so the arg is per-developer).

### Screen-capture protection — ref-counted `SecureScreen` + `SecureScreenScope` (`3a982d0`)

- **The native side does not count.** Android `addFlags`/`clearFlags` and the iOS bool flag are **last-caller-wins**, so
  the naive `initState`→enable / `dispose`→disable pattern turned protection **OFF too early**: a recovery screen opened
  above the vault disabled FLAG_SECURE on its own dispose while the vault was still visible and showing live OTP codes.
- **The counter now lives in Dart:** `SecureScreen.acquire()`/`release()` call native `enable` **only on 0→1** and
  `disable` **only on 1→0**. `enable`/`disable` are no longer public — there is exactly one way in. An unmatched extra
  `release()` is ignored (the counter cannot go negative; otherwise the next `acquire()` would miss its 0→1 transition).
  **Native (`MainActivity.kt` / `AppDelegate.swift`) is UNCHANGED.**
- **`SecureScreenScope`** binds acquire/release to the widget lifecycle (wrap the outermost widget of the page's `build`)
  → no manual pairing mistakes. **Do not call enable/disable by hand.**
- **Protected screens:** `VaultPage` (live OTP codes; migrated off the raw enable/disable it got in `3b3653f`),
  `UnlockPage` and `SetupPasswordPage` (master password typed), `RecoveryUnlockPage` (24 words + new master password),
  `RecoveryShowPage` and `RecoveryVerifyPage` (migrated to the scope).
  **Deliberately NOT protected:** `/auth-integrity` (shows no secret), scan/settings (reached from a mounted vault, which
  already holds the scope), and login/register — those take the **Supabase account** password, not the master password;
  a separate decision, left OPEN.
- **⚠️ Known limitation:** iOS has no FLAG_SECURE equivalent. Only the background/recents snapshot is hidden (opaque
  overlay on resign-active) — **screenshots and screen recording are NOT blocked on iOS.** Android blocks both.
- Tests: ref-count units (nested acquire, early-disable regression, negative guard, scope mount/unmount) + per-page widget tests.

## 2026-06-19 (security review round 1–2 + Vault/Cipher v2.0 UI refresh)

Two security review rounds and a visual refresh, none of which touch the crypto model or the server schema.
host **413/413 → 425/425 → 436/436**.

### Release manifest, password policy, recovery secrecy (`7876504`)

- **Android manifest:** `INTERNET` permission added to the MAIN manifest (it existed only in debug/profile) — **release
  builds could not reach Supabase at all.** Auto Backup disabled (`allowBackup=false`, `fullBackupContent=false`):
  `flutter_secure_storage`'s `EncryptedSharedPreferences` must not be backed up (privacy + a new-device Keystore mismatch
  would corrupt the vault).
- **Master password policy raised: min 8 → min 12 characters AND ≥3 character classes** (upper/lower/digit/symbol).
  Single source of truth in `KeyManager` (`minPasswordLength`, `minPasswordClasses`, `passwordClassCount`, `meetsPolicy`);
  the setup screen gained a **color-is-not-the-only-signal** strength meter (bar + icon + label + `Semantics`).
  *(This supersedes the "min 8" policy recorded under 2026-06-07.)*
- **Recovery key clipboard:** conditional auto-clear ~60 s after copy — it wipes **only if the clipboard still holds our
  value**, so a later copy by the user is never overwritten — plus a warning in the UI.
- **Screenshot/recents protection** introduced on the recovery show + verify screens via a `SecureScreen` MethodChannel
  (Android `FLAG_SECURE`; iOS resign-active opaque overlay). Scoped to sensitive screens only.

### Vault/Cipher v2.0 visual refresh (`de30aa6`)

- **`AppSurfaces` `ThemeExtension`** (graphite surface ramp) + the Vault/Cipher v2.0 theme, so surface colors stop being
  hardcoded per widget.
- **5 new shared components:** `status_badge`, `app_banner`, `empty_state`, `skeleton_loader`, `staggered_entrance`.
- Docs upkeep: `docs/architecture.md` translated to English, `docs/CRYPTO.md` rewritten.

### Vault reset remote cleanup, clipboard hygiene, prod config, OTP JSON (`3b3653f`)

Four review findings, each verified at the source before fixing. **host 425 → 436.**

- **[High] `resetVault` left the server vault state behind** → after a fresh setup the new masterKey could not decrypt the
  old remote rows (corruption/integrity loop). `resetVault` now **soft-deletes (tombstones)** this uid's server token rows,
  and the next `commitSetup` overwrites the stale `key_attributes` wrap (update-if-exists). **No hard DELETE / no migration**
  — the soft-delete sync model and the existing UPDATE grant are preserved. An offline/RLS failure records a timestamped
  retry marker (**`ResetPendingStore`**); the next signed-in unlock retries, tombstoning **only pre-reset rows** so a fresh
  vault's newer tokens are spared (race-safe).
- **[High] The recovery key could linger in the clipboard** — `dispose` cancelled the 60 s clear timer. `dispose` no longer
  cancels it (the wipe must outlive the screen); the callback is disposed-safe.
- **[Med] Release builds could silently fall back to the dev Supabase project.** The dev URL/key fallbacks became empty in
  `kReleaseMode` → a forgotten `--dart-define` fails loudly. *(Superseded on 2026-09-01 by `ccc5a8f`: the fallbacks are
  gone entirely and validation now fails fast in debug too.)*
- **[Low] `OtpAccount.fromJson` silently truncated fractional numbers** (`digits: 6.9` → 6). A fractional `num` is now
  rejected (`FormatException`), matching the strict `KeyAttributes` policy; integer-valued doubles are still accepted.
- Also: `OtpCard` copies the OTP with a **30 s conditional clipboard wipe**; `VaultPage` enables SecureScreen.
  `.fvmrc` committed, `.fvm/` gitignored.

## 2026-06-10 (Phase 3 Patch 4 — devices registration + catalog/feature_flags/announcements + token_sync kill-switch)

Three additional server capabilities OUTSIDE identity/sync — **WITHOUT TOUCHING the E2E surface** (NO new crypto; none of
these tables carry any secret/masterKey). Three rounds of plan review (Codex), with supabase-flutter APIs confirmed against
Context7. host **347/347 → 413/413**. The server schema is UNCHANGED.

- **`devices` registration (owner-only RLS):** on signedIn, a random `device_id` (uuid v4, GLOBAL secure storage —
  NOT hardware-derived; privacy-friendly) + register (idempotent upsert, composite PK `user_id,device_id`).
  on resume, a `last_seen` heartbeat; **0 rows → register-fallback** (recreates the resume row if the first register
  was lost to a network error). `DeviceRepository`/`SupabaseDeviceRepository` + `DeviceRegistrar` + `StableDeviceIdStore`.
  **TRADEOFF (documented):** multiple accounts on the same device → the backend can do cross-account correlation via the
  same device_id (accepted; needed for multi-device list consistency — see docs/CRYPTO.md).
- **Public read tables (READ-only; NO client write grant):** `catalog_services` (issuer catalog),
  `feature_flags` (remote flags), `announcements`. All have a repo + global cache + offline fallback.
  NO Realtime → fetch-on-signedIn + cache.
- **catalog_services → issuer canonicalization (add-token):** AFTER QR/manual parsing, the issuer is aligned to the
  catalog's canonical name (`IssuerAvatar.slugFor` shared → avatar/catalog stay consistent). **`logo_url` is IGNORED**
  (the "NO runtime logo fetching — offline/privacy" decision is preserved; no network image is downloaded). Empty catalog/no match → no-op.
- **`token_sync_enabled` kill-switch (FeatureFlagsService):** the server can remotely disable token push/pull/live.
  **The gate is INSIDE `TokenSyncService`** (Realtime bypass closed — VaultCubit's gate does not cover `_onRealtimeEvent`);
  when the flag flips to false the service self-subscribes `disableLive`, on true + livePref → `enableLive`. Before `start`, a bounded
  `ensureLoaded` (prevents the fallback from accidentally starting sync on a cache-empty first launch). **fallback=true**
  (no flag/offline → sync runs; only an explicit server `false` disables it). **It gates ONLY the token transport —
  `key_attributes` restore/backfill/update ALWAYS runs** (critical for identity recovery).
- **Announcements as a read-only section in Settings:** `audience` is a client-side filter (RLS does not filter); `all`/platform
  match. feature_flags are not shown in the UI (internal consumption only).
- **Global cache/device_id stores are NOT DELETED on vault reset** (uid-independent; PUBLIC data + the device id must
  remain the same across re-login). All new dependencies are optional/nullable → the 347 existing tests + legacy paths are byte-identical.
- **Remaining on-device (manual checklist):** devices owner-only round-trip + register-fallback; catalog/feature_flags/
  announcements public SELECT; `token_sync_enabled` kill-switch (Realtime bypass + cache-empty first launch).

## 2026-06-09 (Phase 3 Patch 3 — encrypted token sync + key_attributes UPDATE)

Encrypted TOTP tokens are synchronized with the server — with the E2E guarantee PRESERVED. A token added/deleted on one
device appears on the other; a new device restores all tokens. Also, **changePassword now UPDATES the server-side
`key_attributes` envelope** (the guarded-insert limitation from Patch 2 is GONE → a fresh restore on a new device uses the
new password). The server schema is UNCHANGED; there is NO new crypto routine. Five rounds of plan review (Codex), with every
supabase-flutter API confirmed against Context7. host **293/293 → 347/347**.

- **Only opaque data goes to the server:** `ciphertext`/`nonce` (the `OtpAccount` JSON encrypted with masterKey + XChaCha20-
  Poly1305; AAD `token|1|<id>`) + `version` + `deleted`. **The plaintext TOTP secret, masterKey,
  KEK, and recovery key NEVER do.** `updated_at`/`created_at` are not sent by the client (a server trigger overrides them).
- **Three layers + orchestrator (masterKey-free sync):** `RawTokenStore` (= the new face of
  `EncryptedVaultRepository`; `exportRaw`/`importRemote`/`markDeleted` — NO decrypt) + `RemoteTokenRepository`/
  `SupabaseTokenRepository` (opaque transport; `ByteaCodec` + `SyncError`) + `TokenSyncService` (cursor +
  push/pull/merge + Realtime). `VaultRepository` (`load/save/purgeCorrupted`) stays decrypted → the 293 tests do not break.
- **Arrival-order LWW (the server `updated_at` is the arbiter):** the client epoch-ms is NEVER compared; each record
  keeps the last reconciled server cursor (`sv`). For locally-dirty records (sv=null), the pull-cursor distinguishes echo-vs-new.
  Merge is id-based + idempotent (a double pull is harmless).
- **Soft-delete (tombstone):** deletion = `deleted=true` (no hard DELETE — there is no policy/grant on the server).
  `markDeleted` produces a tombstone from the last known blob + writes it atomically; `load()` does not show it in accounts,
  `exportRaw` returns it for push. Tombstones are preserved across saves (a token is not resurrected).
- **Realtime = a TRIGGER only (bytea #1180 double-encode):** the payload is NOT READ; the change signal triggers a REST
  `pullSince`. Order: subscribe-first → catch-up pull → idempotent merge. The subscription is tied to the VaultCubit subtree
  lifecycle (start on unlock, dispose on lock/background/signOut).
- **Malformed-remote-row QUARANTINE:** a single malformed row in a successful response is skipped + counted (the vault
  does NOT GO DOWN, NO overwrite); the cursor advances only up to the last-valid before the first-malformed (`safeCursorIso`)
  → no gap is skipped, and it is retried once the server is fixed. A network/RLS error (the whole request) ≠ a single bad row.
- **changePassword sync (Step K):** the masterKey does NOT CHANGE → NO token re-encryption; only the `key_attributes`
  row is UPDATEd (LWW). On a network error → the `attrs_dirty_v1` marker stays SET → on the next unlock dirty-replay
  retries again (a real retry; CLEARed on success). If two devices conflict the last-arriving wins (no data loss —
  the loser keeps working with its local attrs; the recovery envelope does not change).
- **Push is best-effort (silent), pull is a self-healing reconciler.** Conflicts are silent LWW (no notification to the user).
- **UI:** a "Live sync" toggle in Settings (per-uid `live_sync_enabled_v1`, off by default; even when off, a
  catch-up sync runs at launch). A sync indicator in the VaultPage AppBar (`syncing`/`error`/`malformedCount`; a11y Semantics).
- **`uid==null` (legacy/no-uid) → all sync is INERT; the behavior + the 293 tests are IDENTICAL.**
- **DELIBERATE limits:** token sync only while unlocked; a locked background raw-pull is out of scope. Force re-wrapping
  other devices via push is out of scope (not needed; a provisioned device works with local attrs). Tombstone GC is future work.
- **Manual/integration checklist (on-device):** a real bytea token INSERT/SELECT round-trip against Supabase +
  Realtime trigger → REST pull + new-device token restore + soft-delete cross-device + LWW + post-changePassword
  fresh-restore with the new password + malformed-row quarantine.
- **Implementation-review fixes (3 findings, confirmed from source):**
  - [P1] **Merge writes are now UNDER the VaultCubit sequencer:** `TokenSyncService` does NOT call `importRemote`
    DIRECTLY; the `mergeRemote` callback → `VaultCubit.applyRemoteMerge` (import+reload in a SINGLE critical section,
    `_opChain`) → no race with concurrent user add/delete/increment (data loss closed).
  - [P2] **Push is REALLY best-effort:** in `syncOnce`, push is in its own `try/catch` → a push failure does NOT
    BLOCK the pull (other devices' changes are still pulled).
  - [P2] **Live-preference race:** instead of a `_liveAtStart` setter, a `liveSyncResolver` (async) → `load()` `await`s it
    BEFORE start → a persisted `live=true` is applied for certain at the start of unlock (it subscribes).
  - **Round 2 (2 findings):** [P1] **advancing-without-merge:** if the vault closes during an in-flight sync,
    `applyRemoteMerge` returns `null` (merge NOT APPLIED) → `syncOnce` does NOT ADVANCE the cursor (old behavior: it still wrote →
    the cursor advanced before remote rows hit disk, and the next pull would skip them = token sync data loss). [P2]
    **`purgeCorrupted` moved into the sequencer** (so the purge disk write does not race with the sync import / mutations — a single write queue).
  - host **340→347** (+7: push-fail-pull, applyRemoteMerge import+reload, sequencer-serialize, persisted-live-true/false,
    merge-null→cursor-does-not-advance, applyRemoteMerge-closed→null).

## 2026-06-08 (Phase 3 Patch 2 — key_attributes upload/restore)

The crypto **metadata** (`key_attributes`: KDF parameters + the master key already-encrypted with the KEK/recovery) is
backed up to the server and **restored on a new device** — with the E2E guarantee PRESERVED. The user can now sign in to
Supabase on a new device and open the vault with their master password (tokens do not arrive yet — Patch 3).
**NO token sync.** The server schema is UNCHANGED. Three rounds of plan review + two rounds of implementation review (Codex),
with every API confirmed from the `.pub-cache`/Context7 source. host **257/257 → 293/293**, APK debug build OK.

- **Only already-encrypted metadata goes:** `encrypted_master_key`/`recovery_encrypted_master_key` +
  KDF `salt/ops/mem` + nonces. **The masterKey, KEK, recovery key, and plaintext TOTP secret NEVER go to the server.**
  `bmk` (the biometric wrap) does not go either (device-local; there is no column for it in the server schema → a new
  device re-enrolls).
- **bytea interop at a single point (`ByteaCodec`):** PostgreSQL `bytea` ↔ `Uint8List` (`\x`+hex). A local
  `EncryptedBlob` keeps nonce+ciphertext TOGETHER; the server has SEPARATE columns → on upload the blob is SPLIT IN TWO,
  on restore it is reconstructed from the two columns. The bytea JSON-body INSERT format is an explicit risk to be verified
  on-device → isolated in a single file (fixed there if needed; the schema does not change).
- **Restore (new device):** `VaultLockCubit.bootstrap` fetches from the server if there are no local attrs. **A
  `restoring` state BEFORE the fetch STARTS** → router `/splash` (spinner), **the user does NOT SEE `/setup`** (cannot set
  up a new vault before the fetch finishes → double-vault prevented). remote EXISTS → write locally + `locked` (the master
  password is asked); a genuine 0-row → `uninitialized` (setup); **network/RLS error → a separate `restoreFailed` screen**
  (`/auth/restore-failed`: retry + switch account; NO password/recovery/biometrics) — it does NOT FALL to `uninitialized`
  (so you cannot set up a wrong password and clobber the server vault). `SyncError` cleanly separates a genuine 0-row.
- **Upload (backfill):** when the vault becomes `unlocked` (unlock/recover/commitSetup), a best-effort guarded insert
  inside `VaultLockCubit`: if a record EXISTS on the server do NOT OVERWRITE it (server-wins; the changePassword multi-device
  sync was DELIBERATELY deferred to Patch 3's `updated_at` LWW). Best-effort: it does not block the user, errors are silent.
- **Router guard (review [P1] location-loss fix):** in the `sessionGuard` signedIn branch, the special vault statuses
  (`restoring`/`restoreFailed`/`keyAttributesCorrupted`) are handled with the REAL `location` BEFORE the `splash`/auth rewrite
  → `null` while already at the target (no redirect loop). Side benefit: the same latent location-loss bug for the existing
  `keyAttributesCorrupted` is also closed.
- **No regression:** `VaultLockCubit.remoteRepo`/`uid` are NULLABLE → legacy/no-uid vaults and Patch 1 tests preserve the
  old behavior identically (restore/upload no-op). uid is derived from the prefix (`'<uid>/'`→`'<uid>'`; empty→null).
- **Restore local-finalize error (post-review [P2] fix):** if the remote fetch succeeds but `attrsStore.write`
  (Keychain/Keystore IO) throws, the error used to bubble up from the `bootstrap` future and leave the state stuck at
  `restoring` (router hangs at `/splash`, no retry). `_restoreFromRemote` now also converts unexpected errors OTHER than
  `SyncError` to `restoreFailed` (safe + retryable; it does not fall to `/setup`, no unhandled future).
- New tests: `bytea_codec_test`, `supabase_key_attributes_repository_test` (mapping round-trip + bmk
  is not sent), `vault_lock_cubit_test` (+restore 9 scenarios: fetch-pending→`restoring`, network→`restoreFailed`,
  retry, upload-guard), `restore_failed_page_test` (NO password/recovery), `guard_test` (+restoring/restoreFailed
  + location-loss regression). **293/293 host, analyze clean, APK debug build OK.** The real bytea network flow = manual checklist.

## 2026-06-08 (Phase 3 Patch 1 — Supabase identity / auth)

An **identity layer** was added to the app (Supabase email/password): registration/sign-in/sign-out + email confirmation.
An identity gate was added at the outermost layer of the vault E2E flow (master password/unlock/biometrics), **preserving its
internal logic**. **NO sync** (Patch 2–3). Designed across twelve rounds of external review (Codex), with every API confirmed
from the `.pub-cache`/Context7 source. host **220/220 → 257/257**, APK debug build OK.

- **Two independent "gates" (in sequence):** the Supabase session (identity) → the vault lock (E2E). The combined guard
  keeps the identity gate OUTERMOST; the vault guard (the shell requiring masterKey) only in the `signedIn &&
  !linkRequired` branch. `/splash` throughout `unknown` (the vault shell is not rendered before `signedIn`
  → no `masterKey` crash). The login password ≠ the master password; they do not **derive** each other.
- **`SessionCubit`** + `SupabaseAuthRepository`: `signUp`/`signInWithPassword`/`signOut`;
  `onAuthStateChange` **`onError` is MANDATORY** (gotrue surfaces a network error as a stream error → without it the
  app crashes). `AuthException.code` → mapped to domain errors (`email_not_confirmed`/`invalid_credentials`/
  `email_exists`/`weak_password`, confirmed from source).
- **Email confirmation is MANDATORY** (PKCE + deep-link `dev.mustafakara.projectauth://login-callback`):
  Android intent-filter (VIEW+DEFAULT+BROWSABLE) + iOS `CFBundleURLTypes`. `emailConfirmPending`
  is PERSISTED (`auth_pending_email_v1`) — on re-launch it returns to the confirmation screen; "Use a different email"
  clears pending and signs out (a guard trap is avoided).
- **signOut safety:** the local vault volatile cleanup (`VaultLockCubit.onAuthSignedOut`) runs BEFORE the network
  signOut — at EVERY stage including setup/unlock/biometric, the masterKey/mnemonic is wiped
  (a separate general method since `lock()` is a no-op in `setupPending`; the commit-in-flight rule is the same as `:400`).
  **`SignOutScope.global`** (a user decision — revokes all the device's refresh-tokens on the server); `signedOut` is
  reached EVEN on a network error (gotrue deletes the local token first — #683; an offline guarantee).
- **SIGN-IN with an unconfirmed email (post-review [P2] fix):** on `AuthEmailNotConfirmed`, `signIn` PERSISTs the
  pending email + emits `emailConfirmPending` → the `/auth/confirm` screen sees the email filled in, and resend
  works (in the previous state email=null → resend was a no-op + the user was stuck).
- **Per-uid view mode (post-review [P3] fix):** `VaultPage` now reads the `ViewModeStore` provided by the ShellRoute
  (namespaced to the active uid) via `context.read` instead of a global singleton (standalone/test fallback to
  global). User A's card/list preference does not leak to B; a namespaced reset also clears the view-mode.
- **Root session-listener ownership (post-review [P3] fix):** the `SessionState` subscription in `main` is now
  held in a `StreamSubscription` field + canceled in `dispose` + the async error path is preserved via `onError`
  (no leak into the zone). Previously the anonymous listener was not owned (leak + crash risk).
- **uid-namespace isolation priority (post-review [P3] fix):** on a uid change, `main._onSession`
  FIRST moves the in-memory vault stack to the correct uid namespace, THEN persists the active uid
  (best-effort). Even if `setActive` (secure storage) fails, the user stays in the correct namespace —
  it does NOT SILENTLY STAY on the legacy `''` stack (wrong-vault leak prevented); the persist is retried on the next launch.
- **Multi-vault per uid:** a SEPARATE local vault namespace for each Supabase uid (`'<uid>/'` prefix;
  stores take a `keyPrefix`, empty = Phase 2 byte-identical). `vault_active_uid_v1` (active uid) +
  `legacy_link_decided/<uid>` (a per-uid decision). On the first login, if a no-uid Phase 2 vault exists, an **explicit
  account-linking confirmation** (`/auth/link`): "link" (migrate + CLEAR `bmk` + `biometric.disable`
  → re-enroll) / "a new empty vault". Either choice marks the decision → `linkRequired` clears
  (no guard loop). `linkRequired` is a SYNCHRONOUS `SessionState` field (the guard does not read async storage).
- **Config:** `String.fromEnvironment` + a dev fallback (aligned with PROJECT_INFO); `publishableKey`
  (anon, behind RLS). `sb_secret_` never in the client. The server schema is unchanged (bytea; hex codec in Patch 2+).
- New tests: `session_cubit_test` (+linkRequired hydrate bridge, signOut-throw, onError, cancel),
  the `sessionGuard` group, the `onAuthSignedOut` group (including commit-in-flight), `multi_vault_namespace_test`,
  `auth_pages_test`. **257/257 host, analyze clean, APK debug build OK.**

## 2026-06-08 (Phase 2 Patch 5 — biometric vault unlock)

A biometric unlock shortcut was added — **without weakening the E2E password model**. The masterKey
always opens with the password + recovery key as well; biometrics only opens a 3rd wrap path.
Designed across five rounds of external review (Codex) + every API confirmed from the `.pub-cache` source
(no blind acceptance). host **186/186 → 219/219**, integration +3.

- **The security boundary = OS keystore access control** (NOT the `local_auth` bool).
  `biometricKey` (32-byte random) wraps the masterKey with the `masterkey-biometric|1` AAD →
  `KeyAttributes.biometricEncryptedMasterKey` (an optional `bmk` field; existing vaults
  are byte-identical, no version bump). The raw `biometricKey` lives in `vault_biometric_key_v1`, in **a
  separate-options/namespaced** secure storage with biometric access control:
  - **iOS:** `useSecureEnclave: true` + `AccessControlFlag.biometryCurrentSet` →
    the key is AUTOMATICALLY invalidated when the biometric set changes (open with password + re-enroll;
    no token loss).
  - **Android:** `AndroidOptions.biometric(enforceBiometrics: true,
    strongBiometricOnly)` → bound in the Keystore to strong biometrics only (PIN/pattern
    are rejected); `strongBiometricOnly` → `biometricPromptNegativeButton` is required.
- **The real prompt = the `storage.read()` OS gate** (a SINGLE prompt). `local_auth` is only an
  availability check → **no double prompt** (reviewer round 2). The `biometricKey` bytes are
  NEVER cached in Dart; after use, `fillRange(0)`.
- **State model:** `biometricEnrolled` (attrs.bmk) + `deviceBiometricAvailable` (device
  capability, independent of enrollment) are kept SEPARATE — the UnlockPage button is the intersection of the two,
  the Settings enable switch looks at `deviceBiometricAvailable` (without which a new user could never
  enable it — reviewer round 3 deadlock). ALL `locked`/`unlocked` emits preserve these fields via the central
  `_locked()`/`_unlocked()` helpers (reviewer round 4).
- **Atomicity:** `enableBiometric` order is OS-key-write → attrs-write; if attrs.write fails →
  clean up the orphan OS key with `biometric.disable()` + the state does not change. `biometricUnlock`
  on `KeyMissing` → `bmk` is CLEARed from PERSIST (avoids a bootstrap loop); on write fail →
  shown as off in the UI (no loop). `resetVault` + `disableBiometric` explicitly
  call `BiometricService.disable()` (a separate namespace → the default `_deleteKeys` is not enough).
- **Lifecycle:** the `inactive` produced by the biometric system prompt (`_biometricPromptInFlight`)
  does NOT ABORT a successful unlock; `paused` (a real background) still aborts for certain. `main.dart`
  delivers `paused`/`inactive` separately.
- **Android API<28:** an `sdkInt >= 28` gate via `device_info_plus` (`getAvailableBiometrics`
  does not gate the SDK; `enforceBiometrics` would throw a native exception on <28 — reviewer round 4).
- **Native:** `MainActivity` → `FlutterFragmentActivity`, `AndroidManifest` `USE_BIOMETRIC`,
  `styles.xml`+`values-night/styles.xml` `Theme.AppCompat.DayNight.NoActionBar` (local_auth
  Android 8 crash prevention), iOS `NSFaceIDUsageDescription`. `flutter build apk --debug` passed.
- **[P2 review fix] Settings switch:** in the `enrolled && !deviceAvailable` case (the biometric
  set changed/lockout) the switch was fully disabled → the user COULD NOT TURN IT OFF from Settings.
  The comment described the correct invariant, but `onChanged: !deviceAvailable ? null`
  also locked turning it off. Fix: enable if the device is available, **disable independent of availability**
  (`enrolled || deviceAvailable`). +1 test (enrolled+unavailable → can be turned off).
- **Verification:** `flutter analyze` clean · host 220/220 · integration 12/12 · `flutter build
  apk --debug` passed · `BiometricServiceImpl` (real OS/local_auth) requires a device → manual
  checklist [docs/CRYPTO.md §11].

## 2026-06-07 (Phase 2 Patch 4 — commitSetup write-fail atomicity, round 3)

- **[P2] `commitSetup()` `_attrsStore.write()` fail + background.** The previous round closed the migration-fail
  path, but `write()` was a separate async point: if `write()` fails the code NEVER enters the migration
  catch and falls to `finally`, and `finally` only sets `_commitInFlight=false`
  → `_masterKey`/`_pendingAttrs`/`setupPending` stayed alive. If the app had backgrounded in the meantime
  (since `onAppBackgrounded` does not call `cancelSetup` while commit is in-flight) the masterKey would stay
  in memory in the background (ARCHITECTURE §2.3 violation). **Fix:**
  `write()` was wrapped in its own `try/catch` → on write fail, dispose the key + clear pending +
  `uninitialized` (write fail = NOTHING written to disk → vault not set up → unlike migration-fail the correct
  state is `uninitialized`, not `locked`) + rethrow. Now at every async exit of commitSetup
  (write-fail / migration-fail / background-abort / success) the key is guaranteed to be handled.
- **[P3] Full-intersection regression test.** The first write-fail test only verified the cleanup
  but had NO background call; the existing background test waited in `_migrate` AFTER write FINISHED —
  i.e. the full "background while `write()` is in flight, THEN write fails" intersection had not been
  tested. A `writeGate` (Completer) was added to `FakeSecureStorage`: while write is hanging in
  `_attrsStore.write()`, `onAppBackgrounded()` is triggered, then write throws. The expected behavior was
  verified — write-fail cleanup (uninitialized + dispose) wins; since `_commitInFlight=true`,
  `onAppBackgrounded` does not call `cancelSetup`, and cleanup happens via a single path (the write catch).
- **Verification:** `flutter analyze` clean · host **186/186** (+1: commitSetup write-fail →
  uninitialized + dispose; +1: write-hanging-background intersection regression) · integration
  **34/34** · `git diff --check` clean.

## 2026-06-07 (Phase 2 Patch 4 — lifecycle lock edge cases, round 2)

Three edge cases not closed in the previous lifecycle round (review, confirmed from source):

- **[P1] `beginSetup()` background race.** If the app backgrounds while `KeyManager.setup()` (Argon2id/KEK)
  is in progress, `onAppBackgrounded` (state `uninitialized`) only set
  `_abortToBackground=true`; since `beginSetup` did not check this flag, it would take the masterKey + mnemonic
  into memory when done and emit `setupPending` →
  the key/mnemonic stayed alive in the background. **Fix:** `beginSetup` checks the flag after the await
  → if set, dispose the generated key + `uninitialized` (no persist).
- **[P1/P2] background during `locking` before the frame arrives.** Interactive `lock()`
  defers the dispose to a post-frame; if the app backgrounds in the meantime, `onAppBackgrounded`
  was doing a `break` in the `locking` case → if the frame never arrives the key stayed in memory. **Fix:**
  the `locking` case now does a SYNCHRONOUS dispose + `locked`. The stale post-frame callback
  is status-guarded → no-op.
- **[P2] `commitSetup()` migration-fail was not atomic.** If `_migrate` fails after `attrs` is
  written, the function rethrows but `_masterKey`/`_pendingAttrs`/
  `setupPending` stayed; while attrs is on disk the user hits "cancel" → `cancelSetup` does not
  delete attrs → an inconsistent "uninitialized but bootstrap locked". **Fix:** on the migration-fail
  path too, dispose the key + clear pending + emit `locked` (the vault is REALLY set up —
  attrs is on disk; migration is idempotent/commit-marked → the next unlock retries)
  + rethrow (the UI shows the error). It no longer returns to `setupPending` → no cancel inconsistency.
- **[P3] Doc drift:** OTP_ENGINE.md still said 180/180 → 184/184.
- **Verification:** `flutter analyze` clean · host **184/184** (+3: beginSetup background-abort,
  locking-no-frame synchronous dispose, commitSetup migration-fail atomic-locked) · integration
  **34/34** · `git diff --check` clean.

## 2026-06-07 (Phase 2 Patch 4 — lifecycle lock security holes + doc/test alignment)

The review found two lifecycle security risks (confirmed from source, both real):

- **[P1] An async unlock/recover/commit continuing during background later emitted
  `unlocked`.** Scenario: the user taps "Open", the app becomes `paused`/`inactive` while
  Argon2id/migration is in progress; `onAppBackgrounded()` does nothing because it still sees the state
  as `locked`; when the async op finishes the app would become `unlocked` WHILE IN THE BACKGROUND (the key
  in memory, the vault open). **Fix:** an `_abortToBackground` guard. `onAppBackgrounded`
  sets the flag if it sees `locked`/`uninitialized`/`keyAttributesCorrupted`/`setupPending`;
  `unlock`/`recoverWithNewPassword`/`commitSetup` check the flag BEFORE emitting `unlocked`
  → if set, dispose the key + `locked` (the vault does not open). In `commitSetup`, if attrs
  was already written the correct state is `locked` (not uninitialized).
- **[P2] `lock()` tied the master-key dispose to `addPostFrameCallback`; since a frame is not
  guaranteed in `paused`, the key could stay in memory.** **Fix:** `lock({bool immediate})`.
  `onAppBackgrounded` disposes the key SYNCHRONOUSLY via `lock(immediate: true)` (security
  priority — ARCHITECTURE §2.3 "wiped on backgrounding"). The interactive "Lock"
  button uses `immediate: false` → the framed soft teardown (no use-after-free) is preserved.
- **[P3] Doc/test alignment:** the old test counts in PLAN.md/OTP_ENGINE.md were updated
  (host 181/181). `MnemonicGrid` is now a `SelectableText` (Design.md §3.2 contract +
  wraps at textScaler 2.0). The Design.md `OtpCard` line was pulled to reality (NO separate copy
  icon button, tap-to-copy). A textScaler 2.0 overflow test gate was added for the recovery grid (Design.md §5).
- **Verification:** `flutter analyze` clean · host **181/181** (+5: 3 P1 race tests —
  unlock/recover/commit background-abort + 1 P2 synchronous-dispose/interactive-lock distinction +
  1 recovery textScaler overflow) · `git diff --check` clean.

## 2026-06-07 (Phase 2 Patch 4 — automatic reinstall-reset REVERTED)

A `FirstRunGuard` (a SharedPreferences first-launch flag) had first been added for the iOS "I deleted the app,
it still asks for a password" issue; if the flag was missing, the Keychain residue would be
wiped and a clean setup performed. **Review P0 release blocker:** a single boolean flag
cannot distinguish a "clean reinstall" from "an existing user installed BEFORE this patch" — in
both there is no flag but there is a real vault in the Keychain. When an existing user takes this
patch and opens it for the first time, the flag is treated as absent → `bootstrap` deletes
`VaultStorageKeys.all` → **the existing user's vault is lost.**

- **Decision (user):** the feature was fully reverted. The iOS Keychain not being cleared on
  app deletion is Apple's deliberate decision and cannot be auto-detected without putting existing
  users at risk. The data-loss risk was reduced to zero.
- **Reverted:** `FirstRunGuard` + its test were deleted; the
  `isFreshInstall` hook in `VaultLockCubit` + the wipe in bootstrap were removed; the `main.dart` wiring was
  reverted; the `shared_preferences ^2.5.5` dependency was removed from the pubspec.
- **Current path:** if the user wants to clear the vault, they use the existing
  **"Reset vault"** (double-confirmed, `resetVault()` → 5 keys) flow.
- **Verification:** `flutter analyze` clean · host 176/176 (the previous +5 reverted).

## 2026-06-07 (Phase 2 Patch 4 — auth screens redesign + recovery UX)

In the first round of Patch 4 the auth screens were left "functional/unpolished" (the visual
redesign had been applied only to the vault/OtpCard). This round **the entire auth flow was pulled into the
Design.md language** + a critical recovery UX issue was resolved. Visual verification:
6 screens × dark/light were rendered on the iOS simulator and confirmed via screenshots.

- **Recovery key display (UX critical):** the 24 words used to be in a vertical `ListTile`
  list → the user could not see all of them on one screen, could write down half, tap
  the "I wrote it down" checkbox, and proceed. The new `MnemonicGrid`: **a 2-column ×
  12-row numbered grid** (left 1–12, right 13–24), GeistMono words → all 24 visible on a single
  screen. A copy button + an "I backed up the 24 words" confirmation (Continue disabled until
  checked). The verification behavior (3 words + 3-attempt limit) is UNCHANGED — a user decision.
- **"Copy to clipboard" numbered format:** previously `words.join(' ')` → just the words,
  no sequence number (after pasting the user could not tell which word was which). Now
  `1. lizard\n2. goddess ...` (each line numbered). `RecoveryUnlockPage` input parsing
  was also hardened: if the numbered backup format is pasted, the sequence prefix (`12.`/`12)`/`12-`)
  is stripped → the user can paste the copied key back directly; plain space-separated input
  also works (regression-tested).
- **Shared auth UI layer** (`lib/core/ui/widgets/`): `AuthScaffold` (icon +
  title[headlineSmall] + description[onSurfaceVariant] + a scrollable body + a fixed
  bottom CTA; safe-area + consistent `Gap` spacing + no dynamic-type overflow), `AppTextField`
  (visible label + show/hide + inline error + helper), `MnemonicGrid`, `auth_bits`
  (AuthErrorText + BtnSpinner). `monoWord` added to `app_theme` (the GeistMono recovery word).
- **6 auth screens rewritten:** setup_password, recovery_show, recovery_verify,
  recovery_unlock, unlock, auth_integrity → all use `AuthScaffold`/`AppTextField`,
  tokens, Geist typography, a single primary CTA (Design.md §3/§4). The "unpolished version"
  comments are gone.
- **vault_page state-views + scan_page:** `_EmptyView`/`_NoMatchView`/
  `_IntegrityErrorView` + the search padding were pulled to tokens; `_ScanError` token +
  textTheme (the raw `Colors.grey`/fixed spacing is gone; the reticle overlay color was deliberately preserved).
- **Verification:** `flutter analyze` clean · host 176/176 (no regression; +3:
  recovery_unlock numbered-parse + plain-input, recovery_show numbered-copy) · iOS
  simulator visual verification (6 screens, dark+light). The `recovery_verify_page_test`
  behavior was preserved (the TextFormField → TextField render matches via `find.byType`).

## 2026-06-07 (Phase 2 Patch 4) — Setup/Unlock UI + session lock + UI/UX redesign

The vault now has a real lock/session flow and the entire interface is in one consistent design
language ("Precision/Technical"). First the boundaries were locked down with `docs/Design.md`, then the
security core → corruption UI → visual redesign were applied in that order (regression
isolation). **Host tests 122 → 173/173.** All findings confirmed from source.

- **`docs/Design.md`:** the design language, tokens, component inventory, accessibility
  contract, asset licenses (Geist OFL 1.1, simple-icons CC0 — confirmed from source).
- **Session core:** the `VaultLockCubit` state machine (`uninitialized`/`setupPending`/
  `locked`/`unlocked`/`locking`/`keyAttributesCorrupted`) + a single key-ownership model
  (lock: `locking`→subtree teardown→`masterKey.dispose()`→`locked`; no use-after-free).
  `KeyAttributesStore` (malformed→`keyAttributesCorrupted`, no leak). Setup commit
  **does NOT persist before recovery is verified**; recover+new password is a single atomic call.
- **Router:** `createAppRouter`→`AppRouterBundle` + its own `CubitRefreshNotifier` adapter
  (**there is NO `GoRouterRefreshStream` in go_router 17.3.0** — confirmed from source; CHANGELOG:693).
  The refreshListenable is disposed at the root widget (go_router does not dispose it). The guard covers all states;
  the `ShellRoute` provides `VaultCubit` in the unlocked subtree (scan/add only there).
- **Lifecycle lock:** `paused` AND `inactive` → unlocked locks, setupPending is cleared.
- **Corruption/integrity UI:** a VaultPage `corruptedCount` banner (Continue anyway /
  confirmed remove) + a `VaultIntegrityException` integrity screen (NOT an empty-state) +
  `/auth-integrity` (Retry / Reset vault) + `resetVault()` (deletes 5 keys;
  including plaintext+marker → it is not re-migrated).
- **UI/UX redesign:** Geist + GeistMono **embedded** (no runtime fetch; Turkish glyphs confirmed;
  `google_fonts` is NOT USED), a trust-blue palette + a `CountdownColors` `ThemeExtension`,
  `CountdownRing` (green→amber→red + seconds in the center, <5s pulse, off under reduced-motion),
  `IssuerAvatar` (simple-icons CC0 curated 27 icons + initial fallback), `OtpCard` (card/list
  variant + tap-to-copy + Semantics), a card/list toggle (`vault_view_mode_v1` secure_storage),
  a ScanPage corner-guided reticle.
- **Accessibility gate:** Semantics (code + remaining time), no overflow at textScaler 2.0,
  no reduced-motion crash — via widget tests.
- **DI/main:** the global `VaultCubit` was removed; the root `StatefulWidget` holds the `VaultLockCubit` + router
  bundle, watches the lifecycle, and disposes `bundle.refresh`.
- **Patch 4 hardening (review round — 6 findings, all confirmed from source):**
  - **(P1) masterKey migration-fail lifecycle:** `unlock`/`recoverWithNewPassword` now
    own the masterKey only after migration SUCCEEDS; if migration throws, the
    key is disposed in `finally` and it does not transition to `unlocked` (the "live key in
    locked state" invariant is preserved).
  - **(P1) guard setup sub-routes:** while `uninitialized`, only `/setup` (the recovery-show/
    verify sub-routes are blocked) — a deep-link to `/setup/verify` before the mnemonic exists
    produced a `RangeError`. The subtree is open only in `setupPending`.
  - **(P2) setup restart:** `beginSetup` disposes the previous pending masterKey (it does not overwrite
    and leak it).
  - **(P2) recovery-verify attempt limit:** on a wrong word, now an inline error + remaining attempts;
    after 3 wrong ones, `cancelSetup()` (the pending key is disposed). It does not hang in memory
    indefinitely, but a single typo does not force setup from scratch (a user decision).
  - **(P2) integrity screen reset:** a double-confirmed "Reset vault" last resort was added to the
    fully-corrupted `_IntegrityErrorView` (same pattern as AuthIntegrityPage).
  - **(P3) CountdownRing critical threshold:** `forFraction(5/30)` → `forRemaining(remaining, period)`
    ABSOLUTE seconds; correct when period≠30 (with period=60 the last 5s is critical, not 10s; with period=15
    3s is critical). Aligned with Design.md.
- **Patch 4 hardening (2nd review round — 3 findings, all confirmed from source):**
  - **(P1) mutation-before-load-finishes data loss:** `VaultCubit` mutations (add/remove/
    increment/purge) now **wait** until the first `load()` completes (via a `Completer`).
    The previous `_mutatedBeforeLoad` merge only fixed memory; if `save()` was called before load
    finished, the not-yet-read encrypted records on disk were OVERWRITTEN (writing while `_lastById`/`_corruptedRaw`
    was empty). `load()` is also idempotent (a single first-load).
  - **(P2) lifecycle lock safe order:** `onAppBackgrounded` now delegates directly to
    `lock()` in `unlocked` (locking → subtree teardown → post-frame `masterKey.dispose()`).
    Previously it disposed immediately → a use-after-free risk on a disposed `SecureKey` while the
    repo was doing async encrypt/decrypt. `setupPending` → `cancelSetup` (no consumer, immediately safe).
  - **(P3) integrity reset test:** the double-confirmed "Reset vault" → `resetVault()` flow on the
    fully-corrupted integrity screen was closed with a widget test (data-destructive).
- **Patch 4 hardening (3rd review round — 1 finding, confirmed from source):**
  - **(P1) adding while in integrity state = unconfirmed overwrite:** full corruption (top-level
    malformed/non-list or all-records decrypt-fail) makes `load()` throw early → `state.error`
    is set, `accounts` is empty, the repo cache (`_corruptedRaw`/`_lastById`) is EMPTY. In this state, while `VaultPage`
    shows the integrity screen, **the FAB was still active** → a manual/QR add → `VaultCubit.add` →
    `save()` runs and, with the empty cache, writes only the new token and **would overwrite the
    corrupted-but-maybe-recoverable raw vault on disk WITHOUT the user's explicit "Reset vault" confirmation.**
    A two-layer fix: (a) **`VaultCubit` `_guardIntegrity()`** — while `state.error != null`,
    add/remove/increment throw a `StateError` (the UI `_runMutation`/`_addAndClose` catch it →
    SnackBar); (b) the **VaultPage FAB** is hidden in the integrity state (`integrityBlocked`). +3 tests.
- **Verification:** `flutter analyze` clean, host 173/173, `flutter build apk --debug` +
  `flutter build ios --debug --no-codesign` passed. Asset delta ~912KB raw (curated; lean).

## 2026-06-07 (Phase 2 Patch 1–3) — E2E crypto layer + encrypted local vault

The core of Phase 2: the vault now works offline **but not as plain JSON — E2E encrypted**.
Each patch went through multi-round external review; **all findings confirmed from source (Context7/pub.dev/
the installed package source)** (standing rule) — some plausible-but-wrong claims were dismissed
(the sodium version, `runIsolated` arity). UI/route/DI rewiring + biometrics in Patch 4–6.

- **Patch 1 — `core/crypto/`:** `CryptoService` (abstract) + `SodiumCryptoService` (SodiumSumo).
  XChaCha20-Poly1305 IETF (with AAD) + Argon2id (KEK, **a separate isolate** — does not block the UI).
  `EncryptedBlob`/`KeyHandle` (opaque, `SecureKey` does not leak) + `crypto_exceptions`.
  **Version decision:** `sodium 3.4.6 + sodium_libs 3.4.6+4` — sodium 4.x requires Dart 3.11+,
  the project is on Dart 3.10.7. Details in [docs/CRYPTO.md](docs/CRYPTO.md).
- **Patch 2 — key hierarchy:** `KeyManager` (setup/unlock/recoverUnlock/changePassword,
  all Future, intermediate keys disposed/zero-filled in `finally`). The `KeyAttributes` value object.
  **Our own BIP39 impl** (the canonical package is unmaintained → not brought into the trust boundary): the official 2048
  words (MIT, SHA-256 confirmed), 256-bit, checksum-verified; tested with the official Trezor vectors.
  A domain password policy (`WeakPasswordException`, min 8) — *superseded 2026-06-19: min 12 + ≥3 character classes*.
- **Patch 3 — encrypted vault + migration:** `EncryptedVaultRepository` (a token-based record
  `{id,v,n,c,updatedAt,deleted}`, AAD `token|1|<id>`, **unchanged-blob protection**,
  **corrupted-record protection** — including scalar/null, **with an integrity exception** so no silent
  data loss). `VaultMigration` (Phase 1 plaintext → encrypted, commit-marker idempotency,
  **id-based upsert** — does not overwrite what exists after a crash). The `VaultRepository` interface expanded
  (`load()→VaultLoadResult`, `purgeCorrupted()`). Raw-storage security test:
  secret/issuer/accountName appears **nowhere** outside the ciphertext.
- **Strict validation (review):** `EncryptedBlob`/`KeyAttributes` parsing rejects corrupted/forward-version
  metadata before it reaches sodium (nonce=24B, ciphertext≥16B, salt=16B, KDF a positive
  integer, a supported version; a fractional `num` is not silently truncated).
- **Tests:** host **79 → 122** (EncryptedBlob/KeyAttributes JSON+validation, BIP39 +
  official vectors, vault corruptedCount). **Integration 34** (device/sim — real libsodium):
  sodium service 8 + KeyManager 8 + encrypted vault/migration 18. `analyze` clean, APK + iOS
  build passes. (The libsodium tests are in `integration_test/` — `sodium_libs` is not loaded in the plain `flutter test`
  VM host.)

## 2026-06-07 (round 3) — JSON type-safety + error handling on all mutations (review)

The external review gave 4 more findings (2 medium + 2 low); **all confirmed from source, all real** and fixed. (The previous round's add/QR fixes were confirmed closed; this round covers the remaining edge cases.)

- **#1 (medium) — `fromJson` casts could produce a `TypeError`:** the `as String?`/`as num?`
  casts threw a `TypeError`, NOT a `FormatException`, on corrupted stored data like `type: 123` /
  `digits: "6"` → the `on FormatException` in `load()` cannot catch it, and a single bad record broke the entire
  load. **Fix:** type-tolerant `_asString`/`_asInt` helpers (wrong type →
  `FormatException`; a numeric String → flexibly to int). `VaultRepository.load()` is now safe
  with a general per-record `catch` (beyond FormatException) + the key `_coerceStringKeys`.
- **#2 (medium/low) — the UI did not catch delete/HOTP counter-increment persistence errors:** `onDelete`/
  `onIncrement` were fire-and-forget via a `VoidCallback` (add/QR had been fixed but these two were
  left behind). If save blew up the user thought it succeeded, and on restart the change reverted.
  **Fix:** `VaultPage._runMutation(Future, errorPrefix)` — it `await`s the mutation and shows a
  SnackBar on a save error (the in-memory state is current but it informs if the write failed).
- **#3 (low) — the `mounted` guard was missing on a QR save error:** the `_onDetect` catch did `_showError` →
  it used `context`; a disposed-context risk if the user had left. **Fix:** `if (!mounted) return`
  at the top of `_showError` (consistent with the protection in the add sheet).
- **#4 (low) — Doc drift:** the `PLAN.md` CI line still said "67/67" (the rest of the file is 75) →
  updated.
- **Tests:** +4 (wrong-type type/digits rejection, numeric-String tolerance, remove/increment save-error
  throw) + wrong-type record scenarios in the load test. **75 → 79, all pass; `analyze` clean.**

## 2026-06-07 (round 2) — Persistence resilience + async error handling (review)

The external review gave 5 findings (2 medium + 3 low); **all confirmed from source, all real** and fixed. The APK + iOS build also passed (by the review).

- **#1 (medium) — JSON loading bypassed parser validation:** `OtpAccount.fromJson`
  did no Base32/digits/period/counter check → a corrupted record would crash on `OtpCard` render/timer
  (`secretBytes`, `period=0` division). **Fix:** validation was pulled to a SINGLE point —
  the `OtpAccount` ctor now calls `validate()` (secret Base32, digits 6–8/Steam 5, period 1–600,
  counter ≥0). So parse, fromJson, and programmatic construction all go through the same safety gate;
  an invalid `OtpAccount` cannot be created via any path. Also, `VaultRepository.load()` now catches the
  top-level `jsonDecode` error (previously the whole load blew up) → falls back to an empty vault.
- **#2 (medium) — the `add()` future was not awaited:** manual/QR add was calling `add()` fire-and-forget;
  a `secure_storage` write error was not caught in the UI (the user thought it was "added" and could
  lose it on restart). **Fix:** `_AddSheet` and `ScanPage._onDetect` now `await`
  it; on success they close, on error they leave the form/scan open and show the error. During the add,
  the buttons are disabled + a spinner.
- **#3 (low/medium) — Startup race condition:** if the user adds before `load()` finishes, a late
  `load()` could overwrite the current state with the old stored content. **Fix:** `VaultCubit`
  tracks the pre-load mutation; instead of overwriting, the late `load()` **merges** the stored record +
  the user's additions id-based and re-persists.
- **#4 (low) — Search clearing:** the `clear` button only reset `_query`; since there was no `TextField`
  controller, the old text stayed on screen. **Fix:** a `TextEditingController`
  was added, and on clear both the state and the visible text are reset (it is disposed).
- **#5 (low) — Doc drift:** `PLAN.md` said "60/60", `docs/OTP_ENGINE.md` still described the vault
  as "in-memory / next step" → pulled to the current state (a persistent vault, single-point validation)
  and the test count.
- **Tests:** +8 (4 JSON validation rejections + 3 load resilience (corrupted JSON/record via mocktail) +
  save-error throw + race-condition merge). **67 → 75, all pass; `analyze` clean.**

## 2026-06-07 — Phase 1 remainder: persistence + QR scanning + search (+ doc drift)

Phase 1 is complete. The external review's two low-priority doc drifts (confirmed from source) were fixed, then the remaining three items of Phase 1 were implemented.

- **Doc drift #1 (low) — ARCHITECTURE.md RLS example:** the §RLS policies line showed a bare
  `user_id = auth.uid()`; the live/migration uses `(select auth.uid())` (the init-plan
  optimization). If copied it would return an `auth_rls_initplan` warning → the example was updated
  to `(select auth.uid())` with a note explaining why.
- **Doc drift #2 (low) — PROJECT_INFO.md migration summary:** it said "+ audit FK index" for the
  `initplan` migration; the index was actually moved into the init migration and removed from initplan
  (the migration file documents this). The summary was corrected.
- **Persistence (secure_storage):** `OtpAccount.toJson/fromJson` (different from the URI — it preserves
  local/operational fields like `id` + `counter`; a corrupted field → `FormatException`). The `VaultRepository`
  interface + `SecureStorageVaultRepository` (a single JSON key; a single corrupted record is skipped, the entire
  vault does not go down). `VaultCubit` now takes a repository: `load()` at launch, persist on each mutation;
  no unnecessary writes on no-ops. A spinner on the first load via the `loaded` state.
- **QR scanning (`mobile_scanner` 7.2):** `ScanPage` is a real scanner — `DetectionSpeed.noDuplicates`,
  the `qrCode` format only, a double-add-guarded pop on the first valid `otpauth://`, a SnackBar on an invalid QR
  + continue scanning, flash/camera-switch, a user-friendly `errorBuilder` for permission denial.
  Platform permissions: iOS `NSCameraUsageDescription`, Android `CAMERA` + `uses-feature camera
  required=false` (manual entry still possible).
- **Vault search:** a search bar in the `VaultPage` AppBar — a case-insensitive filter over
  issuer/account/label; a separate state when there is no match. The add menu distinguishes QR/manual.
- **Tests:** 7 new (6 JSON round-trip/resilience + 1 VaultCubit load); 5 VaultCubit tests
  were adapted to the async repository signature (persist verification with FakeRepo). **60 → 67, all pass;
  `analyze` clean.** The APIs were confirmed with Context7 (mobile_scanner v7 `errorBuilder`/
  `MobileScannerErrorCode`, flutter_secure_storage v10 default RSA-OAEP+AES-GCM).

## 2026-06-06 (round 5) — Vault state robustness + token id + parse hardening (review #5)

The external review gave 5 findings; **all confirmed from the source code, all real** and fixed.

- **#1 (medium) — the TOTP timer could stall on OtpCard state reuse:** `VaultPage` was not giving the cards a stable
  `Key`; `OtpCard.didUpdateWidget` did not start/cancel the timer on a type change (TOTP↔HOTP).
  **Fix:** `ValueKey(account.id)` on the cards + `_syncTimer()`
  (idempotent: start the timer if time-based, cancel for HOTP) in both `initState` and `didUpdateWidget`.
- **#2 (medium) — no stable id on a token (drift from ARCHITECTURE §7.5):** a uuid v4
  `id` was added to `OtpAccount` (assigned at construction if not provided). `VaultCubit` is now **id-based**
  instead of index-based (`removeById`/`incrementCounter(id)`) — it does not touch the wrong item on a
  list reorder/concurrent change. The basis for the idempotent upsert of the Phase 3 backfill. `copyWith` preserves the id; included in `props`.
- **#3 (medium) — an unknown `algorithm` silently fell to SHA1:** `OtpAlgorithm.fromName`
  now rejects a **provided but unsupported** algorithm (`SHA3`, `md5`, a typo) with a `FormatException`;
  missing/empty still defaults to SHA1. The same "validate if provided" principle as `digits`/`period`.
- **#4 (low) — ARCHITECTURE.md `sodium_libs` drift:** the §1 table + the package note were updated to the `sodium`
  package (aligned with README/PLAN; a `sodium_libs` discontinued warning was added).
- **#5 (low) — the route diagnostic log was permanently on:** `debugLogDiagnostics: kDebugMode`
  (debug build only; profile/release silent).
- **#6 (medium, follow-up round) — a missing `counter` in HOTP was silently treated as 0:** proved
  it fell to 0 with a repro test. Per the Key URI Format, `counter` is **mandatory** in HOTP →
  a `required` parameter was added to `_parseBounded`; a missing counter in HOTP is a `FormatException`.
  Since counter is not used in TOTP/Steam, its absence is allowed (0). 3 new tests.
- **Tests:** 12 new tests (4 algorithm/id + 5 VaultCubit + 3 HOTP counter requirement).
  **Total 48 → 60, all pass; `analyze` clean.** `uuid 4.5.3` added.

## 2026-06-06 (round 4) — Doc drift + seed config (review #4)
- Test count drift: the remaining `38/38`·`39/39` in README/PLAN/OTP_ENGINE → made the current **48/48**.
- `config.toml` `[db.seed]` `enabled=false` (the non-existent `./seed.sql` produced a "no files matched" WARN;
  we do not use seed). Confirmed the WARN is gone with a local `supabase start`.

## 2026-06-06 (round 3) — OTP input validation + end-to-end hook verification

The external review gave 2 more findings; both were **proven with a reproduction test** and fixed.

- **#1 (medium) — Malformed otpauth:// UI crash risk:** a repro test was written and the crash was PROVEN:
  the invalid Base32 secret passed parsing but `secretBytes` (card render) threw a `FormatException`;
  `period=0` divided by zero in `secondsRemaining`. **Fix:** validation was pulled to the
  moment of `OtpAuthUri.parse` — the secret Base32 decode is verified, `digits` (6–8/Steam 5),
  `period` (1–600), `counter` (≥0) pass a range check; invalid → `FormatException`.
  9 new tests added. **Test total 39 → 48, all pass; `analyze` clean.**
- **#2 (low) — the hook was off in the local config:** `[auth.hook.custom_access_token]`
  was enabled in `config.toml` (`pg-functions://postgres/public/custom_access_token_hook`). The real login flow
  was **tested end-to-end with the local stack** (GoTrue): signup → add admin → signin →
  `app_metadata.admin=true` in the JWT; `false` for a normal user (negative control). This is stronger than the
  previous "call the function directly" test — it verifies the full auth pipeline.

## 2026-06-06 (round 2) — External review #2 fixes + fresh-deploy verification

The external review gave 4 more findings; all were handled **on real Postgres with the local Supabase CLI**
(the Supabase MCP was not connected in this session → a local stack was set up with `supabase start`).

- **#1 (high) — Fresh deploy fail:** the `idx_audit_logs_actor` index was created in both the `init` and `initplan`
  migrations → on a clean project the 2nd migration would say "already exists".
  The duplicate `create index` was REMOVED from the `initplan` file. **A fresh deploy was applied from scratch
  locally, and all three migrations passed without error.**
- **#2 (medium) — `supabase_admin` default ACL:** the `postgres` owner default was narrowed with 0003, but
  the `supabase_admin` owner default is still broad. Tested locally: a migration CANNOT CHANGE the
  default privilege of `supabase_admin` ("permission denied" — a Supabase restriction). The solution is not code
  but discipline → a permanent warning was added to 0003: tables must be created only with `postgres` (migration).
- **#3 (medium) — Flutter init API:** confirmed exactly from the installed package source
  (`supabase_flutter 2.14.1/lib/src/supabase.dart`): `publishableKey` is a REAL parameter, `anonKey`
  is now `@Deprecated`. `publishableKey:` is both correct and forward-compatible. PROJECT_INFO updated.
- **#4 (low) — Test drift + idempotency:** the migration names were updated (TEST_REPORT +
  the test script). A fixed `id` was added to the token inserts; running the script twice
  actually proved idempotency (count=1 on the 2nd run too).
- Added: `supabase/config.toml` (CLI init), `supabase/.gitignore` (`.branches/.temp`).

## 2026-06-06 — Flutter Phase 0/1 core + DB hardening

### Flutter — Phase 0 (base setup)
- Flutter project created (3.38.6, org `dev.mustafakara`, iOS+Android).
- Feature-first + layered folder structure: `lib/core/{otp,di,router,theme,error,config,storage}`,
  `lib/features/{vault,scan}/...`.
- Dependencies added and version conflicts resolved:
  `flutter_bloc 9.1`, `go_router 17.3`, `get_it 9.2`, `injectable 2.5`, `freezed 3.2`,
  `supabase_flutter 2.14`, `sodium_libs 3.4`, `flutter_secure_storage 10.3`,
  `mobile_scanner 7.2`, `local_auth 3.0`, `crypto`, `equatable`.
- A DI composition root (`configureDependencies`, get_it manual), go_router routes,
  Material 3 light/dark theme, `main.dart` (BlocProvider + MaterialApp.router).

### Flutter — Phase 1 (OTP core)
- `core/otp/`: Base32 (RFC 4648), HOTP (RFC 4226), TOTP (RFC 6238), Steam Guard,
  the `OtpAccount` model, `otpauth://` parse/serialize.
- **38 RFC test vectors written and run — all passed** (HOTP Appendix D,
  TOTP Appendix B SHA1/256/512, Base32, Steam, URI round-trip).
- Vault UI: `VaultCubit` (in-memory), `VaultPage`, a countdown/copyable `OtpCard`,
  manual `otpauth://` add. `ScanPage` placeholder (QR next).
- Verification: `flutter analyze` clean · `flutter test` **39/39** passed.

### Known version pitfalls (managed in the pubspec)
- 🔐 Crypto (Phase 2): `sodium ^3.4.6` + `sodium_libs ^3.4.6+4`. sodium 4.x requires Dart 3.11+; the project is on Dart 3.10.7 → 4.x cannot be resolved (3.x is a deliberate decision, pre-built binary, no native-assets flag needed). `sodium_libs` is tagged "discontinued" but the 3.x line works (proven by integration tests). Details in docs/CRYPTO.md.
- `injectable` pinned to 2.x (the generator does not support 3.x yet).
- `json_annotation` pinned to ^4.9.0 (4.12 is not yet compatible with `json_serializable`).

### Supabase backend — post-external-review fixes
- **The `0003_least_privilege_revoke` migration** (applied live): the excess `anon`/`authenticated` table
  privileges from `pg_default_acl` were revoked
  (RLS + table-grant, two layers). After the revoke the security advisor still shows **0 warnings**.
- **Migration history aligned:** the local single squashed `0001` → 3 timestamped files matching live
  + `supabase/migrations/README.md`.
- **Doc drifts fixed:** `unused_index` 3→1 (the real advisor output),
  a `db push` warning (re-pushing to the existing live project), the migration lists.
- 2 rejected review findings (after verification): the `publishableKey` parameter is real and
  does not fail at compile time (Context7 Dart upgrade-guide); the test idempotency is theoretical/low.

## Earlier — Architecture & Backend (summary)
- A full architecture matured through multi-round review + verification (ARCHITECTURE.md).
- The Supabase `authenticator-dev` project: 8 tables + RLS + a Custom Access Token Hook +
  a private admin aggregate. The end-to-end security test passed 8/8 (TEST_REPORT.md).
