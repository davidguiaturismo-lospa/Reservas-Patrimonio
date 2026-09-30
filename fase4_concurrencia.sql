-- =====================================================================
-- FASE 4 · Control de concurrencia: red de seguridad en la base de datos
-- Requiere Fases 1-3.
-- Objetivo: que NINGÚN camino (RPC actual, funciones futuras, scripts,
-- importaciones) pueda dejar una franja por encima de su capacidad.
-- =====================================================================

-- ---------- 1. REGLA ÚNICA: ¿QUÉ ESTADOS CONSUMEN PLAZAS? --------------
create or replace function public.status_consumes_capacity(p_status text, p_event_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select p_status in ('CONFIRMADA','REALIZADA')
      or ( p_status = 'NO_PRESENTADO'
           and coalesce((select e.no_show_consumes_capacity
                           from public.events e where e.id = p_event_id), true) );
$$;

-- slot_occupied ahora usa esa misma regla (sigue habiendo una sola fuente de verdad)
create or replace function public.slot_occupied(p_slot_id uuid)
returns int
language sql stable security definer
set search_path = public
as $$
  select coalesce(sum(r.people_count), 0)::int
    from public.reservations r
   where r.slot_id = p_slot_id
     and public.status_consumes_capacity(r.status, r.event_id);
$$;

-- Estas funciones no deben ser invocables por usuarios anónimos
revoke all on function public.status_consumes_capacity(text, uuid) from public, anon;
revoke all on function public.slot_occupied(uuid) from public, anon;
grant execute on function public.status_consumes_capacity(text, uuid) to authenticated;
grant execute on function public.slot_occupied(uuid) to authenticated;

-- ---------- 2. TRIGGER GUARDIÁN DE CAPACIDAD ---------------------------
-- Se dispara tras insertar o actualizar (franja, personas, estado).
-- Bloquea la franja, recalcula con datos ya confirmados por otras
-- transacciones y aborta si se supera la capacidad.
-- Cancelar o reducir personas NUNCA falla.
create or replace function public.enforce_slot_capacity()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_cap int;
  v_occ int;
begin
  -- Si la fila no consume plazas, no hay nada que comprobar
  if not public.status_consumes_capacity(new.status, new.event_id) then
    return null;
  end if;

  -- Si ya consumía en la misma franja y no aumenta, tampoco
  if tg_op = 'UPDATE'
     and public.status_consumes_capacity(old.status, old.event_id)
     and new.slot_id = old.slot_id
     and new.people_count <= old.people_count then
    return null;
  end if;

  -- Serializa con cualquier otra operación sobre la misma franja
  select capacity into v_cap
    from public.time_slots where id = new.slot_id
    for update;

  v_occ := public.slot_occupied(new.slot_id);

  if v_occ > v_cap then
    raise exception 'CAPACITY_EXCEEDED: la franja tiene % plazas y se intentan ocupar %',
      v_cap, v_occ using errcode = 'P0001';
  end if;

  return null;
end;
$$;

create trigger reservations_capacity_guard
  after insert or update of slot_id, people_count, status on public.reservations
  for each row execute function public.enforce_slot_capacity();

-- ---------- 3. CAMBIAR "NO PRESENTADO CONSUME PLAZAS" CON SEGURIDAD -----
-- Si se activa la opción, los no presentados vuelven a contar; eso podría
-- provocar sobreaforo retroactivo. Se impide en ese caso.
create or replace function public.check_event_no_show_flag()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if new.no_show_consumes_capacity and not old.no_show_consumes_capacity then
    perform 1 from public.time_slots where event_id = new.id for update;

    if exists (
      select 1
        from public.time_slots ts
       where ts.event_id = new.id
         and ts.capacity < (
           select coalesce(sum(r.people_count), 0)
             from public.reservations r
            where r.slot_id = ts.id
              and r.status in ('CONFIRMADA','REALIZADA','NO_PRESENTADO')
         )
    ) then
      raise exception 'No se puede activar: al contar los no presentados alguna franja superaría su capacidad'
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

create trigger events_no_show_flag_guard
  before update of no_show_consumes_capacity on public.events
  for each row execute function public.check_event_no_show_flag();
