-- Approval settings, audit trail, notifications, and variance/audit log.

-- Singleton row (id is always `true`) — same pattern as today's single
-- `approvalSettings` object, just with a real PK.
create table approval_settings (
  id boolean primary key default true check (id),
  value_threshold numeric(14,2) not null default 20000,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id)
);
insert into approval_settings (id, value_threshold) values (true, 20000);

-- Flagged customers as FK rows, not a name array: renaming a customer no
-- longer silently un-flags them, which is a real bug in the current
-- approvalSettings.flaggedCustomers: string[] implementation.
create table approval_flagged_customers (
  customer_id uuid primary key references customers(id) on delete cascade
);

-- Append-only. INSERT is restricted to SECURITY DEFINER RPCs only (see RLS
-- migration) so every mutation's audit row is written atomically inside the
-- same transaction as the mutation itself — closing the gap where today's
-- logAction() is a separate, non-atomic client-side call.
create table audit_log (
  id uuid primary key default gen_random_uuid(),
  ts timestamptz not null default now(),
  actor_id uuid references profiles(id),
  actor_name text not null,       -- denormalized snapshot; survives actor deletion
  action text not null,
  module text not null,
  entity_type text,
  entity_id uuid
);
create index audit_log_ts_idx on audit_log (ts desc);
create index audit_log_entity_idx on audit_log (entity_type, entity_id);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  ts timestamptz not null default now(),
  type text not null,
  message text not null,
  recipient_id uuid references profiles(id),   -- null = broadcast to everyone (today's behavior)
  read boolean not null default false
);
create index notifications_recipient_idx on notifications (recipient_id, read);

create table variance_log (
  id uuid primary key default gen_random_uuid(),
  display_code text unique not null default gen_display_code('VAR', 'seq_variance'::regclass, 3),
  item_id uuid references items(id),
  branch_id uuid references branches(id),
  expected numeric not null,
  counted numeric not null,
  delta numeric not null,
  severity variance_severity not null,
  note text,
  created_at timestamptz not null default now()
);
create index variance_log_item_idx on variance_log (item_id);
