-- =====================================================================
-- FASE 4 · PRUEBAS DE LÓGICA (capacidad, cancelación, red de seguridad)
--
-- No hace falta editar nada: el script elige automáticamente un usuario
-- ACTIVO con departamento en public.profiles (prefiere un admin).
--
-- El script termina SIEMPRE con un "error" a propósito que contiene el
-- informe. Ese error hace que Postgres REVIERTA todo: no deja datos de
-- prueba. (Solo se "gastan" números de la secuencia RES-xxxxxx.)
-- =====================================================================
do $$
declare
  v_uid   uuid;
  v_event public.events%rowtype;
  v_slot  uuid;
  v_out   text := '';
  v_r     jsonb;
  v_ok    int := 0;
  v_id2   uuid;
  i       int;
begin
  -- Usuario de prueba: un perfil ACTIVO con departamento (prefiere admin)
  select id into v_uid from public.profiles
   where active and department_id is not null
   order by (role = 'admin') desc
   limit 1;
  if v_uid is null then
    raise exception E'No hay ningún usuario activo con departamento.\nSolución: crea un departamento y asígnalo a tu admin:\n  insert into public.departments (name) values (''Administración'');\n  update public.profiles set department_id = (select id from public.departments limit 1) where role = ''admin'';';
  end if;

  select * into v_event from public.events where active limit 1;
  if not found then raise exception 'No hay evento activo'; end if;

  insert into public.time_slots (event_id, date, start_time, end_time, capacity)
  values (v_event.id, v_event.start_date, '23:30', '23:59', 30)
  returning id into v_slot;

  -- Simula la sesión del usuario (auth.uid())
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ---- TEST 1: llenar hasta 30 e intentar 1 más ----------------------
  for i in 1..6 loop
    v_r := public.create_reservation(v_slot, 5, 'Test ' || i, '600000000');
    if (v_r->>'ok')::boolean then v_ok := v_ok + 1; end if;
  end loop;
  v_out := v_out || case when v_ok = 6 then 'OK    ' else 'FALLO ' end
        || '1a. 6 reservas de 5 personas aceptadas (capacidad 30)' || chr(10);

  v_r := public.create_reservation(v_slot, 1, 'Test extra', '600000000');
  v_out := v_out || case when v_r->>'error' = 'CAPACITY' then 'OK    ' else 'FALLO ' end
        || '1b. La reserva 31 es rechazada con error CAPACITY' || chr(10);

  -- ---- TEST 2: cancelar libera plazas --------------------------------
  update public.reservations
     set status = 'CANCELADA', cancelled_at = now(), cancelled_by = v_uid
   where id = (select id from public.reservations
                where slot_id = v_slot order by created_at limit 1);

  v_out := v_out || case when public.slot_occupied(v_slot) = 25 then 'OK    ' else 'FALLO ' end
        || '2a. Tras cancelar una reserva de 5, ocupadas = 25' || chr(10);

  v_r := public.create_reservation(v_slot, 5, 'Test tras cancelar', '600000000');
  v_out := v_out || case when (v_r->>'ok')::boolean then 'OK    ' else 'FALLO ' end
        || '2b. Se pueden volver a reservar las 5 plazas liberadas' || chr(10);

  v_r := public.create_reservation(v_slot, 1, 'Test extra 2', '600000000');
  v_out := v_out || case when v_r->>'error' = 'CAPACITY' then 'OK    ' else 'FALLO ' end
        || '2c. Franja de nuevo completa: 1 más es rechazada' || chr(10);

  -- ---- TEST 3: red de seguridad (inserción directa saltándose el RPC) -
  begin
    insert into public.reservations
      (event_id, slot_id, customer_name, phone, people_count, department_id, created_by)
    select v_event.id, v_slot, 'Directo', '600000000', 1, p.department_id, v_uid
      from public.profiles p where p.id = v_uid;
    v_out := v_out || 'FALLO ' || '3.  Un INSERT directo SUPERÓ la capacidad' || chr(10);
  exception when others then
    v_out := v_out || 'OK    ' || '3.  Un INSERT directo que supera la capacidad es abortado por el trigger' || chr(10);
  end;

  -- ---- TEST 4: no bajar capacidad por debajo de lo reservado ---------
  begin
    update public.time_slots set capacity = 10 where id = v_slot;
    v_out := v_out || 'FALLO ' || '4.  Se redujo la capacidad por debajo de lo reservado' || chr(10);
  exception when others then
    v_out := v_out || 'OK    ' || '4.  No se puede reducir la capacidad por debajo de lo reservado' || chr(10);
  end;

  -- ---- TEST 5: NO PRESENTADO configurable ----------------------------
  update public.events set no_show_consumes_capacity = false where id = v_event.id;

  select id into v_id2 from public.reservations
   where slot_id = v_slot and status = 'CONFIRMADA' order by created_at limit 1;
  update public.reservations set status = 'NO_PRESENTADO' where id = v_id2;

  v_out := v_out || case when public.slot_occupied(v_slot) = 25 then 'OK    ' else 'FALLO ' end
        || '5a. Con la opción desactivada, un no presentado libera sus plazas' || chr(10);

  v_r := public.create_reservation(v_slot, 5, 'Test tras no-show', '600000000');
  v_out := v_out || case when (v_r->>'ok')::boolean then 'OK    ' else 'FALLO ' end
        || '5b. Esas plazas se pueden reservar de nuevo' || chr(10);

  begin
    update public.events set no_show_consumes_capacity = true where id = v_event.id;
    v_out := v_out || 'FALLO ' || '5c.  Se reactivó la opción provocando sobreaforo' || chr(10);
  exception when others then
    v_out := v_out || 'OK    ' || '5c. No se puede reactivar la opción si provocaría sobreaforo' || chr(10);
  end;

  raise exception E'\n=== RESULTADOS (todo se ha revertido, es normal ver este "error") ===\n%',
    v_out;
end;
$$;
