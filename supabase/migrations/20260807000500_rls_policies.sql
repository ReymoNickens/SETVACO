-- Authorization. Single primitive (has_role) plus RLS policies for every
-- plain-CRUD table, mirroring the NAV role matrix and per-panel `canManage`
-- checks in index.html. Tables with a workflow + side effect (quotations,
-- invoices, purchase_orders and their line tables) have INSERT/UPDATE
-- revoked from `authenticated` entirely — all writes to those go through the
-- SECURITY DEFINER RPCs in 20260807000600_rpc_functions.sql, which is the
-- only place stock mutation + status transition + audit logging can be kept
-- atomic. See docs/architecture.md §2.3 for the full reasoning.

-- SECURITY DEFINER is required here, not optional: profiles has its own RLS
-- policy (profiles_select, below) that itself calls has_role(). If this
-- function ran as SECURITY INVOKER, its `select ... from profiles` would be
-- evaluated under the calling role and re-trigger profiles_select, which
-- calls has_role() again — infinite recursion the first time any policy on
-- any other table invokes it. Running as the (trusted) function owner
-- bypasses RLS for just this one lookup and breaks that cycle.
create or replace function has_role(allowed text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and status = 'Active' and role = any(allowed)
  )
$$;

create or replace function current_profile_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from profiles where id = auth.uid() and status = 'Active'
$$;

-- ---------------------------------------------------------------------------
-- Lookups — readable by any authenticated (active) user, writable by admin only.
-- ---------------------------------------------------------------------------
alter table roles enable row level security;
alter table branches enable row level security;
alter table nav_permissions enable row level security;

create policy roles_select on roles for select using (has_role(array['admin','sales','warehouse','procurement','service','finance']));
create policy branches_select on branches for select using (has_role(array['admin','sales','warehouse','procurement','service','finance']));
create policy branches_write on branches for all using (has_role(array['admin'])) with check (has_role(array['admin']));
create policy nav_permissions_select on nav_permissions for select using (has_role(array['admin','sales','warehouse','procurement','service','finance']));

-- ---------------------------------------------------------------------------
-- profiles — everyone can read (internal roster), no direct client writes.
-- Creation/role/status changes go through the admin-manage-user Edge
-- Function, which uses the service-role key to also manage the auth.users row.
-- ---------------------------------------------------------------------------
alter table profiles enable row level security;
create policy profiles_select on profiles for select using (has_role(array['admin','sales','warehouse','procurement','service','finance']));
revoke insert, update, delete on profiles from authenticated;

-- ---------------------------------------------------------------------------
-- Stock rooms & items — matches partsInventory/equipmentInventory NAV roles;
-- write restricted to the roles InventoryPanel's canManage allows.
-- ---------------------------------------------------------------------------
alter table stock_rooms enable row level security;
alter table items enable row level security;

create policy stock_rooms_select on stock_rooms for select using (has_role(array['admin','sales','warehouse','procurement','service','finance']));
create policy stock_rooms_write on stock_rooms for all
  using (has_role(array['admin','warehouse','procurement']))
  with check (has_role(array['admin','warehouse','procurement']));

create policy items_select on items for select using (has_role(array['admin','sales','warehouse','procurement','service','finance']));
create policy items_write on items for all
  using (has_role(array['admin','warehouse','procurement']))
  with check (has_role(array['admin','warehouse','procurement']));

-- ---------------------------------------------------------------------------
-- Vendors — purchasing NAV roles; write restricted to VendorsTab's canManage.
-- ---------------------------------------------------------------------------
alter table vendors enable row level security;
create policy vendors_select on vendors for select using (has_role(array['admin','procurement','finance']));
create policy vendors_write on vendors for all
  using (has_role(array['admin','procurement']))
  with check (has_role(array['admin','procurement']));

-- ---------------------------------------------------------------------------
-- Customers & contacts — customers NAV roles; write restricted to admin/sales
-- (CreateCustomerModal's canCreate). Walk-in customers created inline by
-- create_quotation (SECURITY DEFINER) bypass this, same as today's
-- resolveOrCreateCustomer flow.
-- ---------------------------------------------------------------------------
alter table customers enable row level security;
alter table customer_contacts enable row level security;

create policy customers_select on customers for select using (has_role(array['admin','sales','finance']));
create policy customers_write on customers for all
  using (has_role(array['admin','sales']))
  with check (has_role(array['admin','sales']));

create policy customer_contacts_select on customer_contacts for select using (has_role(array['admin','sales','finance']));
create policy customer_contacts_write on customer_contacts for all
  using (has_role(array['admin','sales']))
  with check (has_role(array['admin','sales']));

-- ---------------------------------------------------------------------------
-- Quotations / invoices / purchase orders — SELECT via RLS (mirrors the
-- Parts Sales / Equipment Sales / Purchasing NAV role splits). All writes
-- revoked from `authenticated`; see RPCs.
-- ---------------------------------------------------------------------------
alter table quotations enable row level security;
alter table quotation_lines enable row level security;
alter table invoices enable row level security;
alter table invoice_lines enable row level security;
alter table purchase_orders enable row level security;
alter table purchase_order_lines enable row level security;

create policy quotations_select on quotations for select using (
  (type = 'part' and has_role(array['admin','sales','warehouse','finance']))
  or (type = 'equipment' and has_role(array['admin','sales','finance']))
);
revoke insert, update, delete on quotations from authenticated;

create policy quotation_lines_select on quotation_lines for select using (
  exists (select 1 from quotations q where q.id = quotation_lines.quotation_id)
);
revoke insert, update, delete on quotation_lines from authenticated;

create policy invoices_select on invoices for select using (
  (type = 'part' and has_role(array['admin','sales','warehouse','finance']))
  or (type = 'equipment' and has_role(array['admin','sales','finance']))
);
revoke insert, update, delete on invoices from authenticated;

create policy invoice_lines_select on invoice_lines for select using (
  exists (select 1 from invoices i where i.id = invoice_lines.invoice_id)
);
revoke insert, update, delete on invoice_lines from authenticated;

create policy purchase_orders_select on purchase_orders for select using (has_role(array['admin','procurement','finance']));
revoke insert, update, delete on purchase_orders from authenticated;

create policy purchase_order_lines_select on purchase_order_lines for select using (
  exists (select 1 from purchase_orders p where p.id = purchase_order_lines.purchase_order_id)
);
revoke insert, update, delete on purchase_order_lines from authenticated;

-- ---------------------------------------------------------------------------
-- Service jobs — matches servicejobs NAV roles; write restricted to
-- ServiceJobsTab's canManage. No stock side effect on completion today, so
-- plain RLS (not an RPC) is sufficient — see docs/architecture.md.
-- ---------------------------------------------------------------------------
alter table service_jobs enable row level security;
create policy service_jobs_select on service_jobs for select using (has_role(array['admin','service','warehouse']));
create policy service_jobs_write on service_jobs for all
  using (has_role(array['admin','service']))
  with check (has_role(array['admin','service']));

-- ---------------------------------------------------------------------------
-- Notes (feedback + manager comments) — SELECT follows the parent record's
-- visibility (once a manager comment exists, anyone who can see the
-- quotation/job can read it — matches ManagerCommentsPanel's canView).
-- INSERT: feedback is open to the parent's viewers; manager comments are
-- admin/finance only (ManagerCommentsPanel's canComment).
-- ---------------------------------------------------------------------------
alter table notes enable row level security;

create policy notes_select on notes for select using (
  exists (select 1 from quotations q where q.id = notes.quotation_id)
  or exists (select 1 from service_jobs j where j.id = notes.service_job_id)
);
create policy notes_insert_feedback on notes for insert with check (
  kind = 'feedback' and author_id = current_profile_id()
);
create policy notes_insert_manager on notes for insert with check (
  kind = 'manager' and author_id = current_profile_id() and has_role(array['admin','finance'])
);

-- ---------------------------------------------------------------------------
-- Approval settings, audit log, notifications, variance log.
-- ---------------------------------------------------------------------------
alter table approval_settings enable row level security;
alter table approval_flagged_customers enable row level security;
alter table audit_log enable row level security;
alter table notifications enable row level security;
alter table variance_log enable row level security;

create policy approval_settings_select on approval_settings for select using (has_role(array['admin','finance']));
create policy approval_settings_write on approval_settings for update
  using (has_role(array['admin']))
  with check (has_role(array['admin']));

create policy approval_flagged_customers_select on approval_flagged_customers for select using (has_role(array['admin','finance']));
create policy approval_flagged_customers_write on approval_flagged_customers for all
  using (has_role(array['admin']))
  with check (has_role(array['admin']));

-- audit_log is written only inside the RPCs (SECURITY DEFINER); no direct
-- client insert path exists, so authenticated only ever needs SELECT.
create policy audit_log_select on audit_log for select using (has_role(array['admin','finance']));
revoke insert, update, delete on audit_log from authenticated;

create policy notifications_select on notifications for select using (
  recipient_id is null or recipient_id = current_profile_id()
);
create policy notifications_update_own on notifications for update using (
  recipient_id is null or recipient_id = current_profile_id()
) with check (
  recipient_id is null or recipient_id = current_profile_id()
);

create policy variance_log_select on variance_log for select using (has_role(array['admin','finance']));
create policy variance_log_write on variance_log for all
  using (has_role(array['admin','finance']))
  with check (has_role(array['admin','finance']));
