-- Two more HR/Finance office stations: Performance & Discipline (HR),
-- Petty Cash (Finance). Both are simple logs — current-state-plus-history
-- records, not workflow engines with approval stages, matching how
-- leave_requests/expenses were deliberately kept to a first pass.

create sequence seq_performance_record;
create sequence seq_petty_cash;

-- ---------------------------------------------------------------------------
-- performance_records — periodic reviews and disciplinary write-ups live in
-- one table (record_type discriminates), same reasoning as leave_types
-- being a lookup rather than a table-per-leave-type: they're the same
-- shape (who, when, what, by whom), just a different flavor of "HR event
-- about an employee." Never self-service — an employee can see their own
-- history but never write their own review or write-up.
-- ---------------------------------------------------------------------------
create table performance_records (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('PF', 'seq_performance_record'::regclass, 3),
  employee_id  uuid not null references profiles(id),
  record_type  text not null check (record_type in ('Review', 'Disciplinary')),
  record_date  date not null default current_date,
  rating       int check (rating is null or (rating between 1 and 5)),
  summary      text not null,
  details      text,
  recorded_by  uuid not null references profiles(id),
  created_at   timestamptz not null default now()
);
create index performance_records_company_idx on performance_records (company_id);
create index performance_records_employee_idx on performance_records (employee_id);

-- Same tenant-derivation shape as leave_requests_set_tenant; recorded_by is
-- also forced server-side, never trusted from the client.
create function performance_records_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from profiles where id = new.employee_id;
  if v_company is null then
    raise exception 'Invalid employee_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot create a performance record for another company''s employee';
  end if;
  new.company_id := v_company;
  new.recorded_by := current_profile_id();
  return new;
end $$;
create trigger performance_records_set_tenant before insert on performance_records
  for each row execute function performance_records_set_tenant();

alter table performance_records enable row level security;
create policy performance_records_select on performance_records for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr']))
  or employee_id = current_profile_id()
  or is_platform_admin()
);
-- Writing a review or write-up is an HR/admin action only — never the
-- employee's own, and no update/delete in this first pass (a correction is
-- a new record, keeping the history honest rather than editable after the
-- fact).
create policy performance_records_insert on performance_records for insert with check (
  company_id = current_company_id() and has_role(array['admin', 'hr'])
);

-- ---------------------------------------------------------------------------
-- petty_cash_transactions — a running log of small day-to-day cash in/out,
-- not routed through a PO or invoice. Finance/admin record entries as they
-- happen (no approval workflow — this is a cash box log, not a spend
-- request); the balance is the running sum of ins minus outs, computed by
-- the frontend from the transaction list rather than stored redundantly.
-- ---------------------------------------------------------------------------
create table petty_cash_transactions (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references companies(id),
  display_code     text unique not null default gen_display_code('PC', 'seq_petty_cash'::regclass, 4),
  branch_id        uuid references branches(id),
  transaction_type text not null check (transaction_type in ('In', 'Out')),
  amount           numeric(12,2) not null check (amount > 0),
  description      text not null,
  recorded_by      uuid not null references profiles(id),
  transaction_date date not null default current_date,
  created_at       timestamptz not null default now()
);
create index petty_cash_company_idx on petty_cash_transactions (company_id);

-- Root table like expenses: company_id from the caller's own session;
-- branch_id, if given, cross-checked against that same company.
create function petty_cash_set_company() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_branch_company uuid;
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  if new.branch_id is not null then
    select company_id into v_branch_company from branches where id = new.branch_id;
    if v_branch_company is null or v_branch_company <> new.company_id then
      raise exception 'branch_id must belong to the same company';
    end if;
  end if;
  new.recorded_by := current_profile_id();
  return new;
end $$;
create trigger petty_cash_set_company before insert on petty_cash_transactions
  for each row execute function petty_cash_set_company();

alter table petty_cash_transactions enable row level security;
create policy petty_cash_select on petty_cash_transactions for select using (
  (company_id = current_company_id() and has_role(array['admin', 'finance']))
  or is_platform_admin()
);
-- Finance/admin only — this isn't self-service (unlike expenses, which
-- anyone can submit for reimbursement, petty cash entries are Finance's
-- own record of the physical cash box).
create policy petty_cash_insert on petty_cash_transactions for insert with check (
  company_id = current_company_id() and has_role(array['admin', 'finance'])
);

insert into features (key, label) values
  ('performance', 'Performance & Discipline'),
  ('petty_cash', 'Petty Cash');

insert into tenant_features (company_id, feature_key)
select id, unnest(array['performance', 'petty_cash'])
from companies where slug = 'setvaco';
