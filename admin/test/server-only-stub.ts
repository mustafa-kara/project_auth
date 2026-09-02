/**
 * Test-only stand-in for the `server-only` marker package.
 *
 * `server-only` throws on import outside a React Server Component graph, which
 * would make `lib/db.ts` / `lib/audit.ts` untestable. `vitest.config.mts` aliases
 * the package to this empty module. Next.js still enforces the real marker at
 * build time, so the server/client boundary is unaffected.
 */
export {}
