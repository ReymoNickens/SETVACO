-- Core reference data: stock rooms, items, vendors, customers, customer
-- contacts, and profiles (the auth.users extension table). Plain CRUD tables —
-- access is governed entirely by RLS (see 20260807000500_rls_policies.sql),
-- no RPCs needed for these.

create function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- profiles: 1:1 extension of auth.users carrying role/status/display info.
-- Auto-created by a trigger on auth.users insert (see bottom of this file);
-- role/username are then set by the admin-manage-user Edge Function, which is
-- the only path that may create a new login (it alone holds the service-role
-- key needed to call the Auth Admin API).
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_code text unique not null default gen_display_code('U', 'seq_user'::regclass, 2),
  name text not null,
  email text not null,
  username text unique not null,
  role text not null references roles(key),
  status user_status not null default 'Active',
  created_at timestamptz not null default now()
);

create function handle_new_auth_user() returns trigger language plpgsql security definer as $$
begin
  insert into profiles (id, name, email, username, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', new.email),
    new.email,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'role', 'sales')
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();

create table stock_rooms (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null default gen_display_code('SR', 'seq_stock_room'::regclass, 2),
  name text not null,
  branch_id uuid not null references branches(id),
  created_at timestamptz not null default now()
);

create table items (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null,
  type item_type not null,
  name text not null,
  brand text,
  category text,
  branch_id uuid not null references branches(id),
  stock_room_id uuid not null references stock_rooms(id),
  qty numeric not null default 0 check (qty >= 0),
  reorder numeric not null default 0,
  cost numeric(14,2) not null default 0,
  sell numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

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
create trigger items_updated_at before update on items
  for each row execute function set_updated_at();
create index items_branch_idx on items (branch_id);
create index items_stock_room_idx on items (stock_room_id);
create index items_type_idx on items (type);

create table vendors (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null default gen_display_code('V', 'seq_vendor'::regclass, 2),
  code text unique,                 -- vendor's own industry-standard code, used by match_po_code
  name text not null,
  contact text,
  email text,
  phone text,
  alt_contact text,
  categories text,
  tax_exempt boolean not null default false,
  certificate_path text,            -- Supabase Storage object key, bucket 'vendor-certificates'
  created_at timestamptz not null default now()
);
create index vendors_code_upper_idx on vendors (upper(code));

create table customers (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null default gen_display_code('C', 'seq_customer'::regclass, 2),
  name text not null,
  tier customer_tier not null default 'Standard',
  country text,
  address text,
  email text,
  phone text,
  contact_person text,
  contact_address text,
  company_details text,
  po_code text unique,              -- customer's own industry-standard code
  credit_limit numeric(14,2) not null default 0,
  outstanding numeric(14,2) not null default 0,
  tax_exempt boolean not null default false,
  is_walk_in boolean not null default false,
  created_at timestamptz not null default now()
);
create index customers_po_code_upper_idx on customers (upper(po_code));

create table customer_contacts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete cascade,
  name text not null,
  role text,
  email text,
  phone text
);
create index customer_contacts_customer_idx on customer_contacts (customer_id);
