import { describe, expect, it } from 'vitest'

import { buildSslOptions, parseGlobalStats } from '@/lib/db'

describe('buildSslOptions', () => {
  it('always verifies the server certificate', () => {
    // `ssl: 'require'` is NOT this: in postgres@3.4.9 the string forms set
    // `rejectUnauthorized = false`, i.e. encrypted but unauthenticated.
    expect(buildSslOptions(undefined).rejectUnauthorized).toBe(true)
    expect(buildSslOptions('-----BEGIN CERTIFICATE-----').rejectUnauthorized).toBe(true)
  })

  it('omits `ca` entirely when no certificate is configured', () => {
    expect(buildSslOptions(undefined)).toEqual({ rejectUnauthorized: true })
    expect('ca' in buildSslOptions(undefined)).toBe(false)
    expect(buildSslOptions('')).toEqual({ rejectUnauthorized: true })
  })

  it('pins the configured CA when one is given', () => {
    const pem = '-----BEGIN CERTIFICATE-----\nMIIDdummy\n-----END CERTIFICATE-----'
    expect(buildSslOptions(pem)).toEqual({ rejectUnauthorized: true, ca: pem })
  })
})

describe('parseGlobalStats', () => {
  it('parses the jsonb payload of private.admin_global_stats()', () => {
    const stats = parseGlobalStats({
      total_users: 12,
      total_tokens: 340,
      total_devices: 25,
      generated_at: '2026-09-02T10:00:00+00:00',
    })

    expect(stats).toEqual({
      total_users: 12,
      total_tokens: 340,
      total_devices: 25,
      generated_at: '2026-09-02T10:00:00+00:00',
    })
  })

  it('accepts zero counts on an empty project', () => {
    expect(
      parseGlobalStats({
        total_users: 0,
        total_tokens: 0,
        total_devices: 0,
        generated_at: '2026-09-02T10:00:00+00:00',
      }).total_users,
    ).toBe(0)
  })

  it('rejects counts arriving as strings (bigint serialisation regression)', () => {
    expect(() =>
      parseGlobalStats({
        total_users: '12',
        total_tokens: 340,
        total_devices: 25,
        generated_at: '2026-09-02T10:00:00+00:00',
      }),
    ).toThrow(/total_users/)
  })

  it('rejects a missing field', () => {
    expect(() =>
      parseGlobalStats({
        total_users: 12,
        total_tokens: 340,
        generated_at: '2026-09-02T10:00:00+00:00',
      }),
    ).toThrow(/total_devices/)
  })

  it('rejects null / non-object payloads', () => {
    expect(() => parseGlobalStats(null)).toThrow()
    expect(() => parseGlobalStats(undefined)).toThrow()
    expect(() => parseGlobalStats('{}')).toThrow()
  })
})
