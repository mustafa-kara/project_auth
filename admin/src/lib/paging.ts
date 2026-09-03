/**
 * Offset pagination primitives shared by every paged table in the panel
 * (`/audit`, `/announcements`, `/catalog`, `/flags`).
 *
 * Deliberately free of `server-only`, Supabase and React imports: the pages are
 * server components, but every decision they make about *what* to query (page
 * clamping, `.range()` bounds, "is there a next page") is pure arithmetic and
 * lives here so it can be unit-tested without a database or a request.
 *
 * `/users` is **not** built on this module: `auth.admin.listUsers` pages through
 * the Auth admin API (`page`/`perPage`), not through PostgREST `.range()`, so it
 * keeps its own helpers in `lib/users.ts`.
 */

/** Rows per page. `.range()` is inclusive, so a page spans `from … from + 49`. */
export const DEFAULT_PAGE_SIZE = 50

/**
 * Hard ceiling on `?page=`.
 *
 * Unbounded page numbers turn into an unbounded `offset` in the PostgREST query
 * string (`?page=1e21` → `offset=5e22`), which the database answers with a 5xx
 * rather than an empty page. 10 000 pages × 50 rows = 500 000 rows, far past
 * anything worth paging through in a browser.
 */
export const MAX_PAGE = 10_000

/** A single value of a Next.js `searchParams` entry. */
export type SearchParamValue = string | string[] | undefined

/** Inclusive bounds for `PostgrestTransformBuilder.range(from, to)`. */
export interface PageRange {
  from: number
  to: number
}

/** First value of a repeated search param (`?page=2&page=9` → `'2'`). */
export function firstSearchParamValue(value: SearchParamValue): string | undefined {
  if (Array.isArray(value)) return value[0]
  return value
}

/**
 * `?page=` → a 1-based page number.
 *
 * Anything that is not a finite integer ≥ 1 (missing, `0`, `-3`, `1.5`, `abc`,
 * `Infinity`) collapses to page 1 rather than erroring: a hand-edited URL should
 * show the first page, not a 500. Anything above {@link MAX_PAGE} is clamped
 * down to it for the same reason.
 */
export function parsePage(value: SearchParamValue, maxPage: number = MAX_PAGE): number {
  const raw = firstSearchParamValue(value)
  if (typeof raw !== 'string' || raw.trim() === '') return 1

  const parsed = Number(raw)
  if (!Number.isFinite(parsed)) return 1

  const page = Math.floor(parsed)
  if (page < 1) return 1
  return page > maxPage ? maxPage : page
}

/**
 * Page number → inclusive `.range()` bounds.
 *
 * Verified against `@supabase/postgrest-js@2.114.0`
 * (`src/PostgrestTransformBuilder.ts`): `range(from, to)` sets `offset=from` and
 * `limit=to - from + 1`, i.e. `to` is inclusive.
 */
export function pageRange(page: number, pageSize: number = DEFAULT_PAGE_SIZE): PageRange {
  const safePage = page < 1 ? 1 : Math.floor(page)
  const from = (safePage - 1) * pageSize
  return { from, to: from + pageSize - 1 }
}

/** Total page count for `count: 'exact'`; always ≥ 1 so the footer reads "1 / 1". */
export function pageCount(total: number, pageSize: number = DEFAULT_PAGE_SIZE): number {
  if (!Number.isFinite(total) || total <= 0) return 1
  return Math.max(1, Math.ceil(total / pageSize))
}

/**
 * Is there a page after this one?
 *
 * With an exact `count` the page count answers it. Without one — PostgREST can omit
 * the total from `content-range` — `pageCount` collapses to 1 and "Sonraki" would
 * be disabled even though more rows exist. In that case a **full** page is the
 * signal: exactly `pageSize` rows means there is probably another page (a
 * false positive costs one empty page, a false negative hides the rest of the table).
 *
 * `rowCount` must be the number of rows PostgREST actually returned, **not** the
 * number left after client-side mapping drops malformed ones — a quarantined row
 * still occupies a slot in the page.
 */
export function hasNextPage(
  page: number,
  total: number | null,
  rowCount: number,
  pageSize: number = DEFAULT_PAGE_SIZE,
  maxPage: number = MAX_PAGE,
): boolean {
  if (page >= maxPage) return false
  if (total === null) return rowCount === pageSize
  return page < pageCount(total, pageSize)
}

/**
 * Canonical href for a page of a filter-less table. Page 1 is written without a
 * query string so the URL of the default view stays clean and shareable.
 *
 * Pages that carry filters of their own build their own href instead — see
 * `buildAuditHref` in `lib/audit-query.ts`.
 */
export function pageHref(basePath: string, page: number): string {
  return page > 1 ? `${basePath}?page=${page}` : basePath
}
