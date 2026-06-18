# OTP Core (`lib/core/otp/`)

A serverless, pure-Dart OTP engine. No network/IO; all functions are deterministic and
unit-testable. It is the heart of Phase 1; **in Phase 2 (E2E crypto) this model's plaintext
data was encrypted with `masterKey`**, and **in Patch 4 the vault was placed behind a lock/session
flow (setup → unlock/recovery, `VaultLockCubit`)** — tokens are decrypted only after unlock, with the
in-memory masterKey. Details: [CRYPTO.md](CRYPTO.md) (the design system is kept local).

## Files

| File | Responsibility |
|---|---|
| `base32.dart` | RFC 4648 Base32 decode/encode (tolerant of padding/whitespace/lowercase) |
| `otp_algorithm.dart` | `OtpAlgorithm` enum (SHA1/256/512) + `crypto.Hash` mapping |
| `otp_generator.dart` | HOTP (RFC 4226), TOTP (RFC 6238), Steam Guard generation |
| `otp_account.dart` | `OtpAccount` immutable model (Equatable) + `OtpType` |
| `otpauth_uri.dart` | `otpauth://` URI parse / serialize (Key URI Format) |

## Algorithms

- **HOTP (RFC 4226):** `HMAC(secret, counter_8byte_BE)` → dynamic truncation (§5.3)
  → `31-bit int % 10^digits`, left-padded with zeros.
- **TOTP (RFC 6238):** built on HOTP; `counter = floor(unixSeconds / period)`.
  Supports SHA1/256/512 + variable `digits`/`period`.
- **Steam Guard:** TOTP counter + SHA1; instead of digits, 5 symbols from a 26-letter alphabet
  (`23456789BCDFGHJKMNPQRTVWXY`).
- **Countdown:** `secondsRemaining = period - (unixSeconds % period)` — the UI ring.

## `otpauth://` URI

`otpauth://TYPE/LABEL?secret=...&issuer=...&algorithm=...&digits=...&period=...&counter=...`

- `LABEL` = `issuer:account` or just `account` (URL-decoded).
- The `issuer` in the query overrides the issuer in the label (spec precedence).
- Steam detection: `host=steam` **or** (`host=totp` and `issuer=Steam`).
- `secret` is required; missing/malformed scheme → `FormatException`.

### Input validation (at parse time — preventing UI crashes)
`parse()` is the single entry gate (for both QR and manual entry). To prevent malformed input
from crashing at a late stage (during card render), validation is performed **at parse time**:
- **secret** → Base32-decoded; invalid/empty → `FormatException` (otherwise the `secretBytes`
  getter would throw a `FormatException` on the card and crash the UI).
- **digits** → 6–8 (also 5 for Steam); outside that → `FormatException` (digits=0 would produce a meaningless code).
- **period** → 1–600; `period=0` is rejected (otherwise division by zero in `secondsRemaining`/the counter).
- **counter** → ≥0; negative is rejected. **Required for HOTP** (Key URI Format) — if missing,
  `FormatException` (assuming 0 would add the token with the wrong counter). Unused for TOTP/Steam; defaults to 0 if missing.
- **algorithm** → if missing/empty, SHA1 (the RFC default); if provided, SHA1/SHA256/SHA512 (dash/case-tolerant)
  is accepted; **provided but unsupported** (a typo, `SHA3`, `md5`) → `FormatException`
  (otherwise it would silently fall back to SHA1 and produce the wrong code).
- Missing parameter → safe default; **provided but invalid** → rejected.

`features/vault`'s `_AddSheet` catches this `FormatException` and surfaces it to the user as an error.

## Correctness — RFC test vectors

Under `test/core/otp/` there are **54 OTP tests, all passing**. (Historical: at the end of Phase 1 the project
total was 79 = 54 OTP + 16 vault_repository/JSON + 8 VaultCubit + 1 widget smoke. After Phase 2
Patch 4 the host total is **186/186** — crypto/auth/UI were added; see README / PLAN.md.)
The table below is the OTP core's RFC coverage:

| Group | Source | Coverage |
|---|---|---|
| HOTP | RFC 4226 Appendix D | counter 0–9, 6 digits (10 vectors) |
| TOTP | RFC 6238 Appendix B | SHA1/256/512, t=59 … 20000000000, 8 digits (10 vectors) |
| Counter/countdown | — | `totpCounter`, `secondsRemaining` |
| Steam | — | 5 characters + alphabet validation |
| Base32 | RFC 4648 | known vector, tolerance, round-trip, invalid input |
| URI | Key URI Format | parse variants + serialize→parse round-trip |
| URI validation | — | malformed secret/digits/period/counter/algorithm + HOTP missing-counter → FormatException; valid algorithm + stable id (16 tests) |

> The test vectors were taken from the RFC appendices and the engine was verified
> by **running** against them (not by rote). If the vectors change or the engine breaks, the tests fail.

## Important implementation notes

- The `crypto` package is imported **with the `as crypto` prefix**: the package's top-level
  `sha1`/`sha256`/`sha512` constants collide by name with the `OtpAlgorithm` enum values.
- `OtpAccount` is a pure value object; the `secretBytes` getter decodes the Base32.
- `OtpAccount` carries a stable **uuid v4 `id`** per instance (assigned at construction if not provided).
  The `id` is a local identity; it is **not carried** in the `otpauth://` URI (a round-trip produces a new id).
  The vault works id-based (`VaultCubit.removeById`/`incrementCounter(id)`, `OtpCard`
  `ValueKey(id)`) → the wrong item is not touched on a list change; idempotent for the Phase 3 backfill.
- The vault is **device-persistent**. **In Phase 2 it became E2E-encrypted:** `EncryptedVaultRepository`
  encrypts the tokens with `masterKey` + XChaCha20-Poly1305 (`vault_encrypted_v1`,
  a per-token record). The `VaultRepository` interface was preserved (`save` is the same; `load` now
  returns a `VaultLoadResult`, and `purgeCorrupted` was added). The Phase 1 plaintext
  (`vault_accounts_v1`) is encrypted and deleted via a one-time `VaultMigration`. Details:
  [CRYPTO.md](CRYPTO.md). `VaultCubit` runs `load()` at startup and persists on every mutation.
  **Validation is at a SINGLE point** (`OtpAccount` ctor → `validate()`): `otpauth://` parsing,
  JSON loading, and programmatic construction all pass through it → an invalid secret/digits/period
  does not crash late during card render; it becomes a `FormatException` at the source.
