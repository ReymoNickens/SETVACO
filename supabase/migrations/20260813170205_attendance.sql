-- Attendance / Time Tracking — first of the HR/Finance office expansion
-- (see docs/architecture.md's HR Office section). One row per employee per
-- working day; clock in inserts the row, clock out updates it. Not a
-- append-only ledger like items/stock, because "when did X clock in/out
-- today" only ever has one current answer per day — correcting a mistaken
-- punch is an update, not a new event.

create table attendance_records (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  employee_id  uuid not null references profiles(id),
  work_date    date not null default current_date,
  clock_in     timestamptz,
  clock_out    timestamptz check (clock_out is null or clock_in is null or clock_out >= clock_in),
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (employee_id, work_date)
);
create index attendance_records_company_idx on attendance_records (company_id);
create index attendance_records_employee_idx on attendance_records (employee_id);

-- Same tenant-derivation shape as leave_requests_set_tenant: company_id
-- always comes from the referenced employee's own profile, never trusted
-- from the client.
create function attendance_records_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from profiles where id = new.employee_id;
  if v_company is null then
    raise exception 'Invalid employee_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot create an attendance record for another company''s employee';
  end if;
  new.company_id := v_company;
  return new;
end $$;
create trigger attendance_records_set_tenant before insert on attendance_records
  for each row execute function attendance_records_set_tenant();
create trigger attendance_records_updated_at before update on attendance_records
  for each row execute function set_updated_at();

alter table attendance_records enable row level security;

create policy attendance_records_select on attendance_records for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr']))
  or employee_id = current_profile_id()
  or is_platform_admin()
);

-- Clocking in is self-service: an employee inserts their own row for today.
-- HR/admin can also log one on someone's behalf (e.g. a missed punch fixed
-- from a paper record) — same posture as leave_requests_insert.
create policy attendance_records_insert on attendance_records for insert with check (
  company_id = current_company_id()
  and (employee_id = current_profile_id() or has_role(array['admin', 'hr']))
);

-- Clocking out (setting clock_out on your own still-open row) is
-- self-service too; HR/admin can correct any row for time-sheet fixes.
create policy attendance_records_update on attendance_records for update using (
  company_id = current_company_id()
  and (employee_id = current_profile_id() or has_role(array['admin', 'hr']))
) with check (
  company_id = current_company_id()
  and (employee_id = current_profile_id() or has_role(array['admin', 'hr']))
);

insert into features (key, label) values ('attendance', 'Attendance / Time Tracking');

-- profiles_select was missing 'hr' from its role allowlist (added by the
-- tenant_features migration before the 'hr' role existed) — an HR user
-- couldn't see their own company's staff roster at all. Widening it here
-- since Attendance's own roster view depends on the same profiles read.
drop policy profiles_select on profiles;
create policy profiles_select on profiles for select using (
  (company_id = current_company_id()
   and has_role(array['admin','sales','warehouse','procurement','service','finance','hr']))
  or is_platform_admin()
);

insert into tenant_features (company_id, feature_key)
select id, 'attendance' from companies where slug = 'setvaco';
