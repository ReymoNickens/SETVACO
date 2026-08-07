-- Transactional documents: quotations, invoices, purchase orders, service
-- jobs, and their line items / notes. Every table here that carries a status
-- workflow with a side effect (stock deduction/addition, approval gating) has
-- INSERT/UPDATE revoked from `authenticated` in the RLS migration — writes to
-- those go exclusively through the RPCs in 20260807000600_rpc_functions.sql.

create table quotations (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null default gen_display_code('QT', 'seq_quotation'::regclass, 4),
  type item_type not null,
  customer_id uuid not null references customers(id),
  country text,
  notes text,
  subtotal numeric(14,2) not null default 0,
  apply_tax boolean not null default false,
  tax_rate numeric(5,2) not null default 0,
  tax_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  lead_time_days integer,
  eta date,
  prepared_by_id uuid references profiles(id),
  status quote_status not null default 'Quoted',
  quote_date date not null default current_date,
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger quotations_updated_at before update on quotations
  for each row execute function set_updated_at();
create index quotations_customer_idx on quotations (customer_id);
create index quotations_type_idx on quotations (type);
create index quotations_status_idx on quotations (status);

create table quotation_lines (
  id uuid primary key default gen_random_uuid(),
  quotation_id uuid not null references quotations(id) on delete cascade,
  item_id uuid references items(id),     -- null when new_part = true (not yet in inventory)
  description text not null,
  qty numeric not null check (qty > 0),
  unit_price numeric(14,2) not null,
  new_part boolean not null default false,
  line_no integer not null
);
create index quotation_lines_quotation_idx on quotation_lines (quotation_id);

create table invoices (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null default gen_display_code('INV', 'seq_invoice'::regclass, 4),
  quotation_id uuid not null references quotations(id),
  type item_type not null,
  customer_id uuid not null references customers(id),
  subtotal numeric(14,2) not null default 0,
  apply_tax boolean not null default false,
  tax_rate numeric(5,2) not null default 0,
  tax_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  status invoice_status not null default 'Issued',
  invoice_date date not null default current_date,
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);
create index invoices_customer_idx on invoices (customer_id);
create index invoices_quotation_idx on invoices (quotation_id);

create table invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references invoices(id) on delete cascade,
  item_id uuid references items(id),
  description text not null,
  qty numeric not null check (qty > 0),
  unit_price numeric(14,2) not null,
  new_part boolean not null default false,
  line_no integer not null
);
create index invoice_lines_invoice_idx on invoice_lines (invoice_id);

create table purchase_orders (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null default gen_display_code('PO', 'seq_po'::regclass, 4),
  vendor_id uuid references vendors(id),        -- nullable: uploaded/unmatched POs may lack one
  vendor_name_raw text,                          -- snapshot name for uploaded POs with no vendor match
  status po_status not null default 'Ordered',
  po_date date not null default current_date,
  expected date,
  source po_source not null default 'manual',
  customer_id uuid references customers(id),     -- set only when source = 'matched'
  external_po_number text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index purchase_orders_vendor_idx on purchase_orders (vendor_id);
create index purchase_orders_customer_idx on purchase_orders (customer_id);
create index purchase_orders_status_idx on purchase_orders (status);

create table purchase_order_lines (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references purchase_orders(id) on delete cascade,
  item_id uuid references items(id),
  item_name text not null,     -- kept as a point-in-time snapshot, same as today's shape
  qty numeric not null check (qty > 0)
);
create index purchase_order_lines_po_idx on purchase_order_lines (purchase_order_id);

create table service_jobs (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null default gen_display_code('SJ', 'seq_job'::regclass, 3),
  customer_id uuid not null references customers(id),
  job_type text,
  country text,
  description text,
  technician_id uuid references profiles(id),
  technician_name text,          -- fallback label for non-staff/contract technicians
  item_id uuid references items(id),
  item_name text,
  qty numeric,
  eta date,
  prepared_by_id uuid references profiles(id),
  status job_status not null default 'Open',
  job_date date not null default current_date,
  created_at timestamptz not null default now()
);
create index service_jobs_customer_idx on service_jobs (customer_id);
create index service_jobs_status_idx on service_jobs (status);

-- Shared feedback/manager-comment thread for quotations and service jobs.
-- Kept as one child table with a `kind` discriminant (not JSONB on the parent
-- row) specifically so RLS can grant "manager"-kind write access more
-- narrowly than "feedback"-kind write access — see 20260807000500_rls_policies.sql.
create table notes (
  id uuid primary key default gen_random_uuid(),
  quotation_id uuid references quotations(id) on delete cascade,
  service_job_id uuid references service_jobs(id) on delete cascade,
  kind note_kind not null,
  body text not null,
  author_id uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  constraint notes_exactly_one_parent check (
    (quotation_id is not null)::int + (service_job_id is not null)::int = 1
  )
);
create index notes_quotation_idx on notes (quotation_id, kind, created_at);
create index notes_job_idx on notes (service_job_id, kind, created_at);
