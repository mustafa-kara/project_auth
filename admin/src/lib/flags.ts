import { z } from 'zod'

/**
 * `public.feature_flags` — pure schema + row-mapping layer (no I/O).
 *
 * ## Client contract
 * `lib/features/account/domain/feature_flags_service.dart` reads exactly one key
 * today: `token_sync_enabled`. It is a **kill switch** — an explicit `enabled=false`
 * stops token sync on every client; a missing/unreadable flag falls back to `true`.
 * Deleting the row therefore *enables* sync rather than disabling it, which is why
 * the panel refuses to delete that key at all.
 *
 * `FeatureFlag.fromJson` quarantines any row whose `key` is not a string or whose
 * `enabled` is not a bool, and takes `payload` only when it is a JSON object
 * (arrays and scalars become `null` on the client) — hence the object-or-null rule
 * enforced here.
 */

export const TOKEN_SYNC_FLAG_KEY = 'token_sync_enabled'

/** Warning shown wherever `token_sync_enabled` can be switched off. */
export const TOKEN_SYNC_WARNING = 'Kapatmak tüm istemcilerde token senkronunu durdurur.'

/** lowercase, starts with a letter, 3–64 chars total. */
export const FLAG_KEY_PATTERN = /^[a-z][a-z0-9_]{2,63}$/

export const PAYLOAD_MAX_BYTES = 8 * 1024

export const flagKeySchema = z
  .string({ message: 'Anahtar zorunludur.' })
  .trim()
  .regex(FLAG_KEY_PATTERN, {
    message:
      'Anahtar küçük harfle başlamalı; yalnızca küçük harf, rakam ve alt çizgi içermeli ve 3–64 karakter olmalıdır.',
  })

export type FlagPayload = Record<string, unknown> | null

export type FlagPayloadResult =
  | { readonly ok: true; readonly value: FlagPayload }
  | { readonly ok: false; readonly error: string }

const encoder = new TextEncoder()

/**
 * Parses the payload textarea.
 *
 * Empty / whitespace-only → `null` (column stays NULL). Otherwise the text must be
 * JSON, at most {@link PAYLOAD_MAX_BYTES} bytes, and must decode to a JSON **object**
 * or the literal `null`. Arrays and scalars are rejected because the Flutter client
 * drops them, which would silently produce a flag whose payload never arrives.
 *
 * The size check runs before `JSON.parse` so an oversized blob is never parsed.
 */
export function parseFlagPayload(raw: string | null | undefined): FlagPayloadResult {
  if (raw === null || raw === undefined) return { ok: true, value: null }
  const text = raw.trim()
  if (text.length === 0) return { ok: true, value: null }

  if (encoder.encode(text).byteLength > PAYLOAD_MAX_BYTES) {
    return { ok: false, error: `Payload en fazla ${PAYLOAD_MAX_BYTES / 1024} KiB olabilir.` }
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return { ok: false, error: 'Payload geçerli JSON değil.' }
  }

  if (parsed === null) return { ok: true, value: null }
  if (typeof parsed !== 'object' || Array.isArray(parsed)) {
    return { ok: false, error: 'Payload bir JSON nesnesi ya da null olmalıdır.' }
  }

  return { ok: true, value: parsed as Record<string, unknown> }
}

/** Textarea text → `FlagPayload`, reporting {@link parseFlagPayload} failures as zod issues. */
export const flagPayloadTextSchema = z
  .string({ message: 'Payload metin olmalıdır.' })
  .transform((value, ctx): FlagPayload => {
    const result = parseFlagPayload(value)
    if (!result.ok) {
      ctx.addIssue({ code: 'custom', message: result.error })
      return z.NEVER
    }
    return result.value
  })

export const flagCreateSchema = z.object({
  key: flagKeySchema,
  enabled: z.boolean({ message: 'Durum bilgisi eksik.' }),
  payload: flagPayloadTextSchema,
})

export type FlagCreateInput = z.infer<typeof flagCreateSchema>

export const flagPayloadUpdateSchema = z.object({
  key: flagKeySchema,
  payload: flagPayloadTextSchema,
})

export const flagToggleSchema = z.object({
  key: flagKeySchema,
  enabled: z.boolean({ message: 'Durum bilgisi eksik.' }),
})

export const flagDeleteSchema = z.object({
  key: flagKeySchema.refine((key) => key !== TOKEN_SYNC_FLAG_KEY, {
    message: `${TOKEN_SYNC_FLAG_KEY} silinemez: satır yoksa istemciler senkronu açık varsayar.`,
  }),
})

export interface FeatureFlag {
  key: string
  enabled: boolean
  payload: FlagPayload
  updatedAt: string | null
}

export function mapFlagRow(row: unknown): FeatureFlag | null {
  if (typeof row !== 'object' || row === null) return null
  const r = row as Record<string, unknown>

  if (typeof r.key !== 'string' || r.key.length === 0) return null
  if (typeof r.enabled !== 'boolean') return null

  const payload = r.payload
  const usable =
    typeof payload === 'object' && payload !== null && !Array.isArray(payload)
      ? (payload as Record<string, unknown>)
      : null

  return {
    key: r.key,
    enabled: r.enabled,
    payload: usable,
    updatedAt: typeof r.updated_at === 'string' ? r.updated_at : null,
  }
}

export function mapFlagRows(rows: unknown): FeatureFlag[] {
  if (!Array.isArray(rows)) return []
  const out: FeatureFlag[] = []
  for (const row of rows) {
    const mapped = mapFlagRow(row)
    if (mapped !== null) out.push(mapped)
  }
  return out
}

/** Pretty-prints a payload for the editor textarea; `null` becomes an empty field. */
export function formatPayload(payload: FlagPayload): string {
  if (payload === null) return ''
  return JSON.stringify(payload, null, 2)
}

/**
 * Flag operations all share the single `flag.update` audit action, so the *what*
 * has to live in `target`.
 */
export const FLAG_OPERATIONS = ['create', 'enable', 'disable', 'payload', 'delete'] as const

export type FlagOperation = (typeof FLAG_OPERATIONS)[number]

/** `token_sync_enabled` + `disable` → `token_sync_enabled:disable`. */
export function flagAuditTarget(key: string, operation: FlagOperation): string {
  return `${key}:${operation}`
}
