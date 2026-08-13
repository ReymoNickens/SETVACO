-- Meeting Room, Phase 1 (voice/video calling). The room itself is hosted
-- by Daily.co (see create-meeting-room Edge Function) — this table just
-- tracks who started what meeting and when, same shape as every other
-- module: company_id derived server-side, RLS on every policy.
--
-- Deliberately not built here: recording/transcript storage (Phase 2/3 —
-- see docs/architecture.md and the brief's phasing). Adding those columns
-- now, before the recording/consent/retention-policy work is designed,
-- would be exactly the half-built-ahead-of-need pattern this codebase
-- avoids elsewhere.

create sequence seq_meeting;

create table meetings (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references companies(id),
  display_code    text unique not null default gen_display_code('MR', 'seq_meeting'::regclass, 3),
  title           text not null,
  daily_room_url  text,
  daily_room_name text,
  status          text not null default 'Active' check (status in ('Active', 'Ended')),
  created_by      uuid not null references profiles(id),
  started_at      timestamptz not null default now(),
  ended_at        timestamptz
);
create index meetings_company_idx on meetings (company_id);

-- Root table like `customers`/`expenses` — direct client insert by
-- whoever's signed in, so company_id comes straight from their own
-- session.
create function meetings_set_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  return new;
end $$;
create trigger meetings_set_company before insert on meetings
  for each row execute function meetings_set_company();

alter table meetings enable row level security;
-- Meetings aren't role-gated the way approvals are — matches the
-- "virtual office" framing where any staff member can call a meeting.
create policy meetings_select on meetings for select using (
  company_id = current_company_id() or is_platform_admin()
);
create policy meetings_insert on meetings for insert with check (
  company_id = current_company_id() and created_by = current_profile_id()
);
-- Ending a meeting (or any other update) is limited to whoever started it,
-- or an admin — same "you can't touch someone else's record, admin can
-- for support" shape used elsewhere.
create policy meetings_update on meetings for update
  using (company_id = current_company_id() and (created_by = current_profile_id() or has_role(array['admin'])))
  with check (company_id = current_company_id() and (created_by = current_profile_id() or has_role(array['admin'])));

-- Meeting Room is a platform-wide nav room (see docs/design-system.md's
-- room/station structure) but not every tenant necessarily wants it —
-- gate it behind tenant_features like every other module, and turn it on
-- for SETVACO now that it's real.
insert into features (key, label) values ('meetings', 'Meeting Room');
insert into tenant_features (company_id, feature_key)
select id, 'meetings' from companies where slug = 'setvaco';
