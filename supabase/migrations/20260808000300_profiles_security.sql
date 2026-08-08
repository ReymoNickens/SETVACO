-- profiles: 1:1 extension of auth.users carrying company/role/status. This is
-- the load-bearing table for both multi-tenancy and authorization:
--   - company_id says which tenant this login belongs to.
--   - role + status feed has_role(), used by every RLS policy and RPC.
--
-- Password storage/hashing is entirely Supabase Auth's job (bcrypt, in
-- auth.users.encrypted_password) — nothing custom is built or needed here.

create table profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('U', 'seq_user'::regclass, 2),
  name         text not null,
  email        text not null,
  username     text unique not null,
  role         text not null references roles(key),
  status       user_status not null default 'Active',
  locale       text not null default 'en' check (locale in ('en', 'fr')),
  created_at   timestamptz not null default now()
);
create index profiles_company_idx on profiles (company_id);

-- Security-definer primitives. SECURITY DEFINER is required, not optional:
-- profiles has its own RLS policy that itself calls has_role()/current_company_id().
-- Running these as SECURITY INVOKER would re-trigger that policy from inside
-- itself — infinite recursion the first time any policy anywhere calls them.
-- Running as the (trusted) function owner bypasses RLS for just this one
-- lookup and breaks the cycle.
create function has_role(allowed text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and status = 'Active' and role = any(allowed)
  )
$$;

create function current_company_id() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from profiles where id = auth.uid() and status = 'Active'
$$;

create function current_profile_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from profiles where id = auth.uid() and status = 'Active'
$$;

-- Auto-creates the profile row the instant a Supabase Auth user is created.
-- Deliberately reads company_id from raw_app_meta_data, NOT raw_user_meta_data:
-- app_metadata can only ever be set by a service-role caller (the
-- admin-manage-user Edge Function), never by the person signing up. Because
-- company_id is NOT NULL with no default, a signup that doesn't go through
-- that Edge Function has no company_id to write and this trigger raises an
-- exception, rolling back the whole auth.users insert — so self-serve signup
-- can't produce a working account even if the "Allow signups" dashboard
-- toggle is left on. role is likewise never taken from client-suppliable
-- metadata: every new profile starts at the least-privileged 'sales' role,
-- and only an already-verified admin (via the Edge Function) can escalate it.
create function handle_new_auth_user() returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_company_id uuid;
begin
  v_company_id := (new.raw_app_meta_data->>'company_id')::uuid;
  if v_company_id is null then
    raise exception 'Signup rejected: account must be provisioned by an administrator';
  end if;
  insert into profiles (id, company_id, name, email, username, role)
  values (
    new.id,
    v_company_id,
    coalesce(new.raw_user_meta_data->>'name', new.email),
    new.email,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    'sales'
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();

-- Minimal audit trail. Written only from inside SECURITY DEFINER RPCs (see
-- rpc_functions.sql) — there is no direct client insert path.
create table audit_log (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies(id),
  actor_id    uuid references profiles(id),
  action      text not null,
  module      text,
  entity_type text,
  entity_id   uuid,
  created_at  timestamptz not null default now()
);
create index audit_log_company_idx on audit_log (company_id);
