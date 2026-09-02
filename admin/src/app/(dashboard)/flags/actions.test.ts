import { beforeEach, describe, expect, it, vi } from 'vitest'

import { createPostgrestMock, ZERO_ROWS, type QueryHandler } from '../../../../test/postgrest-mock'

import {
  createFlagAction,
  deleteFlagAction,
  initialActionState,
  toggleFlagAction,
  updateFlagPayloadAction,
} from './actions'

/**
 * The zero-row hole mattered most here: a server action is a POST with an
 * arbitrary body, so before the `.select('key')` check any admin could call
 * `toggleFlagAction('ghost_key', false)` and mint a `flag.update` audit entry for a
 * key that does not exist.
 */

const revalidatePath = vi.fn()
const requireAdmin = vi.fn()
const writeAudit = vi.fn()

const ACTOR = '00000000-0000-4000-8000-00000000aaaa'
const KEY = 'new_vault_ui'

const oneRow: QueryHandler = (q) => ({ data: q.single ? { key: KEY } : [{ key: KEY }], error: null })

let handler: QueryHandler = oneRow
let db = createPostgrestMock((q) => handler(q))

vi.mock('next/cache', () => ({ revalidatePath: (path: string) => revalidatePath(path) }))
vi.mock('@/lib/auth', () => ({ requireAdmin: () => requireAdmin() }))
vi.mock('@/lib/audit', () => ({ writeAudit: (entry: unknown) => writeAudit(entry) }))
vi.mock('@/lib/supabase/admin', () => ({ createAdminClient: () => db.client }))

function createForm(overrides: Record<string, string> = {}): FormData {
  const data = new FormData()
  data.set('key', KEY)
  data.set('enabled', 'true')
  data.set('payload', '')
  for (const [name, value] of Object.entries(overrides)) data.set(name, value)
  return data
}

function payloadForm(payload: string, key = KEY): FormData {
  const data = new FormData()
  data.set('key', key)
  data.set('payload', payload)
  return data
}

beforeEach(() => {
  vi.clearAllMocks()
  vi.spyOn(console, 'error').mockImplementation(() => {})
  requireAdmin.mockResolvedValue({ userId: ACTOR, email: 'yonetici@ornek.com' })
  writeAudit.mockResolvedValue(undefined)
  handler = oneRow
  db = createPostgrestMock((q) => handler(q))
})

const ACTIONS = [
  { name: 'createFlagAction', run: () => createFlagAction(initialActionState, createForm()) },
  { name: 'toggleFlagAction', run: () => toggleFlagAction(KEY, false) },
  {
    name: 'updateFlagPayloadAction',
    run: () => updateFlagPayloadAction(initialActionState, payloadForm('{"a":1}')),
  },
  { name: 'deleteFlagAction', run: () => deleteFlagAction(KEY) },
] as const

describe('flags actions — requireAdmin is the first gate', () => {
  it.each(ACTIONS)('$name calls requireAdmin()', async ({ run }) => {
    await run()
    expect(requireAdmin).toHaveBeenCalled()
  })

  it.each(ACTIONS)(
    '$name touches neither Supabase nor the audit log when requireAdmin rejects',
    async ({ run }) => {
      requireAdmin.mockRejectedValue(new Error('ForbiddenError'))

      await expect(run()).rejects.toThrow()
      expect(db.calls).toHaveLength(0)
      expect(writeAudit).not.toHaveBeenCalled()
      expect(revalidatePath).not.toHaveBeenCalled()
    },
  )
})

describe('createFlagAction', () => {
  it('inserts and audits <key>:create', async () => {
    const state = await createFlagAction(initialActionState, createForm())

    expect(db.calls[0]).toMatchObject({ table: 'feature_flags', op: 'insert' })
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'flag.update',
      target: `${KEY}:create`,
    })
    expect(state.status).toBe('success')
  })

  it('names a duplicate key instead of reporting a generic failure', async () => {
    handler = () => ({ data: null, error: { code: '23505', message: 'duplicate key value' } })

    const state = await createFlagAction(initialActionState, createForm())

    expect(state).toEqual({ status: 'error', message: 'Bu anahtar zaten var.' })
    expect(writeAudit).not.toHaveBeenCalled()
  })

  it('rejects a prototype-shaped payload key before any write', async () => {
    const state = await createFlagAction(
      initialActionState,
      createForm({ payload: '{"__proto__":{"admin":true}}' }),
    )

    expect(state.status).toBe('error')
    expect(db.calls).toHaveLength(0)
  })
})

describe('toggleFlagAction', () => {
  it('asks for the affected rows back and audits enable/disable', async () => {
    const state = await toggleFlagAction(KEY, false)

    expect(db.calls[0]).toMatchObject({
      table: 'feature_flags',
      op: 'update',
      values: { enabled: false },
      columns: 'key',
      filters: [{ column: 'key', value: KEY }],
    })
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'flag.update',
      target: `${KEY}:disable`,
    })
    expect(state.status).toBe('success')
  })

  it('refuses to audit a toggle of a key that does not exist', async () => {
    handler = () => ZERO_ROWS

    const state = await toggleFlagAction('ghost_key', false)

    expect(state).toEqual({ status: 'error', message: expect.stringContaining('bulunamadı') })
    expect(writeAudit).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })

  it('rejects a malformed key before touching the database', async () => {
    const state = await toggleFlagAction('Not A Key', true)

    expect(state.status).toBe('error')
    expect(db.calls).toHaveLength(0)
  })
})

describe('updateFlagPayloadAction', () => {
  it('writes the parsed payload and audits <key>:payload', async () => {
    const state = await updateFlagPayloadAction(initialActionState, payloadForm('{"a":1}'))

    expect(db.calls[0]).toMatchObject({
      table: 'feature_flags',
      op: 'update',
      values: { payload: { a: 1 } },
      columns: 'key',
    })
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'flag.update',
      target: `${KEY}:payload`,
    })
    expect(state.status).toBe('success')
  })

  it('reports a zero-row payload write as an error and mints no audit row', async () => {
    handler = () => ZERO_ROWS

    const state = await updateFlagPayloadAction(initialActionState, payloadForm('{"a":1}'))

    expect(state.status).toBe('error')
    expect(writeAudit).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })

  it('rejects an array payload (the client drops it) before writing', async () => {
    const state = await updateFlagPayloadAction(initialActionState, payloadForm('[1,2,3]'))

    expect(state.status).toBe('error')
    expect(db.calls).toHaveLength(0)
  })
})

describe('deleteFlagAction', () => {
  it('deletes and audits <key>:delete', async () => {
    const state = await deleteFlagAction(KEY)

    expect(db.calls[0]).toMatchObject({
      table: 'feature_flags',
      op: 'delete',
      columns: 'key',
      filters: [{ column: 'key', value: KEY }],
    })
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'flag.update',
      target: `${KEY}:delete`,
    })
    expect(state.status).toBe('success')
  })

  it('refuses to delete the token_sync kill switch', async () => {
    const state = await deleteFlagAction('token_sync_enabled')

    expect(state.status).toBe('error')
    expect(db.calls).toHaveLength(0)
    expect(writeAudit).not.toHaveBeenCalled()
  })

  it('refuses to audit a delete of a key that does not exist', async () => {
    handler = () => ZERO_ROWS

    const state = await deleteFlagAction('ghost_key')

    expect(state.status).toBe('error')
    expect(writeAudit).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })
})
