
# PROMPT MAESTRO — FRONTEND · APP INTERNA DE RESERVAS

> Guarda este archivo en la raíz del repositorio (por ejemplo como `PROMPT_FRONTEND.md`, o como `AGENTS.md` / `CLAUDE.md` si tu asistente lo lee automáticamente) y pídele al asistente: **"Lee PROMPT_FRONTEND.md y empieza por la FASE A."**

---

## 0. CONTEXTO Y REGLA DE ORO

Construyes el **frontend** de una aplicación web interna de gestión de reservas para un evento. Se usa por teléfono: un trabajador atiende una llamada y registra la reserva en segundos. Varios departamentos trabajan a la vez sobre los mismos datos.

**El backend ya existe, está terminado y verificado** (Supabase: PostgreSQL + Auth + RLS + Realtime). Toda la lógica de negocio vive en la base de datos: capacidad, concurrencia, permisos, auditoría.

**Reglas que no se pueden romper:**

1. **NO modifiques, crees ni sugieras cambios directos en el esquema SQL.** Está en `supabase/migrations/` como referencia y ya está aplicado. Si crees que hace falta un cambio de backend, anótalo en `docs/backend-change-requests.md` (qué, por qué, propuesta) y **continúa sin él**.
2. **El frontend NO decide reglas de negocio.** No calcules capacidad para "aprobar" una reserva, no decidas permisos como fuente de verdad. El backend decide; el frontend muestra y avisa. Las comprobaciones del cliente son solo ayuda visual.
3. **Nunca uses la clave `service_role` en el frontend ni en Vercel.** Solo la clave `anon`/`publishable`.
4. **Nada de datos simulados** como sistema definitivo, ni `localStorage` como fuente de datos. Todo viene de Supabase.
5. **Nunca muestres errores técnicos** al usuario (nada de "Postgres", "constraint", códigos). Siempre mensajes claros en español.
6. Trabaja **por fases pequeñas y comprobables**. Al terminar cada una: `npm run typecheck`, `npm run lint`, `npm run build` sin errores, y verifica que lo anterior sigue funcionando.

---

## 1. STACK Y REPOSITORIO

- **Vite + React 18 + TypeScript (strict)**.
- **Tailwind CSS**. Componentes propios reutilizables (opcionalmente shadcn/ui).
- **react-router-dom** (rutas del punto 4).
- **@supabase/supabase-js v2**.
- **@tanstack/react-query** para caché y refetch.
- **zod** + **react-hook-form** para formularios.
- **recharts** para gráficos.
- **date-fns** (locale `es`) para fechas.
- **vitest** + Testing Library para pruebas de utilidades y componentes críticos.
- Sin dependencias innecesarias. Interfaz en **español**.

**Estructura sugerida**

```
/
├─ src/
│  ├─ lib/           supabase.ts, errors.ts, dates.ts, format.ts, permissions.ts
│  ├─ api/           un módulo por área: slots.ts, reservations.ts, admin.ts, stats.ts...
│  ├─ hooks/         useSession, useProfile, useRealtimeInvalidation...
│  ├─ components/    ui/ (Button, Card, Badge, Modal...), layout/, reservations/...
│  ├─ pages/         Login, Dashboard, Reservas, NuevaReserva, Reserva, Calendario, ...
│  ├─ types/         database.ts (tipos del esquema)
│  └─ main.tsx, App.tsx, routes.tsx
├─ supabase/
│  ├─ migrations/    (copia de los .sql ya aplicados, SOLO LECTURA)
│  └─ functions/admin-users/   (Edge Function, ver FASE G)
├─ docs/backend-change-requests.md
├─ .github/workflows/ci.yml    (typecheck + lint + test + build en cada push/PR)
├─ vercel.json
├─ .env.example
└─ README.md
```

**Variables de entorno** (`.env.example`, nunca commitear `.env`):

```
VITE_SUPABASE_URL=https://xxxx.supabase.co
VITE_SUPABASE_ANON_KEY=
```

**`vercel.json`** (SPA con rutas del cliente):

```json
{ "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }] }
```

Scripts en `package.json`: `dev`, `build`, `preview`, `typecheck`, `lint`, `test`.

---

## 2. CONTRATO DEL BACKEND (ya implementado)

Zona horaria de negocio: **Europe/Madrid**. Las fechas (`date`) son cadenas `YYYY-MM-DD`; las horas (`time`) llegan como `HH:MM:SS` → mostrar `HH:MM`. "Hoy" se calcula en Madrid, nunca con `toISOString()` (UTC).

### 2.1 Estados de reserva
`CONFIRMADA` · `CANCELADA` · `REALIZADA` · `NO_PRESENTADO`

### 2.2 Roles
`admin` · `supervisor` · `operador` (tabla `roles`, ampliable: no asumas solo estos tres al pintar).
Un usuario con `profiles.active = false` **no puede leer nada**: muestra una pantalla "Tu cuenta está pendiente de activación. Contacta con administración" y ofrece cerrar sesión.

### 2.3 Lecturas (SELECT con la sesión del usuario; la RLS filtra)

| Objeto | Campos principales |
|---|---|
| `profiles` | id, nombre, email, role, department_id, active |
| `departments` | id, name, active |
| `events` | id, name, description, logo_url, start_date, end_date, active, no_show_consumes_capacity |
| `reservation_types` | id, name, active, sort_order |
| `time_slots` | id, event_id, date, start_time, end_time, capacity, active |
| `role_permissions` | id, role, permission |
| **`slot_availability`** (vista) | slot_id, event_id, date, start_time, end_time, capacity, active, **occupied, remaining, is_full** |
| **`reservation_details`** (vista) | todos los campos de la reserva + slot_date, start_time, end_time, type_name, department_name, created_by_name, cancelled_by_name, cancel_reason |
| **`daily_summary`** (vista) | event_id, date, slots, capacity, occupied, remaining, occupancy_pct, reservations, cancelled, no_shows |
| `audit_log_view` (vista; solo supervisor/admin) | id, created_at, action, entity_type, entity_id, user_name, user_email, department_name, old_data, new_data |

Campos de `reservation_details`: `id, reservation_code, event_id, slot_id, customer_name, phone, email, people_count, reservation_type_id, notes, status, department_id, created_by, created_at, updated_at, cancelled_at, cancelled_by, cancel_reason`.

**Las reservas NO se escriben con INSERT/UPDATE/DELETE. Solo por RPC (siguiente sección).** Cualquier escritura directa fallará.

### 2.4 Escrituras: RPC (`supabase.rpc(nombre, params)`)

Todas devuelven JSON. Éxito: `{ ok: true, ... }`. Error de negocio: `{ ok: false, error: 'CODIGO', message: '...', remaining?: n }`. **Muestra siempre `message` tal cual** (ya está en lenguaje llano). Si `supabase.rpc` devuelve un `error` de transporte/permiso (no un `ok:false`), muestra un mensaje genérico ("No se ha podido completar la operación. Inténtalo de nuevo") y registra el detalle solo en consola.

**`create_reservation`**
`p_slot_id uuid, p_people int, p_customer_name text, p_phone text, p_email text?, p_reservation_type_id uuid?, p_notes text?`
→ ok: `{ reservation_id, reservation_code, people, remaining }`
→ errores: `CAPACITY` (con `remaining`), `SLOT_CLOSED`, `SLOT_NOT_FOUND`, `INVALID_INPUT`, `NO_DEPARTMENT`

**`update_reservation`**
`p_reservation_id uuid, p_slot_id uuid, p_people int, p_customer_name text, p_phone text, p_email text?, p_reservation_type_id uuid?, p_notes text?` (envía **todos** los campos; semántica de reemplazo)
→ ok: `{ reservation_id, reservation_code, remaining }`
→ errores: `NOT_FOUND`, `FORBIDDEN`, `NOT_EDITABLE`, `INVALID_INPUT`, `SLOT_NOT_FOUND`, `SLOT_CLOSED`, `CAPACITY` (con `remaining` = máximo de personas que caben para esa reserva)

**`cancel_reservation`**
`p_reservation_id uuid, p_reason text?`
→ ok: `{ reservation_id, reservation_code, remaining }`
→ errores: `NOT_FOUND`, `FORBIDDEN`, `ALREADY_CANCELLED`, `NOT_CANCELLABLE`, `INVALID_INPUT`

**`set_reservation_status`**
`p_reservation_id uuid, p_status text` (`CONFIRMADA` | `REALIZADA` | `NO_PRESENTADO`; para cancelar se usa `cancel_reservation`)
→ ok: `{ reservation_id, reservation_code, status }`
→ errores: `NOT_FOUND`, `FORBIDDEN`, `NOT_EDITABLE`, `INVALID_INPUT`, `CAPACITY`

**`search_reservations`**
`p_query text, p_limit int = 50` → devuelve filas de `reservation_details`. Busca por nombre, teléfono, código (`RES-000124` o `124`), email y fecha (`AAAA-MM-DD` o `DD/MM/AAAA`).

**`event_stats`** (solo supervisor/admin)
`p_event_id uuid?` (por defecto, el evento activo) → JSON:
`{ totals:{reservations,people,cancelled,no_shows}, avg_occupancy_pct, by_department:[{department,reservations,people}], by_day:[{date,reservations,people,capacity,occupancy_pct}], by_slot:[{start_time,people,capacity,occupancy_pct}] }`

**`can_manage_reservation`**
`p_action ('edit'|'cancel'), p_res_department uuid` → boolean. Úsalo (o la lógica equivalente sobre `role_permissions`) **solo para mostrar u ocultar botones**; la decisión real siempre la toma el backend.

**`generate_slots`** (solo admin)
`p_event_id, p_from date, p_to date, p_start_times time[], p_duration_min int, p_capacity int` → nº de franjas creadas.

### 2.5 Escrituras directas permitidas (solo admin, por RLS)
`departments`, `reservation_types`, `events`, `time_slots`, `role_permissions`, `roles`, y `profiles` (activar/rol/departamento). Los usuarios nuevos **no** se crean así (ver FASE G).

Errores esperables al editar como admin y su mensaje amigable:
- Reducir capacidad por debajo de lo reservado → "No puedes reducir la capacidad por debajo de las plazas ya reservadas (N)."
- Fecha de franja fuera del evento → "La fecha debe estar dentro de las fechas del evento."
- Acortar el evento dejando franjas fuera → "Hay franjas fuera del nuevo rango de fechas."
- Activar "no presentados ocupan plaza" causando sobreaforo → "No se puede activar: alguna franja superaría su capacidad."
- Franja duplicada → "Ya existe una franja a esa hora."
Traduce estos casos en `lib/errors.ts` detectando el texto/código del error de Postgres; cualquier otro → mensaje genérico.

---

## 3. REGLAS DE INTERFAZ

**Prioridades:** 1) rapidez, 2) claridad, 3) evitar errores, 4) información visible, 5) facilidad al atender una llamada.

- Diseño limpio, moderno, profesional. Botones grandes, textos claros. Los colores comunican **estado**, no decoran.
- **Semáforo de franjas** (calcúlalo desde `slot_availability`):
  - 🔴 **COMPLETO**: `remaining = 0` (o `is_full`).
  - 🟠 **POCAS PLAZAS**: `remaining > 0` y `remaining ≤ 30 %` de la capacidad. Texto: "Solo quedan N plazas".
  - 🟢 **DISPONIBLE**: el resto.
  - ⚪ **CERRADA**: `active = false`.
  - No dependas solo del color: incluye siempre texto/icono (accesibilidad).
- Franjas: "18 / 30 personas" + etiqueta de estado.
- Responsive real (móvil, tablet, portátil, sobremesa). En móvil, "Nueva reserva" debe ser especialmente cómoda (campos grandes, teclado numérico para personas y teléfono con `inputMode`).
- Navegación completa con **teclado** en Nueva reserva (orden de tabulación lógico, Enter avanza, foco inicial en fecha).
- Estados de carga (skeletons), vacíos ("No hay reservas para este día") y de error reintentables en todas las pantallas.
- Confirmaciones explícitas antes de cancelar.
- Mensajes de aviso:
  - 🟢 "Reserva disponible" · 🟠 "Solo quedan N plazas" · 🔴 "Esta franja está completa"
  - ⚠️ "La disponibilidad ha cambiado. Actualiza la reserva."
  - Si `create_reservation` devuelve `CAPACITY`: mostrar `message`, **refrescar la disponibilidad automáticamente** y mantener los datos ya escritos en el formulario para que el trabajador solo tenga que elegir otra franja.

---

## 4. RUTAS Y PANTALLAS

Rutas protegidas por sesión y rol (guardas de ruta; la seguridad real es RLS). Sin sesión → `/login`.

| Ruta | Rol mínimo | Contenido |
|---|---|---|
| `/login` | público | Logo del evento, "Gestión de reservas", email, contraseña, **ENTRAR**. Errores claros ("Email o contraseña incorrectos"). Sin registro público ni "crear cuenta". |
| `/dashboard` | operador | Bloque **HOY** (reservas, personas, plazas disponibles, % ocupación, cancelaciones, no presentados — desde `daily_summary` de la fecha de hoy en Madrid). Lista de franjas de hoy clicables (→ reservas de esa franja). Botón grande **+ NUEVA RESERVA**. Buscador global en la cabecera. |
| `/reservas` | operador | Listado con filtros (fecha, estado, departamento, tipo) y paginación. Clic → ficha. |
| `/reservas/nueva` | operador | Ver 5. |
| `/reservas/:id` | operador | Ficha completa (ver 6). |
| `/calendario` | operador | Vistas **Día / Semana / Lista**. Cada día: nº reservas, personas, % ocupación y semáforo (desde `daily_summary` + `slot_availability`). Clic en día → detalle de franjas. |
| `/estadisticas` | supervisor | Tarjetas de totales + gráficos sencillos (`event_stats`): por departamento, por día, por franja, ocupación media. |
| `/actividad` | supervisor | **Registro de actividad** (`audit_log_view`): filtros por usuario, acción, fechas; ver valores anteriores/nuevos de forma legible (no JSON crudo). |
| `/administracion` | admin | Configuración del evento (nombre, descripción, logo, fechas, opción "no presentados ocupan plaza") y **exportación**. |
| `/administracion/usuarios` | admin | Crear / editar / activar-desactivar usuarios (rol, departamento). Ver FASE G. |
| `/administracion/departamentos` | admin | Crear / editar / desactivar. |
| `/administracion/horarios` | admin | Franjas y capacidades por día (crear una, generar en bloque con `generate_slots`, editar capacidad, cerrar/abrir). Tipos de reserva. Permisos por rol (`role_permissions`). |

Menú lateral (o inferior en móvil) que solo muestra lo accesible para el rol. Cabecera con nombre, departamento y cerrar sesión.

---

## 5. NUEVA RESERVA (pantalla crítica)

Flujo: **FECHA → HORA → PERSONAS → NOMBRE → TELÉFONO → (email, tipo, observaciones) → RESUMEN → CONFIRMAR.**

- Fecha con selector (limitado al rango del evento). Hora: **solo franjas activas** de ese día, con su disponibilidad visible.
- Personas: campo numérico grande. Al escribir, aviso inmediato: "Quedan N plazas" / "No hay capacidad suficiente" / franja completa. Botón de confirmar deshabilitado si no cabe (ayuda visual; el backend valida igualmente).
- Departamento: automático (el del usuario), solo lectura. Estado por defecto: CONFIRMADA.
- Validación de formulario con zod: nombre (2–120), teléfono (6–20 caracteres: dígitos, espacios, `+ ( ) . -`), email opcional válido, observaciones ≤ 1000, personas ≥ 1.
- **Pantalla de resumen** antes de guardar (fecha, hora, personas, responsable, teléfono, departamento) con `[CANCELAR]` y `[CONFIRMAR RESERVA]`. Evita el doble envío (deshabilitar mientras se procesa).
- Éxito: "RESERVA CONFIRMADA — RES-000124 — 30 septiembre 2026 · 12:00 — 4 personas — Quedan 12 plazas" (usa `reservation_code` y `remaining` de la respuesta) con botones "Nueva reserva" y "Ver reserva".
- Atajos: al terminar, "Nueva reserva" reinicia el formulario con foco en la fecha.

---

## 6. FICHA DE RESERVA (`/reservas/:id`)

Muestra: código, fecha y hora, personas, nombre y teléfono (con enlace `tel:`), email, tipo, departamento, estado (con color), creada (fecha/hora) y por quién, observaciones, y si está cancelada: cuándo, quién y motivo.

Botones según estado y permisos (usa `can_manage_reservation`):
- **EDITAR** (solo `CONFIRMADA`): mismo formulario que Nueva reserva, con la reserva precargada. Al cambiar personas o franja, mostrar la disponibilidad **para esta reserva**. Enviar todos los campos a `update_reservation`.
- **CANCELAR RESERVA**: modal "¿Quieres cancelar esta reserva?" con motivo opcional; `[VOLVER]` / `[CANCELAR RESERVA]`.
- Marcar **REALIZADA** / **NO PRESENTADO** / volver a **CONFIRMADA** (`set_reservation_status`).
- Historial de la reserva (acciones de `audit_log_view` filtradas por `entity_id`) solo si el rol puede leer la auditoría.

---

## 7. TIEMPO REAL

- Suscríbete (canal de Supabase Realtime, `postgres_changes`) a **`reservations`** y **`time_slots`**.
- Ante cualquier cambio: **invalida las consultas de React Query** afectadas (`slot_availability`, `daily_summary`, listados, ficha abierta). No mutes el estado a mano a partir del payload.
- Indicador discreto de conexión ("En vivo" / "Reconectando…"). Si el canal cae, **fallback con refetch cada 30 s** y refetch al recuperar el foco de la ventana.
- Si el usuario está en Nueva reserva y la franja elegida se completa o cambia su disponibilidad, actualizar el aviso al instante.

---

## 8. PERMISOS EN LA INTERFAZ

- Oculta lo que el rol no puede usar, pero **asume que el backend rechazará** cualquier intento y trata `FORBIDDEN` con: "No tienes permiso para hacer esto."
- Reglas por defecto actuales (configurables en `role_permissions`): admin gestiona todo; operador edita/cancela reservas **de su departamento**; supervisor solo consulta salvo autorización. No las codifiques de forma rígida: lee `role_permissions` y `can_manage_reservation`.
- Estadísticas y Actividad: supervisor y admin. Administración: solo admin.

---

## 9. EXPORTACIÓN (en `/administracion`)

Exportar **CSV** desde `reservation_details` con filtros: fecha o rango, departamento, estado, tipo. Excel opcional (`xlsx`/SheetJS) si no complica el bundle. Requisitos del CSV:
- Codificación UTF-8 **con BOM** y separador `;` (para que Excel en español lo abra bien).
- Escapa comillas y saltos de línea; evita inyección de fórmulas (prefija con `'` los valores que empiecen por `=`, `+`, `-`, `@`).
- Pagina la descarga si hay muchos registros (no truncar en silencio).
Solo visible para admin.

---

## 10. FASES DE TRABAJO (una por una; no avances si la anterior no está verificada)

**FASE A — Base del proyecto y acceso.** Scaffold, Tailwind, router, cliente Supabase, tipos, sesión, guardas de ruta, layout, `/login`, cuenta inactiva, cerrar sesión, CI en GitHub, `vercel.json`, README con instrucciones de despliegue.

**FASE B — Disponibilidad y nueva reserva.** Dashboard "HOY" con franjas, componente de semáforo, `/reservas/nueva` completo con resumen y manejo de `CAPACITY`.

**FASE C — Gestión de reservas.** Listado con filtros, ficha, editar, cancelar, cambios de estado, botones según permisos.

**FASE D — Calendario y búsqueda.** Vistas día/semana/lista y buscador global.

**FASE E — Estadísticas y actividad.** Gráficos y registro de actividad legible.

**FASE F — Administración.** Evento, departamentos, horarios/capacidades, tipos, permisos por rol, exportación.

**FASE G — Usuarios (Edge Function).** Ver sección 11.

**FASE H — Tiempo real, pulido y pruebas.** Realtime completo con fallback, accesibilidad, revisión responsive, pruebas (vitest), revisión de errores y de textos.

---

## 11. FASE G — GESTIÓN DE USUARIOS (Edge Function)

Crear usuarios exige la clave `service_role`, que **nunca** va al navegador ni a Vercel. Se implementa como **Edge Function de Supabase** en `supabase/functions/admin-users/`, desplegada con Supabase CLI (`supabase functions deploy admin-users`). La clave se guarda solo como secreto de Supabase (ya disponible en el entorno de la función).

La función:
1. Exige cabecera `Authorization: Bearer <JWT>`; valida el JWT y comprueba en `profiles` que el llamante es **admin y está activo**. Si no → 403.
2. Acciones (`POST` con `{ action, ... }`, validadas con zod):
   - `create`: `{ email, nombre, role, department_id, password }` → crea el usuario con `auth.admin.createUser({ email_confirm: true, user_metadata: { nombre } })` y **después** actualiza su `profiles` (`role`, `department_id`, `nombre`, `active = true`). Si falla la segunda parte, elimina el usuario creado para no dejar cuentas a medias.
   - `update`: cambia nombre, rol, departamento.
   - `set_active`: activa/desactiva (`profiles.active`) y bloquea/desbloquea la cuenta en Auth (`ban_duration`).
   - `reset_password`: establece una contraseña nueva.
3. Valida que `role` exista en `roles` y `department_id` en `departments`.
4. CORS restringido al dominio de la app; respuestas JSON con mensajes claros; sin filtrar información sensible en los errores.

La pantalla `/administracion/usuarios` llama a esta función con `supabase.functions.invoke`. Nunca escribe en `auth.users`.

---

## 12. SEGURIDAD Y CALIDAD

- Solo clave `anon`/`publishable` en el cliente. `.env` en `.gitignore`. Sin secretos en el repositorio.
- No uses `dangerouslySetInnerHTML`. Trata todo texto de reservas como no confiable (React ya escapa; respeta eso también en el CSV).
- Cabeceras de seguridad en Vercel (`vercel.json`): `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`, `Permissions-Policy` básica.
- Cierra la sesión limpiando la caché de React Query.
- CI en GitHub Actions: `typecheck`, `lint`, `test`, `build`.
- Accesibilidad: etiquetas en formularios, foco visible, contraste suficiente, no depender solo del color.

---

## 13. PRUEBAS MÍNIMAS ANTES DE DAR POR TERMINADO

Unitarias (vitest): semáforo de franjas (umbrales), formato de fechas/horas en Madrid, traducción de errores, escape del CSV, validación zod de la reserva.

Manuales (documentarlas en el README como checklist):
1. Login correcto, incorrecto y cuenta inactiva.
2. Crear una reserva completa de principio a fin con el teclado.
3. Intentar reservar más plazas de las que quedan → mensaje claro y datos del formulario conservados.
4. Dos ventanas con dos usuarios: crear en una y ver la disponibilidad actualizada en la otra sin recargar.
5. Editar personas (subir por encima de lo disponible → rechazo con el máximo permitido).
6. Cancelar → la franja recupera plazas.
7. Operador: no ve Administración, Estadísticas ni Actividad; no puede editar reservas de otro departamento.
8. Buscar por teléfono, nombre, código y fecha.
9. Exportar CSV y abrirlo en Excel (acentos correctos).
10. Móvil: crear una reserva cómodamente.

---

## 14. CRITERIO DE FINALIZACIÓN

Terminado cuando: todas las rutas funcionan con sus roles; la reserva por teléfono se hace de forma rápida y fluida; todos los errores de negocio se muestran en lenguaje llano; el tiempo real actualiza la disponibilidad; el proyecto compila y pasa la CI; está desplegado en Vercel con las variables de entorno; y **no hay ningún dato ficticio, secreto ni clave privada en el código**.

**Empieza por la FASE A. Antes de escribir código, resume en pocas líneas qué vas a crear y pregunta solo si algo bloquea de verdad.**
