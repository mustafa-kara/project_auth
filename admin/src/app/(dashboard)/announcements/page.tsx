import type { Metadata } from 'next'

import { AnnouncementFormDialog } from '@/components/announcements/announcement-form-dialog'
import { DeleteAnnouncementDialog } from '@/components/announcements/delete-announcement-dialog'
import { Badge } from '@/components/ui/badge'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  AUDIENCE_LABELS,
  formatDateTime,
  isKnownAudience,
  mapAnnouncementRows,
} from '@/lib/announcements'
import { requireAdmin } from '@/lib/auth'
import { createClient } from '@/lib/supabase/server'

export const metadata: Metadata = { title: 'Duyurular — Yönetim Paneli' }

/**
 * Reads with access path (c) — the admin's own session. `announcements` grants
 * SELECT to anon+authenticated, so the secret key is not needed to list; it is
 * used only by the write actions in `./actions.ts`.
 */
export default async function AnnouncementsPage() {
  await requireAdmin()

  const supabase = await createClient()
  const { data, error } = await supabase
    .from('announcements')
    .select('id,title,body,audience,created_at')
    .order('created_at', { ascending: false })

  const announcements = mapAnnouncementRows(data)

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Duyurular</h1>
          <p className="text-muted-foreground text-sm">
            Uygulama içi duyurular. Herkes okuyabilir; yalnızca panel yazabilir.
          </p>
        </div>
        <AnnouncementFormDialog />
      </div>

      {error ? (
        <p role="alert" className="text-destructive text-sm">
          Duyurular yüklenemedi. Lütfen sayfayı yenileyin.
        </p>
      ) : announcements.length === 0 ? (
        <div className="rounded-lg border border-dashed p-10 text-center">
          <p className="text-sm font-medium">Henüz duyuru yok</p>
          <p className="text-muted-foreground mt-1 text-sm">
            “Yeni duyuru” ile ilk duyuruyu oluşturun.
          </p>
        </div>
      ) : (
        <div className="rounded-lg border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Başlık</TableHead>
                <TableHead>Hedef kitle</TableHead>
                <TableHead>Oluşturulma</TableHead>
                <TableHead className="w-0 text-right">İşlemler</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {announcements.map((announcement) => (
                <TableRow key={announcement.id}>
                  <TableCell className="max-w-md align-top">
                    <p className="font-medium">{announcement.title}</p>
                    <p className="text-muted-foreground line-clamp-2 text-sm break-words">
                      {announcement.body}
                    </p>
                  </TableCell>
                  <TableCell className="align-top">
                    {isKnownAudience(announcement.audience) ? (
                      <Badge variant="secondary">{AUDIENCE_LABELS[announcement.audience]}</Badge>
                    ) : (
                      <Badge
                        variant="destructive"
                        title="İstemci bu değeri tanımıyor; duyuru hiçbir cihazda görünmez."
                      >
                        {announcement.audience} (tanınmıyor)
                      </Badge>
                    )}
                  </TableCell>
                  <TableCell className="text-muted-foreground align-top text-sm whitespace-nowrap">
                    {formatDateTime(announcement.createdAt)}
                  </TableCell>
                  <TableCell className="align-top text-right whitespace-nowrap">
                    <AnnouncementFormDialog announcement={announcement} />
                    <DeleteAnnouncementDialog announcement={announcement} />
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
