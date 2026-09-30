-- =====================================================================
-- FASE 5 · PRUEBAS (modificar, cancelar, estados, auditoría, permisos)
-- No hace falta editar nada. Termina con un "error" intencionado que
-- contiene el informe y REVIERTE todo (no deja datos de prueba).
-- Requiere un evento activo y un usuario activo con departamento.
-- =====================================================================
create or replace function pg_temp.chk(p_ok boolean, p_txt text)
returns text language sql as $$
  select case when p_ok then 'OK    ' else 'FALLO ' end || p_txt || chr(10)
$$;

do $$
declare
  v_uid   uuid;
  v_dept  uuid;
  v_dept2 uuid;
  v_event public.events%rowtype;
  v_s1    uuid;
  v_s2    uuid;
  v_a     uuid;
  v_b     uuid;
  v_c     uuid;
  v_r     jsonb;
  v_n     int;
  v_row   public.reservations%rowtype;
  v_out   text := '';
begin
  select id, department_id into v_uid, v_dept
    from public.profiles
   where active and department_id is not null
   order by (role = 'admin') desc limit 1;
  if v_uid is null then raise exception 'No hay usuario activo con departamento'; end if;

  select * into v_event from public.events where active limit 1;
  if not found then raise exception 'No hay evento activo'; end if;

  insert into public.time_slots (event_id, date, start_time, end_time, capacity)
    values (v_event.id, v_event.start_date, '22:10', '22:59', 30) returning id into v_s1;
  insert into public.time_slots (event_id, date, start_time, end_time, capacity)
    values (v_event.id, v_event.start_date, '22:11', '22:59', 5)  returning id into v_s2;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- Preparación: A = 2 personas, B = 25 personas  -> ocupadas 27, quedan 3
  v_r := public.create_reservation(v_s1, 2,  'Reserva A', '600000001'); v_a := (v_r->>'reservation_id')::uuid;
  v_r := public.create_reservation(v_s1, 25, 'Reserva B', '600000002'); v_b := (v_r->>'reservation_id')::uuid;
  v_out := v_out || pg_temp.chk(public.slot_occupied(v_s1) = 27, '0.  Preparación: 27 plazas ocupadas de 30');

  -- ---- MODIFICAR PERSONAS -------------------------------------------
  v_r := public.update_reservation(v_a, v_s1, 10, 'Reserva A', '600000001');
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'CAPACITY' and (v_r->>'remaining')::int = 5,
            '1a. Cambiar de 2 a 10 personas con 3 libres es rechazado (máximo 5)');
  v_out := v_out || pg_temp.chk(public.slot_occupied(v_s1) = 27,
            '1b. Tras el rechazo la ocupación no cambia (27)');

  v_r := public.update_reservation(v_a, v_s1, 5, 'Reserva A', '600000001');
  v_out := v_out || pg_temp.chk((v_r->>'ok')::boolean and public.slot_occupied(v_s1) = 30,
            '1c. Subir de 2 a 5 (justo las libres) es aceptado y llena la franja');

  v_r := public.update_reservation(v_a, v_s1, 6, 'Reserva A', '600000001');
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'CAPACITY', '1d. Subir a 6 con la franja completa es rechazado');

  v_r := public.update_reservation(v_a, v_s1, 1, 'Reserva A', '600000001');
  v_out := v_out || pg_temp.chk((v_r->>'ok')::boolean and public.slot_occupied(v_s1) = 26,
            '1e. Reducir a 1 persona libera plazas (26 ocupadas)');

  -- ---- CAMBIAR DE FRANJA --------------------------------------------
  v_r := public.update_reservation(v_a, v_s2, 6, 'Reserva A', '600000001');
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'CAPACITY'
              and (select slot_id from public.reservations where id = v_a) = v_s1,
            '2a. Mover a una franja sin hueco (6 en capacidad 5) es rechazado y no se mueve');

  v_r := public.update_reservation(v_a, v_s2, 1, 'Reserva A', '600000001');
  v_out := v_out || pg_temp.chk((v_r->>'ok')::boolean
              and public.slot_occupied(v_s1) = 25 and public.slot_occupied(v_s2) = 1,
            '2b. Mover a otra franja con hueco funciona y actualiza ambas ocupaciones');

  -- ---- CANCELAR ------------------------------------------------------
  v_r := public.cancel_reservation(v_b, 'Prueba');
  select * into v_row from public.reservations where id = v_b;
  v_out := v_out || pg_temp.chk((v_r->>'ok')::boolean and public.slot_occupied(v_s1) = 0
              and v_row.status = 'CANCELADA' and v_row.cancelled_at is not null
              and v_row.cancelled_by = v_uid and v_row.cancel_reason = 'Prueba',
            '3a. Cancelar libera 25 plazas y registra fecha, usuario y motivo');

  v_r := public.cancel_reservation(v_b);
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'ALREADY_CANCELLED', '3b. Cancelar dos veces es rechazado');

  v_r := public.update_reservation(v_b, v_s1, 3, 'Reserva B', '600000002');
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'NOT_EDITABLE', '3c. No se puede modificar una reserva cancelada');

  v_r := public.set_reservation_status(v_b, 'CONFIRMADA');
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'NOT_EDITABLE', '3d. Una cancelada no se puede reactivar');

  -- ---- CAMBIOS DE ESTADO --------------------------------------------
  v_r := public.set_reservation_status(v_a, 'NO_PRESENTADO');
  v_out := v_out || pg_temp.chk((v_r->>'ok')::boolean and public.slot_occupied(v_s2) = 1,
            '4a. Marcar NO_PRESENTADO funciona (con la opción por defecto sigue ocupando)');

  v_r := public.set_reservation_status(v_a, 'CANCELADA');
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'INVALID_INPUT', '4b. No se puede cancelar por la vía de cambio de estado');

  v_r := public.set_reservation_status(v_a, 'CONFIRMADA');
  v_out := v_out || pg_temp.chk((v_r->>'ok')::boolean, '4c. Volver a CONFIRMADA funciona');

  -- ---- AUDITORÍA -----------------------------------------------------
  select count(*) into v_n from public.audit_log
   where entity_id = v_a::text and action = 'reservation_update';
  v_out := v_out || pg_temp.chk(v_n = 3, '5a. Las 3 modificaciones válidas de A están auditadas (hay ' || v_n || ')');

  select count(*) into v_n from public.audit_log
   where entity_id = v_b::text and action = 'reservation_cancel' and user_id = v_uid;
  v_out := v_out || pg_temp.chk(v_n = 1, '5b. La cancelación de B está auditada con su usuario');

  -- ---- PERMISOS ------------------------------------------------------
  v_r := public.create_reservation(v_s1, 1, 'Reserva C', '600000003'); v_c := (v_r->>'reservation_id')::uuid;
  insert into public.departments (name) values ('Departamento de prueba') returning id into v_dept2;

  update public.profiles set role = 'operador', department_id = v_dept2 where id = v_uid;
  v_r := public.cancel_reservation(v_c);
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'FORBIDDEN',
            '6a. Un operador NO puede cancelar reservas de otro departamento');
  v_r := public.update_reservation(v_c, v_s1, 2, 'Reserva C', '600000003');
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'FORBIDDEN',
            '6b. Un operador NO puede modificar reservas de otro departamento');

  update public.profiles set role = 'supervisor', department_id = v_dept where id = v_uid;
  v_r := public.cancel_reservation(v_c);
  v_out := v_out || pg_temp.chk(v_r->>'error' = 'FORBIDDEN',
            '6c. Un supervisor sin autorización NO puede cancelar');

  update public.profiles set role = 'admin', department_id = v_dept2 where id = v_uid;
  v_r := public.update_reservation(v_c, v_s1, 2, 'Reserva C', '600000003');
  v_out := v_out || pg_temp.chk((v_r->>'ok')::boolean,
            '6d. Un admin puede modificar reservas de cualquier departamento');

  update public.profiles set role = 'operador', department_id = v_dept where id = v_uid;
  v_r := public.cancel_reservation(v_c);
  v_out := v_out || pg_temp.chk((v_r->>'ok')::boolean,
            '6e. Un operador SÍ puede cancelar reservas de su propio departamento');

  raise exception E'\n=== RESULTADOS FASE 5 (todo se ha revertido, es normal ver este "error") ===\n%', v_out;
end;
$$;
