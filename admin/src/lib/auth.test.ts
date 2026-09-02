import { beforeEach, describe, expect, it, vi } from 'vitest'

import { ADMIN_REVOKED_MESSAGE, ForbiddenError, isAdminClaims, requireAdmin } from '@/lib/auth'
import { FORBIDDEN_DIGEST } from '@/lib/forbidden'

/**
 * Both Supabase clients are mocked at the module boundary — no network, no keys.
 * `requireAdmin()` is the gate every dashboard page and every server action goes
 * through, so what is under test is its ORDER and its failure modes: claim check
 * first (cheap reject), then the `admin_users` freshness lookup, which FAILS CLOSED.
 */

const getClaims = vi.fn()
const maybeSingle = vi.fn()
const redirect = vi.fn((path: string) => {
  // The real `next/navigation` redirect() throws, and callers rely on that: the
  // code after it must never run.
  throw new Error(`NEXT_REDIRECT:${path}`)
})

vi.mock('next/navigation', () => ({ redirect: (path: string) => redirect(path) }))
vi.mock('@/lib/supabase/server', () => ({
  createClient: async () => ({ auth: { getClaims: () => getClaims() } }),
}))
vi.mock('@/lib/supabase/admin', () => ({
  createAdminClient: () => ({
    from: (table: string) => ({
      select: (columns: string) => ({
        eq: (column: string, value: string) => ({
          maybeSingle: () => maybeSingle({ table, columns, column, value }),
        }),
      }),
    }),
  }),
}))

const ADMIN_ID = '00000000-0000-4000-8000-00000000aaaa'

function adminClaims(overrides: Record<string, unknown> = {}) {
  return {
    data: {
      claims: {
        sub: ADMIN_ID,
        email: 'yonetici@ornek.com',
        app_metadata: { admin: true },
        ...overrides,
      },
    },
    error: null,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  // The fail-closed branch logs the driver error server-side; keep it out of the
  // test output without hiding that it happens.
  vi.spyOn(console, 'error').mockImplementation(() => {})
  getClaims.mockResolvedValue(adminClaims())
  maybeSingle.mockResolvedValue({ data: { user_id: ADMIN_ID }, error: null })
})

describe('isAdminClaims', () => {
  it('accepts claims with app_metadata.admin === true', () => {
    expect(isAdminClaims({ sub: 'u1', app_metadata: { admin: true } })).toBe(true)
  })

  it('rejects app_metadata.admin === false (the hook emits this for normal users)', () => {
    expect(isAdminClaims({ sub: 'u1', app_metadata: { admin: false } })).toBe(false)
  })

  it('rejects truthy non-boolean admin values', () => {
    expect(isAdminClaims({ app_metadata: { admin: 'true' } })).toBe(false)
    expect(isAdminClaims({ app_metadata: { admin: 1 } })).toBe(false)
    expect(isAdminClaims({ app_metadata: { admin: {} } })).toBe(false)
  })

  it('rejects an admin flag placed outside app_metadata', () => {
    expect(isAdminClaims({ admin: true })).toBe(false)
    expect(isAdminClaims({ user_metadata: { admin: true } })).toBe(false)
  })

  it('rejects missing / malformed claims', () => {
    expect(isAdminClaims(undefined)).toBe(false)
    expect(isAdminClaims(null)).toBe(false)
    expect(isAdminClaims('admin')).toBe(false)
    expect(isAdminClaims(42)).toBe(false)
    expect(isAdminClaims({})).toBe(false)
    expect(isAdminClaims({ app_metadata: null })).toBe(false)
    expect(isAdminClaims({ app_metadata: 'admin' })).toBe(false)
  })
})

describe('ForbiddenError', () => {
  it('is an Error with a stable name and a Turkish default message', () => {
    const error = new ForbiddenError()
    expect(error).toBeInstanceOf(Error)
    expect(error.name).toBe('ForbiddenError')
    expect(error.message).toBe('Bu hesap yönetici değil.')
  })

  it('carries the digest the (dashboard) error boundary matches on', () => {
    // Next.js strips message/stack in production but preserves a digest the error
    // already had, so this is the boundary's only reliable signal there.
    expect(new ForbiddenError().digest).toBe(FORBIDDEN_DIGEST)
    expect(new ForbiddenError(ADMIN_REVOKED_MESSAGE).digest).toBe(FORBIDDEN_DIGEST)
  })
})

describe('requireAdmin', () => {
  it('returns the identity when the claim holds AND the admin_users row is present', async () => {
    const identity = await requireAdmin()

    expect(identity).toEqual({ userId: ADMIN_ID, email: 'yonetici@ornek.com' })
    expect(maybeSingle).toHaveBeenCalledWith({
      table: 'admin_users',
      columns: 'user_id',
      column: 'user_id',
      value: ADMIN_ID,
    })
    expect(redirect).not.toHaveBeenCalled()
  })

  it('forbids when the admin_users row is gone — revocation must not wait for the token to rotate', async () => {
    maybeSingle.mockResolvedValue({ data: null, error: null })

    await expect(requireAdmin()).rejects.toThrow(ForbiddenError)
    await expect(requireAdmin()).rejects.toThrow(ADMIN_REVOKED_MESSAGE)
  })

  it('fails CLOSED when admin_users cannot be read', async () => {
    maybeSingle.mockResolvedValue({ data: null, error: { message: 'connection reset' } })

    await expect(requireAdmin()).rejects.toThrow(ForbiddenError)
  })

  it('does not touch the database when the claim is missing (cheap reject first)', async () => {
    getClaims.mockResolvedValue({
      data: { claims: { sub: ADMIN_ID, app_metadata: { admin: false } } },
      error: null,
    })

    await expect(requireAdmin()).rejects.toThrow(ForbiddenError)
    expect(maybeSingle).not.toHaveBeenCalled()
  })

  it('forbids an admin claim with no sub — an audit row has nobody to attribute', async () => {
    getClaims.mockResolvedValue({
      data: { claims: { app_metadata: { admin: true } } },
      error: null,
    })

    await expect(requireAdmin()).rejects.toThrow(ForbiddenError)
    expect(maybeSingle).not.toHaveBeenCalled()
    expect(redirect).not.toHaveBeenCalled()
  })

  it('redirects to /login when there is no session', async () => {
    getClaims.mockResolvedValue({ data: null, error: null })

    await expect(requireAdmin()).rejects.toThrow('NEXT_REDIRECT:/login')
    expect(redirect).toHaveBeenCalledWith('/login')
    expect(maybeSingle).not.toHaveBeenCalled()
  })

  it('redirects to /login when getClaims() reports an error', async () => {
    getClaims.mockResolvedValue({ data: null, error: { message: 'invalid JWT signature' } })

    await expect(requireAdmin()).rejects.toThrow('NEXT_REDIRECT:/login')
    expect(redirect).toHaveBeenCalledWith('/login')
  })

  it('leaves email null when the claim does not carry one', async () => {
    getClaims.mockResolvedValue({
      data: { claims: { sub: ADMIN_ID, app_metadata: { admin: true } } },
      error: null,
    })

    await expect(requireAdmin()).resolves.toEqual({ userId: ADMIN_ID, email: null })
  })
})
