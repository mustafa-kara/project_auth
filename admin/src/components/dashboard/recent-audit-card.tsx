import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { createClient } from '@/lib/supabase/server'
import { formatDateTime, shortId, summariseError } from '@/lib/users'

export const RECENT_AUDIT_LIMIT = 10

interface AuditRow {
  id: string
  created_at: string
  action: string
  target: string | null
  actor: string | null
}

/**
 * Access path (c) — the signed-in admin's own session (publishable key + cookies).
 *
 * `public.audit_logs` has a select policy `to authenticated using (public.is_admin())`,
 * so this read is authorised by the caller's own admin claim; the secret key is not
 * involved and RLS stays in force.
 */
export async function RecentAuditCard() {
  const supabase = await createClient()

  let rows: AuditRow[] = []
  let error: string | null = null

  try {
    const result = await supabase
      .from('audit_logs')
      .select('id, created_at, action, target, actor')
      .order('created_at', { ascending: false })
      .limit(RECENT_AUDIT_LIMIT)

    if (result.error) {
      error = summariseError(result.error)
    } else {
      rows = (result.data ?? []) as AuditRow[]
    }
  } catch (caught) {
    error = summariseError(caught)
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Son denetim kayıtları</CardTitle>
        <CardDescription>
          Son {RECENT_AUDIT_LIMIT} ayrıcalıklı işlem. Kendi oturumunuzla, RLS{' '}
          <code>is_admin()</code> politikası altında okunur.
        </CardDescription>
      </CardHeader>

      <CardContent>
        {error !== null ? (
          <p role="alert" className="text-destructive text-sm">
            Denetim kayıtları okunamadı: <span className="font-mono text-xs">{error}</span>
          </p>
        ) : rows.length === 0 ? (
          <p className="text-muted-foreground text-sm">
            Henüz denetim kaydı yok. Panelden yapılan her ayrıcalıklı işlem buraya bir satır yazar.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Zaman</TableHead>
                  <TableHead>İşlem</TableHead>
                  <TableHead>Hedef</TableHead>
                  <TableHead>Yetkili</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id}>
                    <TableCell className="whitespace-nowrap">
                      {formatDateTime(row.created_at)}
                    </TableCell>
                    <TableCell className="font-mono text-xs">{row.action}</TableCell>
                    <TableCell className="font-mono text-xs" title={row.target ?? undefined}>
                      {shortId(row.target)}
                    </TableCell>
                    <TableCell className="font-mono text-xs" title={row.actor ?? undefined}>
                      {shortId(row.actor)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
