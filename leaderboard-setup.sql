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


-- Below Zero leaderboard, upgrade 4: new lakes and species, legendary fish, golden/albino fish, and monthly seasons.
-- Run this AFTER upgrade 3. Supabase: SQL Editor > New query > paste > Run. Safe to run more than once.

alter table public.board add column if not exists variant text;
alter table public.board drop constraint if exists board_variant_ok;
alter table public.board add constraint board_variant_ok check (variant is null or variant in ('golden','albino'));

alter table public.board drop constraint if exists board_species_check;
alter table public.board add constraint board_species_check check (species in (
  'bluegill','perch','crappie','largemouth','smallmouth','walleye','channel','pike','laketrout','muskie','flathead','sturgeon',
  'cisco','kokanee','sauger','whitefish','rainbow','splake','burbot','char','oldwhiskers','ironjaw','paleghost'));

-- Anti-cheat: no fish can weigh more than its species can in the game.
alter table public.board drop constraint if exists real_weight;
alter table public.board add constraint real_weight check (lb > 0 and lb <= case species
  when 'bluegill' then 2 when 'perch' then 2.5 when 'crappie' then 4 when 'largemouth' then 16
  when 'smallmouth' then 9 when 'walleye' then 18 when 'channel' then 40 when 'pike' then 35
  when 'laketrout' then 45 when 'muskie' then 60 when 'flathead' then 100 when 'sturgeon' then 150
  when 'cisco' then 5 when 'kokanee' then 5 when 'sauger' then 8 when 'whitefish' then 14 when 'rainbow' then 25
  when 'splake' then 20 when 'burbot' then 20 when 'char' then 25
  when 'oldwhiskers' then 130 when 'ironjaw' then 65 when 'paleghost' then 90 end);

-- Periods: all time, weeks (w2026-10-19) and monthly seasons (s2026-10).
alter table public.board drop constraint if exists board_period_ok;
alter table public.board add constraint board_period_ok check (period = 'all' or period ~ '^w[0-9]{4}-[0-9]{2}-[0-9]{2}$' or period ~ '^s[0-9]{4}-[0-9]{2}$');
grant select (name, tag, species, lb, inches, bait, spot, updated_at, period, caught_at, variant) on public.board to anon, authenticated;

-- New sync: only replaces the periods the game sends, so past seasons stay in the hall of fame.
create or replace function public.sync_player2(p_pid uuid, p_secret text, p_name text, p_tag text, p_fish jsonb, p_periods text[])
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
  if jsonb_typeof(coalesce(p_fish, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_fish, '[]'::jsonb)) > 80 then
    raise exception 'bad fish list';
  end if;
  if p_periods is null or array_length(p_periods, 1) > 3 then
    raise exception 'bad periods';
  end if;
  select secret into saved from players where pid = p_pid;
  if saved is null then
    insert into players (pid, secret) values (p_pid, p_secret);
  elsif saved <> p_secret then
    raise exception 'not your fish';
  end if;
  delete from board where pid = p_pid and period = any(p_periods);
  insert into board (pid, name, tag, species, lb, inches, bait, spot, period, caught_at, variant)
  select p_pid, p_name, p_tag, f->>'species', (f->>'lb')::numeric, (f->>'inches')::numeric, f->>'bait', f->>'spot',
         coalesce(f->>'period', 'all'), (f->>'caught_at')::timestamptz, f->>'variant'
  from jsonb_array_elements(coalesce(p_fish, '[]'::jsonb)) as f
  where coalesce(f->>'period', 'all') = any(p_periods);
  -- keep names consistent if the player renamed
  update board set name = p_name, tag = p_tag where pid = p_pid and (name <> p_name or tag <> p_tag) and period = any(p_periods);
end;
$$;
revoke all on function public.sync_player2(uuid, text, text, text, jsonb, text[]) from public;
grant execute on function public.sync_player2(uuid, text, text, text, jsonb, text[]) to anon, authenticated;
