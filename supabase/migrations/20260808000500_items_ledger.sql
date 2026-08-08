-- Items and the inventory ledger.
--
-- On purpose, `items` has NO quantity column at all — there is nothing to
-- overwrite. Every stock change (initial stock, a purchase coming in, a
-- sale going out, a manual correction) is a new row in `inventory_ledger`,
-- which is append-only (no UPDATE/DELETE grant, ever). The quantity anyone
-- sees is always a SUM of that item's ledger rows, computed fresh — so the
-- current stock level can never silently drift from its own history, and
-- "who changed this and why" is always answerable from the ledger itself.

create table items (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  branch_id    uuid not null references branches(id),
  stock_room_id uuid not null references stock_rooms(id),
  display_code text unique not null,
  type         item_type not null,
  name         text not null,
  brand        text,
  category     text,
  reorder      numeric not null default 0,
  cost         numeric(14,2) not null default 0,
  sell         numeric(14,2) not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index items_company_idx on items (company_id);
create index items_branch_idx on items (branch_id);
create index items_stock_room_idx on items (stock_room_id);
create index items_type_idx on items (type);

-- branch_id and company_id are always derived from stock_room_id, never
-- trusted from the client — this is what stops an item from ever pointing
-- at a stock room in one branch/company while claiming another.
create function items_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
  v_branch  uuid;
begin
  select company_id, branch_id into v_company, v_branch from stock_rooms where id = new.stock_room_id;
  if v_company is null then
    raise exception 'Invalid stock_room_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot create an item in another company''s stock room';
  end if;
  new.company_id := v_company;
  new.branch_id := v_branch;
  return new;
end $$;
create trigger items_set_tenant before insert on items
  for each row execute function items_set_tenant();
create trigger items_set_tenant_on_move before update of stock_room_id on items
  for each row execute function items_set_tenant();

create function items_set_display_code() returns trigger language plpgsql as $$
begin
  if new.display_code is null then
    new.display_code := gen_display_code(
      case new.type when 'equipment' then 'EQ' else 'WP' end,
      case new.type when 'equipment' then 'seq_item_equipment'::regclass else 'seq_item_part'::regclass end,
      4);
  end if;
  return new;
end $$;
create trigger items_display_code before insert on items
  for each row execute function items_set_display_code();

create function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
create trigger items_updated_at before update on items
  for each row execute function set_updated_at();

-- Append-only stock ledger. unit_cost/currency_code are populated when a
-- movement has a real money cost attached (e.g. a purchase receipt in XOF)
-- so that history — not just the running total — remembers what currency a
-- stock-in actually happened in.
create table inventory_ledger (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(id),
  item_id       uuid not null references items(id),
  stock_room_id uuid not null references stock_rooms(id),
  qty_delta     numeric not null check (qty_delta <> 0),
  reason        text not null check (reason in
                  ('initial_stock', 'purchase_receipt', 'sale', 'adjustment',
                   'transfer_in', 'transfer_out', 'correction')),
  unit_cost     numeric(14,2),
  currency_code text references currencies(code),
  reference_type text,
  reference_id  uuid,
  note          text,
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now()
);
create index inventory_ledger_company_idx on inventory_ledger (company_id);
create index inventory_ledger_item_idx on inventory_ledger (item_id);
create index inventory_ledger_stock_room_idx on inventory_ledger (stock_room_id);

-- No one, not even an admin through the API, ever updates or deletes a
-- ledger row. A mistake is fixed by inserting a correcting entry, the same
-- way real accounting ledgers work.
revoke update, delete on inventory_ledger from authenticated;

-- security_invoker=true is required here: without it, this view would run
-- as its owner (the migration role) and silently bypass every RLS policy on
-- items/inventory_ledger for whoever queries it. With it, the view enforces
-- exactly the same row security as querying the base tables directly.
create view items_with_stock
with (security_invoker = true) as
select
  i.*,
  coalesce(l.qty_on_hand, 0) as qty
from items i
left join (
  select item_id, sum(qty_delta) as qty_on_hand
  from inventory_ledger
  group by item_id
) l on l.item_id = i.id;
