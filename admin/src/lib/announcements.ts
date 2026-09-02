import { z } from 'zod'

/**
 * `public.announcements` — pure schema + row-mapping layer.
 *
 * No I/O here on purpose: reads happen in the page (access path (c), the admin's
 * own session) and writes in the route's server actions (path (b), secret key).
 * This module only decides what a *valid* row looks like, so it stays unit-testable.
 *
 * ## Client contract (do not widen without changing the Flutter app)
 * `lib/features/account/domain/announcements_repository.dart` filters `audience`
 * **client-side**, lowercased, and keeps a row only when it is `all`, `flutter`, or
 * the running platform (`android` / `ios`). Any other value silently hides the
 * announcement on every device, so the panel refuses to write one.
 */

export const ANNOUNCEMENT_AUDIENCES = ['all', 'flutter', 'android', 'ios'] as const

export type AnnouncementAudience = (typeof ANNOUNCEMENT_AUDIENCES)[number]

export const AUDIENCE_LABELS: Record<AnnouncementAudience, string> = {
  all: 'Herkes',
  flutter: 'Tüm Flutter istemcileri',
  android: 'Android',
  ios: 'iOS',
}

export const TITLE_MAX_LENGTH = 120
export const BODY_MAX_LENGTH = 4000

/** Form input (server action). Trims first, so "   " is rejected as empty. */
export const announcementInputSchema = z.object({
  title: z
    .string({ message: 'Başlık zorunludur.' })
    .trim()
    .min(1, { message: 'Başlık boş olamaz.' })
    .max(TITLE_MAX_LENGTH, {
      message: `Başlık en fazla ${TITLE_MAX_LENGTH} karakter olabilir.`,
    }),
  body: z
    .string({ message: 'Metin zorunludur.' })
    .trim()
    .min(1, { message: 'Metin boş olamaz.' })
    .max(BODY_MAX_LENGTH, {
      message: `Metin en fazla ${BODY_MAX_LENGTH} karakter olabilir.`,
    }),
  audience: z.enum(ANNOUNCEMENT_AUDIENCES, {
    message: 'Hedef kitle all, flutter, android veya ios olmalıdır.',
  }),
})

export type AnnouncementInput = z.infer<typeof announcementInputSchema>

/** A row as the panel renders it. `createdAt` stays an ISO string (server → client safe). */
export interface Announcement {
  id: string
  title: string
  body: string
  audience: string
  createdAt: string
}

export function isKnownAudience(value: string): value is AnnouncementAudience {
  return (ANNOUNCEMENT_AUDIENCES as readonly string[]).includes(value)
}

/**
 * PostgREST row → view model, or `null` when the row is malformed.
 *
 * Mirrors the Flutter repository's "quarantine the bad row, keep the good ones"
 * behaviour rather than throwing and blanking the whole table. `audience` falls
 * back to `all` exactly like `Announcement.fromJson` does on the client.
 */
export function mapAnnouncementRow(row: unknown): Announcement | null {
  if (typeof row !== 'object' || row === null) return null
  const r = row as Record<string, unknown>

  if (typeof r.id !== 'string' || r.id.length === 0) return null
  if (typeof r.title !== 'string') return null
  if (typeof r.body !== 'string') return null
  if (typeof r.created_at !== 'string') return null
  if (Number.isNaN(Date.parse(r.created_at))) return null

  return {
    id: r.id,
    title: r.title,
    body: r.body,
    audience: typeof r.audience === 'string' ? r.audience : 'all',
    createdAt: r.created_at,
  }
}

export function mapAnnouncementRows(rows: unknown): Announcement[] {
  if (!Array.isArray(rows)) return []
  const out: Announcement[] = []
  for (const row of rows) {
    const mapped = mapAnnouncementRow(row)
    if (mapped !== null) out.push(mapped)
  }
  return out
}

const dateTimeFormat = new Intl.DateTimeFormat('tr-TR', {
  timeZone: 'UTC',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
})

/**
 * Deterministic UTC formatting. The table renders on the server and the string is
 * handed to the client as-is, so a locale/timezone-dependent format would hydrate
 * differently in the browser.
 */
export function formatDateTime(iso: string): string {
  const ms = Date.parse(iso)
  if (Number.isNaN(ms)) return '—'
  return `${dateTimeFormat.format(new Date(ms))} UTC`
}
