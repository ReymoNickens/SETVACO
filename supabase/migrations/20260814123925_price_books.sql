-- Price Books — the last of the four modules still local-only in
-- index.html (see docs/architecture.md's "What's built vs. not yet built").
-- Already live-referenced from real data: a customer record carries a
-- price_book_id, and quoting (create_quotation) is meant to price each line
-- off whichever book the customer is assigned to. Leaving the books/entries
-- themselves as client-side state meant that assignment silently reset on
-- every refresh — a real customer could show up with the wrong price at
-- quote time with no record of why.
--
-- Same "root config table + entries" shape as budgets/expense_categories.
-- Every company always has exactly one Standard book (falls back to each
-- item's own default sell price, holds no entries of its own) plus as many
-- custom books as they create.

create sequence seq_price_book;
create sequence seq_price_book_entry;

create table price_books (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id),
  display_code text unique not null default gen_display_code('PB', 'seq_price_book'::regclass, 4),
  name         text not null,
  is_standard  boolean not null default false,
  created_at   timestamptz not null default now()
);
create index price_books_company_idx on price_books (company_id);
-- Exactly one Standard book per company — customers.price_book_id = null
-- falls back to it.
create unique index price_books_one_standard on price_books (company_id) where is_standard;

create function price_books_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce(current_company_id(), new.company_id);
  if new.company_id is null then
    raise exception 'company_id is required';
  end if;
  return new;
end $$;
create trigger price_books_set_tenant before insert on price_books
  for each row execute function price_books_set_tenant();

-- The Standard book is a fixed anchor, not an editable/removable record —
-- renaming or deleting it would silently break every customer that has no
-- price_book_id override. Enforced as a trigger rather than a second RLS
-- policy: multiple permissive "for all" policies on the same command are
-- OR'd together in Postgres, which would only ever loosen this, not add a
-- second condition that must also hold.
create function price_books_protect_standard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.is_standard then
    raise exception 'The Standard price book cannot be renamed or removed';
  end if;
  return old;
end $$;
create trigger price_books_protect_standard before update or delete on price_books
  for each row execute function price_books_protect_standard();

create table price_book_entries (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(id),
  display_code  text unique not null default gen_display_code('PBE', 'seq_price_book_entry'::regclass, 4),
  price_book_id uuid not null references price_books(id) on delete cascade,
  item_id       uuid not null references items(id),
  price         numeric(14,2) not null check (price >= 0),
  created_at    timestamptz not null default now(),
  unique (price_book_id, item_id)
);
create index price_book_entries_company_idx on price_book_entries (company_id);
create index price_book_entries_book_idx on price_book_entries (price_book_id);

-- company_id is derived from the parent book rather than the caller's own
-- session directly, and item_id is cross-checked against that same
-- company — same "validate every foreign id belongs to the caller's own
-- tenant" pattern used by service_jobs/service_job_notes.
create function price_book_entries_set_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_book_company uuid;
  v_item_company uuid;
begin
  select company_id into v_book_company from price_books where id = new.price_book_id;
  if v_book_company is null then
    raise exception 'Invalid price_book_id';
  end if;
  if current_company_id() is not null and current_company_id() <> v_book_company then
    raise exception 'Cannot add an entry under another company''s price book';
  end if;
  select company_id into v_item_company from items where id = new.item_id;
  if v_item_company is distinct from v_book_company then
    raise exception 'item_id must belong to the same company as the price book';
  end if;
  new.company_id := v_book_company;
  return new;
end $$;
create trigger price_book_entries_set_tenant before insert on price_book_entries
  for each row execute function price_book_entries_set_tenant();

alter table price_books enable row level security;
alter table price_book_entries enable row level security;

-- Sales needs to read prices while quoting, Finance needs visibility for
-- the same reason it can see customers/vendors — same role set as
-- customers_select. Writing (creating books, adding overrides) is an
-- admin-only config action, same posture as tenant_features.
create policy price_books_select on price_books for select using (
  company_id = current_company_id() and has_role(array['admin','sales','finance'])
);
create policy price_books_write on price_books for all
  using (company_id = current_company_id() and has_role(array['admin']))
  with check (company_id = current_company_id() and has_role(array['admin']));

create policy price_book_entries_select on price_book_entries for select using (
  company_id = current_company_id() and has_role(array['admin','sales','finance'])
);
create policy price_book_entries_write on price_book_entries for all
  using (company_id = current_company_id() and has_role(array['admin']))
  with check (company_id = current_company_id() and has_role(array['admin']));

-- null means "use the Standard book".
alter table customers add column price_book_id uuid references price_books(id);

-- Runs after customers_set_company (alphabetically later trigger name on
-- the same BEFORE INSERT event, and explicitly also on UPDATE OF
-- price_book_id) so new.company_id is already populated by the time this
-- reads it — blocks assigning a customer to another company's price book,
-- same shape as customer_contacts_set_tenant's cross-tenant check.
create function customers_validate_price_book() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_book_company uuid;
begin
  if new.price_book_id is null then
    return new;
  end if;
  select company_id into v_book_company from price_books where id = new.price_book_id;
  if v_book_company is distinct from new.company_id then
    raise exception 'price_book_id must belong to the same company';
  end if;
  return new;
end $$;
create trigger customers_validate_price_book before insert or update of price_book_id on customers
  for each row execute function customers_validate_price_book();

insert into features (key, label) values ('price_books', 'Price Books');
insert into tenant_features (company_id, feature_key)
select id, 'price_books' from companies where slug = 'setvaco';

-- Every existing company needs a Standard book so a customer with no
-- explicit price_book_id (i.e. every customer today) resolves to
-- something — seeded here rather than left to be created through the UI,
-- which the "one standard per company" unique index would then race
-- against on first use.
insert into price_books (company_id, name, is_standard)
select id, 'Standard', true from companies;
