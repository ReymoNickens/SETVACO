-- Multi-country foundation: SETVACO's client base already spans Ghana, Mali,
-- and Côte d'Ivoire (see customers.country), and branches are now expanding
-- into other African countries too. This adds country/currency/tax as data
-- (new rows) rather than new code, so opening in another country doesn't
-- require a schema change — without building the full mine-operator-scale
-- machinery (HSE, CMMS, customs transit, offline sync) SETVACO doesn't need,
-- since it supplies and services mines rather than operating them.

create table countries (
  code text primary key,             -- ISO 3166-1 alpha-2, e.g. 'GH', 'ML', 'CI', 'ZA'
  name text not null,
  default_currency_code text not null,
  default_locale text not null default 'en' check (default_locale in ('en', 'fr'))
);

create table currencies (
  code text primary key,             -- ISO 4217, e.g. 'GHS', 'XOF', 'ZAR', 'USD'
  name text not null,
  symbol text not null
);

alter table countries
  add constraint countries_currency_fk foreign key (default_currency_code) references currencies(code);

-- One row per country's sales-tax treatment. Deliberately a flat rate + label
-- rather than a rule engine: SETVACO's actual tax need per jurisdiction is
-- "what % and what do we call it on the quotation", not divergent computation
-- logic. If a country ever needs genuinely different tax math, that's a real
-- escalation to handle then, not something to speculate into today.
create table tax_profiles (
  country_code text primary key references countries(code),
  label text not null,               -- e.g. 'VAT + NHIL + GetFund', 'TVA'
  rate_pct numeric(5,2) not null default 0
);

-- Manually-entered rates for quoting in one currency while books stay in
-- another. Not an automated FX feed or a gain/loss variance ledger — SETVACO
-- doesn't have transaction volume yet that justifies that; this is enough to
-- let a branch quote a francophone customer in their own currency today.
create table fx_rates (
  id uuid primary key default gen_random_uuid(),
  from_currency_code text not null references currencies(code),
  to_currency_code text not null references currencies(code),
  rate numeric(18,6) not null,
  as_of date not null default current_date,
  entered_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (from_currency_code, to_currency_code, as_of)
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

-- branches: attach a country so a new branch in another country is a row
-- insert, not a migration. Existing branches default to Ghana.
alter table branches add column country_code text references countries(code);
update branches set country_code = 'GH';
alter table branches alter column country_code set not null;

-- vendors: several are already foreign (Sandvik/SA, Terex, AUROX/Finland) but
-- the table never captured that — add it now alongside the rest of the
-- country plumbing rather than as a separate pass later.
alter table vendors add column country_code text references countries(code);

-- customers.country has always been free text (frontend-entered, e.g.
-- "Ghana", "Côte d'Ivoire") — add a proper code alongside it so
-- create_quotation can look up the customer's tax profile and currency
-- authoritatively instead of trusting a client-supplied rate. Left nullable:
-- an unmapped/unrecognized country falls back to the RPC's existing default
-- rather than blocking quotation creation.
alter table customers add column country_code text references countries(code);
update customers set country_code = 'GH' where country = 'Ghana';
update customers set country_code = 'ML' where country = 'Mali';
update customers set country_code = 'CI' where country in ('Côte d''Ivoire', 'Cote d''Ivoire', 'Ivory Coast');
update customers set country_code = 'ZA' where country = 'South Africa';

-- profiles: persisted per-user UI language preference (frontend enforces
-- the actual translation; this just carries the choice across sessions).
alter table profiles add column locale text not null default 'en' check (locale in ('en', 'fr'));

-- quotations / invoices / purchase_orders: tag every money-bearing document
-- with the currency it was actually written in, so a Bamako branch can quote
-- in XOF while consolidated reporting still reads GHS via fx_rates. Existing
-- rows default to GHS (SETVACO's current operating currency).
alter table quotations add column currency_code text not null default 'GHS' references currencies(code);
alter table invoices add column currency_code text not null default 'GHS' references currencies(code);
alter table purchase_orders add column currency_code text not null default 'GHS' references currencies(code);
