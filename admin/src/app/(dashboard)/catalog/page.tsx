import type { Metadata } from 'next'

import { CatalogFormDialog } from '@/components/catalog/catalog-form-dialog'
import { DeleteCatalogDialog } from '@/components/catalog/delete-catalog-dialog'
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
import { createClient } from '@/lib/supabase/server'

export const metadata: Metadata = { title: 'Katalog — Yönetim Paneli' }

/** Reads with access path (c); writes live in `./actions.ts` (path (b)). */
export default async function CatalogPage() {
  await requireAdmin()

  const supabase = await createClient()
  const { data, error } = await supabase
    .from('catalog_services')
    .select('id,name,issuer,logo_url')
    .order('name', { ascending: true })

  const services = mapCatalogRows(data)

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
    </div>
  )
}
