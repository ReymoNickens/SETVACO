-- Row-Level Security. Every business-data policy checks BOTH a role
-- (has_role) and a tenant match (company_id = current_company_id()) — role
-- alone would let one company's warehouse clerk see another company's
-- stock. Global reference data (roles, countries, currencies, tax_profiles)
-- has no company_id at all, so it's readable by any active login and
-- writable by no one through the API (managed only via migrations).

alter table roles enable row level security;
create policy roles_select on roles for select using (auth.role() = 'authenticated');
revoke insert, update, delete on roles from authenticated;

alter table currencies enable row level security;
alter table countries enable row level security;
alter table tax_profiles enable row level security;
create policy currencies_select on currencies for select using (auth.role() = 'authenticated');
create policy countries_select on countries for select using (auth.role() = 'authenticated');
create policy tax_profiles_select on tax_profiles for select using (auth.role() = 'authenticated');
revoke insert, update, delete on currencies from authenticated;
revoke insert, update, delete on countries from authenticated;
revoke insert, update, delete on tax_profiles from authenticated;

-- ---------------------------------------------------------------------------
-- companies — a login can see only its own tenant row. No client writes.
-- ---------------------------------------------------------------------------
alter table companies enable row level security;
create policy companies_select on companies for select using (id = current_company_id());
revoke insert, update, delete on companies from authenticated;

-- ---------------------------------------------------------------------------
-- profiles — internal roster, but only your own company's roster. No direct
-- client writes: account creation/role/status changes go through the
-- admin-manage-user Edge Function (service-role key).
-- ---------------------------------------------------------------------------
alter table profiles enable row level security;
create policy profiles_select on profiles for select using (
  company_id = current_company_id()
  and has_role(array['admin','sales','warehouse','procurement','service','finance'])
);
revoke insert, update, delete on profiles from authenticated;

-- ---------------------------------------------------------------------------
-- audit_log — read-only to clients, own company only. Written only from
-- inside SECURITY DEFINER RPCs.
-- ---------------------------------------------------------------------------
alter table audit_log enable row level security;
create policy audit_log_select on audit_log for select using (
  company_id = current_company_id() and has_role(array['admin','finance'])
);
revoke insert, update, delete on audit_log from authenticated;

-- ---------------------------------------------------------------------------
-- branches & stock_rooms
-- ---------------------------------------------------------------------------
alter table branches enable row level security;
alter table stock_rooms enable row level security;

create policy branches_select on branches for select using (
  company_id = current_company_id()
  and has_role(array['admin','sales','warehouse','procurement','service','finance'])
);
create policy branches_write on branches for all
  using (company_id = current_company_id() and has_role(array['admin']))
  with check (company_id = current_company_id() and has_role(array['admin']));

create policy stock_rooms_select on stock_rooms for select using (
  company_id = current_company_id()
  and has_role(array['admin','sales','warehouse','procurement','service','finance'])
);
create policy stock_rooms_write on stock_rooms for all
  using (company_id = current_company_id() and has_role(array['admin','warehouse','procurement']))
  with check (company_id = current_company_id() and has_role(array['admin','warehouse','procurement']));

-- ---------------------------------------------------------------------------
-- items — plain CRUD for everything except quantity (there is no qty
-- column to write to). Stock changes only happen through adjust_stock().
-- ---------------------------------------------------------------------------
alter table items enable row level security;
create policy items_select on items for select using (
  company_id = current_company_id()
  and has_role(array['admin','sales','warehouse','procurement','service','finance'])
);
create policy items_write on items for all
  using (company_id = current_company_id() and has_role(array['admin','warehouse','procurement']))
  with check (company_id = current_company_id() and has_role(array['admin','warehouse','procurement']));

-- ---------------------------------------------------------------------------
-- inventory_ledger — readable by the same roles that can see items; no
-- direct INSERT grant, everything goes through adjust_stock(); UPDATE/DELETE
-- already revoked entirely in items_ledger.sql.
-- ---------------------------------------------------------------------------
alter table inventory_ledger enable row level security;
create policy inventory_ledger_select on inventory_ledger for select using (
  company_id = current_company_id()
  and has_role(array['admin','sales','warehouse','procurement','service','finance'])
);
revoke insert on inventory_ledger from authenticated;

-- ---------------------------------------------------------------------------
-- customers & contacts
-- ---------------------------------------------------------------------------
alter table customers enable row level security;
alter table customer_contacts enable row level security;

create policy customers_select on customers for select using (
  company_id = current_company_id() and has_role(array['admin','sales','finance'])
);
create policy customers_write on customers for all
  using (company_id = current_company_id() and has_role(array['admin','sales']))
  with check (company_id = current_company_id() and has_role(array['admin','sales']));

create policy customer_contacts_select on customer_contacts for select using (
  company_id = current_company_id() and has_role(array['admin','sales','finance'])
);
create policy customer_contacts_write on customer_contacts for all
  using (company_id = current_company_id() and has_role(array['admin','sales']))
  with check (company_id = current_company_id() and has_role(array['admin','sales']));
