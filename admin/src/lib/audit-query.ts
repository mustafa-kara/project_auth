import { AUDIT_ACTIONS, type AuditAction } from '@/lib/audit'

/**
 * Pure search-param parsing for `/audit`.
 *
 * Deliberately free of `server-only`, Supabase and React imports: the page is a
 * server component, but every decision it makes about *what* to query (page
 * clamping, action whitelisting, search sanitising, `.range()` bounds) lives
 * here so it can be unit-tested without a database or a request.
 */

/** Rows per page. `.range()` is inclusive, so a page spans `from … from + 49`. */
export const AUDIT_PAGE_SIZE = 50

/**
 * Upper bound on `?q=`. `audit_logs.target` is a uuid / flag key / announcement
 * id — never long free text — so anything past this is noise, and capping it
 * keeps the PostgREST query string bounded.
 */
export const AUDIT_SEARCH_MAX_LENGTH = 100

/** A single value of a Next.js `searchParams` entry. */
export type SearchParamValue = string | string[] | undefined

export interface AuditSearchParams {
  page?: SearchParamValue
  action?: SearchParamValue
  q?: SearchParamValue
}

export interface AuditQuery {
  /** 1-based, always ≥ 1. */
  page: number
  /** `undefined` means "tümü" — no `action` filter is applied. */
  action?: AuditAction
  /** Already trimmed and length-capped; `undefined` means no `target` filter. */
  q?: string
}

/** Inclusive bounds for `PostgrestTransformBuilder.range(from, to)`. */
export interface AuditRange {
  from: number
  to: number
}

/** Turkish labels for the action filter and the table badge. */
export const AUDIT_ACTION_LABELS: Readonly<Record<AuditAction, string>> = {
  'user.ban': 'Kullanıcı askıya alındı',
  'user.unban': 'Kullanıcı askıdan çıkarıldı',
  'user.delete': 'Kullanıcı silindi',
  'announcement.create': 'Duyuru oluşturuldu',
  'announcement.update': 'Duyuru güncellendi',
  'announcement.delete': 'Duyuru silindi',
  'catalog.create': 'Katalog kaydı eklendi',
  'catalog.update': 'Katalog kaydı güncellendi',
  'catalog.delete': 'Katalog kaydı silindi',
  'flag.update': 'Bayrak güncellendi',
}

/** Actions whose badge is rendered as destructive (irreversible / punitive). */
const DESTRUCTIVE_ACTIONS: ReadonlySet<string> = new Set<AuditAction>([
  'user.ban',
  'user.delete',
  'announcement.delete',
  'catalog.delete',
])

/**
 * Badge variant for an action. Takes a plain `string`, not `AuditAction`: rows
 * written by an older deploy may carry an action this build does not know about,
 * and the table must still render them.
 */
export function auditActionVariant(action: string): 'secondary' | 'destructive' | 'outline' {
  if (DESTRUCTIVE_ACTIONS.has(action)) return 'destructive'
  return (AUDIT_ACTIONS as readonly string[]).includes(action) ? 'secondary' : 'outline'
}

/** Label for an action, falling back to the raw value for unknown actions. */
export function auditActionLabel(action: string): string {
  return AUDIT_ACTION_LABELS[action as AuditAction] ?? action
}

/** First value of a repeated search param (`?page=2&page=9` → `'2'`). */
function firstValue(value: SearchParamValue): string | undefined {
  if (Array.isArray(value)) return value[0]
  return value
}

/**
 * `?page=` → a 1-based page number.
 *
 * Anything that is not a finite integer ≥ 1 (missing, `0`, `-3`, `1.5`, `abc`,
 * `Infinity`) collapses to page 1 rather than erroring: a hand-edited URL should
 * show the first page, not a 500.
 */
export function parseAuditPage(value: SearchParamValue): number {
  const raw = firstValue(value)
  if (typeof raw !== 'string' || raw.trim() === '') return 1

  const parsed = Number(raw)
  if (!Number.isFinite(parsed)) return 1

  const page = Math.floor(parsed)
  return page < 1 ? 1 : page
}

/**
 * `?action=` → a member of `AUDIT_ACTIONS`, or `undefined`.
 *
 * Whitelisted against the union rather than passed through, so the value handed
 * to `.eq('action', …)` can never be attacker-chosen.
 */
export function parseAuditAction(value: SearchParamValue): AuditAction | undefined {
  const raw = firstValue(value)
  if (typeof raw !== 'string') return undefined

  return (AUDIT_ACTIONS as readonly string[]).includes(raw) ? (raw as AuditAction) : undefined
}

/** `?q=` → a trimmed, length-capped needle, or `undefined` when it is empty. */
export function parseAuditSearch(value: SearchParamValue): string | undefined {
  const raw = firstValue(value)
  if (typeof raw !== 'string') return undefined

  const trimmed = raw.trim()
  if (trimmed === '') return undefined

  return trimmed.slice(0, AUDIT_SEARCH_MAX_LENGTH)
}

/** Parses a whole `searchParams` object into the query the page will run. */
export function parseAuditQuery(params: AuditSearchParams = {}): AuditQuery {
  return {
    page: parseAuditPage(params.page),
    action: parseAuditAction(params.action),
    q: parseAuditSearch(params.q),
  }
}

/**
 * Page number → inclusive `.range()` bounds.
 *
 * Verified against `@supabase/postgrest-js@2.114.0`
 * (`src/PostgrestTransformBuilder.ts`): `range(from, to)` sets `offset=from` and
 * `limit=to - from + 1`, i.e. `to` is inclusive.
 */
export function auditRange(page: number, pageSize: number = AUDIT_PAGE_SIZE): AuditRange {
  const safePage = page < 1 ? 1 : Math.floor(page)
  const from = (safePage - 1) * pageSize
  return { from, to: from + pageSize - 1 }
}

/** Total page count for `count: 'exact'`; always ≥ 1 so the footer reads "1 / 1". */
export function auditPageCount(total: number, pageSize: number = AUDIT_PAGE_SIZE): number {
  if (!Number.isFinite(total) || total <= 0) return 1
  return Math.max(1, Math.ceil(total / pageSize))
}

/**
 * Escapes a needle for `.ilike()`.
 *
 * `postgrest-js` interpolates the pattern into the query string verbatim
 * (`url.searchParams.append(column, \`ilike.${pattern}\`)`), so LIKE
 * metacharacters in user input would otherwise act as wildcards. `%` and `_` are
 * escaped with a backslash (PostgreSQL's default LIKE escape character); `*` is
 * dropped instead, because PostgREST rewrites it to `%` before PostgreSQL ever
 * sees the pattern and therefore cannot be neutralised by escaping.
 */
export function escapeLikePattern(value: string): string {
  return value
    .replace(/\*/g, '')
    .replace(/\\/g, '\\\\')
    .replace(/%/g, '\\%')
    .replace(/_/g, '\\_')
}

/**
 * Canonical `/audit` href. Omits defaults (page 1, no filters) so the URL stays
 * clean, and always emits `page` last for readability.
 */
export function buildAuditHref(query: Partial<AuditQuery> = {}): string {
  const params = new URLSearchParams()
  if (query.action) params.set('action', query.action)
  if (query.q) params.set('q', query.q)
  if (query.page !== undefined && query.page > 1) params.set('page', String(query.page))

  const search = params.toString()
  return search === '' ? '/audit' : `/audit?${search}`
}
