-- Advisor follow-up: pin search_path on plain functions (prevents
-- search_path hijacking), and lock down internal trigger/helper functions
-- so they can't be invoked directly as a PostgREST RPC endpoint by anyone —
-- they're implementation details, not part of the API surface. has_role /
-- current_company_id / current_profile_id keep EXECUTE for `authenticated`
-- deliberately: every RLS policy calls them, and revoking that would break
-- row security for every table, not just close an API endpoint.

alter function set_updated_at() set search_path = public;
alter function items_set_display_code() set search_path = public;
alter function gen_display_code(text, regclass, int) set search_path = public;

revoke execute on function branches_set_company() from public, anon, authenticated;
revoke execute on function stock_rooms_set_tenant() from public, anon, authenticated;
revoke execute on function items_set_tenant() from public, anon, authenticated;
revoke execute on function customers_set_company() from public, anon, authenticated;
revoke execute on function customer_contacts_set_tenant() from public, anon, authenticated;
revoke execute on function handle_new_auth_user() from public, anon, authenticated;
revoke execute on function set_updated_at() from public, anon, authenticated;
revoke execute on function items_set_display_code() from public, anon, authenticated;
revoke execute on function gen_display_code(text, regclass, int) from public, anon, authenticated;

revoke execute on function has_role(text[]) from public, anon;
revoke execute on function current_company_id() from public, anon;
revoke execute on function current_profile_id() from public, anon;

revoke execute on function adjust_stock(uuid, numeric, text, text, numeric, text, text, uuid) from public, anon;
