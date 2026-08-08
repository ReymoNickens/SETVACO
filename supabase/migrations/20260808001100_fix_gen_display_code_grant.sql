-- Correction to 20260808000900_security_hardening.sql: gen_display_code()
-- is invoked as a column DEFAULT (customers.display_code, branches.display_code,
-- stock_rooms.display_code) and from inside items_set_display_code's trigger
-- body — both execute under the CALLING role's privileges (neither is
-- SECURITY DEFINER), unlike the tenant-scoping trigger functions, which are
-- invoked by the trigger machinery itself and never need direct EXECUTE
-- rights. Revoking authenticated's EXECUTE on it broke every insert that
-- relies on it for a display code. anon still doesn't need it — only
-- authenticated, logged-in users create rows.
grant execute on function gen_display_code(text, regclass, int) to authenticated;
