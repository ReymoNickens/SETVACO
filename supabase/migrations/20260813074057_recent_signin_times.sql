-- Powers the "ghost rows" on the sign-in register login screen (see
-- docs/design-system.md) — a couple of real recent sign-in timestamps,
-- shown before the user has authenticated, to make the register feel like
-- a real sheet other staff have already signed today.
--
-- This is a deliberate, narrow exception to "RLS blocks everything
-- pre-auth": the login screen has no session and (until subdomain-based
-- tenant routing exists, see docs/architecture.md) no way to know which
-- company it's even showing a login form for. p_company_slug is not
-- sensitive — it's a public identifier, the same shape as a subdomain
-- would be — and the function returns ONLY timestamps, never a name,
-- email, or id. SECURITY DEFINER is required here specifically because
-- anon has no grant on auth.users (or profiles) at all; this bypasses
-- that narrowly, for this one minimal, non-identifying shape, and nothing
-- else.
create function recent_signin_times(p_company_slug text, p_limit int default 2)
returns table(signed_in_at timestamptz)
language sql stable security definer set search_path = public as $$
  select u.last_sign_in_at
  from auth.users u
  join profiles p on p.id = u.id
  join companies c on c.id = p.company_id
  where c.slug = p_company_slug
    and p.status = 'Active'
    and u.last_sign_in_at is not null
  order by u.last_sign_in_at desc
  limit greatest(1, least(coalesce(p_limit, 2), 5));
$$;

revoke all on function recent_signin_times(text, int) from public;
grant execute on function recent_signin_times(text, int) to anon, authenticated;
