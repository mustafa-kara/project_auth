import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

import { getPublicEnv } from '@/lib/env'

/**
 * Access path (c) — the signed-in admin's own session, read from the request
 * cookies. Publishable key only; RLS applies exactly as it does for the app.
 *
 * Use from server components, server actions and route handlers. Cookie writes
 * from a server component throw (React does not allow it) — that is expected and
 * swallowed, because `src/proxy.ts` refreshes the session cookie for every request.
 */
export async function createClient() {
  const env = getPublicEnv()
  const cookieStore = await cookies()

  return createServerClient(
    env.NEXT_PUBLIC_SUPABASE_URL,
    env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options)
            }
          } catch {
            // Called from a server component: ignore — the proxy refreshes cookies.
          }
        },
      },
    },
  )
}
