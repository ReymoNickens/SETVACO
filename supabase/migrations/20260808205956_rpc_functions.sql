-- adjust_stock: the only sanctioned way to change how much of an item is on
-- hand. It never overwrites a number — it inserts one row into
-- inventory_ledger and returns the new running total. Runs as SECURITY
-- DEFINER so it can insert into inventory_ledger (which has no direct
-- INSERT grant for `authenticated`), but re-checks role and tenant itself
-- rather than relying on RLS, since RLS is bypassed for the duration of a
-- SECURITY DEFINER function.
create function adjust_stock(
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

  select company_id, stock_room_id into v_company, v_stock_room
  from items where id = p_item_id;
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

grant execute on function adjust_stock to authenticated;
