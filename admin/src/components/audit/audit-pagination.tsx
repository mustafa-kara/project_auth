import Link from 'next/link'

import { Button } from '@/components/ui/button'
import { buildAuditHref, type AuditQuery } from '@/lib/audit-query'

interface AuditPaginationProps {
  query: AuditQuery
  /** `count: 'exact'` from PostgREST; `null` when the count header was absent. */
  total: number | null
  pageCount: number
}

/**
 * Prev/next links that preserve the active filters. Rendered as links (not
 * buttons) so the page stays shareable and works without JavaScript.
 */
export function AuditPagination({ query, total, pageCount }: AuditPaginationProps) {
  const hasPrev = query.page > 1
  const hasNext = query.page < pageCount

  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <p className="text-muted-foreground text-sm" aria-live="polite">
        Sayfa {query.page} / {pageCount}
        {total === null ? '' : ` — toplam ${total} kayıt`}
      </p>

      <div className="flex items-center gap-2">
        <Button variant="outline" size="sm" asChild={hasPrev} disabled={!hasPrev}>
          {hasPrev ? (
            <Link href={buildAuditHref({ ...query, page: query.page - 1 })} rel="prev">
              Önceki
            </Link>
          ) : (
            'Önceki'
          )}
        </Button>
        <Button variant="outline" size="sm" asChild={hasNext} disabled={!hasNext}>
          {hasNext ? (
            <Link href={buildAuditHref({ ...query, page: query.page + 1 })} rel="next">
              Sonraki
            </Link>
          ) : (
            'Sonraki'
          )}
        </Button>
      </div>
    </div>
  )
}
