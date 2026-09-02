import { z } from 'zod'

/**
 * `public.catalog_services` — pure schema + row-mapping layer (no I/O).
 *
 * ## Client contract
 * `lib/features/vault/domain/catalog_repository.dart` canonicalises issuer names
 * against this table and **quarantines malformed rows** (a row whose `id` or `name`
 * is not a string is silently dropped). `logo_url` is carried but deliberately
 * ignored by the app — no logo is ever fetched at runtime (offline + privacy
 * decision) — so it is stored for forward compatibility only.
 *
 * `logo_url` is still validated as an absolute `https://` URL: the column is public
 * (anon SELECT) and a `http://`, `javascript:` or `data:` value would become a
 * stored payload the moment any future client starts rendering it.
 */

export const NAME_MAX_LENGTH = 80
export const ISSUER_MAX_LENGTH = 80
export const LOGO_URL_MAX_LENGTH = 512

/** Absolute `https://` URLs only — no relative paths, no other scheme. */
export function isHttpsUrl(value: string): boolean {
  let parsed: URL
  try {
    parsed = new URL(value)
  } catch {
    return false
  }
  return parsed.protocol === 'https:' && parsed.hostname.length > 0
}

/** `<input>` gives `''` for an untouched optional field; the column wants NULL. */
function emptyToNull(value: unknown): unknown {
  if (value === undefined || value === null) return null
  if (typeof value === 'string' && value.trim().length === 0) return null
  return value
}

export const catalogInputSchema = z.object({
  name: z
    .string({ message: 'Ad zorunludur.' })
    .trim()
    .min(1, { message: 'Ad boş olamaz.' })
    .max(NAME_MAX_LENGTH, { message: `Ad en fazla ${NAME_MAX_LENGTH} karakter olabilir.` }),
  issuer: z.preprocess(
    emptyToNull,
    z
      .string({ message: 'Sağlayıcı metin olmalıdır.' })
      .trim()
      .max(ISSUER_MAX_LENGTH, {
        message: `Sağlayıcı en fazla ${ISSUER_MAX_LENGTH} karakter olabilir.`,
      })
      .nullable(),
  ),
  logo_url: z.preprocess(
    emptyToNull,
    z
      .string({ message: 'Logo adresi metin olmalıdır.' })
      .trim()
      .max(LOGO_URL_MAX_LENGTH, {
        message: `Logo adresi en fazla ${LOGO_URL_MAX_LENGTH} karakter olabilir.`,
      })
      .refine(isHttpsUrl, { message: 'Logo adresi mutlak bir https:// adresi olmalıdır.' })
      .nullable(),
  ),
})

export type CatalogInput = z.infer<typeof catalogInputSchema>

export interface CatalogService {
  id: string
  name: string
  issuer: string | null
  logoUrl: string | null
}

/** PostgREST row → view model, or `null` for a row the Flutter client would quarantine. */
export function mapCatalogRow(row: unknown): CatalogService | null {
  if (typeof row !== 'object' || row === null) return null
  const r = row as Record<string, unknown>

  if (typeof r.id !== 'string' || r.id.length === 0) return null
  if (typeof r.name !== 'string') return null

  return {
    id: r.id,
    name: r.name,
    issuer: typeof r.issuer === 'string' ? r.issuer : null,
    logoUrl: typeof r.logo_url === 'string' ? r.logo_url : null,
  }
}

export function mapCatalogRows(rows: unknown): CatalogService[] {
  if (!Array.isArray(rows)) return []
  const out: CatalogService[] = []
  for (const row of rows) {
    const mapped = mapCatalogRow(row)
    if (mapped !== null) out.push(mapped)
  }
  return out
}
