-- Remaining items from the full-codebase review, batched into one
-- migration: two real gaps (create_quotation's missing item_id tenant
-- check, expenses self-approval) plus structural consistency fixes
-- (missing updated_at triggers, stock_rooms missing its "on move"
-- re-derivation trigger, handle_new_auth_user missing the existence-check
-- pattern every sibling trigger already has). All additive/behavior-
-- tightening only — nothing here removes existing access.

-- ---------------------------------------------------------------------------
-- create_quotation — every other cross-table reference in the schema
-- validates the referenced row belongs to the same company (stock_rooms ->
-- branches, items -> stock_rooms, employee_details -> branches, ...) and
-- raises if not. This one didn't: a line's item_id was inserted into
-- quotation_lines with no check at all, so a guessed/leaked item_id from
-- another tenant would be silently accepted.
-- ---------------------------------------------------------------------------
create or replace function create_quotation(
  p_customer_id     uuid,
  p_type            item_type,
  p_lines           jsonb,
  p_lead_time_days  int default null,
  p_eta             date default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company          uuid;
  v_country_code     text;
  v_tax_exempt       boolean;
  v_currency_code    text;
  v_tax_rate         numeric(5,2);
  v_subtotal         numeric(14,2) := 0;
  v_tax_amount       numeric(14,2);
  v_total            numeric(14,2);
  v_quotation_id     uuid;
  v_line             jsonb;
  v_line_no          int := 0;
  v_prepared_by_name text;
  v_item_id          uuid;
  v_item_company     uuid;
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

    insert into quotation_lines (company_id, quotation_id, item_id, description, qty, unit_price, line_no)
    values (
      v_company, v_quotation_id, v_item_id,
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

-- ---------------------------------------------------------------------------
-- expenses — segregation of duties: a finance/admin user could previously
-- submit their own expense and then approve/reject/mark-paid it themselves.
-- Now the approver must be someone other than the submitter.
-- ---------------------------------------------------------------------------
drop policy expenses_update on expenses;
create policy expenses_update on expenses for update
  using (company_id = current_company_id() and has_role(array['admin', 'finance']) and submitted_by <> current_profile_id())
  with check (company_id = current_company_id() and has_role(array['admin', 'finance']) and submitted_by <> current_profile_id());

-- ---------------------------------------------------------------------------
-- Missing updated_at columns/triggers on mutable tables. quotations,
-- invoices, items, customers, employee_details all already have this —
-- these five didn't, despite all being writable via a `for all`/update
-- policy.
-- ---------------------------------------------------------------------------
alter table branches add column updated_at timestamptz not null default now();
create trigger branches_updated_at before update on branches
  for each row execute function set_updated_at();

alter table stock_rooms add column updated_at timestamptz not null default now();
create trigger stock_rooms_updated_at before update on stock_rooms
  for each row execute function set_updated_at();

alter table customer_contacts add column updated_at timestamptz not null default now();
create trigger customer_contacts_updated_at before update on customer_contacts
  for each row execute function set_updated_at();

alter table leave_requests add column updated_at timestamptz not null default now();
create trigger leave_requests_updated_at before update on leave_requests
  for each row execute function set_updated_at();

alter table expenses add column updated_at timestamptz not null default now();
create trigger expenses_updated_at before update on expenses
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- stock_rooms was the one place in the branch/stock_room/item hierarchy
-- missing the "re-derive on move" trigger its siblings (items, employee_
-- details) have — an update to stock_rooms.branch_id never re-validated
-- or re-derived company_id. stock_rooms_set_tenant already has the right
-- logic (it's what runs on insert); this just also runs it on branch_id
-- changes.
-- ---------------------------------------------------------------------------
create trigger stock_rooms_set_tenant_on_move before update of branch_id on stock_rooms
  for each row execute function stock_rooms_set_tenant();

-- ---------------------------------------------------------------------------
-- handle_new_auth_user — every other tenant-derivation trigger explicitly
-- checks its parent row exists and raises a friendly error; this one only
-- checked company_id wasn't null, so a stale/malformed company_id in
-- raw_app_meta_data fell through to a raw FK-violation error during signup
-- — the one place a clean error matters most.
-- ---------------------------------------------------------------------------
create or replace function handle_new_auth_user() returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_company_id uuid;
begin
  v_company_id := (new.raw_app_meta_data->>'company_id')::uuid;
  if v_company_id is null then
    raise exception 'Signup rejected: account must be provisioned by an administrator';
  end if;
  if not exists (select 1 from companies where id = v_company_id) then
    raise exception 'Signup rejected: company % does not exist', v_company_id;
  end if;
  insert into profiles (id, company_id, name, email, username, role)
  values (
    new.id,
    v_company_id,
    coalesce(new.raw_user_meta_data->>'name', new.email),
    new.email,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    'sales'
  );
  return new;
end $$;
