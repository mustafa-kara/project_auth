import type { NextConfig } from 'next'

/**
 * Deliberately empty.
 *
 * **Server Action origin check.** Next.js compares the request's `Origin` against
 * its `Host` and rejects the action when they disagree, which is the built-in CSRF
 * defence for Server Functions. Behind a reverse proxy or CDN that rewrites `Host`,
 * every action starts failing with an opaque error. Two supported answers:
 *
 *  1. serve the panel with `Host` preserved (`proxy_set_header Host $host;` in
 *     nginx, `X-Forwarded-Host` honoured by the platform) — the default, and what
 *     this config assumes; or
 *  2. list the deployment domains explicitly:
 *
 *     experimental: { serverActions: { allowedOrigins: ['panel.example.com', '*.example.com'] } }
 *
 * The key name was read from the installed Next 16.3.4 type definition
 * (`node_modules/next/dist/server/config-shared.d.ts`, `experimental.serverActions`
 * → `allowedOrigins?: string[]`, documented as "Allowed origins that can bypass
 * Server Action's CSRF check"). It stays commented out because the deployment
 * domain is not decided yet; see admin/README.md §8.
 */
const nextConfig: NextConfig = {}

export default nextConfig
