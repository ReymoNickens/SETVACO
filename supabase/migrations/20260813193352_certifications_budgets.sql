-- Two more HR/Finance office stations: Training & Certifications (HR),
-- Budgets (Finance). Same "simple log, not a workflow engine" posture as
-- the previous HR/Finance slices.

create sequence seq_certification;
create sequence seq_budget;

-- ---------------------------------------------------------------------------
-- certifications — one row per certificate an employee holds. Relevant to
-- SETVACO specifically: field technicians servicing crushing/screening
-- equipment need safety/equipment certifications tracked with real expiry
-- dates, not just a generic HR record. expiry_date is nullable — not every
-- certification expires. "Expiring soon / expired" status is computed by
-- the frontend from expiry_date vs today, not stored, so it's always
-- current without a background job.
-- ---------------------------------------------------------------------------
create table certifications (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references companies(id),
  display_code   text unique not null default gen_display_code('CT', 'seq_certification'::regclass, 3),
  employee_id    uuid not null references profiles(id),
  cert_name      text not null,
  issuing_body   text,
  cert_number    text,
  issue_date     date not null default current_date,
  expiry_date    date,
  recorded_by    uuid not null references profiles(id),
  created_at     timestamptz not null default now()
);
create index certifications_company_idx on certifications (company_id);
create index certifications_employee_idx on certifications (employee_id);

-- Same tenant-derivation shape as performance_records_set_tenant.
create function certifications_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from profiles where id = new.employee_id;
  if v_company is null then
    raise exception 'Invalid employee_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot create a certification for another company''s employee';
  end if;
  new.company_id := v_company;
  new.recorded_by := current_profile_id();
  return new;
end $$;
create trigger certifications_set_tenant before insert on certifications
  for each row execute function certifications_set_tenant();

alter table certifications enable row level security;
create policy certifications_select on certifications for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr']))
  or employee_id = current_profile_id()
  or is_platform_admin()
);
-- Admin/hr record certifications (verifying the physical document is an
-- HR step) — never the employee's own self-entry, same posture as
-- performance_records.
create policy certifications_insert on certifications for insert with check (
  company_id = current_company_id() and has_role(array['admin', 'hr'])
);

-- ---------------------------------------------------------------------------
-- budgets — one row per category+period. Deliberately scoped to Expense
-- categories only (reuses expense_categories, the lookup expenses already
-- uses) rather than also covering Purchasing/payroll spend: Purchasing
-- isn't migrated to this schema yet (still local demo state — see
-- docs/architecture.md), so a budget that tried to span it would be
-- comparing against data that doesn't exist here. "Actual" spend for a
-- budget is computed by the frontend from approved/paid expenses in that
-- category and period, not stored — always current, no background job.
-- ---------------------------------------------------------------------------
create table budgets (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('BG', 'seq_budget'::regclass, 3),
  category     text not null references expense_categories(key),
  period_start date not null,
  period_end   date not null check (period_end >= period_start),
  amount       numeric(14,2) not null check (amount >= 0),
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now(),
  unique (company_id, category, period_start, period_end)
);
create index budgets_company_idx on budgets (company_id);

create function budgets_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  new.created_by := current_profile_id();
  return new;
end $$;
create trigger budgets_set_tenant before insert on budgets
  for each row execute function budgets_set_tenant();

alter table budgets enable row level security;
create policy budgets_select on budgets for select using (
  (company_id = current_company_id() and has_role(array['admin', 'finance']))
  or is_platform_admin()
);
create policy budgets_write on budgets for all
  using (company_id = current_company_id() and has_role(array['admin', 'finance']))
  with check (company_id = current_company_id() and has_role(array['admin', 'finance']));

insert into features (key, label) values
  ('certifications', 'Training & Certifications'),
  ('budgets', 'Budgets');

insert into tenant_features (company_id, feature_key)
select id, unnest(array['certifications', 'budgets'])
from companies where slug = 'setvaco';
