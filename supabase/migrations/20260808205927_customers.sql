-- Customers. country_code drives which currency/tax profile a transaction
-- with this customer defaults to once quotations/invoices are built in a
-- later phase (currency itself is stored per-transaction there, not here —
-- see items_ledger's inventory_ledger.currency_code for the same principle
-- applied to stock movements).

create table customers (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('C', 'seq_customer'::regclass, 2),
  name         text not null,
  tier         customer_tier not null default 'Standard',
  country_code text references countries(code),
  address      text,
  email        text,
  phone        text,
  contact_person text,
  credit_limit numeric(14,2) not null default 0,
  outstanding  numeric(14,2) not null default 0,
  tax_exempt   boolean not null default false,
  is_walk_in   boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index customers_company_idx on customers (company_id);

create function customers_set_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  return new;
end $$;
create trigger customers_set_company before insert on customers
  for each row execute function customers_set_company();
create trigger customers_updated_at before update on customers
  for each row execute function set_updated_at();

create table customer_contacts (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies(id),
  customer_id uuid not null references customers(id) on delete cascade,
  name        text not null,
  role        text,
  email       text,
  phone       text
);
create index customer_contacts_company_idx on customer_contacts (company_id);
create index customer_contacts_customer_idx on customer_contacts (customer_id);

create function customer_contacts_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from customers where id = new.customer_id;
  if v_company is null then
    raise exception 'Invalid customer_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot create a contact under another company''s customer';
  end if;
  new.company_id := v_company;
  return new;
end $$;
create trigger customer_contacts_set_tenant before insert on customer_contacts
  for each row execute function customer_contacts_set_tenant();
