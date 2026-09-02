import { AuditTimestamp } from '@/components/audit/audit-timestamp'
import { Badge } from '@/components/ui/badge'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { auditActionLabel, auditActionVariant } from '@/lib/audit-query'

/** One `public.audit_logs` row, exactly as selected by `/audit`. */
export interface AuditLogRow {
  id: string
  created_at: string
  action: string
  target: string | null
  /** Nullable: the FK is `on delete set null`, so a deleted admin leaves `null`. */
  actor: string | null
}

export function AuditTable({ rows }: { rows: readonly AuditLogRow[] }) {
  if (rows.length === 0) {
    return (
      <div className="rounded-lg border border-dashed p-10 text-center">
        <p className="text-sm font-medium">Kayıt bulunamadı</p>
        <p className="text-muted-foreground mt-1 text-sm">
          Bu filtrelerle eşleşen bir denetim kaydı yok. Filtreleri temizleyip yeniden deneyin.
        </p>
      </div>
    )
  }

  return (
    <div className="rounded-lg border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-56">Zaman</TableHead>
            <TableHead className="w-72">İşlem</TableHead>
            <TableHead>Hedef</TableHead>
            <TableHead className="w-32">Yönetici</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row) => (
            <TableRow key={row.id}>
              <TableCell className="text-muted-foreground">
                <AuditTimestamp iso={row.created_at} />
              </TableCell>
              <TableCell>
                <Badge variant={auditActionVariant(row.action)} title={row.action}>
                  {auditActionLabel(row.action)}
                </Badge>
              </TableCell>
              <TableCell className="max-w-0 truncate font-mono text-xs" title={row.target ?? ''}>
                {row.target ?? <span className="text-muted-foreground font-sans">—</span>}
              </TableCell>
              <TableCell>
                {row.actor ? (
                  <span className="font-mono text-xs" title={row.actor}>
                    {row.actor.slice(0, 8)}
                  </span>
                ) : (
                  <span className="text-muted-foreground">—</span>
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}
