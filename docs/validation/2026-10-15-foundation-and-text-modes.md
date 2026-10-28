# SketchUp 2017 foundation and text-mode checks — 2026-10-15

The installed **3.7.170 / r17** candidate completed the foundation drawing's
ordinary-menu import, Save As and separate fresh-process Open/resave checks.
Its **single Undo after saving remains failed**: SketchUp placed **Check
Validity** above the import in the Undo stack. The mixed horizontal/rotated
fixture completed ordinary-menu **Text** import, Save As and one Undo, followed
by a separate fresh-process Open/resave. The same fixture also completed the
requested **Labels**, **3D Text**, **Geometry** and the fresh **Glyphs r2**
retry's menu import, Save As and single Undo, followed by separate fresh-process
Open/resave checks for each mode. Raster also completed those lifecycle operations, but its visible slanted-
text gaps remain an unresolved visual failure. Raster mode is **not accepted**
by that lifecycle pass. This record extends [the earlier lifecycle checks](2026-10-15-ordinary-menu-lifecycle.md)
and preserves their results and original evidence.

The host was **SketchUp Make 2017 17.2.2555 / Ruby 2.2.4** on Windows. An operator
used the ordinary import dialog, File > Save As, Edit > Undo and File > Open.
The startup observer only recorded lightweight native inventories, transaction
callbacks and actual report bytes; it did not import, save, Undo or close the
application. Each guided stage allowed **1,800 seconds** for operator/tool
round trips, with a separate **hard 60-second deadline per diagnostic capture**.
Pipeline times below exclude later operator handling and saving. Tests used new
model copies and retained the original PDFs and pre-existing drawing fixture.

## Exact candidate

| Identity | Value |
|---|---|
| Runtime source commit | `a340c91c210403e81214490465598f1cc39a6676` |
| Source Git tree | `7cd7fd294284fef330dcd9fc70435081bcc9c084` |
| RBZ | `SketchUp-PDF-Importer-TEST_v3.7.170_2026-10-15-r17.rbz` |
| RBZ SHA-256 | `34fb03b8ce72ea505372380beac581c4ce85b61b704942edb822aeba64539adf` |
| Test-build identity SHA-256 | `c1f5f47bbda25adf20f3c574b6613b5064f2b5d5d1cfe93c34d151db70aab923` |
| Expected source-payload manifest SHA-256 | `e943f5e7e464ba0196e769d2db774d40649f4e8c359a4761ad579de5c894ebd7` |

The package is under
`C:/BlueCollar-Test-Builds/2026-10-12/SketchUp-r17-candidate/`.
The bound request verifies its **650 installed files** against the exact RBZ.
Version 3.7.170 changes reporting plus loader/metadata versions; the tested
geometry implementation remains the same as r16. These checks do not publish
a release or establish compatibility with every PDF, setting or host release.

## Foundation drawing, requested 3D Text

Source: private foundation sheet F1 (file name and SHA-256 kept in private evidence).
Evidence root: `C:/TMP/su170-fm-foundation-3d-20261015-r1`.

- Native PID **17604** completed the ordinary import in **220.3 seconds**. The
  actual report records **one page**, **31,983 vector primitives**, **41,412
  edges**, **286 source-outline 3D Text items**, one PDF layer and one embedded
  image. Five qualified blank source spans containing **32 space characters**
  were retained without creating pictures. No text raster fallback, failed
  page or fill-delivery failure was reported.
- The title-block scale resolved to **3/4 inch = 1 foot**, factor **16**, with
  reported confidence **98%**. This is the importer scale result, not an
  independent dimensional survey of the saved model.
- Ordinary Save As passed. The imported and saved lightweight inventories
  matched exactly. The new page retained **312 direct children**, alongside
  the original fixture.
- The first subsequent Undo was labeled **Undo Check Validity**. It consumed
  one transaction but left the foundation sheet and captured inventory intact.
  The combined menu owner therefore retains `execution_passed: false` and a
  **FAIL** for exact single-Undo baseline restoration, while its separate
  `import_save` outcome is **PASS**.
- After that immutable failed capture, the separately observed second command,
  **Undo Import PDF Vectors**, removed the foundation. Zoom Extents showed the
  original fixture. That observation does not replace the failed first Undo.
  Declining to save the later Undo changes preserved the imported model.
- Separate native PID **6908** opened the saved model through File > Open,
  displayed the sheet, saved a new copy and closed normally. Its fresh-open/save
  outcome passed with verified owned exit and no observed repair prompt.
- The strict saved-to-fresh comparison remains **FALSE**: exactly **321
  `entity_id` fields** changed, while persistent IDs and every other captured
  field matched. The strict fresh-to-resaved comparison was **TRUE**. No raw
  result was normalized into a pass.

Transaction callbacks show one import commit before saving and one additional
commit during the save workflow. The importer does not call a Check Validity
operation. The lightweight evidence establishes the extra Undo step but does
not identify which deeper geometry or internal bookkeeping the host checked.
No geometry repair or suppression of host validation is justified by these
captures alone. The earlier r16 foundation time of **214.3 seconds** remains a
separate historical run.

The report's embedded-image paint-order record remains **unqualified** because
the clip is not one four-corner contour. The separate native TextureWriter
checks below establish this image's saved/reopened pixels and subtree
persistence. They do not qualify its clipping or certify full-page rendered
parity, text/vector geometry or the failed single Undo.

### Foundation embedded image — saved/reopened physical checks completed

Evidence root: `C:/TMP/su170-pixels-foundation-20261015-r2`. Separate native
processes opened the exact ordinary-menu saved models identified above; this
read-only diagnostic did not import, save, Undo or mutate either model.

- Native PID **31040** opened `Output/imported.skp`; PID **32920** opened
  `Output/reopened.skp`. Both loaded the foundation sheet without an observed
  repair prompt, completed the image capture, closed normally and verified
  owned exit. Both physical-image owners passed. The captures took **3.847**
  and **3.271 seconds**, respectively, within the separate 60-second deadline.
- A real SketchUp TextureWriter exported the actual **401 × 251 RGB Image**
  in each session. Each successful export was **9,419 bytes**. Independently
  decoded canonical pixels matched the original **7,978-byte PNG**, with
  identical dimensions and visual-pixel SHA-256
  `afd22ac27135972a067cb5c7d3e44099d9445715394496d79517cecfef8f755a`.
  The original encoded PNG SHA-256 is
  `e829f8bb9e24e25515c0b82445c11d59a20e79d39f42258520eb6a739a6b6e66`.
  Source binding identifies the exact PDF, page **1**, object **15** and
  placement **1**; encoded PNG equality was not required of the host export.
- Image persistent ID **228223**, ancestor group persistent ID **7918**,
  ancestor properties and transformations, and the complete world image
  transformation matched. The raw physical-row comparison remains **FALSE**:
  only its session-local `entity_id` changed, from **416211** to **416239**.
  The reopened capture separately records physical and ancestor persistence
  as verified; the raw equality result is preserved.
- Both models were unmodified before and after the capture, and the diagnostic
  left product features unchanged. This is acceptance of **one embedded
  image's actual pixels and subtree persistence**, not full-page or full-delivery
  certification. Foundation single Undo remains **FAIL**, and the unrelated
  mixed-fixture Raster visual defect below remains unresolved.

## Mixed horizontal/rotated fixture, requested Text

The fictional fixture `mixed-rotated-modes.pdf` has SHA-256
`5d0f7d3c428a782e51aa0f05d4cdb04b1248416fc20b0c090c28bb0c03c1538e`.
Its three authored text-show operators use **0°, 90° and 30°** baselines and
share the page with a border, an L path, a blue filled rectangle and one color
Image XObject. The external extractor divides those three runs into **eight
source spans**; eight spans must not be described as eight PDF text-show
operators. Evidence root: `C:/TMP/su170-rm-mode-text-20261015-r1`.

- In native PID **5432**, the import dialog selected **Text**. The import took
  **7.1 seconds** and retained one page, three vector primitives, six reported
  edges and all eight source text spans, with zero failed or unaccounted spans.
- The actual delivered representation was **eight source-outline 3D Text
  items**, not distinct flat editable model Text or native annotation Labels.
  The report's renderer record and per-item log warnings explicitly record
  **Text → 3D Text**, reason `host_representation_unsupported`. The item-bound
  capability observation identifies the missing distinct flat editable model
  Text API. This is not a rotation-only fallback and does not excuse a
  transform bug. The report records source-glyph identity and positive depth;
  this lightweight observer does not independently evaluate their geometry.
- One embedded image was placed. Its source paint-order record has one
  qualified image and no unqualified entries. No item-image text fallback,
  omitted inline image or failed page was reported. Physical saved/reopened
  image pixels remain a separate acceptance check.
- No drawing scale was detected. The report retained a **1:1 default** and its
  explicit verify-scale warning; the fixture is not an independently measured
  takeoff reference.
- Ordinary Save As retained the imported lightweight inventory. One ordinary
  **Undo Import PDF Vectors** restored the original fixture inventory exactly.
  The menu owner passed, with verified owned exit. The operator observed the
  horizontal, vertical and slanted source words, fill, paths and color image.
- Separate native PID **32836** opened the saved model with the ordinary File
  Open command, displayed the rotated words, fill, paths and embedded image,
  saved a new copy and closed normally. Its fresh-open/save outcome passed with
  verified owned exit, process exit code zero and no observed repair prompt.
- The strict saved-to-fresh inventory comparison remains **FALSE**: exactly
  **21 `entity_id` fields** changed. Persistent IDs and every other captured
  field matched. The strict fresh-to-resaved comparison was **TRUE**. These
  lightweight results do not establish full evaluated geometry or visual parity.

## Mixed horizontal/rotated fixture, requested Labels

Source fixture and SHA-256 are the same as the Text case. Evidence root:
`C:/TMP/su170-rm-mode-labels-20261015-r1`.

- Native PID **31556** selected **Labels** in the import dialog and completed
  import in **6.6 seconds**. The actual report records one page, three vector
  primitives, six reported edges and all eight source spans delivered, with
  zero failed or unaccounted spans.
- The delivered representation is **eight source-outline 3D Text items**, not
  native editable annotation Labels. Every span has an item-bound **Labels →
  3D Text** capability transition, reason `host_representation_unsupported`.
  Six finite-bbox span proofs report
  `label_source_size_unsupported_by_host`: native `Sketchup::Text` lacks
  source glyph-size and run-width controls. Two report
  `label_rotation_unsupported_by_host`, with observed source angles **−90°**
  and approximately **−30°** in the extractor's coordinate convention;
  `Text#vector` controls a leader rather than label-glyph rotation.
- These affirmative capability transitions precede native annotation creation;
  they do not jump directly to pictures or establish a transform workaround.
  The report records source-glyph identity and positive Z depth. The lightweight
  observer does not independently evaluate the glyph geometry.
- One embedded image was placed, with one qualified source paint-order entry
  and no unqualified entry. No item-image text fallback or failed page was
  reported. The **1:1 default** and explicit verify-scale warning remained.
- Ordinary Save As passed and retained the imported lightweight inventory.
  The first Undo was **Undo Import PDF Vectors** and restored the original
  fixture inventory exactly. The menu owner passed, the process closed normally
  and owned exit was verified. The operator observed the horizontal, vertical
  and slanted words, blue fill, paths and color image.
- Separate native PID **17444** opened the saved model with the ordinary File
  Open command, displayed the horizontal, vertical and slanted words, paths,
  fill and color image, saved a new copy and closed normally. Its fresh-open/save
  outcome passed with verified owned exit and no observed repair prompt.
- The strict saved-to-fresh comparison remains **FALSE**: exactly **21
  `entity_id` fields** changed. Persistent IDs and every other captured field
  matched. The strict fresh-to-resaved comparison was **TRUE**. These scoped
  lifecycle results do not certify saved/reopened image pixels or full visual
  parity.

## Mixed horizontal/rotated fixture, requested 3D Text

Source fixture and SHA-256 are the same as the Text/Labels cases. Evidence root:
`C:/TMP/su170-rm-mode-3d-20261015-r1`.

- Native PID **32740** selected **3D Text** and completed import in **9.1
  seconds**. The report records all eight source spans as source-outline 3D
  Text in the requested mode, with source-glyph identity and positive Z depth.
  No capability transition, item text raster, failed page or unaccounted span
  was reported. One page, three vector primitives, six reported edges and one
  embedded image were retained; image paint order has one qualified entry.
- Ordinary Save As retained the imported lightweight inventory. One **Undo
  Import PDF Vectors** restored the original fixture inventory exactly. The
  menu owner passed, the process closed normally and owned exit was verified.
- Separate native PID **29064** used ordinary File Open, displayed the rotated
  words, fill, paths and color image, saved a new copy and closed normally.
  Its fresh-open/save outcome passed with verified owned exit and no observed
  repair prompt.
- The strict saved-to-fresh comparison remains **FALSE** on exactly **21
  `entity_id` fields**, while persistent IDs and every other captured field
  matched. Fresh-to-resaved raw inventory equality was **TRUE**. These captures
  do not independently certify glyph geometry, image pixels or full-page parity.

## Mixed horizontal/rotated fixture, requested Geometry

Source fixture and SHA-256 are the same as the earlier mixed-mode cases.
Evidence root: `C:/TMP/su170-rm-mode-geometry-20261015-r1`.

- Native PID **25556** selected **Geometry** and completed import in **5.6
  seconds**. The report records all eight source spans as **page-path geometry**
  in the requested mode, not 3D Text. It records three page vector primitives,
  **678 edges** and one embedded image. No capability transition, item text
  raster, failed page or unaccounted span was reported.
- Ordinary Save As retained the imported lightweight inventory. One **Undo
  Import PDF Vectors** restored the original fixture inventory exactly. The
  menu owner passed, the process closed normally and owned exit was verified.
- Separate native PID **26760** used ordinary File Open, displayed the
  horizontal, vertical and slanted text outlines, blue fill, border, L path and
  image, saved a new copy and closed normally. Its fresh-open/save outcome
  passed with verified owned exit and no observed repair prompt.
- The strict saved-to-fresh comparison remains **FALSE** on exactly **14
  `entity_id` fields**, while persistent IDs and every other captured field
  matched. Fresh-to-resaved raw inventory equality was **TRUE**.
- The original encoded **24 × 16 RGB PNG** and its metadata were retained
  before closing the import session, with matching recorded bytes and hashes.
  That retention receipt is **not physical host-image acceptance**. Real
  saved/reopened TextureWriter pixel checks and evaluated-geometry checks
  remain separate.

## Mixed horizontal/rotated fixture, requested Glyphs — r2

Source fixture and SHA-256 are the same as the earlier mixed-mode cases.
Evidence root: `C:/TMP/su170-rm-mode-glyphs-20261015-r2`. This is a fresh run;
the initial r1 harness failure below remains unchanged.

- Native PID **8796** selected **Glyphs** and completed import in **5.2
  seconds**. The report records all eight source spans as **glyph-outline
  items** in the requested mode, with three page vector primitives, **646
  edges** and one embedded image. No capability transition, item text raster,
  failed page or unaccounted span was reported. The report's
  `source_glyph_identity_verified` flag for this delivery is **false**; these
  results do not add an independent source-glyph certification.
- Ordinary Save As retained the imported lightweight inventory. One **Undo
  Import PDF Vectors** restored the original fixture inventory exactly. The
  menu owner passed, the process closed normally and owned exit was verified.
- Separate native PID **13396** used ordinary File Open, displayed the
  horizontal, vertical and slanted outlines, fill, paths and color image,
  saved a new copy and closed normally. Its fresh-open/save outcome passed
  with verified owned exit and no observed repair prompt.
- The strict saved-to-fresh comparison remains **FALSE** on exactly **14
  `entity_id` fields**, while persistent IDs and every other captured field
  matched. Fresh-to-resaved raw inventory equality was **TRUE**.
- The original embedded PNG and metadata were retained before closing, with
  matching encoded bytes and hashes. The retention receipt explicitly records
  **original bytes only**, not physical saved/reopened host-image acceptance.

## Mixed horizontal/rotated fixture, requested Raster — visual unresolved

Source fixture and SHA-256 are the same as the earlier mixed-mode cases.
Evidence root: `C:/TMP/su170-rm-mode-raster-20261015-r1`.

- Native PID **18716** selected **Raster** and completed import in **6.5
  seconds**. The report records **eight item raster images**, one for each
  extracted source span, plus one embedded image, three page vector primitives
  and six reported edges. This is requested **item Raster**, not a whole-page
  image or a vector-to-raster fallback. The accounting reports zero failed or
  unaccounted spans, but its claims do not replace visual or physical acceptance.
- The operator observed **white gaps in the slanted text before saving**.
  Those gaps **persisted after fresh reopening**. Horizontal/vertical text,
  paths, fill and color image were visible. This establishes an unresolved
  visible defect; **Raster visual acceptance remains failed/pending repair**.
- Ordinary Save As retained the imported lightweight inventory. One **Undo
  Import PDF Vectors** restored the original fixture inventory exactly.
  Separate native PID **29976** used ordinary File Open and Save As without
  a repair prompt. Both lifecycle owner stages passed, closed normally and
  verified owned exit. Those outcomes certify only their recorded lifecycle
  operations, not Raster mode fidelity.
- The strict saved-to-fresh comparison remains **FALSE** on exactly **21
  `entity_id` fields**; persistent IDs and every other captured field matched.
  Fresh-to-resaved raw inventory equality was **TRUE**. Matching inventories
  do not remove the observed white gaps.
- Attempted original-crop retention failed with `FileNotFoundError` while the
  import host was still open, before an output retention receipt was created.
  The importer had already deleted its temporary item crop files. **No original
  item crop PNGs were retained, and no physical Raster request was prepared**.
  Report fields and saved Image attributes are not TextureWriter pixel proof.
- A crop/display rounding mismatch is under repair in a separate source change.
  No corrected package or successful native retest is claimed by this record.

## Preserved Glyphs harness failure

The first Glyphs run, `C:/TMP/su170-rm-mode-glyphs-20261015-r1`, failed **before
import** while its operator-signal JSON was being published. The owner reports
`Expecting value: line 1 column 1 (char 0)`, `stage_completed: false` and no
import/save outcome or saved model. Its owned process PID **12084** required
forced cleanup; owned exit was verified. The failed receipt and all **18
original run files** remain preserved. This is a test-harness failure, with
**no Glyphs product result**. The new r2 request uses a fresh run root and
atomic signal publication; its separately completed outcomes are recorded in
the Glyphs r2 section above. That retry does not reclassify the failed r1 run.

## Remaining acceptance work

All six requested mixed-fixture modes now have completed lifecycle runs,
including the separate successful Glyphs retry. **Raster visual repair and
retest remain pending**; its lifecycle pass is not a fidelity acceptance.
The foundation embedded image's saved/reopened physical check is complete as
scoped above. Other physical-image checks and evaluated-geometry acceptance
remain separate, incomplete work. Requested item Raster and saved/reopened image acceptance require real
TextureWriter exports with successful files, decoded canonical RGB/RGBA pixels
and matching dimensions; importer attributes and PNG headers are insufficient.
Current SketchUp-release coverage, other PDFs/settings and full-page visual
comparisons remain separate work.

## Immutable local evidence bindings

The following SHA-256 values bind the actual local request, copied import report
and finished owner receipts. Model hashes are the physical saved files, not a
claim that two SketchUp files must be byte-identical across sessions.

| Foundation evidence, relative to its evidence root | SHA-256 |
|---|---|
| `request.json` | `afc5b68ee656776fcf60d0614dd28cdb3761651d2f8de95f9503054ad0da8588` |
| `Evidence/menu-imported-actual-import-report.json` | `d558fe29116537aa1d924ad49070cc68c28c2440a86da53b829fa7ba4f4e44b3` |
| `Evidence/menu-owner.json` — single Undo FAIL retained | `832d3a2b8f8e32ef95b68f6120f82e4e70077c96272626d09d7fb8e1b9ae73f5` |
| `Evidence/fresh-owner.json` — fresh Open/save PASS | `377c35fac101ef2f49c29c4f6b456e695366f8ef346d61c11105ba52bb856b40` |
| `Output/imported.skp` — 15,958,188 bytes | `d7bfa383dfa493b3bb97c96b355a1cd008c68619877b573939bbccd2bd1dedbf` |
| `Output/reopened.skp` — 15,974,024 bytes | `af6204dbc2c0c2c8e03e4f259b57aeb6261d810953ed4f09569354bd6c0ed27b` |

| Foundation image evidence, relative to its separate physical-check root | SHA-256 |
|---|---|
| `request.json` | `632b10d079040ddeefaf26e44b6552b8f9847cbca5e1c32a5cbecdee5b236dff` |
| `Evidence/saved-image-000.json` — actual saved Image pixels | `a147b867ac04ea9e28bdc460807e9ed3059b85218492fc7fba2fa33a37f20c52` |
| `Evidence/reopened-image-000.json` — actual reopened Image pixels/persistence | `0f42cf8d9a07e5df04d46b0eec355c999fd93eeec2b6d37bb88eef0d9eb41881` |
| `Evidence/saved-owner.json` — physical check PASS | `8bf072586008f1d4ac89a673dd5a7ca3a6263868c580357fb9b1b7cffb0eced8` |
| `Evidence/reopened-owner.json` — physical check PASS | `6a93036f0457408dfa1ab2b863733389fe99adc46f34be3187100f7da5f77f47` |

| Text evidence, relative to its evidence root | SHA-256 |
|---|---|
| `request.json` | `fccc3091321982a86d140d8beec0e6eeb3e40e2cbb63071c7936e4d27c687669` |
| `Evidence/menu-imported-actual-import-report.json` | `5a232fc5c5d2ee88e416008dcf68a9779e1ec65b6fc9cc96d321fcc129a217cc` |
| `Evidence/menu-owner.json` — import/save/single Undo PASS | `3b55bdcba8ee393c8a2fe4386745935ffd756af2bb7ae81248237afa5ebf58e1` |
| `Evidence/fresh-owner.json` — fresh Open/save PASS | `b1244fbfed639ac64b07f0d63aa236e698cd1bfd776eb73ad5a518a5c5aba557` |
| `Output/imported.skp` — 823,148 bytes | `75b4ee09c2d9b5fe25fe6a9e954aa053c40dd6d69c99e0dbc8d25b7f563f46bd` |
| `Output/reopened.skp` — 823,148 bytes | `b22288d2334284154756ccff27c95b076f2c8c2e36541adc8f1bdc2bfaa94027` |

| Labels evidence, relative to its evidence root | SHA-256 |
|---|---|
| `request.json` | `ca81e8bfb67fb4d479594a0d369af9c88687bb668b569274605d9c52bc589f69` |
| `Evidence/menu-imported-actual-import-report.json` | `aa2014b97690ded81bfbfb94bd7a6f4247d4aa888e9b783f71711d058d8e2410` |
| `Evidence/menu-owner.json` — import/save/single Undo PASS | `3145f8d9a97bb60617db904a0afe3d4cd7c69437ba11901dd3ff55b45f994192` |
| `Evidence/fresh-owner.json` — fresh Open/save PASS | `0551ab75034c96671f237209c3de1ec0a40a0116fdae189074ff4844960433fc` |
| `Output/imported.skp` — 827,037 bytes | `b16db79829af5fa562bb8293540d937210e8fc90b6ba3461458097d05692df4d` |
| `Output/reopened.skp` — 827,037 bytes | `7b6a78b7970fbcb15dd890818979934e8a2b4989acc659fa70b6422aced38ab9` |

| 3D Text evidence, relative to its evidence root | SHA-256 |
|---|---|
| `request.json` | `9a37f66f638dcdb1157784bed48dfec5d69bb6bd71851caef87450068e7a4e12` |
| `Evidence/menu-imported-actual-import-report.json` | `6ac7aca38ff27ee6f7eee13a50558a2748bfcf2e21c62b5a516bb71ef1e35112` |
| `Evidence/menu-owner.json` — import/save/single Undo PASS | `1dffb1cf8c5b9d86921d717a40432db268b40cb5cd95be71622cc3b7a6834bbc` |
| `Evidence/fresh-owner.json` — fresh Open/save PASS | `7835a4b3ef56f0be48f1b3abbdbe67cf13835374b248ad2468fc5c0b3fccaff5` |
| `Output/imported.skp` — 798,168 bytes | `5e050b59246140a029399e45e4f9eaf885f1f14335c5542b9552ba01761206e0` |
| `Output/reopened.skp` — 798,168 bytes | `7198a0fa9e86c8e9a5fcef42aab98cb16c421737bdb3b59e127c47f708f9c9a6` |

| Geometry evidence, relative to its evidence root | SHA-256 |
|---|---|
| `request.json` | `1a8d9b9928e3f436f51dc6e1269466d74d77e7f1de0bce0b89381c79ea932701` |
| `Evidence/menu-imported-actual-import-report.json` | `be8754685c746d9a8b4be95c8471b4131a34ea66adb9961a7654d6f9872dfc1f` |
| `Evidence/menu-owner.json` — import/save/single Undo PASS | `8676c112c29cc4af806ed46536e9b39676db162dc57d64151738a3d18093630a` |
| `Evidence/fresh-owner.json` — fresh Open/save PASS | `6273854a7dabd5b55dbdccada8e979cf14b10a645b622fa41784e0e3f6fcced0` |
| `Evidence/Retained-image-artifacts-r1/receipt.json` — original bytes retained only | `29c85e366f9b67377bc20eec9359b02bf5fcb3c0184980912e2fb3228ecef28d` |
| `Output/imported.skp` — 913,513 bytes | `f45db301494db2b0e1e130e7e4698968dec9e695efb9f39cce1b64add526d75f` |
| `Output/reopened.skp` — 913,513 bytes | `f0c1bb37d9648b83f260d19c3d2a20b26a65614c0b234024bced9a798f7c4a65` |

| Failed Glyphs r1 evidence, relative to its run root | SHA-256 |
|---|---|
| `request.json` | `6306c25c82de78c4515e32b54abe91385f68f772791a8f27036b3affdf0656ca` |
| `Evidence/menu-owner.json` — harness failure before import retained | `07d629049dde4b13691380656a5b345c6d5da628ad99e5f8c89898dbcf77b8db` |

| Glyphs r2 evidence, relative to its evidence root | SHA-256 |
|---|---|
| `request.json` | `7805c7ab2bd72ee970b847793e26f62124b5532ab19f53614f1904ff688b3439` |
| `Evidence/menu-imported-actual-import-report.json` | `ba9520816f6a4199bea1c33ce7147ce8a9872b49edf63ef34f00f16306af2b00` |
| `Evidence/menu-owner.json` — import/save/single Undo PASS | `e7568cbfdea8a75c2aea764f335ef3ccf497f0509c6587a5ca01c0e328d0b707` |
| `Evidence/fresh-owner.json` — fresh Open/save PASS | `233aab450bc1643b5ff5f0294b52a05eb66050d3c435f734d827fac28eedc5b0` |
| `Evidence/Retained-image-artifacts-r1/receipt.json` — original bytes retained only | `33e2078905bcadab0c656ef3c97e1d5d026f57b55c2f098d9f6003247599ceb3` |
| `Output/imported.skp` — 868,313 bytes | `f63495725e9b3526925ece1c55405b2c758a36857c46f2fabfb07ba6e7ea9756` |
| `Output/reopened.skp` — 868,313 bytes | `e79e33d63fcd231679c63984e241977bc33638e1e6a7fb1eb321dabee16d5728` |

| Raster evidence, relative to its evidence root — lifecycle only; visual unresolved | SHA-256 |
|---|---|
| `request.json` | `f88f07d8a79d922ba25e7248e5127cbc13c9923c761a03c9cb1a36b6b53179e6` |
| `Evidence/menu-imported-actual-import-report.json` | `dbd699a64212277012eec4d333874ae13a79db329cfe1388499af71450e27a32` |
| `Evidence/menu-owner.json` — lifecycle PASS; visual defect retained in root observation | `d1bd0b289a37a3dd2b07e8397bd5735aba0ed478d1f972800659a8b63bbbb47f` |
| `Evidence/fresh-owner.json` — lifecycle PASS; persistent white gaps observed | `1312437d92f001f086372fd7a8c75ea580a74e7570f86bd1f63c8b3152df09ff` |
| `Output/imported.skp` — 574,009 bytes | `0fbc4ec9c46437ff40e560aff5bf1520b9cfd7495985cc3d8b9b7c3d2f4cd5c6` |
| `Output/reopened.skp` — 574,009 bytes | `b6bc033958bf1bd80d91e28b7be68ad741ec336a922c542d9a273b27cc1750de` |
