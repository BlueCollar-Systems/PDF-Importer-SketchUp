# SketchUp 2017 foundation Save/Undo repair: v3.7.173

## Reproduction in the unchanged v3.7.172/r20 package

The ordinary-menu foundation test explicitly selected **3D Text** in SketchUp
Make 17.2.2555 / Ruby 2.2.4. Import completed in 147.9 seconds. Normal Save As
succeeded, but the first Edit-menu Undo changed from **Import PDF Vectors** to
**Check Validity** during Save. Exactly one Undo left the sheet in place. This
failed result remains preserved. A separate process opened the saved model and
saved a new copy without a model-repair prompt; both processes closed normally.

Read-only native graphs captured 111,841 entities before Save and 111,825
afterward: 16 loose Edges removed, none added, and no retained entity rows
modified. Six definition GUID fields also changed. Each removed edge has a
surviving duplicate with identical endpoint coordinates and the **same native
vertex IDs**, aligned independently of edge direction. The pairs have no faces,
curves or attributes and equal captured appearance. All affected collections
belong to drawing-geometry batches, rather than text glyph definitions.

One additional coincident pair uses different native vertices and survives
Save. The fix must preserve it. These observations identify the redundant
native topology repaired by Save; they do not identify the exact earlier API
call that created it or certify every internal model invariant.

## Change and source checks

The existing duplicate cleanup runs before collinear joins and gap bridging,
which can write additional geometry. A final sweep now follows both phases,
inside the caller's existing import operation. It removes only equally styled,
unattributed, faceless, non-curve edges with the same native vertices and exact
finite coordinates. Source-width ownership exclusions still apply. An uncertain
erase or changed survivor raises the existing cleanup failure so the caller
rolls back its operation. It starts no new operation and changes no validation
preferences, text representation or display depth.

The new regression tests check source-segment coverage, reversed direction,
separate coincident vertices, nearby and overlapping strokes, face/curve/source
ownership, all native style fields, nonfinite coordinates and uncertain erase
outcomes. The focused suite passes 23 tests / 209 assertions on actual Ruby
2.2.4 and 3.4.4, including the existing collinear coverage tests. Selected-operation
and geometry-staging checks also pass on both runtimes.

A separate replay of the actual changed method over the four captured native
collections removes exactly 16 mock edges (3/4/4/5) and preserves the separate
coincident pair on both runtimes. This checks the selection rule against actual
captured data; mock erasure does not establish native save validity.

## Native acceptance plan (historical: before r21 host checks, 2026-10-17)

Pending the new r21 package: repeat ordinary import, Save As, exactly one Undo,
normal close, fresh-process Open and Save As. Capture the actual Undo captions
and native graph before/after Save. A failed first Undo must stay failed; do not
hide it with a second Undo, a transparent operation or disabled validation.
Repeat the finite Raster fixture with real saved/reopened TextureWriter exports.

Private evidence stays outside Git under
`C:/BlueCollar-Validation/2026-10-17/`: `foundation172-ordinary-r2/Evidence/`
contains the original owners and exact graph delta; `foundation173-final-duplicate-tests-r1/`
contains both runtime results and captured-property replays. Original PDFs,
earlier failures and test packages remain unchanged. No release is published.


## Completed exact r21 native checks: 2026-10-17

The plan above records the pre-test pending state. The unchanged r21 package
was subsequently tested in SketchUp 2017 Make 17.2.2555 / Ruby 2.2.4:

| Identity | Value |
|---|---|
| Version / candidate | 3.7.173 / r21 |
| Tested source HEAD | `c164a7db0b5534f2362ef00552351abe37b462da` |
| Source tree | `4160f236964dda80160a20063efd14d84376e078` |
| RBZ | `SketchUp-PDF-Importer-TEST_v3.7.173_2026-10-17-r21.rbz` |
| SHA-256 | `e1dfec729ace66e240597e7240cfe25440770cf143b233b14df65292873506a2` |
| Bytes / members | 27,698,884 / 651 |

The foundation case explicitly requested **3D Text**. Ordinary import took
158.2 seconds; Save As succeeded and the first Undo after Save remained
**Import PDF Vectors**. Exactly one Edit-menu Undo restored the exact empty
baseline. After normal close without saving that Undo, a fresh process opened
the retained saved import and saved a new copy, without a repair prompt. Both
native roots exited normally (PIDs 26540 and 15800, actual exit code 0).

The exact same-session Save graph retained 111,825 entities: zero additions,
removals, modified entity rows or definition changes. Four total events contain
diagnostic arming and three Save callbacks; the event buffer did not overflow.
The targeted census found the 16 prior shared-vertex duplicate defects gone
before Save, all unique captured styled segments retained, and the separate
coincident pair with different vertices preserved. This is scoped exposed-
property/topology evidence, not a complete internal-validity certificate.

The instrumented first Undo completed about 104 seconds after an approximate
UI click; an empty viewport was confirmed within an approximately 109-second
observation bound. This is one instrumented observation, without a comparable
performance baseline or a proven cause. Native queue/observer registration and
geometry Undo costs were not isolated.

The authored **Raster** fixture also passed ordinary import (4.8 seconds),
Save As, one Undo to exact empty baseline, normal close and separate fresh
Open/resave. All 16 actual TextureWriter PNG exports independently matched the
eight original crop pixels, dimensions, persistent ancestry and transformed
placement. The finite horizontal, vertical and slanted regions retain all
15,273 reference ink pixels, with zero missing in either native stage. Native
PIDs 20096 and 24048 both exited normally with code 0.

Raw saved/fresh inventory equality remains **false**: 313 foundation and 10
Raster session `entity_id` fields differ. Literal differences are retained;
no raw equality was manufactured by normalizing IDs. Fresh-open/resaved raw
inventory is exactly equal in each case. The full foundation fresh-loaded deep
graph was not captured, so lightweight inventory does not establish every
deep property across sessions.

Current package [native acceptance](C:/BlueCollar-Test-Builds/2026-10-12/SketchUp-r21-candidate/NATIVE_ACCEPTANCE_2026-10-17.json)
and [curated evidence summary](C:/BlueCollar-Test-Builds/2026-10-12/SketchUp-r21-candidate/Evidence/native-2026-10-17-r1/SUMMARY.json)
bind the actual owners/UI facts, foundation independent lifecycle audit (307
assertions), exact Save delta/census/findings, and independent Raster physical
and lifecycle receipts. Modest evidence includes 16 native PNGs and eight
authored crop references; customer PDFs/models and full ~178 MB native graphs
remain private. Original build/runtime manifests and earlier failures remain
unchanged; the build identity's initial pending status is historical.

These results cover this requested foundation lifecycle/Save topology and
finite Raster fixture. They do not certify other PDFs/modes/hosts, full-page
compositing or general glyph editability. The foundation case did not add new
physical TextureWriter proof for its embedded images. This evidence/guide
update dispatches no release; remaining required checks stay separately scoped.
