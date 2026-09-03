import type { Metadata } from 'next'
import Link from 'next/link'

import { DeleteFlagDialog } from '@/components/flags/delete-flag-dialog'
import { FlagCreateDialog } from '@/components/flags/flag-create-dialog'
import { FlagPayloadDialog } from '@/components/flags/flag-payload-dialog'
import { FlagToggle } from '@/components/flags/flag-toggle'
import { TablePagination } from '@/components/table-pagination'
import { Badge } from '@/components/ui/badge'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { formatDateTime } from '@/lib/announcements'
import { requireAdmin } from '@/lib/auth'
import { mapFlagRows, TOKEN_SYNC_FLAG_KEY, TOKEN_SYNC_WARNING } from '@/lib/flags'
import {
  hasNextPage,
  pageCount,
  pageHref,
  pageRange,
  parsePage,
  type SearchParamValue,
} from '@/lib/paging'
import { createClient } from '@/lib/supabase/server'

export const metadata: Metadata = { title: 'Bayraklar — Yönetim Paneli' }

/** Reads with access path (c); writes live in `./actions.ts` (path (b)). */
export default async function FlagsPage({
  searchParams,
}: {
  searchParams: Promise<{ page?: SearchParamValue }>
}) {
  await requireAdmin()

  const page = parsePage((await searchParams).page)
  const { from, to } = pageRange(page)

  const supabase = await createClient()
  const { data, count, error } = await supabase
    .from('feature_flags')
    .select('key,enabled,payload,updated_at', { count: 'exact' })
    // `key` is the primary key, so it is a total order on its own — no tiebreaker
    // column exists or is needed here.
    .order('key', { ascending: true })
    .range(from, to)

  const flags = mapFlagRows(data)
  const total = typeof count === 'number' ? count : null
  // From the raw response, not from `flags`: a row `mapFlagRow` quarantines still
  // occupies a slot in the page.
  const rowCount = (data ?? []).length
  const totalPages = pageCount(total ?? rowCount)
  const hasNext = hasNextPage(page, total, rowCount)

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Özellik bayrakları</h1>
          <p className="text-muted-foreground text-sm">
            İstemcinin bugün okuduğu tek anahtar <code>{TOKEN_SYNC_FLAG_KEY}</code>. Bilinmeyen
            anahtarlar istemcide yok sayılır.
          </p>
        </div>
        <FlagCreateDialog />
      </div>

      {error ? (
        <p role="alert" className="text-destructive text-sm">
          Bayraklar yüklenemedi. Lütfen sayfayı yenileyin.
        </p>
      ) : rowCount === 0 && page > 1 ? (
        <div className="rounded-lg border border-dashed p-10 text-center">
          <p className="text-sm font-medium">Bu sayfada kayıt yok</p>
          <p className="text-muted-foreground mt-1 text-sm">
            <Link href={pageHref('/flags', 1)} className="underline underline-offset-4">
              İlk sayfaya dön
            </Link>
          </p>
        </div>
      ) : flags.length === 0 ? (
        <div className="rounded-lg border border-dashed p-10 text-center">
          <p className="text-sm font-medium">Tanımlı bayrak yok</p>
          <p className="text-muted-foreground mt-1 text-sm">
            <code>{TOKEN_SYNC_FLAG_KEY}</code> satırı yokken istemciler token senkronunu açık
            varsayar.
          </p>
        </div>
      ) : (
        <div className="rounded-lg border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Anahtar</TableHead>
                <TableHead className="w-0">Durum</TableHead>
                <TableHead>Payload</TableHead>
                <TableHead>Güncelleme</TableHead>
                <TableHead className="w-0 text-right">İşlemler</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {flags.map((flag) => {
                const isKillSwitch = flag.key === TOKEN_SYNC_FLAG_KEY
                return (
                  <TableRow key={flag.key}>
                    <TableCell className="align-top">
                      <code className="text-sm font-medium">{flag.key}</code>
                      {isKillSwitch ? (
                        <div className="mt-1 flex flex-col items-start gap-1">
                          <Badge variant="destructive">Kill switch</Badge>
                          <p className="text-muted-foreground max-w-xs text-xs">
                            {TOKEN_SYNC_WARNING}
                          </p>
                        </div>
                      ) : null}
                    </TableCell>
                    <TableCell className="align-top">
                      <FlagToggle flag={flag} />
                    </TableCell>
                    <TableCell className="text-muted-foreground align-top text-xs">
                      {flag.payloadUnusable ? (
                        <Badge variant="outline" className="text-destructive">
                          JSON nesnesi değil
                        </Badge>
                      ) : flag.payload === null ? (
                        '—'
                      ) : (
                        <code className="line-clamp-2 break-all">
                          {JSON.stringify(flag.payload)}
                        </code>
                      )}
                    </TableCell>
                    <TableCell className="text-muted-foreground align-top text-sm whitespace-nowrap">
                      {flag.updatedAt === null ? '—' : formatDateTime(flag.updatedAt)}
                    </TableCell>
                    <TableCell className="align-top text-right whitespace-nowrap">
                      <FlagPayloadDialog flag={flag} />
                      {isKillSwitch ? null : <DeleteFlagDialog flag={flag} />}
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </div>
      )}

      {error ? null : (
        <TablePagination
          page={page}
          total={total}
          pageCount={totalPages}
          hasNext={hasNext}
          hrefForPage={(target) => pageHref('/flags', target)}
        />
      )}
    </div>
  )
}
