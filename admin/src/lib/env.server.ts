import 'server-only'

import { z } from 'zod'

/**
 * Server-only half of the environment contract (ARCHITECTURE §6).
 *
 * Split out of `src/lib/env.ts` so the `server-only` marker — not a runtime
 * `typeof window` guard — is what keeps these values out of a client component.
 * Next.js already replaces non-`NEXT_PUBLIC_` `process.env.X` with `undefined` in
 * client bundles, so this is defence in depth; the marker turns a silent
 * `undefined` into a build error.
 *
 * Validation stays LAZY (`getServerEnv()` is called at request time, never at
 * module scope), so `next build` succeeds with no secrets at all.
 */

const PEM_HEADER = '-----BEGIN CERTIFICATE-----'

/**
 * PEM as it survives a single-line environment variable.
 *
 * `.env` files and most hosting dashboards cannot carry a real newline, so the
 * certificate arrives with literal `\n` two-character sequences. Node's TLS stack
 * needs real newlines, hence the rewrite. Empty / whitespace-only means "not set".
 */
export function normaliseCaCert(value: string | undefined | null): string | undefined {
  if (typeof value !== 'string') return undefined
  const text = value.replace(/\\n/g, '\n').trim()
  return text.length === 0 ? undefined : text
}

const caCertSchema = z
  .string()
  .optional()
  .transform((value) => normaliseCaCert(value))
  .refine((value) => value === undefined || value.includes(PEM_HEADER), {
    message: `SUPABASE_CA_CERT must be a PEM certificate (it has to contain ${PEM_HEADER})`,
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
  /**
   * OPTIONAL. The project's Postgres CA certificate, handed to `src/lib/db.ts` for
   * `rejectUnauthorized: true`. Optional in the schema so the panel still boots and
   * builds without access path (a) — but see admin/README.md §5 note 5: the
   * Supavisor pooler chain is signed by a PRIVATE Supabase root, so in practice this
   * value is required for the dashboard's stats cards to work.
   */
  SUPABASE_CA_CERT: caCertSchema,
})

export type ServerEnv = z.infer<typeof serverEnvSchema>

function formatIssues(error: z.ZodError): string {
  return error.issues.map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`).join('; ')
}

/**
 * Server-only env. The `import 'server-only'` above is the enforcement; the
 * `typeof window` check is kept as a belt-and-braces runtime signal.
 */
export function getServerEnv(): ServerEnv {
  if (typeof window !== 'undefined') {
    throw new Error('getServerEnv() sunucu tarafına özeldir; istemciden çağrılamaz.')
  }
  const parsed = serverEnvSchema.safeParse({
    SUPABASE_SECRET_KEY: process.env.SUPABASE_SECRET_KEY,
    DATABASE_URL: process.env.DATABASE_URL,
    SUPABASE_CA_CERT: process.env.SUPABASE_CA_CERT,
  })
  if (!parsed.success) {
    throw new Error(`Geçersiz ortam değişkenleri (server): ${formatIssues(parsed.error)}`)
  }
  return parsed.data
}
