-- =====================================================================
-- FASE 5 · Modificar, cancelar y cambiar estado de reservas
-- Requiere Fases 1-4.
-- Todo se hace por RPC (el cliente sigue sin poder escribir en la tabla).
-- =====================================================================

-- ---------- 1. MOTIVO DE CANCELACIÓN (opcional) ------------------------
alter table public.reservations
  add column cancel_reason text
  check (cancel_reason is null or char_length(cancel_reason) <= 500);

-- ---------- 2. PERMISOS POR ROL (configurables sin tocar código) -------
create table public.role_permissions (
  id         uuid primary key default gen_random_uuid(),
  role       text not null references public.roles(code) on delete cascade,
  permission text not null check (permission in (
               'reservations.edit_any',   'reservations.edit_own_department',
               'reservations.cancel_any', 'reservations.cancel_own_department')),
  unique (role, permission)
);

-- Valores por defecto (CAMBIABLES, ver notas al final):
--   admin      -> edita y cancela cualquier reserva
--   operador   -> edita y cancela las reservas de SU departamento
--   supervisor -> nada hasta que el admin lo autorice
insert into public.role_permissions (role, permission) values
  ('admin',    'reservations.edit_any'),
  ('admin',    'reservations.cancel_any'),
  ('operador', 'reservations.edit_own_department'),
  ('operador', 'reservations.cancel_own_department');

alter table public.role_permissions enable row level security;

create policy role_permissions_select on public.role_permissions
  for select to authenticated using (public.is_active_user());
create policy role_permissions_admin_write on public.role_permissions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create trigger audit_role_permissions
  after insert or update or delete on public.role_permissions
  for each row execute function public.audit_trigger();

-- ¿Puede el usuario actual hacer p_action ('edit' | 'cancel') sobre una
-- reserva de ese departamento?
create or replace function public.can_manage_reservation(p_action text, p_res_department uuid)
returns boolean
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_role text;
  v_dept uuid;
begin
  select p.role, p.department_id into v_role, v_dept
    from public.profiles p where p.id = auth.uid() and p.active;
  if v_role is null then return false; end if;

  return exists (select 1 from public.role_permissions rp
                  where rp.role = v_role
                    and rp.permission = 'reservations.' || p_action || '_any')
      or ( v_dept is not null and v_dept = p_res_department
           and exists (select 1 from public.role_permissions rp
                        where rp.role = v_role
                          and rp.permission = 'reservations.' || p_action || '_own_department') );
end;
$$;

-- ---------- 3. VALIDACIÓN COMÚN ----------------------------------------
create or replace function public.reservation_input_error(
  p_people int, p_name text, p_phone text, p_email text, p_notes text, p_type_id uuid
) returns text
language plpgsql stable
set search_path = public
as $$
begin
  if p_people is null or p_people < 1 then
    return 'Indica un número de personas válido.';
  end if;
  if char_length(p_name) < 2 or char_length(p_name) > 120 then
    return 'Indica el nombre del responsable de la reserva.';
  end if;
  if p_phone !~ '^[0-9+()\s.\-]{6,20}$' then
    return 'El teléfono no parece válido.';
  end if;
  if p_email is not null and p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return 'El email no parece válido.';
  end if;
  if p_notes is not null and char_length(p_notes) > 1000 then
    return 'Las observaciones son demasiado largas (máximo 1000 caracteres).';
  end if;
  if p_type_id is not null and not exists (
       select 1 from public.reservation_types where id = p_type_id and active) then
    return 'El tipo de reserva seleccionado no está disponible.';
  end if;
  return null;
end;
$$;

-- ---------- 4. MODIFICAR RESERVA ---------------------------------------
-- Orden de bloqueos: reserva -> franjas (ordenadas por id). Evita interbloqueos.
-- Errores: NOT_FOUND | FORBIDDEN | NOT_EDITABLE | INVALID_INPUT |
--          SLOT_NOT_FOUND | SLOT_CLOSED | CAPACITY
create or replace function public.update_reservation(
  p_reservation_id      uuid,
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
  v_old       public.reservations%rowtype;
  v_new       public.reservations%rowtype;
  v_slot      public.time_slots%rowtype;
  v_event     public.events%rowtype;
  v_available int;
  v_err       text;
  v_name      text := trim(coalesce(p_customer_name, ''));
  v_phone     text := trim(coalesce(p_phone, ''));
  v_email     text := nullif(trim(coalesce(p_email, '')), '');
  v_notes     text := nullif(trim(coalesce(p_notes, '')), '');
begin
  if not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_old from public.reservations where id = p_reservation_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
      'message', 'No se ha encontrado la reserva.');
  end if;

  if not public.can_manage_reservation('edit', v_old.department_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN',
      'message', 'No tienes permiso para modificar esta reserva.');
  end if;

  if v_old.status <> 'CONFIRMADA' then
    return jsonb_build_object('ok', false, 'error', 'NOT_EDITABLE',
      'message', 'Solo se pueden modificar reservas confirmadas.');
  end if;

  v_err := public.reservation_input_error(p_people, v_name, v_phone, v_email, v_notes, p_reservation_type_id);
  if v_err is not null then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT', 'message', v_err);
  end if;

  -- Bloquear franja actual y nueva, siempre en el mismo orden
  perform 1 from public.time_slots
   where id in (v_old.slot_id, p_slot_id)
   order by id
   for update;

  select * into v_slot from public.time_slots where id = p_slot_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SLOT_NOT_FOUND',
      'message', 'La franja seleccionada no existe.');
  end if;
  if v_slot.event_id <> v_old.event_id then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'No se puede mover una reserva a otro evento.');
  end if;

  select * into v_event from public.events where id = v_slot.event_id;
  if (p_slot_id <> v_old.slot_id or p_people > v_old.people_count)
     and (not v_slot.active or not v_event.active) then
    return jsonb_build_object('ok', false, 'error', 'SLOT_CLOSED',
      'message', 'Esa franja no admite más reservas en este momento.');
  end if;

  -- Plazas disponibles PARA ESTA reserva (si sigue en la misma franja,
  -- sus propias plazas cuentan como libres)
  v_available := v_slot.capacity - public.slot_occupied(p_slot_id)
                 + case when p_slot_id = v_old.slot_id then v_old.people_count else 0 end;

  if p_people > v_available then
    return jsonb_build_object(
      'ok', false, 'error', 'CAPACITY', 'remaining', greatest(v_available, 0),
      'message', case
        when v_available <= 0
          then 'Esa franja está completa. Elige otra hora.'
        when p_slot_id = v_old.slot_id
          then 'No hay capacidad suficiente: en esta franja como máximo puedes reservar '
               || v_available || ' personas.'
        else 'No hay capacidad suficiente en la nueva franja: solo quedan '
             || v_available || ' plazas.'
      end);
  end if;

  update public.reservations
     set slot_id             = p_slot_id,
         people_count        = p_people,
         customer_name       = v_name,
         phone               = v_phone,
         email               = v_email,
         reservation_type_id = p_reservation_type_id,
         notes               = v_notes
   where id = p_reservation_id
   returning * into v_new;

  perform public.write_audit('reservation_update', 'reservations', v_new.id::text,
                             to_jsonb(v_old), to_jsonb(v_new));

  return jsonb_build_object(
    'ok', true,
    'reservation_id', v_new.id,
    'reservation_code', v_new.reservation_code,
    'remaining', v_available - p_people);
end;
$$;

-- ---------- 5. CANCELAR RESERVA ----------------------------------------
-- Errores: NOT_FOUND | FORBIDDEN | ALREADY_CANCELLED | NOT_CANCELLABLE
create or replace function public.cancel_reservation(
  p_reservation_id uuid,
  p_reason         text default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_old       public.reservations%rowtype;
  v_new       public.reservations%rowtype;
  v_reason    text := nullif(trim(coalesce(p_reason, '')), '');
  v_remaining int;
begin
  if not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_old from public.reservations where id = p_reservation_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
      'message', 'No se ha encontrado la reserva.');
  end if;

  if not public.can_manage_reservation('cancel', v_old.department_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN',
      'message', 'No tienes permiso para cancelar esta reserva.');
  end if;

  if v_old.status = 'CANCELADA' then
    return jsonb_build_object('ok', false, 'error', 'ALREADY_CANCELLED',
      'message', 'Esta reserva ya estaba cancelada.');
  end if;
  if v_old.status <> 'CONFIRMADA' then
    return jsonb_build_object('ok', false, 'error', 'NOT_CANCELLABLE',
      'message', 'Solo se pueden cancelar reservas confirmadas.');
  end if;

  if v_reason is not null and char_length(v_reason) > 500 then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'El motivo es demasiado largo (máximo 500 caracteres).');
  end if;

  update public.reservations
     set status        = 'CANCELADA',
         cancelled_at  = now(),
         cancelled_by  = auth.uid(),
         cancel_reason = v_reason
   where id = p_reservation_id
   returning * into v_new;

  perform public.write_audit('reservation_cancel', 'reservations', v_new.id::text,
                             to_jsonb(v_old), to_jsonb(v_new));

  select ts.capacity - public.slot_occupied(ts.id) into v_remaining
    from public.time_slots ts where ts.id = v_new.slot_id;

  return jsonb_build_object(
    'ok', true,
    'reservation_id', v_new.id,
    'reservation_code', v_new.reservation_code,
    'remaining', v_remaining);
end;
$$;

-- ---------- 6. CAMBIAR ESTADO (REALIZADA / NO PRESENTADO / CONFIRMADA) --
-- Sirve para marcar asistencia y para corregir errores.
-- Cancelar NO se hace aquí (usa cancel_reservation). Una cancelada no se reactiva.
-- Errores: NOT_FOUND | FORBIDDEN | INVALID_INPUT | NOT_EDITABLE | CAPACITY
create or replace function public.set_reservation_status(
  p_reservation_id uuid,
  p_status         text
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_old       public.reservations%rowtype;
  v_new       public.reservations%rowtype;
  v_slot      public.time_slots%rowtype;
  v_available int;
begin
  if not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if p_status is null or p_status not in ('CONFIRMADA','REALIZADA','NO_PRESENTADO') then
    return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT',
      'message', 'Estado no válido. Para cancelar usa la opción "Cancelar reserva".');
  end if;

  select * into v_old from public.reservations where id = p_reservation_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'NOT_FOUND',
      'message', 'No se ha encontrado la reserva.');
  end if;

  if not public.can_manage_reservation('edit', v_old.department_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN',
      'message', 'No tienes permiso para modificar esta reserva.');
  end if;

  if v_old.status = 'CANCELADA' then
    return jsonb_build_object('ok', false, 'error', 'NOT_EDITABLE',
      'message', 'Una reserva cancelada no se puede reactivar. Crea una reserva nueva.');
  end if;

  select * into v_slot from public.time_slots where id = v_old.slot_id for update;

  -- Si pasa de NO consumir plazas a consumirlas, hay que comprobar capacidad
  if public.status_consumes_capacity(p_status, v_old.event_id)
     and not public.status_consumes_capacity(v_old.status, v_old.event_id) then
    v_available := v_slot.capacity - public.slot_occupied(v_slot.id);
    if v_old.people_count > v_available then
      return jsonb_build_object('ok', false, 'error', 'CAPACITY',
        'remaining', greatest(v_available, 0),
        'message', 'No se puede volver a confirmar: la franja ya no tiene plazas suficientes (quedan '
                   || greatest(v_available, 0) || ').');
    end if;
  end if;

  update public.reservations set status = p_status
   where id = p_reservation_id
   returning * into v_new;

  perform public.write_audit('reservation_status_change', 'reservations', v_new.id::text,
                             to_jsonb(v_old), to_jsonb(v_new));

  return jsonb_build_object('ok', true, 'reservation_id', v_new.id,
                            'reservation_code', v_new.reservation_code, 'status', v_new.status);
end;
$$;

-- ---------- 7. PERMISOS DE EJECUCIÓN -----------------------------------
revoke all on function public.can_manage_reservation(text, uuid)                     from public, anon;
revoke all on function public.reservation_input_error(int,text,text,text,text,uuid) from public, anon;
revoke all on function public.update_reservation(uuid,uuid,int,text,text,text,uuid,text) from public, anon;
revoke all on function public.cancel_reservation(uuid,text)                          from public, anon;
revoke all on function public.set_reservation_status(uuid,text)                      from public, anon;

grant execute on function public.can_manage_reservation(text, uuid)                     to authenticated;
grant execute on function public.reservation_input_error(int,text,text,text,text,uuid) to authenticated;
grant execute on function public.update_reservation(uuid,uuid,int,text,text,text,uuid,text) to authenticated;
grant execute on function public.cancel_reservation(uuid,text)                          to authenticated;
grant execute on function public.set_reservation_status(uuid,text)                      to authenticated;

-- ---------- NOTAS: CÓMO CAMBIAR PERMISOS -------------------------------
-- Dejar que los operadores editen/cancelen CUALQUIER reserva:
--   insert into public.role_permissions (role, permission) values
--     ('operador','reservations.edit_any'), ('operador','reservations.cancel_any');
-- Autorizar a los supervisores a modificar y cancelar todo:
--   insert into public.role_permissions (role, permission) values
--     ('supervisor','reservations.edit_any'), ('supervisor','reservations.cancel_any');
-- Quitar un permiso:
--   delete from public.role_permissions
--    where role = 'operador' and permission = 'reservations.cancel_own_department';
