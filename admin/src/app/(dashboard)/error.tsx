'use client'

import Link from 'next/link'

import { Button } from '@/components/ui/button'
import { FORBIDDEN_DIGEST } from '@/lib/forbidden'

/**
 * Error boundary for every `(dashboard)` route.
 *
 * `requireAdmin()` throws `ForbiddenError` rather than redirecting, so without a
 * boundary a non-admin who reaches a dashboard page — possible whenever the proxy
 * does not run, e.g. an edge deployment or a future matcher change — would get a
 * raw Next.js error screen instead of `/forbidden`.
 *
 * **The digest is the only reliable signal.** In a production build Next.js
 * replaces a server error's `message` and `stack` with a generic string before it
 * reaches the client, but preserves a digest the error already carried
 * (`next/dist/server/app-render/create-error-handler.js:79-91`). `name` is checked
 * first anyway because it survives in development and for errors thrown on the
 * client.
 *
 * Nothing from the error object is rendered: `message` on a server error can carry
 * driver/constraint detail, and this component is the browser.
 */
export default function DashboardError({
  error,
  reset,
}: {
  error: Error & { digest?: string }
  reset: () => void
}) {
  const forbidden = error.name === 'ForbiddenError' || error.digest === FORBIDDEN_DIGEST

  return (
    <div className="mx-auto flex max-w-md flex-col items-start gap-4 py-16">
      <h1 className="text-2xl font-semibold">
        {forbidden ? 'Yetkiniz yok' : 'Bir şeyler ters gitti'}
      </h1>
      <p className="text-muted-foreground text-sm">
        {forbidden
          ? 'Bu hesap yönetici değil ya da yönetici yetkisi kaldırılmış. Yetki verildiğinde yeniden giriş yapmanız gerekir.'
          : 'Sayfa yüklenirken beklenmeyen bir hata oluştu. Tekrar deneyebilir ya da panele dönebilirsiniz.'}
      </p>

      <div className="flex flex-wrap items-center gap-2">
        {forbidden ? (
          <Button asChild>
            <Link href="/forbidden">Devam et</Link>
          </Button>
        ) : (
          <Button type="button" onClick={reset}>
            Tekrar dene
          </Button>
        )}
        <Button variant="outline" asChild>
          <Link href="/">Panele dön</Link>
        </Button>
      </div>
    </div>
  )
}
