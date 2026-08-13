-- Purchasing — Vendors, Purchase Orders, and real stock receiving.
-- Migrates the last major still-local module: "purchasing" is already a
-- tenant_feature (backfilled for SETVACO in the original
-- tenant_features_branding_platform_admin migration), so no new feature
-- flag is needed here, just real tables behind it.
--
-- Same shape as quotations/invoices: purchase_orders/purchase_order_lines
-- are created only through create_purchase_order() and advanced only
-- through advance_purchase_order() (both SECURITY DEFINER, direct
-- INSERT/UPDATE/DELETE revoked from authenticated) — receiving a PO moves
-- real stock through adjust_stock(), so the whole lifecycle needs to be
-- server-controlled, not client-writable.

create sequence seq_vendor;
create sequence seq_purchase_order;

-- ---------------------------------------------------------------------------
-- vendors — root table like customers: company_id comes straight from the
-- caller's own session. vendor_code is the free-text industry/business
-- code (e.g. "SND-GH-014") the Match PO Code feature searches on —
-- distinct from display_code, which is this app's own internal V-XXX
-- reference. certificate_file stores just the chosen filename (no actual
-- upload plumbing here — the prototype UI never uploaded anything either,
-- this preserves that exact scope rather than quietly adding real file
-- storage for vendors too).
-- ---------------------------------------------------------------------------
create table vendors (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references companies(id),
  display_code      text unique not null default gen_display_code('V', 'seq_vendor'::regclass, 3),
  name              text not null,
  vendor_code       text,
  contact_name      text,
  email             text,
  phone             text,
  alt_contact       text,
  categories        text,
  tax_exempt        boolean not null default false,
  certificate_file  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index vendors_company_idx on vendors (company_id);

create function vendors_set_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  return new;
end $$;
create trigger vendors_set_company before insert on vendors
  for each row execute function vendors_set_company();
create trigger vendors_updated_at before update on vendors
  for each row execute function set_updated_at();

alter table vendors enable row level security;
create policy vendors_select on vendors for select using (
  (company_id = current_company_id() and has_role(array['admin', 'procurement', 'finance']))
  or is_platform_admin()
);
create policy vendors_write on vendors for all
  using (company_id = current_company_id() and has_role(array['admin', 'procurement']))
  with check (company_id = current_company_id() and has_role(array['admin', 'procurement']));

-- ---------------------------------------------------------------------------
-- purchase_orders / purchase_order_lines. A PO belongs to either a vendor
-- (a normal internal order) or a customer (the "Match PO Code" flow, where
-- an industry-standard code on an inbound order matches one of our own
-- customers rather than a vendor we ordered from) — never neither.
-- ---------------------------------------------------------------------------
create table purchase_orders (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references companies(id),
  display_code         text unique not null default gen_display_code('PO', 'seq_purchase_order'::regclass, 4),
  vendor_id            uuid references vendors(id),
  customer_id          uuid references customers(id),
  external_po_number   text,
  status               text not null default 'Ordered' check (status in ('Ordered', 'In Transit', 'Received', 'Cancelled')),
  expected_date        date,
  created_by           uuid references profiles(id),
  created_at           timestamptz not null default now(),
  check (vendor_id is not null or customer_id is not null)
);
create index purchase_orders_company_idx on purchase_orders (company_id);

create table purchase_order_lines (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(id),
  po_id         uuid not null references purchase_orders(id) on delete cascade,
  item_id       uuid references items(id),
  description   text not null,
  qty_ordered   numeric not null check (qty_ordered > 0),
  qty_received  numeric not null default 0 check (qty_received >= 0 and qty_received <= qty_ordered),
  unit_cost     numeric(14,2),
  line_no       int not null default 1
);
create index purchase_order_lines_po_idx on purchase_order_lines (po_id);

alter table purchase_orders enable row level security;
create policy purchase_orders_select on purchase_orders for select using (
  (company_id = current_company_id() and has_role(array['admin', 'procurement', 'finance']))
  or is_platform_admin()
);
revoke insert, update, delete on purchase_orders from authenticated;

alter table purchase_order_lines enable row level security;
create policy purchase_order_lines_select on purchase_order_lines for select using (
  (company_id = current_company_id() and has_role(array['admin', 'procurement', 'finance']))
  or is_platform_admin()
);
revoke insert, update, delete on purchase_order_lines from authenticated;

-- ---------------------------------------------------------------------------
-- create_purchase_order — p_lines is a JSON array of {item_id?, description,
-- qty}, same shape as create_quotation's p_lines (item_id nullable for a
-- custom/not-yet-in-inventory line). Every item_id is checked against the
-- caller's own company, same fix already applied to create_quotation.
-- ---------------------------------------------------------------------------
create function create_purchase_order(
  p_vendor_id           uuid default null,
  p_customer_id         uuid default null,
  p_external_po_number  text default null,
  p_expected_date       date default null,
  p_lines               jsonb default '[]'::jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company           uuid;
  v_vendor_company     uuid;
  v_customer_company   uuid;
  v_po_id             uuid;
  v_line              jsonb;
  v_line_no           int := 0;
  v_item_id           uuid;
  v_item_company      uuid;
begin
  if not has_role(array['admin', 'procurement']) then
    raise exception 'Not authorized to raise purchase orders';
  end if;
  if p_vendor_id is null and p_customer_id is null then
    raise exception 'A purchase order needs either a vendor or a matched customer';
  end if;
  v_company := current_company_id();
  if v_company is null then
    raise exception 'No active company for current user';
  end if;

  if p_vendor_id is not null then
    select company_id into v_vendor_company from vendors where id = p_vendor_id;
    if v_vendor_company is null then
      raise exception 'Vendor not found';
    end if;
    if v_vendor_company <> v_company then
      raise exception 'Vendor belongs to a different company';
    end if;
  end if;
  if p_customer_id is not null then
    select company_id into v_customer_company from customers where id = p_customer_id;
    if v_customer_company is null then
      raise exception 'Customer not found';
    end if;
    if v_customer_company <> v_company then
      raise exception 'Customer belongs to a different company';
    end if;
  end if;

  insert into purchase_orders (company_id, vendor_id, customer_id, external_po_number, expected_date, created_by)
  values (v_company, p_vendor_id, p_customer_id, p_external_po_number, p_expected_date, current_profile_id())
  returning id into v_po_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_line_no := v_line_no + 1;
    v_item_id := nullif(v_line->>'item_id', '')::uuid;
    if v_item_id is not null then
      select company_id into v_item_company from items where id = v_item_id;
      if v_item_company is null then
        raise exception 'Item not found';
      end if;
      if v_item_company <> v_company then
        raise exception 'Item belongs to a different company';
      end if;
    end if;
    insert into purchase_order_lines (company_id, po_id, item_id, description, qty_ordered, line_no)
    values (v_company, v_po_id, v_item_id, v_line->>'description', (v_line->>'qty')::numeric, v_line_no);
  end loop;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), 'Raised a purchase order', 'Purchasing', 'purchase_order', v_po_id);

  return v_po_id;
end $$;
grant execute on function create_purchase_order(uuid, uuid, text, date, jsonb) to authenticated;
revoke execute on function create_purchase_order(uuid, uuid, text, date, jsonb) from public, anon;

-- ---------------------------------------------------------------------------
-- advance_purchase_order — Ordered -> In Transit -> Received, matching the
-- existing UI's single "advance" button. Reaching Received receives every
-- line in full and moves real stock through adjust_stock() (reason
-- purchase_receipt) — no partial-receive screen in this pass, that's a
-- real feature of its own, not a gap in this one.
-- ---------------------------------------------------------------------------
create function advance_purchase_order(p_po_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_company      uuid;
  v_status       text;
  v_next_status  text;
  v_line         record;
  v_remaining    numeric;
begin
  if not has_role(array['admin', 'procurement']) then
    raise exception 'Not authorized to update purchase orders';
  end if;

  select company_id, status into v_company, v_status from purchase_orders where id = p_po_id;
  if v_company is null then
    raise exception 'Purchase order not found';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Purchase order belongs to a different company';
  end if;

  if v_status = 'Ordered' then
    v_next_status := 'In Transit';
  elsif v_status = 'In Transit' then
    v_next_status := 'Received';
  else
    raise exception 'Purchase order is already %', v_status;
  end if;

  update purchase_orders set status = v_next_status where id = p_po_id;

  if v_next_status = 'Received' then
    for v_line in select id, item_id, qty_ordered, qty_received from purchase_order_lines where po_id = p_po_id loop
      v_remaining := v_line.qty_ordered - v_line.qty_received;
      if v_line.item_id is not null and v_remaining > 0 then
        perform adjust_stock(
          p_item_id => v_line.item_id,
          p_qty_delta => v_remaining,
          p_reason => 'purchase_receipt',
          p_reference_type => 'purchase_order',
          p_reference_id => p_po_id
        );
      end if;
      update purchase_order_lines set qty_received = qty_ordered where id = v_line.id;
    end loop;
    insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
    values (v_company, current_profile_id(), 'Received purchase order — stock updated', 'Purchasing', 'purchase_order', p_po_id);
  else
    insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
    values (v_company, current_profile_id(), format('Marked purchase order as %s', v_next_status), 'Purchasing', 'purchase_order', p_po_id);
  end if;

  return v_next_status;
end $$;
grant execute on function advance_purchase_order(uuid) to authenticated;
revoke execute on function advance_purchase_order(uuid) from public, anon;
