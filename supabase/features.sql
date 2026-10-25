-- Crate: gig crates, wantlist, value history.
-- Run once in Supabase > SQL Editor, AFTER schema.sql and friends.sql.
-- Everything here is private to the owner. Friends never see any of it.

create table if not exists public.crates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  gig_date date,
  notes text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.crate_items (
  crate_id uuid not null references public.crates(id) on delete cascade,
  record_id uuid not null references public.records(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  position int not null default 0,
  packed boolean not null default false,
  returned boolean not null default false,
  primary key (crate_id, record_id)
);

create table if not exists public.wants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  discogs_id bigint not null,
  snapshot jsonb not null default '{}',
  note text not null default '',
  created_at timestamptz not null default now(),
  unique (user_id, discogs_id)
);

create table if not exists public.price_history (
  record_id uuid not null references public.records(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  taken_on date not null default current_date,
  value numeric not null,
  primary key (record_id, taken_on)
);

create table if not exists public.value_snapshots (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  taken_on date not null default current_date,
  total numeric not null,
  records int not null,
  primary key (user_id, taken_on)
);

alter table public.crates enable row level security;
alter table public.crate_items enable row level security;
alter table public.wants enable row level security;
alter table public.price_history enable row level security;
alter table public.value_snapshots enable row level security;

drop policy if exists own_crates on public.crates;
create policy own_crates on public.crates for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- A crate item must point at a crate AND a record that belong to you.
drop policy if exists own_crate_items on public.crate_items;
create policy own_crate_items on public.crate_items for all
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.crates c where c.id = crate_id and c.user_id = auth.uid())
    and exists (select 1 from public.records r where r.id = record_id and r.user_id = auth.uid())
  );

drop policy if exists own_wants on public.wants;
create policy own_wants on public.wants for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists own_price_history on public.price_history;
create policy own_price_history on public.price_history for all
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.records r where r.id = record_id and r.user_id = auth.uid())
  );

drop policy if exists own_value_snapshots on public.value_snapshots;
create policy own_value_snapshots on public.value_snapshots for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.crates, public.crate_items, public.wants,
  public.price_history, public.value_snapshots to authenticated;
grant all on public.crates, public.crate_items, public.wants,
  public.price_history, public.value_snapshots to service_role;
