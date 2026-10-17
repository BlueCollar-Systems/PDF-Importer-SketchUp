# SketchUp 2017: other text modes, v3.7.173

The exact r21 test package was exercised through ordinary SketchUp 2017 Make
17.2.2555 menus. Text, Labels, Glyphs and Geometry each passed import, Save As,
one Undo of the import, a fresh-process Open, and a second Save As. Save kept
`Undo Import PDF Vectors` as the first Undo operation. The saved import remained
available after closing the undone document without saving.

These are finite fixture results, not certification of arbitrary PDFs or all
SketchUp releases. Viewport appearance is a separate acceptance criterion.

## Bound inputs

- Source HEAD: `cec992ceba0e1aa20402b4f9c2d801cc8c8c4afd`.
- Installed/archive r21 SHA-256:
  `e1dfec729ace66e240597e7240cfe25440770cf143b233b14df65292873506a2`.
- Authored `mixed-rotated-modes.pdf` SHA-256:
  `269b98c863b22c246a0234418bbd4fa8fe113d46b01b332eacaa6bbbef5a228b`.
- The Letter-size fixture contains horizontal, vertical and 30-degree text,
  23 glyph placements, eight extracted spans and a vector rectangle. It has
  no embedded image. A differently hashed older fixture is not this input.

Private evidence is under
`C:/BlueCollar-Validation/2026-10-17/su173-{text,labels,glyphs,geometry}-r1`.
Original PDFs, saved models, native captures and screenshots stay outside Git.

## Actual native delivery

| Requested mode | Observed delivery | Import time | Saved/fresh expanded nodes |
| --- | --- | --- | --- |
| Text | Eight source-outline 3D groups after the item-bound Text capability proof | 3.6 s | 2,660 / 2,660 |
| Labels | Eight source-outline 3D groups after six size/run-width and two rotation proofs | 3.3 s | 2,660 / 2,660 |
| Glyphs | Eight span owners with 23 flat glyph units and 23 filled faces | 4.4 s | 694 / 694 |
| Geometry | Eight span owners with flat native edges and 23 filled faces | 3.7 s | 703 / 703 |

Text and Labels did not create editable `Sketchup::Text` annotations. Their
reported adjacent fallback is the source-outline 3D representation. Glyphs and
Geometry remained in their requested modes. No image appeared in these four
mode captures.

The eight lifecycle stages all exited normally under their retained owned
process handles. There was no forced cleanup. Guided UI round trips used the
separate 1,800-second allowance; each read-only physical capture retained its
hard 60-second deadline.

The final lifecycle integration receipt is
`textmodes173-integration-audit-r1/FINAL-ALL-FOUR-MODES.json`, SHA-256
`13efa7df52f0fc1ab9d192327b9b7393f4e516ea242fb3508f47234c10214e12`.
It verifies operations and ownership, not visual equivalence.

## Physical checks and their limits

Independent checks traversed actual native faces, loops, edges, instance
transforms, persistent IDs, materials and source attributes. Text/Labels kept
positive depth; Glyphs/Geometry remained flat. Per saved/fresh capture, 4,618
opaque source-interior samples and 415,571 clear-interior samples across the
three fixed text regions had no missing or unexpected face ink. A one-pixel
boundary band was excluded. These samples do not measure displayed edge ink
or prove whole-page pixel identity.

All primary coordinates, topology, transforms, persistent IDs, styles and
attributes remained literally equal across the fresh reopen. Session
`entity_id` values changed. Text/Labels additionally had 1,291 derived Face
normal/plane/area differences. Every raw difference is retained; strict raw
equality remains false. Only those derived fields satisfy the separately
reported observed bounds: at most two ULP and 2.220446049250313e-16 for
normal/plane values; at most three ULP and 8.673617379884035e-19 square inches
for area. No primary coordinate or arbitrary attribute normalization is used.
Glyphs/Geometry had only session-ID differences.

Independent physical receipt SHA-256 values:

- Text: `58ba6fd947f7d93ac017e6f8bcda22f71f59aa2e00920632218e58dcb2311111`.
- Labels: `f4d364231000b181718786272598a302cdd35f9c636c05d74332a10885c85fcd`.
- Glyphs: `a91b0cd3b2e58aab61496fdd2d1047826e879e64fe6106347d033fc7e1851cc8`.
- Geometry: `76f5bdb693b97ac285eea24d7b12facce9128a84cc8033d0c3cffbd719ffb88a`.

## Display issue found

Despite the face-interior checks, Glyphs and Geometry looked heavier than the
3D text equivalents. Their filled letter faces also had visible contour edges.
A separate private-copy UI control toggled View > Edge Style > Edges exactly
once, with no camera navigation or geometry edit. The letters visibly became
thinner. The standalone page rectangle also disappeared, so changing the
whole model's display setting is not an acceptable product repair.

The control's original failed post-exit qualifier and all original captures
remain unchanged. Independent file-only qualification records the actual
SketchUp 2017 option, `EdgeDisplayMode`, and explicitly resolves the root-fact
field-name mismatch. The failure is not rewritten as an original passing run.
Its supplement, under
`C:/BlueCollar-Validation/Checks/su173-edges-display-independent-20261017-r1/INDEPENDENT-SUPPLEMENT.json`,
has SHA-256
`79515823b328edf7b1190086a19def07bad9d9cc332bb09cac7364ad9088f2b7`.
All 701 expanded scene nodes, IDs, styles, attributes, camera and viewport
remained literally equal; the sole rendering-option difference was the actual
integer `EdgeDisplayMode` changing from 1 to 0. Both saved model files retained
their original bytes. The host exited normally with no forced cleanup.
A source fix and its new package/native results require their own evidence;
these v3.7.173 results must not be relabeled as a later version.

The Geometry captures additionally contain 32 tagged loose contours duplicating
32 anonymous, host-created Face boundary edges. Every pair has literally equal
local and world endpoints, the same source glyph/placement through its owned
Face, and the same effective visible black paint. Each pair shares one native
vertex and has a distinct but coincident second vertex. Raw layers and
attributes differ: the anonymous boundary is on Layer0. These distinctions are
retained, not normalized away. Hiding only attached boundaries would leave the
32 loose contours visible; requiring source attributes on every host-created
edge would reject genuine Geometry output. The independent classification is
`C:/BlueCollar-Validation/Checks/su173-geometry-unfaced-20261017-r1/CLASSIFICATION.json`,
SHA-256 `8603b12cbeddc48ba082472fb4c99316002ec66dd4955fcac7de576ac257c524`.
