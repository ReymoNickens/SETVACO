-- Quotations and invoices. Currency and tax are never trusted from the
-- client — create_quotation (next migration) derives both authoritatively
-- from the customer's country_code via countries/tax_profiles, the same
-- principle already applied to inventory_ledger's currency_code.
--
-- Only two statuses matter for the core loop this phase builds:
-- quotations: Quoted -> Sent -> Invoiced (Rejected is a manual dead end).
-- invoices: Issued -> Paid.
-- The two-stage credit-risk approval workflow from the original prototype
-- needs approval_settings/credit-limit plumbing that doesn't exist yet —
-- deferred, not built speculatively.

create type quote_status as enum ('Quoted', 'Sent', 'Rejected', 'Invoiced');
create type invoice_status as enum ('Issued', 'Paid');

create sequence seq_quotation;
create sequence seq_invoice;

create table quotations (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references companies(id),
  display_code   text unique not null default gen_display_code('QT', 'seq_quotation'::regclass, 4),
  type           item_type not null,
  customer_id    uuid not null references customers(id),
  currency_code  text not null references currencies(code),
  subtotal       numeric(14,2) not null default 0,
  tax_rate       numeric(5,2) not null default 0,
  tax_amount     numeric(14,2) not null default 0,
  total          numeric(14,2) not null default 0,
  status         quote_status not null default 'Quoted',
  lead_time_days int,
  eta            date,
  prepared_by    uuid references profiles(id),
  created_by     uuid references profiles(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index quotations_company_idx on quotations (company_id);
create index quotations_customer_idx on quotations (customer_id);

create table quotation_lines (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(id),
  quotation_id  uuid not null references quotations(id) on delete cascade,
  item_id       uuid references items(id),
  description   text not null,
  qty           numeric not null check (qty > 0),
  unit_price    numeric(14,2) not null default 0,
  line_no       int not null default 1
);
create index quotation_lines_quotation_idx on quotation_lines (quotation_id);

create table invoices (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references companies(id),
  display_code   text unique not null default gen_display_code('INV', 'seq_invoice'::regclass, 4),
  quotation_id   uuid references quotations(id),
  type           item_type not null,
  customer_id    uuid not null references customers(id),
  currency_code  text not null references currencies(code),
  subtotal       numeric(14,2) not null default 0,
  tax_rate       numeric(5,2) not null default 0,
  tax_amount     numeric(14,2) not null default 0,
  total          numeric(14,2) not null default 0,
  status         invoice_status not null default 'Issued',
  created_by     uuid references profiles(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index invoices_company_idx on invoices (company_id);
create index invoices_customer_idx on invoices (customer_id);

create table invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  invoice_id   uuid not null references invoices(id) on delete cascade,
  item_id      uuid references items(id),
  description  text not null,
  qty          numeric not null check (qty > 0),
  unit_price   numeric(14,2) not null default 0,
  line_no      int not null default 1
);
create index invoice_lines_invoice_idx on invoice_lines (invoice_id);

create trigger quotations_updated_at before update on quotations
  for each row execute function set_updated_at();
create trigger invoices_updated_at before update on invoices
  for each row execute function set_updated_at();
