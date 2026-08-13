-- Service Bay — Active Jobs, Installed Base (Assets), Service Contracts.
-- Migrates the Service side of the business off local-only demo state,
-- same posture as every other module: company_id derived server-side,
-- every cross-table reference validated against the caller's own company,
-- direct client insert only where that's always been safe (these are
-- simple operational records, not money-moving ledgers — no RPC needed).

create sequence seq_asset;
create sequence seq_service_job;
create sequence seq_service_job_note;
create sequence seq_service_contract;

-- ---------------------------------------------------------------------------
-- assets — SETVACO-side record of equipment installed at a customer site.
-- item_id references our own equipment catalog (nullable — the unit may
-- have been sold before this system existed, or isn't in our own catalog);
-- item_name is a snapshot, same reasoning as quotation_lines.description,
-- so the record stays readable even if the catalog item is later renamed
-- or removed.
-- ---------------------------------------------------------------------------
create table assets (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references companies(id),
  display_code     text unique not null default gen_display_code('AS', 'seq_asset'::regclass, 4),
  customer_id      uuid not null references customers(id),
  item_id          uuid references items(id),
  item_name        text not null,
  serial_number    text,
  install_date     date,
  warranty_expiry  date,
  status           text not null default 'Active' check (status in ('Active', 'Retired')),
  notes            text,
  created_by       uuid references profiles(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index assets_company_idx on assets (company_id);
create index assets_customer_idx on assets (customer_id);

create function assets_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_customer_company uuid;
  v_item_company uuid;
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  select company_id into v_customer_company from customers where id = new.customer_id;
  if v_customer_company is null or v_customer_company <> new.company_id then
    raise exception 'customer_id must belong to the same company';
  end if;
  if new.item_id is not null then
    select company_id into v_item_company from items where id = new.item_id;
    if v_item_company is null or v_item_company <> new.company_id then
      raise exception 'item_id must belong to the same company';
    end if;
  end if;
  return new;
end $$;
create trigger assets_set_tenant before insert on assets
  for each row execute function assets_set_tenant();
create trigger assets_set_tenant_on_move before update of customer_id, item_id on assets
  for each row execute function assets_set_tenant();
create trigger assets_updated_at before update on assets
  for each row execute function set_updated_at();

alter table assets enable row level security;
create policy assets_select on assets for select using (
  (company_id = current_company_id() and has_role(array['admin', 'sales', 'service', 'finance']))
  or is_platform_admin()
);
create policy assets_write on assets for all
  using (company_id = current_company_id() and has_role(array['admin', 'sales', 'service']))
  with check (company_id = current_company_id() and has_role(array['admin', 'sales', 'service']));

-- ---------------------------------------------------------------------------
-- service_jobs — a job against a customer, optionally tied to one of their
-- assets. `technician` stays free text (no technician-picker in the
-- existing UI, not adding one speculatively here).
-- ---------------------------------------------------------------------------
create table service_jobs (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references companies(id),
  display_code      text unique not null default gen_display_code('SJ', 'seq_service_job'::regclass, 3),
  customer_id       uuid not null references customers(id),
  asset_id          uuid references assets(id),
  job_type          text not null,
  country           text,
  description       text,
  technician        text not null default 'Unassigned',
  eta               date,
  prepared_by_name  text,
  status            text not null default 'Open' check (status in ('Open', 'In Progress', 'Completed')),
  created_by        uuid references profiles(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index service_jobs_company_idx on service_jobs (company_id);
create index service_jobs_customer_idx on service_jobs (customer_id);
create index service_jobs_asset_idx on service_jobs (asset_id);

create function service_jobs_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_customer_company uuid;
  v_asset_company uuid;
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  select company_id into v_customer_company from customers where id = new.customer_id;
  if v_customer_company is null or v_customer_company <> new.company_id then
    raise exception 'customer_id must belong to the same company';
  end if;
  if new.asset_id is not null then
    select company_id into v_asset_company from assets where id = new.asset_id;
    if v_asset_company is null or v_asset_company <> new.company_id then
      raise exception 'asset_id must belong to the same company';
    end if;
  end if;
  return new;
end $$;
create trigger service_jobs_set_tenant before insert on service_jobs
  for each row execute function service_jobs_set_tenant();
create trigger service_jobs_set_tenant_on_move before update of customer_id, asset_id on service_jobs
  for each row execute function service_jobs_set_tenant();
create trigger service_jobs_updated_at before update on service_jobs
  for each row execute function set_updated_at();

alter table service_jobs enable row level security;
create policy service_jobs_select on service_jobs for select using (
  (company_id = current_company_id() and has_role(array['admin', 'service', 'warehouse']))
  or is_platform_admin()
);
create policy service_jobs_insert on service_jobs for insert with check (
  company_id = current_company_id() and has_role(array['admin', 'service'])
);
create policy service_jobs_update on service_jobs for update
  using (company_id = current_company_id() and has_role(array['admin', 'service']))
  with check (company_id = current_company_id() and has_role(array['admin', 'service']));

-- ---------------------------------------------------------------------------
-- service_job_notes — client feedback and internal manager commentary in
-- one table (note_type discriminates), same reasoning as
-- performance_records bundling reviews/write-ups. Feedback is writable by
-- whoever can see the job; manager notes are admin-only (finance, who
-- could comment in the old prototype, can't reach this screen at all —
-- Active Jobs isn't in finance's nav — so there's no real gap here).
-- ---------------------------------------------------------------------------
create table service_job_notes (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references companies(id),
  service_job_id  uuid not null references service_jobs(id) on delete cascade,
  note_type       text not null check (note_type in ('Feedback', 'Manager')),
  note            text not null,
  author_name     text,
  created_by      uuid references profiles(id),
  created_at      timestamptz not null default now()
);
create index service_job_notes_job_idx on service_job_notes (service_job_id);

create function service_job_notes_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from service_jobs where id = new.service_job_id;
  if v_company is null then
    raise exception 'Invalid service_job_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot add a note to another company''s service job';
  end if;
  new.company_id := v_company;
  new.created_by := current_profile_id();
  return new;
end $$;
create trigger service_job_notes_set_tenant before insert on service_job_notes
  for each row execute function service_job_notes_set_tenant();

alter table service_job_notes enable row level security;
create policy service_job_notes_select on service_job_notes for select using (
  (company_id = current_company_id() and has_role(array['admin', 'service', 'warehouse']))
  or is_platform_admin()
);
create policy service_job_notes_insert on service_job_notes for insert with check (
  company_id = current_company_id() and (
    (note_type = 'Feedback' and has_role(array['admin', 'service', 'warehouse']))
    or (note_type = 'Manager' and has_role(array['admin']))
  )
);

-- ---------------------------------------------------------------------------
-- service_contracts — a coverage agreement against a customer, optionally
-- tied to one of their assets. Display status (Active/Expiring/Expired) is
-- computed by the frontend from end_date, same as certifications' expiry
-- status — status column here only tracks Active vs Cancelled.
-- ---------------------------------------------------------------------------
create table service_contracts (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references companies(id),
  display_code     text unique not null default gen_display_code('SC', 'seq_service_contract'::regclass, 4),
  customer_id      uuid not null references customers(id),
  asset_id         uuid references assets(id),
  contract_type    text not null,
  start_date       date not null default current_date,
  end_date         date not null,
  value            numeric(14,2) not null default 0,
  status           text not null default 'Active' check (status in ('Active', 'Cancelled')),
  coverage_notes   text,
  created_by       uuid references profiles(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_date >= start_date)
);
create index service_contracts_company_idx on service_contracts (company_id);
create index service_contracts_customer_idx on service_contracts (customer_id);

create function service_contracts_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_customer_company uuid;
  v_asset_company uuid;
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  select company_id into v_customer_company from customers where id = new.customer_id;
  if v_customer_company is null or v_customer_company <> new.company_id then
    raise exception 'customer_id must belong to the same company';
  end if;
  if new.asset_id is not null then
    select company_id into v_asset_company from assets where id = new.asset_id;
    if v_asset_company is null or v_asset_company <> new.company_id then
      raise exception 'asset_id must belong to the same company';
    end if;
  end if;
  return new;
end $$;
create trigger service_contracts_set_tenant before insert on service_contracts
  for each row execute function service_contracts_set_tenant();
create trigger service_contracts_updated_at before update on service_contracts
  for each row execute function set_updated_at();

alter table service_contracts enable row level security;
create policy service_contracts_select on service_contracts for select using (
  (company_id = current_company_id() and has_role(array['admin', 'service', 'finance']))
  or is_platform_admin()
);
create policy service_contracts_insert on service_contracts for insert with check (
  company_id = current_company_id() and has_role(array['admin', 'service', 'finance'])
);
create policy service_contracts_update on service_contracts for update
  using (company_id = current_company_id() and has_role(array['admin', 'finance']))
  with check (company_id = current_company_id() and has_role(array['admin', 'finance']));
