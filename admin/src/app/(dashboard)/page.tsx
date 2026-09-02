import { GlobalStatsCards } from '@/components/dashboard/global-stats-cards'
import { RecentAuditCard } from '@/components/dashboard/recent-audit-card'
import { requireAdmin } from '@/lib/auth'
import { loadGlobalStats } from '@/lib/stats'

export const dynamic = 'force-dynamic'

export default async function DashboardPage() {
  await requireAdmin()

  // Path (a) — direct Postgres. Never throws: a failure becomes an error card so the
  // audit tail (path (c)) and the rest of the shell keep working.
  const stats = await loadGlobalStats()

  return (
    <div className="mx-auto flex max-w-5xl flex-col gap-6">
      <div>
        <h1 className="text-2xl font-semibold">Panel</h1>
        <p className="text-muted-foreground text-sm">
          Uçtan uca şifreleme nedeniyle panel hiçbir TOTP sırrını göremez; yalnızca üst veri ve
          sayımlar gösterilir.
        </p>
      </div>

      <GlobalStatsCards result={stats} />

      <RecentAuditCard />
    </div>
  )
}
