-- The sales workflow RPCs. Same pattern as adjust_stock: SECURITY DEFINER
-- so they can write to tables `authenticated` has no direct grant on, but
-- every one re-checks role and company itself rather than leaning on RLS
-- (which is bypassed for the duration of a SECURITY DEFINER call).

-- create_quotation: currency and tax rate are derived from the customer's
-- own country_code (via countries/tax_profiles), never taken from the
-- client — a quotation always reflects what that customer is actually
-- taxed and billed in. p_lines is a JSON array of
-- {item_id?, description, qty, unit_price}; item_id is null for a
-- custom/not-yet-in-inventory line, matching the existing UI's
-- "add item not in inventory" option.
create function create_quotation(
  p_customer_id     uuid,
  p_type            item_type,
  p_lines           jsonb,
  p_lead_time_days  int default null,
  p_eta             date default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company        uuid;
  v_country_code   text;
  v_tax_exempt     boolean;
  v_currency_code  text;
  v_tax_rate       numeric(5,2);
  v_subtotal       numeric(14,2) := 0;
  v_tax_amount     numeric(14,2);
  v_total          numeric(14,2);
  v_quotation_id   uuid;
  v_line           jsonb;
  v_line_no        int := 0;
begin
  if not has_role(array['admin','sales']) then
    raise exception 'Not authorized to create quotations';
  end if;
  if jsonb_array_length(p_lines) = 0 then
    raise exception 'A quotation needs at least one line';
  end if;

  select company_id, country_code, tax_exempt into v_company, v_country_code, v_tax_exempt
  from customers where id = p_customer_id;
  if v_company is null then
    raise exception 'Customer not found';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Customer belongs to a different company';
  end if;

  select co.default_currency_code, coalesce(tp.rate_pct, 0)
  into v_currency_code, v_tax_rate
  from countries co
  left join tax_profiles tp on tp.country_code = co.code
  where co.code = v_country_code;

  if v_currency_code is null then
    -- No mapped country on this customer yet — fall back to the company's
    -- own default rather than blocking quotation creation.
    v_currency_code := 'GHS';
    v_tax_rate := 0;
  end if;
  if v_tax_exempt then
    v_tax_rate := 0;
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_subtotal := v_subtotal + (v_line->>'qty')::numeric * (v_line->>'unit_price')::numeric;
  end loop;
  v_tax_amount := round(v_subtotal * v_tax_rate / 100, 2);
  v_total := v_subtotal + v_tax_amount;

  insert into quotations
    (company_id, type, customer_id, currency_code, subtotal, tax_rate, tax_amount, total,
     lead_time_days, eta, prepared_by, created_by)
  values
    (v_company, p_type, p_customer_id, v_currency_code, v_subtotal, v_tax_rate, v_tax_amount, v_total,
     p_lead_time_days, p_eta, current_profile_id(), current_profile_id())
  returning id into v_quotation_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_line_no := v_line_no + 1;
    insert into quotation_lines (company_id, quotation_id, item_id, description, qty, unit_price, line_no)
    values (
      v_company, v_quotation_id,
      nullif(v_line->>'item_id', '')::uuid,
      v_line->>'description',
      (v_line->>'qty')::numeric,
      (v_line->>'unit_price')::numeric,
      v_line_no
    );
  end loop;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), format('Created quotation for %s total', to_char(v_total, 'FM999,999,999.00')), 'Sales', 'quotation', v_quotation_id);

  return v_quotation_id;
end $$;
grant execute on function create_quotation(uuid, item_type, jsonb, int, date) to authenticated;

create function mark_quotation_sent(p_quotation_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid;
begin
  if not has_role(array['admin','sales']) then
    raise exception 'Not authorized';
  end if;
  select company_id into v_company from quotations where id = p_quotation_id and status = 'Quoted';
  if v_company is null then
    raise exception 'Quotation not found or not in Quoted status';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Quotation belongs to a different company';
  end if;
  update quotations set status = 'Sent' where id = p_quotation_id;
end $$;
grant execute on function mark_quotation_sent(uuid) to authenticated;

create function reject_quotation(p_quotation_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid;
begin
  if not has_role(array['admin','sales']) then
    raise exception 'Not authorized';
  end if;
  select company_id into v_company from quotations where id = p_quotation_id and status in ('Quoted','Sent');
  if v_company is null then
    raise exception 'Quotation not found or already closed';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Quotation belongs to a different company';
  end if;
  update quotations set status = 'Rejected' where id = p_quotation_id;
  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), 'Rejected quotation', 'Sales', 'quotation', p_quotation_id);
end $$;
grant execute on function reject_quotation(uuid) to authenticated;

-- convert_quotation_to_invoice: the one function in this file with a real
-- side effect beyond its own tables — every line with a real item_id
-- deducts stock through adjust_stock (reason 'sale'), so the same
-- negative-stock guard and ledger trail apply here as everywhere else.
-- If any line would overdraw stock, the whole conversion rolls back —
-- nothing is invoiced half-fulfilled.
create function convert_quotation_to_invoice(p_quotation_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_q          quotations%rowtype;
  v_invoice_id uuid;
  v_line       record;
begin
  if not has_role(array['admin','sales']) then
    raise exception 'Not authorized to issue invoices';
  end if;

  select * into v_q from quotations where id = p_quotation_id;
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
    (company_id, quotation_id, type, customer_id, currency_code, subtotal, tax_rate, tax_amount, total, created_by)
  values
    (v_q.company_id, v_q.id, v_q.type, v_q.customer_id, v_q.currency_code, v_q.subtotal, v_q.tax_rate, v_q.tax_amount, v_q.total, current_profile_id())
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
grant execute on function convert_quotation_to_invoice(uuid) to authenticated;

create function mark_invoice_paid(p_invoice_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid; v_customer uuid; v_total numeric(14,2); v_status invoice_status;
begin
  if not has_role(array['admin','finance']) then
    raise exception 'Not authorized to mark invoices paid';
  end if;
  select company_id, customer_id, total, status into v_company, v_customer, v_total, v_status
  from invoices where id = p_invoice_id;
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
grant execute on function mark_invoice_paid(uuid) to authenticated;

revoke execute on function create_quotation(uuid, item_type, jsonb, int, date) from public, anon;
revoke execute on function mark_quotation_sent(uuid) from public, anon;
revoke execute on function reject_quotation(uuid) from public, anon;
revoke execute on function convert_quotation_to_invoice(uuid) from public, anon;
revoke execute on function mark_invoice_paid(uuid) from public, anon;
