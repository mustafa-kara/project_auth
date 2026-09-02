import { describe, expect, it } from 'vitest'

import {
  flagAuditTarget,
  flagCreateSchema,
  FORBIDDEN_PAYLOAD_KEYS,
  flagDeleteSchema,
  flagKeySchema,
  flagPayloadTextSchema,
  formatPayload,
  mapFlagRow,
  mapFlagRows,
  parseFlagPayload,
  PAYLOAD_MAX_BYTES,
  TOKEN_SYNC_FLAG_KEY,
} from '@/lib/flags'

describe('flagKeySchema', () => {
  it('accepts the key the mobile client reads', () => {
    expect(flagKeySchema.parse(TOKEN_SYNC_FLAG_KEY)).toBe('token_sync_enabled')
  })

  it('accepts lowercase snake_case keys of 3–64 chars', () => {
    for (const key of ['abc', 'a_b', 'a1_b2', `a${'x'.repeat(63)}`]) {
      expect(flagKeySchema.safeParse(key).success).toBe(true)
    }
  })

  it('rejects keys the regex forbids', () => {
    for (const key of [
      'ab', // too short
      `a${'x'.repeat(64)}`, // 65 chars
      '1abc', // starts with a digit
      '_abc', // starts with an underscore
      'Abc', // uppercase
      'a-b', // hyphen
      'a b', // space
      'a.b', // dot
      '',
    ]) {
      expect(flagKeySchema.safeParse(key).success).toBe(false)
    }
  })
})

describe('parseFlagPayload', () => {
  it('treats empty and whitespace-only text as NULL', () => {
    expect(parseFlagPayload('')).toEqual({ ok: true, value: null })
    expect(parseFlagPayload('   \n\t ')).toEqual({ ok: true, value: null })
    expect(parseFlagPayload(null)).toEqual({ ok: true, value: null })
    expect(parseFlagPayload(undefined)).toEqual({ ok: true, value: null })
  })

  it('accepts a JSON object', () => {
    expect(parseFlagPayload('{"min_build": 42, "nested": {"a": true}}')).toEqual({
      ok: true,
      value: { min_build: 42, nested: { a: true } },
    })
  })

  it('accepts the literal null', () => {
    expect(parseFlagPayload('null')).toEqual({ ok: true, value: null })
  })

  it('rejects malformed JSON', () => {
    const result = parseFlagPayload('{ not json')
    expect(result.ok).toBe(false)
    expect(result.ok === false && result.error).toMatch(/JSON/)
  })

  it('rejects arrays and scalars the Flutter client would drop', () => {
    for (const raw of ['[1,2,3]', '"metin"', '42', 'true']) {
      expect(parseFlagPayload(raw).ok).toBe(false)
    }
  })

  it('rejects a payload larger than 8 KiB', () => {
    const tooBig = JSON.stringify({ v: 'x'.repeat(PAYLOAD_MAX_BYTES) })
    const result = parseFlagPayload(tooBig)
    expect(result.ok).toBe(false)
    expect(result.ok === false && result.error).toMatch(/KiB/)
  })

  it('measures the cap in bytes, not characters', () => {
    // 'ç' is 2 bytes in UTF-8, so a string well under 8192 chars can still be over.
    const value = 'ç'.repeat(PAYLOAD_MAX_BYTES / 2)
    expect(JSON.stringify({ v: value }).length).toBeLessThan(PAYLOAD_MAX_BYTES)
    expect(parseFlagPayload(JSON.stringify({ v: value })).ok).toBe(false)
  })

  it('rejects prototype-shaped keys at the top level', () => {
    for (const key of FORBIDDEN_PAYLOAD_KEYS) {
      const result = parseFlagPayload(`{"${key}": {"admin": true}}`)
      expect(result.ok).toBe(false)
      expect(result.ok === false && result.error).toContain(key)
    }
  })

  it('rejects prototype-shaped keys nested inside objects and arrays', () => {
    expect(parseFlagPayload('{"a": {"b": {"__proto__": {"x": 1}}}}').ok).toBe(false)
    expect(parseFlagPayload('{"a": [{"constructor": {"x": 1}}]}').ok).toBe(false)
    expect(parseFlagPayload('{"a": [[{"prototype": 1}]]}').ok).toBe(false)
  })

  it('still accepts a payload that merely mentions those words as values', () => {
    expect(parseFlagPayload('{"note": "__proto__ is not a key here"}')).toEqual({
      ok: true,
      value: { note: '__proto__ is not a key here' },
    })
  })
})

describe('flagPayloadTextSchema', () => {
  it('reports the parse failure as a zod issue', () => {
    const result = flagPayloadTextSchema.safeParse('[1]')
    expect(result.success).toBe(false)
    expect(result.error?.issues[0]?.message).toMatch(/nesnesi/)
  })

  it('yields the parsed object on success', () => {
    expect(flagPayloadTextSchema.parse('{"a":1}')).toEqual({ a: 1 })
  })
})

describe('flagCreateSchema', () => {
  it('accepts a new flag with a payload', () => {
    expect(
      flagCreateSchema.parse({ key: 'new_feature', enabled: false, payload: '{"a":1}' }),
    ).toEqual({ key: 'new_feature', enabled: false, payload: { a: 1 } })
  })

  it('rejects an invalid key even when the payload is fine', () => {
    expect(flagCreateSchema.safeParse({ key: 'Bad-Key', enabled: true, payload: '' }).success).toBe(
      false,
    )
  })
})

describe('flagDeleteSchema', () => {
  it('refuses to delete the token sync kill switch', () => {
    const result = flagDeleteSchema.safeParse({ key: TOKEN_SYNC_FLAG_KEY })
    expect(result.success).toBe(false)
    expect(result.error?.issues[0]?.message).toMatch(/silinemez/)
  })

  it('allows deleting any other key', () => {
    expect(flagDeleteSchema.safeParse({ key: 'some_other_flag' }).success).toBe(true)
  })
})

describe('flagAuditTarget', () => {
  it('formats key and operation as key:operation', () => {
    expect(flagAuditTarget(TOKEN_SYNC_FLAG_KEY, 'disable')).toBe('token_sync_enabled:disable')
    expect(flagAuditTarget(TOKEN_SYNC_FLAG_KEY, 'enable')).toBe('token_sync_enabled:enable')
    expect(flagAuditTarget('new_feature', 'create')).toBe('new_feature:create')
    expect(flagAuditTarget('new_feature', 'payload')).toBe('new_feature:payload')
    expect(flagAuditTarget('new_feature', 'delete')).toBe('new_feature:delete')
  })
})

describe('mapFlagRow', () => {
  const valid = { key: 'token_sync_enabled', enabled: true, payload: null, updated_at: '2026-09-02T10:00:00+00:00' }

  it('maps a well-formed row', () => {
    expect(mapFlagRow(valid)).toEqual({
      key: 'token_sync_enabled',
      enabled: true,
      payload: null,
      payloadUnusable: false,
      updatedAt: '2026-09-02T10:00:00+00:00',
    })
  })

  it('quarantines rows with a non-string key or non-boolean enabled', () => {
    expect(mapFlagRow({ ...valid, key: 1 })).toBeNull()
    expect(mapFlagRow({ ...valid, key: '' })).toBeNull()
    expect(mapFlagRow({ ...valid, enabled: 'true' })).toBeNull()
    expect(mapFlagRow({ ...valid, enabled: null })).toBeNull()
    expect(mapFlagRow(null)).toBeNull()
  })

  it('nulls a payload that is not an object, matching the client', () => {
    expect(mapFlagRow({ ...valid, payload: [1, 2] })?.payload).toBeNull()
    expect(mapFlagRow({ ...valid, payload: 'x' })?.payload).toBeNull()
    expect(mapFlagRow({ ...valid, payload: { a: 1 } })?.payload).toEqual({ a: 1 })
  })

  it('flags a coerced payload as unusable so the editor can warn instead of erasing it', () => {
    expect(mapFlagRow({ ...valid, payload: [1, 2] })?.payloadUnusable).toBe(true)
    expect(mapFlagRow({ ...valid, payload: 'x' })?.payloadUnusable).toBe(true)
    expect(mapFlagRow({ ...valid, payload: 42 })?.payloadUnusable).toBe(true)
    expect(mapFlagRow({ ...valid, payload: false })?.payloadUnusable).toBe(true)
  })

  it('does not call an ordinary NULL (or an absent column) unusable', () => {
    expect(mapFlagRow({ ...valid, payload: null })?.payloadUnusable).toBe(false)
    expect(mapFlagRow({ key: 'k_ey', enabled: false })?.payloadUnusable).toBe(false)
    expect(mapFlagRow({ ...valid, payload: { a: 1 } })?.payloadUnusable).toBe(false)
  })

  it('tolerates a missing updated_at', () => {
    expect(mapFlagRow({ key: 'k_ey', enabled: false })?.updatedAt).toBeNull()
  })

  it('keeps the good rows and drops the bad ones', () => {
    expect(mapFlagRows([valid, { key: 'x', enabled: 1 }])).toHaveLength(1)
    expect(mapFlagRows(undefined)).toEqual([])
  })
})

describe('formatPayload', () => {
  it('renders null as an empty editor', () => {
    expect(formatPayload(null)).toBe('')
  })

  it('pretty-prints an object', () => {
    expect(formatPayload({ a: 1 })).toBe('{\n  "a": 1\n}')
  })
})
