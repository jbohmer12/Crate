-- Crate: friends, per-record privacy, trade flags.
-- Run once in Supabase > SQL Editor, AFTER schema.sql and BEFORE uploading the new index.html.
--
-- Privacy model: friends never read the records table. They only get the safe columns returned by
-- the functions below. Dollar values, what you paid, notes, shelf info, etched text and hidden
-- records are never returned to anyone but the owner.

alter table public.records
  add column if not exists hidden boolean not null default false,
  add column if not exists for_trade boolean not null default false;

alter table public.profiles add column if not exists username text;
alter table public.profiles drop constraint if exists username_format;
alter table public.profiles add constraint username_format
  check (username is null or username ~ '^[a-z0-9_]{3,20}$');
create unique index if not exists profiles_username_key on public.profiles (username) where username is not null;

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references auth.users(id) on delete cascade,
  addressee uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
create unique index if not exists friendships_pair_key
  on public.friendships (least(requester, addressee), greatest(requester, addressee));
alter table public.friendships enable row level security;  -- no policies: only the functions below touch it
grant all on public.friendships to service_role;

create or replace function public.set_username(p_username text) returns void
language plpgsql security definer set search_path = public as $$
declare u text := lower(trim(p_username));
begin
  if auth.uid() is null then raise exception 'Please sign in again.'; end if;
  if u !~ '^[a-z0-9_]{3,20}$' then raise exception 'Use 3 to 20 letters, numbers or underscores.'; end if;
  begin
    insert into profiles (id, username) values (auth.uid(), u)
    on conflict (id) do update set username = excluded.username;
  exception when unique_violation then
    raise exception 'That username is taken.';
  end;
end $$;

create or replace function public.send_friend_request(p_username text) returns void
language plpgsql security definer set search_path = public as $$
declare
  target uuid;
  existing friendships%rowtype;
begin
  if auth.uid() is null then raise exception 'Please sign in again.'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and username is not null) then
    raise exception 'Pick your own username first.';
  end if;
  select id into target from profiles where username = lower(trim(p_username));
  if target is null then raise exception 'No one has that username.'; end if;
  if target = auth.uid() then raise exception 'You can''t add yourself.'; end if;

  select * into existing from friendships
   where least(requester, addressee) = least(auth.uid(), target)
     and greatest(requester, addressee) = greatest(auth.uid(), target);
  if found then
    if existing.status = 'pending' and existing.addressee = auth.uid() then
      update friendships set status = 'accepted' where id = existing.id;  -- they already asked you
      return;
    end if;
    raise exception 'You are already friends, or a request is pending.';
  end if;
  insert into friendships (requester, addressee) values (auth.uid(), target);
end $$;

create or replace function public.respond_friend_request(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in again.'; end if;
  if p_accept then
    update friendships set status = 'accepted'
     where id = p_id and addressee = auth.uid() and status = 'pending';
  else
    delete from friendships where id = p_id and addressee = auth.uid() and status = 'pending';
  end if;
end $$;

create or replace function public.remove_friend(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in again.'; end if;
  delete from friendships where id = p_id and (requester = auth.uid() or addressee = auth.uid());
end $$;

create or replace function public.list_friends()
returns table (friendship_id uuid, user_id uuid, username text, status text, incoming boolean)
language sql security definer stable set search_path = public as $$
  select f.id, p.id, p.username, f.status, (f.addressee = auth.uid())
  from friendships f
  join profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where auth.uid() in (f.requester, f.addressee)
  order by f.status, p.username
$$;

-- What a friend is allowed to see of your collection. No prices, no "paid", no notes, no hidden records.
create or replace function public.get_friend_collection(p_friend uuid)
returns table (record_id uuid, discogs_id bigint, artist text, title text, release_year text, label text,
               cover text, media text, have int, edition_size int, edition_source text, for_trade boolean)
language plpgsql security definer stable set search_path = public as $$
begin
  if not exists (
    select 1 from friendships f
    where f.status = 'accepted'
      and ((f.requester = auth.uid() and f.addressee = p_friend)
        or (f.addressee = auth.uid() and f.requester = p_friend))
  ) then
    raise exception 'You are not friends with this user.';
  end if;
  return query
    select r.id, r.discogs_id, r.snapshot->>'artist', r.snapshot->>'title', r.snapshot->>'year',
           r.snapshot->>'label', r.snapshot->>'cover', r.media,
           nullif(r.snapshot->'stats'->>'have', '')::int, r.edition_size, r.edition_source, r.for_trade
    from records r
    where r.user_id = p_friend and r.hidden = false
    order by r.added_at desc;
end $$;

-- Records your friends have marked "open to trade". Same safe columns.
create or replace function public.get_trade_board()
returns table (owner_id uuid, owner_username text, record_id uuid, discogs_id bigint, artist text, title text,
               release_year text, label text, cover text, media text, have int, edition_size int, edition_source text)
language sql security definer stable set search_path = public as $$
  select p.id, p.username, r.id, r.discogs_id, r.snapshot->>'artist', r.snapshot->>'title', r.snapshot->>'year',
         r.snapshot->>'label', r.snapshot->>'cover', r.media,
         nullif(r.snapshot->'stats'->>'have', '')::int, r.edition_size, r.edition_source
  from friendships f
  join profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  join records r on r.user_id = p.id
  where f.status = 'accepted' and auth.uid() in (f.requester, f.addressee)
    and r.for_trade and not r.hidden
  order by r.added_at desc
$$;

revoke all on function public.set_username(text), public.send_friend_request(text),
  public.respond_friend_request(uuid, boolean), public.remove_friend(uuid), public.list_friends(),
  public.get_friend_collection(uuid), public.get_trade_board() from public, anon;
grant execute on function public.set_username(text), public.send_friend_request(text),
  public.respond_friend_request(uuid, boolean), public.remove_friend(uuid), public.list_friends(),
  public.get_friend_collection(uuid), public.get_trade_board() to authenticated;
