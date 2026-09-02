import { describe, expect, it } from 'vitest'

import {
  catalogInputSchema,
  isHttpsUrl,
  ISSUER_MAX_LENGTH,
  LOGO_URL_MAX_LENGTH,
  mapCatalogRow,
  mapCatalogRows,
  NAME_MAX_LENGTH,
} from '@/lib/catalog'

describe('catalogInputSchema', () => {
  it('accepts a full row and trims', () => {
    expect(
      catalogInputSchema.parse({
        name: '  GitHub  ',
        issuer: '  github.com  ',
        logo_url: '  https://cdn.example.com/github.png  ',
      }),
    ).toEqual({
      name: 'GitHub',
      issuer: 'github.com',
      logo_url: 'https://cdn.example.com/github.png',
    })
  })

  it('turns empty optional fields into null', () => {
    expect(catalogInputSchema.parse({ name: 'GitHub', issuer: '', logo_url: '   ' })).toEqual({
      name: 'GitHub',
      issuer: null,
      logo_url: null,
    })
    expect(catalogInputSchema.parse({ name: 'GitHub' })).toEqual({
      name: 'GitHub',
      issuer: null,
      logo_url: null,
    })
  })

  it('rejects an empty or whitespace-only name', () => {
    expect(catalogInputSchema.safeParse({ name: '' }).success).toBe(false)
    expect(catalogInputSchema.safeParse({ name: '   ' }).success).toBe(false)
  })

  it('enforces the length caps at the boundary', () => {
    expect(catalogInputSchema.safeParse({ name: 'a'.repeat(NAME_MAX_LENGTH) }).success).toBe(true)
    expect(catalogInputSchema.safeParse({ name: 'a'.repeat(NAME_MAX_LENGTH + 1) }).success).toBe(
      false,
    )
    expect(
      catalogInputSchema.safeParse({ name: 'a', issuer: 'i'.repeat(ISSUER_MAX_LENGTH + 1) }).success,
    ).toBe(false)
    expect(
      catalogInputSchema.safeParse({
        name: 'a',
        logo_url: `https://e.com/${'p'.repeat(LOGO_URL_MAX_LENGTH)}`,
      }).success,
    ).toBe(false)
  })

  it('accepts only absolute https logo URLs', () => {
    expect(
      catalogInputSchema.safeParse({ name: 'a', logo_url: 'https://e.com/x.png' }).success,
    ).toBe(true)
    for (const bad of [
      'http://e.com/x.png',
      '//e.com/x.png',
      '/logo.png',
      'e.com/x.png',
      'javascript:alert(1)',
      'data:image/png;base64,AAAA',
      'ftp://e.com/x.png',
      'https://',
    ]) {
      expect(catalogInputSchema.safeParse({ name: 'a', logo_url: bad }).success).toBe(false)
    }
  })
})

describe('isHttpsUrl', () => {
  it('accepts absolute https URLs only', () => {
    expect(isHttpsUrl('https://example.com')).toBe(true)
    expect(isHttpsUrl('https://example.com/a/b?c=d')).toBe(true)
    expect(isHttpsUrl('HTTPS://example.com')).toBe(true)
    expect(isHttpsUrl('http://example.com')).toBe(false)
    expect(isHttpsUrl('not a url')).toBe(false)
    expect(isHttpsUrl('')).toBe(false)
  })
})

describe('mapCatalogRow', () => {
  const valid = { id: 'c0000000-0000-4000-8000-000000000001', name: 'GitHub' }

  it('maps a minimal row with null optionals', () => {
    expect(mapCatalogRow(valid)).toEqual({
      id: valid.id,
      name: 'GitHub',
      issuer: null,
      logoUrl: null,
    })
  })

  it('maps snake_case logo_url to logoUrl', () => {
    expect(
      mapCatalogRow({ ...valid, issuer: 'github.com', logo_url: 'https://e.com/g.png' }),
    ).toEqual({
      id: valid.id,
      name: 'GitHub',
      issuer: 'github.com',
      logoUrl: 'https://e.com/g.png',
    })
  })

  it('quarantines rows the Flutter client would drop', () => {
    expect(mapCatalogRow({ ...valid, id: 7 })).toBeNull()
    expect(mapCatalogRow({ ...valid, id: '' })).toBeNull()
    expect(mapCatalogRow({ ...valid, name: null })).toBeNull()
    expect(mapCatalogRow(null)).toBeNull()
    expect(mapCatalogRow([valid])).toBeNull()
  })

  it('coerces non-string optionals to null instead of dropping the row', () => {
    const mapped = mapCatalogRow({ ...valid, issuer: 12, logo_url: {} })
    expect(mapped).not.toBeNull()
    expect(mapped?.issuer).toBeNull()
    expect(mapped?.logoUrl).toBeNull()
  })

  it('keeps the good rows and drops the bad ones', () => {
    expect(mapCatalogRows([valid, { id: 'x' }, { ...valid, name: 3 }])).toHaveLength(1)
    expect(mapCatalogRows('nope')).toEqual([])
  })
})
