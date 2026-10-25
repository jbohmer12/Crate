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


const MODEL = Deno.env.get('VISION_MODEL') ?? 'claude-sonnet-5-5'
const FREE_LIMIT = Number(Deno.env.get('FREE_SCANS_PER_MONTH') ?? '15')
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY')!

const PROMPTS: Record<string, string> = {
  label: `This is a photo of the center label of a vinyl record. Read the printed text exactly as written. Return only a JSON object with these keys:
"artist", "title" (album or single title if printed; null if only track titles appear), "label" (record label name), "catno" (catalog number exactly as printed, keeping prefixes, dashes and spaces), "country" (from text like "Made in Germany", else null), "year" (the ℗ or © year as a number, else null), "side" (A, B, 1, 2 and so on, else null), "tracks" (array of track titles you can read), "other" (short note on anything distinguishing such as promo, stereo, test pressing, or null).
Use null for anything you cannot read. Do not guess.`,
  runout: `This is a photo of the runout groove (the smooth ring near the center) of a vinyl record, with etched or stamped text. Read every string you can: matrix numbers, side marks, stamper codes, mastering engineer initials or names, plant marks. Return only a JSON object: {"matrix": [each separate etched string exactly as written, keeping punctuation and spacing, using ? for any uncertain character], "other": a short note or null}. If nothing is readable return {"matrix": [], "other": null}. Do not guess.`,
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const { asUser } = clients(req)
    const { data: { user } } = await asUser.auth.getUser()
    if (!user) return json({ error: 'auth', message: 'Please sign in again.' }, 401)

    const { kind, image } = await req.json()
    if (!PROMPTS[kind]) return json({ error: 'bad_request', message: 'Unknown scan type.' }, 400)
    if (typeof image !== 'string' || image.length < 100 || image.length > 7_000_000) {
      return json({ error: 'bad_image', message: 'That photo is empty or too large.' }, 413)
    }

    const { data: allowed, error: qErr } = await asUser.rpc('use_scan', { p_limit: FREE_LIMIT })
    if (qErr) throw qErr
    if (!allowed) {
      return json({ error: 'quota', message: `You’ve used your ${FREE_LIMIT} free scans this month. Searching by catalog number still works.` }, 402)
    }

    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': ANTHROPIC_KEY, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 500,
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: image } },
          { type: 'text', text: PROMPTS[kind] },
        ] }],
      }),
    })
    if (!r.ok) {
      console.error('anthropic', r.status, await r.text())
      await asUser.rpc('refund_scan')
      return json({ error: 'upstream', message: 'The scan service is busy. Try again in a moment.' }, 502)
    }
    const d = await r.json()
    const text = (d.content ?? []).map((c: { text?: string }) => c.text ?? '').join('')
    const m = text.match(/\{[\s\S]*\}/)
    if (!m) return json({ error: 'unreadable', message: 'Could not read that photo. Try a sharper, brighter shot.' }, 422)
    try {
      return json({ result: JSON.parse(m[0]) })
    } catch {
      return json({ error: 'unreadable', message: 'Could not read that photo. Try a sharper, brighter shot.' }, 422)
    }
  } catch (e) {
    console.error(e)
    return json({ error: 'server', message: 'Something went wrong on our side. Try again.' }, 500)
  }
})
