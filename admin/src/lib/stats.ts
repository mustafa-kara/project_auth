import 'server-only'

import { getGlobalStats, type GlobalStats } from '@/lib/db'
import { summariseError } from '@/lib/users'

/**
 * Access path (a) wrapper for the dashboard.
 *
 * `getGlobalStats()` reaches Postgres directly and can fail for reasons that are
 * entirely operational (no `DATABASE_URL`, the `admin_app` login role not created
 * yet, `admin_backend` not granted, the pooler unreachable). None of those should
 * take the authenticated shell down with them, so the failure is turned into a
 * value the dashboard renders as an error card.
 */
export type GlobalStatsResult =
  | { ok: true; stats: GlobalStats }
  | { ok: false; message: string }

export async function loadGlobalStats(): Promise<GlobalStatsResult> {
  try {
    return { ok: true, stats: await getGlobalStats() }
  } catch (error) {
    return { ok: false, message: summariseError(error) }
  }
}
