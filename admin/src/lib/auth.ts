import { redirect } from 'next/navigation'

import { createClient } from '@/lib/supabase/server'

/** Thrown when a valid session exists but does not carry `app_metadata.admin === true`. */
export class ForbiddenError extends Error {
  readonly name = 'ForbiddenError'

  constructor(message = 'Bu hesap yönetici değil.') {
    super(message)
  }
}

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
  if (!isAdminClaims(claims)) {
    throw new ForbiddenError()
  }

  const userId = typeof claims.sub === 'string' ? claims.sub : null
  if (!userId) {
    redirect('/login')
  }

  return {
    userId,
    email: typeof claims.email === 'string' ? claims.email : null,
  }
}
