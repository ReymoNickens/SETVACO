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

## Platform admin (cross-company, read-only)

`is_platform_admin` is a boolean flag on `profiles`, not a `role` value.
Kept deliberately orthogonal to `role`/`has_role()`: a platform-admin login
is still, mechanically, a profile belonging to one `companies` row (the
`evolveit` row, inserted for this purpose — not SETVACO's), the same as
every other login. The flag only widens what that specific login's SELECT
policies allow:

```sql
create function is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and status = 'Active' and is_platform_admin = true
  )
$$;
```

Every SELECT policy across the schema is `(company_id = current_company_id()
and has_role(...)) or is_platform_admin()`. Deliberately SELECT-only:
`is_platform_admin()` is never OR'd into a `_write`/`for all` policy
anywhere. A platform admin can look across tenants for support/monitoring,
but can't mutate another tenant's rows through client-side RLS-gated
writes — actual cross-tenant writes (onboarding a new company) go through a
service-role path (the `admin-manage-user` Edge Function), the same
posture that already applies to account provisioning.

No profile has this flag set yet — provisioning the first platform-admin
login is a manual step (create the auth user under the `evolveit` company,
same shape as the SETVACO bootstrap admin, then flip the flag by hand).

## Per-tenant feature gating and branding

`tenant_features` gates which modules a company can see — the mechanism
behind "don't hardcode `if SETVACO then show HR`" anywhere in the app.
Shaped like `roles`: a global `features` lookup table (module keys: 
`stock_room`, `sales`, `purchasing`, `service_jobs`, `hr`, `finance`) plus
a per-company join (`company_id`, `feature_key`, `enabled`). **Absence of a
row means disabled** — a new tenant starts with zero modules until an
operator explicitly enables them; SETVACO was backfilled with the four
modules already live (`stock_room`, `sales`, `purchasing`, `service_jobs`)
so the migration didn't hide anything for the existing tenant.

```sql
create function company_has_feature(feature text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select enabled from tenant_features
     where company_id = current_company_id() and feature_key = feature),
    false
  )
$$;
```

Enabling/disabling a company's modules is a platform-admin-only write (an
onboarding/upsell action), not something a company's own admin can
self-serve.

The frontend (`index.html`) reads this at login: `fetchTenantFeatures()`
loads the caller's enabled feature keys, and `NAV` items tagged with a
`feature` key are filtered against it. That filter fails **open** — if the
fetch errors (e.g. run against a database that predates this migration),
gating is treated as inactive rather than hiding every module, so this
degrades safely rather than locking anyone out.

`companies` also carries branding (`logo_url`, `primary_color`,
`accent_color`, hex-validated) and a `plan` field (plain `text`, default
`'standard'`, deliberately unconstrained — no `plans` table yet since
billing isn't designed).

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
- Quotations / Invoices (Parts Sales, Equipment Sales): `create_quotation`
  derives currency and tax rate authoritatively from the customer's
  `country_code` — the client only ever previews that number, never sets
  it. `convert_quotation_to_invoice` deducts real stock through
  `adjust_stock` (reason `sale`) and updates `customers.outstanding`;
  `mark_invoice_paid` reverses the balance. The two-stage credit-risk
  approval workflow from the original prototype was **not** carried
  over — every quotation goes straight to `Quoted` (see
  `20260810000100_quotations_invoices.sql`'s header comment). Inline
  "create a new customer while quoting" was also dropped; a customer has
  to exist first (via Customers) before they can be quoted.
- Per-tenant feature gating (`tenant_features`/`company_has_feature()`),
  branding + plan fields on `companies`, and a read-only cross-company
  platform-admin path (`is_platform_admin()`) — see "Per-tenant feature
  gating and branding" and "Platform admin" above. No profile has the
  platform-admin flag set yet (provisioning is a manual step, not done).
- HR Office: Employee Records (`employee_details`, 1:1 extension of
  `profiles`), Leave Requests (self-service file + admin/hr approve),
  Attendance (self-service clock in/out, `attendance_records`, one row per
  employee per day — see `20260813170205_attendance.sql`), Payroll Setup
  (admin/hr sets each active employee's `employee_compensation` — current
  salary only, not a history ledger), Performance & Discipline
  (self-service view, admin/hr-only write, `performance_records` — reviews
  and disciplinary write-ups in one table, no update/delete since a
  correction is a new record, not an edit to history), Training &
  Certifications (self-service view, admin/hr-only write, `certifications`
  — expiry status is computed by the frontend from `expiry_date`, not
  stored), Recruitment (admin/hr only end to end — no self-service side,
  since a candidate isn't a system user — `job_openings` + `candidates`;
  stops at "hired," no onboarding-checklist workflow in this pass),
  Employee Documents (self-service view, admin/hr-only upload —
  `employee_documents` metadata + a private `employee-documents` Storage
  bucket, the first use of Supabase Storage anywhere in this schema.
  Objects are keyed `{company_id}/{employee_id}/{uuid}-{filename}` and
  `storage.objects` has its own RLS policies mirroring the table's, so a
  doc is only ever reachable via a short-lived signed URL, never a public
  link — see `20260813203106_employee_documents.sql`).
- Finance Office: Expenses (self-service submit + admin/finance
  approve/reject/mark-paid; submitter can't approve their own, enforced
  server-side), Budgets (admin/finance set an amount per expense category
  and period, `budgets` — "actual" spend is computed by the frontend from
  Approved/Paid expenses in that category and period; deliberately scoped
  to Expense categories only, not Purchasing — a budget spanning both would
  need its own design pass), Payroll (admin/finance run a pay period through
  `run_payroll()` — a SECURITY DEFINER RPC that's the *only* way
  `payroll_runs`/`payslips` rows are created; direct INSERT/UPDATE/DELETE
  on both tables is revoked from `authenticated`, same posture as
  quotations/invoices. SSNIT/PAYE figures use the standard Ghana bands as
  of 2024 — a best-effort calculation, not a certified tax engine; see
  `20260813173638_payroll.sql`'s header comment), Petty Cash (admin/finance
  log cash in/out against the physical cash box, no approval workflow;
  balance is the running sum of ins minus outs, computed by the frontend
  rather than stored).
- Users & Access: real `profiles` roster, real account creation/
  suspend/reactivate through `admin-manage-user` (see above). Changing an
  existing user's role isn't wired to a backend action yet — the "Access
  Level" column is read-only.

- Purchasing: Vendors (`vendors`, root table, admin/procurement write,
  admin/procurement/finance read), Purchase Orders (`purchase_orders` +
  `purchase_order_lines`, created only via `create_purchase_order()` and
  advanced only via `advance_purchase_order()` — both SECURITY DEFINER,
  direct table writes revoked from `authenticated`, same posture as
  quotations/invoices). Receiving a PO moves real stock through
  `adjust_stock()` (reason `purchase_receipt`). A PO belongs to either a
  vendor (normal order) or a customer (the "Match PO Code" flow, matching
  an inbound industry-standard code to one of SETVACO's own customers) —
  never neither. See `20260813210923_purchasing.sql`.

- Service Bay: Active Jobs (`service_jobs`, admin/service/warehouse read,
  admin/service write — customer/asset cross-tenant validated server-side),
  Installed Base (`assets`, admin/sales/service/finance read, admin/sales/
  service write), Service Contracts (`service_contracts`, admin/service/
  finance read/create, admin/finance can cancel). Client feedback and
  internal manager commentary on a job are unified in `service_job_notes`
  (`note_type` discriminates, same shape as `performance_records`) — no
  update/delete, a correction is a new note. Display status
  (Expiring Soon/Expired for contracts, warranty status for assets) is
  computed by the frontend from date columns, not stored. See
  `20260813240000_service_jobs_assets_contracts.sql`.

- Price Books: `price_books` (root, admin-only write, admin/sales/finance
  read — sales needs it to price a quote, finance for visibility) always
  has exactly one Standard book per company (enforced by a partial unique
  index; a trigger blocks renaming or deleting it), plus as many custom
  books as the company creates. `price_book_entries` holds the per-item
  overrides, cross-tenant-validated against both its parent book and the
  item the same way service_jobs validates its foreign ids.
  `customers.price_book_id` (null = Standard) is validated against the
  same company on insert/update. `resolveUnitPrice()` in index.html is
  unchanged — it was already written against this exact shape, just
  against local-state ids instead of real ones. See
  `20260814123925_price_books.sql`.

- Notifications: the bell-icon inbox (`pushNotification()`), now backed by
  `notifications` (company-wide when `for_profile_id` is null, otherwise
  targeted — resolved from the display name every call site already
  passes). Unlike `audit_log`, a notification carries no integrity
  requirement, so it's a direct client insert under RLS rather than
  RPC-only. `read` is a single shared flag rather than tracked per
  recipient — a deliberate carry-over of the same simplification the
  local-state version already had, not a new gap. See
  `20260814132759_notifications.sql`.

- Variance & Audit's "Audit Log" sub-tab and Staff Activity now read from
  the real `audit_log` table instead of local state. `audit_log` already
  existed (`profiles_security.sql`) and was already being written to by 8
  different RPCs (`create_quotation`, `run_payroll`, purchasing, ...) —
  only the frontend read path was stale. It's deliberately RPC-only
  (`revoke insert, update, delete on audit_log from authenticated` —
  no client insert path, since it's a trust-sensitive record), so most
  `logAction()` call sites elsewhere in index.html (HR panels, Meeting
  Room, Price Books, ...) still have no real backing and never show up
  here — the UI says so directly (`va.auditLogDesc`) rather than
  implying this is a complete trail. The per-entry commenting feature
  StaffActivityTab/Sheet used to offer is removed: the real table has no
  place to store it, so keeping it would have meant comments that
  silently vanished on reload. Staff messaging (unrelated — backed by
  the real `notifications` table) is unaffected.

- Reports: the report *data* (quotations, invoices, service jobs, purchase
  orders, items, customers) has been real since those modules were
  migrated — `computeReport()` always worked against live data. Only the
  saved report *definitions* (a named source/groupBy/metric preset) were
  still local state, meaning a saved report never survived a browser
  switch. Now backed by `saved_reports`, company-wide visible like a price
  book, delete restricted to the creator or an admin. See
  `20260814153300_saved_reports.sql`.

- Stock Variance: a new feature, not a migration — `varianceLog` was a
  hardcoded const with no schema behind it at all. Two-phase, both through
  SECURITY DEFINER RPCs (no direct client insert on either table, same
  posture as purchase orders/quotations): `create_stock_count()` records
  what was physically counted per item against a server-snapshotted
  expected quantity (summed fresh from `inventory_ledger`, never trusted
  from the client — the same source of truth `adjust_stock()` itself
  uses), with no stock movement yet. `post_stock_count()` is the separate,
  explicit step that reconciles any variance into real stock, posting one
  `adjust_stock()` `'correction'` row per line — so a reconciliation is
  just as ledger-traceable as a purchase receipt or a sale, and shows up
  in the real Audit Log above. Gated to admin/warehouse/procurement,
  matching `adjust_stock()`'s own role check exactly (select access also
  extends to finance for oversight). The Stock Variance sub-tab now shows
  every nonzero-delta line across all counts, plus a Recent Counts list
  with a Post action for anything still Open. See
  `20260814160422_stock_counts.sql`.

- Accounts Payable: a new feature, scoped to PO-receipt-only (not manual
  bill entry) per the brief. `purchase_order_lines.unit_cost` existed
  since the original Purchasing migration but nothing ever populated it —
  the manual PO form, the Excel bulk-upload path, and
  `create_purchase_order()`'s p_lines shape all needed a unit_cost field
  added first, since a payable can't have an amount without one (the
  manual form defaults it from the item's own `cost`, still editable; the
  Excel path reads a Unit Cost/Price/Cost column if present, same
  item-cost fallback if not). `advance_purchase_order()` now inserts one
  `vendor_bills` row when a **vendor-sourced** PO (never a
  customer-matched one — nothing is owed there) reaches Received, summing
  `qty_ordered * unit_cost` across the PO's own lines. Payment terms are a
  flat net-30 for every vendor — no per-vendor terms field exists, and
  adding one is its own decision, not needed to make this feature work
  (documented simplification, same spirit as payroll's Ghana-tax-bands
  note). `pay_vendor_bill()` is a simple Open→Paid transition, admin/
  finance only, matching `mark_invoice_paid()`'s own posture on the AR
  side — no real bank/cash movement here either. See
  `20260814201430_accounts_payable.sql`.

**Still local demo state in `index.html`** (untouched, not yet migrated to
this schema): `nav_permissions` (server-side mirror of the role→nav-item
matrix) doesn't exist yet in this schema. Bank Reconciliation (Finance) is
a natural next step now that Purchasing/Accounts Payable are real, but
isn't built yet. Full audit parity (adding `audit_log` writes to every
remaining RPC/Edge Function so all logged actions become real) was
considered and deliberately deferred — see the audit_log migration's
commit for the tradeoff.

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

## `admin-manage-user` Edge Function

`supabase/functions/admin-manage-user/index.ts` now targets the current
schema: `create` sets `company_id` in `app_metadata` from the *caller's
own* `profiles.company_id` (never client-suppliable, so an admin can only
provision accounts inside their own tenant), and validates the requested
role against the live `roles` table instead of a hardcoded list — so a new
role added later (e.g. an `hr` role for the HR module) doesn't require
editing this function to become assignable.

Also fixed in the same pass, both pre-existing bugs that would have hit
the first real call: `suspend`/`reactivate` update `profiles` via the
service-role client, which bypasses RLS entirely — without an explicit
check, an admin from one company could suspend a login belonging to a
*different* company by `userId` alone. It now verifies the target profile's
`company_id` matches the caller's before touching it. Separately, every
`audit_log` insert wrote a nonexistent `actor_name` column and omitted the
required `company_id`, which would have errored on any actual invocation.

Deployed to the live project and wired into the frontend — "Users &
Access" in `index.html` creates real accounts through this function (no
password field in the create-user form; the temp password is
server-generated and never seen by the calling admin) and calls it again
for suspend/reactivate. The bootstrap admin remains the one account
created by hand directly against the database during setup, left to set
its own password via a genuine Supabase password-recovery email (nobody,
including the person who built this, ever knew or stored that password in
plaintext). Because `create` always provisions under the *caller's own*
company, this function can only ever add staff to a company that already
has an active admin — it can't bootstrap the very first admin of a brand
new company (SETVACO's own bootstrap admin or the first `evolveit`
platform-admin login). That first account per company still has to be
created by hand, directly against the database/Auth Admin API, same as
SETVACO's was.
