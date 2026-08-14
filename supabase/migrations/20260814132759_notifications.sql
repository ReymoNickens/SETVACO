-- Notifications — the bell-icon inbox (pushNotification() in index.html).
-- Was purely local React state, meaning it reset per browser/device: a
-- notification meant for a teammate ("New quotation created for X",
-- "Sent a message to Y") never actually reached them if they were signed
-- in on a different machine, and vanished entirely on refresh either way.
--
-- Unlike audit_log (deliberately RPC-only — see profiles_security.sql's
-- header comment — because it's a trust-sensitive record of what
-- happened), a notification is just an informational nudge with no
-- integrity requirement, so a direct client insert under RLS is fine here,
-- same posture as customers/meetings.
--
-- Known simplification carried over unchanged from the local-state
-- version: `read` is a single shared flag, not tracked per recipient. For
-- a company-wide notification (for_profile_id null) that means one
-- person opening the bell marks it read for everyone — acceptable for
-- this app's team sizes, but worth knowing if this ever needs to scale
-- past that.

create table notifications (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references companies(id),
  type           text not null,
  message        text not null,
  -- null = company-wide, everyone sees it (the common case — most call
  -- sites don't pass a target).
  for_profile_id uuid references profiles(id),
  read           boolean not null default false,
  created_at     timestamptz not null default now()
);
create index notifications_company_idx on notifications (company_id);

create function notifications_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_target_company uuid;
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  if new.for_profile_id is not null then
    select company_id into v_target_company from profiles where id = new.for_profile_id;
    if v_target_company is distinct from new.company_id then
      raise exception 'for_profile_id must belong to the same company';
    end if;
  end if;
  return new;
end $$;
create trigger notifications_set_tenant before insert on notifications
  for each row execute function notifications_set_tenant();

alter table notifications enable row level security;

-- Any active company member sees the company-wide ones plus whatever was
-- targeted at them specifically.
create policy notifications_select on notifications for select using (
  company_id = current_company_id() and (for_profile_id is null or for_profile_id = current_profile_id())
);
-- Every existing call site fires this with no role check (a quotation
-- being created, a leave request being filed, etc. are routine actions,
-- not privileged ones) — matches that.
create policy notifications_insert on notifications for insert with check (
  company_id = current_company_id()
);
-- Marking read is the only update path, and (per the header comment) it's
-- a blunt shared flag rather than per-recipient state — same visibility
-- rule as select.
create policy notifications_update on notifications for update
  using (company_id = current_company_id() and (for_profile_id is null or for_profile_id = current_profile_id()))
  with check (company_id = current_company_id() and (for_profile_id is null or for_profile_id = current_profile_id()));
