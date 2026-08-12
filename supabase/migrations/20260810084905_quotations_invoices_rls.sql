-- SELECT via plain RLS (company + role scoped, same as every other table).
-- INSERT/UPDATE/DELETE revoked from authenticated entirely: every write to
-- these tables has a side effect (stock deduction, customer.outstanding,
-- a status transition) that has to happen atomically with the write, which
-- RLS alone can't express. All writes go through the RPCs in the next
-- migration instead.

alter table quotations enable row level security;
alter table quotation_lines enable row level security;
alter table invoices enable row level security;
alter table invoice_lines enable row level security;

create policy quotations_select on quotations for select using (
  company_id = current_company_id() and has_role(array['admin','sales','warehouse','finance'])
);
revoke insert, update, delete on quotations from authenticated;

create policy quotation_lines_select on quotation_lines for select using (
  company_id = current_company_id() and has_role(array['admin','sales','warehouse','finance'])
);
revoke insert, update, delete on quotation_lines from authenticated;

create policy invoices_select on invoices for select using (
  company_id = current_company_id() and has_role(array['admin','sales','warehouse','finance'])
);
revoke insert, update, delete on invoices from authenticated;

create policy invoice_lines_select on invoice_lines for select using (
  company_id = current_company_id() and has_role(array['admin','sales','warehouse','finance'])
);
revoke insert, update, delete on invoice_lines from authenticated;
