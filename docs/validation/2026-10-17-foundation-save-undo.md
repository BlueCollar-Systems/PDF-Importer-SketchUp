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

## Exact candidate native acceptance

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
