-- =====================================================================
-- FASE 6 · PRUEBAS de la capa de lectura
-- No hace falta editar nada. Termina con un "error" intencionado que
-- contiene el informe y REVIERTE todo.
-- =====================================================================
create or replace function pg_temp.chk(p_ok boolean, p_txt text)
returns text language sql as $$
  select case when p_ok then 'OK    ' else 'FALLO ' end || p_txt || chr(10)
$$;

do $$
declare
  v_uid    uuid;
  v_event  public.events%rowtype;
  v_slot   uuid;
  v_a      uuid;
  v_b      uuid;
  v_code   text;
  v_r      jsonb;
  v_n      int;
  v_before public.daily_summary%rowtype;
  v_after  public.daily_summary%rowtype;
  v_stats  jsonb;
  v_out    text := '';
begin
  select id into v_uid from public.profiles
   where active and department_id is not null
   order by (role = 'admin') desc limit 1;
  if v_uid is null then raise exception 'No hay usuario activo con departamento'; end if;

  select * into v_event from public.events where active limit 1;
  if not found then raise exception 'No hay evento activo'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- Estado del día ANTES de crear nada (puede no existir si no hay franjas)
  select * into v_before from public.daily_summary
   where event_id = v_event.id and date = v_event.start_date;

  insert into public.time_slots (event_id, date, start_time, end_time, capacity)
    values (v_event.id, v_event.start_date, '22:30', '22:59', 30) returning id into v_slot;

  v_r := public.create_reservation(v_slot, 3, 'Zeta Buscable', '611 222 333', 'zeta@ejemplo.org');
  v_a := (v_r->>'reservation_id')::uuid;  v_code := v_r->>'reservation_code';
  v_r := public.create_reservation(v_slot, 4, 'Otra Persona', '699000111');
  v_b := (v_r->>'reservation_id')::uuid;

  -- ---- DAILY_SUMMARY -------------------------------------------------
  select * into v_after from public.daily_summary
   where event_id = v_event.id and date = v_event.start_date;

  v_out := v_out || pg_temp.chk(
    v_after.capacity     = coalesce(v_before.capacity, 0) + 30
    and v_after.occupied = coalesce(v_before.occupied, 0) + 7
    and v_after.reservations = coalesce(v_before.reservations, 0) + 2,
    '1a. daily_summary suma +30 capacidad, +7 personas y +2 reservas');

  perform public.cancel_reservation(v_b);
  select * into v_after from public.daily_summary
   where event_id = v_event.id and date = v_event.start_date;

  v_out := v_out || pg_temp.chk(
    v_after.occupied     = coalesce(v_before.occupied, 0) + 3
    and v_after.reservations = coalesce(v_before.reservations, 0) + 1
    and v_after.cancelled    = coalesce(v_before.cancelled, 0) + 1,
    '1b. Tras cancelar una de 4: personas +3, vigentes +1, canceladas +1');

  -- ---- BÚSQUEDA ------------------------------------------------------
  select count(*) into v_n from public.search_reservations('611222333') where id = v_a;
  v_out := v_out || pg_temp.chk(v_n = 1, '2a. Buscar por teléfono (sin espacios) encuentra la reserva');

  select count(*) into v_n from public.search_reservations('611 222') where id = v_a;
  v_out := v_out || pg_temp.chk(v_n = 1, '2b. Buscar por parte del teléfono (con espacios) la encuentra');

  select count(*) into v_n from public.search_reservations('zeta buscable') where id = v_a;
  v_out := v_out || pg_temp.chk(v_n = 1, '2c. Buscar por nombre (sin distinguir mayúsculas) la encuentra');

  select count(*) into v_n from public.search_reservations(v_code) where id = v_a;
  v_out := v_out || pg_temp.chk(v_n = 1, '2d. Buscar por código completo (' || v_code || ') la encuentra');

  select count(*) into v_n from public.search_reservations(
      (regexp_replace(v_code, '\D', '', 'g'))::int::text) where id = v_a;
  v_out := v_out || pg_temp.chk(v_n = 1, '2e. Buscar solo por el número del código la encuentra');

  select count(*) into v_n from public.search_reservations('zeta@ejemplo') where id = v_a;
  v_out := v_out || pg_temp.chk(v_n = 1, '2f. Buscar por email la encuentra');

  select count(*) into v_n from public.search_reservations(to_char(v_event.start_date, 'YYYY-MM-DD')) where id = v_a;
  v_out := v_out || pg_temp.chk(v_n = 1, '2g. Buscar por fecha (AAAA-MM-DD) la encuentra');

  select count(*) into v_n from public.search_reservations(to_char(v_event.start_date, 'DD/MM/YYYY')) where id = v_a;
  v_out := v_out || pg_temp.chk(v_n = 1, '2h. Buscar por fecha (DD/MM/AAAA) la encuentra');

  select count(*) into v_n from public.search_reservations('%');
  v_out := v_out || pg_temp.chk(v_n = 0, '2i. Buscar "%" no devuelve todo (comodines escapados)');

  -- ---- ESTADÍSTICAS --------------------------------------------------
  v_stats := public.event_stats();
  v_out := v_out || pg_temp.chk(
    (v_stats->'totals'->>'people')::int >= 3
    and (v_stats->'totals'->>'cancelled')::int >= 1
    and jsonb_typeof(v_stats->'by_department') = 'array'
    and jsonb_typeof(v_stats->'by_day') = 'array'
    and jsonb_typeof(v_stats->'by_slot') = 'array',
    '3a. event_stats devuelve totales y las tres agrupaciones (admin)');

  update public.profiles set role = 'operador' where id = v_uid;
  begin
    perform public.event_stats();
    v_out := v_out || pg_temp.chk(false, '3b. Un operador pudo ver las estadísticas');
  exception when others then
    v_out := v_out || pg_temp.chk(true, '3b. Un operador NO puede ver las estadísticas');
  end;

  begin
    select count(*) into v_n from public.audit_log_view;
    -- Como superusuario la RLS no aplica; la comprobación real de RLS se hace con el rol authenticated:
    set local role authenticated;
    select count(*) into v_n from public.audit_log_view;
    reset role;
    v_out := v_out || pg_temp.chk(v_n = 0, '3c. Un operador ve 0 filas del registro de actividad (RLS)');
  exception when others then
    reset role;
    v_out := v_out || pg_temp.chk(false, '3c. Error al consultar el registro como operador: ' || sqlerrm);
  end;

  update public.profiles set role = 'admin' where id = v_uid;
  begin
    set local role authenticated;
    select count(*) into v_n from public.audit_log_view;
    reset role;
    v_out := v_out || pg_temp.chk(v_n > 0, '3d. Un admin ve el registro de actividad (' || v_n || ' filas)');
  exception when others then
    reset role;
    v_out := v_out || pg_temp.chk(false, '3d. Error al consultar el registro como admin: ' || sqlerrm);
  end;

  -- ---- REALTIME ------------------------------------------------------
  select count(*) into v_n from pg_publication_tables
   where pubname = 'supabase_realtime' and schemaname = 'public'
     and tablename in ('reservations', 'time_slots');
  v_out := v_out || pg_temp.chk(v_n = 2, '4.  reservations y time_slots están publicadas en Realtime');

  raise exception E'\n=== RESULTADOS FASE 6 (todo se ha revertido, es normal ver este "error") ===\n%', v_out;
end;
$$;
