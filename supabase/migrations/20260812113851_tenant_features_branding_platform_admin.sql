-- Multi-tenant foundation, part 2: per-tenant feature gating, branding,
-- plan field, and a platform-operator role that spans companies.
--
-- Nothing here changes behavior for any existing login: every SELECT policy
-- edit below only *adds* an `or is_platform_admin()` clause on top of the
-- existing check, and the new tenant_features/company columns are additive.
-- SETVACO keeps working exactly as it does today unless a profile is
-- explicitly flagged is_platform_admin = true.

-- ---------------------------------------------------------------------------
-- companies: branding + plan
-- ---------------------------------------------------------------------------
alter table companies
  add column logo_url      text,
  add column primary_color text check (primary_color ~ '^#[0-9a-fA-F]{6}$'),
  add column accent_color  text check (accent_color  ~ '^#[0-9a-fA-F]{6}$'),
  add column plan          text not null default 'standard';

-- No plans lookup table yet — billing doesn't exist. `plan` is deliberately
-- unconstrained beyond NOT NULL so it's not blocking on a billing model that
-- isn't designed yet; add a `check` or a `plans` table (matching the
-- roles/features pattern) once billing is real.

-- ---------------------------------------------------------------------------
-- platform admin — a profile flag, not a role. Kept orthogonal to `role`
-- (which still drives has_role() and stays scoped to one company) because a
-- platform operator is still, mechanically, a login that belongs to one
-- company row (e.g. an internal operator company) — they don't get a
-- special company_id of NULL or similar; is_platform_admin just widens what
-- SELECT policies let that specific login read.
--
-- Deliberately SELECT-only throughout this migration: is_platform_admin()
-- is never OR'd into a _write policy. A platform admin can look across
-- tenants for support/monitoring, but cannot mutate another tenant's rows
-- through client-side RLS-gated writes — cross-tenant writes (e.g.
-- onboarding a new company) go through a service-role path (Edge
-- Function), same pattern as admin-manage-user already uses. Defined here,
-- ahead of tenant_features below, because that table's own RLS policies
-- reference is_platform_admin() too.
-- ---------------------------------------------------------------------------
alter table profiles add column is_platform_admin boolean not null default false;

-- Operator tenant: platform-admin logins belong to their own company row,
-- not SETVACO's. Keeps the client's own roster (profiles_select, above)
-- free of internal accounts, and gives is_platform_admin a normal, non-
-- special company_id to satisfy the NOT NULL constraint on profiles.
insert into companies (name, slug) values ('EvolveIT', 'evolveit');

-- No profiles row is created here — an auth.users login can't be inserted
-- by a plain migration (Supabase Auth owns that table). Provisioning the
-- first platform-admin account is a manual step, same shape as the
-- bootstrap SETVACO admin already documented in docs/architecture.md:
-- create the user via the admin-manage-user Edge Function (or dashboard)
-- against the 'evolveit' company_id, then
--   update profiles set is_platform_admin = true where id = '<that user's id>';

create function is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and status = 'Active' and is_platform_admin = true
  )
$$;

-- ---------------------------------------------------------------------------
-- features / tenant_features — same shape as `roles`: a global lookup of
-- module keys, plus a per-company join saying which are switched on.
-- No feature_key hardcoded per company anywhere in the app — the frontend
-- nav reads this table (via company_has_feature()) to decide what to show.
-- ---------------------------------------------------------------------------
create table features (
  key   text primary key,
  label text not null
);

insert into features (key, label) values
  ('stock_room',   'Stock Room / Inventory'),
  ('sales',        'Sales & Quotations'),
  ('purchasing',   'Purchasing'),
  ('service_jobs', 'Service Jobs'),
  ('hr',           'HR'),
  ('finance',      'Finance');

create table tenant_features (
  company_id  uuid not null references companies(id),
  feature_key text not null references features(key),
  enabled     boolean not null default true,
  updated_at  timestamptz not null default now(),
  primary key (company_id, feature_key)
);
create index tenant_features_company_idx on tenant_features (company_id);

-- Backfill: SETVACO gets the modules that are already live today, so this
-- migration doesn't silently hide anything for the existing tenant.
insert into tenant_features (company_id, feature_key)
select id, unnest(array['stock_room', 'sales', 'purchasing', 'service_jobs'])
from companies where slug = 'setvaco';

-- Absence of a row = disabled. This is the "don't hardcode if SETVACO then
-- show HR" primitive: a brand new tenant has zero rows here until an
-- operator explicitly enables modules for them.
create function company_has_feature(feature text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select enabled from tenant_features
     where company_id = current_company_id() and feature_key = feature),
    false
  )
$$;

alter table features enable row level security;
create policy features_select on features for select using (auth.role() = 'authenticated');
revoke insert, update, delete on features from authenticated;

alter table tenant_features enable row level security;
create policy tenant_features_select on tenant_features for select using (
  company_id = current_company_id() or is_platform_admin()
);
-- Enabling/disabling a client's modules is an operator action (onboarding,
-- upsell), not something a company's own admin can self-serve — so writes
-- are platform-admin only, same posture as the admin-manage-user Edge
-- Function path for account provisioning.
create policy tenant_features_write on tenant_features for all
  using (is_platform_admin())
  with check (is_platform_admin());

-- --- Widen existing SELECT policies with "or is_platform_admin()" ---------
-- Mechanical edit, same shape 13 times: drop, recreate with the OR clause
-- appended. Nothing else about each policy changes.

drop policy companies_select on companies;
create policy companies_select on companies for select using (
  id = current_company_id() or is_platform_admin()
);

drop policy profiles_select on profiles;
create policy profiles_select on profiles for select using (
  (company_id = current_company_id()
   and has_role(array['admin','sales','warehouse','procurement','service','finance']))
  or is_platform_admin()
);

drop policy audit_log_select on audit_log;
create policy audit_log_select on audit_log for select using (
  (company_id = current_company_id() and has_role(array['admin','finance']))
  or is_platform_admin()
);

drop policy branches_select on branches;
create policy branches_select on branches for select using (
  (company_id = current_company_id()
   and has_role(array['admin','sales','warehouse','procurement','service','finance']))
  or is_platform_admin()
);

drop policy stock_rooms_select on stock_rooms;
create policy stock_rooms_select on stock_rooms for select using (
  (company_id = current_company_id()
   and has_role(array['admin','sales','warehouse','procurement','service','finance']))
  or is_platform_admin()
);

drop policy items_select on items;
create policy items_select on items for select using (
  (company_id = current_company_id()
   and has_role(array['admin','sales','warehouse','procurement','service','finance']))
  or is_platform_admin()
);

drop policy inventory_ledger_select on inventory_ledger;
create policy inventory_ledger_select on inventory_ledger for select using (
  (company_id = current_company_id()
   and has_role(array['admin','sales','warehouse','procurement','service','finance']))
  or is_platform_admin()
);

drop policy customers_select on customers;
create policy customers_select on customers for select using (
  (company_id = current_company_id() and has_role(array['admin','sales','finance']))
  or is_platform_admin()
);

drop policy customer_contacts_select on customer_contacts;
create policy customer_contacts_select on customer_contacts for select using (
  (company_id = current_company_id() and has_role(array['admin','sales','finance']))
  or is_platform_admin()
);

drop policy quotations_select on quotations;
create policy quotations_select on quotations for select using (
  (company_id = current_company_id() and has_role(array['admin','sales','warehouse','finance']))
  or is_platform_admin()
);

drop policy quotation_lines_select on quotation_lines;
create policy quotation_lines_select on quotation_lines for select using (
  (company_id = current_company_id() and has_role(array['admin','sales','warehouse','finance']))
  or is_platform_admin()
);

drop policy invoices_select on invoices;
create policy invoices_select on invoices for select using (
  (company_id = current_company_id() and has_role(array['admin','sales','warehouse','finance']))
  or is_platform_admin()
);

drop policy invoice_lines_select on invoice_lines;
create policy invoice_lines_select on invoice_lines for select using (
  (company_id = current_company_id() and has_role(array['admin','sales','warehouse','finance']))
  or is_platform_admin()
);
