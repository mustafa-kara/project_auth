import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { requireAdmin } from '@/lib/auth'

export default async function DashboardPage() {
  await requireAdmin()

  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-6">
      <div>
        <h1 className="text-2xl font-semibold">Panel</h1>
        <p className="text-muted-foreground text-sm">
          Uçtan uca şifreleme nedeniyle panel hiçbir TOTP sırrını göremez; yalnızca üst veri ve
          sayımlar gösterilir.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            Genel istatistikler
            <Badge variant="secondary">Yakında</Badge>
          </CardTitle>
          <CardDescription>
            Kullanıcı, jeton ve cihaz sayıları doğrudan Postgres bağlantısı üzerinden
            <code className="mx-1">private.admin_global_stats()</code> ile okunacak.
          </CardDescription>
        </CardHeader>
        <CardContent className="text-muted-foreground text-sm">
          Bu bölüm bir sonraki aşamada dolduruluyor.
        </CardContent>
      </Card>
    </div>
  )
}
