/**
 * A tiny stand-in for the postgrest-js query builder, shared by the server-action
 * tests (announcements / catalog / flags).
 *
 * It exists to pin down the ONE behaviour that made zero-row writes look like
 * successes: a `PATCH`/`DELETE` matching no rows comes back as `204 No Content`,
 * which postgrest-js surfaces as `{ data: null, error: null }`. So the mock records
 * the whole chain — including whether `.select()` was asked for — and lets a test
 * hand back exactly that shape.
 *
 * Not a Supabase client: it only implements what the four action modules call.
 */

export interface QueryResult {
  data: unknown
  error: unknown
}

export interface RecordedQuery {
  table: string
  op: 'insert' | 'update' | 'delete' | 'select'
  values?: unknown
  filters: { column: string; value: unknown }[]
  /** Columns passed to `.select(…)`, or `undefined` when it was never called. */
  columns?: string
  single: boolean
}

export type QueryHandler = (query: RecordedQuery) => QueryResult | Promise<QueryResult>

interface Chain extends PromiseLike<QueryResult> {
  select(columns: string): Chain
  eq(column: string, value: unknown): Chain
  order(column: string, options?: unknown): Chain
  single(): Chain
  maybeSingle(): Chain
}

export interface PostgrestMock {
  /** Pass this where the code expects `createAdminClient()`'s return value. */
  client: {
    from(table: string): {
      insert(values: unknown): Chain
      update(values: unknown): Chain
      delete(): Chain
      select(columns: string): Chain
    }
  }
  /** Every query built, in order, with its filters and selected columns. */
  calls: RecordedQuery[]
}

export function createPostgrestMock(handler: QueryHandler): PostgrestMock {
  const calls: RecordedQuery[] = []

  function build(query: RecordedQuery): Chain {
    const chain: Chain = {
      select(columns: string) {
        query.columns = columns
        return chain
      },
      eq(column: string, value: unknown) {
        query.filters.push({ column, value })
        return chain
      },
      order() {
        return chain
      },
      single() {
        query.single = true
        return chain
      },
      maybeSingle() {
        query.single = true
        return chain
      },
      then(onfulfilled, onrejected) {
        return Promise.resolve(handler(query)).then(onfulfilled, onrejected)
      },
    }
    return chain
  }

  function start(table: string, op: RecordedQuery['op'], values?: unknown): Chain {
    const query: RecordedQuery = { table, op, values, filters: [], single: false }
    calls.push(query)
    return build(query)
  }

  return {
    calls,
    client: {
      from(table: string) {
        return {
          insert: (values: unknown) => start(table, 'insert', values),
          update: (values: unknown) => start(table, 'update', values),
          delete: () => start(table, 'delete'),
          select: (columns: string) => start(table, 'select').select(columns),
        }
      },
    },
  }
}

/** PostgREST's answer to a write that matched no rows: 204, no error. */
export const ZERO_ROWS: QueryResult = { data: [], error: null }

/**
 * What postgrest-js returns for a `204 No Content` when `.select()` was NOT asked
 * for — the shape that made the original bug invisible.
 */
export const NO_CONTENT: QueryResult = { data: null, error: null }
