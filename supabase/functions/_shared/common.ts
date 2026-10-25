import { createClient } from 'npm:@supabase/supabase-js@2.45.4'

export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

export function clients(req: Request) {
  const url = Deno.env.get('SUPABASE_URL')!
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const auth = req.headers.get('Authorization') ?? ''
  // asUser runs with the caller's login (Row Level Security applies). admin bypasses it; use sparingly.
  const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } } })
  const admin = createClient(url, service)
  return { asUser, admin }
}
