import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatDateTime } from '@/lib/users'
import type { GlobalStatsResult } from '@/lib/stats'

const numberFormat = new Intl.NumberFormat('tr-TR')

const CARDS = [
  {
    key: 'total_users',
    title: 'Kullanıcı',
    description: 'Kayıtlı hesap sayısı',
  },
  {
    key: 'total_tokens',
    title: 'Jeton',
    description: 'Şifreli TOTP kaydı sayısı (içerik görünmez)',
  },
  {
    key: 'total_devices',
    title: 'Cihaz',
    description: 'Kayıtlı cihaz sayısı',
  },
] as const

/**
 * Access path (a) output. On failure the panel must stay usable, so the error is
 * rendered as a card instead of throwing through the layout.
 */
export function GlobalStatsCards({ result }: { result: GlobalStatsResult }) {
  if (!result.ok) {
    return (
      <Card role="alert" className="border-destructive/50">
        <CardHeader>
          <CardTitle className="text-destructive">Genel istatistikler okunamadı</CardTitle>
          <CardDescription>
            Sayımlar doğrudan Postgres bağlantısı üzerinden{' '}
            <code>private.admin_global_stats()</code> ile okunur. Sık nedenler:{' '}
            <code>DATABASE_URL</code> tanımlı değil, operatör <code>admin_app</code> login rolünü
            oluşturmadı, <code>admin_backend</code> rolü verilmedi ya da havuza (pooler)
            ulaşılamıyor. Panelin geri kalanı çalışmaya devam eder.
          </CardDescription>
        </CardHeader>
        <CardContent className="text-muted-foreground font-mono text-xs break-words">
          {result.message}
        </CardContent>
      </Card>
    )
  }

  const { stats } = result

  return (
    <div className="flex flex-col gap-2">
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {CARDS.map((card) => (
          <Card key={card.key}>
            <CardHeader>
              <CardDescription>{card.title}</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {numberFormat.format(stats[card.key])}
              </CardTitle>
            </CardHeader>
            <CardContent className="text-muted-foreground text-xs">{card.description}</CardContent>
          </Card>
        ))}
      </div>

      <p className="text-muted-foreground text-xs">
        Üretim zamanı: {formatDateTime(stats.generated_at)}
      </p>
    </div>
  )
}
