'use server'

import { revalidatePath } from 'next/cache'
import { z } from 'zod'

import { writeAudit, type AuditEntry } from '@/lib/audit'
import { requireAdmin } from '@/lib/auth'
import { catalogInputSchema } from '@/lib/catalog'
import { createAdminClient } from '@/lib/supabase/admin'

/**
 * Write path for `public.catalog_services` — access path (b), secret key.
 * `requireAdmin()` runs first and outside the try/catch (see the announcements
 * actions for why).
 */

export type ActionState =
  | { status: 'idle' }
  | { status: 'success'; message: string }
  | { status: 'error'; message: string }

export const initialActionState: ActionState = { status: 'idle' }

const idSchema = z.uuid({ message: 'Geçersiz servis kimliği.' })

function firstIssue(error: z.ZodError, fallback: string): string {
  return error.issues[0]?.message ?? fallback
}

function failure(context: string, cause: unknown, message: string): ActionState {
  console.error(`[catalog] ${context}`, cause)
  return { status: 'error', message }
}

/** An audit failure is not a write failure — the row already landed. */
async function auditThen(entry: AuditEntry, successMessage: string): Promise<ActionState> {
  try {
    await writeAudit(entry)
  } catch (cause) {
    console.error(`[catalog] audit:${entry.action}`, cause)
    return { status: 'error', message: `${successMessage} Ancak denetim kaydı yazılamadı.` }
  }
  return { status: 'success', message: successMessage }
}

function readInput(formData: FormData) {
  return catalogInputSchema.safeParse({
    name: formData.get('name'),
    issuer: formData.get('issuer'),
    logo_url: formData.get('logo_url'),
  })
}

export async function createCatalogServiceAction(
  _prevState: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const admin = await requireAdmin()

  const parsed = readInput(formData)
  if (!parsed.success) {
    return { status: 'error', message: firstIssue(parsed.error, 'Servis bilgileri geçersiz.') }
  }

  let createdId: string | null = null
  try {
    const supabase = createAdminClient()
    const { data, error } = await supabase
      .from('catalog_services')
      .insert(parsed.data)
      .select('id')
      .single()

    if (error) throw error
    createdId = typeof data?.id === 'string' ? data.id : null
  } catch (cause) {
    return failure('create', cause, 'Servis eklenemedi.')
  }

  revalidatePath('/catalog')
  return auditThen(
    { actor: admin.userId, action: 'catalog.create', target: createdId },
    'Servis eklendi.',
  )
}

export async function updateCatalogServiceAction(
  _prevState: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const admin = await requireAdmin()

  const id = idSchema.safeParse(formData.get('id'))
  if (!id.success) {
    return { status: 'error', message: firstIssue(id.error, 'Geçersiz servis kimliği.') }
  }

  const parsed = readInput(formData)
  if (!parsed.success) {
    return { status: 'error', message: firstIssue(parsed.error, 'Servis bilgileri geçersiz.') }
  }

  try {
    const supabase = createAdminClient()
    const { error } = await supabase.from('catalog_services').update(parsed.data).eq('id', id.data)

    if (error) throw error
  } catch (cause) {
    return failure('update', cause, 'Servis güncellenemedi.')
  }

  revalidatePath('/catalog')
  return auditThen(
    { actor: admin.userId, action: 'catalog.update', target: id.data },
    'Servis güncellendi.',
  )
}

export async function deleteCatalogServiceAction(rawId: string): Promise<ActionState> {
  const admin = await requireAdmin()

  const id = idSchema.safeParse(rawId)
  if (!id.success) {
    return { status: 'error', message: firstIssue(id.error, 'Geçersiz servis kimliği.') }
  }

  try {
    const supabase = createAdminClient()
    const { error } = await supabase.from('catalog_services').delete().eq('id', id.data)

    if (error) throw error
  } catch (cause) {
    return failure('delete', cause, 'Servis silinemedi.')
  }

  revalidatePath('/catalog')
  return auditThen(
    { actor: admin.userId, action: 'catalog.delete', target: id.data },
    'Servis silindi.',
  )
}
