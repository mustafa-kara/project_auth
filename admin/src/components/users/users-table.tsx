'use client'

import Link from 'next/link'
import { useMemo, useState } from 'react'

import { UserRowActions } from '@/components/users/user-row-actions'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { filterRowsByEmail, formatDateTime, type UsersPage } from '@/lib/users'

export function UsersTable({ page }: { page: UsersPage }) {
  const [query, setQuery] = useState('')

  const rows = useMemo(() => filterRowsByEmail(page.rows, query), [page.rows, query])

  const prevPage = page.page > 1 ? page.page - 1 : null

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label htmlFor="user-search">E-posta ara</Label>
        <Input
          id="user-search"
          type="search"
          inputMode="email"
          placeholder="ornek@alan.com"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          aria-describedby="user-search-help"
          className="max-w-sm"
        />
        <p id="user-search-help" className="text-muted-foreground text-xs">
          Arama <strong>yalnızca bu sayfadaki</strong> {page.rows.length} kayıt üzerinde çalışır.
          Supabase <code>auth.admin.listUsers</code> uç noktası yalnızca <code>page</code> /{' '}
          <code>perPage</code> alır; sunucu tarafı e-posta filtresi yoktur. Diğer sayfalarda aramak
          için önce sayfayı değiştirin.
        </p>
      </div>

      <div className="overflow-x-auto rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>E-posta</TableHead>
              <TableHead>Kayıt</TableHead>
              <TableHead>Son giriş</TableHead>
              <TableHead>Sağlayıcı</TableHead>
              <TableHead>Durum</TableHead>
              <TableHead className="text-right">İşlemler</TableHead>
            </TableRow>
          </TableHeader>

          <TableBody>
            {rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={6} className="text-muted-foreground py-8 text-center text-sm">
                  {page.rows.length === 0
                    ? 'Bu sayfada kullanıcı yok.'
                    : 'Bu sayfada aramanızla eşleşen kullanıcı yok.'}
                </TableCell>
              </TableRow>
            ) : (
              rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="font-medium">
                    <div className="flex items-center gap-2">
                      <span className="truncate">{row.email ?? '—'}</span>
                      {row.isAdmin ? <Badge variant="secondary">Yönetici</Badge> : null}
                      {row.isSelf ? <Badge variant="outline">Siz</Badge> : null}
                    </div>
                  </TableCell>
                  <TableCell className="whitespace-nowrap">
                    {formatDateTime(row.createdAt)}
                  </TableCell>
                  <TableCell className="whitespace-nowrap">
                    {formatDateTime(row.lastSignInAt)}
                  </TableCell>
                  <TableCell>
                    {row.providers.length === 0 ? (
                      <span className="text-muted-foreground">—</span>
                    ) : (
                      <div className="flex flex-wrap gap-1">
                        {row.providers.map((provider) => (
                          <Badge key={provider} variant="outline">
                            {provider}
                          </Badge>
                        ))}
                      </div>
                    )}
                  </TableCell>
                  <TableCell className="whitespace-nowrap">
                    {row.status === 'banned' ? (
                      <Badge variant="destructive" title={`Bitiş: ${formatDateTime(row.bannedUntil)}`}>
                        Yasaklı
                      </Badge>
                    ) : (
                      <Badge variant="secondary">Aktif</Badge>
                    )}
                  </TableCell>
                  <TableCell className="text-right">
                    <UserRowActions row={row} />
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-muted-foreground text-xs">
          Sayfa {page.page} / {Math.max(page.lastPage, page.page)} — bu sayfada {page.rows.length}{' '}
          kayıt, toplam {page.total} kullanıcı.
        </p>

        <div className="flex gap-2">
          {prevPage === null ? (
            <Button variant="outline" size="sm" disabled>
              Önceki
            </Button>
          ) : (
            <Button asChild variant="outline" size="sm">
              <Link href={`/users?page=${prevPage}`}>Önceki</Link>
            </Button>
          )}

          {page.nextPage === null ? (
            <Button variant="outline" size="sm" disabled>
              Sonraki
            </Button>
          ) : (
            <Button asChild variant="outline" size="sm">
              <Link href={`/users?page=${page.nextPage}`}>Sonraki</Link>
            </Button>
          )}
        </div>
      </div>
    </div>
  )
}
