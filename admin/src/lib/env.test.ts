import { describe, expect, it } from 'vitest'

import { publicEnvSchema, serverEnvSchema } from '@/lib/env'

const LEGACY_JWT =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlhdCI6MTcwMDAwMDAwMH0.signature'

describe('publicEnvSchema', () => {
  it('accepts a URL + sb_publishable_ key', () => {
    const result = publicEnvSchema.safeParse({
      NEXT_PUBLIC_SUPABASE_URL: 'https://vfyqokvgtdxxurroqbtj.supabase.co',
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_abc123',
    })
    expect(result.success).toBe(true)
  })

  it('rejects the legacy eyJ… JWT anon key', () => {
    const result = publicEnvSchema.safeParse({
      NEXT_PUBLIC_SUPABASE_URL: 'https://vfyqokvgtdxxurroqbtj.supabase.co',
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: LEGACY_JWT,
    })
    expect(result.success).toBe(false)
  })

  it('rejects a secret key smuggled into the public slot', () => {
    const result = publicEnvSchema.safeParse({
      NEXT_PUBLIC_SUPABASE_URL: 'https://vfyqokvgtdxxurroqbtj.supabase.co',
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: 'sb_secret_abc123',
    })
    expect(result.success).toBe(false)
  })

  it('rejects a non-URL', () => {
    const result = publicEnvSchema.safeParse({
      NEXT_PUBLIC_SUPABASE_URL: 'vfyqokvgtdxxurroqbtj',
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_abc123',
    })
    expect(result.success).toBe(false)
  })

  it('rejects missing values', () => {
    expect(publicEnvSchema.safeParse({}).success).toBe(false)
  })
})

describe('serverEnvSchema', () => {
  const validDbUrl = 'postgres://admin_app.ref:pw@aws-0-eu-central-1.pooler.supabase.com:6543/postgres'

  it('accepts an sb_secret_ key + postgres URL', () => {
    const result = serverEnvSchema.safeParse({
      SUPABASE_SECRET_KEY: 'sb_secret_abc123',
      DATABASE_URL: validDbUrl,
    })
    expect(result.success).toBe(true)
  })

  it('accepts the postgresql:// scheme too', () => {
    const result = serverEnvSchema.safeParse({
      SUPABASE_SECRET_KEY: 'sb_secret_abc123',
      DATABASE_URL: 'postgresql://admin_app:pw@db.ref.supabase.co:5432/postgres',
    })
    expect(result.success).toBe(true)
  })

  it('rejects the legacy eyJ… JWT service_role key', () => {
    const result = serverEnvSchema.safeParse({
      SUPABASE_SECRET_KEY: LEGACY_JWT,
      DATABASE_URL: validDbUrl,
    })
    expect(result.success).toBe(false)
  })

  it('rejects a publishable key in the secret slot', () => {
    const result = serverEnvSchema.safeParse({
      SUPABASE_SECRET_KEY: 'sb_publishable_abc123',
      DATABASE_URL: validDbUrl,
    })
    expect(result.success).toBe(false)
  })

  it('rejects a non-postgres DATABASE_URL', () => {
    const result = serverEnvSchema.safeParse({
      SUPABASE_SECRET_KEY: 'sb_secret_abc123',
      DATABASE_URL: 'https://vfyqokvgtdxxurroqbtj.supabase.co',
    })
    expect(result.success).toBe(false)
  })
})
