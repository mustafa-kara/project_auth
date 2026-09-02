import { describe, expect, it } from 'vitest'

import {
  ANNOUNCEMENT_AUDIENCES,
  announcementInputSchema,
  BODY_MAX_LENGTH,
  formatDateTime,
  isKnownAudience,
  mapAnnouncementRow,
  mapAnnouncementRows,
  TITLE_MAX_LENGTH,
} from '@/lib/announcements'

describe('announcementInputSchema', () => {
  it('accepts a well-formed announcement and trims whitespace', () => {
    const parsed = announcementInputSchema.parse({
      title: '  Bakım duyurusu  ',
      body: '  Yarın 02:00–03:00 arası bakım var.  ',
      audience: 'all',
    })

    expect(parsed).toEqual({
      title: 'Bakım duyurusu',
      body: 'Yarın 02:00–03:00 arası bakım var.',
      audience: 'all',
    })
  })

  it.each(ANNOUNCEMENT_AUDIENCES)('accepts the audience the client filters on: %s', (audience) => {
    expect(
      announcementInputSchema.parse({ title: 'a', body: 'b', audience }).audience,
    ).toBe(audience)
  })

  it('rejects an audience the Flutter client would hide on every platform', () => {
    for (const audience of ['web', 'ALL', 'All', 'desktop', '']) {
      expect(
        announcementInputSchema.safeParse({ title: 'a', body: 'b', audience }).success,
      ).toBe(false)
    }
  })

  it('rejects a whitespace-only title or body', () => {
    expect(
      announcementInputSchema.safeParse({ title: '   ', body: 'b', audience: 'all' }).success,
    ).toBe(false)
    expect(
      announcementInputSchema.safeParse({ title: 'a', body: '\n\t ', audience: 'all' }).success,
    ).toBe(false)
  })

  it('enforces the length caps at the boundary', () => {
    const audience = 'all'
    expect(
      announcementInputSchema.safeParse({
        title: 'x'.repeat(TITLE_MAX_LENGTH),
        body: 'y'.repeat(BODY_MAX_LENGTH),
        audience,
      }).success,
    ).toBe(true)
    expect(
      announcementInputSchema.safeParse({
        title: 'x'.repeat(TITLE_MAX_LENGTH + 1),
        body: 'y',
        audience,
      }).success,
    ).toBe(false)
    expect(
      announcementInputSchema.safeParse({
        title: 'x',
        body: 'y'.repeat(BODY_MAX_LENGTH + 1),
        audience,
      }).success,
    ).toBe(false)
  })

  it('rejects non-string fields', () => {
    expect(
      announcementInputSchema.safeParse({ title: 42, body: 'b', audience: 'all' }).success,
    ).toBe(false)
    expect(
      announcementInputSchema.safeParse({ title: 'a', body: null, audience: 'all' }).success,
    ).toBe(false)
  })
})

describe('isKnownAudience', () => {
  it('recognises exactly the four client-supported values', () => {
    expect(isKnownAudience('all')).toBe(true)
    expect(isKnownAudience('flutter')).toBe(true)
    expect(isKnownAudience('android')).toBe(true)
    expect(isKnownAudience('ios')).toBe(true)
    expect(isKnownAudience('web')).toBe(false)
    expect(isKnownAudience('ALL')).toBe(false)
  })
})

describe('mapAnnouncementRow', () => {
  const valid = {
    id: '9f1c2f7e-0000-4000-8000-000000000001',
    title: 'Başlık',
    body: 'Metin',
    audience: 'android',
    created_at: '2026-09-02T10:00:00+00:00',
  }

  it('maps a well-formed row', () => {
    expect(mapAnnouncementRow(valid)).toEqual({
      id: valid.id,
      title: 'Başlık',
      body: 'Metin',
      audience: 'android',
      createdAt: valid.created_at,
    })
  })

  it('falls back to "all" when audience is missing or not a string, like the client does', () => {
    expect(mapAnnouncementRow({ ...valid, audience: undefined })?.audience).toBe('all')
    expect(mapAnnouncementRow({ ...valid, audience: 7 })?.audience).toBe('all')
  })

  it('quarantines rows with a bad id, title, body or timestamp', () => {
    expect(mapAnnouncementRow({ ...valid, id: 42 })).toBeNull()
    expect(mapAnnouncementRow({ ...valid, id: '' })).toBeNull()
    expect(mapAnnouncementRow({ ...valid, title: null })).toBeNull()
    expect(mapAnnouncementRow({ ...valid, body: [] })).toBeNull()
    expect(mapAnnouncementRow({ ...valid, created_at: 'dün' })).toBeNull()
    expect(mapAnnouncementRow({ ...valid, created_at: 1234 })).toBeNull()
  })

  it('rejects non-object input', () => {
    expect(mapAnnouncementRow(null)).toBeNull()
    expect(mapAnnouncementRow('{}')).toBeNull()
    expect(mapAnnouncementRow(undefined)).toBeNull()
  })

  it('keeps the good rows and drops the bad ones', () => {
    expect(mapAnnouncementRows([valid, { ...valid, title: 1 }, { ...valid, id: 'x' }])).toHaveLength(
      2,
    )
    expect(mapAnnouncementRows(null)).toEqual([])
  })
})

describe('formatDateTime', () => {
  it('formats an ISO timestamp deterministically in UTC', () => {
    expect(formatDateTime('2026-09-02T10:05:00+00:00')).toBe('02.09.2026 10:05 UTC')
  })

  it('normalises an offset timestamp to UTC', () => {
    expect(formatDateTime('2026-09-02T13:05:00+03:00')).toBe('02.09.2026 10:05 UTC')
  })

  it('returns a dash for an unparseable value', () => {
    expect(formatDateTime('yarın')).toBe('—')
  })
})
