-- Extensions, global lookups, and the display-code generator used by every
-- tenant table below. None of this is company-scoped: role definitions,
-- item-type/status enums, and the WP-1001-style code sequences are the same
-- shape for every tenant, so they live once, not once per company.

create extension if not exists pgcrypto;

create table roles (
  key   text primary key,
  label text not null
);

insert into roles (key, label) values
  ('admin',       'Administrator'),
  ('sales',       'Sales Officer'),
  ('warehouse',   'Warehouse Clerk'),
  ('procurement', 'Procurement Officer'),
  ('service',     'Service Technician Lead'),
  ('finance',     'Finance / Audit');

create type item_type as enum ('part', 'equipment');
create type customer_tier as enum ('Standard', 'Silver', 'Gold');
create type user_status as enum ('Active', 'Suspended');

-- Per-prefix sequence + helper for human-readable codes (WP-1001, C-01, ...).
-- Atomic under concurrency — no client-side max(existing)+1 race.
create sequence seq_branch;
create sequence seq_stock_room;
create sequence seq_item_part;
create sequence seq_item_equipment;
create sequence seq_customer;
create sequence seq_user;

create function gen_display_code(prefix text, seq regclass, pad int default 4)
returns text language sql as $$
  select prefix || '-' || lpad(nextval(seq)::text, pad, '0')
$$;
