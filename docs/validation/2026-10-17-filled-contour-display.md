# SketchUp 2017 fill-only contour display: bounded native validation

Version 3.7.174/r22 preserves editable Glyphs/Geometry faces, counters, edges and
glyph units while hiding redundant fill-boundary ink only when original PDF and
SVG paint evidence affirmatively establish fill-only text. Genuine or unknown
text strokes, uncovered/open edges and standalone/page paths remain visible.
Hidden boundaries can be selected through **View > Hidden Geometry**.

The exact built/tested source was `fc593cecdf3a07502ea7f1b4588dd49ca33fb552`,
tree `a14ffb52344289df200716bb4e5e8bd5b7ee6c87`. The 27,707,904-byte, 651-member
RBZ has SHA256 `e675989f4661f02bb8c964d85a2b7646ace78dbc5bed8a3a377af2267e452d1c`.
The later `c1ea99f` correction changes CI test assertions for old Minitest only;
it does not change the installed/tested product payload.
The immutable build identity retains its original build-time pending-check
entry; the dated native acceptance supplies the completed check status.

The complete accepted cases are Glyphs `su174-glyphs-r3` and Geometry
`su174-geometry-r1`. In each, the operator used ordinary import, Save As, exactly
one Undo, then File Open and Save As in a fresh SketchUp 2017 Make process.
Save did not replace the first Undo Import PDF Vectors operation, and one Undo
restored the empty baseline. Fresh opens showed no repair prompt. All four native
roots exited normally with their retained owned-process handles closed.

Both saved-stage captures had global `EdgeDisplayMode == 1`, with identical
rendering options after reopening. The operator observed thin horizontal,
vertical and slanted letters plus the visible rectangular page border at both
stages. Independent physical checks bound source paint, provenance and persisted
visibility to actual native face-loop/edge topology and world placement.

| Check | Glyphs | Geometry |
|---|---:|---:|
| Source owners / glyph placements | 8 / 23 | 8 / 23 |
| Native filled faces / counters | 23 / 9 | 23 / 9 |
| Hidden attached boundaries | 640 | 640 |
| Hidden exact loose duplicate boundaries | 0 | 32 |
| Separate visible page-border edges | 4 | 4 |
| Literal source session-entity-ID differences | 7,372 | 6,795 |
| Literal page-peer session-entity-ID differences | 42 | 42 |

Primary and derived geometry, placement, material and topology were literally
equal across each save/reopen pair. Raw IDs were retained rather than normalized
away; the different SKP file hashes are also retained. Finite opaque/transparent
source-interior samples in horizontal, vertical and slanted regions had zero
missing or extra ink. These finite samples do not establish analytical cubic
outline equality or whole-viewport parity.

Failures remain visible. Glyphs-r1 used the original source path instead of the
request-bound case path; Glyphs-r2 fresh failed a retained descendant image query
before baseline/open, so the entire case was repeated as r3. The Geometry strict
offline checker initially expected bare action arrays and a `resaved.json` UI
receipt; the actual metadata wrappers and `saved.json`/reopened title were checked
in a separate explicit supplement. Its window/tree/screenshot/hash/ownership gates
were retained, and early menu actions remain explicitly declared but unlogged.
No original owner failure was rewritten or promoted.

The existing report can include a generic impossibility reason even for
successful same-mode delivery. Both new cases retained requested/delivered mode,
`degraded=false`, `fallback.used=false`, and empty fallback transitions. This is
an acknowledged report wording ambiguity; no report-reason fix is in the payload.

Historical v3.7.173/r21 Text/Labels, foundation 3D Text and Raster checks remain
identified as 173 evidence. Text/Labels each used 8 truthful capability fallbacks
to native 3D Text geometry on 2017 Make; those finite structure/placement/depth/
material/persistence/sample checks do not prove general text-string editability
or certify 174. Full meshes, literal differences, PDFs and SKP files stay in
hash-bound private evidence, with compact summaries only in test delivery.

This validation covers one authored 8-span/23-glyph fixture. Other PDFs, newer
hosts, exact cubic outlines, whole-page viewport equivalence and general string
editing remain separate checks. No release is dispatched by this record.

## Source and CI verification

The paint guard uses a bounded original-stream inspection and one compact cached
page proof. It does not add a parser, renderer process or PDF hash per text item.
Forms, unsupported graphics state, Type3 fonts, annotations and uncertain paint
leave contours visible. Glyph component cache identity includes the policy;
actual SVG bytes and page identity must match the proof before hiding a boundary.
Exact loose duplicates require the same native collection, owned Face/glyph/
placement, endpoints and effective style. No edge or vertex is erased or moved.

The actual-repository required and focused matrix passed 20 runs across Ruby
2.2.4 and 3.4.4. The source-only matrix passed 16 runs and six syntax checks,
including original PDF paint negatives and dense-stream allocation bounds.
Actual retained Geometry replay passed four tests/3,357 assertions on each Ruby.
These source checks supplement the separate exact-package native results above.

Initial hosted Ruby 2.2.4 smoke failed because its official bundled Minitest
5.4.3 matches exception classes exactly; local Minitest 5.15 accepted subclasses.
The precise test correction asserts RuntimeError for a failing native setter,
ContractError for ignored hidden-state readback, their exact messages and absent
success-policy metadata. Actual-repository confirmation passed 17 tests/124
assertions with official Minitest 5.4.3, isolated 5.15 and Ruby 3.4.4/default 5.25.
No product or CI dependency change concealed that failure.

## Bound acceptance references

The local updated test guide is
`C:/BlueCollar-Test-Builds/2026-10-12/SketchUp-r22-candidate/READ_ME_FIRST.txt`.
Its `NATIVE_ACCEPTANCE_2026-10-17.json` links compact owners, root observations,
physical gates, historical results and preserved failures. Original build
identity and both RBZ aliases retain their original bytes.

- Four-stage lifecycle rollup:
  `C:/BlueCollar-Validation/Checks/su174-both-modes-integration-20261017-r1/FINAL-ALL-FOUR-STAGES.json`,
  SHA256 `fd343a25b9e00e0b21a082a441620263ef9d2ec1550ff6162d9fd48b1bd53819`.
- Glyphs physical gate:
  `su174-glyphs-r3/Evidence/independent-mode-full-r1/COMPACT-FINAL-GATE.json`,
  SHA256 `41542421d365fa35e268d7561f0a5d822cf9e40bba2d84e66b33064dc3655ff8`.
- Geometry physical gate:
  `su174-geometry-r1/Evidence/independent-mode-full-r1/COMPACT-FINAL-GATE.json`,
  SHA256 `cde9420c83782f6bbddfccc1c3924468cb7857e424aaf443949d1f7cad37c13d`.
- Root display receipt:
  `C:/BlueCollar-Validation/2026-10-17/ROOT-DISPLAY-174-20261017-r1.json`,
  SHA256 `bdde91acebe12fa709224f4074985b740d757e7e823b77dc09c4b06a9fdfad47`.
- Actual repository assertion confirmation:
  `C:/BlueCollar-Validation/Checks/su174-ci-actualrepo-contour-confirmation-20261017-r1/CONFIRMATION.json`,
  SHA256 `3963352e561c7e14c344c4cd32a272ac579b5f4dc110c77cc5ef7ef4e71389db`.

Relative case references above resolve under
`C:/BlueCollar-Validation/2026-10-17`. Large native captures and literal differences
remain private; these hashes identify retained evidence, not portable attachments.
