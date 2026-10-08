-- =====================================================================
-- MisFinanzas v2 · FASE 3 · Funciones de cuotas y gastos recurrentes
-- Correr DESPUES de 01_fase1_esquema.sql. No hace falta en la Fase 1.
-- Las funciones se ejecutan con los permisos de quien las llama
-- (SECURITY INVOKER), asi que siguen respetando la seguridad por fila.
-- =====================================================================

-- Crea un plan de cuotas y una fila "proyectada" por cada cuota.
create or replace function public.create_installment_plan(
  p_workspace   uuid,
  p_description text,
  p_total       numeric,
  p_currency    text,
  p_installments int,
  p_first_due   date,
  p_card        uuid default null,
  p_category    uuid default null,
  p_account     uuid default null
) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_plan uuid;
  v_each numeric;
  v_i    int;
  v_amt  numeric;
begin
  insert into public.installment_plans
    (workspace_id, description, total_amount, currency, installments, first_due_on, card_id, category_id)
  values
    (p_workspace, p_description, p_total, p_currency, p_installments, p_first_due, p_card, p_category)
  returning id into v_plan;

  v_each := round(p_total / p_installments, 2);

  for v_i in 1..p_installments loop
    -- la ultima cuota absorbe el redondeo para que la suma sea exacta
    v_amt := case when v_i = p_installments
                  then p_total - v_each * (p_installments - 1)
                  else v_each end;
    insert into public.transactions
      (workspace_id, kind, status, occurred_on, amount, currency, description,
       category_id, card_id, account_id, payment_method, expense_type, source,
       installment_plan_id, installment_no, external_id)
    values
      (p_workspace, 'gasto', 'proyectado',
       (p_first_due + make_interval(months => v_i - 1))::date,
       v_amt, p_currency,
       p_description || ' (' || v_i || '/' || p_installments || ')',
       p_category, p_card, p_account, 'credito', 'variable', 'cuotas',
       v_plan, v_i, 'plan:' || v_plan || ':' || v_i);
  end loop;

  return v_plan;
end;
$$;

-- Genera los movimientos proyectados de las reglas recurrentes hasta p_until.
-- Se puede llamar todas las veces que se quiera: no duplica.
create or replace function public.generate_recurring(p_workspace uuid, p_until date)
returns int
language plpgsql security invoker set search_path = public as $$
declare
  r        record;
  v_month  date;
  v_day    date;
  v_count  int := 0;
  v_rows   int;
begin
  for r in
    select * from public.recurring_rules
    where workspace_id = p_workspace and active
  loop
    v_month := date_trunc('month', coalesce(r.last_generated_on + interval '1 month', r.starts_on))::date;
    while v_month <= p_until loop
      -- dia pedido, recortado al ultimo dia del mes si el mes es mas corto
      v_day := v_month + (least(r.day_of_month,
                 extract(day from (v_month + interval '1 month - 1 day'))::int) - 1);
      if v_day >= r.starts_on and (r.ends_on is null or v_day <= r.ends_on) and v_day <= p_until then
        insert into public.transactions
          (workspace_id, kind, status, occurred_on, amount, currency, description,
           category_id, account_id, card_id, payment_method, expense_type, source,
           recurring_rule_id, external_id)
        values
          (p_workspace, r.kind, 'proyectado', v_day, r.amount, r.currency, r.description,
           r.category_id, r.account_id, r.card_id, r.payment_method, 'fijo', 'recurrente',
           r.id, 'rule:' || r.id || ':' || to_char(v_day, 'YYYY-MM'))
        on conflict (workspace_id, source, external_id) do nothing;
        get diagnostics v_rows = row_count;
        v_count := v_count + v_rows;
      end if;
      v_month := (v_month + interval '1 month')::date;
    end loop;
    update public.recurring_rules
       set last_generated_on = date_trunc('month', p_until)::date
     where id = r.id;
  end loop;
  return v_count;
end;
$$;

-- Pasa a "confirmado" lo proyectado cuya fecha ya llego.
-- Los proyectados en USD sin cotizacion quedan pendientes hasta cargarla.
create or replace function public.confirm_due(p_workspace uuid)
returns int
language plpgsql security invoker set search_path = public as $$
declare v_n int;
begin
  update public.transactions
     set status = 'confirmado'
   where workspace_id = p_workspace
     and status = 'proyectado'
     and occurred_on <= current_date
     and (currency = 'ARS' or fx_rate is not null);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.create_installment_plan(uuid,text,numeric,text,int,date,uuid,uuid,uuid) from public, anon;
revoke execute on function public.generate_recurring(uuid,date) from public, anon;
revoke execute on function public.confirm_due(uuid) from public, anon;
grant execute on function public.create_installment_plan(uuid,text,numeric,text,int,date,uuid,uuid,uuid) to authenticated;
grant execute on function public.generate_recurring(uuid,date) to authenticated;
grant execute on function public.confirm_due(uuid) to authenticated;
