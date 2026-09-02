'use client'

import { useSyncExternalStore } from 'react'

/** No client-side store to watch: the value flips once, when hydration finishes. */
const noopSubscribe = () => () => {}

/**
 * True only after hydration.
 *
 * `useSyncExternalStore` renders `getServerSnapshot` on the server *and* during
 * hydration, then re-renders with `getSnapshot` once hydration completes — the
 * documented way to render a client-only value without a hydration mismatch (and
 * without `setState` inside an effect).
 */
function useHydrated(): boolean {
  return useSyncExternalStore(
    noopSubscribe,
    () => true,
    () => false,
  )
}

/**
 * Renders `created_at` in the *viewer's* timezone, with the exact ISO value in
 * `title` (and `dateTime`, so it stays machine-readable).
 *
 * Server-rendered markup uses a timezone-independent UTC string, because the
 * server's timezone is not the admin's.
 */
export function AuditTimestamp({ iso }: { iso: string }) {
  const hydrated = useHydrated()

  return (
    <time dateTime={iso} title={iso} className="tabular-nums">
      {hydrated ? formatLocal(iso) : formatUtc(iso)}
    </time>
  )
}

/** Deterministic `YYYY-MM-DD HH:MM:SS UTC` — identical on both sides of hydration. */
function formatUtc(iso: string): string {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return iso
  return `${date.toISOString().slice(0, 19).replace('T', ' ')} UTC`
}

function formatLocal(iso: string): string {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return iso
  return date.toLocaleString('tr-TR', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}
