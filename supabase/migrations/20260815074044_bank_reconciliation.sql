-- Bank Reconciliation — a new feature, not a migration; no schema or nav
-- item existed for it. Scoped as a simple checklist per the brief: finance
-- enters bank statement lines by hand (there's no live bank feed to pull
-- from) and marks each one Reconciled once they've verified it against
-- their own records — no cross-table matching against expenses/invoices/
-- vendor bills, which would be a much bigger, more rigorous feature.
--
-- No RPC needed, unlike Accounts Payable/Stock Counts: there's no derived
-- amount to compute and no other table's state to touch, so a direct
-- client insert/update under RLS (same posture as notifications/petty
-- cash) is enough. A trigger still owns who/when a line was reconciled —
-- never trusted from the client — and, since it's SECURITY DEFINER
-- already, logs the reconciliation to the real audit_log too.

create sequence seq_bank_transaction;

create table bank_transactions (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references companies(id),
  display_code   text unique not null default gen_display_code('BT', 'seq_bank_transaction'::regclass, 3),
  bank_date      date not null,
  description    text not null,
  -- Signed: positive = money in, negative = money out. Matches how a bank
  -- statement's own running balance works, avoids a separate direction
  -- column that could disagree with the sign.
  amount         numeric(14,2) not null,
  note           text,
  status         text not null default 'Unreconciled' check (status in ('Unreconciled', 'Reconciled')),
  created_by     uuid references profiles(id),
  created_at     timestamptz not null default now(),
  reconciled_by  uuid references profiles(id),
  reconciled_at  timestamptz
);
create index bank_transactions_company_idx on bank_transactions (company_id);

create function bank_transactions_set_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := coalesce(current_company_id(), new.company_id);
    if new.company_id is null then
      raise exception 'company_id is required';
    end if;
    new.created_by := coalesce(current_profile_id(), new.created_by);
    -- Reconciliation state always starts clean, regardless of what a
    -- client might send.
    new.status := 'Unreconciled';
    new.reconciled_by := null;
    new.reconciled_at := null;
  elsif tg_op = 'UPDATE' then
    new.company_id := old.company_id;
    if new.status = 'Reconciled' and old.status <> 'Reconciled' then
      new.reconciled_by := current_profile_id();
      new.reconciled_at := now();
      insert into audit_log (company_id, actor_id, action, module, entity_type, entity_id)
      values (new.company_id, current_profile_id(), format('Reconciled bank transaction: %s', new.description), 'Bank Reconciliation', 'bank_transaction', new.id);
    elsif new.status = 'Unreconciled' and old.status = 'Reconciled' then
      new.reconciled_by := null;
      new.reconciled_at := null;
    end if;
  end if;
  return new;
end $$;
create trigger bank_transactions_set_fields before insert or update on bank_transactions
  for each row execute function bank_transactions_set_fields();

alter table bank_transactions enable row level security;
-- Finance-only, both read and write — nobody else has a reason to see a
-- bank statement line, unlike vendor_bills/purchase_orders where
-- procurement also needs visibility.
create policy bank_transactions_write on bank_transactions for all
  using (company_id = current_company_id() and has_role(array['admin', 'finance']))
  with check (company_id = current_company_id() and has_role(array['admin', 'finance']));

insert into features (key, label) values ('bank_reconciliation', 'Bank Reconciliation');
insert into tenant_features (company_id, feature_key)
select id, 'bank_reconciliation' from companies where slug = 'setvaco';
