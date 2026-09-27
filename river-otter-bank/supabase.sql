-- =====================================================================
--  RIVER OTTER BANK  -  base de données Supabase
--  A coller en entier dans Supabase > SQL Editor > New query > Run
--  Le script peut être relancé sans perdre les données.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------
create table if not exists public.rob_children (
  id        smallint primary key,
  name      text     not null,
  position  smallint not null
);

create table if not exists public.rob_schedules (
  id             bigserial primary key,
  child_id       smallint not null references public.rob_children(id),
  effective_from date     not null,
  amount_cents   integer  not null check (amount_cents between 0 and 99999),
  freq           text     not null check (freq in ('weekly','monthly')),
  weekday        smallint check (weekday between 1 and 7),    -- 1 = lundi ... 6 = samedi, 7 = dimanche
  monthday       smallint check (monthday between 1 and 28),
  created_at     timestamptz not null default now(),
  unique (child_id, effective_from),
  check ((freq = 'weekly' and weekday is not null) or (freq = 'monthly' and monthday is not null))
);

create table if not exists public.rob_transactions (
  id           bigserial primary key,
  child_id     smallint not null references public.rob_children(id),
  amount_cents integer  not null check (amount_cents <> 0),
  kind         text     not null check (kind in ('deposit','withdrawal','allowance')),
  label        text     not null default '',
  due_at       timestamptz,
  created_at   timestamptz not null default now()
);
create unique index if not exists rob_allowance_once
  on public.rob_transactions (child_id, due_at) where kind = 'allowance';
create index if not exists rob_tx_child_date
  on public.rob_transactions (child_id, created_at desc);

create table if not exists public.rob_settings (
  id            boolean primary key default true check (id),
  code_hash     text    not null,
  sounds        boolean not null default true,
  failed_count  integer not null default 0,
  locked_until  timestamptz
);

-- Données de départ (ignorées si déjà présentes)
insert into public.rob_children (id, name, position) values
  (1, 'Martí', 1), (2, 'Adrià', 2)
on conflict (id) do nothing;

insert into public.rob_settings (id, code_hash)
values (true, extensions.crypt('0000', extensions.gen_salt('bf')))
on conflict (id) do nothing;

-- Personne n'accède directement aux tables : tout passe par les fonctions.
alter table public.rob_children     enable row level security;
alter table public.rob_schedules    enable row level security;
alter table public.rob_transactions enable row level security;
alter table public.rob_settings     enable row level security;
revoke all on public.rob_children, public.rob_schedules,
              public.rob_transactions, public.rob_settings
  from anon, authenticated;
revoke all on sequence public.rob_schedules_id_seq, public.rob_transactions_id_seq
  from anon, authenticated;

-- ---------------------------------------------------------------------
--  Fonctions internes
-- ---------------------------------------------------------------------

-- Vérifie le code parent, gère le blocage (3 erreurs = 15 min).
-- Renvoie null si le code est bon, sinon un objet d'erreur.
create or replace function public.rob_check_code(p_code text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare s public.rob_settings;
begin
  select * into s from public.rob_settings where id for update;
  if s.locked_until is not null and s.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked', 'until', s.locked_until);
  end if;
  if p_code is not null and p_code ~ '^[0-9]{4}$'
     and extensions.crypt(p_code, s.code_hash) = s.code_hash then
    update public.rob_settings set failed_count = 0, locked_until = null where id;
    return null;
  end if;
  if s.failed_count + 1 >= 3 then
    update public.rob_settings
       set failed_count = 0, locked_until = now() + interval '15 minutes' where id;
    return jsonb_build_object('ok', false, 'error', 'locked',
                              'until', now() + interval '15 minutes');
  end if;
  update public.rob_settings set failed_count = s.failed_count + 1 where id;
  return jsonb_build_object('ok', false, 'error', 'bad_code',
                            'remaining', 3 - (s.failed_count + 1));
end $$;

-- Echéances d'argent de poche d'un enfant dans l'intervalle ]p_from, p_to].
-- Chaque réglage vaut à partir de sa date d'effet et jusqu'au réglage suivant,
-- et jamais avant le moment où il a été enregistré (le passé ne change pas).
create or replace function public.rob_occurrences(p_child integer, p_from timestamptz, p_to timestamptz)
returns table (due_at timestamptz, amount_cents integer)
language plpgsql stable security definer
set search_path = public
as $$
declare
  r record;
  seg_start timestamptz;
  seg_end   timestamptz;
  d date;
  ts timestamptz;
begin
  for r in
    select s.*, lead(s.effective_from) over (order by s.effective_from) as next_from
      from public.rob_schedules s
     where s.child_id = p_child
     order by s.effective_from
  loop
    continue when r.amount_cents = 0;
    seg_start := greatest((r.effective_from::timestamp) at time zone 'Europe/Paris', r.created_at, p_from);
    seg_end   := least(coalesce((r.next_from::timestamp) at time zone 'Europe/Paris', 'infinity'::timestamptz), p_to);
    continue when seg_end <= seg_start;
    for d in
      select g::date from generate_series(
        (seg_start at time zone 'Europe/Paris')::date,
        (seg_end   at time zone 'Europe/Paris')::date,
        interval '1 day') g
    loop
      if (r.freq = 'weekly'  and extract(isodow from d) = r.weekday)
      or (r.freq = 'monthly' and extract(day    from d) = r.monthday) then
        ts := (d + time '00:01') at time zone 'Europe/Paris';
        if ts > seg_start and ts <= seg_end then
          due_at := ts; amount_cents := r.amount_cents;
          return next;
        end if;
      end if;
    end loop;
  end loop;
end $$;

-- Verse tout l'argent de poche dû jusqu'à maintenant (rattrape les oublis,
-- ne verse jamais deux fois la même échéance).
create or replace function public.rob_run_allowances()
returns void
language plpgsql security definer
set search_path = public
as $$
declare c record;
begin
  for c in select id from public.rob_children loop
    insert into public.rob_transactions (child_id, amount_cents, kind, label, due_at, created_at)
    select c.id, o.amount_cents, 'allowance', 'Argent de poche', o.due_at, o.due_at
      from public.rob_occurrences(c.id, '2000-01-01'::timestamptz, now()) o
    on conflict (child_id, due_at) where kind = 'allowance' do nothing;
  end loop;
end $$;

create or replace function public.rob_balance(p_child integer)
returns integer
language sql stable security definer
set search_path = public
as $$ select coalesce(sum(amount_cents), 0)::integer from public.rob_transactions where child_id = p_child $$;

create or replace function public.rob_schedule_json(p_child integer, p_at date)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_build_object('amount_cents', amount_cents, 'freq', freq, 'weekday', weekday,
                            'monthday', monthday, 'effective_from', effective_from)
    from public.rob_schedules
   where child_id = p_child and effective_from <= p_at
   order by effective_from desc limit 1
$$;

-- ---------------------------------------------------------------------
--  Fonctions appelées par l'appli
-- ---------------------------------------------------------------------

-- Etat complet pour l'écran d'accueil.
create or replace function public.rob_get_state()
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  today date := (now() at time zone 'Europe/Paris')::date;
  kids jsonb;
  s public.rob_settings;
begin
  perform public.rob_run_allowances();
  select * into s from public.rob_settings where id;
  select coalesce(jsonb_agg(x order by x->>'position'), '[]'::jsonb) into kids from (
    select jsonb_build_object(
      'id', c.id, 'name', c.name, 'position', c.position,
      'balance_cents', public.rob_balance(c.id),
      'next', (select jsonb_build_object('due_at', o.due_at, 'amount_cents', o.amount_cents)
                 from public.rob_occurrences(c.id, now(), now() + interval '400 days') o
                order by o.due_at limit 1),
      'current', public.rob_schedule_json(c.id, today),
      'planned', (select jsonb_build_object('amount_cents', amount_cents, 'freq', freq, 'weekday', weekday,
                                            'monthday', monthday, 'effective_from', effective_from)
                    from public.rob_schedules
                   where child_id = c.id and effective_from > today
                   order by effective_from limit 1)
    ) as x
    from public.rob_children c
  ) t;
  return jsonb_build_object('children', kids, 'sounds', s.sounds,
                            'locked_until', case when s.locked_until > now() then s.locked_until end,
                            'server_time', now());
end $$;

-- Historique d'un enfant, du plus récent au plus ancien.
create or replace function public.rob_get_history(p_child integer, p_limit integer default 30, p_offset integer default 0)
returns jsonb
language sql security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'amount_cents', amount_cents, 'kind', kind,
                                               'label', label, 'at', created_at) order by created_at desc, id desc), '[]'::jsonb)
    from (select * from public.rob_transactions
           where child_id = p_child
           order by created_at desc, id desc
           limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0)) t
$$;

-- Vérifie le code (pour ouvrir la section Parents).
create or replace function public.rob_verify(p_code text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare err jsonb;
begin
  err := public.rob_check_code(p_code);
  if err is not null then return err; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Dépôt ou retrait (code obligatoire).
create or replace function public.rob_add_transaction(p_code text, p_child integer, p_kind text,
                                                      p_amount_cents integer, p_label text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare err jsonb; bal integer;
begin
  err := public.rob_check_code(p_code);
  if err is not null then return err; end if;
  if p_kind not in ('deposit','withdrawal') then
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;
  if not exists (select 1 from public.rob_children where id = p_child) then
    return jsonb_build_object('ok', false, 'error', 'bad_child');
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 or p_amount_cents > 999999 then
    return jsonb_build_object('ok', false, 'error', 'bad_amount');
  end if;
  perform public.rob_run_allowances();
  perform 1 from public.rob_children where id = p_child for update;
  bal := public.rob_balance(p_child);
  if p_kind = 'withdrawal' and p_amount_cents > bal then
    return jsonb_build_object('ok', false, 'error', 'insufficient', 'balance_cents', bal);
  end if;
  if p_kind = 'deposit' and bal + p_amount_cents > 999999 then
    return jsonb_build_object('ok', false, 'error', 'too_big', 'balance_cents', bal);
  end if;
  insert into public.rob_transactions (child_id, amount_cents, kind, label)
  values (p_child,
          case when p_kind = 'withdrawal' then -p_amount_cents else p_amount_cents end,
          p_kind,
          left(coalesce(nullif(trim(p_label), ''),
                        case when p_kind = 'withdrawal' then 'Retrait' else 'Dépôt' end), 60));
  return jsonb_build_object('ok', true, 'balance_cents', public.rob_balance(p_child));
end $$;

-- Réglage de l'argent de poche d'un enfant, à partir d'une date (aujourd'hui ou plus tard).
create or replace function public.rob_set_schedule(p_code text, p_child integer, p_amount_cents integer,
                                                   p_freq text, p_weekday integer, p_monthday integer,
                                                   p_effective_from date)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare err jsonb; today date := (now() at time zone 'Europe/Paris')::date;
begin
  err := public.rob_check_code(p_code);
  if err is not null then return err; end if;
  if not exists (select 1 from public.rob_children where id = p_child) then
    return jsonb_build_object('ok', false, 'error', 'bad_child');
  end if;
  if p_effective_from is null or p_effective_from < today then
    return jsonb_build_object('ok', false, 'error', 'past_date');
  end if;
  if p_amount_cents is null or p_amount_cents < 0 or p_amount_cents > 99999 then
    return jsonb_build_object('ok', false, 'error', 'bad_amount');
  end if;
  if not ((p_freq = 'weekly' and p_weekday between 1 and 7)
       or (p_freq = 'monthly' and p_monthday between 1 and 28)) then
    return jsonb_build_object('ok', false, 'error', 'bad_freq');
  end if;
  perform public.rob_run_allowances();       -- verse d'abord tout ce qui était dû
  delete from public.rob_schedules where child_id = p_child and effective_from >= p_effective_from;
  insert into public.rob_schedules (child_id, effective_from, amount_cents, freq, weekday, monthday)
  values (p_child, p_effective_from, p_amount_cents, p_freq,
          case when p_freq = 'weekly'  then p_weekday  end,
          case when p_freq = 'monthly' then p_monthday end);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.rob_set_sounds(p_code text, p_on boolean)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare err jsonb;
begin
  err := public.rob_check_code(p_code);
  if err is not null then return err; end if;
  update public.rob_settings set sounds = coalesce(p_on, true) where id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.rob_change_code(p_code text, p_new_code text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare err jsonb;
begin
  err := public.rob_check_code(p_code);
  if err is not null then return err; end if;
  if p_new_code is null or p_new_code !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_new_code');
  end if;
  update public.rob_settings
     set code_hash = extensions.crypt(p_new_code, extensions.gen_salt('bf')) where id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
--  Droits : seules les fonctions de l'appli sont appelables
-- ---------------------------------------------------------------------
revoke execute on function
  public.rob_check_code(text),
  public.rob_occurrences(integer, timestamptz, timestamptz),
  public.rob_run_allowances(),
  public.rob_balance(integer),
  public.rob_schedule_json(integer, date)
from public, anon, authenticated;

revoke execute on function
  public.rob_get_state(),
  public.rob_get_history(integer, integer, integer),
  public.rob_verify(text),
  public.rob_add_transaction(text, integer, text, integer, text),
  public.rob_set_schedule(text, integer, integer, text, integer, integer, date),
  public.rob_set_sounds(text, boolean),
  public.rob_change_code(text, text)
from public;

grant execute on function
  public.rob_get_state(),
  public.rob_get_history(integer, integer, integer),
  public.rob_verify(text),
  public.rob_add_transaction(text, integer, text, integer, text),
  public.rob_set_schedule(text, integer, integer, text, integer, integer, date),
  public.rob_set_sounds(text, boolean),
  public.rob_change_code(text, text)
to anon, authenticated;

-- ---------------------------------------------------------------------
--  Versement automatique : vérifie toutes les 10 minutes
-- ---------------------------------------------------------------------
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'rob-argent-de-poche';
select cron.schedule('rob-argent-de-poche', '*/10 * * * *', 'select public.rob_run_allowances()');
