-- Payroll — salary setup lives in HR Office, running pay lives in Finance
-- Office, same split described in docs/architecture.md. Deliberately
-- narrower than a real payroll system: no draft/void workflow (a run is
-- finalized the moment it's created, same one-stage choice
-- 20260810084843_quotations_invoices.sql made for quotations), no
-- pro-rating by attendance, and the Ghana SSNIT/PAYE math below is a
-- best-effort implementation of the standard 2024 GRA bands — NOT a
-- certified tax engine. Verify against current GRA guidance before relying
-- on this for a real pay run.

create sequence seq_payroll_run;

insert into features (key, label) values ('payroll', 'Payroll');

-- ---------------------------------------------------------------------------
-- employee_compensation — current salary structure per employee, one row
-- each (not a history ledger: a raise overwrites the row, same reasoning
-- as leave_requests being current-state-only rather than append-only).
-- The payslip a payroll run produces is the durable historical record of
-- what was actually paid, so this table only ever needs to answer "what
-- would this person be paid right now."
-- ---------------------------------------------------------------------------
create table employee_compensation (
  profile_id      uuid primary key references profiles(id) on delete cascade,
  company_id      uuid not null references companies(id),
  basic_salary    numeric(12,2) not null check (basic_salary >= 0),
  allowances      numeric(12,2) not null default 0 check (allowances >= 0),
  effective_date  date not null default current_date,
  set_by          uuid references profiles(id),
  updated_at      timestamptz not null default now()
);
create index employee_compensation_company_idx on employee_compensation (company_id);

-- Same tenant-derivation shape as employee_details_set_tenant. set_by is
-- also forced server-side (who actually made this change), never trusted
-- from the client.
create function employee_compensation_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from profiles where id = new.profile_id;
  if v_company is null then
    raise exception 'Invalid profile_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot set compensation for another company''s profile';
  end if;
  new.company_id := v_company;
  new.set_by := current_profile_id();
  return new;
end $$;
create trigger employee_compensation_set_tenant before insert or update on employee_compensation
  for each row execute function employee_compensation_set_tenant();
create trigger employee_compensation_updated_at before update on employee_compensation
  for each row execute function set_updated_at();

alter table employee_compensation enable row level security;
-- An employee can see their own salary; HR/admin/finance see the whole
-- roster (finance needs it to understand payroll's cost, same reasoning as
-- employee_details_select).
create policy employee_compensation_select on employee_compensation for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr', 'finance']))
  or profile_id = current_profile_id()
  or is_platform_admin()
);
-- Setting pay is an HR/admin action, not finance's (finance runs pay, HR
-- decides what it is) and never the employee's own.
create policy employee_compensation_write on employee_compensation for all
  using (company_id = current_company_id() and has_role(array['admin', 'hr']))
  with check (company_id = current_company_id() and has_role(array['admin', 'hr']));

-- ---------------------------------------------------------------------------
-- payroll_runs / payslips — INSERT/UPDATE/DELETE revoked from authenticated
-- entirely, same posture as quotations/invoices: the only way rows appear
-- here is through run_payroll() below, so the money math can never be
-- client-supplied.
-- ---------------------------------------------------------------------------
create table payroll_runs (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references companies(id),
  display_code   text unique not null default gen_display_code('PR', 'seq_payroll_run'::regclass, 3),
  period_start   date not null,
  period_end     date not null check (period_end >= period_start),
  run_by         uuid references profiles(id),
  run_at         timestamptz not null default now(),
  employee_count int not null default 0,
  total_gross    numeric(14,2) not null default 0,
  total_net      numeric(14,2) not null default 0,
  unique (company_id, period_start, period_end)
);
create index payroll_runs_company_idx on payroll_runs (company_id);

alter table payroll_runs enable row level security;
create policy payroll_runs_select on payroll_runs for select using (
  (company_id = current_company_id() and has_role(array['admin', 'finance']))
  or is_platform_admin()
);
revoke insert, update, delete on payroll_runs from authenticated;

create table payslips (
  id              uuid primary key default gen_random_uuid(),
  payroll_run_id  uuid not null references payroll_runs(id) on delete cascade,
  company_id      uuid not null references companies(id),
  employee_id     uuid not null references profiles(id),
  basic_salary    numeric(12,2) not null,
  allowances      numeric(12,2) not null,
  gross_pay       numeric(12,2) not null,
  ssnit_employee  numeric(12,2) not null,
  ssnit_employer  numeric(12,2) not null,
  paye            numeric(12,2) not null,
  net_pay         numeric(12,2) not null,
  created_at      timestamptz not null default now(),
  unique (payroll_run_id, employee_id)
);
create index payslips_run_idx on payslips (payroll_run_id);
create index payslips_employee_idx on payslips (employee_id);
create index payslips_company_idx on payslips (company_id);

alter table payslips enable row level security;
-- An employee can see their own payslip; finance/admin see everyone's
-- (they ran the payroll and own the accounting for it).
create policy payslips_select on payslips for select using (
  (company_id = current_company_id() and has_role(array['admin', 'finance']))
  or employee_id = current_profile_id()
  or is_platform_admin()
);
revoke insert, update, delete on payslips from authenticated;

-- ---------------------------------------------------------------------------
-- calc_ghana_paye_monthly — standard graduated monthly PAYE bands (2024 GRA
-- schedule, GHS). Band widths below 490/110/130/3166.67/16000/30520, rates
-- 0%/5%/10%/17.5%/25%/30%, anything above the last band at 35%. These
-- figures move with GRA policy — this is a best-effort calculation for a
-- first pass, not a certified tax engine; an operator should confirm the
-- bands are still current before a real pay run depends on this.
-- ---------------------------------------------------------------------------
create function calc_ghana_paye_monthly(p_taxable numeric) returns numeric
language plpgsql immutable set search_path = public as $$
declare
  v_widths numeric[] := array[490, 110, 130, 3166.67, 16000, 30520];
  v_rates  numeric[] := array[0, 0.05, 0.10, 0.175, 0.25, 0.30, 0.35];
  v_remaining numeric := greatest(p_taxable, 0);
  v_tax numeric := 0;
  v_width numeric;
  i int;
begin
  for i in 1..array_length(v_widths, 1) loop
    exit when v_remaining <= 0;
    v_width := least(v_remaining, v_widths[i]);
    v_tax := v_tax + v_width * v_rates[i];
    v_remaining := v_remaining - v_width;
  end loop;
  if v_remaining > 0 then
    v_tax := v_tax + v_remaining * v_rates[array_length(v_rates, 1)];
  end if;
  return round(v_tax, 2);
end $$;

-- ---------------------------------------------------------------------------
-- run_payroll — the only way payroll_runs/payslips rows are created.
-- SSNIT is computed on basic_salary only (5.5% employee tier-1
-- contribution, 13% employer contribution — standard Ghana rates); PAYE is
-- computed on gross pay less the employee's own SSNIT contribution, which
-- is the usual taxable-income base. Employees without a compensation row
-- are silently skipped (no salary set up yet), not an error — see the
-- "no employees" guard below for the case where nobody has one.
-- ---------------------------------------------------------------------------
create function run_payroll(p_period_start date, p_period_end date) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
  v_run_id uuid;
  v_total_gross numeric(14,2) := 0;
  v_total_net numeric(14,2) := 0;
  v_count int := 0;
  r record;
  v_gross numeric(12,2);
  v_ssnit_emp numeric(12,2);
  v_ssnit_er numeric(12,2);
  v_paye numeric(12,2);
  v_net numeric(12,2);
begin
  if not has_role(array['admin', 'finance']) then
    raise exception 'Not authorized to run payroll';
  end if;
  v_company := current_company_id();
  if v_company is null then
    raise exception 'No active company for current user';
  end if;
  if p_period_end < p_period_start then
    raise exception 'period_end must be on or after period_start';
  end if;

  insert into payroll_runs (company_id, period_start, period_end, run_by)
  values (v_company, p_period_start, p_period_end, current_profile_id())
  returning id into v_run_id;

  for r in
    select ec.profile_id, ec.basic_salary, ec.allowances
    from employee_compensation ec
    join profiles p on p.id = ec.profile_id
    where ec.company_id = v_company and p.status = 'Active'
  loop
    v_gross := r.basic_salary + r.allowances;
    v_ssnit_emp := round(r.basic_salary * 0.055, 2);
    v_ssnit_er := round(r.basic_salary * 0.13, 2);
    v_paye := calc_ghana_paye_monthly(v_gross - v_ssnit_emp);
    v_net := v_gross - v_ssnit_emp - v_paye;

    insert into payslips (payroll_run_id, company_id, employee_id, basic_salary, allowances, gross_pay, ssnit_employee, ssnit_employer, paye, net_pay)
    values (v_run_id, v_company, r.profile_id, r.basic_salary, r.allowances, v_gross, v_ssnit_emp, v_ssnit_er, v_paye, v_net);

    v_total_gross := v_total_gross + v_gross;
    v_total_net := v_total_net + v_net;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    delete from payroll_runs where id = v_run_id;
    raise exception 'No employees have a salary set up yet — add compensation in HR Office first';
  end if;

  update payroll_runs set employee_count = v_count, total_gross = v_total_gross, total_net = v_total_net
  where id = v_run_id;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), format('Ran payroll for %s employees (%s to %s)', v_count, p_period_start, p_period_end), 'Finance', 'payroll_run', v_run_id);

  return v_run_id;
end $$;

grant execute on function run_payroll(date, date) to authenticated;
revoke execute on function run_payroll(date, date) from public, anon;
revoke execute on function employee_compensation_set_tenant() from public, anon, authenticated;
-- Internal helper only — run_payroll() calls it under its own SECURITY
-- DEFINER context, so no client role needs direct EXECUTE on this.
revoke execute on function calc_ghana_paye_monthly(numeric) from public, anon, authenticated;

insert into tenant_features (company_id, feature_key)
select id, 'payroll' from companies where slug = 'setvaco';
