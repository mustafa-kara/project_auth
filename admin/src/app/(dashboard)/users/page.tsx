import { UsersTable } from '@/components/users/users-table'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { requireAdmin } from '@/lib/auth'
import { parsePageParam, USERS_PER_PAGE } from '@/lib/users'

import { loadUsersPage } from './data'

export const dynamic = 'force-dynamic'

export const metadata = { title: 'Kullanıcılar — Yönetim Paneli' }

export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>
}) {
  // The (dashboard) layout guards this route too; repeated deliberately — the guard
  // belongs in every handler that reaches privileged data, not only in the shell.
  const admin = await requireAdmin()

  const page = parsePageParam((await searchParams).page)
  const result = await loadUsersPage(page, admin.userId)

  return (
    <div className="mx-auto flex max-w-6xl flex-col gap-6">
      <div>
        <h1 className="text-2xl font-semibold">Kullanıcılar</h1>
        <p className="text-muted-foreground text-sm">
          Yalnızca hesap üst verisi listelenir ({USERS_PER_PAGE} kayıt/sayfa). Uçtan uca şifreleme
          nedeniyle jeton içerikleri panele hiçbir yoldan açılmaz.
        </p>
      </div>

      {result.ok ? (
        <UsersTable page={result.data} />
      ) : (
        <Card role="alert" className="border-destructive/50">
          <CardHeader>
            <CardTitle className="text-destructive">Kullanıcı listesi alınamadı</CardTitle>
            <CardDescription>
              Supabase Auth yönetim API&apos;si (<code>auth.admin.listUsers</code>) yanıt vermedi.
              <code className="mx-1">SUPABASE_SECRET_KEY</code> geçerli mi ve sunucu Supabase&apos;e
              ulaşabiliyor mu kontrol edin.
            </CardDescription>
          </CardHeader>
          <CardContent className="text-muted-foreground font-mono text-xs break-words">
            {result.message}
          </CardContent>
        </Card>
      )}
    </div>
  )
}
