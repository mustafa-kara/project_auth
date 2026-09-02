'use server'

import { revalidatePath } from 'next/cache'
import { z } from 'zod'

import { writeAudit, type AuditEntry } from '@/lib/audit'
import { requireAdmin } from '@/lib/auth'
import {
  flagAuditTarget,
  flagCreateSchema,
  flagDeleteSchema,
  flagPayloadUpdateSchema,
  flagToggleSchema,
} from '@/lib/flags'
import { createAdminClient } from '@/lib/supabase/admin'

/**
 * Write path for `public.feature_flags` — access path (b), secret key.
 *
 * All four operations share the single `flag.update` audit action, so the audited
 * `target` carries the key *and* the operation (`token_sync_enabled:disable`) —
 * see `flagAuditTarget`. `requireAdmin()` runs first and outside the try/catch.
 */

export type ActionState =
  | { status: 'idle' }
  | { status: 'success'; message: string }
  | { status: 'error'; message: string }

export const initialActionState: ActionState = { status: 'idle' }

function firstIssue(error: z.ZodError, fallback: string): string {
  return error.issues[0]?.message ?? fallback
}

function failure(context: string, cause: unknown, message: string): ActionState {
  console.error(`[flags] ${context}`, cause)
  return { status: 'error', message }
}

/** An audit failure is not a write failure — the flag already changed. */
async function auditThen(entry: AuditEntry, successMessage: string): Promise<ActionState> {
  try {
    await writeAudit(entry)
  } catch (cause) {
    console.error(`[flags] audit:${entry.target}`, cause)
    return { status: 'error', message: `${successMessage} Ancak denetim kaydı yazılamadı.` }
  }
  return { status: 'success', message: successMessage }
}

/**
 * PostgREST returns `204 No Content` and no error for a PATCH/DELETE that matched
 * zero rows, so the affected rows have to be requested back (`.select('key')`).
 * Without it a server action — which is just a POST with an arbitrary body — could
 * be used to mint `flag.update` audit rows for keys that do not exist, and the
 * `trg_feature_flags_touch` trigger never fires either, so not even `updated_at`
 * moves.
 */
const NOT_FOUND_MESSAGE = 'Bayrak bulunamadı (başka bir yönetici silmiş olabilir).'

function affectedRowCount(data: unknown): number {
  return Array.isArray(data) ? data.length : 0
}

export async function createFlagAction(
  _prevState: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const admin = await requireAdmin()

  const parsed = flagCreateSchema.safeParse({
    key: formData.get('key'),
    enabled: formData.get('enabled') === 'true',
    payload: formData.get('payload') ?? '',
  })
  if (!parsed.success) {
    return { status: 'error', message: firstIssue(parsed.error, 'Bayrak bilgileri geçersiz.') }
  }

  try {
    const supabase = createAdminClient()
    const { error } = await supabase.from('feature_flags').insert(parsed.data)

    if (error) {
      // 23505 = unique_violation on the `key` primary key; safe and useful to name.
      if (error.code === '23505') {
        return { status: 'error', message: 'Bu anahtar zaten var.' }
      }
      throw error
    }
  } catch (cause) {
    return failure('create', cause, 'Bayrak oluşturulamadı.')
  }

  revalidatePath('/flags')
  return auditThen(
    {
      actor: admin.userId,
      action: 'flag.update',
      target: flagAuditTarget(parsed.data.key, 'create'),
    },
    'Bayrak oluşturuldu.',
  )
}

/** Called from the row switch (with a confirmation dialog for the kill switch). */
export async function toggleFlagAction(rawKey: string, enabled: boolean): Promise<ActionState> {
  const admin = await requireAdmin()

  const parsed = flagToggleSchema.safeParse({ key: rawKey, enabled })
  if (!parsed.success) {
    return { status: 'error', message: firstIssue(parsed.error, 'Bayrak bilgileri geçersiz.') }
  }

  let affected = 0
  try {
    const supabase = createAdminClient()
    const { data, error } = await supabase
      .from('feature_flags')
      .update({ enabled: parsed.data.enabled })
      .eq('key', parsed.data.key)
      .select('key')

    if (error) throw error
    affected = affectedRowCount(data)
  } catch (cause) {
    return failure('toggle', cause, 'Bayrak durumu değiştirilemedi.')
  }

  // Before revalidate and before the audit write: nothing happened.
  if (affected === 0) {
    return { status: 'error', message: NOT_FOUND_MESSAGE }
  }

  revalidatePath('/flags')
  return auditThen(
    {
      actor: admin.userId,
      action: 'flag.update',
      target: flagAuditTarget(parsed.data.key, parsed.data.enabled ? 'enable' : 'disable'),
    },
    parsed.data.enabled ? 'Bayrak açıldı.' : 'Bayrak kapatıldı.',
  )
}

export async function updateFlagPayloadAction(
  _prevState: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const admin = await requireAdmin()

  const parsed = flagPayloadUpdateSchema.safeParse({
    key: formData.get('key'),
    payload: formData.get('payload') ?? '',
  })
  if (!parsed.success) {
    return { status: 'error', message: firstIssue(parsed.error, 'Payload geçersiz.') }
  }

  let affected = 0
  try {
    const supabase = createAdminClient()
    const { data, error } = await supabase
      .from('feature_flags')
      .update({ payload: parsed.data.payload })
      .eq('key', parsed.data.key)
      .select('key')

    if (error) throw error
    affected = affectedRowCount(data)
  } catch (cause) {
    return failure('payload', cause, 'Payload kaydedilemedi.')
  }

  if (affected === 0) {
    return { status: 'error', message: NOT_FOUND_MESSAGE }
  }

  revalidatePath('/flags')
  return auditThen(
    {
      actor: admin.userId,
      action: 'flag.update',
      target: flagAuditTarget(parsed.data.key, 'payload'),
    },
    'Payload kaydedildi.',
  )
}

/**
 * `token_sync_enabled` is rejected by `flagDeleteSchema`: a missing row makes the
 * client fall back to `true`, so deleting the kill switch silently *enables* sync.
 */
export async function deleteFlagAction(rawKey: string): Promise<ActionState> {
  const admin = await requireAdmin()

  const parsed = flagDeleteSchema.safeParse({ key: rawKey })
  if (!parsed.success) {
    return { status: 'error', message: firstIssue(parsed.error, 'Bayrak silinemez.') }
  }

  let affected = 0
  try {
    const supabase = createAdminClient()
    const { data, error } = await supabase
      .from('feature_flags')
      .delete()
      .eq('key', parsed.data.key)
      .select('key')

    if (error) throw error
    affected = affectedRowCount(data)
  } catch (cause) {
    return failure('delete', cause, 'Bayrak silinemedi.')
  }

  if (affected === 0) {
    return { status: 'error', message: NOT_FOUND_MESSAGE }
  }

  revalidatePath('/flags')
  return auditThen(
    {
      actor: admin.userId,
      action: 'flag.update',
      target: flagAuditTarget(parsed.data.key, 'delete'),
    },
    'Bayrak silindi.',
  )
}
