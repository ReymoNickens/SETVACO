# Per-client design method

## Standing principle

Every client on this platform gets a visual design grounded in their own
industry and daily materials, not a shared dashboard template with swapped
colors. No client should recognize the "shape" of another client's system
underneath theirs, even though the codebase is shared.

This isn't a one-time decision for SETVACO — it's the method to apply for
every future client:

1. **Identify the client's own native visual artifact** — the real
   paperwork or material their staff already handle daily. Not "what
   industry are they in" in the abstract, but the literal object: an
   invoice, a drawing, a lab report, a manifest, a prescription pad.
2. **Extract the structural signature of that artifact** — how it's laid
   out, stamped, annotated, numbered — not just a color palette lifted from
   their logo. The palette should have a *reason* traceable to the
   artifact (see SETVACO below: blueprint blue is the actual color of a
   cyanotype engineering drawing, not "blue because that's the brand").
3. **Actively avoid default SaaS dashboard vocabulary** — rounded cards,
   pastel icon chips, ring-progress KPIs, pill-highlighted sidebars. Treat
   these as off-limits by default, not caught only after a first draft
   looks generic. If a design decision would look identical dropped into
   any other SaaS product with the brand colors swapped, it hasn't found
   the client's own visual language yet.

## Architectural note: theme packs, not bespoke code per client

Per-client branding is a **theme pack**: a defined, reusable set of
layout/component variants assigned per tenant, built out deliberately over
time — not fully bespoke code written from scratch for every client. This
is what keeps "no client looks the same" achievable at 50+ clients without
a growing design team.

Today (single client, SETVACO) the theme lives directly in `index.html`'s
`Style()` component and JSX — there's no theme-switching mechanism yet
because there's only one theme. The CSS variable *names* in `Style()`
(`--brand`, `--ore`, `--vital`, `--teal`, etc.) were deliberately kept
stable across the SETVACO retheme specifically so that a future
multi-theme mechanism can swap *values* per tenant (via `tenant_features`/
`companies` branding columns, already in the schema — see
`docs/architecture.md`) without every component needing to change. The
room/station navigation *structure* (see Part 3 below) is meant to be
platform-wide; only the labels and sheet-index-style tags are per-client
vocabulary.

When a second client is onboarded, the actual "theme pack" abstraction
(how a tenant's theme gets selected and loaded) should get designed then,
against a second real example — not speculatively built now against a
guess at what a second client's artifact-derived direction will need.

## SETVACO: technical drawing / blueprint

**Native artifact**: SETVACO distributes and services crushing & screening
equipment for mining/quarry/construction clients. Their staff's real,
daily paperwork is engineering drawings and machine spec sheets — not
generic business documents. Blueprint blue-and-white is the literal color
of a cyanotype engineering drawing, which is why it's the right home for
the client's actual brand colors (blue/white) rather than an arbitrary
choice.

**Tokens** (`Style()` in `index.html`, values only — variable names
unchanged from the prior palette on purpose, see above):
- `--brand: #1E3A8A` — deep drafting-pen ink blue
- `--paper: #FFFFFF` — drawing-sheet white
- `--grid-line: #DCE6F7` — faint blueprint grid line
- `--ink: #101828` — primary text
- `--vital`/`--coral: #B4351E` — a single restrained "red pen" alert color
  (correction/critical mark), not a bright SaaS red
- `--amber: #9C6B12` — muted ochre caution mark
- `--teal: #1E7A5C` — deep technical green ("approved"/healthy)

**Type**: Oswald (condensed, technical/stencil character) for headlines —
replacing the previous Space Grotesk, which read as generic
startup-friendly rather than drafted. IBM Plex Mono is used much more
heavily throughout — every measured number (stock counts, dimensions,
dates, metadata) reads as a measured value, not dashboard decoration. IBM
Plex Sans remains for body copy.

**Structural signature**:
- **Sheet-index sidebar** (Part 3) — rooms and stations tagged like a
  drawing set's sheet numbers (`ST`, `SL`, `PU`, `SV`, `HR`, `FN`, `MR`),
  not an icon-and-label feature menu.
- **Title block header** — the stamped metadata box style from a real
  engineering drawing (sheet name, date, prepared-by, role, live status)
  replacing a generic page-title eyebrow.
- **Dimension-callout stats** — a measured number with a thin bracket line
  underneath, mono label, styled like a drawing's measurement annotation —
  replacing rounded icon-chip stat cards.
- **Cross-hatch** (`.mis-crosshatch`) for empty/no-access states — the
  pattern a real drawing uses for a cut-away or restricted section,
  instead of generic greyed-out placeholders.
- Fine blueprint grid background throughout (`.mis-root`'s
  `background-image`).

**Restraint rule**: every visual choice should be traceable back to "would
this exist on an actual engineering drawing." If not, reconsider it. This
ruled out, for example, soft drop shadows and large rounded corners in the
new components — a real drawing sheet is flat and hard-edged.

**Not yet built** (interaction-level, layered on top of this same
foundation once useful, not built speculatively ahead of demand):
loading states as a draw-on line animation, CAD-style layer-visibility
toggles for filters, dimension-line-style hover tooltips on measured
numbers, the audit trail as a literal revision-history table (Rev A/B/C).
