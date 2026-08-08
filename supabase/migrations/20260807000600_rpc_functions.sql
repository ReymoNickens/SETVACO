-- RPC functions. Every function here is SECURITY DEFINER because it needs to
-- either (a) atomically touch more than one table (a document + its lines +
-- stock + the audit log, in one transaction), or (b) look up a row the
-- calling role isn't granted SELECT on by RLS (match_po_code letting
-- procurement resolve a customer's PO code without granting procurement
-- blanket customer visibility). Each function re-implements the exact
-- business rule found at the cited index.html line, so behavior does not
-- silently drift from the frontend it's replacing.

-- ---------------------------------------------------------------------------
-- create_quotation — mirrors CreateQuotationModal.submit() (index.html:866).
-- Recomputes totals and the approval-threshold decision server-side; never
-- trusts a client-sent total.
-- ---------------------------------------------------------------------------
create or replace function create_quotation(
  p_type item_type,
  p_customer_id uuid,
  p_is_new_customer boolean,
  p_new_customer_name text,
  p_new_customer_country text,
  p_lines jsonb,                 -- [{item_id, description, qty, unit_price, new_part}]
  p_notes text default null,
  p_lead_time_days integer default null,
  p_eta date default null,
  p_prepared_by_id uuid default null,
  p_apply_tax boolean default true,
  p_tax_rate numeric default 15
) returns quotations
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_customer customers;
  v_line jsonb;
  v_line_subtotal numeric := 0;
  v_tax_amount numeric := 0;
  v_total numeric := 0;
  v_effective_apply_tax boolean;
  v_needs_approval boolean;
  v_status quote_status;
  v_quotation quotations;
  v_line_no integer := 0;
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  if not has_role(array['admin','sales']) then raise exception 'Not authorized to create quotations'; end if;
  select name into v_actor_name from profiles where id = v_actor;

  if p_is_new_customer then
    if p_new_customer_name is null or btrim(p_new_customer_name) = '' then
      raise exception 'Customer name required';
    end if;
    insert into customers (name, country, tier, is_walk_in)
    values (btrim(p_new_customer_name), coalesce(nullif(btrim(p_new_customer_country), ''), '—'), 'Standard', true)
    returning * into v_customer;
    insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
    values (v_actor, v_actor_name, format('Created walk-in customer record for %s', v_customer.name), 'Customers', 'customer', v_customer.id);
  else
    select * into v_customer from customers where id = p_customer_id;
    if v_customer.id is null then raise exception 'Customer not found'; end if;
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if coalesce((v_line->>'qty')::numeric, 0) > 0
       and (nullif(v_line->>'item_id', '') is not null or nullif(v_line->>'description', '') is not null) then
      v_line_subtotal := v_line_subtotal + (v_line->>'qty')::numeric * coalesce((v_line->>'unit_price')::numeric, 0);
    end if;
  end loop;

  v_effective_apply_tax := p_apply_tax and not v_customer.tax_exempt;
  v_tax_amount := case when v_effective_apply_tax then round(v_line_subtotal * coalesce(p_tax_rate, 0) / 100) else 0 end;
  v_total := v_line_subtotal + v_tax_amount;
  v_needs_approval := v_total > (select value_threshold from approval_settings where id = true)
    or exists (select 1 from approval_flagged_customers where customer_id = v_customer.id);
  v_status := case when v_needs_approval then 'Pending Approval'::quote_status else 'Quoted'::quote_status end;

  insert into quotations (type, customer_id, country, notes, subtotal, apply_tax, tax_rate, tax_amount, total,
      lead_time_days, eta, prepared_by_id, status, created_by)
    values (p_type, v_customer.id, v_customer.country, p_notes, v_line_subtotal, v_effective_apply_tax,
      coalesce(p_tax_rate, 0), v_tax_amount, v_total, p_lead_time_days, p_eta,
      coalesce(p_prepared_by_id, v_actor), v_status, v_actor)
    returning * into v_quotation;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if coalesce((v_line->>'qty')::numeric, 0) > 0
       and (nullif(v_line->>'item_id', '') is not null or nullif(v_line->>'description', '') is not null) then
      v_line_no := v_line_no + 1;
      insert into quotation_lines (quotation_id, item_id, description, qty, unit_price, new_part, line_no)
      values (
        v_quotation.id,
        nullif(v_line->>'item_id', '')::uuid,
        coalesce(nullif(v_line->>'description', ''), (select name from items where id = nullif(v_line->>'item_id', '')::uuid), ''),
        (v_line->>'qty')::numeric,
        coalesce((v_line->>'unit_price')::numeric, 0),
        coalesce((v_line->>'new_part')::boolean, false),
        v_line_no
      );
    end if;
  end loop;

  insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
  values (v_actor, v_actor_name,
    format('Created %s quotation %s for %s%s', p_type::text, v_quotation.display_code, v_customer.name,
      case when v_needs_approval then ' — held for management approval' else '' end),
    'Sales', 'quotation', v_quotation.id);

  insert into notifications (type, message)
  values ('quote', format('%s created for %s%s', v_quotation.display_code, v_customer.name,
    case when v_needs_approval then ' (pending approval)' else '' end));

  return v_quotation;
end;
$$;

-- ---------------------------------------------------------------------------
-- approve_quotation / reject_quotation — mirrors approveOrder/rejectOrder
-- (index.html:1194-1201), guarded to admin/finance and Pending Approval only,
-- matching QuotationDetailDrawer's canApprove (index.html:1233).
-- ---------------------------------------------------------------------------
create or replace function approve_quotation(p_id uuid) returns quotations
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_quotation quotations;
begin
  if v_actor is null or not has_role(array['admin','finance']) then
    raise exception 'Not authorized to approve quotations';
  end if;
  select name into v_actor_name from profiles where id = v_actor;

  update quotations set status = 'Quoted'
  where id = p_id and status = 'Pending Approval'
  returning * into v_quotation;
  if v_quotation.id is null then raise exception 'Quotation not found or not pending approval'; end if;

  insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
  values (v_actor, v_actor_name, format('%s approved by %s', v_quotation.display_code, v_actor_name), 'Sales', 'quotation', v_quotation.id);
  return v_quotation;
end;
$$;

create or replace function reject_quotation(p_id uuid) returns quotations
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_quotation quotations;
begin
  if v_actor is null or not has_role(array['admin','finance']) then
    raise exception 'Not authorized to reject quotations';
  end if;
  select name into v_actor_name from profiles where id = v_actor;

  update quotations set status = 'Rejected'
  where id = p_id and status = 'Pending Approval'
  returning * into v_quotation;
  if v_quotation.id is null then raise exception 'Quotation not found or not pending approval'; end if;

  insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
  values (v_actor, v_actor_name, format('%s rejected by %s', v_quotation.display_code, v_actor_name), 'Sales', 'quotation', v_quotation.id);
  return v_quotation;
end;
$$;

-- ---------------------------------------------------------------------------
-- convert_quotation_to_invoice — mirrors convertQuotationToInvoice
-- (index.html:1281): one transaction covering the invoice + its lines, the
-- quotation status flip, and the stock deduction per line.
-- ---------------------------------------------------------------------------
create or replace function convert_quotation_to_invoice(p_quotation_id uuid) returns invoices
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_quotation quotations;
  v_customer_name text;
  v_invoice invoices;
  v_line record;
begin
  if v_actor is null or not has_role(array['admin','sales']) then
    raise exception 'Not authorized to convert quotations to invoices';
  end if;
  select name into v_actor_name from profiles where id = v_actor;

  update quotations set status = 'Invoiced'
  where id = p_quotation_id and status in ('Quoted', 'Sent')
  returning * into v_quotation;
  if v_quotation.id is null then raise exception 'Quotation not found or not in a convertible status'; end if;
  select name into v_customer_name from customers where id = v_quotation.customer_id;

  insert into invoices (quotation_id, type, customer_id, subtotal, apply_tax, tax_rate, tax_amount, total, status, created_by)
  values (v_quotation.id, v_quotation.type, v_quotation.customer_id, v_quotation.subtotal, v_quotation.apply_tax,
    v_quotation.tax_rate, v_quotation.tax_amount, v_quotation.total, 'Issued', v_actor)
  returning * into v_invoice;

  for v_line in select * from quotation_lines where quotation_id = v_quotation.id loop
    insert into invoice_lines (invoice_id, item_id, description, qty, unit_price, new_part, line_no)
    values (v_invoice.id, v_line.item_id, v_line.description, v_line.qty, v_line.unit_price, v_line.new_part, v_line.line_no);

    if v_line.item_id is not null then
      update items set qty = greatest(0, qty - v_line.qty) where id = v_line.item_id;
    end if;
  end loop;

  insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
  values (v_actor, v_actor_name,
    format('Converted %s to invoice %s for %s — stock updated', v_quotation.display_code, v_invoice.display_code, v_customer_name),
    'Sales', 'invoice', v_invoice.id);

  insert into notifications (type, message)
  values ('invoice', format('%s issued to %s', v_invoice.display_code, v_customer_name));

  return v_invoice;
end;
$$;

-- ---------------------------------------------------------------------------
-- raise_purchase_order — mirrors InternalPOsTab.submit() (index.html:1360).
-- ---------------------------------------------------------------------------
create or replace function raise_purchase_order(
  p_vendor_id uuid,
  p_expected date,
  p_lines jsonb        -- [{item_id, item_name, qty}]
) returns purchase_orders
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_vendor vendors;
  v_po purchase_orders;
  v_line jsonb;
  v_line_names text := '';
begin
  if v_actor is null or not has_role(array['admin','procurement']) then
    raise exception 'Not authorized to raise purchase orders';
  end if;
  select name into v_actor_name from profiles where id = v_actor;

  select * into v_vendor from vendors where id = p_vendor_id;
  if v_vendor.id is null then raise exception 'Vendor not found'; end if;

  insert into purchase_orders (vendor_id, status, expected, source, created_by)
  values (v_vendor.id, 'Ordered', p_expected, 'manual', v_actor)
  returning * into v_po;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if nullif(v_line->>'item_id', '') is not null and coalesce((v_line->>'qty')::numeric, 0) > 0 then
      insert into purchase_order_lines (purchase_order_id, item_id, item_name, qty)
      values (v_po.id, (v_line->>'item_id')::uuid, v_line->>'item_name', (v_line->>'qty')::numeric);
      v_line_names := v_line_names || case when v_line_names = '' then '' else ', ' end || (v_line->>'item_name');
    end if;
  end loop;

  insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
  values (v_actor, v_actor_name, format('Raised %s to %s for %s', v_po.display_code, v_vendor.name, v_line_names), 'Purchasing', 'purchase_order', v_po.id);

  insert into notifications (type, message)
  values ('po', format('%s raised to %s', v_po.display_code, v_vendor.name));

  return v_po;
end;
$$;

-- ---------------------------------------------------------------------------
-- advance_purchase_order — mirrors InternalPOsTab.advance() (index.html:1371):
-- forward-only Ordered -> In Transit -> Received, stock addition only on the
-- Received transition.
-- ---------------------------------------------------------------------------
create or replace function advance_purchase_order(p_id uuid) returns purchase_orders
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_po purchase_orders;
  v_next po_status;
  v_line record;
  v_line_names text := '';
begin
  if v_actor is null or not has_role(array['admin','procurement']) then
    raise exception 'Not authorized to advance purchase orders';
  end if;
  select name into v_actor_name from profiles where id = v_actor;

  select * into v_po from purchase_orders where id = p_id;
  if v_po.id is null then raise exception 'Purchase order not found'; end if;

  v_next := case v_po.status
    when 'Ordered' then 'In Transit'::po_status
    when 'In Transit' then 'Received'::po_status
    else v_po.status
  end;
  if v_next = v_po.status then return v_po; end if;

  update purchase_orders set status = v_next where id = v_po.id returning * into v_po;

  if v_next = 'Received' then
    for v_line in select * from purchase_order_lines where purchase_order_id = v_po.id loop
      if v_line.item_id is not null then
        update items set qty = qty + v_line.qty where id = v_line.item_id;
      end if;
      v_line_names := v_line_names || case when v_line_names = '' then '' else ', ' end || v_line.item_name;
    end loop;
    insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
    values (v_actor, v_actor_name,
      format('Received %s — stock updated for %s', v_po.display_code, coalesce(nullif(v_line_names, ''), 'matched order')),
      'Purchasing', 'purchase_order', v_po.id);
  else
    insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
    values (v_actor, v_actor_name, format('Marked %s as %s', v_po.display_code, v_next), 'Purchasing', 'purchase_order', v_po.id);
  end if;

  return v_po;
end;
$$;

-- ---------------------------------------------------------------------------
-- match_po_code / submit_matched_order — mirrors MatchPOCodeTab (index.html:
-- 1488). SECURITY DEFINER lets procurement resolve a code against customers
-- without granting procurement blanket customer SELECT via RLS — only the
-- minimal matched fields are returned, not the full row.
-- ---------------------------------------------------------------------------
create or replace function match_po_code(p_code text)
returns table (kind text, id uuid, name text, country text, contact_person text, email text)
language plpgsql security definer set search_path = public as $$
declare
  v_needle text := upper(btrim(p_code));
begin
  if not has_role(array['admin','procurement','finance']) then
    raise exception 'Not authorized to match PO codes';
  end if;
  if v_needle = '' then return; end if;

  return query
    select 'customer'::text, c.id, c.name, c.country, c.contact_person, c.email
    from customers c where upper(c.po_code) = v_needle limit 1;
  if found then return; end if;

  return query
    select 'vendor'::text, v.id, v.name, null::text, null::text, null::text
    from vendors v where upper(v.code) = v_needle limit 1;
end;
$$;

create or replace function submit_matched_order(p_code text, p_external_po_number text) returns purchase_orders
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_customer customers;
  v_po purchase_orders;
begin
  if v_actor is null or not has_role(array['admin','procurement']) then
    raise exception 'Not authorized to submit matched orders';
  end if;
  select name into v_actor_name from profiles where id = v_actor;

  select * into v_customer from customers where upper(po_code) = upper(btrim(p_code));
  if v_customer.id is null then raise exception 'No customer found with that PO code'; end if;

  insert into purchase_orders (vendor_id, customer_id, external_po_number, status, source, created_by)
  values (null, v_customer.id, coalesce(nullif(p_external_po_number, ''), p_code), 'Ordered', 'matched', v_actor)
  returning * into v_po;

  insert into audit_log (actor_id, actor_name, action, module, entity_type, entity_id)
  values (v_actor, v_actor_name,
    format('Matched industry code %s to %s and submitted order %s (external PO %s)', p_code, v_customer.name, v_po.display_code, coalesce(nullif(p_external_po_number, ''), 'n/a')),
    'Purchasing', 'purchase_order', v_po.id);

  insert into notifications (type, message)
  values ('po', format('Order %s submitted for %s from matched PO code %s', v_po.display_code, v_customer.name, p_code));

  return v_po;
end;
$$;

-- ---------------------------------------------------------------------------
-- bulk_upsert_items — commit path for the Excel inventory import (SheetJS
-- parsing stays client-side; this validates and writes the whole batch in one
-- transaction instead of trusting a direct setItems(...) as today's
-- confirmUpload() does).
-- ---------------------------------------------------------------------------
create or replace function bulk_upsert_items(p_rows jsonb) returns setof items
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_row jsonb;
  v_branch_id uuid;
  v_stock_room_id uuid;
  v_count integer := 0;
begin
  if v_actor is null or not has_role(array['admin','warehouse','procurement']) then
    raise exception 'Not authorized to import inventory';
  end if;
  select name into v_actor_name from profiles where id = v_actor;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    select id into v_branch_id from branches where name = v_row->>'branch';
    if v_branch_id is null then raise exception 'Unknown branch: %', v_row->>'branch'; end if;
    select id into v_stock_room_id from stock_rooms where name = v_row->>'stock_room' and branch_id = v_branch_id;
    if v_stock_room_id is null then raise exception 'Unknown stock room: % (%)', v_row->>'stock_room', v_row->>'branch'; end if;

    insert into items (display_code, type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell)
    values (
      nullif(v_row->>'display_code', ''), (v_row->>'type')::item_type, v_row->>'name', v_row->>'brand', v_row->>'category',
      v_branch_id, v_stock_room_id, coalesce((v_row->>'qty')::numeric, 0), coalesce((v_row->>'reorder')::numeric, 0),
      coalesce((v_row->>'cost')::numeric, 0), coalesce((v_row->>'sell')::numeric, 0)
    )
    on conflict (display_code) do update set
      name = excluded.name, brand = excluded.brand, category = excluded.category,
      branch_id = excluded.branch_id, stock_room_id = excluded.stock_room_id,
      qty = excluded.qty, reorder = excluded.reorder, cost = excluded.cost, sell = excluded.sell;
    v_count := v_count + 1;
  end loop;

  insert into audit_log (actor_id, actor_name, action, module)
  values (v_actor, v_actor_name, format('Bulk-imported %s inventory row(s)', v_count), 'Inventory');

  return query select * from items;
end;
$$;

-- ---------------------------------------------------------------------------
-- bulk_create_purchase_orders — commit path for the "Upload purchase order"
-- flow (InventoryPanel's showUploadPO), grouped client-side by vendor/party
-- exactly as today, written server-side in one transaction.
-- ---------------------------------------------------------------------------
create or replace function bulk_create_purchase_orders(p_groups jsonb)
  -- p_groups: [{vendor_id, vendor_name_raw, expected, lines: [{item_id, item_name, qty}]}]
returns setof purchase_orders
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_profile_id();
  v_actor_name text;
  v_group jsonb;
  v_line jsonb;
  v_po purchase_orders;
  v_count integer := 0;
begin
  if v_actor is null or not has_role(array['admin','procurement','warehouse']) then
    raise exception 'Not authorized to import purchase orders';
  end if;
  select name into v_actor_name from profiles where id = v_actor;

  for v_group in select * from jsonb_array_elements(p_groups) loop
    insert into purchase_orders (vendor_id, vendor_name_raw, expected, status, source, created_by)
    values (nullif(v_group->>'vendor_id', '')::uuid, v_group->>'vendor_name_raw', nullif(v_group->>'expected', '')::date, 'Ordered', 'uploaded', v_actor)
    returning * into v_po;

    for v_line in select * from jsonb_array_elements(v_group->'lines') loop
      insert into purchase_order_lines (purchase_order_id, item_id, item_name, qty)
      values (v_po.id, nullif(v_line->>'item_id', '')::uuid, v_line->>'item_name', coalesce((v_line->>'qty')::numeric, 0));
    end loop;
    v_count := v_count + 1;
  end loop;

  insert into audit_log (actor_id, actor_name, action, module)
  values (v_actor, v_actor_name, format('Bulk-uploaded %s purchase order(s)', v_count), 'Purchasing');

  return query select * from purchase_orders order by created_at desc limit v_count;
end;
$$;

-- All RPCs above check has_role(...) themselves, so a blanket EXECUTE grant on
-- every function in the schema is safe (unauthorized callers are rejected
-- inside the function body, not by the grant).
grant execute on all functions in schema public to authenticated;
