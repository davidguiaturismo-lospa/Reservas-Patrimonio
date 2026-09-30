-- =====================================================================
-- FASE 2 · Eventos + franjas horarias + capacidades
-- Requiere haber ejecutado la Fase 1.
-- =====================================================================

-- ---------- 1. EVENTOS --------------------------------------------------
create table public.events (
  id                      uuid primary key default gen_random_uuid(),
  name                    text not null check (length(trim(name)) > 0),
  description             text,
  logo_url                text,
  start_date              date not null,
  end_date                date not null,
  active                  boolean not null default true,
  -- Comportamiento configurable de "NO PRESENTADO" respecto a la capacidad
  -- (se aplica en la Fase 3/4 al calcular plazas ocupadas).
  no_show_consumes_capacity boolean not null default true,
  created_at              timestamptz not null default now(),
  constraint events_dates_ok check (end_date >= start_date)
);

-- Solo un evento activo a la vez (la app trabaja sobre "el evento").
-- Si en el futuro hay varios simultáneos, basta con eliminar este índice.
create unique index events_single_active_idx
  on public.events ((true)) where active;

-- ---------- 2. TIPOS DE RESERVA (configurables) -------------------------
create table public.reservation_types (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (length(trim(name)) > 0),
  active     boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

insert into public.reservation_types (name, sort_order) values
  ('Particular', 1), ('Grupo', 2), ('Colegio', 3),
  ('Asociación', 4), ('Empresa', 5), ('Otro', 6);

-- ---------- 3. FRANJAS HORARIAS ----------------------------------------
create table public.time_slots (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events(id) on delete restrict,
  date       date not null,
  start_time time not null,
  end_time   time not null,
  capacity   int  not null check (capacity >= 0),
  active     boolean not null default true,   -- false = franja cerrada (no admite reservas nuevas)
  created_at timestamptz not null default now(),
  constraint time_slots_time_ok check (end_time > start_time),
  constraint time_slots_unique unique (event_id, date, start_time)
);

create index time_slots_event_date_idx on public.time_slots(event_id, date);

-- La fecha de la franja debe estar dentro del rango del evento.
create or replace function public.check_slot_within_event()
returns trigger
language plpgsql
as $$
declare v_start date; v_end date;
begin
  select start_date, end_date into v_start, v_end
    from public.events where id = new.event_id;
  if new.date < v_start or new.date > v_end then
    raise exception 'La fecha de la franja queda fuera del rango del evento'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger time_slots_within_event
  before insert or update of date, event_id on public.time_slots
  for each row execute function public.check_slot_within_event();

-- Si se acorta el evento, no puede dejar franjas fuera de rango.
create or replace function public.check_event_range_covers_slots()
returns trigger
language plpgsql
as $$
begin
  if exists (
    select 1 from public.time_slots
     where event_id = new.id and (date < new.start_date or date > new.end_date)
  ) then
    raise exception 'Hay franjas fuera del nuevo rango de fechas del evento'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger events_range_covers_slots
  before update of start_date, end_date on public.events
  for each row execute function public.check_event_range_covers_slots();

-- NOTA (Fase 3): se añadirá un trigger que impida bajar `capacity`
-- por debajo de las plazas ya reservadas en la franja.

-- ---------- 4. AUDITORÍA -----------------------------------------------
create trigger audit_events
  after insert or update on public.events
  for each row execute function public.audit_trigger();

create trigger audit_time_slots
  after insert or update on public.time_slots
  for each row execute function public.audit_trigger();

create trigger audit_reservation_types
  after insert or update on public.reservation_types
  for each row execute function public.audit_trigger();

-- ---------- 5. RLS ------------------------------------------------------
alter table public.events            enable row level security;
alter table public.reservation_types enable row level security;
alter table public.time_slots        enable row level security;

create policy events_select on public.events
  for select to authenticated using (public.is_active_user());
create policy events_admin_write on public.events
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy rtypes_select on public.reservation_types
  for select to authenticated using (public.is_active_user());
create policy rtypes_admin_write on public.reservation_types
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy slots_select on public.time_slots
  for select to authenticated using (public.is_active_user());
create policy slots_admin_write on public.time_slots
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- 6. GENERADOR MASIVO DE FRANJAS (solo admin) -----------------
-- Ejemplo: select public.generate_slots(
--   '<event_id>', '2026-09-30', '2026-10-02',
--   array['10:00','11:00','12:00','13:00','17:00']::time[], 60, 30);
-- Crea franjas de 60 min con capacidad 30 para cada día del rango.
-- Es idempotente: ignora las que ya existen.
create or replace function public.generate_slots(
  p_event_id        uuid,
  p_from            date,
  p_to              date,
  p_start_times     time[],
  p_duration_min    int,
  p_capacity        int
) returns int
language plpgsql security definer
set search_path = public
as $$
declare
  v_day date;
  v_t   time;
  v_count int := 0;
  v_rows int;
begin
  if not public.is_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  if p_to < p_from or p_duration_min <= 0 or p_capacity < 0 then
    raise exception 'Parámetros no válidos' using errcode = 'P0001';
  end if;

  for v_day in select generate_series(p_from, p_to, interval '1 day')::date loop
    foreach v_t in array p_start_times loop
      insert into public.time_slots (event_id, date, start_time, end_time, capacity)
      values (p_event_id, v_day, v_t, v_t + make_interval(mins => p_duration_min), p_capacity)
      on conflict (event_id, date, start_time) do nothing;
      get diagnostics v_rows = row_count;
      v_count := v_count + v_rows;
    end loop;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.generate_slots(uuid,date,date,time[],int,int) from public, anon;
grant execute on function public.generate_slots(uuid,date,date,time[],int,int) to authenticated;
