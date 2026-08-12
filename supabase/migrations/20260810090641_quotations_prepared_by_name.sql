-- Denormalized snapshot of who prepared the quotation at the time it was
-- created — avoids a cross-table join just to show a name in a list, and
-- means the document correctly keeps showing who actually wrote it even if
-- that staff member's profile name changes later.
alter table quotations add column prepared_by_name text;

create or replace function create_quotation(
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
  v_prepared_by_name text;
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

  select name into v_prepared_by_name from profiles where id = current_profile_id();

  insert into quotations
    (company_id, type, customer_id, currency_code, subtotal, tax_rate, tax_amount, total,
     lead_time_days, eta, prepared_by, prepared_by_name, created_by)
  values
    (v_company, p_type, p_customer_id, v_currency_code, v_subtotal, v_tax_rate, v_tax_amount, v_total,
     p_lead_time_days, p_eta, current_profile_id(), v_prepared_by_name, current_profile_id())
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
