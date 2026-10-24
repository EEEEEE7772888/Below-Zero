-- Below Zero leaderboard, version 2: the board shows each player's biggest KEPT fish of each kind.
-- Paste this whole thing into Supabase: SQL Editor > New query > Run. If it warns about a destructive operation, confirm.

-- The old table from version 1 is no longer used.
drop table if exists public.catches;

-- Each player's secret code. Nobody can read this table from the website.
create table if not exists public.players (
  pid uuid primary key,
  secret text not null,
  created_at timestamptz not null default now()
);
alter table public.players enable row level security;
revoke all on public.players from anon, authenticated;

-- The leaderboard: one row per player per kind of fish.
create table if not exists public.board (
  pid uuid not null references public.players(pid) on delete cascade,
  name text not null check (name ~ '^[A-Za-z0-9_]{2,16}$'),
  tag text not null check (tag ~ '^[0-9]{4}$'),
  species text not null check (species in ('bluegill','perch','crappie','largemouth','smallmouth','walleye','channel','pike','laketrout','muskie','flathead','sturgeon')),
  lb numeric(7,4) not null,
  inches numeric(5,2) not null check (inches > 0 and inches < 100),
  bait text check (bait in ('worm','minnow','cut','sucker')),
  spot text check (spot in ('shallows','weedline','deep')),
  updated_at timestamptz not null default now(),
  primary key (pid, species),
  -- Anti-cheat: no fish can weigh more than its species can in the game.
  constraint real_weight check (lb > 0 and lb <= case species
    when 'bluegill' then 2 when 'perch' then 2.5 when 'crappie' then 4 when 'largemouth' then 16
    when 'smallmouth' then 9 when 'walleye' then 18 when 'channel' then 40 when 'pike' then 35
    when 'laketrout' then 45 when 'muskie' then 60 when 'flathead' then 100 when 'sturgeon' then 150 end)
);
create index if not exists board_lb on public.board (lb desc);
alter table public.board enable row level security;
drop policy if exists "read board" on public.board;
create policy "read board" on public.board for select to anon, authenticated using (true);
revoke all on public.board from anon, authenticated;
grant select (name, tag, species, lb, inches, bait, spot, updated_at) on public.board to anon, authenticated;

-- The only way to change the board: replace YOUR OWN rows, proven by your secret code.
create or replace function public.sync_player(p_pid uuid, p_secret text, p_name text, p_tag text, p_fish jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  saved text;
begin
  if p_secret is null or length(p_secret) < 20 then
    raise exception 'bad secret';
  end if;
  if jsonb_typeof(coalesce(p_fish, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_fish, '[]'::jsonb)) > 12 then
    raise exception 'bad fish list';
  end if;
  select secret into saved from players where pid = p_pid;
  if saved is null then
    insert into players (pid, secret) values (p_pid, p_secret);
  elsif saved <> p_secret then
    raise exception 'not your fish';
  end if;
  delete from board where pid = p_pid;
  insert into board (pid, name, tag, species, lb, inches, bait, spot)
  select p_pid, p_name, p_tag, f->>'species', (f->>'lb')::numeric, (f->>'inches')::numeric, f->>'bait', f->>'spot'
  from jsonb_array_elements(coalesce(p_fish, '[]'::jsonb)) as f;
end;
$$;
revoke all on function public.sync_player(uuid, text, text, text, jsonb) from public;
grant execute on function public.sync_player(uuid, text, text, text, jsonb) to anon, authenticated;


-- Below Zero leaderboard, upgrade 3: adds the weekly leaderboard.
-- Run this AFTER the version 2 setup. Supabase: SQL Editor > New query > paste > Run. Safe to run more than once.

alter table public.board add column if not exists period text not null default 'all';
alter table public.board add column if not exists caught_at timestamptz;
alter table public.board drop constraint if exists board_pkey;
alter table public.board add constraint board_pkey primary key (pid, species, period);
alter table public.board drop constraint if exists board_period_ok;
alter table public.board add constraint board_period_ok check (period = 'all' or period ~ '^w[0-9]{4}-[0-9]{2}-[0-9]{2}$');
create index if not exists board_period_lb on public.board (period, lb desc);
grant select (name, tag, species, lb, inches, bait, spot, updated_at, period, caught_at) on public.board to anon, authenticated;

create or replace function public.sync_player(p_pid uuid, p_secret text, p_name text, p_tag text, p_fish jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  saved text;
begin
  if p_secret is null or length(p_secret) < 20 then
    raise exception 'bad secret';
  end if;
  if jsonb_typeof(coalesce(p_fish, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_fish, '[]'::jsonb)) > 24 then
    raise exception 'bad fish list';
  end if;
  select secret into saved from players where pid = p_pid;
  if saved is null then
    insert into players (pid, secret) values (p_pid, p_secret);
  elsif saved <> p_secret then
    raise exception 'not your fish';
  end if;
  delete from board where pid = p_pid;
  insert into board (pid, name, tag, species, lb, inches, bait, spot, period, caught_at)
  select p_pid, p_name, p_tag, f->>'species', (f->>'lb')::numeric, (f->>'inches')::numeric, f->>'bait', f->>'spot',
         coalesce(f->>'period', 'all'), (f->>'caught_at')::timestamptz
  from jsonb_array_elements(coalesce(p_fish, '[]'::jsonb)) as f;
end;
$$;
revoke all on function public.sync_player(uuid, text, text, text, jsonb) from public;
grant execute on function public.sync_player(uuid, text, text, text, jsonb) to anon, authenticated;
