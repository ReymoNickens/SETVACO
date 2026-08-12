-- Multi-tenancy root, plus country/currency/tax reference data.
--
-- `companies` is the tenant table: every business-data row elsewhere in the
-- schema carries a `company_id` and every RLS policy filters on it. SETVACO
-- is the only row today, but the schema never assumes there's only one.
--
-- Countries/currencies/tax rates are NOT tenant-scoped — 'GH' means Ghana
-- for every company, not just this one. Modeled as data so a new country is
-- an insert, not a migration.

create table companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique not null,
  created_at timestamptz not null default now()
);

create table currencies (
  code   text primary key,   -- ISO 4217, e.g. 'GHS', 'XOF', 'ZAR', 'USD'
  name   text not null,
  symbol text not null
);

create table countries (
  code                   text primary key,  -- ISO 3166-1 alpha-2
  name                   text not null,
  default_currency_code  text not null references currencies(code),
  default_locale         text not null default 'en' check (default_locale in ('en', 'fr'))
);

-- Flat rate + label per country, not a rule engine: SETVACO's actual need is
-- "what % and what do we call it on the quotation".
create table tax_profiles (
  country_code text primary key references countries(code),
  label        text not null,   -- e.g. 'VAT + NHIL + GetFund', 'TVA'
  rate_pct     numeric(5,2) not null default 0
);

insert into currencies (code, name, symbol) values
  ('GHS', 'Ghanaian Cedi', 'GH₵'),
  ('XOF', 'West African CFA Franc', 'CFA'),
  ('ZAR', 'South African Rand', 'R'),
  ('USD', 'US Dollar', '$');

insert into countries (code, name, default_currency_code, default_locale) values
  ('GH', 'Ghana', 'GHS', 'en'),
  ('ML', 'Mali', 'XOF', 'fr'),
  ('CI', 'Côte d''Ivoire', 'XOF', 'fr'),
  ('ZA', 'South Africa', 'ZAR', 'en');

insert into tax_profiles (country_code, label, rate_pct) values
  ('GH', 'VAT + NHIL + GetFund', 21.90),
  ('ML', 'TVA', 18.00),
  ('CI', 'TVA', 18.00),
  ('ZA', 'VAT', 15.00);

insert into companies (name, slug) values ('SETVACO', 'setvaco');
