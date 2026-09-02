import 'server-only'

import { createAdminClient } from '@/lib/supabase/admin'

/**
 * Every privileged operation the panel performs writes exactly one `audit_logs`
 * row, in the same handler that performed it.
 *
 * `public.audit_logs` has no INSERT policy, so this must go through the secret-key
 * client (access path (b)). Shape: `id, actor uuid, action text, target text, created_at`.
 */
export const AUDIT_ACTIONS = [
  'user.ban',
  'user.unban',
  'user.delete',
  'announcement.create',
  'announcement.update',
  'announcement.delete',
  'catalog.create',
  'catalog.update',
  'catalog.delete',
  'flag.update',
] as const

export type AuditAction = (typeof AUDIT_ACTIONS)[number]

export interface AuditEntry {
  /** `auth.users.id` of the acting admin — from `requireAdmin()`, never from the request body. */
  actor: string
  action: AuditAction
  /** Free-form subject of the action (a user id, an announcement id, a flag key…). */
  target?: string | null
}

export async function writeAudit({ actor, action, target = null }: AuditEntry): Promise<void> {
  const supabase = createAdminClient()
  const { error } = await supabase.from('audit_logs').insert({ actor, action, target })

  if (error) {
    throw new Error(`Denetim kaydı yazılamadı (${action}): ${error.message}`)
  }
}
