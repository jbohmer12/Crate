// Paste this whole file into the Supabase dashboard editor.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

function clients(req: Request) {
  const url = Deno.env.get('SUPABASE_URL')!
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const auth = req.headers.get('Authorization') ?? ''
  // asUser runs with the caller's login (Row Level Security applies). admin bypasses it; use sparingly.
  const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } } })
  const admin = createClient(url, service)
  return { asUser, admin }
}


const TOKEN = Deno.env.get('DISCOGS_TOKEN')!
const UA = 'Crate/1.0'
const DAY = 24 * 60 * 60 * 1000
const SEARCH_KEYS = ['q', 'catno', 'label', 'artist', 'release_title', 'barcode']

async function dg(path: string, params: Record<string, string> = {}) {
  const u = new URL('https://api.discogs.com' + path)
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v)
  const r = await fetch(u, { headers: { Authorization: `Discogs token=${TOKEN}`, 'User-Agent': UA } })
  if (r.status === 404) return null
  if (!r.ok) throw new Error('discogs ' + r.status)
  return r.json()
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const { asUser, admin } = clients(req)
    const { data: { user } } = await asUser.auth.getUser()
    if (!user) return json({ error: 'auth', message: 'Please sign in again.' }, 401)
    const body = await req.json()

    if (body.action === 'search') {
      const params: Record<string, string> = { type: 'release', format: 'Vinyl', per_page: '15' }
      let n = 0
      for (const k of SEARCH_KEYS) {
        const v = body.params?.[k]
        if (typeof v === 'string' && v.trim()) { params[k] = v.trim().slice(0, 200); n++ }
      }
      if (!n) return json({ error: 'bad_request', message: 'Type something to search for.' }, 400)
      const d = await dg('/database/search', params)
      return json({
        results: (d?.results ?? []).map((r: any) => ({
          id: r.id, title: r.title, year: r.year, country: r.country,
          label: r.label, catno: r.catno, format: r.format, thumb: r.thumb,
        })),
      })
    }

    if (body.action === 'release') {
      const id = Number(body.id)
      if (!Number.isInteger(id) || id <= 0) return json({ error: 'bad_request', message: 'Bad release id.' }, 400)
      const rel = await dg(`/releases/${id}`, { curr_abbr: 'USD' })
      if (!rel) return json({ error: 'not_found', message: 'Release not found on Discogs.' }, 404)

      // Cache prices only (24h). Counts and images are always fetched fresh.
      let priceStats: any = null
      const { data: c } = await admin.from('releases_cache').select('data,fetched_at').eq('discogs_id', id).maybeSingle()
      if (c && Date.now() - new Date(c.fetched_at).getTime() < DAY) priceStats = c.data
      if (!priceStats) {
        const [mk, ps] = await Promise.all([
          dg(`/marketplace/stats/${id}`, { curr_abbr: 'USD' }).catch(() => null),
          dg(`/marketplace/price_suggestions/${id}`).catch(() => null),
        ])
        let sugg: Record<string, number> | null = null
        if (ps && !ps.message && Object.values(ps).every((v: any) => v?.currency === 'USD')) {
          sugg = Object.fromEntries(Object.entries(ps).map(([k, v]: any) => [k, v.value]))
        }
        priceStats = { lowest: mk?.lowest_price?.value ?? rel.lowest_price ?? null, forSale: mk?.num_for_sale ?? rel.num_for_sale ?? 0, sugg }
        await admin.from('releases_cache').upsert({ discogs_id: id, data: priceStats, fetched_at: new Date().toISOString() })
      }

      return json({
        rel: {
          title: rel.title, year: rel.year, country: rel.country, notes: rel.notes,
          artists: (rel.artists ?? []).map((a: any) => ({ name: a.name })),
          labels: (rel.labels ?? []).map((l: any) => ({ name: l.name, catno: l.catno })),
          formats: rel.formats ?? [],
          images: (rel.images ?? []).slice(0, 1).map((i: any) => ({ uri: i.uri, uri150: i.uri150 })),
          thumb: rel.thumb,
        },
        stats: { ...priceStats, have: rel.community?.have ?? 0, want: rel.community?.want ?? 0, updated: Date.now() },
      })
    }

    if (body.action === 'identifiers') {
      const ids: number[] = (body.ids ?? []).map(Number).filter((n: number) => Number.isInteger(n) && n > 0).slice(0, 10)
      const out: Record<string, string[]> = {}
      for (let i = 0; i < ids.length; i += 5) {
        await Promise.all(ids.slice(i, i + 5).map(async (id) => {
          const r = await dg(`/releases/${id}`).catch(() => null)
          out[id] = (r?.identifiers ?? []).map((x: any) => x.value).filter(Boolean)
        }))
      }
      return json({ identifiers: out })
    }

    return json({ error: 'bad_request', message: 'Unknown action.' }, 400)
  } catch (e) {
    console.error(e)
    const busy = String((e as Error).message).includes('429')
    return json({ error: busy ? 'busy' : 'server', message: busy ? 'Discogs is busy. Try again in a minute.' : 'Something went wrong on our side. Try again.' }, busy ? 429 : 500)
  }
})
