-- =====================================================================
-- FASES 6, 7, 9 y 11 (parte de base de datos): capa de LECTURA
--   · reservation_details  -> listados, ficha y búsqueda
--   · daily_summary        -> dashboard "HOY" y calendario
--   · search_reservations  -> buscador global
--   · event_stats          -> estadísticas (solo supervisor/admin)
--   · audit_log_view       -> pantalla "Registro de actividad"
--   · Realtime             -> reservations y time_slots
-- Requiere Fases 1-5. Solo LEE: no modifica datos ni reglas.
-- =====================================================================

-- ---------- 1. RESERVAS CON TODOS LOS DATOS PARA MOSTRAR ---------------
create or replace view public.reservation_details
with (security_invoker = true) as
select
  r.*,
  ts.date        as slot_date,
  ts.start_time  as start_time,
  ts.end_time    as end_time,
  rt.name        as type_name,
  d.name         as department_name,
  pc.nombre      as created_by_name,
  px.nombre      as cancelled_by_name
from public.reservations r
join public.time_slots ts         on ts.id = r.slot_id
join public.departments d         on d.id  = r.department_id
left join public.reservation_types rt on rt.id = r.reservation_type_id
left join public.profiles pc      on pc.id = r.created_by
left join public.profiles px      on px.id = r.cancelled_by;

-- ---------- 2. RESUMEN POR DÍA (dashboard y calendario) ----------------
-- Solo franjas activas cuentan para capacidad. "reservations" = reservas
-- vigentes (confirmadas + realizadas).
create or replace view public.daily_summary
with (security_invoker = true) as
with s as (
  select event_id, date,
         sum(capacity)::int as capacity,
         sum(occupied)::int as occupied,
         count(*)::int      as slots
    from public.slot_availability
   where active
   group by event_id, date
),
r as (
  select ts.event_id, ts.date,
         count(*) filter (where x.status in ('CONFIRMADA','REALIZADA'))::int as reservations,
         count(*) filter (where x.status = 'CANCELADA')::int                 as cancelled,
         count(*) filter (where x.status = 'NO_PRESENTADO')::int             as no_shows
    from public.reservations x
    join public.time_slots ts on ts.id = x.slot_id
   group by ts.event_id, ts.date
)
select
  s.event_id,
  s.date,
  s.slots,
  s.capacity,
  s.occupied,
  greatest(s.capacity - s.occupied, 0)                          as remaining,
  round(100.0 * s.occupied / nullif(s.capacity, 0), 1)          as occupancy_pct,
  coalesce(r.reservations, 0)                                   as reservations,
  coalesce(r.cancelled, 0)                                      as cancelled,
  coalesce(r.no_shows, 0)                                       as no_shows
from s
left join r on r.event_id = s.event_id and r.date = s.date;

-- ---------- 3. BUSCADOR GLOBAL -----------------------------------------
-- Busca por nombre, teléfono, nº de reserva (RES-000124 o solo 124),
-- email y fecha (2026-09-30 o 30/09/2026). Respeta RLS (security invoker).
create or replace function public.search_reservations(p_query text, p_limit int default 50)
returns setof public.reservation_details
language plpgsql stable
set search_path = public
as $$
declare
  q      text := trim(coalesce(p_query, ''));
  q_like text;
  digits text;
  d      date := null;
  lim    int  := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if char_length(q) < 1 then return; end if;

  -- Escapar comodines para que "%" o "_" se busquen como texto literal
  q_like := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  digits := regexp_replace(q, '\D', '', 'g');

  begin
    if q ~ '^\d{4}-\d{2}-\d{2}$' then
      d := q::date;
    elsif q ~ '^\d{1,2}/\d{1,2}/\d{4}$' then
      d := to_date(q, 'DD/MM/YYYY');
    end if;
  exception when others then
    d := null;
  end;

  return query
  select rd.*
    from public.reservation_details rd
   where rd.reservation_code ilike q_like
      or rd.customer_name    ilike q_like
      or rd.email            ilike q_like
      or (char_length(digits) >= 3
          and regexp_replace(rd.phone, '\D', '', 'g') like '%' || digits || '%')
      or (q ~ '^\d+$' and rd.reservation_code = 'RES-' || lpad(q, 6, '0'))
      or (d is not null and rd.slot_date = d)
   order by rd.slot_date desc, rd.start_time desc, rd.created_at desc
   limit lim;
end;
$$;

-- ---------- 4. ESTADÍSTICAS (solo supervisor / admin) ------------------
create or replace function public.event_stats(p_event_id uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_event uuid;
begin
  if not public.is_supervisor_or_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  v_event := coalesce(p_event_id, (select id from public.events where active limit 1));
  if v_event is null then
    return jsonb_build_object('error', 'NO_EVENT');
  end if;

  return jsonb_build_object(
    'totals', (
      select jsonb_build_object(
        'reservations', count(*) filter (where r.status <> 'CANCELADA'),
        'people',       coalesce(sum(r.people_count) filter (where r.status <> 'CANCELADA'), 0),
        'cancelled',    count(*) filter (where r.status = 'CANCELADA'),
        'no_shows',     count(*) filter (where r.status = 'NO_PRESENTADO'))
        from public.reservations r
       where r.event_id = v_event),

    'avg_occupancy_pct', (
      select round(100.0 * sum(occupied) / nullif(sum(capacity), 0), 1)
        from public.slot_availability
       where event_id = v_event and active),

    'by_department', coalesce((
      select jsonb_agg(jsonb_build_object(
               'department', t.name, 'reservations', t.n, 'people', t.p) order by t.name)
        from (select d.name, count(*)::int as n, sum(r.people_count)::int as p
                from public.reservations r
                join public.departments d on d.id = r.department_id
               where r.event_id = v_event and r.status <> 'CANCELADA'
               group by d.name) t), '[]'::jsonb),

    'by_day', coalesce((
      select jsonb_agg(jsonb_build_object(
               'date', s.date, 'reservations', s.reservations, 'people', s.occupied,
               'capacity', s.capacity, 'occupancy_pct', s.occupancy_pct) order by s.date)
        from public.daily_summary s
       where s.event_id = v_event), '[]'::jsonb),

    'by_slot', coalesce((
      select jsonb_agg(jsonb_build_object(
               'start_time', t.start_time, 'people', t.people,
               'capacity', t.capacity, 'occupancy_pct', t.pct) order by t.start_time)
        from (select sa.start_time,
                     sum(sa.occupied)::int as people,
                     sum(sa.capacity)::int as capacity,
                     round(100.0 * sum(sa.occupied) / nullif(sum(sa.capacity), 0), 1) as pct
                from public.slot_availability sa
               where sa.event_id = v_event and sa.active
               group by sa.start_time) t), '[]'::jsonb)
  );
end;
$$;

-- ---------- 5. REGISTRO DE ACTIVIDAD -----------------------------------
-- audit_log ya restringe la lectura a supervisor/admin por RLS.
create or replace view public.audit_log_view
with (security_invoker = true) as
select
  a.id,
  a.created_at,
  a.action,
  a.entity_type,
  a.entity_id,
  a.user_id,
  p.nombre  as user_name,
  p.email   as user_email,
  d.name    as department_name,
  a.old_data,
  a.new_data
from public.audit_log a
left join public.profiles p    on p.id = a.user_id
left join public.departments d on d.id = a.department_id;

-- ---------- 6. TIEMPO REAL ---------------------------------------------
-- Realtime respeta RLS: solo usuarios activos reciben los cambios.
-- El frontend se suscribe a estas tablas y vuelve a consultar slot_availability.
do $$
begin
  alter publication supabase_realtime add table public.reservations;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.time_slots;
exception when duplicate_object then null;
end $$;

-- ---------- 7. PERMISOS -------------------------------------------------
revoke all on public.reservation_details from anon;
revoke all on public.daily_summary       from anon;
revoke all on public.audit_log_view      from anon;
revoke all on function public.search_reservations(text, int) from public, anon;
revoke all on function public.event_stats(uuid)              from public, anon;

grant select on public.reservation_details to authenticated;
grant select on public.daily_summary       to authenticated;
grant select on public.audit_log_view      to authenticated;
grant execute on function public.search_reservations(text, int) to authenticated;
grant execute on function public.event_stats(uuid)              to authenticated;
