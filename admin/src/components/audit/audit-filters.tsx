import Link from 'next/link'

import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { AUDIT_ACTIONS } from '@/lib/audit'
import { AUDIT_ACTION_LABELS, AUDIT_SEARCH_MAX_LENGTH, type AuditQuery } from '@/lib/audit-query'

/**
 * Filter bar for `/audit`.
 *
 * A plain `method="get"` form, so it needs no client JavaScript and no server
 * action: the browser turns the fields into `?action=…&q=…` itself. `page` is
 * intentionally not a field — submitting a new filter must land on page 1.
 */
export function AuditFilters({ query }: { query: AuditQuery }) {
  const hasFilters = query.action !== undefined || query.q !== undefined

  return (
    <form method="get" action="/audit" className="flex flex-wrap items-end gap-3">
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="audit-action">İşlem</Label>
        <select
          id="audit-action"
          name="action"
          defaultValue={query.action ?? ''}
          className="border-input dark:bg-input/30 focus-visible:border-ring focus-visible:ring-ring/50 h-8 w-64 rounded-lg border bg-transparent px-2.5 py-1 text-sm transition-colors outline-none focus-visible:ring-3"
        >
          <option value="">Tümü</option>
          {AUDIT_ACTIONS.map((action) => (
            <option key={action} value={action}>
              {AUDIT_ACTION_LABELS[action]}
            </option>
          ))}
        </select>
      </div>

      <div className="flex flex-col gap-1.5">
        <Label htmlFor="audit-q">Hedef</Label>
        <Input
          id="audit-q"
          name="q"
          type="search"
          inputMode="search"
          maxLength={AUDIT_SEARCH_MAX_LENGTH}
          placeholder="Hedefte ara (kullanıcı id, bayrak anahtarı…)"
          defaultValue={query.q ?? ''}
          className="w-72"
        />
      </div>

      <div className="flex items-center gap-2">
        <Button type="submit">Filtrele</Button>
        {hasFilters ? (
          <Button variant="ghost" asChild>
            <Link href="/audit">Temizle</Link>
          </Button>
        ) : null}
      </div>
    </form>
  )
}
