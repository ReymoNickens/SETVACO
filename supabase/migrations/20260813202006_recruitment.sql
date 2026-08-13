-- Recruitment — job openings and their candidate pipeline. Admin/hr only,
-- end to end: unlike every other HR slice this session, there's no
-- self-service side here (a candidate isn't a system user with a profile
-- row), and interview notes are sensitive enough that regular staff
-- shouldn't see the pipeline at all. Deliberately stops at "hired" rather
-- than reaching into onboarding-checklist territory — that's real scope,
-- not this pass's job.

create sequence seq_job_opening;
create sequence seq_candidate;

create table job_openings (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('JO', 'seq_job_opening'::regclass, 3),
  title        text not null,
  department   text,
  status       text not null default 'Open' check (status in ('Open', 'Closed')),
  opened_date  date not null default current_date,
  closed_date  date,
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now()
);
create index job_openings_company_idx on job_openings (company_id);

create function job_openings_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  new.created_by := current_profile_id();
  return new;
end $$;
create trigger job_openings_set_tenant before insert on job_openings
  for each row execute function job_openings_set_tenant();

alter table job_openings enable row level security;
create policy job_openings_select on job_openings for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr']))
  or is_platform_admin()
);
create policy job_openings_write on job_openings for all
  using (company_id = current_company_id() and has_role(array['admin', 'hr']))
  with check (company_id = current_company_id() and has_role(array['admin', 'hr']));

-- ---------------------------------------------------------------------------
-- candidates — one row per applicant against an opening. `stage` is a
-- simple funnel, not a full ATS workflow (no scheduling, no scorecards) —
-- matches the scope of every other HR log built this session.
-- ---------------------------------------------------------------------------
create table candidates (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('CD', 'seq_candidate'::regclass, 4),
  opening_id   uuid not null references job_openings(id) on delete cascade,
  name         text not null,
  email        text,
  phone        text,
  stage        text not null default 'Applied' check (stage in ('Applied', 'Interviewing', 'Offered', 'Hired', 'Rejected')),
  notes        text,
  applied_date date not null default current_date,
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now()
);
create index candidates_company_idx on candidates (company_id);
create index candidates_opening_idx on candidates (opening_id);

-- company_id derives from the referenced opening, same shape as
-- employee_details_set_tenant deriving from its parent profile.
create function candidates_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from job_openings where id = new.opening_id;
  if v_company is null then
    raise exception 'Invalid opening_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot create a candidate for another company''s opening';
  end if;
  new.company_id := v_company;
  new.created_by := current_profile_id();
  return new;
end $$;
create trigger candidates_set_tenant before insert on candidates
  for each row execute function candidates_set_tenant();

alter table candidates enable row level security;
create policy candidates_select on candidates for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr']))
  or is_platform_admin()
);
create policy candidates_write on candidates for all
  using (company_id = current_company_id() and has_role(array['admin', 'hr']))
  with check (company_id = current_company_id() and has_role(array['admin', 'hr']));

insert into features (key, label) values ('recruitment', 'Recruitment');

insert into tenant_features (company_id, feature_key)
select id, 'recruitment' from companies where slug = 'setvaco';
