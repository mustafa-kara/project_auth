import { z } from 'zod'

/**
 * Environment contract for the admin panel.
 *
 * Two disjoint groups, mirroring ARCHITECTURE §6:
 *  - public  : inlined into the browser bundle by Next.js (`NEXT_PUBLIC_*`).
 *  - server  : NEVER reaches the browser — the secret key and the Postgres URL.
 *
 * Validation is LAZY (`getPublicEnv()` / `getServerEnv()` are called at request
 * time, never at module scope), so `next build` succeeds without real secrets.
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

/** Rejects the legacy `eyJ…` JWT service_role key — this project uses secret keys only. */
export const serverEnvSchema = z.object({
  SUPABASE_SECRET_KEY: z.string().startsWith('sb_secret_', {
    message:
      'SUPABASE_SECRET_KEY must be a new-format secret key (sb_secret_…), not a legacy JWT service_role key',
  }),
  DATABASE_URL: z
    .string()
    .refine((v) => v.startsWith('postgres://') || v.startsWith('postgresql://'), {
      message: 'DATABASE_URL must be a postgres:// or postgresql:// connection string',
    }),
})

export type PublicEnv = z.infer<typeof publicEnvSchema>
export type ServerEnv = z.infer<typeof serverEnvSchema>

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

/**
 * Server-only env. Callers live in modules that `import 'server-only'`
 * (`lib/supabase/admin.ts`, `lib/db.ts`, `lib/audit.ts`), so this can never be
 * reached from a client component. The `typeof window` guard is belt-and-braces.
 */
export function getServerEnv(): ServerEnv {
  if (typeof window !== 'undefined') {
    throw new Error('getServerEnv() sunucu tarafına özeldir; istemciden çağrılamaz.')
  }
  const parsed = serverEnvSchema.safeParse({
    SUPABASE_SECRET_KEY: process.env.SUPABASE_SECRET_KEY,
    DATABASE_URL: process.env.DATABASE_URL,
  })
  if (!parsed.success) {
    throw new Error(`Geçersiz ortam değişkenleri (server): ${formatIssues(parsed.error)}`)
  }
  return parsed.data
}
