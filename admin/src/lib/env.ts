import { z } from 'zod'

/**
 * PUBLIC half of the environment contract for the admin panel.
 *
 * Two disjoint groups, mirroring ARCHITECTURE §6:
 *  - public  : this module — inlined into the browser bundle by Next.js (`NEXT_PUBLIC_*`).
 *  - server  : `src/lib/env.server.ts` (`import 'server-only'`) — the secret key,
 *              the Postgres URL and the optional CA certificate. NEVER reaches the browser.
 *
 * Validation is LAZY (`getPublicEnv()` is called at request time, never at module
 * scope), so `next build` succeeds without real secrets.
 */

/** Rejects the legacy `eyJ…` JWT anon key — this project uses publishable keys only. */
export const publicEnvSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url({ message: 'NEXT_PUBLIC_SUPABASE_URL must be a URL' }),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z
    .string()
    .startsWith('sb_publishable_', {
      message:
        'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY must be a new-format publishable key (sb_publishable_…), not a legacy JWT anon key',
    }),
})

export type PublicEnv = z.infer<typeof publicEnvSchema>

function formatIssues(error: z.ZodError): string {
  return error.issues.map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`).join('; ')
}

/**
 * Public env — safe in both server and client components.
 * The `process.env.X` accesses are literal so Next.js can statically inline them.
 */
export function getPublicEnv(): PublicEnv {
  const parsed = publicEnvSchema.safeParse({
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  })
  if (!parsed.success) {
    throw new Error(`Geçersiz ortam değişkenleri (public): ${formatIssues(parsed.error)}`)
  }
  return parsed.data
}
