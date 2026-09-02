'use server'

import { revalidatePath } from 'next/cache'
import { z } from 'zod'

import { writeAudit, type AuditAction } from '@/lib/audit'
import { requireAdmin } from '@/lib/auth'
import { createAdminClient } from '@/lib/supabase/admin'
import {
  BAN_DURATION_FOREVER,
  BAN_DURATION_NONE,
  checkUserActionAllowed,
  describeActionError,
  summariseError,
  type UserActionIntent,
} from '@/lib/users'

import { fetchAdminUserIds } from './data'

export interface UserActionState {
  status: 'idle' | 'success' | 'error'
  message: string | null
}

export const initialUserActionState: UserActionState = { status: 'idle', message: null }

const requestSchema = z.object({
  userId: z.uuid({ message: 'Geçersiz kullanıcı kimliği.' }),
  intent: z.enum(['ban', 'unban', 'delete'], { message: 'Geçersiz işlem.' }),
})

const AUDIT_ACTION_BY_INTENT: Record<UserActionIntent, AuditAction> = {
  ban: 'user.ban',
  unban: 'user.unban',
  delete: 'user.delete',
}

const SUCCESS_MESSAGE: Record<UserActionIntent, string> = {
  ban: 'Kullanıcı yasaklandı.',
  unban: 'Kullanıcının yasağı kaldırıldı.',
  delete: 'Kullanıcı ve ilişkili tüm şifreli verileri silindi.',
}

/**
 * The single privileged entry point for /users.
 *
 * Order matters and is enforced HERE, not in the UI (a Server Function is a POST to
 * the page route; the proxy alone is never the authorization boundary):
 *   1. `requireAdmin()` — JWKS-verified `app_metadata.admin === true`.
 *   2. Validate the request body.
 *   3. Read `public.admin_users` (fails closed if unreadable).
 *   4. `checkUserActionAllowed()` — no self-service, no acting on another admin.
 *   5. Perform the `auth.admin` call (access path (b)).
 *   6. `writeAudit()` with the actor from step 1 — never from the form.
 */
export async function userAction(
  _prevState: UserActionState,
  formData: FormData,
): Promise<UserActionState> {
  const admin = await requireAdmin()

  const parsed = requestSchema.safeParse({
    userId: formData.get('userId'),
    intent: formData.get('intent'),
  })

  if (!parsed.success) {
    return { status: 'error', message: parsed.error.issues[0]?.message ?? 'Geçersiz istek.' }
  }

  const { userId, intent } = parsed.data

  let adminIds: ReadonlySet<string>
  try {
    adminIds = await fetchAdminUserIds()
  } catch (error) {
    return { status: 'error', message: summariseError(error) }
  }

  const verdict = checkUserActionAllowed({ actorId: admin.userId, targetId: userId, adminIds })
  if (!verdict.allowed) {
    return { status: 'error', message: verdict.message }
  }

  const supabase = createAdminClient()

  try {
    if (intent === 'delete') {
      const { error } = await supabase.auth.admin.deleteUser(userId)
      if (error) return { status: 'error', message: describeActionError(intent, error) }
    } else {
      const { error } = await supabase.auth.admin.updateUserById(userId, {
        ban_duration: intent === 'ban' ? BAN_DURATION_FOREVER : BAN_DURATION_NONE,
      })
      if (error) return { status: 'error', message: describeActionError(intent, error) }
    }
  } catch (error) {
    return { status: 'error', message: describeActionError(intent, error) }
  }

  // The operation already happened; a failed audit write is reported as such rather
  // than as a failed operation, so the discrepancy is visible instead of silent.
  try {
    await writeAudit({
      actor: admin.userId,
      action: AUDIT_ACTION_BY_INTENT[intent],
      target: userId,
    })
  } catch (error) {
    revalidatePath('/users')
    return {
      status: 'error',
      message: `${SUCCESS_MESSAGE[intent]} Ancak denetim kaydı yazılamadı: ${summariseError(error)}`,
    }
  }

  revalidatePath('/users')

  return { status: 'success', message: SUCCESS_MESSAGE[intent] }
}
