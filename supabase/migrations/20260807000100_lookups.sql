-- Lookups: roles, branches, nav_permissions, shared enums, and the display-code
-- generator used by every table below (replaces the client-side uid() max+1 race).

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

create table branches (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  created_at timestamptz not null default now()
);

insert into branches (name) values
  ('Accra HQ'), ('Kumasi Branch'), ('Tema Warehouse');

-- One row per (nav item, role) that may see it — the server-side mirror of the
-- NAV array's `roles` field in index.html, and the single source of truth the
-- frontend reads instead of hardcoding the matrix a second time.
create table nav_permissions (
  nav_key text not null,
  role    text not null references roles(key),
  primary key (nav_key, role)
);

insert into nav_permissions (nav_key, role) values
  ('dashboard', 'admin'), ('dashboard', 'sales'), ('dashboard', 'warehouse'), ('dashboard', 'procurement'), ('dashboard', 'service'), ('dashboard', 'finance'),
  ('partsInventory', 'admin'), ('partsInventory', 'sales'), ('partsInventory', 'warehouse'), ('partsInventory', 'procurement'), ('partsInventory', 'service'), ('partsInventory', 'finance'),
  ('equipmentInventory', 'admin'), ('equipmentInventory', 'sales'), ('equipmentInventory', 'warehouse'), ('equipmentInventory', 'procurement'), ('equipmentInventory', 'finance'),
  ('salesoverview', 'admin'), ('salesoverview', 'sales'), ('salesoverview', 'finance'),
  ('partsales', 'admin'), ('partsales', 'sales'), ('partsales', 'warehouse'), ('partsales', 'finance'),
  ('equipmentsales', 'admin'), ('equipmentsales', 'sales'), ('equipmentsales', 'finance'),
  ('servicejobs', 'admin'), ('servicejobs', 'service'), ('servicejobs', 'warehouse'),
  ('purchasing', 'admin'), ('purchasing', 'procurement'), ('purchasing', 'finance'),
  ('customers', 'admin'), ('customers', 'sales'), ('customers', 'finance'),
  ('variance', 'admin'), ('variance', 'finance'),
  ('access', 'admin');

-- Fixed, rarely-changing status sets — enums are appropriate here (unlike `role`,
-- which is a lookup table; see docs/architecture.md for the reasoning).
create type item_type as enum ('part', 'equipment');
create type customer_tier as enum ('Standard', 'Silver', 'Gold');
create type quote_status as enum ('Quoted', 'Sent', 'Pending Approval', 'Rejected', 'Invoiced');
create type invoice_status as enum ('Issued', 'Paid');
create type po_status as enum ('Ordered', 'In Transit', 'Received');
create type po_source as enum ('manual', 'uploaded', 'matched');
create type job_status as enum ('Open', 'In Progress', 'Completed');
create type user_status as enum ('Active', 'Suspended');
create type variance_severity as enum ('Low', 'Medium', 'High');
create type note_kind as enum ('feedback', 'manager');

-- Per-prefix sequence + helper used by a BEFORE INSERT trigger on every table
-- that needs a human-readable code (WP-1001, QT-9001, ...). Atomic under
-- concurrency, unlike the current client-side `uid()` max(existing)+1 scheme.
create sequence seq_item_part;
create sequence seq_item_equipment;
create sequence seq_stock_room;
create sequence seq_vendor;
create sequence seq_customer;
create sequence seq_quotation;
create sequence seq_invoice;
create sequence seq_po;
create sequence seq_job;
create sequence seq_user;
create sequence seq_variance;

create function gen_display_code(prefix text, seq regclass, pad int default 4)
returns text language sql as $$
  select prefix || '-' || lpad(nextval(seq)::text, pad, '0')
$$;
