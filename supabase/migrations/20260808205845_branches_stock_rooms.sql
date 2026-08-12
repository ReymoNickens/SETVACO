-- The physical hierarchy: Company -> Country -> Branch -> Stock Room.
-- "Country" isn't a separate table level of its own — it's the
-- `country_code` column on `branches` pointing at the global `countries`
-- table, so a new branch in a new country is a row insert, not a schema
-- change. Company -> Branch -> Stock Room is the real nesting: every branch
-- belongs to exactly one company, and every stock room belongs to exactly
-- one branch.
--
-- Tenant-safety pattern used here and in every migration after this one:
-- company_id is never trusted from client input. A BEFORE INSERT trigger
-- always overwrites it — either with the acting user's own company
-- (current_company_id()), or by deriving it from the parent row (branch ->
-- stock room, stock room -> item, etc.) and rejecting the insert outright if
-- that would cross a tenant boundary. This means even a bug elsewhere in the
-- app that forgot to filter by company can't leak or corrupt another
-- tenant's data — the database itself won't allow the row to exist.

create table branches (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  country_code text not null references countries(code),
  display_code text unique not null default gen_display_code('BR', 'seq_branch'::regclass, 2),
  name         text not null,
  created_at   timestamptz not null default now(),
  unique (company_id, name)
);
create index branches_company_idx on branches (company_id);

create function branches_set_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- coalesce: an authenticated end user always gets their own company
  -- forced on, regardless of what they sent. Only a service-role caller
  -- (no auth.uid(), e.g. seeding or an Edge Function) may set it explicitly.
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  return new;
end $$;
create trigger branches_set_company before insert on branches
  for each row execute function branches_set_company();

create table stock_rooms (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  branch_id    uuid not null references branches(id),
  display_code text unique not null default gen_display_code('SR', 'seq_stock_room'::regclass, 2),
  name         text not null,
  created_at   timestamptz not null default now(),
  unique (branch_id, name)
);
create index stock_rooms_company_idx on stock_rooms (company_id);
create index stock_rooms_branch_idx on stock_rooms (branch_id);

create function stock_rooms_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_branch_company uuid;
begin
  select company_id into v_branch_company from branches where id = new.branch_id;
  if v_branch_company is null then
    raise exception 'Invalid branch_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_branch_company then
    raise exception 'Cannot create a stock room under another company''s branch';
  end if;
  new.company_id := v_branch_company;
  return new;
end $$;
create trigger stock_rooms_set_tenant before insert on stock_rooms
  for each row execute function stock_rooms_set_tenant();
