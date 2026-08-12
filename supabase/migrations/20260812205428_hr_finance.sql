-- HR and Finance, first slice.
--
-- Scope deliberately bounded: Employee records + Leave requests (HR), and
-- Expense tracking (Finance). Payroll and a real chart of accounts /
-- general ledger are both significant enough to deserve their own scoped
-- pass later — this migration doesn't reach for either, so it isn't a
-- half-built stub of a bigger system.
--
-- Same primitives as every other module: company_id derived server-side
-- (never trusted from the client), has_role()/current_company_id() on
-- every policy, gated behind tenant_features (see below).

create sequence seq_employee;
create sequence seq_leave_request;
create sequence seq_expense;

-- New role: HR staff can see/manage employee records and leave requests,
-- but nothing outside that boundary (no stock, no sales, no finance) —
-- keeps HR a clean module rather than folding into an existing role.
insert into roles (key, label) values ('hr', 'Human Resources');

-- ---------------------------------------------------------------------------
-- employee_details — 1:1 extension of profiles. Kept as its own table
-- rather than adding columns to profiles: profiles is the
-- auth/authorization-facing table (role, status, login identity) and is
-- readable by every active role in the company (see profiles_select);
-- employee_details carries HR-only PII (date of birth, emergency contact)
-- that shouldn't be exposed that broadly.
-- ---------------------------------------------------------------------------
create table employee_details (
  profile_id       uuid primary key references profiles(id) on delete cascade,
  company_id       uuid not null references companies(id),
  display_code     text unique not null default gen_display_code('EMP', 'seq_employee'::regclass, 3),
  department       text,
  job_title        text,
  branch_id        uuid references branches(id),
  employment_type  text not null default 'Full-time' check (employment_type in ('Full-time', 'Part-time', 'Contract')),
  hire_date        date,
  termination_date date,
  date_of_birth    date,
  phone            text,
  emergency_contact_name  text,
  emergency_contact_phone text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index employee_details_company_idx on employee_details (company_id);

-- company_id derives from the referenced profile (never client-supplied);
-- branch_id, if given, is cross-checked against that same company so an
-- employee record can't claim a branch belonging to a different tenant.
create function employee_details_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
  v_branch_company uuid;
begin
  select company_id into v_company from profiles where id = new.profile_id;
  if v_company is null then
    raise exception 'Invalid profile_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot create employee details for another company''s profile';
  end if;
  new.company_id := v_company;

  if new.branch_id is not null then
    select company_id into v_branch_company from branches where id = new.branch_id;
    if v_branch_company is null or v_branch_company <> v_company then
      raise exception 'branch_id must belong to the same company';
    end if;
  end if;
  return new;
end $$;
create trigger employee_details_set_tenant before insert on employee_details
  for each row execute function employee_details_set_tenant();
create trigger employee_details_set_tenant_on_move before update of branch_id on employee_details
  for each row execute function employee_details_set_tenant();
create trigger employee_details_updated_at before update on employee_details
  for each row execute function set_updated_at();

alter table employee_details enable row level security;
-- Admin/HR/Finance (payroll-adjacent) see the whole company roster's
-- details; anyone else can see only their own row.
create policy employee_details_select on employee_details for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr', 'finance']))
  or profile_id = current_profile_id()
  or is_platform_admin()
);
-- Maintaining HR records (not just viewing your own) is an HR/admin action.
create policy employee_details_write on employee_details for all
  using (company_id = current_company_id() and has_role(array['admin', 'hr']))
  with check (company_id = current_company_id() and has_role(array['admin', 'hr']));

-- ---------------------------------------------------------------------------
-- leave_types — global lookup, same shape as `roles`/`features`: leave
-- categories don't vary per company for a first pass.
-- ---------------------------------------------------------------------------
create table leave_types (
  key   text primary key,
  label text not null
);
insert into leave_types (key, label) values
  ('annual',        'Annual Leave'),
  ('sick',          'Sick Leave'),
  ('unpaid',        'Unpaid Leave'),
  ('maternity',     'Maternity Leave'),
  ('paternity',     'Paternity Leave'),
  ('compassionate', 'Compassionate Leave');

alter table leave_types enable row level security;
create policy leave_types_select on leave_types for select using (auth.role() = 'authenticated');
revoke insert, update, delete on leave_types from authenticated;

-- ---------------------------------------------------------------------------
-- leave_requests — a request/approval record, not a ledger: unlike
-- inventory or money, "how many leave days has X taken" doesn't need an
-- append-only history for this first pass, just current status.
-- ---------------------------------------------------------------------------
create table leave_requests (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('LV', 'seq_leave_request'::regclass, 3),
  employee_id  uuid not null references profiles(id),
  leave_type   text not null references leave_types(key),
  start_date   date not null,
  end_date     date not null check (end_date >= start_date),
  reason       text,
  status       text not null default 'Pending' check (status in ('Pending', 'Approved', 'Rejected', 'Cancelled')),
  decided_by   uuid references profiles(id),
  decided_at   timestamptz,
  created_at   timestamptz not null default now()
);
create index leave_requests_company_idx on leave_requests (company_id);
create index leave_requests_employee_idx on leave_requests (employee_id);

create function leave_requests_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from profiles where id = new.employee_id;
  if v_company is null then
    raise exception 'Invalid employee_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot create a leave request for another company''s employee';
  end if;
  new.company_id := v_company;
  return new;
end $$;
create trigger leave_requests_set_tenant before insert on leave_requests
  for each row execute function leave_requests_set_tenant();

alter table leave_requests enable row level security;
create policy leave_requests_select on leave_requests for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr', 'finance']))
  or employee_id = current_profile_id()
  or is_platform_admin()
);
-- Self-service: an employee can file their own request; HR/admin can also
-- log one on someone else's behalf (e.g. from a paper form).
create policy leave_requests_insert on leave_requests for insert with check (
  company_id = current_company_id()
  and (employee_id = current_profile_id() or has_role(array['admin', 'hr']))
);
-- Deciding a request (approve/reject) is HR/admin only for this first pass.
-- Employee self-service cancellation of a still-pending request is a
-- reasonable follow-up, not included here to keep the policy shape simple.
create policy leave_requests_update on leave_requests for update
  using (company_id = current_company_id() and has_role(array['admin', 'hr']))
  with check (company_id = current_company_id() and has_role(array['admin', 'hr']));

-- ---------------------------------------------------------------------------
-- expense_categories — global lookup, same reasoning as leave_types.
-- ---------------------------------------------------------------------------
create table expense_categories (
  key   text primary key,
  label text not null
);
insert into expense_categories (key, label) values
  ('travel',   'Travel'),
  ('utilities','Utilities'),
  ('rent',     'Rent'),
  ('supplies', 'Supplies'),
  ('fuel',     'Fuel'),
  ('other',    'Other');

alter table expense_categories enable row level security;
create policy expense_categories_select on expense_categories for select using (auth.role() = 'authenticated');
revoke insert, update, delete on expense_categories from authenticated;

-- ---------------------------------------------------------------------------
-- expenses — company expense tracking, separate from Purchasing's
-- purchase_orders (not yet migrated to this schema — still local demo
-- state, see docs/architecture.md). A PO is "we're buying stock"; an
-- expense is "we spent money on something that isn't stock" (rent,
-- utilities, travel). Different shape, different approval owner
-- (Finance, not Procurement) — kept as separate tables rather than
-- shoehorned into one.
-- ---------------------------------------------------------------------------
create table expenses (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(id),
  display_code  text unique not null default gen_display_code('EX', 'seq_expense'::regclass, 4),
  branch_id     uuid references branches(id),
  category      text not null references expense_categories(key),
  description   text,
  amount        numeric(14,2) not null check (amount > 0),
  currency_code text not null references currencies(code),
  expense_date  date not null default current_date,
  submitted_by  uuid not null references profiles(id),
  status        text not null default 'Pending' check (status in ('Pending', 'Approved', 'Rejected', 'Paid')),
  approved_by   uuid references profiles(id),
  approved_at   timestamptz,
  created_at    timestamptz not null default now()
);
create index expenses_company_idx on expenses (company_id);
create index expenses_submitted_by_idx on expenses (submitted_by);

-- Root table like `customers` — direct client insert by whoever's signed
-- in, so company_id comes straight from their own session, not a parent
-- row lookup.
create function expenses_set_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  return new;
end $$;
create trigger expenses_set_company before insert on expenses
  for each row execute function expenses_set_company();

alter table expenses enable row level security;
create policy expenses_select on expenses for select using (
  (company_id = current_company_id() and has_role(array['admin', 'finance']))
  or submitted_by = current_profile_id()
  or is_platform_admin()
);
-- Any active company member can submit their own expense; who submitted it
-- is never client-spoofable.
create policy expenses_insert on expenses for insert with check (
  company_id = current_company_id() and submitted_by = current_profile_id()
);
-- Approving/rejecting/marking paid is Finance/admin only — the submitter
-- can't edit their own expense after filing it in this first pass (no
-- mid-flight amount changes on a pending approval).
create policy expenses_update on expenses for update
  using (company_id = current_company_id() and has_role(array['admin', 'finance']))
  with check (company_id = current_company_id() and has_role(array['admin', 'finance']));

-- ---------------------------------------------------------------------------
-- SETVACO asked for these — enable both modules now that they're real.
-- Any other company stays without them until an operator turns them on
-- (see tenant_features / company_has_feature() in the previous migration).
-- ---------------------------------------------------------------------------
insert into tenant_features (company_id, feature_key)
select id, unnest(array['hr', 'finance'])
from companies where slug = 'setvaco';
