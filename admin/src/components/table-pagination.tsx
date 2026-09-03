import Link from 'next/link'

import { Button } from '@/components/ui/button'

interface TablePaginationProps {
  /** 1-based current page, already clamped by `parsePage`. */
  page: number
  /** `count: 'exact'` from PostgREST; `null` when the count header was absent. */
  total: number | null
  pageCount: number
  /** From `hasNextPage()` — not `page < pageCount`, which is wrong when `total` is null. */
  hasNext: boolean
  /**
   * Href for a given page. A function rather than a base path so pages that carry
   * filters (`/audit`) can keep them in the link; filter-less tables pass
   * `(p) => pageHref('/catalog', p)`.
   */
  hrefForPage: (page: number) => string
}

/**
 * Prev/next links shared by every paged table. Rendered as links (not buttons)
 * so the page stays shareable and works without JavaScript.
 *
 * A server component: `hrefForPage` is a plain function called during render and
 * never crosses a client boundary, so it does not need to be serialisable.
 */
export function TablePagination({
  page,
  total,
  pageCount,
  hasNext,
  hrefForPage,
}: TablePaginationProps) {
  const hasPrev = page > 1

  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <p className="text-muted-foreground text-sm" aria-live="polite">
        {total === null ? `Sayfa ${page}` : `Sayfa ${page} / ${pageCount}`}
        {total === null ? '' : ` — toplam ${total} kayıt`}
      </p>

      <div className="flex items-center gap-2">
        <Button variant="outline" size="sm" asChild={hasPrev} disabled={!hasPrev}>
          {hasPrev ? (
            <Link href={hrefForPage(page - 1)} rel="prev">
              Önceki
            </Link>
          ) : (
            'Önceki'
          )}
        </Button>
        <Button variant="outline" size="sm" asChild={hasNext} disabled={!hasNext}>
          {hasNext ? (
            <Link href={hrefForPage(page + 1)} rel="next">
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
