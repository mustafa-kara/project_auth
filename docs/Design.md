# Design System — `project_auth` (Phase 2 / Patch 4)

> This document defines the application's **visual boundaries** and design language. The Patch 4
> UI/UX redesign is implemented according to it; later phases extend these tokens, they do not
> violate them. Decided with the `/ui-ux-pro-max` + `/frontend-design` skills + research into Ente Auth / Aegis /
> 2FAS / Raivo (user-approved).

## 1. Product identity

`project_auth` — an **offline-first, E2E-encrypted, privacy-respecting** authenticator
(TOTP/HOTP/Steam). Design direction: **Precision / Technical** — dark, high-contrast,
a "terminal/precision" feel. Goal: signaling trust + technical competence. In spirit it belongs to the
Ente/Aegis family but has more character (not generic Material).

## 2. Design principles

1. **Code readability above all.** The OTP code is the screen's clearest, largest, most
   easily copied element.
2. **Color is never the only signal.** The countdown carries both color (green→amber→red) and a
   number/shape (color-not-only — color blindness safety).
3. **Security is felt through the UI, not through long text.** Lock state, verification,
   and the encrypted badge come from visual cues; technical jargon (AES/Argon2id) is not in the foreground.
4. **Offline + privacy.** Which services you use never leave the device: icons come from the
   bundle, NO runtime logo/favicon fetching.
5. **Platform respect.** Safe area, ≥44pt touch target, reduced-motion, dynamic
   type (large text) — without overflow/jitter.

## 3. Design tokens

All components use **semantic tokens**; NO raw hex inside a component. Tokens are defined in
`lib/core/ui/tokens.dart` (spacing/radius/duration + colors outside `ColorScheme` as a
`ThemeExtension`) and in `lib/core/theme/app_theme.dart`.

### 3.1 Color (dark-first, fully light-supported)

The two themes are designed **together**; contrast is verified separately in each mode. A trust-blue
primary + layered dark surfaces + semantic state colors:

| Role | Meaning |
|-----|--------|
| `primary` | Brand blue — primary action, active state, support for the counter "plentiful" tone |
| `surface` / `surfaceContainer*` | Layered dark/light surfaces (card < sheet < dialog) |
| `success` (green) | Counter plentiful (high remaining time), success feedback |
| `warning` (amber) | Counter running down |
| `error` / `destructive` (red) | Counter critical (<5s), destructive action, error |
| `onSurface` / `onSurfaceVariant` | Primary / secondary text |

- Base: `ColorScheme.fromSeed` + hand-tuned surface tones (the flat indigo
  `#3D5AFE` seed is dropped, moving to a security-blue palette).
- **Contrast target:** body text ≥ 4.5:1; OTP code targets 7:1 (both themes).

### 3.2 Typography

- **Geist** (display/heading + body) + **Geist Mono** (OTP codes, the counter, recovery
  words). Inter/Roboto are **not used** (generic — a frontend-design rule).
- Geist latin-ext → supports **Turkish glyphs** (ş/ğ/ı/İ/ç/ö/ü); confirmed before bundling.
- Code/counter styles: `Geist Mono` + `FontFeature.tabularFigures()` (fixed width →
  the layout does not shift on each tick). Code grouping: 6-digit `123 456`, 8-digit/Steam raw.
- **Fonts are embedded** (`assets/fonts/`, `pubspec.yaml fonts:`). The `google_fonts` package is
  NOT USED (runtime fetch → an offline + privacy violation).

### 3.3 Spacing / shape / elevation / motion

- **Spacing:** a 4/8dp scale (4, 8, 12, 16, 24, 32...). Section rhythm of 16/24/32.
- **Radius:** card ~16, small element ~8 (token).
- **Elevation:** a consistent scale (card < sheet < dialog); no arbitrary shadows.
- **Motion:** 150–300ms; transform/opacity only; ease-out entry, faster exit;
  respects `MediaQuery.disableAnimations`/reduced-motion (animation turns off, information remains).

## 4. Component inventory

| Component | Notes |
|---------|--------|
| `OtpCard` | Two variants: **spacious card** (default) ↔ **compact list**. The code is always visible; a single tap on the card/code = copy to clipboard + a brief confirmation (NO tap-to-reveal; the Google/Aegis default). For HOTP, a refresh icon button (next code) instead of a counter. NO separate copy icon button — the whole card is the copy target. |
| `CountdownRing` | A circular ring; value `remaining/period`; color **healthy → warning (remaining ≤33%) → critical (remaining ≤5s, ABSOLUTE — period-independent)** + **the remaining seconds in the center**. The critical threshold is `remaining`'s seconds, not its ratio → the last 5s is critical whether period=60 or period=15. <5s a slight scale-pulse (off under reduced-motion). For HOTP, a refresh action instead of the ring. |
| `IssuerAvatar` | simple-icons logo (if it matches) or **initial + a deterministic colored circle** fallback. |
| Buttons | Primary (`FilledButton`-based) + secondary/ghost. A single primary CTA per screen. |
| `AppTextField` | A visible label (not placeholder-only), inline error, helper text, password show/hide, clear on submit. |
| `AuthScaffold` | A shared skeleton for the auth flow: icon + title (headlineSmall) + description (onSurfaceVariant) + a scrollable body + a fixed bottom CTA area. Safe-area, consistent `Gap`, no dynamic-type overflow. All setup/unlock/recovery/integrity screens use it. |
| `MnemonicGrid` | The recovery key (24 words) in a **2-column × 12-row numbered grid** (left 1–12, right 13–24), GeistMono. All words are visible on a single screen (NOT a vertical list → the user cannot proceed without seeing them all). |
| `AppBanner` | Corruption warning (actionable). |
| Dialog | Destructive-action confirmation (a double-confirmed reset). |
| State views | empty / no-match / loading (skeleton) / integrity error / auth-integrity. |

## 5. Accessibility contract

- **Contrast:** body ≥ 4.5:1, secondary ≥ 3:1, OTP code targets 7:1 — verified separately in both themes.
- **Touch:** the code area and all actions ≥ 44pt; expanded with `hitSlop`/padding if needed.
- **Semantics:** the code + remaining time in a single label (`"Code 123456, 8 seconds left"`); announced
  on a material change, not every second. Accessibility labels on icon-only buttons.
- **color-not-only:** the counter state via color + number (+ <5s pulse); color alone carries no meaning.
- **reduced-motion:** animation turns off, color + number + content are preserved.
- **dynamic type:** no overflow at a large text scale (e.g. textScaler 2.0).
- **Test gate:** Semantics label + textScaler 2.0 overflow + reduced-motion widget tests are mandatory.

## 6. Boundaries — OUT OF SCOPE for Patch 4

Deliberately left to later phases (to prevent scope drift):

- **Biometric unlock** → Patch 5 (a separate mini-phase).
- **Folders / tags / favorites / sorting** → later.
- **Multi-language (l10n)** → for now texts are hardcoded in Turkish.
- **A separate AMOLED theme / Material You dynamic color** → later (Patch 4 = dark + light, both complete).
- **Advanced gestures / (home-screen) widget** → out of scope.
- **The full simple-icons set** → Patch 4 embeds only a **curated subset of common services**;
  unmatched issuers fall back to the initial.

## 7. Asset licenses (verified at the source — no blind acceptance)

- **Geist / Geist Mono** — SIL Open Font License (OFL). Before being embedded into `assets/fonts/`,
  the license + latin-ext glyph coverage is verified; attribution is kept in this file and in the font
  folder.
- **simple-icons** — CC0 (public domain). A curated SVG subset is embedded into `assets/icons/`;
  single-color → tinted with the theme color. CC0 is verified at the source; attribution in
  `assets/icons/README` + this file.
