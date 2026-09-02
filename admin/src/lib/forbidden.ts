/**
 * The "not an admin" error, kept in its own module with **no** imports.
 *
 * `src/lib/auth.ts` reaches the secret-key client (`import 'server-only'`) for the
 * `admin_users` freshness check, so a client component — `src/app/(dashboard)/error.tsx`
 * — cannot import from it. This module is what both sides share.
 */

/**
 * Stable digest carried on every {@link ForbiddenError}.
 *
 * Next.js replaces a server error's `message` and `stack` with a generic string
 * before handing it to `error.tsx` in production, but **preserves a digest the
 * error already carries** (`next/dist/server/app-render/create-error-handler.js:79-91`:
 * "If the error already has a digest, respect the original digest"). So this is the
 * only field the error boundary can rely on in a production build.
 */
export const FORBIDDEN_DIGEST = 'ADMIN_FORBIDDEN'

/** Thrown when a valid session exists but is not (or is no longer) an admin. */
export class ForbiddenError extends Error {
  readonly name = 'ForbiddenError'

  /** Read by the `(dashboard)` error boundary; see {@link FORBIDDEN_DIGEST}. */
  readonly digest = FORBIDDEN_DIGEST

  constructor(message = 'Bu hesap yönetici değil.') {
    super(message)
  }
}

/** Shown when the JWT still says "admin" but `public.admin_users` no longer does. */
export const ADMIN_REVOKED_MESSAGE = 'Yönetici yetkiniz kaldırılmış. Yeniden giriş yapın.'
