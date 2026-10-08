-- =====================================================================
-- MisFinanzas v2 · FASE 1 · Esquema base (PostgreSQL / Supabase)
-- Pegar completo en: Supabase > SQL Editor > New query > Run
-- Es seguro correrlo una sola vez sobre un proyecto nuevo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ESPACIOS (personal / negocio) Y MIEMBROS
-- ---------------------------------------------------------------------
create table public.workspaces (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  kind        text not null default 'personal' check (kind in ('personal','negocio')),
  created_by  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null default 'owner' check (role in ('owner','editor','viewer')),
  created_at   timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

-- Funciones de permisos. SECURITY DEFINER evita recursion de politicas.
create or replace function public.is_member(ws uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.workspace_members m
    where m.workspace_id = ws and m.user_id = auth.uid()
  );
$$;

create or replace function public.can_edit(ws uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.workspace_members m
    where m.workspace_id = ws and m.user_id = auth.uid()
      and m.role in ('owner','editor')
  );
$$;

create or replace function public.is_owner(ws uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.workspace_members m
    where m.workspace_id = ws and m.user_id = auth.uid()
      and m.role = 'owner'
  );
$$;

-- Crear un espacio: unica via permitida (el cliente no inserta en workspaces).
create or replace function public.create_workspace(p_name text, p_kind text default 'personal')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'No autenticado';
  end if;
  insert into public.workspaces (name, kind, created_by)
  values (trim(p_name), p_kind, v_uid)
  returning id into v_id;
  insert into public.workspace_members (workspace_id, user_id, role)
  values (v_id, v_uid, 'owner');
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. CATALOGOS: cuentas, tarjetas, categorias
-- ---------------------------------------------------------------------
create table public.accounts (
  id              uuid primary key default gen_random_uuid(),
  workspace_id    uuid not null references public.workspaces(id) on delete cascade,
  name            text not null check (length(trim(name)) > 0),
  kind            text not null default 'banco'
                  check (kind in ('banco','billetera','efectivo','inversion','otra')),
  currency        text not null default 'ARS' check (currency in ('ARS','USD')),
  opening_balance numeric(16,2) not null default 0,
  archived        boolean not null default false,
  created_at      timestamptz not null default now(),
  unique (workspace_id, name),
  unique (workspace_id, id)
);

create table public.cards (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name         text not null check (length(trim(name)) > 0),
  network      text not null default 'Visa' check (network in ('Visa','Amex','Mastercard','Otra')),
  closing_day  smallint check (closing_day between 1 and 31),
  due_day      smallint check (due_day between 1 and 31),
  archived     boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (workspace_id, name),
  unique (workspace_id, id)
);

create table public.categories (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name         text not null check (length(trim(name)) > 0),
  kind         text not null default 'gasto' check (kind in ('gasto','ingreso')),
  color        text,
  archived     boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (workspace_id, kind, name),
  unique (workspace_id, id)
);

-- ---------------------------------------------------------------------
-- 3. CUOTAS Y GASTOS RECURRENTES (las tablas existen desde ya; la
--    interfaz y las funciones llegan en la Fase 3)
-- ---------------------------------------------------------------------
create table public.installment_plans (
  id                 uuid primary key default gen_random_uuid(),
  workspace_id       uuid not null references public.workspaces(id) on delete cascade,
  description        text not null,
  total_amount       numeric(16,2) not null check (total_amount > 0),
  currency           text not null default 'ARS' check (currency in ('ARS','USD')),
  installments       smallint not null check (installments between 1 and 60),
  first_due_on       date not null,
  card_id            uuid,
  category_id        uuid,
  created_at         timestamptz not null default now(),
  unique (workspace_id, id),
  foreign key (workspace_id, card_id)     references public.cards (workspace_id, id)      on delete set null (card_id),
  foreign key (workspace_id, category_id) references public.categories (workspace_id, id) on delete set null (category_id)
);

create table public.recurring_rules (
  id                uuid primary key default gen_random_uuid(),
  workspace_id      uuid not null references public.workspaces(id) on delete cascade,
  description       text not null,
  kind              text not null default 'gasto' check (kind in ('gasto','ingreso')),
  amount            numeric(16,2) not null check (amount > 0),
  currency          text not null default 'ARS' check (currency in ('ARS','USD')),
  day_of_month      smallint not null check (day_of_month between 1 and 31),
  starts_on         date not null,
  ends_on           date,
  active            boolean not null default true,
  last_generated_on date,
  category_id       uuid,
  account_id        uuid,
  card_id           uuid,
  payment_method    text check (payment_method in ('debito','credito','transferencia','efectivo','otro')),
  created_at        timestamptz not null default now(),
  unique (workspace_id, id),
  foreign key (workspace_id, category_id) references public.categories (workspace_id, id) on delete set null (category_id),
  foreign key (workspace_id, account_id)  references public.accounts (workspace_id, id)   on delete set null (account_id),
  foreign key (workspace_id, card_id)     references public.cards (workspace_id, id)      on delete set null (card_id)
);

-- ---------------------------------------------------------------------
-- 4. MOVIMIENTOS
-- Reintegros: plata que un tercero (ej. tu empleador) te devuelve por gastos que
-- pagaste vos. NO es ingreso personal: solo cancela lo pendiente.
create table public.reimbursements (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  payer        text not null check (length(trim(payer)) > 0),
  received_on  date not null,
  amount       numeric(16,2) not null check (amount > 0),
  currency     text not null default 'ARS' check (currency in ('ARS','USD')),
  account_id   uuid,           -- cuenta donde depositaste el efectivo / entro la plata
  notes        text not null default '',
  created_by   uuid default auth.uid() references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (workspace_id, id),
  foreign key (workspace_id, account_id) references public.accounts (workspace_id, id) on delete set null (account_id)
);

-- ---------------------------------------------------------------------
create table public.transactions (
  id                  uuid primary key default gen_random_uuid(),
  workspace_id        uuid not null references public.workspaces(id) on delete cascade,
  kind                text not null check (kind in ('gasto','ingreso')),
  -- 'proyectado' = cuota o gasto fijo futuro que todavia no impacta en los totales
  status              text not null default 'confirmado' check (status in ('confirmado','proyectado')),
  occurred_on         date not null,
  amount              numeric(16,2) not null check (amount > 0),
  currency            text not null default 'ARS' check (currency in ('ARS','USD')),
  -- Cotizacion (ARS por 1 USD) vigente EN EL MOMENTO del movimiento
  fx_rate             numeric(14,4) check (fx_rate > 0),
  fx_source           text,
  amount_ars          numeric(18,2) generated always as (
                        case when currency = 'ARS' then amount
                             when fx_rate is not null then round(amount * fx_rate, 2)
                             else null end
                      ) stored,
  description         text not null default '',
  notes               text not null default '',
  tags                text[] not null default '{}',
  category_id         uuid,
  account_id          uuid,
  card_id             uuid,
  payment_method      text check (payment_method in ('debito','credito','transferencia','efectivo','otro')),
  expense_type        text check (expense_type in ('fijo','variable')),
  source              text not null default 'manual'
                      check (source in ('manual','atajo','mail','sms','import','recurrente','cuotas')),
  -- Identificador de origen (id del mail, del atajo, de v1...) para no duplicar
  external_id         text,
  installment_plan_id uuid references public.installment_plans(id) on delete set null,
  installment_no      smallint,
  recurring_rule_id   uuid references public.recurring_rules(id) on delete set null,
  -- Gasto que pagaste vos pero te reintegra un tercero (ej. 'Empleador').
  -- Mientras reimbursement_id sea NULL esta "pendiente de reintegro" y no cuenta
  -- como gasto propio en los resumenes.
  reimbursable_by     text check (reimbursable_by is null or length(trim(reimbursable_by)) > 0),
  reimbursement_id    uuid,
  created_by          uuid default auth.uid() references auth.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  constraint reintegro_coherente check (
    (reimbursable_by is null and reimbursement_id is null) or (reimbursable_by is not null and kind = 'gasto')),
  constraint fx_obligatoria check (currency = 'ARS' or fx_rate is not null or status = 'proyectado'),
  foreign key (workspace_id, category_id) references public.categories (workspace_id, id) on delete set null (category_id),
  foreign key (workspace_id, account_id)  references public.accounts (workspace_id, id)   on delete set null (account_id),
  foreign key (workspace_id, card_id)     references public.cards (workspace_id, id)      on delete set null (card_id),
  foreign key (workspace_id, reimbursement_id) references public.reimbursements (workspace_id, id) on delete set null (reimbursement_id)
);

-- Evita duplicados cuando la misma fuente reenvia el mismo movimiento.
-- (Los NULL no chocan entre si: los movimientos manuales no tienen external_id.)
create unique index transactions_dedupe on public.transactions (workspace_id, source, external_id);
create index transactions_ws_fecha on public.transactions (workspace_id, occurred_on desc);
create index transactions_ws_categoria on public.transactions (workspace_id, category_id);

-- ---------------------------------------------------------------------
-- 5. PRESUPUESTOS
-- ---------------------------------------------------------------------
create table public.budgets (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  category_id  uuid not null,
  amount       numeric(16,2) not null check (amount > 0),
  currency     text not null default 'ARS' check (currency in ('ARS','USD')),
  created_at   timestamptz not null default now(),
  unique (workspace_id, category_id),
  foreign key (workspace_id, category_id) references public.categories (workspace_id, id) on delete cascade
);

-- ---------------------------------------------------------------------
-- 6. SEGURIDAD A NIVEL DE FILA (RLS)
--    Regla de oro: nadie ve ni toca datos de un espacio al que no pertenece.
-- ---------------------------------------------------------------------
alter table public.workspaces        enable row level security;
alter table public.workspace_members enable row level security;

create policy workspaces_select on public.workspaces
  for select to authenticated using (public.is_member(id));
create policy workspaces_update on public.workspaces
  for update to authenticated using (public.is_owner(id)) with check (public.is_owner(id));
create policy workspaces_delete on public.workspaces
  for delete to authenticated using (public.is_owner(id));
-- (sin politica de INSERT: los espacios se crean con create_workspace())

create policy members_select on public.workspace_members
  for select to authenticated using (public.is_member(workspace_id));
create policy members_insert on public.workspace_members
  for insert to authenticated with check (public.is_owner(workspace_id));
create policy members_update on public.workspace_members
  for update to authenticated using (public.is_owner(workspace_id)) with check (public.is_owner(workspace_id));
create policy members_delete on public.workspace_members
  for delete to authenticated using (public.is_owner(workspace_id));

do $$
declare t text;
begin
  foreach t in array array['accounts','cards','categories','installment_plans',
                           'recurring_rules','transactions','budgets','reimbursements'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_member(workspace_id))', t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.can_edit(workspace_id))', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.can_edit(workspace_id)) with check (public.can_edit(workspace_id))', t || '_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.can_edit(workspace_id))', t || '_delete', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 7. PERMISOS: el rol "anon" (visitante sin login) no puede nada.
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;

revoke execute on function public.create_workspace(text, text) from public, anon;
grant  execute on function public.create_workspace(text, text) to authenticated;
