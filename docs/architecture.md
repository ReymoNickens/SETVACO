# SETVACO Backend Architecture

## Why

The app started as a single `index.html` file with all state in React `useState`,
persisted only to per-browser `localStorage` — two staff in different browser
tabs couldn't see each other's stock changes, "login" was a fake role
dropdown, and record IDs were generated client-side via `max(existing)+1`, a
race condition the moment two people used the system at once.

This document describes the real Supabase backend now replacing that
foundation, built multi-tenant from day one even though SETVACO is the only
client today, so a second client is a new row — not a rewrite.

## Stack

- **Supabase**: managed Postgres + Auth + Row-Level Security.
- Everything is Postgres: direct PostgREST + RLS for plain CRUD,
  `SECURITY DEFINER` RPC functions for anything that needs to touch more
  than one table atomically (right now, just `adjust_stock`).
- The frontend (`index.html`) talks to Supabase directly via `supabase-js`
  loaded from a CDN — no build step. `window.sb` is the shared client,
  initialized near the top of the file.

## Multi-tenancy

`companies` is the tenant root. Every business table carries a `company_id`,
and every RLS policy filters on `company_id = current_company_id()` in
addition to a role check. `current_company_id()` reads the logged-in user's
own `profiles.company_id` — there is no way for a client to claim a
different company.

Tenant safety doesn't rely on the frontend remembering to filter correctly.
A `BEFORE INSERT` trigger on every tenant table overwrites `company_id`
itself — either with the acting user's own company (defense against
spoofing) or derived from the parent row it references (a stock room's
company always matches its branch's company, an item's always matches its
stock room's, etc.), and rejects the insert outright if that would cross a
tenant boundary. A bug elsewhere in the app that forgot to scope a query
still can't leak or corrupt another tenant's data — the database itself
won't allow the row to exist.

## The physical hierarchy: Company → Country → Branch → Stock Room

- `companies` — the tenant.
- `countries` / `currencies` / `tax_profiles` — global reference data, not
  tenant-scoped (Ghana is Ghana for every company). A new country a branch
  opens in is a row insert, not a migration.
- `branches` — belongs to one company, tagged with a `country_code`. This is
  what makes "Country" a level in the hierarchy without a separate table:
  branches naturally group by country.
- `stock_rooms` — belongs to one branch.
- `items` — belongs to one stock room (and, derived from that, one branch
  and one company).

## Inventory is an append-only ledger, not a quantity field

`items` has **no quantity column**. Every stock change — an opening count,
a purchase coming in, a sale going out, a correction — is a new row in
`inventory_ledger`. That table only ever grows: `UPDATE`/`DELETE` are
revoked entirely, and plain `INSERT` is revoked too — the only way to add a
row is the `adjust_stock(...)` RPC, which:

1. Checks the caller has an inventory-managing role and that the item
   belongs to their own company.
2. Sums the item's existing ledger rows to get the current balance.
3. Rejects the change if it would take stock negative.
4. Inserts the ledger row and an `audit_log` row, and returns the new
   balance.

"Current stock" is never stored — it's `items_with_stock`, a view that sums
`inventory_ledger` per item (`security_invoker = true`, so it enforces the
querying user's own RLS, not the view owner's). The frontend reads this
view, never `items` directly, whenever it needs a quantity.

Ledger rows also carry an optional `unit_cost` + `currency_code`, so a
purchase receipt in XOF remembers what it actually cost in XOF — not just
the running total, converted.

## Currency lives on the transaction, not the company

There's no single "GHS" assumption anywhere in the schema. `customers`
carries a `country_code` (which implies a default currency/tax rate via
`countries`/`tax_profiles`); money-bearing rows are expected to carry their
own `currency_code` once quotations/invoices are rebuilt against this
foundation (see "Not yet built" below) the same way `inventory_ledger`
already does for stock movements.

## Authorization

One primitive, used by every RLS policy and RPC:

```sql
create function has_role(allowed text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and status = 'Active' and role = any(allowed)
  )
$$;
```

Paired with `current_company_id()` (same shape, returns the caller's
`company_id`). Both are `SECURITY DEFINER` — required, not optional:
`profiles` has its own RLS policy that itself calls `has_role()`; running
these as `SECURITY INVOKER` would re-trigger that policy from inside
itself, infinite recursion the first time anything calls them. Running as
the trusted function owner bypasses RLS for just this one lookup and breaks
the cycle.

Every RLS policy on a tenant table is `company_id = current_company_id()
and has_role(array[...])` — role alone is never enough, since that would
let one company's warehouse clerk see another company's stock.

## Passwords and login

Entirely Supabase Auth's job — nothing custom. `auth.users.encrypted_password`
is a bcrypt hash; sign-in is `supabase.auth.signInWithPassword()`, checked
by Supabase's own GoTrue service. The frontend never sees or handles a raw
password except in the "set a new password" screen shown after a password
recovery link, which calls `supabase.auth.updateUser({ password })` — that
value goes straight to Supabase over HTTPS, never logged or stored locally.

Every new login is a `profiles` row, created automatically by a trigger on
`auth.users` insert (`handle_new_auth_user`). That trigger reads
`company_id` from `raw_app_meta_data` — which only a service-role caller
can set, never the person signing up — and **raises an exception** (rolling
back the whole signup) if it's missing. That means self-serve signup can't
produce a working account even if Supabase's dashboard "Allow signups"
toggle is left on; account creation is meant to go through an admin-only
provisioning path (the `admin-manage-user` Edge Function scaffolding
already in `supabase/functions/`, not yet wired to the new schema — see
below). Every new profile starts at the least-privileged `sales` role
regardless of what the signup request claims; only an already-verified
admin can escalate it.

## What's built vs. not yet built

**Built, live, and RLS-scoped end-to-end** (schema + real frontend wiring):

- Real login (`supabase.auth.signInWithPassword`, forgot-password, set-new-
  password) — replaces the old fake role-switcher entirely.
- Stock Room / Inventory: real stock rooms, real items, real
  `inventory_ledger`-backed quantities, visible in an item's "Stock
  movement ledger" panel. The Excel bulk-upload path writes real rows and
  real ledger adjustments (not a local-state replace).
- Customers: real CRUD, real country lookup, real contacts.

**Still local demo state in `index.html`** (untouched, not yet migrated to
this schema): quotations, invoices, purchase orders, service jobs, vendors,
assets, service contracts, reports, price books, users & access management,
notifications, variance/audit. These need their own migrations (roughly:
`quotations`/`invoices`/`purchase_orders` + line tables, `service_jobs`,
`vendors`, plus RPCs for anything with a status workflow + stock side
effect — `convert_quotation_to_invoice` in particular needs to call
`adjust_stock` instead of touching a quantity field) before they're real.
`nav_permissions` (server-side mirror of the role→nav-item matrix) also
doesn't exist yet in this schema.

## Migrations

Supabase CLI migrations in `supabase/migrations/`, applied in filename
order. `supabase/seed.sql` no longer exists — the old one seeded the
superseded single-tenant schema; there's no demo seed data for the new one
yet (SETVACO's `companies` row and Ghana/Kumasi/Tema `branches` were
inserted directly against the live project while building this, not via a
committed seed script).

## One-time manual step: disable self-serve signup on the hosted project

Same caveat as before: the `on_auth_user_created` trigger already blocks a
self-signed-up account from ever getting a working `profiles` row (see
"Passwords and login" above), but Supabase's platform default of self-serve
signup being *enabled* should still be turned off by hand in Dashboard →
Authentication → Providers → Email, so a stranger hitting `signUp()`
directly gets a clean rejection instead of a confusing 500.

## One-time manual step: enable leaked-password protection

Dashboard → Authentication → Policies (or Providers → Email) → turn on
"leaked password protection" (checks against HaveIBeenPwned on
signup/password-change). Off by default on a new project; no schema or
Edge Function change needed, just a toggle.

## Known gap: `admin-manage-user` Edge Function not yet updated

`supabase/functions/admin-manage-user/index.ts` still targets the old
schema's role list and doesn't set `company_id` in `app_metadata` when
creating a user — needed before it can be used as the real "create a staff
account" path against the new schema. Right now, the only account created
is the bootstrap admin, provisioned by hand directly against the database
during setup and left to set its own password via a genuine Supabase
password-recovery email (nobody, including the person who built this,
ever knew or stored that password in plaintext).
