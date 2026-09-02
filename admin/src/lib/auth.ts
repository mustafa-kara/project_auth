import { redirect } from 'next/navigation'

import { ADMIN_REVOKED_MESSAGE, ForbiddenError } from '@/lib/forbidden'
import { createAdminClient } from '@/lib/supabase/admin'
import { createClient } from '@/lib/supabase/server'

// Re-exported so every server-side caller keeps importing the guard and its error
// from one place; the definitions live in `@/lib/forbidden` because this module
// pulls in the `server-only` secret-key client and the error boundary is a client
// component.
export { ADMIN_REVOKED_MESSAGE, FORBIDDEN_DIGEST, ForbiddenError } from '@/lib/forbidden'

export interface AdminIdentity {
  userId: string
  email: string | null
}

/**
 * Pure predicate over verified JWT claims.
 *
 * The `admin` claim is injected by `public.custom_access_token_hook`
 * (see `supabase/migrations/20260606152227_init_authenticator.sql`), which reads
 * `public.admin_users`. Only a literal boolean `true` counts — never `'true'`,
 * never truthiness.
 */
export function isAdminClaims(claims: unknown): boolean {
  if (typeof claims !== 'object' || claims === null) return false
  const appMetadata = (claims as { app_metadata?: unknown }).app_metadata
  if (typeof appMetadata !== 'object' || appMetadata === null) return false
  return (appMetadata as { admin?: unknown }).admin === true
}

/**
 * Guard for server components, server actions and route handlers.
 *
 * Uses `auth.getClaims()`, which verifies the access token's signature against the
 * project's JWKS (`/auth/v1/.well-known/jwks.json`) — the project uses asymmetric
 * signing keys, so verification is local. `getSession()` is NOT trustworthy here
 * (cookies are a shared storage medium) and `getUser()` costs a network round trip
 * without verifying the claim we actually need.
 *
 * - no/invalid session  → `redirect('/login')`
 * - session without the admin claim → `ForbiddenError`
 * - claim present but the `admin_users` row is gone / unreadable → `ForbiddenError`
 *
 * Never rely on `src/proxy.ts` alone: Server Functions are POSTs to the page route
 * and a matcher change can silently drop proxy coverage, so every privileged
 * operation re-checks here.
 */
export async function requireAdmin(): Promise<AdminIdentity> {
  const supabase = await createClient()
  const { data, error } = await supabase.auth.getClaims()

  if (error || !data?.claims) {
    redirect('/login')
  }

  const claims = data.claims
  // Cheap reject first: a non-admin token never costs a database round trip.
  if (!isAdminClaims(claims)) {
    throw new ForbiddenError()
  }

  const userId = typeof claims.sub === 'string' ? claims.sub : null
  if (!userId) {
    // An admin claim with no subject is not a session we can attribute an audit
    // row to, so it is refused rather than sent back through the login flow.
    throw new ForbiddenError('Oturum kimliği okunamadı.')
  }

  await assertStillAdmin(userId)

  return {
    userId,
    email: typeof claims.email === 'string' ? claims.email : null,
  }
}

/**
 * Freshness check — the answer to "revoke this person's admin, now".
 *
 * `app_metadata.admin` is baked into the access token at issue time by
 * `public.custom_access_token_hook`, so deleting the `public.admin_users` row does
 * **not** invalidate an already-issued token: without this lookup a demoted admin
 * keeps full panel powers (including the cascading `auth.admin.deleteUser`) until
 * the token expires and the refresh flow re-runs the hook.
 *
 * Cost: one indexed primary-key lookup on `public.admin_users` per `requireAdmin()`
 * call — i.e. per dashboard request, since the `(dashboard)` layout, every page and
 * every server action call it. That is the deliberate trade (README §6.12).
 *
 * FAIL CLOSED: a read error is treated exactly like a missing row. The alternative
 * — letting a database blip re-open the panel to a demoted admin — is the failure
 * mode this check exists to remove.
 */
async function assertStillAdmin(userId: string): Promise<void> {
  const supabase = createAdminClient()
  const { data, error } = await supabase
    .from('admin_users')
    .select('user_id')
    .eq('user_id', userId)
    .maybeSingle()

  if (error) {
    console.error('[auth] admin_users freshness check failed', error)
    throw new ForbiddenError(ADMIN_REVOKED_MESSAGE)
  }
  if (!data) {
    throw new ForbiddenError(ADMIN_REVOKED_MESSAGE)
  }
}
