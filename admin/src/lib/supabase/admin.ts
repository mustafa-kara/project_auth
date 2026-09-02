import 'server-only'

import { createClient as createSupabaseClient, type SupabaseClient } from '@supabase/supabase-js'

import { getPublicEnv } from '@/lib/env'
import { getServerEnv } from '@/lib/env.server'

/**
 * Access path (b) — the project's SECRET key (`sb_secret_…`).
 *
 * Bypasses RLS. Used ONLY for:
 *   - `auth.admin.*` (listUsers / getUserById / updateUserById(ban_duration) / deleteUser)
 *   - service-role writes to `announcements`, `catalog_services`, `feature_flags`, `audit_logs`
 *
 * NEVER used to read `tokens` / `key_attributes` rows — see ARCHITECTURE §6.
 * Cross-user aggregate reads go through path (a), `lib/db.ts`.
 *
 * Key transport (verified against @supabase/supabase-js 2.114.0 source,
 * `dist/index.mjs` `isNewApiKey` / `fetchWithAuth`): the SDK recognises the
 * `sb_secret_` prefix, always sets the `apikey` header, and drops the
 * key-as-Bearer fallback where the platform would reject it (Edge Functions).
 * So no manual header plumbing is needed — pass the key to `createClient()`.
 */
export function createAdminClient(): SupabaseClient {
  const env = getServerEnv()
  // Via `getPublicEnv()`, not raw `process.env`: a malformed URL then fails at the
  // zod boundary with a named message instead of deep inside the SDK.
  const { NEXT_PUBLIC_SUPABASE_URL: publicUrl } = getPublicEnv()

  return createSupabaseClient(publicUrl, env.SUPABASE_SECRET_KEY, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  })
}
