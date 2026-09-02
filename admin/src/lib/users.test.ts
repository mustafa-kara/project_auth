import { describe, expect, it } from 'vitest'

import {
  BAN_DURATION_FOREVER,
  BAN_DURATION_NONE,
  buildUsersPage,
  checkUserActionAllowed,
  describeActionError,
  deriveProviders,
  deriveStatus,
  filterRowsByEmail,
  formatDateTime,
  mapUserRow,
  parsePageParam,
  shortId,
  summariseError,
  type AdminUserRow,
  type RawAuthUser,
} from '@/lib/users'

const NOW = new Date('2026-09-02T12:00:00Z')
const ACTOR = '00000000-0000-4000-8000-00000000aaaa'
const OTHER = '00000000-0000-4000-8000-00000000bbbb'
const ADMIN = '00000000-0000-4000-8000-00000000cccc'

function row(overrides: Partial<AdminUserRow> = {}): AdminUserRow {
  return {
    id: OTHER,
    email: 'kullanici@ornek.com',
    createdAt: '2026-01-01T00:00:00Z',
    lastSignInAt: null,
    providers: ['email'],
    status: 'active',
    bannedUntil: null,
    isAdmin: false,
    isSelf: false,
    ...overrides,
  }
}

describe('deriveStatus', () => {
  it('treats a missing banned_until as active', () => {
    expect(deriveStatus(undefined, NOW)).toEqual({ status: 'active', bannedUntil: null })
    expect(deriveStatus(null, NOW)).toEqual({ status: 'active', bannedUntil: null })
    expect(deriveStatus('', NOW)).toEqual({ status: 'active', bannedUntil: null })
  })

  it('marks a future banned_until as banned and keeps the instant', () => {
    const until = '2126-09-02T12:00:00Z'
    expect(deriveStatus(until, NOW)).toEqual({ status: 'banned', bannedUntil: until })
  })

  it('treats an expired ban as active (banned_until is a timestamp, not a flag)', () => {
    expect(deriveStatus('2026-09-02T11:59:59Z', NOW)).toEqual({
      status: 'active',
      bannedUntil: null,
    })
  })

  it('treats the exact current instant as no longer banned', () => {
    expect(deriveStatus('2026-09-02T12:00:00Z', NOW).status).toBe('active')
  })

  it('falls back to active on an unparsable value', () => {
    expect(deriveStatus('yakında', NOW)).toEqual({ status: 'active', bannedUntil: null })
  })
})

describe('deriveProviders', () => {
  it('prefers the providers array and folds in the single provider without duplicates', () => {
    expect(deriveProviders({ provider: 'email', providers: ['email', 'google'] })).toEqual([
      'email',
      'google',
    ])
  })

  it('falls back to the single provider', () => {
    expect(deriveProviders({ provider: 'apple' })).toEqual(['apple'])
  })

  it('returns an empty list for missing metadata', () => {
    expect(deriveProviders(null)).toEqual([])
    expect(deriveProviders(undefined)).toEqual([])
    expect(deriveProviders({})).toEqual([])
  })
})

describe('mapUserRow', () => {
  const user: RawAuthUser = {
    id: OTHER,
    email: 'kullanici@ornek.com',
    created_at: '2026-01-01T09:00:00Z',
    last_sign_in_at: '2026-08-30T18:30:00Z',
    banned_until: '2126-01-01T00:00:00Z',
    app_metadata: { provider: 'email', providers: ['email'] },
  }

  it('maps the listUsers user shape to a table row', () => {
    expect(
      mapUserRow(user, { adminIds: new Set<string>(), actorId: ACTOR, now: NOW }),
    ).toEqual({
      id: OTHER,
      email: 'kullanici@ornek.com',
      createdAt: '2026-01-01T09:00:00Z',
      lastSignInAt: '2026-08-30T18:30:00Z',
      providers: ['email'],
      status: 'banned',
      bannedUntil: '2126-01-01T00:00:00Z',
      isAdmin: false,
      isSelf: false,
    })
  })

  it('flags admin membership and the acting admin', () => {
    const mapped = mapUserRow(
      { id: ACTOR, email: 'yonetici@ornek.com' },
      { adminIds: new Set([ACTOR]), actorId: ACTOR, now: NOW },
    )

    expect(mapped.isAdmin).toBe(true)
    expect(mapped.isSelf).toBe(true)
    expect(mapped.status).toBe('active')
    expect(mapped.createdAt).toBeNull()
    expect(mapped.lastSignInAt).toBeNull()
  })
})

describe('buildUsersPage', () => {
  it('carries nextPage / lastPage / total through from the SDK response', () => {
    const page = buildUsersPage(
      {
        users: [{ id: OTHER, email: 'a@b.com' }],
        nextPage: 3,
        lastPage: 7,
        total: 312,
      },
      2,
      { adminIds: new Set<string>(), actorId: ACTOR, now: NOW },
    )

    expect(page.page).toBe(2)
    expect(page.nextPage).toBe(3)
    expect(page.lastPage).toBe(7)
    expect(page.total).toBe(312)
    expect(page.rows).toHaveLength(1)
    expect(page.rows[0]?.email).toBe('a@b.com')
  })

  it('degrades safely when pagination headers are absent (last page)', () => {
    const page = buildUsersPage({ users: [] }, 4, {
      adminIds: new Set<string>(),
      actorId: ACTOR,
      now: NOW,
    })

    expect(page).toEqual({ rows: [], page: 4, nextPage: null, lastPage: 4, total: 0 })
  })
})

describe('filterRowsByEmail', () => {
  const rows = [
    row({ id: '1', email: 'Ali@Ornek.com' }),
    row({ id: '2', email: 'veli@ornek.com' }),
    row({ id: '3', email: null }),
  ]

  it('returns every row for an empty or whitespace query', () => {
    expect(filterRowsByEmail(rows, '')).toHaveLength(3)
    expect(filterRowsByEmail(rows, '   ')).toHaveLength(3)
  })

  it('matches a case-insensitive substring', () => {
    expect(filterRowsByEmail(rows, 'ornek.com').map((r) => r.id)).toEqual(['1', '2'])
    expect(filterRowsByEmail(rows, 'VELI').map((r) => r.id)).toEqual(['2'])
  })

  it('folds case invariantly, not with Turkish rules (ALI must match ali@…)', () => {
    // 'ALI'.toLocaleLowerCase('tr-TR') === 'alı' — dotless, and would match nothing.
    expect(filterRowsByEmail(rows, 'ALI').map((r) => r.id)).toEqual(['1'])
    expect(filterRowsByEmail(rows, 'Ali@Ornek').map((r) => r.id)).toEqual(['1'])
  })

  it('never matches a row without an email and returns a copy', () => {
    expect(filterRowsByEmail(rows, 'a')).not.toContain(rows[2])
    expect(filterRowsByEmail(rows, '')).not.toBe(rows)
  })
})

describe('parsePageParam', () => {
  it('defaults to page 1 for missing, junk or out-of-range values', () => {
    expect(parsePageParam(undefined)).toBe(1)
    expect(parsePageParam('abc')).toBe(1)
    expect(parsePageParam('0')).toBe(1)
    expect(parsePageParam('-4')).toBe(1)
  })

  it('parses a positive page and takes the first value of a repeated param', () => {
    expect(parsePageParam('5')).toBe(5)
    expect(parsePageParam(['3', '9'])).toBe(3)
  })
})

describe('checkUserActionAllowed', () => {
  const adminIds = new Set([ACTOR, ADMIN])

  it('allows acting on an ordinary user', () => {
    expect(checkUserActionAllowed({ actorId: ACTOR, targetId: OTHER, adminIds })).toEqual({
      allowed: true,
    })
  })

  it('refuses acting on yourself', () => {
    const verdict = checkUserActionAllowed({ actorId: ACTOR, targetId: ACTOR, adminIds })

    expect(verdict.allowed).toBe(false)
    expect(verdict.allowed === false && verdict.message).toMatch(/Kendi hesabınız/)
  })

  it('refuses acting on another admin and points at SQL', () => {
    const verdict = checkUserActionAllowed({ actorId: ACTOR, targetId: ADMIN, adminIds })

    expect(verdict.allowed).toBe(false)
    expect(verdict.allowed === false && verdict.message).toMatch(/admin_users/)
  })

  it('checks self first, so an empty admin set still protects the actor', () => {
    const verdict = checkUserActionAllowed({
      actorId: ACTOR,
      targetId: ACTOR,
      adminIds: new Set<string>(),
    })

    expect(verdict.allowed).toBe(false)
  })
})

describe('summariseError / describeActionError', () => {
  it('summarises an Error as name: message', () => {
    expect(summariseError(new TypeError('fetch failed'))).toBe('TypeError: fetch failed')
  })

  it('summarises a Supabase error object without a name', () => {
    expect(summariseError({ message: 'User not found' })).toBe('User not found')
  })

  it('redacts anything shaped like a secret key or a connection string', () => {
    expect(summariseError({ message: 'bad key sb_secret_abc.DEF-123 used' })).toContain(
      'sb_secret_***',
    )
    expect(
      summariseError({ message: 'connect postgresql://admin_app:hunter2@db.host:5432/postgres' }),
    ).toBe('connect postgres://***')
  })

  it('never leaks an unknown throwable', () => {
    expect(summariseError(null)).toBe('bilinmeyen hata')
    expect(summariseError(42)).toBe('bilinmeyen hata')
  })

  it('prefixes the failed intent in Turkish', () => {
    expect(describeActionError('ban', new Error('boom'))).toBe(
      'Kullanıcı yasaklanamadı: Error: boom',
    )
    expect(describeActionError('delete', { message: 'nope' })).toBe(
      'Kullanıcı silinemedi: nope',
    )
  })
})

describe('ban duration constants', () => {
  it('matches the Go duration contract of updateUserById', () => {
    // `AdminUserAttributes.ban_duration?: string | 'none'` — 'none' lifts the ban.
    expect(BAN_DURATION_FOREVER).toBe('876600h')
    expect(BAN_DURATION_NONE).toBe('none')
  })
})

describe('formatDateTime / shortId', () => {
  it('formats an ISO instant in a fixed zone so SSR and hydration agree', () => {
    // 2026-09-02T12:00:00Z is 15:00 in Europe/Istanbul (UTC+3).
    expect(formatDateTime('2026-09-02T12:00:00Z')).toContain('15:00')
  })

  it('renders an em dash for missing or unparsable values', () => {
    expect(formatDateTime(null)).toBe('—')
    expect(formatDateTime(undefined)).toBe('—')
    expect(formatDateTime('not-a-date')).toBe('—')
  })

  it('shortens a uuid to its first block', () => {
    expect(shortId('11111111-2222-4333-8444-555555555555')).toBe('11111111…')
    expect(shortId('short')).toBe('short')
    expect(shortId(null)).toBe('—')
  })
})
