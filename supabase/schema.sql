-- Crate: run this once in Supabase > SQL Editor.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'free' check (plan in ('free','pro')),
  created_at timestamptz not null default now()
);

create table public.records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  discogs_id bigint not null,
  media text not null default 'VG+',
  sleeve text not null default 'VG+',
  paid numeric,
  notes text not null default '',
  edition_size int,
  edition_copy int,
  edition_source text,
  edition_manual boolean not null default false,
  matrix text[] not null default '{}',
  snapshot jsonb not null default '{}',
  added_at timestamptz not null default now()
);
create index records_user_idx on public.records (user_id, added_at desc);

create table public.usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  month text not null,
  scans int not null default 0,
  primary key (user_id, month)
);

-- Prices and counts only. Server-side access only (no policies below).
create table public.releases_cache (
  discogs_id bigint primary key,
  data jsonb not null,
  fetched_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.records enable row level security;
alter table public.usage enable row level security;
alter table public.releases_cache enable row level security;

create policy own_profile on public.profiles for select using (id = auth.uid());
create policy own_records on public.records for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_usage on public.usage for select using (user_id = auth.uid());
-- Users cannot write profiles or usage, so nobody can give themselves the pro plan.

-- Every new account (email or Google) gets a profile row.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Counts a scan against this month's allowance. Returns false when the free limit is reached.
create function public.use_scan(p_limit int) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  m text := to_char(now() at time zone 'utc', 'YYYY-MM');
  v_plan text;
  n int;
begin
  if auth.uid() is null then return false; end if;
  select plan into v_plan from profiles where id = auth.uid();
  insert into usage (user_id, month, scans) values (auth.uid(), m, 0) on conflict do nothing;
  if v_plan = 'pro' then
    update usage set scans = scans + 1 where user_id = auth.uid() and month = m;
    return true;
  end if;
  update usage set scans = scans + 1
    where user_id = auth.uid() and month = m and scans < p_limit
    returning scans into n;
  return n is not null;
end $$;

-- Gives a scan back when our side fails.
create function public.refund_scan() returns void
language sql security definer set search_path = public as $$
  update usage set scans = greatest(scans - 1, 0)
  where user_id = auth.uid() and month = to_char(now() at time zone 'utc', 'YYYY-MM');
$$;

revoke all on function public.use_scan(int) from public, anon;
revoke all on function public.refund_scan() from public, anon;
grant execute on function public.use_scan(int) to authenticated;
grant execute on function public.refund_scan() to authenticated;

-- Data API access. Needed because new projects can be created with
-- "Automatically expose new tables" turned off. Signed-in users get only what they need;
-- anonymous visitors get nothing.
grant usage on schema public to anon, authenticated, service_role;
grant select on public.profiles to authenticated;
grant select, insert, update, delete on public.records to authenticated;
grant select on public.usage to authenticated;
grant all on public.profiles, public.records, public.usage, public.releases_cache to service_role;
