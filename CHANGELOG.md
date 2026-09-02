# Changelog

Project progress log. Newest at the top.

## 2026-09-02 (Phase 6 — admin panel MVP)

The first working version of the **Next.js admin panel**, landed as a **standalone npm package** under `admin/`:
its own `package-lock.json`, its own CI workflow, and deliberately **no** place in the Flutter `analyze`/`test`
pipeline — a Dart change must not be able to break the panel's build and vice versa. Stack: Next.js **16.3.4**
(App Router) + React 19.2.8, `@supabase/ssr` 0.12.5, `@supabase/supabase-js` 2.114.0, the porsager `postgres`
3.4.9 driver, Tailwind 4 + shadcn/ui primitives, zod 4, vitest 4. Every dependency is **pinned to an exact
version** (no `^`/`~`). Full module contract: [admin/README.md](admin/README.md).

**Why now:** the tables the panel administers (`announcements`, `catalog_services`, `feature_flags`,
`audit_logs`, `admin_users`) and the admin claim hook have existed since Phase 3, and Phase 5 closed the
client-side work. Until this entry they could only be operated from the Dashboard SQL editor — i.e. every
announcement, catalog row and kill-switch flip was an unaudited hand-written statement by whoever held the
`postgres` password.

**The E2E boundary is what shapes the panel, not a footnote to it.** The panel cannot decrypt a single TOTP
secret, and it does not read `tokens.ciphertext` or `key_attributes` on **any** path — not even to count
columns. The only cross-user read in the product is an aggregate.

### The three access paths and which module implements each (ARCHITECTURE §6)

They are never mixed; each one exists because the other two cannot do its job.

| Path | Identity | What it is for | Module |
|---|---|---|---|
| **(a)** direct Postgres | `DATABASE_URL` → login role `admin_app`, then `set local role admin_backend` | `select private.admin_global_stats()` — the cross-user **counts** on the dashboard | `admin/src/lib/db.ts` (`getGlobalStats`), wrapped by `src/lib/stats.ts` |
| **(b)** secret key (`sb_secret_…`) | REST/Auth API identity, RLS bypass | `auth.admin.listUsers`/`updateUserById`/`deleteUser`, all writes to `announcements`/`catalog_services`/`feature_flags`, and every `audit_logs` insert | `admin/src/lib/supabase/admin.ts` (`createAdminClient`), `src/lib/audit.ts` (`writeAudit`), the four `actions.ts` files, `users/data.ts` |
| **(c)** the admin's own session | publishable key + `@supabase/ssr` cookies | login/logout, reading the admin-public tables, reading `audit_logs` under the RLS policy `to authenticated using (public.is_admin())` | `admin/src/lib/supabase/server.ts`, `src/lib/supabase/browser.ts`, `src/proxy.ts` |

Path (a) is not a preference: the `private` schema is **not** exposed to the Data API, so
`private.admin_global_stats()` cannot be reached through `.rpc()` at all. Path (c) is used for *reading*
`audit_logs` on purpose — the read needs no RLS bypass, so the secret key stays reserved for writes.

**`src/proxy.ts`, not `middleware.ts`.** Next.js 16 renamed the file convention (`middleware` is deprecated as
of v16.0.0); the exported function must be named `proxy`, and it runs on the Node.js runtime by default.

### Pages

- **`/login`** — email + password, then an immediate claim check: a valid session that is not an admin is
  **signed out on the spot** and told "Bu hesap yönetici değil". The credential error is generic
  ("E-posta veya parola hatalı") so the form never reveals whether an address exists.
- **`/`** — global stats cards from path (a) plus the **last 10** audit rows read over path (c). A failure of
  (a) is turned into an error card rather than an exception, so a missing `DATABASE_URL` or an ungranted role
  cannot take the authenticated shell down with it.
- **`/users`** — `auth.admin.listUsers` at 50 rows/page, ban (`ban_duration: '876600h'`), unban
  (`ban_duration: 'none'`) and delete. `banned_until` is read as a **timestamp, not a flag** (a past instant is
  not a ban). The delete dialog states the FK cascade — deleting the auth user removes their `tokens`,
  `key_attributes` and `devices` rows, which for an E2E product means the data is gone, full stop, because no
  one else ever held the key.
- **`/announcements`** — CRUD over `audience ∈ {all, flutter, android, ios}`. The enum is not decoration: the
  Flutter client filters `audience` **client-side** and silently drops anything else, so a typo'd audience
  would produce an announcement nobody ever sees. Title ≤ 120, body ≤ 4000 characters.
- **`/catalog`** — issuer-canonicalization CRUD. `logo_url` is validated as an **absolute `https://` URL**
  even though the app deliberately never fetches it (offline/privacy decision from Phase 3 Patch 4): the
  column is publicly readable, so a `http://`, `javascript:` or `data:` value would be a stored payload the
  day any future client starts rendering it.
- **`/flags`** — create/enable/disable/payload/delete. `token_sync_enabled` is **delete-proof** (a missing row
  makes clients assume sync is *on*, so deleting it is the opposite of disabling it) and disabling it requires
  a confirmation carrying the warning that it stops token sync on every client. `payload` must be a JSON
  **object** or null (the client drops arrays and scalars) and is capped at **8 KiB**, checked *before*
  `JSON.parse`.
- **`/audit`** — read-only, 50 rows/page, newest first with `id` as tiebreaker so a row cannot vanish between
  pages. The action filter is **whitelisted against the `AUDIT_ACTIONS` union** rather than passed through, and
  the `?q=` needle is LIKE-escaped (`%`/`_` backslash-escaped; `*` dropped, because PostgREST rewrites it to
  `%` before PostgreSQL sees the pattern and escaping therefore cannot neutralise it).
- **`/forbidden`** — signed in, not an admin; offers sign-out and nothing else.

### Security invariants (admin/README.md §6 is the authoritative list)

1. **`SUPABASE_SECRET_KEY` and `DATABASE_URL` are server-only.** Every module that reads them starts with
   `import 'server-only'` (`lib/supabase/admin.ts`, `lib/db.ts`, `lib/audit.ts`) and `getServerEnv()` adds a
   `typeof window` guard. Neither value is ever given a `NEXT_PUBLIC_` prefix.
2. **`tokens` / `key_attributes` are read on no path.** The single cross-user read is
   `private.admin_global_stats()`, which returns counts.
3. **The panel never connects to Postgres as `postgres`.** It connects as `admin_app` and does
   `set local role admin_backend` **inside a transaction** — `SET LOCAL` is transaction-scoped, so it is
   correct under Supavisor transaction-mode pooling as well as session mode. Prepared statements are disabled
   (`prepare: false`) for the same reason.
4. **Authorization is two-layered.** `src/proxy.ts` is the first line only; every privileged handler calls
   `requireAdmin()` again, because a Server Action is a POST to the page route and a matcher edit could
   silently narrow proxy coverage. `requireAdmin()` uses `auth.getClaims()` (JWKS **signature verification**,
   local for asymmetric keys) and demands a literal boolean `app_metadata.admin === true` — never `'true'`,
   never truthiness. `getSession()` is not trusted (cookies are shared storage).
5. **Every privileged operation writes exactly one `audit_logs` row**, in the same handler that performed it,
   with the `actor` taken from `requireAdmin()` and **never** from the request body.
6. **A failed audit write is reported as a failed audit write, not as a failed operation.** The operation has
   already happened at that point; conflating the two would either hide a real mutation behind an error or
   claim a clean success while the log has a hole in it. The user sees "…yapıldı. Ancak denetim kaydı
   yazılamadı: …".
7. **Guards on `/users` are server-side and fail closed:** you cannot act on your own account, and you cannot
   ban/delete another admin (removing admin rights stays a deliberate SQL step against `public.admin_users`).
   The admin-id set comes from `public.admin_users` over the secret-key client and an **unreadable** admin list
   **throws** rather than defaulting to empty — the alternative would silently permit banning an admin.
8. **Env validation is lazy and rejects legacy keys.** `sb_publishable_…` / `sb_secret_…` prefixes are
   required, so an old `eyJ…` JWT anon/service_role key is refused; validation runs at request time, which is
   what lets `next build` (and the CI build step) succeed with no secrets at all.

### Operator prerequisites — required before the dashboard shows numbers

The migration `supabase/migrations/20260902120000_admin_backend_role.sql` **is in the repo but has NOT been
applied to the live project** (`authenticator-dev`). It creates only the NOLOGIN privilege carrier
`admin_backend` and grants it `usage` on `private` + `execute` on `private.admin_global_stats()`, and it
re-revokes both from `public`/`anon`/`authenticated`. It contains **no password**.

1. Apply it: `supabase db push` (or paste the file into Dashboard → SQL Editor).
2. Create the login role by hand — the password is never written into a migration, a transcript or this repo:
   ```sql
   create role admin_app login password '<güçlü-parola>';
   grant admin_backend to admin_app;
   ```
3. Put that role into `admin/.env.local` as `DATABASE_URL`, alongside `NEXT_PUBLIC_SUPABASE_URL`,
   `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_SECRET_KEY`.
4. Make sure at least one real admin exists: `insert into public.admin_users (user_id) values ('<uuid>');`
   Without it nobody can get past `/login`.

**Verified live (2026-09-02, before the migration):** `service_role` holds full grants on `admin_users`,
`audit_logs`, `announcements`, `catalog_services` and `feature_flags` — so path (b) works today. `execute` on
`private.admin_global_stats()` is currently held by `postgres` **only**, which is exactly why the dashboard's
stats cards render an error card until step 1+2 are done.

### Documentation findings (W1) — recorded in full in admin/README.md §5

Library APIs were verified against current documentation **and the installed package source**, not from
memory:

- **Next.js 16 proxy** — the `middleware` file convention is deprecated and renamed `proxy` (v16.0.0); the file
  lives at the project root or in `src/`, the export is named `proxy`, and it runs on the Node.js runtime by
  default. `next build` prints it as `ƒ Proxy (Middleware)`.
- **`@supabase/ssr` cookie contract** — `getAll`/`setAll(cookiesToSet, headers)`; the second `setAll` parameter
  (the `Cache-Control: private, no-cache, no-store…` headers, so a CDN can never cache a response that sets
  auth cookies) was confirmed in the installed package's `types.d.ts` (`SetAllCookies`).
- **`getClaims()` over `getUser()`** — `getClaims()` verifies the token against the project's JWKS, needs no
  network round trip with asymmetric signing keys, and refreshes an about-to-expire session, so it doubles as
  the proxy's session refresh.
- **New API keys are not JWTs** — they travel in the `apikey` header, never `Authorization: Bearer`. The
  installed `supabase-js` 2.114.0 already handles this (`isNewApiKey()` recognises the prefixes and always sets
  `apikey`), so `createAdminClient()` hands the key straight to `createClient()` with no manual headers.
- **Pooler mode vs `SET LOCAL ROLE`** — Supavisor transaction mode (6543) does not support prepared statements
  and resets session state between transactions, so `SET ROLE` without `LOCAL` would be unreliable there;
  `set local role` inside an explicit transaction plus `prepare: false` is correct on **both** ports.

### CI and tests

`.github/workflows/admin-ci.yml` (new): paths-filtered to `admin/**` + the workflow file itself, so it stays
off Dart-only changes and `ci.yml` stays off admin-only ones. `permissions: contents: read`, a concurrency
group namespaced by workflow (it can never cancel the Flutter run for the same ref), Node 22 matching
`engines.node`, actions SHA-pinned (`setup-node` v7.0.0). Steps: `npm ci` → lint → typecheck → test → build.
**No Supabase secrets are supplied on purpose** — a build that starts requiring real credentials fails the
step.

- **admin: 153 vitest tests** across 10 files, all pure/unit: env schemas, `isAdminClaims`, the users guard and
  row mapping, the user server action's ordering, announcements/catalog/flags schemas and row mappers, the
  audit query parser (page clamping, action whitelist, LIKE escaping, `range()` bounds), `parseGlobalStats`,
  and the nav component.
- **Flutter: 1188 host tests, unchanged** — this phase touches no Dart file, no crypto routine, no server
  schema and no sync protocol.

### Known limitations (deliberate, and to be closed later)

- **User search is page-local.** `auth.admin.listUsers` takes only `page`/`perPage` — there is no server-side
  email filter — so the search box narrows the 50 rows currently on screen, and the UI says so rather than
  pretending otherwise.
- **No pagination on `/announcements`, `/catalog`, `/flags`.** All three fetch the whole table. That is fine at
  the current row counts (all three are effectively empty) and will need `.range()` before they are not.
- **The dashboard shows an error card until `DATABASE_URL` + `admin_app` exist** (see the operator steps).
  Everything else on the panel works without them.
- **No FCM push.** Announcement CRUD is here; triggering a push from an announcement stays in **Phase 4**,
  where the Firebase project and the device push-token registration live.
- **No Playwright/e2e suite.** The pure logic is unit-tested and the flows are covered by the manual smoke
  checklist in admin/README.md §7; there is no browser-driven regression test yet.
- The users table case-folds **invariantly** (`toLowerCase`, not Turkish): `'ALI'.toLocaleLowerCase('tr-TR')`
  is `'alı'`, which would never match the ASCII address `ali@…`.

### Deliberately NOT built

- **No growth charts / date histograms** (ARCHITECTURE §6 lists them as a capability). `admin_global_stats()`
  returns three totals plus `generated_at`; a histogram means a new `security definer` function and a new
  migration, so it is not smuggled in with the MVP.
- **No admin management UI.** Granting or revoking admin is a SQL insert/delete on `public.admin_users`, on
  purpose: a panel that can promote its own users is a privilege-escalation surface, and the ban/delete guard
  is built on that table.
- **No Edge Function.** Every privileged operation is a Next.js Server Action; adding a second server-side
  execution environment would have doubled the places the secret key lives.
- **No user-detail page.** There is nothing to show that the list does not already show — the panel cannot read
  a user's tokens, so a detail view would be an empty page with a heading.
- **No TanStack Table / recharts** (both named in ARCHITECTURE §6): with page-local search, no sorting and no
  charts in this MVP, both would have been dependencies carrying no weight.
- **No `pg` driver or Prisma** — one query, over one connection, once per dashboard render; the porsager
  `postgres` driver (already the ARCHITECTURE §6 preference) covers it with a memoised 2-connection pool.


## 2026-09-02 (chore: repo-wide `dart format` + CI format gate + repository/DI tests)

Phase 0's last open infrastructure item, and the one Phase 3.5 left as known debt: the tree was never
`dart format`-clean, so the gate could not be turned on without a reformat first.

- **The reformat** landed as its own commit, `7a88a0b` — `dart format` over the whole repo plus the
  `curly_braces_in_flow_control_structures` fixes it exposed. **Whitespace and braces only: no behavioural
  change**, no API touched, no crypto/AAD/schema touched; `flutter analyze --fatal-infos` stays clean and the
  host suite is unaffected.
- **`.git-blame-ignore-revs`** (new, repo root) lists that one revision so a repo-wide reformat does not bury
  real authorship in `git blame`. It is opt-in per clone — run once: `git config blame.ignoreRevsFile
  .git-blame-ignore-revs` (also noted in README → Development → Flutter).
- **CI gate:** `.github/workflows/ci.yml` gained a **Format** step running
  `dart format --output=none --set-exit-if-changed .`, placed before **Analyze** so a formatting-only failure
  is reported as formatting rather than as a lint failure. All action SHA pins, `permissions: contents: read`
  and the existing comments are unchanged.
- **Tests (1165 → 1188 host):** two documented coverage gaps closed, **no `lib/` change**.
  `test/features/vault/supabase_token_repository_test.dart` now drives a **real** `SupabaseClient` over a
  recording `http.BaseClient` (`test/support/fake_http_client.dart`), so PostgREST's own request building and
  error parsing are under test: `pushUpsert` 1200 rows → 3 POSTs of 500/500/200 with `on_conflict=id` and
  `Prefer: resolution=merge-duplicates`, exactly six columns per row and never `updated_at`/`created_at`, empty
  list → no request, first-chunk failure stops the rest; `_mapError` 401/403 → `SyncPermissionDenied`, 500 →
  `SyncUnknownError`, `SocketException` → `SyncNetworkError`; `tombstoneAllRemote`/`tombstoneAllRemoteBefore`
  PATCH shape and filters; `pullSince` cursor filter, ordering, row mapping and malformed-row quarantine.
  `test/core/di/locator_test.dart` runs `configureDependencies()` on the host VM (fake `SodiumPlatform`, fake
  HTTP-backed `Supabase.initialize`): all 30 registrations resolve, are singletons, survive `locator.reset()`,
  and the concrete wiring is asserted. Not covered, by design: Realtime `subscribe` (WebSocket bypasses the
  injected HTTP client) and real libsodium (integration_test only).

## 2026-09-02 (Phase 5 Patch 3 — tags, pasted migration links, QR from image)

The last three items on the Phase 5 list, which **completes Phase 5**: user **tags** (including the groups Aegis
and 2FAS exports have always carried and this app has always thrown away), and two ways to bring in a Google
Authenticator transfer QR that do not need a working camera — a **pasted `otpauth-migration://` link** and a
**saved QR image file**.

**No Supabase schema change. No crypto change** — no new primitive, no new AAD, no record-version bump, no backup
envelope bump; docs/CRYPTO.md §4's AAD table is byte-for-byte the same table it was before this patch. host
**996/996 → 1165/1165**, integration unchanged (**50**, not run on a device this round), `flutter analyze
--fatal-infos` clean.

### The model decision: tags live inside the encrypted blob, and nothing around them moves (K1–K6)

`OtpAccount` gained `final List<String> tags` — at most **8** labels of at most **32 runes** each. Six decisions
shaped it, and each of them is a decision *not* to disturb something:

- **K1 — no record version bump, no AAD change.** Tags are a new optional key inside the token plaintext, which
  changes neither how a blob is opened nor what it is bound to; the AAD's job is to pin the record to its context
  (`token|1|<id>`) and the id, the context and the cipher are all unchanged. Bumping `v` to 2 would have been the
  expensive alternative: `EncryptedBlob` rejects a version above `supportedVersion` (docs/CRYPTO.md §8), so an
  older client would have refused the **whole vault** ("açılamadı") instead of quietly ignoring one key it does not
  understand, and the server would have been holding records every not-yet-updated device considered malformed. An
  additive field must not be able to cause a total outage on another device.
- **K2 — `toJson` writes the key only when the list is non-empty** (the same conditional shape `issuer` already
  used). An untagged account therefore serializes **byte-identically** to a pre-Patch-3 one. This is what keeps
  the upgrade free: `EncryptedVaultRepository.save()` re-encrypts only records whose `OtpAccount` compares
  unequal, so a vault where nobody has tagged anything re-encrypts nothing, refreshes no `updatedAt` and pushes
  nothing. Had the key always been written as `[]`, the first save after the update would have re-encrypted and
  re-pushed **every token in every vault** — a sync storm for a feature nobody had used yet.
- **K3 — `tags` IS in `OtpAccount.props`, and that is load-bearing, not tidiness.** The repository's
  unchanged-blob shortcut is literally `if (prev != null && prev.account == account)` → keep the old ciphertext.
  A field missing from `props` is invisible to that comparison, so an edit that changed **only** tags would have
  been written back as the old blob: the change would vanish on the next load, with no error and no push. The
  comment at that call site now says so, and `encrypted_vault_raw_store_test.dart` asserts a tags-only edit does
  re-encrypt and does refresh `updatedAt`.
- **K4 — normalize, never reject.** `OtpAccount.normalizeTags` trims → drops blanks → clips to 32 runes → drops
  exact duplicates (first wins, so the user's own order survives) → keeps the first 8. It cannot throw. Import
  sources hand over arbitrary group names, and a thrown exception there would drop an otherwise perfectly good
  token over a *label*. Only a **type** error is fatal (`tags: "work"`, `tags: [1,2]` → `FormatException`), because
  that means the blob is not what we wrote and `VaultRepository.load` must be able to quarantine that one record
  rather than half-understand it.
- **K5 — tags are NOT part of `dedupeKey`.** A token exported from a "Work" group and re-imported after the user
  moved it to "Personal" is the same token. Including tags would have made every group change look like a brand
  new account on the next import. Covered by a regression test in `dedupe_test.dart`.
- **K6 — import group → tag mapping.** Aegis: `db.groups` is `[{uuid, name}]` and an entry references them by uuid
  in `entry.groups`; older exports instead carry a single `entry.group` holding the **name**, so both are read
  (uuids first, the legacy field used verbatim). 2FAS: the root `groups` is `[{id, name}]` and a service points at
  one with `groupId`, so a 2FAS service yields **at most one** tag. Google's migration payload has no grouping
  field at all. An unresolvable reference (a stale uuid, a wrongly typed row, a missing `groups` array) contributes
  no tag **in silence** — it produces no `SkippedEntry`, because a broken group reference says nothing about the
  token, and *nothing* about groups can drop an entry: every accessor on that path is total and the ceilings are
  applied by `normalizeTags`, which never throws.

Backups needed no change at all: the payload already *is* `OtpAccount.toJson()`, so tags ride along, `version`
stays **1**, and a pre-Patch-3 backup imports exactly as it did. Round-trip covered in `backup_service_test.dart`
and end-to-end (grouped Aegis file → preview → `addAll` → export → re-import → tags still there).

### Vault UI — tags, and a long press that no longer destroys anything

- **`VaultCubit.editMetadata / renameTag / deleteTag`, plus a derived `allTags`.** All three follow the `addAll`
  discipline: `_awaitLoaded` → `_sequence` → `_guardIntegrity` → **one** `_emitAndPersist` and **one**
  `_pushAfterMutation` for the whole sweep, and a no-op (unknown id, nothing actually changed, a tag nobody
  carries, a rename to itself) writes nothing and pushes nothing. `editMetadata` runs the result through the same
  catalog canonicalization `add` uses, so an edited token dedupes against imports exactly like an added one.
  A rename **merges** on collision rather than erroring — the renamed entry folds into the existing tag through
  `normalizeTags`, keeping the account's original tag order. `allTags` is a pure derivation of state (usage count
  descending, ties case-insensitively alphabetical), never a cache: a stale one would offer a filter for a tag the
  vault no longer has.
- **`editMetadata` cannot touch the seed, by signature.** It does not accept `secret`, `type`, `algorithm`,
  `digits`, `period` or `counter` — not "validates them", *does not take them*. An edit screen able to rewrite the
  seed or the code geometry turns one typo into a token that generates wrong codes forever, with no way back for
  the user. `EditTokenSheet` correspondingly never reads, shows or copies `account.secret`.
- **`TagChipsBar`** under the search field: horizontal chips, **single selection, session-scoped**. Not persisted
  on purpose — a filter that survives a restart is the classic way a user concludes a token has disappeared. The
  strip renders nothing at all when the vault has no tags, a chip is an **exact** membership test (picking "iş"
  must not also bring "işlem"), and the search box now also matches tag text, AND-ed with the chip. A selection
  that stops existing (renamed or deleted, here or on another device) stops filtering on the very next build and
  is then cleared from state in a post-frame callback, so it cannot come back if the tag does.
- **BEHAVIOUR CHANGE — a long press on a card no longer deletes it.** It used to call `onDelete` directly, with no
  confirmation: a mis-touch while scrolling silently cost the user access to that account's 2FA. It now opens
  `TokenActionSheet` (Kodu düzenle / Etiketleri düzenle / Sil), and **every** delete path — the sheet entry and the
  new assistive action alike — goes through the confirmation dialog first. Anyone with muscle memory for
  "long-press to delete" now gets one extra tap; that is the point.
- **`OtpCard` gained `onLongPress` and `onEdit`**, both optional. A card given no `onLongPress` does **nothing**
  on a long press — there is deliberately no fallback to `onDelete`, so the unconfirmed delete path cannot come
  back through a call site that simply forgot the handler. `onEdit` is separate rather than folded into the long press for an
  accessibility reason: a screen-reader user cannot "long press", so 'Düzenle' and 'Sil' are also published as
  `customSemanticsActions`. The card's primary label and its single-tap "copy the code" are untouched — this only
  *adds* actions.
- **`TagManagerSheet`** (the last chip in the strip) renames or removes a tag across the whole vault, saying up
  front how many codes each operation touches, and its delete dialog spells out that only the **label** goes away.

### Two more ways in for a Google transfer QR

- **A pasted `otpauth-migration://` link** now works in the add sheet (`AddTokenSheet`, lifted out of `VaultPage`
  as part of this patch). It drives the same `MigrationScanController`, the same progress band and the same
  `ImportPreviewView` as the camera path: an incomplete multi-QR export shows "N/M bağlantı eklendi" and asks for
  the rest, a foreign batch offers to start over, a complete one previews and confirms into a single `addAll`.
  For a user with one device, no camera or a broken camera this is the **only** route in — Patch 2 could only
  point them at the camera. `ImportPage`'s Google guide gained exactly one sentence pointing here; no second input
  field was added there.
- **"Görüntüden oku" in `ScanPage`** reads a saved screenshot or photo. It is deliberately independent of camera
  state, because `analyzeImage` needs **neither a camera nor the camera permission** — on a device where the
  permission was denied it is the only thing that works. Every decoded string re-enters the existing `_handleRaw`,
  so single-token and migration mode both work from an image (two QRs of one export in a single screenshot are
  handled in order). The decoder is behind a `QrImageDecoder` typedef with a `@visibleForTesting` override, so the
  entire flow is host-testable with a closure; `MobileScannerQrDecoder` is the one real implementation and is
  deliberately **not** in DI.

### Security hygiene

- **The picked image's plaintext copy is shredded, and the order matters.** The picker hands over its own cached
  copy of the image — a plaintext **picture of a live TOTP seed**, in a directory the OS reclaims on its own
  schedule, possibly never. `ScanPage._pickFromImage` cleans up in a `finally`: first
  `FilePickerDocumentPort.shredCachedCopy(path)` (synchronous zero-fill in place, *then* unlink), only then
  `DocumentPort.clearPickerCache()`. Reversed, the general sweep would unlink the file **without overwriting it**
  and the targeted shred would find nothing, leaving the QR's pixels recoverable. The shred is synchronous on
  purpose: it must finish before the sweep touches the same file and before a screen torn down mid-flow could
  abandon a pending `await`. Both steps are best effort and swallow every failure — housekeeping must not turn a
  finished import into an error. **The user's original image is never touched**; only the sandbox copy is, and the
  plugin does not even hand over the original's path.
- **The clipboard is never read programmatically.** The migration paste is a paste *by the user* into a field
  whose autocorrect and suggestions are off (so the keyboard's learning dictionary never sees a secret); the field
  is cleared after every submission and on dispose. Nothing on either new path is logged, cached or copied, and
  the decoder's two exceptions carry no platform message — a plugin error string can quote a file name or file
  content.
- **The image is never re-encoded** (`compressionQuality` stays 0 — re-encoding is exactly what smears a dense QR
  into an undecodable one) and never read into Dart memory: the decoder takes a **path**, and the 16 MiB ceiling
  is checked against the size the picker reports *before* anything is read.
- **The lock exemption now has a third call site** and the same discipline: `begin` paired with `end` in an inner
  `finally` around the pick alone, plus a `dispose` that closes an exemption left open by a screen torn down while
  the picker is up. docs/CRYPTO.md §17 lists all three flows; the widget tests assert exactly one begin and one
  end on the cancel, success and failure paths alike.
- **`NSPhotoLibraryUsageDescription` was added to `ios/Runner/Info.plist`** — which **reverses** the "keep it out"
  conclusion the file_picker 12 upgrade reached earlier the same day, and PLAN.md's Phase 7 item now says so.
  Note it is there for **review**, not for a prompt: `file_picker_darwin` picks through PHPicker, which hands over
  one photo without the app holding library access, so iOS shows no permission dialog. The string keeps App Review
  from asking about an image-picking app, and keeps the prompt from being string-less if the plugin ever falls
  back to the older picker. No write-access key was added — the app never writes to the photo library.
- `SecureScreenScope` coverage is **unchanged at 11 screens**: every new surface is a sheet or dialog rendered
  inside a page that already holds a scope.

### Accepted limits

- **R1 — an older client that EDITS a tagged token loses its tags, on every device.** It writes the plaintext back
  without the key it never read. Reading, syncing and generating codes on an old client are all safe; only an edit
  drops them. This is the price of K1, and it is the cheap side of that trade: the alternative was every old
  client refusing the entire vault.
- **R3 — a tag rename or delete widens the LWW conflict radius from 1 record to N.** `renameTag`/`deleteTag`
  rewrite every token carrying the tag, so one gesture dirties N records (one persist, one push, but still N rows
  on the wire). Under arrival-order LWW a concurrent edit of any one of those N on another device can lose that
  device's change for that record. Accepted for now — the operation is rare, deliberate and idempotent — and
  recorded in PLAN.md's open design decisions, to be revisited **with** the LWW model rather than separately.
- **R9 — Turkish dotted/dotless İ/i are distinct tags.** Matching is exact string equality, not case- or
  locale-folded, so "İş" and "iş" coexist. Case-insensitive folding in Turkish is locale-dependent and getting it
  wrong silently merges two labels the user meant to keep apart; only the chip strip's *ordering* is
  case-insensitive.
- **R12 — clipping happens before de-duplication, so two long import group names sharing their first 32 runes
  merge into one tag.** Deliberate: the alternative leaves the account with two identical-looking labels.
- **Reading from an image does not work on the iOS Simulator or the web** — the plugin has no Vision/ML Kit path
  there. The UI says "Bu cihazda görüntüden okuma desteklenmiyor." rather than blaming the image, because
  retrying with another picture would not help.
- Tag ordering within an account is the **user's** order, not alphabetical; only the filter strip re-orders (by
  usage).

### Review follow-ups

Applied on top of the patch, before the merge. No schema, crypto or user-visible copy change.

- **`editMetadata` treats a blank issuer as "no issuer", not as `""`.** The edit sheet shows an empty "Servis"
  field for a token that has none and hands that `""` straight back, so `null != ""` made an *untouched* token
  re-encrypt, push and carry `"issuer": ""` inside its blob. Blank now clears (lands as `null`), and the
  no-change comparison runs after that normalization — so the same edit is a real no-op. Clearing an issuer that
  *did* exist still works, and now produces `null` rather than an empty string.
- **`OtpCard.onLongPress` no longer falls back to `onDelete`.** The fallback was dead (the only call site always
  passes a handler) but it kept an unconfirmed delete path alive in the widget; a card given no handler now does
  nothing on long press, and every delete path is confirmed by the caller.
- **The vault's tag filter clears its own field, not just its render.** A selection whose tag disappeared was
  ignored per build but kept in state, so the filter silently came back if the tag did (a sync pull, an undone
  rename). It is now dropped in a post-frame callback.
- **2FAS `groupId` is matched in string form**, so an export carrying integer group ids (hand-edited files, older
  writers) no longer loses the tag. Group *names* keep their String-only rule — a number is not a label.
- Docs corrected where they overstated: `renameTag`'s merge does *not* always preserve the account's tag order
  (the survivor takes the earlier slot, which is the renamed tag's own when it came first); `EditTokenSheet`'s
  tag counter limits **graphemes** while the model clips **runes**, so a ZWJ-emoji label can still be clipped
  after the counter allows it (visible before save, costs a label and never a token — left as is); and
  `_zeroFillSync` now states its worst case (16 MiB, ~200 ms of blocked UI isolate) and why it stays synchronous.
- `scan_page_image_test` now **fails** if the picker cache sweep runs while the plaintext copy still exists,
  pinning the shred-before-clear order the security note claims.

### Tests (996 → 1165 host)

New: `vault_cubit_tags_test`, `vault_page_tags_test`, `edit_token_sheet_test`, `tag_manager_sheet_test`,
`token_action_sheet_test`, `otp_card_a11y_test`, `add_token_sheet_test` (the renamed and much-extended
`vault_add_sheet_test`), `scan_page_image_test`. Extended: `otp_account_test` (normalization rules, the key absent
when empty, the type errors, `copyWith([])` clearing), `aegis_parser_test` / `twofas_parser_test` (group mapping,
unknown references, the legacy field, 40-rune clipping, 12 groups → 8 tags), `dedupe_test`, `backup_service_test`,
`vault_repository_test`, `encrypted_vault_raw_store_test` (the K3 re-encrypt assertion), `end_to_end_test`.

### Manual checklist (cannot be covered on the host VM)

- [ ] **Read a QR from an image on a real iOS device and a real Android device.** The host tests drive a fake
      decoder and a fake picker; ML Kit (Android) and Vision (iOS) have never run this path here, and the iOS
      Simulator cannot. Check both a screenshot of a single `otpauth://` QR and a multi-QR Google export.
- [ ] **Import a real grouped Aegis export and a real grouped 2FAS export** (the fixtures are hand-written).
      Confirm group names arrive as tags, an entry in several Aegis groups gets all of them, and an ungrouped
      entry arrives with none.

## 2026-09-02 (deps: file_picker 12 + device_info_plus 13)

One coupled major upgrade — `file_picker` **11.0.3 → 12.1.3** and `device_info_plus` **12.4.0 → 13.2.0**. They
had to move together: `file_picker >=12.1.3` pulls `windows_file_picker` → `win32 ^6.3.0`, while
`device_info_plus ^12.1.0` required `win32 ^5.11.0`, so neither resolved on its own. **No schema change, no
crypto change, no behaviour change.** host **992/992 → 996/996**, `flutter analyze --fatal-infos` clean,
`flutter build apk --debug` green, `pod install` green.

- **iOS loses the photo-library pod chain.** 12.x moves Apple platforms into the federated `file_picker_darwin`,
  whose podspec depends on Flutter alone. `ios/Podfile.lock` drops `DKImagePickerController` (Core /
  ImageDataManager / PhotoGallery / Resource), `DKPhotoGallery` (all four subspecs), `SDWebImage` and
  `SwiftyGif` — and with them the whole `trunk` SPEC REPOS section. A document-only app no longer links
  photo-library APIs, which closes the `NSPhotoLibraryUsageDescription` release-review item in PLAN.md Phase 7
  *without* needing the `PICKER_MEDIA=false` workaround that item proposed. `ios/Runner/Info.plist` still
  declares only `NSCameraUsageDescription` and `NSFaceIDUsageDescription`.
- **iOS deployment target 13.0 → 14.0**, required by the `file_picker_darwin` podspec (`pod install` refuses
  below it). Applied in `ios/Podfile` (the previously commented-out `platform :ios` line is now explicit),
  all three `IPHONEOS_DEPLOYMENT_TARGET` entries in `Runner.xcodeproj`, and `AppFrameworkInfo.plist`. **No
  device coverage is lost:** iOS 14 runs on exactly the hardware iOS 13 did (iPhone 6s and later).
- **`FilePickerDocumentPort` migrated to the 12.x API**, behaviour unchanged.
  `pickFiles(withData: true)` + `FilePickerResult` are gone: the port now calls `pickFile()` and reads through
  `PlatformFile.readAsBytes()`. The size ceiling is checked against `length()` **before** the read, so an
  oversized document is rejected without ever being materialised in memory — the previous code could not do
  that, because `withData` had already loaded it. A `readAsBytes()` failure maps to the same
  `MalformedImportFileException` the old `bytes == null` branch produced. `saveFile()` returns a `Uri?` rather
  than a path string, so the shredder's "did the user pick the leftover itself?" comparison resolves the URI to
  a filesystem path first and treats non-`file:` schemes (Android SAF `content:`) as "not a local path".
- **The iOS export leftover moved upstream — the shredder stays.** Re-verified from source
  (`file_picker_darwin` 1.0.4, `IOSFilePickerHandler.swift` → `saveFile(_:)`): the staging copy is now written to
  `NSTemporaryDirectory()/<fileName>`, not `NSDocumentDirectory`. It is still never deleted after the export,
  but `NSTemporaryDirectory()` is excluded from device backups, is reclaimed by the OS, and *is* reachable by
  `clearTemporaryFiles()` — so the iCloud-backup leak fixed in the audit round (C1) no longer exists upstream.
  `_shredIosSaveLeftover` was **kept rather than turned into a no-op**: it costs one `exists()` on a directory
  that should now hold nothing, and it is the only thing that would catch the destination moving back to a
  backed-up location. Doc comments in the port, docs/CRYPTO.md §16.5 and the test header say so explicitly.
- **`device_info_plus` 13 needed no code change.** Its only 13.0.0 breaking change is the win32 5→6 bump; the
  `AndroidDeviceInfo.version.sdkInt` surface used by the API<28 biometric gate
  (`biometric_service_impl.dart`) is untouched. 13.0.0 alone would have demanded Dart 3.11 / Flutter 3.41.6,
  which this toolchain (Dart 3.10.7 / Flutter 3.38.6) cannot satisfy — 13.1.0 lowered the floor back to Dart
  3.10 / Flutter 3.38.1, so the resolved 13.2.0 builds here.
- **The port's test seam changed with the plugin's architecture (+4 tests).** file_picker 12 is federated: the
  facade dispatches through `FilePickerPlatform.instance`, and in a host-VM test that instance is the default
  `MethodChannelFilePicker`, whose `pickFile`/`saveFile` throw `UnimplementedError` — so mocking the method
  channel no longer reaches the facade at all (the channel name
  `miguelruivo.flutter.plugins.filepicker` is itself unchanged). `file_picker_document_port_test.dart` now fakes
  the platform interface instead, which also let it cover three things the channel mock could not: that
  `pickFile` is asked for `FileType.any`, that an over-limit `length()` short-circuits before `readAsBytes()`,
  and that a failed read surfaces as `MalformedImportFileException`. A fourth new test covers the non-`file:`
  URI path added above.
- **Docs resynced:** the pin rationale in `pubspec.yaml`, `ARCHITECTURE.md` §4.1 and `docs/architecture.md` §8.1
  described a constraint that no longer exists; PLAN.md's coupled-upgrade item and the
  `NSPhotoLibraryUsageDescription` Phase 7 item are now `[x]`.

## 2026-09-02 (Audit follow-ups)

A post-merge audit of Phase 5 (Patches 1–2) produced 23 findings across data integrity, parser fidelity,
platform hygiene and documentation, plus two follow-ups uncovered while fixing them. All of them are addressed
here. **No Supabase schema change, no new crypto
primitive, no sync-protocol change**; one document *is* touched — docs/CRYPTO.md §15/§16/§17, which had drifted
from the code. host **909/909 → 992/992**, integration unchanged (**50**, not run on a device this round),
`flutter analyze --fatal-infos` clean.

### Data integrity — vault, sync, dedupe (A1–A6)

- **[P1] A live record could coexist with its own tombstone (A1).** `EncryptedVaultRepository._writeRecords`
  wrote the tombstone loop without filtering ids that were live in the same save, so an id-preserving restore of
  a previously deleted token put **two records for one id** on disk. The consequences were both silent and
  permanent: the next `importRemote` let the tombstone win (the token vanished again with no error), and while
  both were dirty `pushUpsert(onConflict: 'id')` failed with Postgres 21000 — wedging **every** later push, not
  just that one. A live record now drops its own tombstone in `_writeRecords`, and `load`/`importRemote` prefer
  the live record if a duplicate ever reaches them anyway (and rewrite the file to heal it). This is a
  **deliberate resurrection**: restoring a backup that contains a deleted token *is* the user asking for it back,
  so the record stays dirty (`sv == null`) and the next push flips the server row to `deleted = false`.
- **[P1] Dedupe and the vault canonicalized issuers differently (A2).** `dedupe.dart` only trimmed and
  lower-cased, while `VaultCubit` rewrote the issuer through the catalog on write (`github.com` → `GitHub`,
  `AWS` → `Amazon Web Services`). Re-importing the same file therefore missed `alreadyInVault` and created
  duplicate tokens. `canonicalizerFor(IssuerCatalog)` is now the single source both sides use — injected into
  `ImportService` from the locator with the same catalog `VaultCubit` gets — and `dedupeKey` additionally reduces
  the issuer to its `IssuerAvatar.slugFor` slug, which collapses `github.com`/`GitHub` on spelling alone. Aliases
  still need the catalog; the slug cannot invent one. **Known limit, documented in the doc comment:** no Unicode
  NFC/NFD normalization — a precomposed `é` and its decomposed twin still key differently, and fixing that needs
  a package the project deliberately does not carry.
- **[P2] The file import path had no entry ceiling (A3).** `ImportFileTooLargeException` bounded bytes, but a
  small file packed with tiny entries sailed past it. `ImportService.maxEntries = 1024` (accounts + skipped, the
  same ceiling the Google path already had) now rejects the file whole with `ImportTooManyEntriesException`
  rather than truncating — importing the first 1024 of a 5000-entry file would leave the user believing it all
  came across. The Turkish message is "Dosyada çok fazla kayıt var (en fazla 1024)."
- **[P2] Push and merge could interleave and re-upload a stale blob (A4).** `pushChanged` ran outside any
  sequencer, so an `applyRemoteMerge` arriving during a long import push wrote a newer blob to disk while the
  in-flight push was still uploading the snapshot it had read beforehand — the server kept the stale one and
  handed it back on the next pull. `TokenSyncService` now serializes `exportRaw + pushUpsert` against the merge
  write with its own async mutex. Deliberately **not** `VaultCubit._opChain`: that queue guards UI mutations and
  must not have a network round trip parked in it.
- **[P3] Re-enabling the sync kill-switch did not catch up (A5).** While `token_sync_enabled` was false,
  `syncOnce`, `pushChanged` and the Realtime trigger were all no-ops, so both server rows and local dirty records
  piled up; restoring the subscription only announced what happened *next*. A false→true transition now runs a
  catch-up `syncOnce` in the same subscribe-then-pull order as `start`.
- **[P3] Final dedupe before `addAll` (A6)** — a token pulled in between preview and confirm no longer slips in
  twice.
- **[P1] On the FIRST sync, a dirty local record now beats a colliding remote row (A2 follow-up).** With
  `pullCursorIso == null` this device has never completed a pull, so there is no reference point that could prove
  a server row arrived *after* our unpushed record — yet the old rule handed the win to the server anyway. That
  turned the A1 resurrection into a silent deletion in the exact case A1 exists for: restore an id-preserving
  backup, resurrect a deleted token (live, `sv == null`), sync for the first time, and the server's tombstone
  wiped it again. Ids with no local record are still always accepted, so a first pull still brings the whole
  vault down; only records waiting to be pushed are left alone, and the collision is settled by server-side LWW
  once the push lands. **Behaviour change**, deliberately: local wins that one race.
- **[P1] `exportRaw` and `_pushDirty` return at most one record per id (A2 follow-up).** `_corruptedRaw` holds
  records that are schema-valid but undecryptable, so one id could legitimately sit in both `_corruptedRaw` and
  `_lastById` and reach the disk twice — and `pushUpsert(onConflict: 'id')` answers a batch carrying the same id
  twice with Postgres 21000, which wedges **every** later push, not just that one. Both the store and the sync
  service now collapse duplicates with the same rule used everywhere else: a live record beats its own tombstone
  (deliberate resurrection), and between two of the same kind the first on disk wins. "Last wins" was not an
  option — it could turn a resurrection back into a tombstone and lose the token silently. The service-side pass
  is defence in depth: `RawTokenStore` is a port, and another implementation (or a hand-edited file) can hand it
  duplicates.

### Parser fidelity — Aegis / 2FAS (B1–B6)

- **[P1] The Steam issuer heuristic is gone (B1).** Both parsers promoted an entry declared `totp` to
  `OtpType.steam` when its issuer read "Steam", forcing 5 digits — which turns a working 6-digit TOTP the user
  merely *named* Steam into a token that generates wrong codes. Both formats have a first-class Steam type
  (`type: "steam"`, `tokenType: "STEAM"`), so the declared type is the only authority, exactly as on the Google
  path. The digits/SHA-1 forcing stays, but only for an entry the file itself declares Steam. The two tests that
  asserted the promotion now assert the opposite.
  **One issuer-based inference deliberately survives**, in `core/otp/otpauth_uri.dart`: the `otpauth://` scheme
  has no Steam host, so Steam Guard links are conventionally written as
  `otpauth://totp/Steam:<account>?issuer=Steam` and the issuer really does carry the type there. Aegis, 2FAS and
  Google all have (or lack) an explicit type field instead, which is exactly why the heuristic is wrong in those
  three and right in this one. Noted in the parser's doc comment so the asymmetry does not read as an oversight.
- **[P2] 2FAS encryption detection follows the official predicate (B2).** 2FAS's own `BackupContent.isEncrypted`
  is "`reference` is not blank"; we only checked `servicesEncrypted`, so an encrypted export could reach the
  parser and fail as "malformed" instead of telling the user to re-export unencrypted. Both are now checked, and
  the fixture's `reference` carries a realistic three-part `data:salt:iv` base64 value.
- **[P2] Known-but-unsupported algorithms are `unsupportedType`, not `invalidFields` (B3).** `SHA224`/`SHA384`
  (both in the 2FAS enum) and `MD5` are recognized names we do not implement, so they are skipped with an
  `algorithm=<NAME>` detail. A name we do not recognize at all remains `invalidFields` — the taxonomy now tracks
  "we know it and won't" versus "this file is wrong".
- **[P3] 512-byte ceiling on parsed strings (B4)** — issuer/name/account, the same `maxStringBytes` the Google
  path uses; over it the entry is skipped as `invalidFields`.
- **[P3] Fixtures now match what the apps actually export (B5).** `twofas_steam_hotp.json` lost the invented
  `initialCounter` field (the parser's tolerance for it stays, re-labelled defensive rather than observed), the
  impossible `totp` + `MD5` row in `aegis_mixed_types.json` became a realistic `motp` entry, and Aegis entries
  carry the `icon_mime`/`icon_hash` fields the parser ignores. A fixture that cannot come out of the real app
  proves nothing about the real app.
- **[P3] 2FAS `[hidden]` secrets get a source-specific message (B6)** — "re-export without link" rather than a
  generic parse failure. The secret string itself is never echoed.

### Platform and UI (C1–C10)

- **[P1] The iOS export left a full copy of the backup in Documents (C1).** file_picker 11.0.3 implements the iOS
  `saveFile` by writing the bytes into `NSDocumentDirectory/<fileName>` and exporting *that*; nothing removes the
  source, and `clearTemporaryFiles()` only walks `NSTemporaryDirectory()`, so it never sees the file. The app's
  Documents directory is part of the iCloud/iTunes device backup — so a backup the user put on a USB stick also
  rode silently to iCloud. `FilePickerDocumentPort.saveJson` now zero-fills and unlinks it in a `finally`
  (best effort; a housekeeping failure must not turn a finished export into an error), `path_provider` was
  promoted to a direct dependency for it, and the code comment claiming "no temp file to shred" is corrected.
  The export screen's "Dosya cihazından çıkmaz" — which was simply false about a file the user is choosing where
  to put — now reads "Dosya yalnız seçtiğin yere kaydedilir; geçici kopya silinir."
- **[P2] Camera action guards on the scan screen (C2)** — flash and camera-switch are disabled until the
  controller reports `isInitialized`, hidden while a migration preview is up, wrapped in try/catch, and the flash
  button is not rendered at all where `torchState == unavailable`.
- **[P2] The skipped-entries list is bounded (C3).** `ExpansionTile` builds all its children at once, and the
  import path admits 1024 entries, so the audit list now renders at most 50 rows plus a "+k tane daha" line.
- **[P3] Smaller UI follow-ups (C4–C8):** the consumed preview is cleared after confirm on both the import page
  and `ScanPage` (which now falls back symmetrically, `maybePop` then `go(Routes.vault)`); a separate message for
  a single-token QR scanned mid-migration, and a short snackbar for a different-batch code arriving while a
  dialog is open; a "Başka dosya seç" secondary action on the password and preview steps; `PasswordStrengthBar`
  colors bound to `ColorScheme` roles with `Semantics(excludeSemantics: true)` so the bar is not read three
  times; `@visibleForTesting` on the pages' injected service seams.
- **[P3] `SecureScreen` native-failure handling (C9).** A failed `enable` marked the protection off so the next
  `acquire()` would retry — but with only one sensitive screen open, that next `acquire()` never comes. A failed
  `enable` now also schedules a **single** 500 ms retry (one-shot, never a loop). And a failed `disable` no longer
  records the protection as off: native protection is still ON in that case, and the bookkeeping must not drift
  away from it.
- **[P3] Absolute cap on the file-picker lock exemption (C10).** The 2-minute budget was renewable without limit,
  which turned a bounded concession into an unbounded one. Renewal stays — a user really can spend more than two
  minutes in a cloud provider's folders — but `VaultLockCubit.systemFileFlowMaxTotal` (10 minutes) now measures
  from the **first** begin of a run and refuses renewals past it, leaving the running deadline to expire on its
  own. `endSystemFileFlow()` clears the clock.

### Documentation (D1–D7)

- **docs/CRYPTO.md §15** — the protected-screen table was three screens out of date and still listed `scan`
  under "deliberately NOT protected" after Patch 2 had given it its own scope. Import, export and scan are now in
  the table (11 screens; `grep -rn "SecureScreenScope(" lib/` is named as the authoritative list), the
  not-protected line is rewritten, and the native-failure paragraph documents the C9 behaviour.
- **docs/CRYPTO.md §16.2** — records why `createdAt` is deliberately outside the AAD (it changes nothing about
  how the ciphertext is opened, and an ISO-8601 timestamp has several valid spellings, so binding it would break
  honest re-serialization for no security gain).
- **docs/CRYPTO.md §16.5** — adds the `Isolate.run` copy as a second accepted memory-hygiene limit alongside the
  unwipeable `String`, and the iOS Documents leftover with its shredder.
- **docs/CRYPTO.md §17** — budget **renewal** was never written down at all; it is now, together with the
  absolute cap.
- **Screen lists** in ARCHITECTURE.md §2.1, docs/architecture.md §7 and PLAN.md (Phase 3.5 + Phase 7) said six or
  eight screens; all now say 11 and point at the grep.
- **Test counts** were stale everywhere they claimed to be current: README's `flutter test` line said 713,
  PLAN.md's CI line said 454 host / 38 integration, README's Phase 2 row said the integration suite was 38
  "today". Measured and corrected to **992 host / 50 integration**. The Patch 2 row's 899 was also inconsistent
  with that patch's own changelog entry (909) and is fixed.
- **`file_picker` pin rationale (pubspec.yaml, ARCHITECTURE.md §4.1, docs/architecture.md §8.1)** — the comment
  explained the win32 conflict but neither cost of staying: `file_picker 12` cannot move without
  `device_info_plus 13` (one coupled job, now a PLAN.md item), and 11.0.3's iOS podspec links
  `DKImagePickerController/PhotoGallery` → `SDWebImage`/`SwiftyGif` into a document-only app unless
  `PICKER_MEDIA=false` is set in `ios/Podfile`. `ios/Runner/Info.plist` has no `NSPhotoLibraryUsageDescription`,
  so that is a release-review question — added to the Phase 7 checklist.
- **Other doc corrections:** `/import` and `/export` added to docs/architecture.md's route matrix; the README
  folder tree gained the five directories it never listed (`core/crypto`, `core/config`, `core/platform`,
  `core/ui`, and the `account`/`auth`/`settings` features); ARCHITECTURE §5 gained the A1/A4/A5 sync-contract
  rules and §4.1 the dedupe and entry-ceiling rules; a note that `postgrest 2.9` auto-retries GET/HEAD three
  times on 503/520 by default (writes are never retried, so `pushUpsert` cannot be duplicated behind our back);
  PLAN.md's "minor upgrades are kept current" softened to what it actually was, a point-in-time sweep; Supabase
  leaked-password protection added to Phase 7; three stale test-file headers still referring to unwritten "W1/W2"
  work rewritten; the duplicate `coverage/` line dropped from `.gitignore`; docs/README.md's "15 ekran" now says
  which two screens have no spec file yet.
- **Corrections to earlier entries in this file** are marked in place rather than rewritten — see the Patch 2 and
  Patch 1 sections above for the superseded Steam passages and the "docs/CRYPTO.md is untouched" claim.

## 2026-09-02 (Phase 5 Patch 2 — Google Authenticator import)

Import from a Google Authenticator **transfer QR** (`otpauth-migration://offline?data=…`), single- and
multi-code exports alike. **NO Supabase schema change, NO new crypto primitive, NO sync-protocol change** — the
imported tokens travel the same
`VaultCubit.addAll → EncryptedVaultRepository → RawTokenStore → pushUpsert` path as Patch 1's.
host **736/736 → 909/909**, integration unchanged (**50**, not run on a device this patch — see the manual
checklist below), `flutter analyze --fatal-infos` clean.

> **Correction (2026-09-02, audit follow-ups).** This entry originally also claimed
> "[docs/CRYPTO.md](docs/CRYPTO.md) is untouched". That was wrong: this patch wrapped `ScanPage` in
> `SecureScreenScope`, which contradicted §15's list of protected screens and its explicit "scan is deliberately
> NOT protected" line. §15 has now been corrected. The crypto model itself was indeed untouched — the stale claim
> was about the document, not the design.

### The payload format

Google's export QR is not an `otpauth://` URI: it is a base64 **protobuf** `MigrationPayload` in the `data`
query parameter. Seven fields, all of them handled:

```
MigrationPayload { repeated OtpParameters otp_parameters = 1; int32 version = 2;
                   int32 batch_size = 3; int32 batch_index = 4; int32 batch_id = 5; }
OtpParameters    { bytes secret = 1; string name = 2; string issuer = 3;
                   Algorithm algorithm = 4; DigitCount digits = 5; OtpType type = 6; int64 counter = 7; }
```

`version` is read and validated but is **never a reason to reject** a payload — a future exporter bump must not
turn a user's tokens into an error message. `batch_id` is a **signed** `int32`: 0 is a perfectly ordinary value
and a negative one arrives sign-extended as a full 10-byte varint, so the collector's "which export is this?"
state is a nullable `int?` rather than a sentinel, and the decoder accepts 10-byte varints.

### Why a hand-written protobuf decoder

`features/import_export/data/protobuf_wire.dart` is ~200 lines of `ProtobufReader` (tag / varint /
length-delimited / skip). No `protobuf` package, no `build_runner`:

- **The project has no codegen anywhere.** Adding a generator and a `.proto` build step for one 7-field message
  would be the single largest tooling change in the repo, for the smallest payload in it.
- **Proto3 field presence is the whole HOTP rule.** A generated message hands back `counter == 0` for both "the
  counter is zero" and "there is no counter field", and the two are not the same token: Patch 1's doctrine is
  that an HOTP entry with no counter is **skipped**, never defaulted to 0 (a guessed counter silently produces
  codes the server rejects). Tracking presence is trivial in a hand-written reader and awkward otherwise.

Hard limits, each a `FormatException` rather than an allocation: URI **8 KiB**, decoded payload **64 KiB**
(estimated from the base64 length *before* decoding), **256** entries per QR, **1024** accounts across an
export, **16** codes per export, 1024-byte secrets, 512-byte strings, 10-byte varints. Wire types 3/4 (the
deprecated groups) are refused, unknown fields are skipped, a repeated scalar takes the last value, and strings
are decoded with `allowMalformed: false` — a mojibake `name` skips that one entry instead of failing the QR.

### The `Uri.queryParameters` trap

`Uri.queryParameters` applies `application/x-www-form-urlencoded` rules, where **`+` means space**. Standard
base64 uses `+` as a symbol, so any payload whose base64 happens to contain one would silently decode into
garbage — intermittently, depending on the secret bytes. `GoogleAuthParser` therefore splits `uri.query` on
`&`/`=` by hand and runs `Uri.decodeComponent` itself. Both the raw and the percent-encoded form of the same QR
must produce identical accounts; golden vector B (`3e3ffbefbefa…`, chosen so its base64 is `+`-heavy) exists
exactly to pin that.

### Field mapping

| Proto | → | Rule |
|---|---|---|
| `secret` | `secret` | `Base32.encode(bytes)` — encode, not decode: every byte string has a Base32 form, so there is no error path that could quote a secret. Empty → `invalidSecret`. |
| `name` | `accountName` (+ issuer fallback) | Split on the first `:`, the same rule as the `otpauth://` parser. |
| `issuer` | `issuer` | The dedicated field wins; otherwise the `name` label prefix; otherwise `null`. Empty account name → issuer → `(isimsiz)`. |
| `algorithm` | | 0/1 → SHA1, 2 → SHA256, 3 → SHA512, **4 (MD5) → skipped** (`unsupportedType`), anything else → `invalidFields`. |
| `digits` | | **0 (UNSPECIFIED) → 6**, 1 → 6, 2 → 8, anything else → `invalidFields`. |
| `type` | | **0 (UNSPECIFIED) → skipped**: HOTP and TOTP are not interchangeable and an unlabelled entry cannot be guessed. 1 → HOTP, 2 → TOTP. |
| `counter` | | HOTP with **no counter field at all** → `invalidFields`; negative → `invalidFields`; ignored for TOTP. |
| — | `period` | Always **30**. The format has no period field; Google's exporter only ever writes 30-second TOTP. |

Every skip is a `SkippedEntry(reason, label)` — an `"Issuer (account)"` label at most, **never a secret**, and
the underlying exception message is never propagated. One bad entry never costs the user the rest of the QR.

### Why Steam is deliberately NOT promoted here

Patch 1 promotes an Aegis/2FAS entry whose issuer is `steam` to `OtpType.steam`. This importer **does not**, on
purpose: Google Authenticator cannot hold a Steam token in the first place (Steam's codec is 5-digit and
non-RFC), so an entry that merely *says* "Steam" is an ordinary 6-digit TOTP the user set up under that name.
Promoting it would rewrite a working token into one that generates wrong codes — the exact failure the Patch 1
review fixed in the 2FAS heuristic. The `period 30` default has the same shape of reasoning.

> **Superseded 2026-09-02 (audit follow-ups).** The reasoning above outlived its exception: the Aegis/2FAS issuer
> heuristic it contrasts itself with was **removed**, because the same argument applies there too. Both formats
> have a first-class Steam type (`type: "steam"` / `tokenType: "STEAM"`), so an entry the file itself calls TOTP
> is a TOTP whatever its issuer reads. No import path infers Steam from an issuer any more.

### Multi-QR exports — `GoogleMigrationCollector`

A large vault leaves Google as several QRs sharing one `batch_id`, each stamped with its `batch_index` of
`batch_size`. The collector (`domain/google_migration.dart`, pure Dart) stitches them back:

- The first accepted code **pins** `batch_id` and `batch_size`; the codes may then be scanned **in any order**
  (`toParsedImport` re-orders by `batchIndex`, so the preview is stable).
- A code from **another export** (`differentBatch`) is **never merged** — not even partially. Every check runs
  before a single field is written, so a stray or hostile QR cannot corrupt what the user already scanned; the
  screen offers "start over" instead.
- Re-scanning a code already collected is a no-op (`duplicateIndex`), self-inconsistent coordinates (index 3 of
  2) are `invalidBatch`, and exceeding 1024 accounts is `full`.
- **A partial import is allowed.** "Bu kadar yeter" imports what has been scanned; the dedupe key means a later
  complete run adds the rest instead of cloning the first half.

### `mobile_scanner` finding: `noDuplicates` survives a reset (Android)

"Baştan başla" clears the collector, but on Android `DetectionSpeed.noDuplicates` keeps the last emitted payload
in `MobileScanner.kt`'s `lastScanned` field and refuses to emit that value again. The field is nulled **only**
in `start()` and `stop()` — so after a reset, the user re-showing the very first QR would have been swallowed by
the plugin, with no error anywhere. The reset path therefore does `stop()` + `start()`, not just a state clear.
The mirror-image finding on iOS/macOS: there is **no** payload comparison at all there, `noDuplicates` only
throttles the frame rate, so the same QR arrives over and over. Three guards absorb the repeats: dialogs are
re-entrant (`_dialogOpen`), a frame arriving once the preview has been requested is dropped (`_previewing`), and
a repeated error message is throttled instead of re-snacked (see "Review follow-ups" below).

### Screen, entry points and what is deliberately not wired

- **One `ScanPage`, no new route, no guard or DI change.** `_onDetect` asks
  `GoogleAuthParser.looksLikeMigrationUri(raw)` first and switches into migration mode by *schema detection*;
  everything else still takes the single-token `otpauth://` path. While a migration is in progress a plain
  single-token QR is **not** added — mixing one stray code into a batch import is never what the user meant.
- **`ScanPage` is now wrapped in `SecureScreenScope`.** It was not before, and it is the one screen that renders
  a QR — i.e. a secret — full-bleed. Cold deep-links into `/scan` previously left screenshot protection off.
  The ref-counted scope nests safely with the pages that already use it.
- **`MigrationScanController`** (`features/scan/presentation/migration_scan_controller.dart`) holds every
  migration rule in plain Dart — no Flutter, no plugin, no `BuildContext` — because `MobileScanner` needs a real
  camera that the `flutter test` VM does not have. `handleRaw` never throws: a hostile QR is a UI message, and
  the three failure causes (bad URI, bad base64, bad protobuf) collapse into **one** event on purpose, since the
  cause is derived from secret material.
- **Paste guard:** pasting a migration link into the vault's "add by URI" sheet is refused with
  "Bu bir Google Authenticator aktarım bağlantısı. Ekle → \"QR kod tara\" ile okut." — `add` is never called with
  a protobuf blob.
- **`ImportPreviewView`** (`presentation/widgets/import_preview_view.dart`): the preview block moved out of
  `ImportPage` so the file import and the QR import share one widget and one set of strings (which is why the
  existing `import_page` preview tests still pass unchanged). `ImportPage` gained a "Google Authenticator (QR)"
  action with a short how-to sheet.
- **Deferred to Patch 3:** pasting a migration URI and picking a QR *image file* (both need a decoder the camera
  path does not), plus tags/folders.

### Tests

`test/support/protobuf_encoder.dart` is a test-only **encoder** — no real Google export may enter this
repository, since that would be a committed bundle of live secrets, so every fixture is synthesized. It was
written by hand against the plan's independently derived golden vectors and compared byte for byte before any
decode was trusted, so the decoder is never checked against itself.
`end_to_end_test.dart` grew a migration group that runs the real parser, the real collector, the real controller
and the real `ImportService.previewParsed` (real `detectSource`/`dedupeKey`, `BackupFakeCrypto`): golden vector A
from raw QR string to a one-token preview; three codes scanned **out of order**, where the repeated token
collapses to `duplicateInFile`; the same token already in the vault → `alreadyInVault`; and a foreign `batch_id`
refused with the two already-scanned codes left intact.

### Review follow-ups

Fixes from the patch review, all on the same host-only surface:

- **SnackBar flood on iOS.** `noDuplicates` does no payload comparison there (`MobileScannerPlugin.swift` only
  forces the frame timeout to 0), so a QR left in the frame re-fired `clearSnackBars()` + `showSnackBar()` every
  single frame. `_showError` now suppresses the **same** message for 2 seconds (`ScanPage.errorRepeatWindow`,
  clock injectable as `debugNow`); a different message still appears immediately.
- **The progress band moved to `bottomNavigationBar`** and error snacks are `SnackBarBehavior.floating`. A
  floating SnackBar is laid out above the Scaffold's bottom widgets, so the counter and the three exits are no
  longer covered by the message telling the user why nothing happened.
- **`_restartCamera` splits `stop()` and `start()`.** A throwing `stop()` used to skip `start()` outright and
  leave the screen with a dead camera after "start over". The test seam widened to `(stop:, start:)` so both are
  counted separately.
- **`_dialogOpen` is cleared in a `finally`.** A throwing `showDialog` would otherwise pin the flag and the
  dialog would never open again.
- **Preview race.** `_showPreview` claims the screen with a `_previewing` flag *before* its first `await` and
  stops the camera first; a frame landing in that window is dropped instead of mutating the collection the
  preview was computed from. If nothing is importable the flag drops and the camera restarts.
- **Two QRs in one frame.** In migration mode every `rawValue` of a `BarcodeCapture` is processed, not just the
  first: Android's `lastScanned` records the whole frame, so a second code held next to the first would never be
  emitted again. Single-token mode still takes the first value.
- **Non-canonical 10-byte varints are rejected.** On the tenth byte only bit 63 can legally be contributed, so
  its payload must be `0x00`/`0x01`; anything else would wrap silently into a different value. Golden vector B
  (`…ff01`) is unaffected.
- **`maxAccounts` now counts skipped entries too.** The preview renders one eager `ExpansionTile` row per skip,
  so an export made of nothing but unmappable entries used to sail past the 1024 ceiling.
- **Pinned, not changed:** `?data=a&data=b` resolves to the **first** value (the rule `Uri.queryParameters`
  applies); a test fixes it so a later refactor cannot drift to "last wins". `ImportPage._showGoogleGuide` also
  gained a `mounted` check between the sheet's `pop` and the `push` to `/scan`.

### Not verified on a device — manual checklist

Everything above is covered on the host VM against synthesized payloads. Before release:

- export from a **real Google Authenticator** — both a **single-QR** vault and a **multi-QR** one — and import
  both on a real device; confirm the resulting codes match what Google shows;
- on **iOS**, watch the UX of the same QR re-triggering (no `lastScanned` there): the counter must not climb, no
  dialog may stack, and "Baştan başla" must accept the first code again;
- re-scan an export whose tokens are already in the vault → everything must read "already in your vault", not a
  second copy.

## 2026-09-02 (Phase 5 Patch 1 — Import/Export)

Aegis + 2FAS import and a password-encrypted backup export. **NO Supabase schema change, NO new crypto
primitive, NO sync-protocol change.** Imported tokens travel the existing `VaultCubit → EncryptedVaultRepository
→ RawTokenStore → pushUpsert` path as opaque blobs.
host **459/459 → 713/713**, integration **38 → 50** (not run on a device this patch — see the manual checklist
below), `flutter analyze --fatal-infos` clean.

### Source parsers — Aegis (plain JSON) + 2FAS (schema v4)

`features/import_export/data/{aegis_parser,twofas_parser}.dart`, both pure Dart behind the `ImportParser`
interface. The guiding rule: **one bad entry must never cost the user the rest of the file.** Every failure is
recorded as a `SkippedEntry` (reason + an `"Issuer (account)"` label at most — **never a secret**) and the import
continues. Deliberate tolerance decisions:

- **HOTP without a counter → skipped**, not defaulted to 0. Both `counter` and `initialCounter` are accepted
  (the field has been spelled both ways in the wild), but a guessed counter silently produces codes the server
  rejects, which is worse than an honest "skipped".
- **`motp` / `yandex` entries → skipped** (`unsupportedType`). Their "secret" is not an RFC 4648 Base32 OTP
  secret, so importing them would only create tokens that generate wrong codes.
- **Unknown algorithm → skipped** (e.g. a 2FAS service declaring `MD5`).
- **Steam promotion:** an entry declared `totp` whose issuer is `steam` is promoted to `OtpType.steam`, matching
  how the `otpauth://` parser already behaves. Steam entries then get `digits: 5` / SHA-1 forced, because the
  Steam codec is fixed and the file's values are cosmetic.
  *(**Removed 2026-09-02**, audit B1: the promotion half was wrong — the declared type is the only authority, and
  both formats have one. `digits: 5` / SHA-1 forcing survives, but only for an entry the file itself declares
  Steam.)*
- **Encrypted sources are recognized, not mangled:** an Aegis vault with populated `header.slots`, or a 2FAS file
  with `servicesEncrypted`, raises `EncryptedSourceException` with source-specific guidance instead of failing as
  "malformed".
- **`groups` is deliberately not read** — tags/folders are Patch 3.

### Format detection + duplicate key

- **`detectSource`** (`domain/import_format_detector.dart`) fingerprints the ROOT JSON object, in order:
  `format == "projectauth-backup"` → our backup; `db` && `header` → Aegis; `services` || `servicesEncrypted` →
  2FAS; otherwise `unknown`. The UI calls it first so it only asks for a backup password when the file actually
  is one of our own backups.
- **`dedupeKey`** (`domain/dedupe.dart`) = `issuer + accountName + Base32.decode→encode(secret)`, all trimmed and
  lower-cased. The Base32 round trip is the point: exporters disagree on padding and case, so
  `"jbswy3dp ehpk3pxp="` and `"JBSWY3DPEHPK3PXP"` must yield one key. `type`, `digits`, `period` and `counter`
  are intentionally **excluded** — a re-import after the user edited digits, or an HOTP counter that has since
  advanced, must still read as "already in your vault" rather than silently cloning the token.
  **The key contains the secret** and is an in-memory comparison value only: never logged, persisted or shown.

### Encrypted backup envelope + `BackupService`

`projectauth-backup` **v1**: `{format, version, createdAt, kdf{alg,opslimit,memlimit,salt}, cipher{alg,nonce}, ciphertext}`.
No new primitive — the same Argon2id + XChaCha20-Poly1305 IETF through the existing `CryptoService`, with
`defaultKdfParams()` as the single source of the cost values.

- **Why the AAD is derived and never stored:** the KDF cost parameters must live in the file so a future build can
  open an old backup — which makes them **attacker-controlled**. `AAD = "backup|<v>|<kdf.alg>|<ops>|<mem>|<b64 salt>|<cipher.alg>"`
  is recomputed from the envelope on every read, so an attacker who rewrites `opslimit` to `1` to cheapen a
  brute force simply fails the tag check. A stored `aad` field would be attacker-controlled too and would defeat
  the construction. The salt is re-encoded from its decoded bytes, so a non-canonical base64 cannot shift the AAD.
- **Strict validation before sodium** (same doctrine as CRYPTO.md §8): `format`, `version`, ISO-8601 `createdAt`,
  `kdf.alg`, `opslimit` 1..10, `memlimit` 8 MiB..512 MiB, 16-byte salt, `cipher.alg`, 24-byte nonce, ≥16-byte
  ciphertext. Two-sided bounds: the floor blocks a cost downgrade even before the AAD check, the ceiling blocks a
  DoS file that would ask sodium for an absurd allocation.
- **The backup password is independent of the master password** — the file must open on a device with no vault, so
  it cannot be tied to `KeyAttributes`. Neither the master password nor the recovery mnemonic opens a backup; the
  export screen says so explicitly.
- Wrong password and tampered bytes are indistinguishable by design (that is what an AEAD is) → one
  `WrongBackupPasswordException`. A malformed record inside a decrypted payload is skipped, not fatal;
  `importDetailed()` surfaces the drop count for the preview while `import()` returns just the usable accounts.
- **`KeyManager.enforcePolicy`** extracted as a static: `KeyManager._enforcePasswordPolicy` now delegates to it and
  `BackupService.export` calls it directly, so the backup password is held to exactly the same 12-character /
  3-character-class rule and the same Turkish messages as the master password — refused **before** any Argon2id work.

### `ImportService` — preview before anything is written

`preview()` returns an `ImportPreview` (`toAdd`, `skipped`, `addCount`/`duplicateCount`/`skippedCount`) and touches
the vault not at all, so previewing is always side-effect free. Parsing runs in `Isolate.run` (pure CPU on plain
data); backup decryption stays on the main isolate because the crypto service holds native handles. An 8 MiB
ceiling is enforced on the UTF-8 byte length before any JSON is decoded. Duplicates are reported separately from
real failures — a file whose entries all turn out to be duplicates is a valid preview ("N already in your vault"),
not an error. Our own backups additionally de-duplicate on the stable `id`, the only source that preserves it.

### Shared `FakeCrypto`

The inline fake from `encrypted_vault_raw_store_test.dart` moved to `test/support/fake_crypto.dart` and grew into a
proper oracle: round-trip, **AAD binding**, **key binding** (derived from password + salt) and a hash-based stand-in
for the Poly1305 tag — so wrong-password, tamper and parameter-downgrade behaviour is reproducible on the plain
`flutter test` VM, where libsodium's plugin does not load. `BackupFakeCrypto` adds envelope-legal Argon2id
parameters (the base fake's 1 MiB is below the envelope's 8 MiB floor on purpose).

### UI, routes and packages

- **`ImportPage`** (one page, three steps: pick file → backup password if needed → preview → confirm) and
  **`ExportPage`** (two password fields + strength bar → save → a warning dialog that the backup password is the
  only key). Both wrapped in `SecureScreenScope`; password fields obscured, cleared on dispose; **nothing is ever
  put on the clipboard** and no secret reaches the screen or a log.
- **Settings → "YEDEKLEME VE AKTARIM"** section ("İçe aktar" / "Şifreli yedek al"), and an
  "import from another app" entry in the vault's add menu.
- **Routes `/import` and `/export`** as children of the unlocked ShellRoute, added to the router guard's unlocked
  allow-list. `_confirmImport` falls back to `context.go(Routes.vault)` when there is nothing to pop (a deep link
  straight into `/import`), so the user is never stranded on a consumed preview.
- **`DocumentPort`** (`pickJson({maxBytes})` / `saveJson({fileName, bytes})`) is the only seam onto the platform,
  which keeps both pages testable without a plugin.
- **`file_picker ^11.0.3`** — held on the 11.x line deliberately: `file_picker >=12.1.3` pulls
  `windows_file_picker` → `win32 ^6.3.0`, while the existing `device_info_plus ^12.1.0` requires `win32 ^5.11.0`,
  so the 12.x line does not resolve. 11.0.3 exposes the same `withData` / `saveFile(bytes:)` API, and SAF /
  `UIDocumentPicker` need no runtime permission → no `share_plus`/`path_provider` fallback is required.
- **`VaultCubit.addAll(List<OtpAccount>)`** — a whole import lands with **exactly one persist and one push**
  instead of N round trips through `add()`. It deliberately does not delegate to `add()`; callers de-duplicate
  beforehand.

### ⚠️ Lock exemption during system file flows — a deliberate threat-model concession

The system file picker runs in a separate process, so the app receives `paused` and the normal rule wipes the
master key and tears the unlocked subtree down — which would make the feature impossible. Both flows are therefore
wrapped in `VaultLockCubit.beginSystemFileFlow()` / `endSystemFileFlow()`:

- skips the background lock **including `paused`** (the pre-existing biometric exemption only covered `inactive`);
- bounded by a **fixed 2-minute budget**;
- closed in a **`finally`** at every call site (cancel, throw and dispose all end it);
- on resume `main.dart` checks `systemFileFlowExpired` and **locks immediately** when the budget was exceeded.

`onAuthSignedOut` and an interactive `lock()` are **not** affected. **What is given up:** for at most two minutes,
someone with physical access to an unlocked-but-backgrounded device finds the vault still unlocked, and the master
key stays resident for that window. Recorded as a concession in [docs/CRYPTO.md §17](docs/CRYPTO.md).

### Integration wiring + regression cover

`locator.dart` now injects the concrete parsers (`ImportService(backup: ..., parsers: [AegisParser(), TwoFasParser()])`)
and passes **no** `detector`/`keyOf`, so production always gets the real `detectSource`/`dedupeKey`.
`test/features/import_export/end_to_end_test.dart` drives that exact wiring against the fixtures — every other test
in the folder stubs one layer, so a mis-wired DI would have left them all green.
`BackupService.parseEnvelope`/`parsePayload` and `ImportService.decodeRoot` were made `static`: they use no
instance state, and keeping them off the implicit interface means test doubles that `implements` these classes do
not have to stub pure JSON helpers.

### Not verified on a device — manual checklist

The integration suite (`integration_test/backup_service_test.dart`, 12 tests: real-libsodium round trip, wrong
password, tampered ciphertext, tampered nonce, and the `opslimit`/`memlimit` downgrade that proves the AAD) was
**not executed on a device or simulator in this patch**. Before release, run it and walk through:

- import a **real** Aegis export and a **real** 2FAS export (field names verified against fixtures only so far);
- `DocumentPort.saveJson` → `file_picker.saveFile(bytes:)` on a **real Android device and a real iOS device**;
- **R4:** create a backup, `resetVault`, restore the backup, then confirm sync converges (a restore re-adds ids the
  local tombstone had removed — a backup is a point-in-time copy, so resurrection is intended, but the
  tombstone/sync interaction has not been exercised end to end).

### Review follow-ups

Fixes for the findings of the Phase 5 Patch 1 code review; same scope rules (no new crypto primitive, no server
schema change, no sync-protocol change). Host suite **713/713 → 736/736**, `flutter analyze --fatal-infos` clean.

- **[P1] The picker left a plaintext copy of the backup in the app cache.** `withData: true` does not stop
  file_picker from materialising the picked document (iOS `NSTemporaryDirectory()`, Android
  `cacheDir/file_picker/`) and it never deletes it. `FilePickerDocumentPort.pickJson` now calls
  `FilePicker.clearTemporaryFiles()` from a `finally` — success, cancel and throw alike — swallowing every error so
  a failed cleanup (desktop/web throw `UnimplementedError`) cannot turn a completed import into a failure. New
  method-channel test covers all four exits.
- **[P2] The file-flow budget could be lost to a race.** `endSystemFileFlow()` cleared the flag unconditionally, so
  a picker result arriving before the `resumed` lifecycle event slipped past `main.dart`'s `systemFileFlowExpired`
  check and the vault stayed open. The budget is now enforced **on `end`**: an already-lapsed exemption locks
  immediately. The resume check stays as a second layer.
- **[P2] 2FAS Steam heuristic read the wrong field.** It used the issuer-with-name fallback, so a service the user
  named "Steam" with an ordinary 6-digit TOTP was rewritten into a 5-digit Steam token. It now reads `otp.issuer`
  only; the `tokenType == steam` path is unchanged.
  *(**Superseded 2026-09-02**, audit B1: narrowing the field was treating the symptom. The heuristic is gone from
  both parsers — a token the file declares TOTP stays a TOTP regardless of its issuer.)*
- **[P3] The lock exemption now also ends on screen `dispose`.** A page torn down while the OS dialog was up
  (router redirect, back gesture) left the exemption running until its budget lapsed. Both pages capture the cubit
  in `didChangeDependencies` and close an active flow in `dispose` — which is what docs/CRYPTO.md §17 already
  claimed.
- **[P3] `BackupEnvelope.maxMemLimit` 1 GiB → 512 MiB.** A 1 GiB Argon2id allocation is an OOM kill on a mid-range
  phone, i.e. a crash rather than a rejected file. No backup we write comes near the new ceiling.
- **[P3] An all-skipped file no longer throws away the reason.** `dedupeSync` raised `EmptyImportException` whenever
  parsing produced 0 accounts, discarding the skip records. It now throws only when the file yielded *nothing at
  all*; 0 accounts + skips returns a preview with an empty `toAdd`, so the UI keeps "İçe aktar" disabled and shows
  the "Atlananlar" list.
- **[P3] `VaultCubit.addAll` drops ids already present.** The vault can change between preview and confirm (sync
  pull, another path), which would have put the same id in the list twice — `removeById` deletes both, sync pushes
  one row twice. A cheap set check keeps the existing row; an all-duplicate call is a no-op (no write, no push).
- **[P3] `OtpAccount.toString()` no longer prints the secret.** Equatable's `stringify` defaults to ON in debug
  builds, so any widget-tree dump, assertion message or failing CI test that interpolated an account leaked the
  TOTP seed. `stringify => false`; equality and `hashCode` are untouched.
- **[P3] `pushUpsert` chunks at 500 rows.** A large import or first sync sent thousands of bytea rows in one body
  (413 / statement timeout). Chunks go out in order and the upsert is id-idempotent, so an interrupted push resumes.
- **[P3] Docs + smaller notes:** `createdAt` is marked as unauthenticated-by-design next to the AAD derivation (the
  authenticated timestamp is `exportedAt`, inside the payload); `pickJson` documents that its size ceiling is a UX
  guard which cannot run before the bytes exist; docs/CRYPTO.md §16 limit table and §17 bullets updated.
- **Deferred:** the detector's double JSON decode (an optimisation) and a pre-read size limit (documented as
  impossible with this plugin) were left alone.

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

### Review follow-ups

Fixes for the findings of the Phase 3.5 code review; same scope rules (no crypto routine, no server schema, no
sync-protocol change).

- **Legacy `eyJ...` JWT keys are now REJECTED by `SupabaseConfig.validate`** — only `sb_publishable_...` passes. The
  shape check (`eyJ` + three dot-separated segments) is identical for an anon key and an all-powerful `service_role`
  key, so the legacy branch would have accepted a **secret** key into a client build. This project is publishable-key
  based (`supabase/PROJECT_INFO.md`), so the branch had no user left. The unit test flipped from "legacy accepted" to
  "legacy anon AND service_role rejected".
- **CI hardening** (`.github/workflows/ci.yml`): explicit least-privilege `permissions: contents: read`; both actions
  pinned to a full 40-char commit SHA with the tag in a comment (`actions/checkout` **v4.4.0**,
  `subosito/flutter-action` **v2.23.0**) so a moved tag cannot swap the action out; `flutter pub get` →
  `flutter pub get --enforce-lockfile` (CI must build exactly the resolution in `pubspec.lock`).
- **`SecureScreen` survives a native failure:** a `PlatformException` from `enable` used to be swallowed *while the
  counter had already advanced*, so the 0→1 edge never came back and protection stayed silently off for the rest of the
  session. A `_nativeOn` flag now tracks the believed native state and `acquire()` **retries `enable` when protection is
  not on**, even without a 0→1 edge. `MissingPluginException` (test/desktop) behaviour is unchanged, and `debugReset()`
  is debug-only. New unit test: failed first enable → next acquire retries → no redundant call after success.
- **Configuration error screen instead of a black screen:** `ensureConfigured()` throwing inside the async `main()`
  surfaced as an unhandled zone error with nothing on glass. It is now caught and `ConfigErrorApp` (a dependency-free
  `MaterialApp`) renders "Yapılandırma hatası" plus the validator message for the developer. Widget test added.
- **`LoginPage` / `RegisterPage` are now capture-protected** (`SecureScreenScope`): they contain `obscure: true`
  password fields, and while the *account* password is not the master password, it is still a secret on glass. This
  closes the item PLAN.md left OPEN. Per-page mount/unmount tests added, plus a **router-level regression test**
  (`test/core/router/secure_screen_router_test.dart`): pushing `/settings` above the vault with the real
  `createAppRouter` must not emit `disable`.

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
