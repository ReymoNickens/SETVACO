-- Accounts Payable — a new feature, not a migration; there was no schema
-- or nav item for it at all. Scoped to PO-receipt-only per the brief: a
-- vendor bill is created automatically when a purchase order is received,
-- not entered manually. That means purchase orders need to actually carry
-- a cost first — purchase_order_lines.unit_cost has existed since the
-- Purchasing migration but was never populated anywhere (the frontend
-- never asked for one), so a payable had nothing to compute an amount
-- from. This fills that gap as a prerequisite, not scope creep: without
-- it, Accounts Payable literally cannot produce a bill amount.
--
-- Payment terms are a flat net-30 from receipt for every vendor (no
-- per-vendor payment-terms field exists, and adding one is its own design
-- decision, not needed to make this feature work) — documented
-- simplification, same spirit as the payroll migration's "best-effort
-- Ghana tax bands, not a certified engine" note.
--
-- Bills are RPC-only, same posture as purchase_orders/quotations: the
-- amount must come from the PO's own lines, never trusted from the
-- client, and "paid" is a state transition, not a freely-editable field.

create sequence seq_vendor_bill;

create table vendor_bills (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('AP', 'seq_vendor_bill'::regclass, 3),
  vendor_id    uuid not null references vendors(id),
  po_id        uuid not null references purchase_orders(id) unique,
  amount       numeric(14,2) not null,
  status       text not null default 'Open' check (status in ('Open', 'Paid')),
  due_date     date not null,
  created_at   timestamptz not null default now(),
  paid_by      uuid references profiles(id),
  paid_at      timestamptz
);
create index vendor_bills_company_idx on vendor_bills (company_id);
create index vendor_bills_vendor_idx on vendor_bills (vendor_id);

alter table vendor_bills enable row level security;
-- Same roles as purchase_orders_select — whoever can see the PO that
-- generated a bill can see the bill.
create policy vendor_bills_select on vendor_bills for select using (
  (company_id = current_company_id() and has_role(array['admin', 'procurement', 'finance']))
  or is_platform_admin()
);
revoke insert, update, delete on vendor_bills from authenticated;

-- ---------------------------------------------------------------------------
-- create_purchase_order — unchanged behavior, extended p_lines shape: each
-- line may now carry an optional unit_cost (null stays null, same as
-- before, for lines nobody priced). Signature is backward compatible —
-- unit_cost simply won't be present in older callers' line objects.
-- ---------------------------------------------------------------------------
create or replace function create_purchase_order(
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
    insert into purchase_order_lines (company_id, po_id, item_id, description, qty_ordered, unit_cost, line_no)
    values (v_company, v_po_id, v_item_id, v_line->>'description', (v_line->>'qty')::numeric,
      nullif(v_line->>'unit_cost', '')::numeric, v_line_no);
  end loop;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), 'Raised a purchase order', 'Purchasing', 'purchase_order', v_po_id);

  return v_po_id;
end $$;

-- ---------------------------------------------------------------------------
-- advance_purchase_order — unchanged for every transition except reaching
-- Received on a vendor-sourced PO (a customer-matched PO owes nothing to
-- anyone and never generates a bill): after stock is received, sums
-- qty_ordered * unit_cost across the PO's own lines (coalescing an unpriced
-- line's cost to 0 rather than failing the whole receipt over one missing
-- price) and inserts the one vendor_bills row this PO will ever have.
-- ---------------------------------------------------------------------------
create or replace function advance_purchase_order(p_po_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_company      uuid;
  v_status       text;
  v_vendor_id    uuid;
  v_next_status  text;
  v_line         record;
  v_remaining    numeric;
  v_bill_amount  numeric;
begin
  if not has_role(array['admin', 'procurement']) then
    raise exception 'Not authorized to update purchase orders';
  end if;

  select company_id, status, vendor_id into v_company, v_status, v_vendor_id from purchase_orders where id = p_po_id;
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

    if v_vendor_id is not null then
      select coalesce(sum(qty_ordered * coalesce(unit_cost, 0)), 0) into v_bill_amount
      from purchase_order_lines where po_id = p_po_id;

      insert into vendor_bills (company_id, vendor_id, po_id, amount, due_date)
      values (v_company, v_vendor_id, p_po_id, v_bill_amount, (now() + interval '30 days')::date);

      insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
      values (v_company, current_profile_id(), format('Vendor bill created for %s', to_char(v_bill_amount, 'FM999,999,990.00')), 'Accounts Payable', 'purchase_order', p_po_id);
    end if;
  else
    insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
    values (v_company, current_profile_id(), format('Marked purchase order as %s', v_next_status), 'Purchasing', 'purchase_order', p_po_id);
  end if;

  return v_next_status;
end $$;

create function pay_vendor_bill(p_bill_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
  v_status  text;
begin
  if not has_role(array['admin', 'finance']) then
    raise exception 'Not authorized to pay a vendor bill';
  end if;

  select company_id, status into v_company, v_status from vendor_bills where id = p_bill_id for update;
  if v_company is null then
    raise exception 'Vendor bill not found';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Vendor bill belongs to a different company';
  end if;
  if v_status <> 'Open' then
    raise exception 'Vendor bill is already paid';
  end if;

  update vendor_bills set status = 'Paid', paid_by = current_profile_id(), paid_at = now() where id = p_bill_id;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), 'Paid a vendor bill', 'Accounts Payable', 'vendor_bill', p_bill_id);
end $$;
revoke execute on function pay_vendor_bill(uuid) from public, anon;
grant execute on function pay_vendor_bill(uuid) to authenticated;

insert into features (key, label) values ('accounts_payable', 'Accounts Payable');
insert into tenant_features (company_id, feature_key)
select id, 'accounts_payable' from companies where slug = 'setvaco';
