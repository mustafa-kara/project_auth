/**
 * Pure helpers for the user management screen.
 *
 * Deliberately free of `server-only` / SDK imports: everything here is a pure
 * function over the shapes `auth.admin.listUsers()` returns, so it is unit-tested
 * without a network or a Supabase client.
 *
 * API shapes verified against the installed package (@supabase/auth-js, bundled
 * with @supabase/supabase-js 2.114.0):
 *   - `node_modules/@supabase/auth-js/dist/module/lib/types.d.ts`
 *       `Pagination = { nextPage: number | null; lastPage: number; total: number }`
 *       `PageParams = { page?: number; perPage?: number }`
 *       `User.banned_until?: string`, `User.app_metadata: UserAppMetadata`
 *       (`provider?: string`, `providers?: string[]`)
 *       `AdminUserAttributes.ban_duration?: string | 'none'` ('none' lifts the ban)
 *   - `node_modules/@supabase/auth-js/dist/module/GoTrueAdminApi.d.ts`
 *       `listUsers(params?: PageParams)` → `{ data: { users, aud } & Pagination, error: null }`
 *                                       | `{ data: { users: [] }, error: AuthError }`
 *       `deleteUser(id, shouldSoftDelete?)`
 *
 * There is NO server-side email filter on `listUsers` — the endpoint only takes
 * `page`/`perPage`. Search is therefore page-local (`filterRowsByEmail`) and the
 * UI says so.
 */

/** ~100 years. `updateUserById(id, { ban_duration })` takes a Go duration string. */
export const BAN_DURATION_FOREVER = '876600h'
/** The literal that lifts a ban. */
export const BAN_DURATION_NONE = 'none'

/** Rows per `listUsers` page. */
export const USERS_PER_PAGE = 50

export type UserStatus = 'active' | 'banned'

/** The metadata-only projection the panel is allowed to show. Never any token data. */
export interface AdminUserRow {
  id: string
  email: string | null
  createdAt: string | null
  lastSignInAt: string | null
  providers: string[]
  status: UserStatus
  bannedUntil: string | null
  /** The row is in `public.admin_users` — cannot be banned/deleted from the panel. */
  isAdmin: boolean
  /** The row is the signed-in admin — cannot act on themselves. */
  isSelf: boolean
}

export interface UsersPage {
  rows: AdminUserRow[]
  page: number
  nextPage: number | null
  lastPage: number
  total: number
}

/** The subset of `User` this screen reads. Never `tokens` / `key_attributes`. */
export interface RawAuthUser {
  id: string
  email?: string | null
  created_at?: string | null
  last_sign_in_at?: string | null
  banned_until?: string | null
  app_metadata?: { provider?: string; providers?: string[] } | null
}

export interface RawListUsersResponse {
  users: RawAuthUser[]
  nextPage?: number | null
  lastPage?: number
  total?: number
}

/**
 * `banned_until` is a timestamp, not a flag: gotrue writes a far-future value when
 * banning and clears it (null / absent / a past instant) when `ban_duration: 'none'`
 * is applied. A ban is therefore "active" only while the instant is still ahead of us.
 */
export function deriveStatus(
  bannedUntil: string | null | undefined,
  now: Date = new Date(),
): { status: UserStatus; bannedUntil: string | null } {
  if (typeof bannedUntil !== 'string' || bannedUntil.trim() === '') {
    return { status: 'active', bannedUntil: null }
  }

  const until = Date.parse(bannedUntil)
  if (Number.isNaN(until) || until <= now.getTime()) {
    return { status: 'active', bannedUntil: null }
  }

  return { status: 'banned', bannedUntil }
}

/** `app_metadata.providers` when present, otherwise the single `provider`, deduped. */
export function deriveProviders(appMetadata: RawAuthUser['app_metadata']): string[] {
  if (!appMetadata) return []

  const list = Array.isArray(appMetadata.providers) ? appMetadata.providers : []
  const single = typeof appMetadata.provider === 'string' ? [appMetadata.provider] : []

  return Array.from(new Set([...list, ...single].filter((p) => typeof p === 'string' && p !== '')))
}

export interface MapUserOptions {
  /** `auth.users.id` values present in `public.admin_users`. */
  adminIds: ReadonlySet<string>
  /** The signed-in admin (from `requireAdmin()`, never from the request). */
  actorId: string
  now?: Date
}

export function mapUserRow(user: RawAuthUser, options: MapUserOptions): AdminUserRow {
  const { status, bannedUntil } = deriveStatus(user.banned_until, options.now ?? new Date())

  return {
    id: user.id,
    email: user.email ?? null,
    createdAt: user.created_at ?? null,
    lastSignInAt: user.last_sign_in_at ?? null,
    providers: deriveProviders(user.app_metadata),
    status,
    bannedUntil,
    isAdmin: options.adminIds.has(user.id),
    isSelf: user.id === options.actorId,
  }
}

/** `listUsers()` payload → the rows + pagination the table renders. */
export function buildUsersPage(
  response: RawListUsersResponse,
  page: number,
  options: MapUserOptions,
): UsersPage {
  return {
    rows: response.users.map((user) => mapUserRow(user, options)),
    page,
    nextPage: response.nextPage ?? null,
    lastPage: response.lastPage ?? page,
    total: response.total ?? response.users.length,
  }
}

/**
 * Page-local email filter. `listUsers` has no server-side search, so this narrows
 * only the 50 rows currently on screen — the UI states this explicitly.
 *
 * Case folding is INVARIANT (`toLowerCase`), not Turkish: `'ALI'.toLocaleLowerCase('tr-TR')`
 * is `'alı'` (dotless), which would never match the ASCII address `ali@…`.
 */
export function filterRowsByEmail(rows: readonly AdminUserRow[], query: string): AdminUserRow[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return [...rows]

  return rows.filter((row) => (row.email ?? '').toLowerCase().includes(needle))
}

/** `?page=` → a 1-based page number; anything unusable falls back to 1. */
export function parsePageParam(raw: string | string[] | undefined): number {
  const value = Array.isArray(raw) ? raw[0] : raw
  if (typeof value !== 'string') return 1

  const parsed = Number.parseInt(value, 10)
  if (!Number.isFinite(parsed) || parsed < 1) return 1

  return parsed
}

export type UserActionIntent = 'ban' | 'unban' | 'delete'

export type ActionVerdict = { allowed: true } | { allowed: false; message: string }

export interface ActionGuardInput {
  /** The signed-in admin's id — always from `requireAdmin()`. */
  actorId: string
  targetId: string
  /** Ids in `public.admin_users`, read with the secret-key client. */
  adminIds: ReadonlySet<string>
}

/**
 * The authorization rule for every destructive user action, as a pure function so
 * it can be unit-tested. The server action calls it AFTER `requireAdmin()`; the UI
 * merely mirrors it by disabling menu items.
 */
export function checkUserActionAllowed({
  actorId,
  targetId,
  adminIds,
}: ActionGuardInput): ActionVerdict {
  if (targetId === actorId) {
    return { allowed: false, message: 'Kendi hesabınız üzerinde bu işlemi yapamazsınız.' }
  }

  if (adminIds.has(targetId)) {
    return {
      allowed: false,
      message:
        'Bu kullanıcı yönetici. Yönetici yetkisi panelden kaldırılamaz; ' +
        'önce SQL ile public.admin_users satırı silinmelidir.',
    }
  }

  return { allowed: true }
}

/**
 * Supabase/network errors → a short Turkish sentence. Never echo a stack trace or
 * anything that could carry the secret key / connection string.
 */
export function describeActionError(intent: UserActionIntent, error: unknown): string {
  const labels: Record<UserActionIntent, string> = {
    ban: 'Kullanıcı yasaklanamadı',
    unban: 'Yasak kaldırılamadı',
    delete: 'Kullanıcı silinemedi',
  }

  return `${labels[intent]}: ${summariseError(error)}`
}

/** One-line, secret-free summary of an unknown throwable / Supabase error object. */
export function summariseError(error: unknown): string {
  if (error === null || error === undefined) return 'bilinmeyen hata'

  if (typeof error === 'object' && 'message' in error) {
    const message = (error as { message?: unknown }).message
    const name = (error as { name?: unknown }).name
    const text = typeof message === 'string' && message !== '' ? message : 'ayrıntı yok'
    return typeof name === 'string' && name !== '' ? `${name}: ${redact(text)}` : redact(text)
  }

  if (typeof error === 'string') return redact(error)

  return 'bilinmeyen hata'
}

/**
 * Belt and braces: even though these values should never reach an error message,
 * strip anything shaped like a secret key or a Postgres connection string before
 * it is rendered.
 */
function redact(text: string): string {
  return text
    .replace(/sb_secret_[A-Za-z0-9._-]+/g, 'sb_secret_***')
    .replace(/postgres(?:ql)?:\/\/[^\s]+/g, 'postgres://***')
}

const dateTimeFormat = new Intl.DateTimeFormat('tr-TR', {
  dateStyle: 'short',
  timeStyle: 'short',
  // Pinned so server and client renders agree (no hydration mismatch).
  timeZone: 'Europe/Istanbul',
})

/** ISO timestamp → `gg.aa.yyyy ss:dd`, or an em dash when absent/unparsable. */
export function formatDateTime(value: string | null | undefined): string {
  if (typeof value !== 'string' || value.trim() === '') return '—'

  const parsed = Date.parse(value)
  if (Number.isNaN(parsed)) return '—'

  return dateTimeFormat.format(new Date(parsed))
}

/** uuid → its first block, for dense tables. */
export function shortId(value: string | null | undefined): string {
  if (typeof value !== 'string' || value.trim() === '') return '—'
  return value.length <= 8 ? value : `${value.slice(0, 8)}…`
}
