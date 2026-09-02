import { describe, expect, it } from 'vitest'

import { ForbiddenError, isAdminClaims } from '@/lib/auth'

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
})
