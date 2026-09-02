import { beforeEach, describe, expect, it, vi } from 'vitest'

import { initialUserActionState, userAction } from './actions'

/**
 * The Supabase clients are mocked at the module boundary — no network, no keys.
 * What is under test is the ORDER of the server-side checks: requireAdmin →
 * validation → admin-list read (fail closed) → guard → SDK call → audit.
 */

const revalidatePath = vi.fn()
const requireAdmin = vi.fn()
const writeAudit = vi.fn()
const fetchAdminUserIds = vi.fn()
const updateUserById = vi.fn()
const deleteUser = vi.fn()

vi.mock('next/cache', () => ({ revalidatePath: (path: string) => revalidatePath(path) }))
vi.mock('@/lib/auth', () => ({ requireAdmin: () => requireAdmin() }))
vi.mock('@/lib/audit', () => ({ writeAudit: (entry: unknown) => writeAudit(entry) }))
vi.mock('./data', () => ({ fetchAdminUserIds: () => fetchAdminUserIds() }))
vi.mock('@/lib/supabase/admin', () => ({
  createAdminClient: () => ({
    auth: {
      admin: {
        updateUserById: (id: string, attrs: unknown) => updateUserById(id, attrs),
        deleteUser: (id: string) => deleteUser(id),
      },
    },
  }),
}))

const ACTOR = '00000000-0000-4000-8000-00000000aaaa'
const TARGET = '00000000-0000-4000-8000-00000000bbbb'
const OTHER_ADMIN = '00000000-0000-4000-8000-00000000cccc'

function form(userId: string, intent: string): FormData {
  const data = new FormData()
  data.set('userId', userId)
  data.set('intent', intent)
  return data
}

beforeEach(() => {
  vi.clearAllMocks()
  requireAdmin.mockResolvedValue({ userId: ACTOR, email: 'yonetici@ornek.com' })
  fetchAdminUserIds.mockResolvedValue(new Set([ACTOR, OTHER_ADMIN]))
  updateUserById.mockResolvedValue({ data: { user: { id: TARGET } }, error: null })
  deleteUser.mockResolvedValue({ data: { user: {} }, error: null })
  writeAudit.mockResolvedValue(undefined)
})

describe('userAction', () => {
  it('bans with the ~100 year duration and audits it', async () => {
    const state = await userAction(initialUserActionState, form(TARGET, 'ban'))

    expect(updateUserById).toHaveBeenCalledWith(TARGET, { ban_duration: '876600h' })
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'user.ban',
      target: TARGET,
    })
    expect(revalidatePath).toHaveBeenCalledWith('/users')
    expect(state.status).toBe('success')
  })

  it("lifts a ban with 'none' and audits user.unban", async () => {
    const state = await userAction(initialUserActionState, form(TARGET, 'unban'))

    expect(updateUserById).toHaveBeenCalledWith(TARGET, { ban_duration: 'none' })
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'user.unban',
      target: TARGET,
    })
    expect(state.status).toBe('success')
  })

  it('deletes through auth.admin.deleteUser and audits user.delete', async () => {
    const state = await userAction(initialUserActionState, form(TARGET, 'delete'))

    expect(deleteUser).toHaveBeenCalledWith(TARGET)
    expect(writeAudit).toHaveBeenCalledWith({
      actor: ACTOR,
      action: 'user.delete',
      target: TARGET,
    })
    expect(state.status).toBe('success')
  })

  it('refuses to act on the acting admin, before touching the SDK', async () => {
    const state = await userAction(initialUserActionState, form(ACTOR, 'ban'))

    expect(state.status).toBe('error')
    expect(state.message).toMatch(/Kendi hesabınız/)
    expect(updateUserById).not.toHaveBeenCalled()
    expect(deleteUser).not.toHaveBeenCalled()
    expect(writeAudit).not.toHaveBeenCalled()
  })

  it('refuses to delete another admin and names the SQL escape hatch', async () => {
    const state = await userAction(initialUserActionState, form(OTHER_ADMIN, 'delete'))

    expect(state.status).toBe('error')
    expect(state.message).toMatch(/admin_users/)
    expect(deleteUser).not.toHaveBeenCalled()
    expect(writeAudit).not.toHaveBeenCalled()
  })

  it('takes the actor from requireAdmin, never from the form body', async () => {
    const data = form(TARGET, 'ban')
    data.set('actor', OTHER_ADMIN)

    await userAction(initialUserActionState, data)

    expect(writeAudit).toHaveBeenCalledWith(
      expect.objectContaining({ actor: ACTOR, target: TARGET }),
    )
  })

  it('rejects a malformed request without calling anything privileged', async () => {
    const state = await userAction(initialUserActionState, form('not-a-uuid', 'ban'))

    expect(state.status).toBe('error')
    expect(fetchAdminUserIds).not.toHaveBeenCalled()
    expect(updateUserById).not.toHaveBeenCalled()
  })

  it('rejects an unknown intent', async () => {
    const state = await userAction(initialUserActionState, form(TARGET, 'promote'))

    expect(state.status).toBe('error')
    expect(updateUserById).not.toHaveBeenCalled()
    expect(deleteUser).not.toHaveBeenCalled()
  })

  it('fails closed when the admin list cannot be read', async () => {
    fetchAdminUserIds.mockRejectedValue(new Error('Yönetici listesi okunamadı: boom'))

    const state = await userAction(initialUserActionState, form(TARGET, 'delete'))

    expect(state.status).toBe('error')
    expect(deleteUser).not.toHaveBeenCalled()
    expect(writeAudit).not.toHaveBeenCalled()
  })

  it('reports a Supabase failure in Turkish without auditing it', async () => {
    updateUserById.mockResolvedValue({ data: { user: null }, error: { message: 'User not found' } })

    const state = await userAction(initialUserActionState, form(TARGET, 'ban'))

    expect(state.status).toBe('error')
    expect(state.message).toBe('Kullanıcı yasaklanamadı: User not found')
    expect(writeAudit).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })

  it('reports a failed audit write as such, not as a failed operation', async () => {
    writeAudit.mockRejectedValue(new Error('audit down'))

    const state = await userAction(initialUserActionState, form(TARGET, 'ban'))

    expect(deleteUser).not.toHaveBeenCalled()
    expect(state.status).toBe('error')
    expect(state.message).toMatch(/denetim kaydı yazılamadı/i)
    expect(revalidatePath).toHaveBeenCalledWith('/users')
  })
})
