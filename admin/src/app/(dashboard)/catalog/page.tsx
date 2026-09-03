import type { Metadata } from 'next'
import Link from 'next/link'

import { CatalogFormDialog } from '@/components/catalog/catalog-form-dialog'
import { DeleteCatalogDialog } from '@/components/catalog/delete-catalog-dialog'
import { TablePagination } from '@/components/table-pagination'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { requireAdmin } from '@/lib/auth'
import { mapCatalogRows } from '@/lib/catalog'
import {
  hasNextPage,
  pageCount,
  pageHref,
  pageRange,
  parsePage,
  type SearchParamValue,
} from '@/lib/paging'
import { createClient } from '@/lib/supabase/server'

export const metadata: Metadata = { title: 'Katalog — Yönetim Paneli' }

/** Reads with access path (c); writes live in `./actions.ts` (path (b)). */
export default async function CatalogPage({
  searchParams,
}: {
  searchParams: Promise<{ page?: SearchParamValue }>
}) {
  await requireAdmin()

  const page = parsePage((await searchParams).page)
  const { from, to } = pageRange(page)

  const supabase = await createClient()
  const { data, count, error } = await supabase
    .from('catalog_services')
    .select('id,name,issuer,logo_url', { count: 'exact' })
    // `name` is not unique, so `id` is the tiebreaker: without it two services
    // sharing a name could swap places between page loads and one would be lost.
    .order('name', { ascending: true })
    .order('id', { ascending: true })
    .range(from, to)

  const services = mapCatalogRows(data)
  const total = typeof count === 'number' ? count : null
  // From the raw response, not from `services`: a row `mapCatalogRow` quarantines
  // still occupies a slot in the page.
  const rowCount = (data ?? []).length
  const totalPages = pageCount(total ?? rowCount)
  const hasNext = hasNextPage(page, total, rowCount)

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Servis kataloğu</h1>
          <p className="text-muted-foreground text-sm">
            İstemci, jetonlardaki issuer adlarını bu tabloya göre kanonikleştirir.
          </p>
        </div>
        <CatalogFormDialog />
      </div>

      {error ? (
        <p role="alert" className="text-destructive text-sm">
          Katalog yüklenemedi. Lütfen sayfayı yenileyin.
        </p>
      ) : rowCount === 0 && page > 1 ? (
        <div className="rounded-lg border border-dashed p-10 text-center">
          <p className="text-sm font-medium">Bu sayfada kayıt yok</p>
          <p className="text-muted-foreground mt-1 text-sm">
            <Link href={pageHref('/catalog', 1)} className="underline underline-offset-4">
              İlk sayfaya dön
            </Link>
          </p>
        </div>
      ) : services.length === 0 ? (
        <div className="rounded-lg border border-dashed p-10 text-center">
          <p className="text-sm font-medium">Katalog boş</p>
          <p className="text-muted-foreground mt-1 text-sm">
            “Yeni servis” ile ilk kaydı ekleyin.
          </p>
        </div>
      ) : (
        <div className="rounded-lg border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Ad</TableHead>
                <TableHead>Sağlayıcı</TableHead>
                <TableHead>Logo adresi</TableHead>
                <TableHead className="w-0 text-right">İşlemler</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {services.map((service) => (
                <TableRow key={service.id}>
                  <TableCell className="font-medium">{service.name}</TableCell>
                  <TableCell className="text-muted-foreground">
                    {service.issuer ?? <span aria-label="boş">—</span>}
                  </TableCell>
                  <TableCell className="text-muted-foreground max-w-xs truncate text-sm">
                    {service.logoUrl ?? <span aria-label="boş">—</span>}
                  </TableCell>
                  <TableCell className="text-right whitespace-nowrap">
                    <CatalogFormDialog service={service} />
                    <DeleteCatalogDialog service={service} />
                  </TableCell>
                </TableRow>
              ))}
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
          hrefForPage={(target) => pageHref('/catalog', target)}
        />
      )}
    </div>
  )
}
