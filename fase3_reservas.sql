-- =====================================================================
-- FASE 3 · Crear reservas (con creación atómica desde el primer día)
-- Requiere Fases 1 y 2.
-- =====================================================================

-- ---------- 1. CÓDIGO LEGIBLE RES-000001 -------------------------------
create sequence public.reservation_code_seq start 1;

-- ---------- 2. TABLA RESERVATIONS --------------------------------------
create table public.reservations (
  id                  uuid primary key default gen_random_uuid(),
  reservation_code    text not null unique
                        default ('RES-' || lpad(nextval('public.reservation_code_seq')::text, 6, '0')),
  event_id            uuid not null references public.events(id),
  slot_id             uuid not null references public.time_slots(id),
  customer_name       text not null check (char_length(trim(customer_name)) between 2 and 120),
  phone               text not null check (phone ~ '^[0-9+()\s.\-]{6,20}$'),
  email               text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  people_count        int  not null check (people_count > 0),
  reservation_type_id uuid references public.reservation_types(id),
  notes               text check (notes is null or char_length(notes) <= 1000),
  status              text not null default 'CONFIRMADA'
                        check (status in ('CONFIRMADA','CANCELADA','REALIZADA','NO_PRESENTADO')),
  department_id       uuid not null references public.departments(id),
  created_by          uuid not null references auth.users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  cancelled_at        timestamptz,
  cancelled_by        uuid references auth.users(id),
  constraint cancelled_fields_consistent check (
    (status = 'CANCELADA') = (cancelled_at is not null)
  )
);

create index reservations_slot_idx    on public.reservations(slot_id);
create index reservations_status_idx  on public.reservations(status);
create index reservations_phone_idx   on public.reservations(phone);
create index reservations_name_idx    on public.reservations(lower(customer_name));
create index reservations_email_idx   on public.reservations(lower(email));
create index reservations_dept_idx    on public.reservations(department_id);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger reservations_touch
  before update on public.reservations
  for each row execute function public.touch_updated_at();

-- ---------- 3. CÁLCULO ÚNICO DE PLAZAS OCUPADAS ------------------------
-- Única fuente de verdad de la ocupación. Reglas:
--   CONFIRMADA y REALIZADA  -> consumen plazas
--   CANCELADA               -> no consume
--   NO_PRESENTADO           -> según events.no_show_consumes_capacity
create or replace function public.slot_occupied(p_slot_id uuid)
returns int
language sql stable security definer
set search_path = public
as $$
  select coalesce(sum(r.people_count), 0)::int
    from public.reservations r
    join public.events e on e.id = r.event_id
   where r.slot_id = p_slot_id
     and ( r.status in ('CONFIRMADA','REALIZADA')
           or (r.status = 'NO_PRESENTADO' and e.no_show_consumes_capacity) );
$$;

-- ---------- 4. VISTA DE DISPONIBILIDAD ---------------------------------
create or replace view public.slot_availability
with (security_invoker = true) as
select
  ts.id as slot_id,
  ts.event_id,
  ts.date,
  ts.start_time,
  ts.end_time,
  ts.capacity,
  ts.active,
  public.slot_occupied(ts.id)                                   as occupied,
  greatest(ts.capacity - public.slot_occupied(ts.id), 0)        as remaining,
  (ts.capacity - public.slot_occupied(ts.id)) <= 0              as is_full
from public.time_slots ts;

-- ---------- 5. NO BAJAR CAPACIDAD POR DEBAJO DE LO RESERVADO -----------
create or replace function public.check_capacity_not_below_occupied()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_occ int;
begin
  if new.capacity < old.capacity then
    -- El UPDATE ya bloquea la fila de la franja; create_reservation
    -- bloquea esa misma fila, así que ambas operaciones se serializan.
    v_occ := public.slot_occupied(new.id);
    if new.capacity < v_occ then
      raise exception 'No se puede reducir la capacidad a % : ya hay % plazas reservadas',
        new.capacity, v_occ using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

create trigger time_slots_capacity_guard
  before update of capacity on public.time_slots
  for each row execute function public.check_capacity_not_below_occupied();

-- ---------- 6. RLS: LECTURA GLOBAL, ESCRITURA SOLO POR RPC -------------
alter table public.reservations enable row level security;

-- Todos los departamentos ven la misma información global (requisito).
create policy reservations_select on public.reservations
  for select to authenticated using (public.is_active_user());

-- Sin políticas de INSERT/UPDATE/DELETE: el cliente no puede escribir.
-- Defensa en profundidad: además se revocan los privilegios.
revoke insert, update, delete on public.reservations from anon, authenticated;
revoke all on public.reservations from anon;
revoke all on public.slot_availability from anon;

-- ---------- 7. CREACIÓN ATÓMICA DE RESERVA -----------------------------
-- Devuelve jsonb. Errores de negocio -> { ok:false, error:'CODIGO', message:'...' }
--   error: CAPACITY | SLOT_CLOSED | SLOT_NOT_FOUND | INVALID_INPUT | NO_DEPARTMENT
-- Errores de seguridad -> excepción (42501).
create or replace function public.create_reservation(
  p_slot_id             uuid,
  p_people              int,
  p_customer_name       text,
  p_phone               text,
  p_email               text default null,
  p_reservation_type_id uuid default null,
  p_notes               text default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_profile   public.profiles%rowtype;
  v_slot      public.time_slots%rowtype;
  v_event     public.events%rowtype;
  v_occupied  int;
  v_remaining int;
  v_res       public.reservations%rowtype;
  v_name      text := trim(coalesce(p_customer_name, ''));
  v_phone     text := trim(coalesce(p_phone, ''));
  v_email     text := nullif(trim(coalesce(p_email, '')), '');
  v_notes     text := nullif(trim(coalesce(p_notes, '')), '');
begin
  -- 1. Seguridad: usuario activo y con departamento
  select * into v_profile from public.profiles
   where id = auth.uid() and active = true;
  if not found then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  if v_profile.department_id is null then
    return jsonb_build_object('ok', false, 'error', 'NO_DEPARTMENT',
      'message', 'Tu usuario no tiene departamento asignado. Contacta con administración.');
  end if;

  -- 2. Validación de entrada (mensajes claros, sin errores técnicos)
  if p_people is null or p_people < 1 then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'Indica un número de personas válido.');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'Indica el nombre del responsable de la reserva.');
  end if;
  if v_phone !~ '^[0-9+()\s.\-]{6,20}$' then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'El teléfono no parece válido.');
  end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'El email no parece válido.');
  end if;
  if v_notes is not null and char_length(v_notes) > 1000 then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'Las observaciones son demasiado largas (máximo 1000 caracteres).');
  end if;
  if p_reservation_type_id is not null and not exists (
       select 1 from public.reservation_types where id = p_reservation_type_id and active) then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'El tipo de reserva seleccionado no está disponible.');
  end if;

  -- 3. BLOQUEO de la fila de la franja (serializa reservas concurrentes)
  select * into v_slot from public.time_slots
   where id = p_slot_id
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SLOT_NOT_FOUND',
      'message', 'La franja seleccionada no existe.');
  end if;

  select * into v_event from public.events where id = v_slot.event_id;
  if not v_slot.active or not v_event.active then
    return jsonb_build_object('ok', false, 'error', 'SLOT_CLOSED',
      'message', 'Esta franja no admite reservas en este momento.');
  end if;

  -- 4. Capacidad REAL, calculada con la fila ya bloqueada
  v_occupied  := public.slot_occupied(v_slot.id);
  v_remaining := v_slot.capacity - v_occupied;

  if p_people > v_remaining then
    return jsonb_build_object(
      'ok', false, 'error', 'CAPACITY',
      'remaining', greatest(v_remaining, 0),
      'message', case
        when v_remaining <= 0
          then 'Lo sentimos, esta franja se ha completado. Elige otra hora.'
        else 'Lo sentimos, mientras realizabas la reserva se han ocupado plazas. Ahora solo quedan '
             || v_remaining || '.'
      end);
  end if;

  -- 5. Crear la reserva
  insert into public.reservations (
    event_id, slot_id, customer_name, phone, email, people_count,
    reservation_type_id, notes, status, department_id, created_by
  ) values (
    v_slot.event_id, v_slot.id, v_name, v_phone, v_email, p_people,
    p_reservation_type_id, v_notes, 'CONFIRMADA', v_profile.department_id, auth.uid()
  ) returning * into v_res;

  -- 6. Auditoría
  perform public.write_audit('reservation_create', 'reservations', v_res.id::text,
                             null, to_jsonb(v_res));

  return jsonb_build_object(
    'ok', true,
    'reservation_id', v_res.id,
    'reservation_code', v_res.reservation_code,
    'people', v_res.people_count,
    'remaining', v_remaining - p_people
  );
end;
$$;

revoke all on function public.create_reservation(uuid,int,text,text,text,uuid,text) from public, anon;
grant execute on function public.create_reservation(uuid,int,text,text,text,uuid,text) to authenticated;
