-- =====================================================================
-- FASE 1 · Base de datos + autenticación + roles
-- Ejecutar en Supabase (SQL Editor o como migración).
-- Requisito previo: en Authentication > Providers > Email, DESACTIVAR
-- "Allow new users to sign up". Los usuarios los crea el administrador.
-- =====================================================================

-- ---------- 1. ROLES (tabla, no enum: permite añadir roles después) ---
create table public.roles (
  code        text primary key,
  description text not null
);

insert into public.roles (code, description) values
  ('admin',      'Administrador: control total y configuración'),
  ('supervisor', 'Supervisor: consulta global y estadísticas'),
  ('operador',   'Operador/Personal: gestión diaria de reservas');

-- ---------- 2. DEPARTAMENTOS ------------------------------------------
create table public.departments (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (length(trim(name)) > 0),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- 3. PERFILES (1:1 con auth.users) ---------------------------
create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  nombre        text not null default '',
  email         text not null,
  role          text not null default 'operador' references public.roles(code),
  department_id uuid references public.departments(id),
  active        boolean not null default false,   -- se activa explícitamente
  created_at    timestamptz not null default now()
);

create index profiles_department_idx on public.profiles(department_id);

-- Al crearse un usuario en auth.users se crea su perfil.
-- IMPORTANTE: nunca se lee el rol desde metadatos del cliente.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, nombre, role, active)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data->>'nombre', ''),
    'operador',
    false
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 4. FUNCIONES AUXILIARES DE PERMISOS ------------------------
-- security definer + search_path fijo: evitan recursión en RLS.
create or replace function public.current_user_role()
returns text
language sql stable security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid() and active = true;
$$;

create or replace function public.is_active_user()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active = true);
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() = 'admin', false);
$$;

create or replace function public.is_supervisor_or_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() in ('admin','supervisor'), false);
$$;

-- ---------- 5. AUDITORÍA (estructura base; se amplía en Fase 9) --------
create table public.audit_log (
  id            bigint generated always as identity primary key,
  user_id       uuid references auth.users(id),
  department_id uuid references public.departments(id),
  action        text not null,
  entity_type   text not null,
  entity_id     text,
  old_data      jsonb,
  new_data      jsonb,
  created_at    timestamptz not null default now()
);

create index audit_log_created_idx on public.audit_log(created_at desc);
create index audit_log_entity_idx  on public.audit_log(entity_type, entity_id);

-- Única vía de escritura en auditoría: esta función (no se inserta desde el cliente).
create or replace function public.write_audit(
  p_action text, p_entity_type text, p_entity_id text,
  p_old jsonb default null, p_new jsonb default null
) returns void
language plpgsql security definer
set search_path = public
as $$
declare v_dept uuid;
begin
  select department_id into v_dept from public.profiles where id = auth.uid();
  insert into public.audit_log (user_id, department_id, action, entity_type, entity_id, old_data, new_data)
  values (auth.uid(), v_dept, p_action, p_entity_type, p_entity_id, p_old, p_new);
end;
$$;

revoke all on function public.write_audit(text,text,text,jsonb,jsonb) from public, anon, authenticated;

-- Auditar cambios en profiles y departments (usuarios/departamentos)
create or replace function public.audit_trigger()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  perform public.write_audit(
    tg_table_name || '_' || lower(tg_op),
    tg_table_name,
    coalesce((case when tg_op = 'DELETE' then old.id else new.id end)::text, ''),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

create trigger audit_profiles
  after insert or update on public.profiles
  for each row execute function public.audit_trigger();

create trigger audit_departments
  after insert or update on public.departments
  for each row execute function public.audit_trigger();

-- ---------- 6. ROW LEVEL SECURITY --------------------------------------
alter table public.roles       enable row level security;
alter table public.departments enable row level security;
alter table public.profiles    enable row level security;
alter table public.audit_log   enable row level security;

-- roles: lectura para usuarios activos, escritura solo admin
create policy roles_select on public.roles
  for select to authenticated using (public.is_active_user());
create policy roles_admin_write on public.roles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- departments: lectura para activos, escritura solo admin
create policy departments_select on public.departments
  for select to authenticated using (public.is_active_user());
create policy departments_admin_write on public.departments
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- profiles: todos los activos ven nombre/departamento (se necesita para
-- "creada por"); solo admin modifica. Nadie puede cambiar su propio rol.
create policy profiles_select on public.profiles
  for select to authenticated
  using (public.is_active_user() or id = auth.uid());   -- un usuario inactivo puede ver su propio perfil para mostrar aviso
create policy profiles_admin_write on public.profiles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- audit_log: solo lectura, y solo admin/supervisor. Sin políticas de escritura.
create policy audit_select on public.audit_log
  for select to authenticated using (public.is_supervisor_or_admin());

-- ---------- 7. PRIMER ADMINISTRADOR (ejecutar UNA vez, a mano) ----------
-- 1) Crea el usuario en Supabase > Authentication > Users.
-- 2) Sustituye el email y ejecuta:
--
-- update public.profiles
--    set role = 'admin', active = true, nombre = 'Administrador'
--  where email = 'admin@tu-organizacion.com';
