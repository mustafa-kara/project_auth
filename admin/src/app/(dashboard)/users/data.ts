import 'server-only'

import { createAdminClient } from '@/lib/supabase/admin'
import {
  buildUsersPage,
  summariseError,
  USERS_PER_PAGE,
  type UsersPage,
} from '@/lib/users'

/**
 * Access path (b) — the secret key. Only `auth.admin.listUsers` and a metadata read
 * of `public.admin_users`; never `tokens` / `key_attributes`.
 */

/**
 * `public.admin_users` has RLS on with no policy for `authenticated`, so it is only
 * readable with the secret-key client (RLS bypass).
 *
 * Throws on failure ON PURPOSE: the ban/delete guard depends on this set, so an
 * unreadable admin list must fail closed rather than silently allow acting on an
 * admin.
 */
export async function fetchAdminUserIds(): Promise<Set<string>> {
  const supabase = createAdminClient()
  const { data, error } = await supabase.from('admin_users').select('user_id')

  if (error) {
    throw new Error(`Yönetici listesi okunamadı: ${error.message}`)
  }

  return new Set((data ?? []).map((row) => String((row as { user_id: string }).user_id)))
}

export type UsersPageResult = { ok: true; data: UsersPage } | { ok: false; message: string }

export async function loadUsersPage(page: number, actorId: string): Promise<UsersPageResult> {
  try {
    const supabase = createAdminClient()
    const adminIds = await fetchAdminUserIds()

    const { data, error } = await supabase.auth.admin.listUsers({
      page,
      perPage: USERS_PER_PAGE,
    })

    if (error) {
      return { ok: false, message: summariseError(error) }
    }

    return {
      ok: true,
      data: buildUsersPage(data, page, { adminIds, actorId }),
    }
  } catch (error) {
    return { ok: false, message: summariseError(error) }
  }
}
