-- Two fixes from the full-codebase review:
--
-- 1. Check-then-act races in every state-transition RPC: each did a plain
--    SELECT precondition check, then an UPDATE that never repeated that
--    check, so two concurrent calls could both pass the check before
--    either committed. Fixed by locking the row being acted on with
--    `for update` as the FIRST read (adjust_stock already had the right
--    shape for its own company/tenant check — this just adds the lock),
--    so a second concurrent call blocks until the first transaction
--    commits, then re-reads the now-changed state and correctly rejects.
--    No behavior change for the normal, non-concurrent path.
--
-- 2. `customers.outstanding` was directly writable by any sales/admin
--    client via plain RLS (`customers_write`), even though it's meant to
--    be a derived balance that only convert_quotation_to_invoice /
--    mark_invoice_paid maintain. A BEFORE UPDATE trigger now rejects any
--    change to it that isn't coming from inside a SECURITY DEFINER RPC —
--    distinguishable because a SECURITY DEFINER function's statements run
--    as the function's owner (current_user), not as the connecting
--    `authenticated` role a direct PostgREST request always uses.
--    `credit_limit` is left as-is: unlike outstanding, it's a business
--    policy value sales/admin legitimately set directly, not a derived
--    ledger balance.

-- ---------------------------------------------------------------------------
-- 1a. adjust_stock — lock the item row before reading the ledger balance.
-- ---------------------------------------------------------------------------
create or replace function adjust_stock(
  p_item_id        uuid,
  p_qty_delta      numeric,
  p_reason         text,
  p_note           text default null,
  p_unit_cost      numeric default null,
  p_currency_code  text default null,
  p_reference_type text default null,
  p_reference_id   uuid default null
) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_company     uuid;
  v_stock_room  uuid;
  v_current_qty numeric;
  v_new_qty     numeric;
begin
  if not has_role(array['admin','warehouse','procurement']) then
    raise exception 'Not authorized to adjust stock';
  end if;
  if p_qty_delta = 0 then
    raise exception 'qty_delta must not be zero';
  end if;
  if p_reason not in ('initial_stock','purchase_receipt','sale','adjustment','transfer_in','transfer_out','correction') then
    raise exception 'Invalid reason: %', p_reason;
  end if;

  -- `for update`: without this, two concurrent calls for the same item
  -- (e.g. two staff both selling the last unit) can both read the same
  -- v_current_qty before either commits, both pass the negative-stock
  -- check below, and both insert a ledger row — taking stock negative
  -- despite the check. Locking here serializes them: the second call
  -- blocks until the first's insert commits, then sees the true balance.
  select company_id, stock_room_id into v_company, v_stock_room
  from items where id = p_item_id
  for update;
  if v_company is null then
    raise exception 'Item not found';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Item belongs to a different company';
  end if;

  select coalesce(sum(qty_delta), 0) into v_current_qty
  from inventory_ledger where item_id = p_item_id;
  v_new_qty := v_current_qty + p_qty_delta;
  if v_new_qty < 0 then
    raise exception 'Stock cannot go negative (currently %, requested change %)', v_current_qty, p_qty_delta;
  end if;

  insert into inventory_ledger
    (company_id, item_id, stock_room_id, qty_delta, reason, unit_cost, currency_code, reference_type, reference_id, note, created_by)
  values
    (v_company, p_item_id, v_stock_room, p_qty_delta, p_reason, p_unit_cost, p_currency_code, p_reference_type, p_reference_id, p_note, current_profile_id());

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (
    v_company, current_profile_id(),
    format('Stock %s %s units (%s)%s',
      case when p_qty_delta > 0 then 'in:' else 'out:' end,
      abs(p_qty_delta), p_reason,
      case when p_note is not null then ' — ' || p_note else '' end),
    'Stock Room', 'item', p_item_id
  );

  return v_new_qty;
end $$;

-- ---------------------------------------------------------------------------
-- 1b. mark_quotation_sent — lock + re-check status instead of a plain
-- SELECT that a concurrent call could race past.
-- ---------------------------------------------------------------------------
create or replace function mark_quotation_sent(p_quotation_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
  v_status  quote_status;
begin
  if not has_role(array['admin','sales']) then
    raise exception 'Not authorized';
  end if;
  select company_id, status into v_company, v_status from quotations where id = p_quotation_id for update;
  if v_company is null then
    raise exception 'Quotation not found';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Quotation belongs to a different company';
  end if;
  if v_status <> 'Quoted' then
    raise exception 'Quotation is not in Quoted status';
  end if;
  update quotations set status = 'Sent' where id = p_quotation_id;
end $$;

-- ---------------------------------------------------------------------------
-- 1c. reject_quotation — same fix.
-- ---------------------------------------------------------------------------
create or replace function reject_quotation(p_quotation_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
  v_status  quote_status;
begin
  if not has_role(array['admin','sales']) then
    raise exception 'Not authorized';
  end if;
  select company_id, status into v_company, v_status from quotations where id = p_quotation_id for update;
  if v_company is null then
    raise exception 'Quotation not found';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Quotation belongs to a different company';
  end if;
  if v_status not in ('Quoted', 'Sent') then
    raise exception 'Quotation already closed';
  end if;
  update quotations set status = 'Rejected' where id = p_quotation_id;
  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), 'Rejected quotation', 'Sales', 'quotation', p_quotation_id);
end $$;

-- ---------------------------------------------------------------------------
-- 1d. convert_quotation_to_invoice — lock the quotation row so two
-- concurrent conversions of the same quotation can't both succeed. The
-- per-line adjust_stock calls inside are already covered by fix 1a's own
-- lock on each item row.
-- ---------------------------------------------------------------------------
create or replace function convert_quotation_to_invoice(p_quotation_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_q          quotations%rowtype;
  v_invoice_id uuid;
  v_line       record;
begin
  if not has_role(array['admin','sales']) then
    raise exception 'Not authorized to issue invoices';
  end if;

  select * into v_q from quotations where id = p_quotation_id for update;
  if v_q.id is null then
    raise exception 'Quotation not found';
  end if;
  if v_q.company_id <> current_company_id() then
    raise exception 'Quotation belongs to a different company';
  end if;
  if v_q.status not in ('Quoted', 'Sent') then
    raise exception 'Only a Quoted or Sent quotation can be converted (current status: %)', v_q.status;
  end if;

  insert into invoices
    (company_id, quotation_id, type, customer_id, currency_code, subtotal, tax_rate, tax_amount, total, prepared_by_name, created_by)
  values
    (v_q.company_id, v_q.id, v_q.type, v_q.customer_id, v_q.currency_code, v_q.subtotal, v_q.tax_rate, v_q.tax_amount, v_q.total, v_q.prepared_by_name, current_profile_id())
  returning id into v_invoice_id;

  for v_line in select * from quotation_lines where quotation_id = v_q.id order by line_no loop
    insert into invoice_lines (company_id, invoice_id, item_id, description, qty, unit_price, line_no)
    values (v_q.company_id, v_invoice_id, v_line.item_id, v_line.description, v_line.qty, v_line.unit_price, v_line.line_no);

    if v_line.item_id is not null then
      perform adjust_stock(
        p_item_id => v_line.item_id,
        p_qty_delta => -v_line.qty,
        p_reason => 'sale',
        p_note => format('Invoiced via %s', v_q.display_code),
        p_reference_type => 'invoice',
        p_reference_id => v_invoice_id
      );
    end if;
  end loop;

  update quotations set status = 'Invoiced' where id = v_q.id;
  update customers set outstanding = outstanding + v_q.total where id = v_q.customer_id;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_q.company_id, current_profile_id(), format('Converted %s to invoice — stock updated, %s added to outstanding', v_q.display_code, to_char(v_q.total, 'FM999,999,999.00')), 'Sales', 'invoice', v_invoice_id);

  return v_invoice_id;
end $$;

-- ---------------------------------------------------------------------------
-- 1e. mark_invoice_paid — lock + re-check status.
-- ---------------------------------------------------------------------------
create or replace function mark_invoice_paid(p_invoice_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid;
  v_customer uuid;
  v_total    numeric(14,2);
  v_status   invoice_status;
begin
  if not has_role(array['admin','finance']) then
    raise exception 'Not authorized to mark invoices paid';
  end if;
  select company_id, customer_id, total, status into v_company, v_customer, v_total, v_status
  from invoices where id = p_invoice_id for update;
  if v_company is null then
    raise exception 'Invoice not found';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Invoice belongs to a different company';
  end if;
  if v_status <> 'Issued' then
    raise exception 'Invoice is not in Issued status';
  end if;

  update invoices set status = 'Paid' where id = p_invoice_id;
  update customers set outstanding = greatest(0, outstanding - v_total) where id = v_customer;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), format('Marked invoice paid — %s removed from outstanding', to_char(v_total, 'FM999,999,999.00')), 'Sales', 'invoice', p_invoice_id);
end $$;

-- ---------------------------------------------------------------------------
-- 2. customers.outstanding — reject direct client writes, only allow
-- changes made from inside a SECURITY DEFINER RPC (convert_quotation_to_
-- invoice / mark_invoice_paid). No frontend code currently writes this
-- column directly (checked index.html — outstanding is read-only there
-- today), so this closes the gap without changing any existing behavior.
-- ---------------------------------------------------------------------------
create function customers_protect_outstanding() returns trigger
language plpgsql as $$
begin
  if new.outstanding is distinct from old.outstanding and current_user = 'authenticated' then
    raise exception 'outstanding cannot be set directly — it is only changed by convert_quotation_to_invoice / mark_invoice_paid';
  end if;
  return new;
end $$;
create trigger customers_protect_outstanding before update on customers
  for each row execute function customers_protect_outstanding();
