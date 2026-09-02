import { beforeEach, describe, expect, it, vi } from 'vitest'

import { createPostgrestMock, ZERO_ROWS, type QueryHandler } from '../../../../test/postgrest-mock'

import {
  createAnnouncementAction,
  deleteAnnouncementAction,
  initialActionState,
  updateAnnouncementAction,
} from './actions'

/**
 * Two invariants are under test here, both of which the module used to break:
 *
 *  1. `requireAdmin()` runs FIRST — when it rejects, nothing privileged happens.
 *  2. An UPDATE/DELETE that matched **zero rows** is an error, not a success:
 *     no `revalidatePath`, and above all no `audit_logs` row for an operation that
 *     never occurred.
 */

const revalidatePath = vi.fn()
const requireAdmin = vi.fn()
const writeAudit = vi.fn()

/** Default: one row affected. `.single()` yields an object, everything else an array. */
const oneRow: QueryHandler = (q) => ({ data: q.single ? { id: ID } : [{ id: ID }], error: null })

let handler: QueryHandler = oneRow
let db = createPostgrestMock((q) => handler(q))

vi.mock('next/cache', () => ({ revalidatePath: (path: string) => revalidatePath(path) }))
vi.mock('@/lib/auth', () => ({ requireAdmin: () => requireAdmin() }))
vi.mock('@/lib/audit', () => ({ writeAudit: (entry: unknown) => writeAudit(entry) }))
vi.mock('@/lib/supabase/admin', () => ({ createAdminClient: () => db.client }))

const ACTOR = '00000000-0000-4000-8000-00000000aaaa'
const ID = '11111111-1111-4111-8111-111111111111'

function form(overrides: Record<string, string> = {}): FormData {
  const data = new FormData()
  data.set('id', ID)
  data.set('title', 'Bakım çalışması')
  data.set('body', 'Pazar günü 02:00–04:00 arası kısa kesintiler olabilir.')
  data.set('audience', 'all')
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

/** Every exported server action, invoked the way its caller invokes it. */
const ACTIONS = [
  {
    name: 'createAnnouncementAction',
    run: () => createAnnouncementAction(initialActionState, form()),
  },
  {
    name: 'updateAnnouncementAction',
    run: () => updateAnnouncementAction(initialActionState, form()),
  },
  { name: 'deleteAnnouncementAction', run: () => deleteAnnouncementAction(ID) },
] as const

describe('announcements actions — requireAdmin is the first gate', () => {
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

describe('createAnnouncementAction', () => {
  it('inserts, revalidates and audits the created id', async () => {
    const state = await createAnnouncementAction(initialActionState, form())

    expect(db.calls[0]).toMatchObject({ table: 'announcements', op: 'insert', columns: 'id' })
    expect(revalidatePath).toHaveBeenCalledWith('/announcements')
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'announcement.create',
      target: ID,
    })
    expect(state.status).toBe('success')
  })

  it('rejects an unknown audience without writing anything', async () => {
    const state = await createAnnouncementAction(initialActionState, form({ audience: 'desktop' }))

    expect(state.status).toBe('error')
    expect(db.calls).toHaveLength(0)
    expect(writeAudit).not.toHaveBeenCalled()
  })
})

describe('updateAnnouncementAction', () => {
  it('asks PostgREST for the affected rows so a no-op cannot look like a success', async () => {
    await updateAnnouncementAction(initialActionState, form())

    expect(db.calls[0]).toMatchObject({
      table: 'announcements',
      op: 'update',
      columns: 'id',
      filters: [{ column: 'id', value: ID }],
    })
  })

  it('reports a zero-row update as an error, with no audit row and no revalidate', async () => {
    handler = () => ZERO_ROWS

    const state = await updateAnnouncementAction(initialActionState, form())

    expect(state).toEqual({ status: 'error', message: expect.stringContaining('bulunamadı') })
    expect(writeAudit).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })

  it('rejects a non-uuid id before touching the database', async () => {
    const state = await updateAnnouncementAction(initialActionState, form({ id: 'nope' }))

    expect(state.status).toBe('error')
    expect(db.calls).toHaveLength(0)
  })

  it('reports a driver error without leaking it, and without auditing', async () => {
    handler = () => ({ data: null, error: { message: 'null value in column "title"' } })

    const state = await updateAnnouncementAction(initialActionState, form())

    expect(state).toEqual({ status: 'error', message: 'Duyuru güncellenemedi.' })
    expect(writeAudit).not.toHaveBeenCalled()
  })
})

describe('deleteAnnouncementAction', () => {
  it('deletes, revalidates and audits', async () => {
    const state = await deleteAnnouncementAction(ID)

    expect(db.calls[0]).toMatchObject({
      table: 'announcements',
      op: 'delete',
      columns: 'id',
      filters: [{ column: 'id', value: ID }],
    })
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'announcement.delete',
      target: ID,
    })
    expect(state.status).toBe('success')
  })

  it('reports a zero-row delete as an error and mints no audit row', async () => {
    // Two admins on the page: A already deleted the row, B clicks delete.
    handler = () => ZERO_ROWS

    const state = await deleteAnnouncementAction(ID)

    expect(state.status).toBe('error')
    expect(writeAudit).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })

  it('reports a failed audit write as such, not as a failed delete', async () => {
    writeAudit.mockRejectedValue(new Error('audit down'))

    const state = await deleteAnnouncementAction(ID)

    expect(state).toEqual({
      status: 'error',
      message: expect.stringMatching(/denetim kaydı yazılamadı/i),
    })
    expect(revalidatePath).toHaveBeenCalledWith('/announcements')
  })
})
