# SETVACO Backend Architecture

## Why

The app started as a single `index.html` file with all state in React `useState`,
persisted only to per-browser `localStorage`. That means two staff in different
browser tabs can't see each other's stock changes, "login" is a fake role
dropdown, and record IDs are generated client-side via `max(existing)+1` — a
race condition the moment two people use the system at once. This document
describes the Supabase backend replacing that, designed so the system stays
usable by a small team **without** needing a human to hand-run migrations or
babysit infrastructure.

## Stack

- **Supabase**: managed Postgres + Auth + Row-Level Security + Storage.
- **Supabase Edge Functions** (Deno): only for the two things Postgres can't
  do itself — sending email (`send-document-email`) and admin auth operations
  (`admin-manage-user`, which needs the service-role key to create/suspend an
  `auth.users` row).
- Everything else — CRUD and every multi-table business transaction — is
  Postgres: direct PostgREST + RLS for plain CRUD, `SECURITY DEFINER` RPC
  functions for anything with a status workflow and a side effect.

## Schema

See `supabase/migrations/` for the authoritative DDL, applied in order:

1. `20260807000100_lookups.sql` — `roles`, `branches`, `nav_permissions`,
   shared enums, and `gen_display_code()` (the per-prefix `SEQUENCE` +
   trigger pattern that replaces the client-side `uid()` race condition).
2. `20260807000200_core_tables.sql` — `profiles` (1:1 extension of
   `auth.users`), `stock_rooms`, `items`, `vendors`, `customers`,
   `customer_contacts`.
3. `20260807000300_transactional_tables.sql` — `quotations`/`quotation_lines`,
   `invoices`/`invoice_lines`, `purchase_orders`/`purchase_order_lines`,
   `service_jobs`, `notes` (the shared feedback/manager-comment thread).
4. `20260807000400_audit_notifications.sql` — `approval_settings`,
   `approval_flagged_customers`, `audit_log`, `notifications`,
   `variance_log`.
5. `20260807000500_rls_policies.sql` — `has_role()` and every table's RLS
   policy.
6. `20260807000550_countries_currency_tax.sql` — `countries`, `currencies`,
   `tax_profiles`, `fx_rates`, plus `country_code`/`currency_code` columns on
   `branches`, `vendors`, `customers`, `profiles.locale`, and every
   money-bearing document table. Sits before `rpc_functions.sql` because
   `create_quotation` depends on it (see below).
7. `20260807000600_rpc_functions.sql` — every transactional RPC.

**Multi-country foundation:** SETVACO's client base already spans Ghana,
Mali, and Côte d'Ivoire, and branches are expanding into other African
countries. `countries`/`currencies`/`tax_profiles` model this as data (new
rows), not new code — a new country is an `insert`, not a migration.
`create_quotation` derives `tax_rate` and `currency_code` authoritatively
from the customer's `country_code` (via `tax_profiles`/`countries`) rather
than trusting the client-supplied `p_tax_rate` parameter it used to accept
uncritically; that parameter is now only a fallback for customers with no
mapped country yet. This is deliberately *not* the full multi-entity /
tri-currency-FX-ledger / offline-sync architecture a mine-operator-scale ERP
would need — SETVACO supplies and services mines, it doesn't run them, so
that scope was cut in favor of the smaller foundation above. See the
"Deferred scope" note near the bottom of this document for what was
considered and explicitly not built.

Key departures from a literal 1:1 field mirror of `index.html`, and why:

- **UUID primary keys everywhere**, with a separate unique `display_code`
  column holding the `WP-1001` / `QT-9001` style codes the frontend already
  uses. FKs on a variable-format text key are error-prone; `auth.users.id` is
  already a UUID, so this keeps one currency throughout.
- **`feedbackLog` / `managerNotes` → a normalized `notes` table**, not JSONB.
  RLS operates per row, not per element inside a JSON array, and
  `managerNotes` has stricter write access (admin/finance only) than
  `feedbackLog` — a single JSONB column can't express that split safely.
- **`approvalSettings.flaggedCustomers` → a join table** (`customer_id` FK),
  not a name array — a customer rename no longer silently un-flags them.
- **`role` is a lookup table, not an enum** — avoids Postgres's
  `ALTER TYPE ... ADD VALUE` transactional restrictions and lets roles carry
  a display label.

## Authorization

One primitive, used by every RLS policy and RPC:

```sql
create function has_role(allowed text[]) returns boolean
language sql stable as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and status = 'Active' and role = any(allowed)
  )
$$;
```

An indexed lookup on `profiles`, not a custom JWT-claims Auth Hook — fewer
moving parts, and suspending a user takes effect on their very next request
instead of waiting for their JWT to expire.

**RLS handles plain CRUD** (items, vendors, customers, stock rooms, branches,
service jobs, notes, ...), mirroring the `NAV` role matrix and each panel's
`canManage` check in `index.html`.

**RPCs handle every table with a workflow + side effect** — `quotations`,
`invoices`, `purchase_orders` all have `INSERT`/`UPDATE` revoked from
`authenticated` entirely, because RLS alone can't express "flip this
quotation to Invoiced *and* deduct stock *and* write an audit row,
atomically." See `20260807000600_rpc_functions.sql` for the full set:
`create_quotation`, `approve_quotation`, `reject_quotation`,
`convert_quotation_to_invoice`, `raise_purchase_order`,
`advance_purchase_order`, `match_po_code`, `submit_matched_order`,
`bulk_upsert_items`, `bulk_create_purchase_orders`.

## Migrations ("not dependent on humans to manage")

- Supabase CLI migrations in `supabase/migrations/`, applied **only** via CI
  (`.github/workflows/migrate.yml`, `supabase db push` on merge to `main`) —
  never hand-run against production through the Studio SQL editor.
- `supabase/seed.sql` reproduces the demo dataset for local dev
  (`supabase db reset`) — it is **not** applied in production; the only
  production-required reference data (`roles`, `branches`, `nav_permissions`)
  ships in the migrations themselves.
- `packages/shared-types/database.types.ts` is regenerated by CI on every
  migration change and consumed by both the frontend and the Edge Functions,
  so a renamed column becomes a type error instead of a silent runtime bug.

## One-time manual step: disable self-serve signup on the hosted project

`supabase/config.toml`'s `enable_signup = false` only governs the local CLI
dev stack — `migrate.yml` and `deploy-functions.yml` push migrations and
function secrets, never `[auth]` config, so a freshly linked hosted project
keeps Supabase's platform default of self-serve signup **enabled** until
someone disables it by hand in Dashboard → Authentication → Providers →
Email → "Allow new users to sign up". Until that's done, anyone can call
`supabase.auth.signUp()` directly. The `on_auth_user_created` trigger always
assigns the new profile the least-privileged `sales` role regardless (it
never trusts client-supplied signup metadata), so this can't be used to
self-grant admin — but it would still let an outsider create a live,
authenticated `sales`-role account, which the intended model (accounts
provisioned only via the `admin-manage-user` Edge Function) doesn't expect.

## Rollout (no big-bang rewrite)

The prototype (`index.html`) keeps running unmodified through Phase 0.

0. **Foundation** — this scaffolding, invisible to users.
1. **Auth cutover + build step** — real Supabase Auth replaces the role
   dropdown; introduces Vite + React (required — in-browser Babel can't hold
   a scoped Supabase client or consume generated types).
2. **Stock Rooms + Items** — first real data module; everything else FKs
   into it, and it's where the localStorage-per-browser split is most
   visibly broken today (add a Realtime subscription on `items` here).
3. **Vendors & Customers** — plain CRUD, gives Phase 4 real FK targets.
4. **Quotations/Invoices, Purchase Orders** — the RPC-heavy modules.
5. **Service Jobs, Variance & Audit, Users & Access, Notifications, email.**

On the frontend side: introduce TanStack Query module-by-module (each panel
gets a hook like `useItems()` that starts as today's `useState(initialX)` and
gets swapped to `useQuery`/`supabase-js` when its phase lands), and shrink the
`savePersisted`/`loadPersisted` localStorage blob one module at a time as
each goes live server-side.

## Deferred scope: what a mine-operator ERP would need that this doesn't build

SETVACO supplies equipment/parts and provides maintenance, training, and
construction *services* to mines and quarries — it doesn't operate mines. A
proposal was raised to architect this as a full Pan-African mining-operator
ERP (multi-entity `Group → Country Subsidiary → Mine Site → Warehouse → Bin`
hierarchy, HSE incident/PPE logs, hazmat and local-content compliance
tracking, CMMS work orders, customs/bonded-warehouse transit corridors,
offline-first IndexedDB sync with idempotent replay, an automated
tri-currency FX gain/loss ledger, inter-company transfer pricing). That's
the right scope for a company that *runs* mine sites; it's not what SETVACO
is or does today, and building it speculatively — before an actual client
need — would mean months of unused schema and modules to maintain.

What was built instead (`20260807000550_countries_currency_tax.sql`) covers
the same underlying ambition — ready to serve a client in another country
without a rewrite — at the scale SETVACO actually operates at: `branches`
gained a `country_code` instead of a full entity hierarchy (a new
branch in Mali is a row, not a new level of nesting); money-bearing
documents carry a `currency_code` and rates are entered manually into
`fx_rates` instead of an automated FX-variance ledger; tax is a per-country
rate + label in `tax_profiles` instead of a pluggable strategy-pattern
engine. If a genuine mine-operator-scale client or in-house mining
operation materializes, revisit this section — the foundation here doesn't
block building any of the deferred pieces, it just doesn't pre-build them.

## Frontend i18n (EN/FR) — scope

`index.html` has a translation dictionary (`TRANSLATIONS`), a `t(lang, key)`
helper, a `tf(lang, key, vars)` variant for strings needing interpolated
values (counts, filenames, dates — `{token}` substitution), a language
toggle in the header (and its own toggle on the login/gate screens, which
render before the main app), and the choice persists via the existing
`localStorage` mechanism (`lang` field; will move to `profiles.locale` once
real auth lands).

**Wired scope (complete):** every screen — navigation, header/sidebar
chrome, Dashboard, Sales Overview (including the Weighted Forecast Value
KPI), Stock Room/Equipment Inventory, Purchasing (all three sub-tabs),
Customers, Users & Access (including the email-templates editor), Variance
& Audit, Staff Activity, Service Jobs, Sales/Quotations (create-quotation
flow, documents table, detail drawers, manager comments), the notification
bell, the command palette, and the customer-facing quotation/invoice
documents and emails. Business-logic data values that happen to be
translated for display (customer tier, branch filter "All") keep their
underlying canonical English value in state — only the label shown changes
— so comparisons like `c.tier === "Gold"` keep working regardless of UI
language.

Admin-authored free text is a separate, deliberate exception to the above:
email template subject/body (`emailTemplates` state, editable in Users &
Access) and staff-activity messages/comments are content admins write
themselves, not UI labels — they are not run through `t()`/`tf()` and stay
in whatever language the admin types them, the same way a customer's name
or a manager's comment note already does.

**Still not wired (deliberate, documented exception):** dynamically-built
strings inside business-logic handlers — audit log entries, toast messages,
`window.alert`/`window.confirm` text. Translating those means extracting
variables out of template literals into parametrized translation strings,
a different and harder class of work than relabeling static JSX (which is
what the rest of this section covers). If/when that's tackled, follow the
same `t(lang, …)` / `tf(lang, key, vars)` pattern already established
throughout, and re-run the Babel+jsdom role/nav sweep afterward — don't
ship a mixed-language UI.

## Frontend login gate — prototype-level, not real auth

`index.html` now shows a `LoginScreen` before the app: username + a shared
demo password (`setvaco-demo`, matching the real password already seeded in
`supabase/seed.sql`'s `auth.users` rows, so the two won't drift confusingly).
A successful match against the local demo user list (`users` state, must be
`status === "Active"`) sets `loggedInUserId`, which now determines `role` and
`currentUser` — the old free role-switcher dropdown in the header is gone,
replaced by a Log out button, since a real login determines your role rather
than letting you pick it.

**This is explicitly not connected to the real Supabase Auth backend** built
earlier in this document — it's the same fidelity as the role dropdown it
replaced, just gated by a real user identity instead of a free choice. The
real login is the Phase 1 auth cutover already described under Rollout
below: real Supabase Auth, a Vite+React build step (required — in-browser
Babel can't hold a scoped Supabase client), real sessions, real password
checks via GoTrue. When that phase starts, `LoginScreen` gets replaced
wholesale by a `supabase.auth.signInWithPassword()` flow — don't try to
gradually wire this one up to the real backend in place, the auth models
are different enough (session tokens vs. a plain `loggedInUserId` in
localStorage) that a clean swap is simpler than a migration.

Session persists via the existing `localStorage` mechanism (`loggedInUserId`
field). If an admin suspends a logged-in user in Users & Access, that
session naturally drops back to the login screen next render, since
`loggedInUser` is looked up live by id + `status === 'Active'` on every
render rather than cached at login time.

## Access-code gate — deterrent, not access control

`index.html` also has a single shared access code (`ACCESS_CODE` near the
end of the file, default `"Setvaco2026"`) gating the entire page behind an
overlay, independent of the per-user login above it. It's implemented as
plain vanilla JS/HTML sitting outside the React tree — the overlay markup
is in `<body>` before `#root`, and the unlock script is a separate `<script>`
tag after the React app's — specifically so it blocks the view before
React/Babel even finish loading, not just after mount. Unlocking isn't
persisted anywhere (no `sessionStorage`/`localStorage`) — the code is asked
for again on every page load or refresh, by design; the gate also reads the
persisted language preference (if any) from the same `localStorage` key the
app uses, so returning visitors see the gate in whichever language they'd
last picked.

**This is not real security and shouldn't be treated as one.** The code is
plaintext in page source — `view-source:` or the browser devtools reveal it
in seconds to anyone who looks, and there's no rate limiting or backend
check at all. It exists purely to stop someone from casually landing on a
shared demo link and poking around; it does not replace `LoginScreen`,
doesn't replace making the GitHub repo private, and doesn't replace real
backend authorization. Change `ACCESS_CODE` before sharing a link, and treat
it as a doorbell, not a lock.

## Salesforce-inspired additions — what was adopted and what wasn't

The client's team has a Salesforce background, so a review pass was done
against Salesforce's feature set to pull in what's genuinely useful here,
without turning this into a Salesforce clone the way the earlier "Pan-African
mining ERP" pitch would have turned it into a full mining ERP. Adopted:

- **Path** (`PathStepper`, `index.html`): the numbered-circle stage tracker
  Salesforce shows on Opportunity/Case records, reimplemented against this
  app's actual status flow. Shown on the quotation detail drawer
  (`Quoted → Sent → Invoiced`) and the service job detail drawer
  (`Open → In Progress → Completed`) — only when the record's status is
  actually one of those three; `Pending Approval` and `Rejected` are
  exception branches, not points on the path, matching how Salesforce Path
  only tracks the "happy path" stages too.
- **Credit-risk-gated approval**: `creditLimit`/`outstanding` per customer
  already existed (Customers table, Dashboard "Customer Credit Risk"
  widget) but weren't wired into anything — the equivalent Salesforce
  pattern is a validation rule on Opportunity that blocks progress based on
  a rollup from the Account. `needsApproval` in `CreateQuotationModal` now
  also holds a quotation for sign-off when the customer is over
  `CREDIT_RISK_THRESHOLD` (75%) of their credit limit, not just over the
  value threshold or on the manually-maintained flagged list.
- **Director role + Company Financials** (`ROLES`, `CompanyFinancials` in
  `index.html`): Salesforce's Role Hierarchy plus profile-restricted
  report/dashboard folders — an executive sees a rollup nobody else does.
  `director` has the same nav access as `admin` everywhere (added to every
  `NAV` roles array and permission check `admin` appears in) plus one
  exclusive page: total stock value, weighted pipeline, total customer
  outstanding, and estimated gross margin by part, company-wide.

**Deliberately not adopted** (would be over-building for a parts/equipment
sales-and-inventory business, the same call made in "Deferred scope"
above): Leads and lead conversion (sales here starts directly as a
quotation against a known customer, there's no separate prospecting
funnel), Campaigns, Territory Management, Opportunity Splits/forecasting
categories beyond the single weighted-pipeline number already shown,
Chatter (the existing Staff Activity module already covers
comment/mention-style staff communication for this app's scale), and
Duplicate Rules (the existing customer-lookup-by-name flow hasn't shown a
duplicate-data problem worth a rules engine yet).

**Known gap:** `director` is a frontend-only role for now. The Supabase
`roles` lookup table and the `has_role(...)` arrays throughout
`supabase/migrations/20260807000500_rls_policies.sql` still list only the
original six roles — harmless today since the frontend isn't cut over to
real Supabase Auth yet (see "Frontend login gate" above), but add
`director` to both when Phase 1 auth cutover happens, or a director-role
account will pass the frontend's login screen and then fail every RLS
check.
