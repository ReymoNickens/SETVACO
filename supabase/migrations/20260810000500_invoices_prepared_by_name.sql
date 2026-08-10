alter table invoices add column prepared_by_name text;

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
