import { beforeEach, describe, expect, it, vi } from 'vitest'

import { createPostgrestMock, ZERO_ROWS, type QueryHandler } from '../../../../test/postgrest-mock'

import {
  createCatalogServiceAction,
  deleteCatalogServiceAction,
  initialActionState,
  updateCatalogServiceAction,
} from './actions'

/**
 * Same two invariants as the announcements suite: `requireAdmin()` first, and a
 * zero-row UPDATE/DELETE is an error rather than a success + a false audit row.
 */

const revalidatePath = vi.fn()
const requireAdmin = vi.fn()
const writeAudit = vi.fn()

const ACTOR = '00000000-0000-4000-8000-00000000aaaa'
const ID = '22222222-2222-4222-8222-222222222222'

const oneRow: QueryHandler = (q) => ({ data: q.single ? { id: ID } : [{ id: ID }], error: null })

let handler: QueryHandler = oneRow
let db = createPostgrestMock((q) => handler(q))

vi.mock('next/cache', () => ({ revalidatePath: (path: string) => revalidatePath(path) }))
vi.mock('@/lib/auth', () => ({ requireAdmin: () => requireAdmin() }))
vi.mock('@/lib/audit', () => ({ writeAudit: (entry: unknown) => writeAudit(entry) }))
vi.mock('@/lib/supabase/admin', () => ({ createAdminClient: () => db.client }))

function form(overrides: Record<string, string> = {}): FormData {
  const data = new FormData()
  data.set('id', ID)
  data.set('name', 'GitHub')
  data.set('issuer', 'GitHub')
  data.set('logo_url', 'https://cdn.example.com/github.png')
  for (const [key, value] of Object.entries(overrides)) data.set(key, value)
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
  {
    name: 'createCatalogServiceAction',
    run: () => createCatalogServiceAction(initialActionState, form()),
  },
  {
    name: 'updateCatalogServiceAction',
    run: () => updateCatalogServiceAction(initialActionState, form()),
  },
  { name: 'deleteCatalogServiceAction', run: () => deleteCatalogServiceAction(ID) },
] as const

describe('catalog actions — requireAdmin is the first gate', () => {
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

describe('createCatalogServiceAction', () => {
  it('inserts, revalidates and audits the created id', async () => {
    const state = await createCatalogServiceAction(initialActionState, form())

    expect(db.calls[0]).toMatchObject({ table: 'catalog_services', op: 'insert', columns: 'id' })
    expect(revalidatePath).toHaveBeenCalledWith('/catalog')
    expect(writeAudit).toHaveBeenCalledWith({ actor: ACTOR, action: 'catalog.create', target: ID })
    expect(state.status).toBe('success')
  })

  it('rejects a non-https logo_url before touching the database', async () => {
    const state = await createCatalogServiceAction(
      initialActionState,
      form({ logo_url: 'http://cdn.example.com/github.png' }),
    )

    expect(state.status).toBe('error')
    expect(db.calls).toHaveLength(0)
    expect(writeAudit).not.toHaveBeenCalled()
  })
})

describe('updateCatalogServiceAction', () => {
  it('asks for the affected rows back', async () => {
    await updateCatalogServiceAction(initialActionState, form())

    expect(db.calls[0]).toMatchObject({
      table: 'catalog_services',
      op: 'update',
      columns: 'id',
      filters: [{ column: 'id', value: ID }],
    })
  })

  it('reports a zero-row update as an error, with no audit row and no revalidate', async () => {
    handler = () => ZERO_ROWS

    const state = await updateCatalogServiceAction(initialActionState, form())

    expect(state).toEqual({ status: 'error', message: expect.stringContaining('bulunamadı') })
    expect(writeAudit).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })

  it('rejects a non-uuid id before touching the database', async () => {
    const state = await updateCatalogServiceAction(initialActionState, form({ id: 'nope' }))

    expect(state.status).toBe('error')
    expect(db.calls).toHaveLength(0)
  })
})

describe('deleteCatalogServiceAction', () => {
  it('deletes, revalidates and audits', async () => {
    const state = await deleteCatalogServiceAction(ID)

    expect(db.calls[0]).toMatchObject({
      table: 'catalog_services',
      op: 'delete',
      columns: 'id',
      filters: [{ column: 'id', value: ID }],
    })
    expect(writeAudit).toHaveBeenCalledWith({ actor: ACTOR, action: 'catalog.delete', target: ID })
    expect(state.status).toBe('success')
  })

  it('reports a zero-row delete as an error and mints no audit row', async () => {
    handler = () => ZERO_ROWS

    const state = await deleteCatalogServiceAction(ID)

    expect(state.status).toBe('error')
    expect(writeAudit).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })

  it('reports a driver error without leaking it', async () => {
    handler = () => ({ data: null, error: { message: 'violates foreign key constraint' } })

    const state = await deleteCatalogServiceAction(ID)

    expect(state).toEqual({ status: 'error', message: 'Servis silinemedi.' })
    expect(writeAudit).not.toHaveBeenCalled()
  })
})
