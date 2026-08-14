-- Stock Variance / cycle counts — the Variance & Audit tab's "Stock
-- Variance" sub-tab was reading a hardcoded const (varianceLog), because
-- there was no feature anywhere in the schema that actually recorded a
-- physical stock count. This adds one.
--
-- A count is two-phase: create_stock_count() snapshots each item's current
-- on-hand quantity (summed from inventory_ledger, the same source of truth
-- adjust_stock() itself uses — never trusted from the client) alongside
-- what was physically counted, so the variance is always computed against
-- a real number from the moment of counting, not something that could
-- drift by the time someone reviews it. Recording a count does NOT touch
-- stock by itself — post_stock_count() is the separate, explicit step
-- that reconciles system quantity to match the physical count, posting a
-- 'correction' row per line through the exact same adjust_stock() path
-- purchase receipts and sales already use, so a reconciliation is just as
-- ledger-traceable as any other stock movement.

create sequence seq_stock_count;

create table stock_counts (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(id),
  display_code  text unique not null default gen_display_code('SC', 'seq_stock_count'::regclass, 3),
  stock_room_id uuid not null references stock_rooms(id),
  status        text not null default 'Open' check (status in ('Open', 'Posted')),
  counted_by    uuid not null references profiles(id),
  posted_by     uuid references profiles(id),
  created_at    timestamptz not null default now(),
  posted_at     timestamptz
);
create index stock_counts_company_idx on stock_counts (company_id);

create table stock_count_lines (
  id             uuid primary key default gen_random_uuid(),
  stock_count_id uuid not null references stock_counts(id) on delete cascade,
  item_id        uuid not null references items(id),
  expected_qty   numeric not null,
  counted_qty    numeric not null,
  note           text
);
create index stock_count_lines_count_idx on stock_count_lines (stock_count_id);

alter table stock_counts enable row level security;
alter table stock_count_lines enable row level security;

-- Same posture as adjust_stock's own role gate: the people who touch
-- physical stock, plus finance for oversight.
create policy stock_counts_select on stock_counts for select using (
  company_id = current_company_id() and has_role(array['admin','warehouse','procurement','finance'])
);
create policy stock_count_lines_select on stock_count_lines for select using (
  exists (select 1 from stock_counts sc where sc.id = stock_count_lines.stock_count_id
    and sc.company_id = current_company_id() and has_role(array['admin','warehouse','procurement','finance']))
);
-- No direct insert/update path on either table for the same reason
-- purchase_orders/quotations aren't directly writable: expected_qty must
-- be a server-computed snapshot, and posting must apply adjust_stock's
-- own negative-stock guard atomically per line. Both RPCs below are
-- SECURITY DEFINER; direct table access stays revoked from authenticated.
revoke insert, update, delete on stock_counts from authenticated;
revoke insert, update, delete on stock_count_lines from authenticated;

create function create_stock_count(p_stock_room_id uuid, p_lines jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
  v_count_id uuid;
  v_line jsonb;
  v_item_id uuid;
  v_counted_qty numeric;
  v_expected_qty numeric;
  v_item_company uuid;
begin
  if not has_role(array['admin','warehouse','procurement']) then
    raise exception 'Not authorized to record a stock count';
  end if;
  v_company := current_company_id();
  if v_company is null then
    raise exception 'No active company for this session';
  end if;
  if jsonb_array_length(p_lines) = 0 then
    raise exception 'A stock count needs at least one line';
  end if;

  insert into stock_counts (company_id, stock_room_id, counted_by)
  values (v_company, p_stock_room_id, current_profile_id())
  returning id into v_count_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_item_id := (v_line->>'item_id')::uuid;
    v_counted_qty := (v_line->>'counted_qty')::numeric;

    select company_id into v_item_company from items where id = v_item_id for update;
    if v_item_company is null then
      raise exception 'Item not found';
    end if;
    if v_item_company <> v_company then
      raise exception 'Item belongs to a different company';
    end if;

    select coalesce(sum(qty_delta), 0) into v_expected_qty
    from inventory_ledger where item_id = v_item_id;

    insert into stock_count_lines (stock_count_id, item_id, expected_qty, counted_qty, note)
    values (v_count_id, v_item_id, v_expected_qty, v_counted_qty, v_line->>'note');
  end loop;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), 'Recorded a stock count', 'Stock Room', 'stock_count', v_count_id);

  return v_count_id;
end $$;
revoke execute on function create_stock_count(uuid, jsonb) from public, anon;
grant execute on function create_stock_count(uuid, jsonb) to authenticated;

create function post_stock_count(p_stock_count_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
  v_status text;
  v_line record;
begin
  if not has_role(array['admin','warehouse','procurement']) then
    raise exception 'Not authorized to post a stock count';
  end if;

  select company_id, status into v_company, v_status from stock_counts where id = p_stock_count_id for update;
  if v_company is null then
    raise exception 'Stock count not found';
  end if;
  if v_company <> current_company_id() then
    raise exception 'Stock count belongs to a different company';
  end if;
  if v_status <> 'Open' then
    raise exception 'Stock count is already posted';
  end if;

  for v_line in select item_id, counted_qty - expected_qty as delta, note
                from stock_count_lines where stock_count_id = p_stock_count_id
  loop
    if v_line.delta <> 0 then
      perform adjust_stock(v_line.item_id, v_line.delta, 'correction',
        coalesce('Stock count reconciliation' || (case when v_line.note is not null then ' — ' || v_line.note else '' end), null));
    end if;
  end loop;

  update stock_counts set status = 'Posted', posted_by = current_profile_id(), posted_at = now()
  where id = p_stock_count_id;

  insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
  values (v_company, current_profile_id(), 'Posted a stock count', 'Stock Room', 'stock_count', p_stock_count_id);
end $$;
revoke execute on function post_stock_count(uuid) from public, anon;
grant execute on function post_stock_count(uuid) to authenticated;
