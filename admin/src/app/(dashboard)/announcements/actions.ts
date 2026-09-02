'use server'

import { revalidatePath } from 'next/cache'
import { z } from 'zod'

import { announcementInputSchema } from '@/lib/announcements'
import { writeAudit, type AuditEntry } from '@/lib/audit'
import { requireAdmin } from '@/lib/auth'
import { createAdminClient } from '@/lib/supabase/admin'

/**
 * Write path for `public.announcements` — access path (b).
 *
 * The table has no INSERT/UPDATE/DELETE grant for `authenticated` by design, so
 * every mutation goes through the secret-key client. `requireAdmin()` runs FIRST
 * and outside the try/catch: a Server Function is a POST to the page route, the
 * proxy is not a sufficient guard on its own, and the `redirect()` it may throw
 * must not be swallowed as a database failure.
 */

export type ActionState =
  | { status: 'idle' }
  | { status: 'success'; message: string }
  | { status: 'error'; message: string }

export const initialActionState: ActionState = { status: 'idle' }

const idSchema = z.uuid({ message: 'Geçersiz duyuru kimliği.' })

function firstIssue(error: z.ZodError, fallback: string): string {
  return error.issues[0]?.message ?? fallback
}

/** Never surface a driver message to the browser — it can carry column/constraint detail. */
function failure(context: string, cause: unknown, message: string): ActionState {
  console.error(`[announcements] ${context}`, cause)
  return { status: 'error', message }
}

/**
 * The row is already written by the time this runs, so an audit failure must not be
 * reported as "the operation failed" — it is a separate, louder problem.
 */
async function auditThen(entry: AuditEntry, successMessage: string): Promise<ActionState> {
  try {
    await writeAudit(entry)
  } catch (cause) {
    console.error(`[announcements] audit:${entry.action}`, cause)
    return { status: 'error', message: `${successMessage} Ancak denetim kaydı yazılamadı.` }
  }
  return { status: 'success', message: successMessage }
}

/**
 * PostgREST answers a PATCH/DELETE that matched **zero** rows with `204 No Content`
 * and no error, so postgrest-js hands back `{ data: null, error: null }`. Without
 * asking for the affected rows back (`.select('id')`) the panel would report a
 * success, revalidate, and write an `announcement.update`/`.delete` audit row for
 * something that never happened — an audit trail whose whole job is attribution.
 */
const NOT_FOUND_MESSAGE = 'Duyuru bulunamadı (başka bir yönetici silmiş olabilir).'

function affectedRowCount(data: unknown): number {
  return Array.isArray(data) ? data.length : 0
}

function readInput(formData: FormData) {
  return announcementInputSchema.safeParse({
    title: formData.get('title'),
    body: formData.get('body'),
    audience: formData.get('audience'),
  })
}

export async function createAnnouncementAction(
  _prevState: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const admin = await requireAdmin()

  const parsed = readInput(formData)
  if (!parsed.success) {
    return { status: 'error', message: firstIssue(parsed.error, 'Duyuru bilgileri geçersiz.') }
  }

  let createdId: string | null = null
  try {
    const supabase = createAdminClient()
    const { data, error } = await supabase
      .from('announcements')
      .insert(parsed.data)
      .select('id')
      .single()

    if (error) throw error
    createdId = typeof data?.id === 'string' ? data.id : null
  } catch (cause) {
    return failure('create', cause, 'Duyuru oluşturulamadı.')
  }

  revalidatePath('/announcements')
  return auditThen(
    { actor: admin.userId, action: 'announcement.create', target: createdId },
    'Duyuru oluşturuldu.',
  )
}

export async function updateAnnouncementAction(
  _prevState: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const admin = await requireAdmin()

  const id = idSchema.safeParse(formData.get('id'))
  if (!id.success) {
    return { status: 'error', message: firstIssue(id.error, 'Geçersiz duyuru kimliği.') }
  }

  const parsed = readInput(formData)
  if (!parsed.success) {
    return { status: 'error', message: firstIssue(parsed.error, 'Duyuru bilgileri geçersiz.') }
  }

  let affected = 0
  try {
    const supabase = createAdminClient()
    const { data, error } = await supabase
      .from('announcements')
      .update(parsed.data)
      .eq('id', id.data)
      .select('id')

    if (error) throw error
    affected = affectedRowCount(data)
  } catch (cause) {
    return failure('update', cause, 'Duyuru güncellenemedi.')
  }

  // Before revalidate and before the audit write: nothing happened.
  if (affected === 0) {
    return { status: 'error', message: NOT_FOUND_MESSAGE }
  }

  revalidatePath('/announcements')
  return auditThen(
    { actor: admin.userId, action: 'announcement.update', target: id.data },
    'Duyuru güncellendi.',
  )
}

/** Called from a confirmation dialog, not a form — the id is still validated here. */
export async function deleteAnnouncementAction(rawId: string): Promise<ActionState> {
  const admin = await requireAdmin()

  const id = idSchema.safeParse(rawId)
  if (!id.success) {
    return { status: 'error', message: firstIssue(id.error, 'Geçersiz duyuru kimliği.') }
  }

  let affected = 0
  try {
    const supabase = createAdminClient()
    const { data, error } = await supabase
      .from('announcements')
      .delete()
      .eq('id', id.data)
      .select('id')

    if (error) throw error
    affected = affectedRowCount(data)
  } catch (cause) {
    return failure('delete', cause, 'Duyuru silinemedi.')
  }

  if (affected === 0) {
    return { status: 'error', message: NOT_FOUND_MESSAGE }
  }

  revalidatePath('/announcements')
  return auditThen(
    { actor: admin.userId, action: 'announcement.delete', target: id.data },
    'Duyuru silindi.',
  )
}
