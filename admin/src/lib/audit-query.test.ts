import { describe, expect, it } from 'vitest'

import { AUDIT_ACTIONS } from '@/lib/audit'
import {
  AUDIT_ACTION_LABELS,
  AUDIT_PAGE_SIZE,
  AUDIT_SEARCH_MAX_LENGTH,
  auditActionLabel,
  auditActionVariant,
  auditPageCount,
  auditRange,
  buildAuditHref,
  escapeLikePattern,
  parseAuditAction,
  parseAuditPage,
  parseAuditQuery,
  parseAuditSearch,
} from '@/lib/audit-query'

describe('parseAuditPage', () => {
  it('reads a positive integer page', () => {
    expect(parseAuditPage('3')).toBe(3)
  })

  it('defaults to 1 when the param is missing or empty', () => {
    expect(parseAuditPage(undefined)).toBe(1)
    expect(parseAuditPage('')).toBe(1)
    expect(parseAuditPage('   ')).toBe(1)
  })

  it('clamps zero and negative pages to 1', () => {
    expect(parseAuditPage('0')).toBe(1)
    expect(parseAuditPage('-7')).toBe(1)
  })

  it('falls back to 1 for non-numeric and non-finite values', () => {
    expect(parseAuditPage('abc')).toBe(1)
    expect(parseAuditPage('Infinity')).toBe(1)
    expect(parseAuditPage('NaN')).toBe(1)
  })

  it('floors fractional pages', () => {
    expect(parseAuditPage('2.9')).toBe(2)
  })

  it('takes the first value of a repeated param', () => {
    expect(parseAuditPage(['4', '99'])).toBe(4)
  })
})

describe('parseAuditAction', () => {
  it('accepts every action in the AUDIT_ACTIONS union', () => {
    for (const action of AUDIT_ACTIONS) {
      expect(parseAuditAction(action)).toBe(action)
    }
  })

  it('returns undefined for an unknown action', () => {
    expect(parseAuditAction('user.promote')).toBeUndefined()
    expect(parseAuditAction('tümü')).toBeUndefined()
    expect(parseAuditAction('')).toBeUndefined()
  })

  it('returns undefined when the param is absent', () => {
    expect(parseAuditAction(undefined)).toBeUndefined()
  })

  it('whitelists rather than passes through, so injection attempts drop out', () => {
    expect(parseAuditAction('user.ban)&target=eq.x')).toBeUndefined()
  })
})

describe('parseAuditSearch', () => {
  it('trims surrounding whitespace', () => {
    expect(parseAuditSearch('  9f2c  ')).toBe('9f2c')
  })

  it('treats an empty or whitespace-only needle as no filter', () => {
    expect(parseAuditSearch('')).toBeUndefined()
    expect(parseAuditSearch('    ')).toBeUndefined()
    expect(parseAuditSearch(undefined)).toBeUndefined()
  })

  it('caps the needle at AUDIT_SEARCH_MAX_LENGTH characters', () => {
    const long = 'a'.repeat(AUDIT_SEARCH_MAX_LENGTH + 40)
    expect(parseAuditSearch(long)).toHaveLength(AUDIT_SEARCH_MAX_LENGTH)
  })

  it('trims before capping', () => {
    const padded = `   ${'b'.repeat(10)}   `
    expect(parseAuditSearch(padded)).toBe('b'.repeat(10))
  })
})

describe('parseAuditQuery', () => {
  it('parses all three params together', () => {
    expect(parseAuditQuery({ page: '2', action: 'user.ban', q: ' abc ' })).toEqual({
      page: 2,
      action: 'user.ban',
      q: 'abc',
    })
  })

  it('yields page 1 with no filters for an empty search-param object', () => {
    expect(parseAuditQuery({})).toEqual({ page: 1, action: undefined, q: undefined })
    expect(parseAuditQuery()).toEqual({ page: 1, action: undefined, q: undefined })
  })

  it('drops an unknown action but keeps a valid page and needle', () => {
    expect(parseAuditQuery({ page: '5', action: 'nope', q: 'x' })).toEqual({
      page: 5,
      action: undefined,
      q: 'x',
    })
  })
})

describe('auditRange', () => {
  it('maps page 1 to the inclusive range 0…49', () => {
    expect(auditRange(1)).toEqual({ from: 0, to: 49 })
  })

  it('maps page 2 to 50…99 with no gap or overlap against page 1', () => {
    expect(auditRange(2)).toEqual({ from: 50, to: 99 })
    expect(auditRange(2).from).toBe(auditRange(1).to + 1)
  })

  it('spans exactly AUDIT_PAGE_SIZE rows (range is inclusive)', () => {
    const { from, to } = auditRange(7)
    expect(to - from + 1).toBe(AUDIT_PAGE_SIZE)
  })

  it('clamps out-of-bounds pages to the first page', () => {
    expect(auditRange(0)).toEqual({ from: 0, to: 49 })
    expect(auditRange(-4)).toEqual({ from: 0, to: 49 })
  })

  it('honours a custom page size', () => {
    expect(auditRange(3, 10)).toEqual({ from: 20, to: 29 })
  })
})

describe('auditPageCount', () => {
  it('reports 1 page for an empty table', () => {
    expect(auditPageCount(0)).toBe(1)
  })

  it('rounds a partial last page up', () => {
    expect(auditPageCount(51)).toBe(2)
    expect(auditPageCount(100)).toBe(2)
    expect(auditPageCount(101)).toBe(3)
  })

  it('never returns less than 1 for a bogus count', () => {
    expect(auditPageCount(-5)).toBe(1)
    expect(auditPageCount(Number.NaN)).toBe(1)
  })
})

describe('escapeLikePattern', () => {
  it('leaves an ordinary needle untouched', () => {
    expect(escapeLikePattern('9f2c-4d')).toBe('9f2c-4d')
  })

  it('escapes LIKE wildcards so they match literally', () => {
    expect(escapeLikePattern('100%')).toBe('100\\%')
    expect(escapeLikePattern('feature_flag')).toBe('feature\\_flag')
  })

  it('doubles a literal backslash before adding its own escapes', () => {
    expect(escapeLikePattern('a\\b')).toBe('a\\\\b')
    expect(escapeLikePattern('a\\%')).toBe('a\\\\\\%')
  })

  it('drops "*", which PostgREST rewrites to "%" before PostgreSQL sees it', () => {
    expect(escapeLikePattern('*')).toBe('')
    expect(escapeLikePattern('a*b')).toBe('ab')
  })
})

describe('buildAuditHref', () => {
  it('omits every default', () => {
    expect(buildAuditHref({})).toBe('/audit')
    expect(buildAuditHref({ page: 1 })).toBe('/audit')
  })

  it('emits the filters that are set, with page last', () => {
    expect(buildAuditHref({ page: 3, action: 'flag.update', q: 'beta' })).toBe(
      '/audit?action=flag.update&q=beta&page=3',
    )
  })

  it('url-encodes the needle', () => {
    expect(buildAuditHref({ q: 'a b&c' })).toBe('/audit?q=a+b%26c')
  })
})

describe('action presentation', () => {
  it('labels every action in the union', () => {
    for (const action of AUDIT_ACTIONS) {
      expect(AUDIT_ACTION_LABELS[action]).toBeTruthy()
      expect(auditActionLabel(action)).toBe(AUDIT_ACTION_LABELS[action])
    }
  })

  it('falls back to the raw value for an action this build does not know', () => {
    expect(auditActionLabel('user.promote')).toBe('user.promote')
    expect(auditActionVariant('user.promote')).toBe('outline')
  })

  it('marks destructive actions and leaves the rest secondary', () => {
    expect(auditActionVariant('user.delete')).toBe('destructive')
    expect(auditActionVariant('user.ban')).toBe('destructive')
    expect(auditActionVariant('flag.update')).toBe('secondary')
    expect(auditActionVariant('user.unban')).toBe('secondary')
  })
})
