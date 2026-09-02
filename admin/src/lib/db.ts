import 'server-only'

import postgres from 'postgres'
import { z } from 'zod'

import { getServerEnv } from '@/lib/env.server'

/**
 * Access path (a) — a DIRECT Postgres connection.
 *
 * The `private` schema is not exposed to the Data API, so `private.admin_global_stats()`
 * cannot be reached over PostgREST/`.rpc()`. It is called here, server-side, over a
 * plain Postgres connection.
 *
 * Role model (Pattern B, see `supabase/migrations/20260902120000_admin_backend_role.sql`):
 * `admin_backend` is a NOLOGIN privilege carrier; the panel connects as the
 * operator-created login role `admin_app` (`grant admin_backend to admin_app`) and
 * does `set local role admin_backend` inside the transaction. The panel NEVER
 * connects as `postgres`.
 *
 * `SET LOCAL` is transaction-scoped, so it is safe under Supavisor transaction-mode
 * pooling (port 6543) as well as session mode (5432). Prepared statements are
 * disabled because transaction mode does not support them.
 */

export const globalStatsSchema = z.object({
  total_users: z.number(),
  total_tokens: z.number(),
  total_devices: z.number(),
  generated_at: z.string(),
})

export type GlobalStats = z.infer<typeof globalStatsSchema>

/** Pure parser for `private.admin_global_stats()` output — unit-tested. */
export function parseGlobalStats(value: unknown): GlobalStats {
  const parsed = globalStatsSchema.safeParse(value)
  if (!parsed.success) {
    throw new Error(
      `admin_global_stats() beklenmeyen bir sonuç döndürdü: ${parsed.error.issues
        .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
        .join('; ')}`,
    )
  }
  return parsed.data
}

type Sql = ReturnType<typeof postgres>

/** `postgres.js` `ssl` option shape for verified TLS. */
export interface VerifiedTlsOptions {
  rejectUnauthorized: true
  ca?: string
}

/**
 * TLS options for the driver — pure so it can be unit-tested.
 *
 * `ssl: 'require'` is deliberately NOT used. In `postgres@3.4.9`
 * (`src/connection.js`) the string forms `'require' | 'allow' | 'prefer'` all set
 * `options.rejectUnauthorized = false`, i.e. the connection is encrypted but the
 * server certificate is never validated — libpq `sslmode=require` semantics, which
 * a network-position attacker can terminate to capture the `admin_app` password
 * from the startup packet. The object form is the supported escape hatch
 * (`else if (typeof ssl === 'object') Object.assign(options, ssl)`).
 *
 * `ca` is optional in the type only. The Supavisor pooler presents a chain rooted
 * at Supabase's own private "Supabase Root 2021 CA", which is NOT in any public
 * trust store, so in production `SUPABASE_CA_CERT` must be set or the handshake
 * fails closed with `self-signed certificate in certificate chain`. See
 * admin/README.md §5 note 5 for the verification and the download location.
 */
export function buildSslOptions(ca: string | undefined): VerifiedTlsOptions {
  return { rejectUnauthorized: true, ...(ca ? { ca } : {}) }
}

// Memoised across HMR reloads so dev does not exhaust the pooler.
const globalForSql = globalThis as unknown as { __adminSql?: Sql }

function getSql(): Sql {
  if (!globalForSql.__adminSql) {
    const { DATABASE_URL, SUPABASE_CA_CERT } = getServerEnv()
    globalForSql.__adminSql = postgres(DATABASE_URL, {
      // Supavisor transaction mode (6543) does not support prepared statements.
      prepare: false,
      max: 2,
      idle_timeout: 20,
      connect_timeout: 10,
      ssl: buildSslOptions(SUPABASE_CA_CERT),
    })
  }
  return globalForSql.__adminSql
}

/**
 * `begin; set local role admin_backend; select private.admin_global_stats(); commit`
 *
 * Returns only aggregates/metadata — never rows, never `tokens.ciphertext`.
 */
export async function getGlobalStats(): Promise<GlobalStats> {
  const sql = getSql()

  const rows = await sql.begin(async (tx) => {
    await tx`set local role admin_backend`
    return tx<{ stats: unknown }[]>`select private.admin_global_stats() as stats`
  })

  const first = (rows as unknown as { stats: unknown }[])[0]
  if (!first) {
    throw new Error('admin_global_stats() satır döndürmedi.')
  }
  return parseGlobalStats(first.stats)
}
