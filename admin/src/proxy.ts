import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

import { isAdminClaims } from '@/lib/auth'
import { getPublicEnv } from '@/lib/env'

/**
 * Next.js 16 renamed the `middleware` file convention to `proxy`
 * (see `node_modules/next/dist/docs/` and https://nextjs.org/docs/app/api-reference/file-conventions/proxy).
 * The exported function must be named `proxy` (or be the default export).
 *
 * Responsibilities, in order:
 *  1. Refresh the Supabase session cookie on every matched request.
 *  2. Unauthenticated → `/login`.
 *  3. Authenticated but not an admin → `/forbidden`.
 *
 * This is a first line of defence only. Server actions and route handlers MUST
 * re-check with `requireAdmin()`.
 */

const PUBLIC_PATHS = ['/login', '/forbidden', '/auth']

function isPublicPath(pathname: string): boolean {
  return PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`))
}

export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request })

  const env = getPublicEnv()
  const supabase = createServerClient(
    env.NEXT_PUBLIC_SUPABASE_URL,
    env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet, headers) {
          for (const { name, value } of cookiesToSet) {
            request.cookies.set(name, value)
          }
          response = NextResponse.next({ request })
          for (const { name, value, options } of cookiesToSet) {
            response.cookies.set(name, value, options)
          }
          // `Cache-Control: private, no-store` etc. — a CDN must never cache a
          // response that sets auth cookies.
          for (const [key, value] of Object.entries(headers)) {
            response.headers.set(key, value)
          }
        },
      },
    },
  )

  // Do not insert code between createServerClient() and the auth call below:
  // getClaims() is what refreshes an about-to-expire session, and the refreshed
  // cookies must be written before the response is committed.
  const { data, error } = await supabase.auth.getClaims()
  const claims = error ? null : (data?.claims ?? null)

  const { pathname } = request.nextUrl

  if (!claims) {
    if (isPublicPath(pathname)) return response
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    url.search = ''
    return NextResponse.redirect(url, { headers: response.headers })
  }

  if (!isAdminClaims(claims)) {
    if (pathname === '/forbidden') return response
    const url = request.nextUrl.clone()
    url.pathname = '/forbidden'
    url.search = ''
    return NextResponse.redirect(url, { headers: response.headers })
  }

  // Signed-in admin has no business on the login page.
  if (pathname === '/login') {
    const url = request.nextUrl.clone()
    url.pathname = '/'
    url.search = ''
    return NextResponse.redirect(url, { headers: response.headers })
  }

  return response
}

export const config = {
  matcher: [
    /*
     * Everything except:
     * - _next/static, _next/image  (build output)
     * - favicon.ico, sitemap.xml, robots.txt
     * - static asset extensions
     */
    '/((?!_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|woff2?)$).*)',
  ],
}
