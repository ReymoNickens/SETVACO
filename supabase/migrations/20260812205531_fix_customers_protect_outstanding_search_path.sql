-- Missed in the previous migration: every other function in the schema
-- pins search_path explicitly; this one didn't, which the security advisor
-- correctly flagged (function_search_path_mutable) — an unqualified
-- reference inside it could be hijacked by a malicious search_path. This
-- function only touches NEW/OLD record fields (no unqualified table/
-- function names), so it wasn't exploitable in practice, but pin it for
-- consistency with the established convention anyway.
create or replace function customers_protect_outstanding() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.outstanding is distinct from old.outstanding and current_user = 'authenticated' then
    raise exception 'outstanding cannot be set directly — it is only changed by convert_quotation_to_invoice / mark_invoice_paid';
  end if;
  return new;
end $$;
