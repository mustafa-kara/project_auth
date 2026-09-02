import { AdminNav } from '@/components/admin-nav'
import { SignOutButton } from '@/components/sign-out-button'
import { Separator } from '@/components/ui/separator'
import { requireAdmin } from '@/lib/auth'

/**
 * Authenticated shell. Every route under `src/app/(dashboard)/` is guarded here
 * AND must call `requireAdmin()` again in its own server action / route handler
 * before any privileged operation.
 */
/**
 * Never prerendered: every render depends on the caller's session cookie, and
 * env validation happens at request time so `next build` needs no real secrets.
 */
export const dynamic = 'force-dynamic'

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const admin = await requireAdmin()

  return (
    <div className="flex min-h-full flex-1">
      <aside className="bg-sidebar text-sidebar-foreground hidden w-60 shrink-0 flex-col gap-4 border-r p-4 md:flex">
        <div>
          <p className="text-sm font-semibold">Yönetim Paneli</p>
          <p className="text-muted-foreground truncate text-xs">{admin.email ?? admin.userId}</p>
        </div>
        <Separator />
        <AdminNav />
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center justify-between gap-4 border-b px-6 py-3">
          <span className="text-sm font-medium md:hidden">Yönetim Paneli</span>
          <div className="ml-auto">
            <SignOutButton />
          </div>
        </header>
        <main className="flex-1 p-6">{children}</main>
      </div>
    </div>
  )
}
