-- Employee Documents — the last piece of the HR office brief. Unlike every
-- other HR/Finance slice this session, this one needs real file storage
-- (contracts, ID scans), not just another Postgres table — the first use
-- of Supabase Storage anywhere in this schema. Kept as narrow as the rest:
-- upload is admin/hr only (verifying and filing the physical document is
-- an HR step, same posture as certifications), no update/delete in this
-- pass — a correction is a new upload, not an edit to history.
--
-- Storage layout: private bucket `employee-documents`, objects keyed
-- `{company_id}/{employee_id}/{uuid}-{filename}`. The company_id segment
-- lets storage policies scope access the same way every table policy
-- already does, without needing a join back into Postgres per object.

insert into storage.buckets (id, name, public)
values ('employee-documents', 'employee-documents', false)
on conflict (id) do nothing;

create policy employee_documents_storage_select on storage.objects for select using (
  bucket_id = 'employee-documents'
  and (
    ((storage.foldername(name))[1] = current_company_id()::text and has_role(array['admin', 'hr']))
    or (storage.foldername(name))[2] = current_profile_id()::text
  )
);
create policy employee_documents_storage_insert on storage.objects for insert with check (
  bucket_id = 'employee-documents'
  and (storage.foldername(name))[1] = current_company_id()::text
  and has_role(array['admin', 'hr'])
);

create sequence seq_employee_document;

create table employee_documents (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(id),
  display_code  text unique not null default gen_display_code('DC', 'seq_employee_document'::regclass, 4),
  employee_id   uuid not null references profiles(id),
  doc_type      text not null check (doc_type in ('Contract', 'ID', 'Certificate', 'Payslip', 'Other')),
  file_name     text not null,
  storage_path  text not null,
  file_size     bigint,
  uploaded_by   uuid not null references profiles(id),
  created_at    timestamptz not null default now()
);
create index employee_documents_company_idx on employee_documents (company_id);
create index employee_documents_employee_idx on employee_documents (employee_id);

-- Same tenant-derivation shape as certifications_set_tenant.
create function employee_documents_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid;
begin
  select company_id into v_company from profiles where id = new.employee_id;
  if v_company is null then
    raise exception 'Invalid employee_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_company then
    raise exception 'Cannot file a document for another company''s employee';
  end if;
  new.company_id := v_company;
  new.uploaded_by := current_profile_id();
  return new;
end $$;
create trigger employee_documents_set_tenant before insert on employee_documents
  for each row execute function employee_documents_set_tenant();

alter table employee_documents enable row level security;
create policy employee_documents_select on employee_documents for select using (
  (company_id = current_company_id() and has_role(array['admin', 'hr']))
  or employee_id = current_profile_id()
  or is_platform_admin()
);
create policy employee_documents_insert on employee_documents for insert with check (
  company_id = current_company_id() and has_role(array['admin', 'hr'])
);

insert into features (key, label) values ('employee_documents', 'Employee Documents');

insert into tenant_features (company_id, feature_key)
select id, 'employee_documents' from companies where slug = 'setvaco';
