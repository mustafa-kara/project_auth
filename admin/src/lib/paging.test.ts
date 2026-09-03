import { describe, expect, it } from 'vitest'

import {
  DEFAULT_PAGE_SIZE,
  MAX_PAGE,
  firstSearchParamValue,
  hasNextPage,
  pageCount,
  pageHref,
  pageRange,
  parsePage,
} from '@/lib/paging'

describe('firstSearchParamValue', () => {
  it('passes a single string through', () => {
    expect(firstSearchParamValue('2')).toBe('2')
  })

  it('takes the first entry of a repeated param', () => {
    expect(firstSearchParamValue(['2', '9'])).toBe('2')
  })

  it('returns undefined for a missing or empty param', () => {
    expect(firstSearchParamValue(undefined)).toBeUndefined()
    expect(firstSearchParamValue([])).toBeUndefined()
  })
})

describe('parsePage', () => {
  it('reads a positive integer page', () => {
    expect(parsePage('3')).toBe(3)
  })

  it('defaults to 1 when the param is missing or blank', () => {
    expect(parsePage(undefined)).toBe(1)
    expect(parsePage('')).toBe(1)
    expect(parsePage('   ')).toBe(1)
  })

  it('clamps zero and negative pages to 1', () => {
    expect(parsePage('0')).toBe(1)
    expect(parsePage('-7')).toBe(1)
  })

  it('falls back to 1 for non-numeric and non-finite values', () => {
    expect(parsePage('abc')).toBe(1)
    expect(parsePage('Infinity')).toBe(1)
    expect(parsePage('NaN')).toBe(1)
  })

  it('floors a fractional page instead of erroring', () => {
    expect(parsePage('2.9')).toBe(2)
  })

  it('reads the first value of a repeated param', () => {
    expect(parsePage(['4', '11'])).toBe(4)
  })

  it('clamps above the ceiling so `offset` cannot run away', () => {
    expect(parsePage(String(MAX_PAGE + 1))).toBe(MAX_PAGE)
    expect(parsePage('1e21')).toBe(MAX_PAGE)
  })

  it('honours a caller-supplied ceiling', () => {
    expect(parsePage('500', 100)).toBe(100)
  })
})

describe('pageRange', () => {
  it('maps page 1 to the first slot', () => {
    expect(pageRange(1)).toEqual({ from: 0, to: DEFAULT_PAGE_SIZE - 1 })
  })

  it('advances by a full page each time, with an inclusive upper bound', () => {
    expect(pageRange(2)).toEqual({ from: 50, to: 99 })
    expect(pageRange(3)).toEqual({ from: 100, to: 149 })
  })

  it('never produces a negative offset for a bad page', () => {
    expect(pageRange(0)).toEqual({ from: 0, to: 49 })
    expect(pageRange(-4)).toEqual({ from: 0, to: 49 })
  })

  it('honours a custom page size', () => {
    expect(pageRange(3, 10)).toEqual({ from: 20, to: 29 })
  })
})

describe('pageCount', () => {
  it('never drops below 1, so the footer reads "1 / 1" on an empty table', () => {
    expect(pageCount(0)).toBe(1)
    expect(pageCount(-5)).toBe(1)
    expect(pageCount(Number.NaN)).toBe(1)
  })

  it('rounds a partial last page up', () => {
    expect(pageCount(1)).toBe(1)
    expect(pageCount(50)).toBe(1)
    expect(pageCount(51)).toBe(2)
    expect(pageCount(100)).toBe(2)
  })

  it('honours a custom page size', () => {
    expect(pageCount(25, 10)).toBe(3)
  })
})

describe('hasNextPage', () => {
  it('uses the exact count when one is available', () => {
    expect(hasNextPage(1, 120, DEFAULT_PAGE_SIZE)).toBe(true)
    expect(hasNextPage(3, 120, 20)).toBe(false)
  })

  it('falls back to "the page came back full" when the total is null', () => {
    expect(hasNextPage(1, null, DEFAULT_PAGE_SIZE)).toBe(true)
    expect(hasNextPage(1, null, DEFAULT_PAGE_SIZE - 1)).toBe(false)
    expect(hasNextPage(1, null, 0)).toBe(false)
  })

  it('stops at the page ceiling even when more rows exist', () => {
    expect(hasNextPage(MAX_PAGE, 10_000_000, DEFAULT_PAGE_SIZE)).toBe(false)
    expect(hasNextPage(MAX_PAGE, null, DEFAULT_PAGE_SIZE)).toBe(false)
  })

  it('honours custom page size and ceiling', () => {
    expect(hasNextPage(1, null, 10, 10)).toBe(true)
    expect(hasNextPage(5, 1000, DEFAULT_PAGE_SIZE, DEFAULT_PAGE_SIZE, 5)).toBe(false)
  })
})

describe('pageHref', () => {
  it('omits the query string for page 1 so the default view stays clean', () => {
    expect(pageHref('/catalog', 1)).toBe('/catalog')
    expect(pageHref('/catalog', 0)).toBe('/catalog')
  })

  it('adds `?page=` for every other page', () => {
    expect(pageHref('/catalog', 2)).toBe('/catalog?page=2')
    expect(pageHref('/flags', 17)).toBe('/flags?page=17')
  })

  it('round-trips through parsePage', () => {
    const url = new URL(pageHref('/announcements', 7), 'https://panel.example')
    expect(parsePage(url.searchParams.get('page') ?? undefined)).toBe(7)
  })
})
