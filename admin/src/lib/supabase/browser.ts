import { createBrowserClient } from '@supabase/ssr'

import { getPublicEnv } from '@/lib/env'

/**
 * Access path (c) — the signed-in admin's own session, publishable key only.
 * Used for sign-in/sign-out and for reading the admin-public tables + audit_logs
 * (RLS `public.is_admin()`).
 */
export function createClient() {
  const env = getPublicEnv()
  return createBrowserClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY)
}
