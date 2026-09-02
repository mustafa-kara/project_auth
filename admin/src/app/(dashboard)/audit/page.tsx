import { AuditFilters } from '@/components/audit/audit-filters'
import { AuditPagination } from '@/components/audit/audit-pagination'
import { AuditTable, type AuditLogRow } from '@/components/audit/audit-table'
import { requireAdmin } from '@/lib/auth'
import {
  auditHasNextPage,
  auditPageCount,
  auditRange,
  escapeLikePattern,
  parseAuditQuery,
  type AuditSearchParams,
} from '@/lib/audit-query'
import { createClient } from '@/lib/supabase/server'

export const metadata = {
  title: 'Denetim Kaydı',
}

/** Columns selected from `public.audit_logs` — the table has no others. */
const AUDIT_COLUMNS = 'id, created_at, action, target, actor'

/**
 * Read-only view of `public.audit_logs` — access path (c).
 *
 * Uses the signed-in admin's own session, so the `admin reads audit_logs` RLS
 * policy (`for select to authenticated using (public.is_admin())`) is what
 * authorises the read. The secret-key client is deliberately NOT used here:
 * reading needs no RLS bypass, and path (b) is reserved for writes.
 *
 * This page performs no writes, so it emits no `audit_logs` row of its own.
 */
export default async function AuditPage({
  searchParams,
}: {
  searchParams: Promise<AuditSearchParams>
}) {
  // The layout already guards this route; re-checking here keeps the page correct
  // on its own, independent of proxy matcher and layout changes.
  await requireAdmin()

  const query = parseAuditQuery(await searchParams)
  const { from, to } = auditRange(query.page)

  const supabase = await createClient()

  // Filters must be applied before order/range: `.range()` returns a transform
  // builder, which no longer exposes `.eq()` / `.ilike()`.
  let filtered = supabase.from('audit_logs').select(AUDIT_COLUMNS, { count: 'exact' })
  if (query.action) {
    filtered = filtered.eq('action', query.action)
  }
  if (query.q) {
    filtered = filtered.ilike('target', `%${escapeLikePattern(query.q)}%`)
  }

  const { data, count, error } = await filtered
    // Newest first. `id` is the tiebreaker so rows sharing a `created_at` cannot
    // reappear on, or vanish between, two pages.
    .order('created_at', { ascending: false })
    .order('id', { ascending: false })
    .range(from, to)

  const rows = (data ?? []) as unknown as AuditLogRow[]
  const total = typeof count === 'number' ? count : null
  const pageCount = auditPageCount(total ?? rows.length)
  // Not `page < pageCount`: when PostgREST omits the total, `pageCount` is 1 and
  // "Sonraki" would be disabled with a full page of rows on screen.
  const hasNext = auditHasNextPage(query.page, total, rows.length)

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-semibold">Denetim Kaydı</h1>
        <p className="text-muted-foreground text-sm">
          Panelden yapılan her ayrıcalıklı işlem burada bir satır bırakır. Bu sayfa yalnızca okur;
          kendisi kayıt yazmaz.
        </p>
      </div>

      <AuditFilters query={query} />

      {error ? (
        <div
          role="alert"
          className="border-destructive/40 bg-destructive/10 text-destructive rounded-lg border p-4 text-sm"
        >
          Denetim kayıtları okunamadı: {error.message}
        </div>
      ) : (
        <>
          <AuditTable rows={rows} />
          <AuditPagination query={query} total={total} pageCount={pageCount} hasNext={hasNext} />
        </>
      )}
    </div>
  )
}
