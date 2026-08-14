-- Reports — the "Report Builder" tab. The report data itself (quotations,
-- invoices, service jobs, purchase orders, items, customers) has been real
-- since those modules were migrated; only the saved report *definitions*
-- (source/groupBy/metric presets a user names and reuses) were still local
-- React state, meaning a saved report never survived a browser switch or a
-- refresh on another device.
--
-- Root table like customers/meetings — direct client insert by whoever's
-- signed in, no integrity requirement (unlike audit_log), same posture.
-- Company-wide visibility: a saved report is a reusable preset, useful to
-- the whole team the same way a price book is, not a private draft.

create table saved_reports (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies(id),
  name        text not null,
  source      text not null,
  group_by    text not null,
  metric      text not null,
  created_by  uuid not null references profiles(id),
  created_at  timestamptz not null default now()
);
create index saved_reports_company_idx on saved_reports (company_id);

create function saved_reports_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  new.created_by := coalesce(current_profile_id(), new.created_by);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  return new;
end $$;
create trigger saved_reports_set_tenant before insert on saved_reports
  for each row execute function saved_reports_set_tenant();

alter table saved_reports enable row level security;

create policy saved_reports_select on saved_reports for select using (
  company_id = current_company_id()
);
create policy saved_reports_insert on saved_reports for insert with check (
  company_id = current_company_id()
);
-- Deleting a saved report is limited to whoever created it, or an admin —
-- same "you can't touch someone else's record, admin can for support"
-- shape used elsewhere (meetings, service contracts).
create policy saved_reports_delete on saved_reports for delete using (
  company_id = current_company_id() and (created_by = current_profile_id() or has_role(array['admin']))
);
