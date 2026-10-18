# PDF Vector Importer for SketchUp

**BUILT. NOT BOUGHT.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-3.7.180-green.svg)]()
[![Platform](https://img.shields.io/badge/Platform-SketchUp%202017%2B-orange.svg)]()
[![Ruby](https://img.shields.io/badge/Ruby-2.2%2B-red.svg)]()

Import PDF vector geometry as native editable SketchUp edges with arc reconstruction, color-based tag grouping, text import, dash patterns, Scale by Reference tool, and full Bezier support.

### Unattended multi-page import

A multi-page import asks its questions up front (the import options dialog, plus the one-time very-large-file warning) and then runs to the end without stopping. Large pages no longer raise a per-page OK/Cancel box; they are logged and listed in the end-of-import summary. A page that fails is logged and skipped, the remaining pages still import, and a later resume retries it. When the import finishes, one status-bar line names the pages imported, any page delivered as a raster image (with the reason), and any failed page; Extensions > PDF Vector Importer > Import Health... has the full summary.

### Page selection

Use `All`, a page number, or ascending ranges such as `1,3-5`. Invalid
selections name the problem instead of importing the entire PDF or silently
omitting requested pages. Ranges remain compact until the PDF page count is
known, so an accidental range such as `1-1000000000` stops before allocating
millions of page entries. Dialog, headless CLI, batch analysis, and host import
use the same validation.

### Recent fixes (v3.7.180)

- White-area refinement can build retained cells together while checking every
  cell boundary, source area and shared edge. A rejected mesh is removed and
  checked before isolated construction is retried. Original fills stay editable;
  requested text modes and construction limits are unchanged.
- Picture clipping or overlap concerns already recorded in detailed diagnostics
  now appear in the import summary and Import Health. The white-area warning
  also uses the correct punctuation.
- The full foundation drawing completed ordinary import, Save As, one Undo,
  fresh Open and resave in SketchUp Make 2017: 939.1 seconds for Glyphs and
  171.1 seconds for 3D Text. Glyphs retained the selected 505 white faces
  and their shared boundaries; both modes retained all 16 final annotations.
  The 3D text census retained 286 owners with positive 1/64-inch depth, caps
  and side walls.
- Two Glyphs white-area checks and picture clipping remain unresolved and are
  reported. Its full graph/census exceeded the existing diagnostic limit;
  strict derived Face measurements also differed after 3D Text was reopened.
  The [completed validation notes](docs/validation/2026-10-18-mask-performance-and-text-height.md#completed-v37180-host-checks)
  separate these limits from the successful lifecycle and selected source checks.

### Recent fixes (v3.7.179)

- Exact white-area classification sweeps the complete source contours once per
  partition slab instead of repeatedly testing every contour for each cell.
  Existing limits, paint ownership, holes and exact cell boundaries remain.
- Partially retained fills construct only the visible native cells. Full source
  coverage, construction clearance, native boundaries and rollback stay checked.
- Import logs flush sparse mask progress records, including the current phase,
  to make a long refinement diagnosable. The user-facing warning explains the
  remaining visual limitation; technical details stay in the structured report.
- The preceding v3.7.178 foundation test passed the 3D Text import, save, Undo and
  reopen lifecycle and the scoped annotation-height checks. Its flat Glyphs test
  expired at the unchanged 30-minute stage limit. The v3.7.179 follow-up also
  expired in Glyphs; its 3D Text lifecycle and 16 final-annotation height checks
  passed within their stated scope. Strict recomputed Face measurements still
  differed after reopening. See the dated validation notes for the exact limits.

### Recent fixes (v3.7.178)

- A verified white-area partition with no ink to remove keeps the original
  editable shapes without constructing replacement faces.
- A white-area failure whose local cleanup succeeds is reported while later
  areas continue. Cancellation, changed resume data and uncertain cleanup
  remain terminal. Earlier successful repairs and independent annotation
  height checks remain intact.

### Recent fixes (v3.7.177)

- When a planar fill needs an excessive construction scale, one perpendicular
  partition attempt can avoid unnecessarily thin internal cells. It maps every
  cell back to the original coordinates and retains the existing native
  geometry, coverage and rollback checks. It does not round away source detail
  or raise the construction limits.

### Recent fixes (v3.7.176)

- Opaque-fill matching can now verify separate filled regions that touch at an
  exact corner. It retains every component and counter, and keeps the existing
  shape, colour and paint-order checks.
- Final annotations retain the measured native text height when a later
  opaque-fill check fails. Verified raster crop exclusions also remain checked;
  incomplete inventories are still reported explicitly.

### Recent fixes (v3.7.175)

- Successful Glyphs and Geometry deliveries no longer carry a misleading
  impossibility reason when they match the requested mode. Actual step-downs
  keep their reason and transition records. This changes reporting only.
- Distinct page simplifications now count as warnings. When a page has these
  limitations, abundant vector content no longer produces a misleading high
  review classification; the report requests comparison with the PDF.

### Recent fixes (v3.7.174)

- Glyphs and Geometry suppress extra SketchUp contour ink when the original
  page and source SVG establish fill-only text. Filled letter faces, counters,
  edges and vertices remain editable. Genuine strokes and uncertain paint
  retain their contours; the import report records that choice.
- Host-created closure edges and exact duplicate fill boundaries use their
  actual source-owned faces and native coordinates. The repair preserves
  topology and the model's display settings. View > Hidden Geometry reveals
  hidden boundaries for editing.
- The [v3.7.173 other-mode checks](docs/validation/2026-10-17-other-text-modes.md)
  document the ordinary-menu lifecycle results and the display issue that led
  to this repair. New package results are recorded separately.

### Recent fixes (v3.7.173)

- Geometry cleanup finishes by removing redundant loose edges only when they
  share the same native vertices, exact coordinates and appearance. Face edges,
  curves, attributed edges and disconnected coincident strokes stay intact.
  This addresses duplicate edges that SketchUp 2017 removed during Save,
  adding a separate Check Validity operation ahead of Undo.

### Recent fixes (v3.7.172)

- Item Raster crops include matched source glyph outlines, preserving
  overhanging and slanted letter strokes. Unqualified source bounds are
  explicitly reported. Font embedding preserves the PDF page orientation.

### Previous fixes (v3.7.169)

- The manual **Extrude Selected Planar Faces** tool keeps both profile caps
  facing outward, including reversed faces and scaled or reflected instances.
  It preserves the caps' physical front/back paint and checks texture placement;
  an unpreserved texture cancels the edit with its reason.
- The tool checks the resulting native cap/side boundaries and closed edge
  connections before committing the edit. An uncertain native correction rolls
  back the operation instead of reporting a completed extrusion.

### Recent fixes (v3.7.168)

- Single filled source contours keep every distinct vertex, including very short
  edges. An identical closing point is removed before the native face call;
  short edges use enlarged construction with an exact inverse scale.
- A filled shape the host cannot create is listed in the report, Import Health
  and completion notice. Other page content stays, and the import does not
  claim complete source geometry. Small or self-intersecting contours are
  never classified as empty just because their signed area is near zero.

### Previous fixes (v3.7.167)

- Empty source TrueType glyphs retain their original text, character positions,
  advances and font identity in the saved page ledger. Blank spaces no longer
  create pictures of neighboring drawing ink or false raster warnings.
- A glyph mapped to a Unicode space keeps its visible source outline and can
  remain 3D text. Unicode whitespace alone cannot prove that a glyph is blank.
- Blank-only pages retain one hidden construction point for their page ledger;
  no visible text solid or picture is claimed. Unsupported or unproved source
  font mappings continue through the existing reported item fallback path.

### Previous fixes (v3.7.166)
- Imports use editable centerlines by default. Advanced **Line widths → Draw source line widths** is an explicit option, saved for subsequent imports and available in the legacy dialog too. Dense sheets or work beyond the time limit retain centerlines and report the limit instead of claiming preserved widths.

- Esc can stop white-mask scanning, source binding, exact intersections and native cell construction. Cancellation removes only the active composition stage before the pipeline rolls back the current page; uncertain cleanup remains a terminal error.
- White-mask composition merges redundant adjacent cells with the same exact region and source owner. Original contours, ink coverage, material boundaries and construction checks remain intact; requested text modes are unchanged.
- Source-unit lookup uses an index, and the source SVG is hashed once for all unit comparisons rather than once per unit.
- Fill/text progress uses plain stage names and the current task's counts; a later mask no longer inherits the earlier mask's 100% or stale ETA.
- Status-bar drawing is limited to one update every two seconds while every progress and cancellation checkpoint still runs. Final import notices remain immediate.
- Shared glyph definitions are scanned once when applying source outline styles; each instance keeps its own placement and material behavior.
- Any failed fill construction verifies removal of its private stage and restoration of source visibility. Uncertain cleanup stops the page commit instead of retaining partial work.
- Exact Ruby 2.2.4 tests cover bounded stroke batches, cancellation and exact partition coverage. Real-host timing and save/reopen acceptance for this candidate remain pending; earlier r8 native results do not certify these new changes.

### Earlier fixes (v3.7.165)

- Dense sheets keep preserved stroke widths inside batches of 250 rather than attaching every stroke group to one live parent. This removes the unbounded construction path; import time still depends on the PDF and host.

### Earlier fixes (v3.7.164)

- Selected-face extrusion preserves source dimensions through nested, reflected and nonuniformly scaled groups, isolates shared component copies, and leaves protected text and linework alone. One Undo restores the operation. Invalid heights and connected geometry that cannot be isolated are refused before editing.
- Multi-contour fills keep their holes and separate filled islands. PDF tint functions and signed font transforms retain the reconciled source-fidelity fixes.
- Publishing requires an explicit manual release run. Pushes continue to run validation.
- The r8 test package passed all 11 import-matrix cases and 15 extrusion/dimension cases in SketchUp Make 2017, plus independent geometry and texture reopening. Those checks cover the specified fixtures, not every PDF or every host version.

### Earlier fixes (v3.7.163)

- A large sheet is drawn as it is read, so a finish-floor plan or grating sheet keeps the rest of its linework.
- A simple font that names each letter in its own encoding comes through as text, including a beam chart that has no Unicode map. The text cleanup that follows stays fast enough for SketchUp 2017.
- A filled shape with a hole stays open when the inner contour winds the other way, or when the paint is even-odd.
- Older LZW PDFs are decoded, including LZW images. Inline LZW strips are still reported as omitted. Fax and JBIG2 images are still skipped.
- Very short dashes keep their gaps, and the pattern starts where the PDF starts.
- Separation and DeviceN fills use the PDF's own color.
- The import windows fit a 1366x768 screen, the buttons stay on screen, and the choices are in plain words. Enter starts the import. Esc stops it only while SketchUp is the program in front.
- File > Import lists PDF. A failed import shows one message. A second PDF lands beside the first. Batch Import continues after a bad file.
- Quick Scale reads a scale the way it is printed, including 1/4" = 12" and 1 = 48, and a malformed entry is refused.
- A page whose text cannot be built still keeps its lines, fills, and pictures, and the import lists the text that was left out.
- Audit import is off unless you turn it on, and the window says when it is on. A big set does not re-check every finished page after each new page.
- Imported text is named by its words, so a piece mark can be found in the Outliner.
- Extensions > Extrude Selected 2D Faces to 3D extrudes the faces you select, without resizing the rest of the model.
- An invalid page selection stops with a plain reason.

### Earlier notes (v3.7.162)

- Pages that paint a pasted picture as one-pixel-tall inline image strips (BI/ID/EI), such as the AG&E title-block logo, keep their vectors and text editable and get that picture back as one placed native image at the source position and scale.
- Inline-image boundaries are proved (exact sample length or /L, filter end-of-data) so a long strip run cannot desynchronize the rest of the page.
- A page-6 white-mask failure (duplicate points) is fixed so that page can finish.

### Earlier notes (v3.7.160)

- Multi-page imports run unattended: no question appears after an import starts. The very-large-file warning is asked once before page 1; large pages are logged instead of prompting.
- A page that fails is logged and skipped while the remaining pages import; resume retries it.
- One non-blocking end-of-import status line (and Import Health) names raster-fallback pages with the reason, failed pages, and inline images that were not placed.
- Pages that paint inline images (e.g. a logo drawn as 1-px strips) keep their vector paths and text instead of being delivered as a whole-page raster; the omitted inline images are reported honestly.

### Earlier notes (v3.7.159)

- Stabilize retained entity signatures across SketchUp Make 2017 `commit_operation` housekeeping: finalize/skip ephemeral empty Groups, sort children stably, and quantize length noise so multi-page text3d imports no longer raise ResumeMismatch after only host purge of empty groups.

### Earlier notes (v3.7.158)

- Decode 8-bit grayscale and gray+alpha embedded-image PNGs in the page ownership/identity proof, so sheets with a `/DeviceGray` embedded image no longer abort with "texture export must be a noninterlaced 8-bit RGB/RGBA PNG".

### Earlier notes (v3.7.157)

- Preserve authored PDF annotation appearances on Acrobat/linearized PDF 1.5+ documents by writing incremental preparation updates as uncompressed cross-reference streams instead of classic tables, preventing Ghostscript `/rangecheck in --runpdf--` normalization aborts.
- Fix Ruby 2.2 / SketchUp 2017 symbolization compatibility in annotation microstroke geometry.

### Earlier notes (v3.7.156)

- Handle attributable font gaps in SvgItemRepresentationRenderer without hard contract error, allowing graceful ladder transition to raster patches for missing base-14 fonts.

### Earlier notes (v3.7.155)

- Excuse Poppler's unused Symbol startup warning when a completed pdffonts inventory proves the document has no Symbol font, even if heavy-page render stderr has extra noise. Real Symbol fonts and other missing display fonts still fail closed.

### Earlier notes (v3.7.154)

- Preserve PDF paint order, colors, nested images, and annotations in the SketchUp report sidecar, isolated from the import folder name so the certified report stays bound to the source items.

### Earlier notes (v3.7.153)

- Bring external text on a /Rotate page back into the displayed page frame by flipping against displayed height and mapping through PageTransform.inverse_transform_point (measured 18/24 outside -> 0/24; unrotated control unchanged). A documented ~33.6 pt residual remains on some rotated sheets.

### Earlier notes (v3.7.152)

- Deliver recovered characters for text a PDF stores as raw glyph codes, using only this host's own positioned span evidence (or an exact unique positional bind). Ambiguous Poppler-only binds are refused so readable wrong numbers never replace obvious garbage.
- Report text a PDF delivers as raw glyph codes instead of characters. Detection is from the font dictionaries; drawing is unchanged.

### This draft (unreleased)

- Embedded image callouts cover earlier drawing marks while later source text remains visible. Display order is checked against the renderer's actual source references and original PDF clipping instructions; source image pixels, XY placement and requested text representations remain unchanged. Unproved image order is reported explicitly.
- Text that needs a display offset retains its original geometry, source identity and local transform inside a dedicated parent created before the text. Saved/reopened verification checks that parent's exact Z offset, ownership, visibility and neutral material, alongside the original text certificates.
- Visible PDF annotations are preserved as page vectors and text before import, including markup lines outside the ordinary page content stream. Screen-visible notes remain visible and hidden notes stay hidden; the source PDF is unchanged. Missing helpers or incomplete normalization stop the import with an error.
- Very short, source-proven round-cap Ink annotations retain their original centerline and editable semicircular arcs even below SketchUp's normal edge tolerance. Their native fill uses 48 segments per semicircle, with its polygon area reported separately from the analytic source area. Where an unrotated original-page crop proves no glyph ink or unrelated annotation overlap, a bounded 600-DPI RGB display patch preserves the original blend appearance above that geometry. The report binds the original source, pixel lattice, saved image pixels and native arcs; unsupported composite scope is reported while retaining the qualified geometry. Text modes are unchanged.
- Encrypted PDFs that open without a password and repaired PDFs use the same screen-visible annotation handling. Temporary normalized files are checked against both source and output bytes; repeating an import after cleanup or repairing a missing helper works within the same session.
- Simultaneous imports keep their reports, parts data and source provenance in separate run folders, preventing one importer from replacing another importer's verification evidence.
- Each import retains its own diagnostic log, and every Compatibility Report is saved as its own file. On SketchUp 2023.1 and newer the report is also copied to the clipboard; on SketchUp 2017 through 2023.0, which have no clipboard access, the saved report opens in your text editor instead (usually Notepad). The report box itself shows the helper status and lists any other PDF extension that is loaded.
- Default report names handle long and non-ASCII drawing names. Explicit CLI report destinations retain their chosen paths.

### Earlier notes (v3.7.151)

- A temporary failed font inventory no longer disables font preparation for the rest of a session.
- A Windows PDF renderer's Symbol startup warning is treated as unrelated only when a complete successful source-font inventory proves that the document has no Symbol font. Actual missing fonts, incomplete inventories and other renderer errors still require repair; text placement and geometry verification remain mandatory.
- Failed text imports now identify the font, language pack or renderer inventory check that failed.
- Covered compound clipping paths retain their exact contours and holes, so clipped logos and other filled details are not replaced by solid rectangles.
- Partial rectangular fills are intersected with linear clipping contours exactly, including their holes, instead of losing the clip when a paint edge falls just short of it.
- Geometry text builds at a safe local size to prevent SketchUp from merging nearby letter vertices. Complete source-edge coverage is checked before and after page placement while the delivered text remains raw edges and faces.
- Fill-only backgrounds no longer gain visible border lines, and polygon outlines beside clipped artwork retain their source vertices instead of being fitted to conflicting circles.
- Embedded PDF images preserve their original reflection, rotation and shear through page placement, including title-block logos whose PDF image axes run backwards.
- Geometry whose complete painted bounds lie outside the PDF page is omitted, matching the page boundary used by PDF viewers. Stroke width, caps, joins and transforms are included in that decision; partially visible paths remain intact.
- Overlapping blank annotation spans no longer take glyphs from neighboring visible text during source ownership matching.
- Earlier opaque white PDF masks are composed around actual flat text faces using verified source glyph paint order. This preserves solid lettering, counters and interleaved replacement notes without changing text coordinates or the requested representation.
- Invalid nested or misplaced holes created by the legacy SketchUp face builder are reconstructed as valid isolated regions, then checked again against the original white area and glyph boundaries. Cleanup tolerates edges that SketchUp has already removed.
- Proven final translucent rectangle annotations retain their source fill opacity and centered stroke width above the text. Final-page text crops are accounted for once, preventing duplicate markup shading. Fill and stroke regions remain separate during crop subtraction so the host cannot merge their different paint styles. Empty construction groups are removed before page certification, preventing a false resume mismatch when SketchUp commits the import.
- Includes the retained large-page recognition and glyph/raster performance improvements.

### Earlier fixes (v3.7.130)

- **Non-ASCII user profiles and file names**: helper output paths now live under an ASCII-safe temporary root, so imports work for accounts and PDF file names containing accented, Cyrillic, or CJK characters. Previously the bundled PDF renderers could not write beneath such paths and affected imports failed silently — including recovery of damaged PDFs whose own file name contained an accent.
- **Actionable runtime diagnostics**: if the bundled PDF runtime cannot start or verify, the importer now names the exact missing piece and the fix, instead of silently disabling itself.


### Recent fixes (v3.7.127)

- **Bounded old-hardware imports**: expensive editable paths now publish deterministic complexity estimates, measured monotonic progress, and Escape checkpoints. Cancelling rolls back only the current partial page while retaining completed page groups.
- **Certified save/reopen resume**: completed pages are journaled by exact PDF, behavior options, importer source, and package identity. Resume rejects missing, duplicated, recertified, or edited page groups—including in-place geometry edits—and continues at the saved page offset.
- **Release and host identity closure**: existing-tag release completion is atomic and idempotent, every asset is post-verified, and release acceptance binds the repository commit/tag, exact RBZ digest and extracted source tree, loaded Ruby modules, requested pages, and live Q&A/host leases.
- **Public deterministic regression corpus**: CI generates a multi-page feature PDF plus malformed-input fixture from literal public instructions, with reproducible manifest digests and no private customer files.

### Recent fixes (v3.7.126)

- **SketchUp 2017 Labels stability and size fidelity**: finite-bbox Labels now prove the host's missing glyph-size/run-width control before `entities.add_text`, avoiding both unmeasured screen annotations and the zero-length-vector host crash. Each item advances exactly one rung to source-outline 3D Text with its semantic hash, source span, placement, and provenance intact.
- **Rotated label fidelity**: fraction and part-mark labels with source rotation use the corresponding item-bound rotation proof and advance to exact source-outline 3D Text; they never become an unrotated native annotation.
- **Multi-page accountability**: host QA now records every requested page as delivered, failed, or unaccounted and rejects incomplete page sets instead of allowing a page-one-only result to appear complete.

### Recent fixes (v3.7.125)

- **Byte-reproducible release packages**: RBZ members now use fixed archive metadata and canonical LF Ruby source bytes, so Windows and GitHub checkouts produce the same artifact instead of leaking filesystem timestamps or CRLF/LF differences into a release.

- **Host-proven Raster telemetry**: terminal page-Raster delivery now retains the renderer's measured render, pixel-proof, placement, cleanup, total-time, and temporary-byte evidence through the verification boundary. Release acceptance therefore fails closed if production work cannot be measured and no longer reports a successful real render as zero time.
- **Stable Raster host evidence with external timing telemetry**: TextureWriter phase timings are reported outside persistent content identity, so identical saved/reopened pixels cannot fail strict host-heal continuity merely because an export took a different number of milliseconds. Pure terminal page-Raster controller verification now recognizes only the explicit no-heal/final-texture-proof state, compares its lightweight pre-reopen snapshot to the authoritative physical reopen, and revalidates delivery against the reopened owned images; every other model retains strict heal/reopen validation.
- **Full-page Raster proof without giant raw files**: production PNG verification and saved-model TextureWriter evidence now decode and hash one scanline at a time, write zero temporary RGBA bytes, and retain the exact premultiplied visual digest, dimensions, placement, and source binding. Pure page-Raster QA saves once and performs one authoritative final reopen/texture proof; geometry and text models keep the existing host-heal path. Per-phase render, verify, placement, cleanup, and temporary-byte counters make future slowdowns visible.
- **Dense text performance without placement shortcuts**: repeated text-angle hints are indexed by normalized source text and then resolved by exact nearest-position matching. Exact 3D Text reuses one source definition across translation, rotation, scale, reflection, or shear only when the underlying outline is genuinely identical; physical evidence verifies each shared definition and every instance transform without asking SketchUp to recalculate redundant per-instance bounds.
- **Filled-vector accuracy and legacy-host stability**: filled PDF contours retain their exact sampled source boundary when SketchUp creates the face. Arc reconstruction remains available for unfilled strokes, but can no longer replace part of a fill boundary and cause valid planar faces to disappear. Fills below SketchUp 2017's native face-construction tolerance are batched by destination and style, built as exact faces at safe local scale, and retained through a small number of inverse-scaled component instances. This preserves every world-space contour while avoiding hundreds of microscopic host instances.

### Recent fixes (v3.7.114)

- **Rotated text fidelity**: exact pdftocairo source-glyph outlines keep their own source orientation without a second semantic rotation. Requested Labels retain that angle through their explicit source-outline 3D visual-equivalent delivery.
- **Dimension placement**: horizontal wide-short dimensions are no longer misclassified as 90° text, one-digit mixed numbers center only in tight dimension breaks, and split diagonal part marks such as `a1` + `2` + `34` rejoin as `a1234`.
- **Text and Labels accuracy**: neither request accepts an unmeasured SketchUp screen annotation as visually exact. Because `Sketchup::Text` exposes no source glyph-size or run-width control, each finite-bbox Labels item carries an affirmative proof and advances to exact source-outline 3D Text. This visual-equivalent result is not promised to remain a native editable annotation, never silently enters Raster, and preserves semantic/provenance identity.
- **Older-hardware performance**: source-glyph matching uses exact spatial preselection, single-use host renders avoid retaining a duplicate full-page point graph, and repeated component evidence reuses immutable definition topology and canonical fragments. A large synthetic regression drawing now imports substantially faster without changing its delivered text inventory.

### Recent fixes (v3.7.113)

- **3D Text performance**: glyph contour point culling and spatial-bucket duplicate detection dramatically reduce mesh complexity for large drawings, including the private large-sheet fixture.
- **Flat Text / Labels stacked dimensions**: stacked vertical dimension numerals are no longer split into sub-items in flat Text mode, fixing source-span contract conflicts and improving alignment/rotation handling.

Core vector import uses the built-in Ruby parser. Windows release RBZ files ship free zero-ceremony Poppler and Ghostscript runtimes for higher-fidelity text, raster, and SVG paths. MuPDF remains an optional free alternate.

---

## Overview

PDF Vector Importer parses PDF content streams directly in Ruby and reconstructs vector geometry as native SketchUp edges. The core vector path does not require Ruby gems, C extensions, or external binaries. Higher-fidelity helper paths can use MuPDF (`mutool`), Poppler (`pdftocairo`, `pdftotext`) and Ghostscript when present. The requested representation is attempted first. If an item cannot be delivered because a helper is missing, a host limit or exception occurs, or the result is empty, that item advances one rung at a time through the finite closest fallback ladder and every transition is reported. If no rung can deliver it, only that item's partial artifacts are removed and the omission is reported; the rest of the page remains. Alignment, rotation and size errors must be fixed within the requested representation. SketchUp 2017 Make (Ruby 2.2) is the host floor; later versions through current Pro remain in scope, with the actual tested hosts listed in [HOST_COMPATIBILITY.md](HOST_COMPATIBILITY.md).

The importer profiles each PDF document to identify its origin (fabrication drawings, CAD exports, architectural plans, vector art, or raster scans) and adapts its import strategy accordingly.

---

## Structural Steel Shape Assets

The former standalone `Structural-Steel-SU-Shapes` repository has been
consolidated here under `steel_shapes/` so the SketchUp
importer repo is the source home for the `.skp` steel shape packs. The
versioned release ZIP from that old repo is intentionally not stored here;
GitHub Releases remain the download layer, while this repo keeps the source
assets, checksums, license, and notes.

---

## Key Features

- **3 Import Modes** (BCS-ARCH-001) — Auto (default: keeps lines and text
  editable and places pictures where they are; a page becomes one picture only
  when it is a scan or its pictures cannot be placed separately), Vector (lines
  and text only, skips pictures) and Raster (a picture of each page). `Hybrid` from older saved settings or the CLI works
  the same as Auto. Every mode targets maximum fidelity.
- **6 Text Rendering Options** — Text, Labels, 3D Text, Glyphs, Geometry,
  Raster (orthogonal to mode) + separate Import text toggle. The dialog reopens
  with the last text rendering option used; the first-run default is 3D Text for
  full-page visual parity.

  | Requested representation | Delivered object | Fidelity contract |
  |--------------------------|------------------|-------------------|
  | **Text** | Closest verified text representation | Never silently aliases to Labels. SketchUp 2017 exposes no distinct flat editable constructor, and native annotations expose no source glyph-size/run-width control; signed item proofs therefore advance automatically to exact source-outline 3D Text. |
  | **Labels** | Explicit source-outline 3D visual equivalent on SketchUp 2017 | A finite source bbox proves native annotation size/run-width control is unavailable before entity creation; rotation and horizontal-size proofs advance one rung while preserving exact semantic/provenance identity. No editability or silent Raster substitution is promised. |
  | **3D Text** | Positive-depth source-glyph solid text | Model-space placement, rotation, size, source glyphs, and depth are verified. |
  | **Glyphs** | Per-glyph grouped source outlines: filled glyph faces + exact outline edges, painted with the source ink | Outline identity, grouping, placement, rotation, size, and visibility are verified; face fill and ink are recorded per item. |
  | **Geometry** | Source/page path outlines: filled glyph faces + exact outline edges, painted with the source ink | Geometry remains separate from Glyph groups and is verified as one owned flat group of edges plus faces. |
  | **Raster** | Source-bound image | Canonical text items use verified item crops; a zero-canonical-text selected page uses a verified page image. |

  Evidence keeps two page-image cases distinct. Explicit full-page Raster from
  the Raster import strategy records semantic text not evaluated; it
  must not claim that the page contains no text. Text-rendering Raster may use a
  page image only with verified zero-canonical-text proof bound to the exact PDF
  bytes and page. Item crops come from one Ghostscript transparent RGBA page render
  per page and use streaming Ruby cropping. The original MediaBox canvas, its
  nonzero origin, and page rotation are retained; the original CropBox clips
  visibility without resizing that canvas. Unlike the previous Cairo item-raster
  path, marks outside the declared CropBox stay clipped. The source PDF is never
  rewritten for item Raster. Renderer warnings, repairs, and arbitrary font
  substitutions fail verification; only exact built-in standard-14 font programs
  are accepted for those standard PDF fonts. A crop must retain alpha-channel provenance
  and visible pixels, but may be fully opaque; it is not rejected merely because
  it contains no `alpha < 255` pixel. One reference PDF digest is cached per
  import, while full bytes are checked immediately before/after each renderer—never
  once per item. Audit import additionally rechecks full bytes before page commit;
  with Audit off, that commit check uses the cached digest and current file size/times.
  Saved/reopened Raster acceptance exports the
  actual SketchUp texture and matches its decoded visual-pixel digest and size;
  importer attributes alone are not proof.

  After white-mask and annotation composition, verified final-page item crops
  display 0.001 inch above the highest native text on their page. This prevents
  overlapping native letters from obscuring the crop's already composed PDF
  colors. Source XY, the canonical source plane, crop pixels and native peer text
  remain unchanged. A separate placement record is checked against source crop
  coordinates and actual host text bounds before and after save/reopen; it does
  not permit an arbitrary image offset.

  Use **3D Text** for go-live visual comparison against Adobe at equal zoom.
  Use **Labels** when you need the explicit Labels request and its audited
  closest-representation ladder. On SketchUp 2017, finite-bbox spans are delivered
  as source-outline 3D visual equivalents, not editable screen annotations.
  Use **Text** when you want the closest verified text result automatically;
  SketchUp 2017 reaches exact source-outline 3D Text because its flat annotation
  API cannot preserve source size. Use **Glyphs** or **Geometry** when the
  corresponding exact outline structure is preferred. The selected option is sacred: fix transforms in-mode; do
  not switch representation to paper over alignment/rotation/scale bugs
  just to make a defect less visible.

  ### Text-mode fidelity and failure handling

  The selected text rung is always attempted first. For finite-bbox Labels on
  SketchUp 2017, the item-bound capability attempt proves before host creation
  that native annotations cannot preserve source size/run width; the adjacent
  source-outline 3D attempt is then verified for placement, rotation, width,
  height, semantics, and provenance. A generic failed proof cleans its exact
  partial artifacts and stops; it cannot trigger a representation change.

  Missing helpers, generic host/API failures, exceptions, empty artifacts, and
  currently broken transform code are not proof that a representation is
  impossible. They therefore cannot enter or skip through the fallback ladder.

  When an exact item-specific source/host inventory affirmatively proves the
  current representation impossible, only these requested-specific ladders apply;
  Text advances directly to 3D Text and never through Labels:

  - Text → 3D Text → Glyphs → Geometry → item Raster
  - Labels → 3D Text → Glyphs → Geometry → item Raster
  - 3D Text → Glyphs → Geometry → item Raster
  - Glyphs → Geometry → item Raster
  - Geometry → item Raster

  Raster has no next rung. Requested Raster attempts a verified item crop for
  each canonical text span, or a verified page image for each selected
  zero-canonical-text page. Fallback Raster is always item-scoped. Each adjacent
  rung has its own renderer and ownership/type/visual proof. Terminal Raster can
  still fail verification: render, crop, ownership, placement, or visual failure
  is reported and stops without pretending delivery succeeded. The finite
  controller never cycles or erases successful peer spans/page geometry, and
  requires no paid component.
- **Built-in Ruby vector parser** — core vector import requires no gems or C extensions
- **Adaptive Bezier subdivision** with configurable flatness tolerance
- **Kasa algebraic circle fitting** for arc reconstruction from point sequences
- **OCG layer support** — PDF Optional Content Groups map to SketchUp Tags
- **PDF layer matching by default** — PDF layers become same-named SketchUp Tags when the PDF contains layer data
- **Color-based tag grouping** with dash pattern mapping
- **Scale by Reference** tool — select an edge, type the real-world dimension
- **Quick Scale** — type the drawing scale the way it is printed (`48`,
  `1:48`, `1/4"=1'-0"`, `3/8"=1'`) and a paper-size import grows to real size
- **Architectural scale notation parsing**
- **Import quality assessment** with warnings and performance metrics in
  `import_report.json` and **Import Health**
- **Post-import tools** in **Extensions > PDF Vector Importer**: Clean Up
  Selected Groups, Feature Inventory (what each imported page holds) and
  Show/Hide PDF Tags
- **Document profiling** (fabrication, CAD, architectural, vector art, raster)
  used by recognition; it does not switch the import mode
- **FlateDecode decompression** for compressed PDF streams
- **Form XObject recursion** for embedded PDF forms

---

## Installation

1. Download the latest `SketchUp-PDF-Importer_vX.Y.Z.rbz` from [Releases](https://github.com/BlueCollar-Systems/PDF-Importer-SketchUp/releases)
2. In SketchUp: **Window > Extension Manager > Install Extension**
3. Select the `.rbz` file
4. Restart SketchUp if prompted

The extension adds **File > Import PDF Vectors...**, lists **PDF Vector Drawings (*.pdf)**
in SketchUp's own **File > Import**, and adds the **Extensions > PDF Vector Importer**
menu (Import PDF, Safe Mode, Batch Import Folder, the scale tools, Extrude Selected
Planar Faces, Clean Up Selected Groups, Feature Inventory, Show/Hide PDF Tags,
Compatibility Report, Import Health and About). There is no toolbar.

**Offline install:** The GitHub Release `.rbz` installs without internet. Core vector import and the bundled free Poppler and Ghostscript helpers work offline. MuPDF is an optional separate free install.

For SketchUp 2025 users: native PDF import discoverability changed in SketchUp UI,
but this extension still provides its own PDF import menu commands.

## Upgrading / skipping versions

Install the latest `.rbz` from Releases via Extension Manager (overwrites the prior extension). When the version changes, SketchUp shows a **one-time update notice** on next launch — run **Compatibility Report** and retest one of your own representative PDFs before shop use. Skipping intermediate versions (e.g. 3.7.55 → 3.7.70) is supported; there is no incremental migration tool.

## Enterprise / multi-user installs

Install the RBZ **per Windows user** on each PC where SketchUp runs. Avoid roaming only the `Plugins` folder across PCs with different SketchUp years. **Compatibility Report** records extension/helper capability status and any other loaded PDF extension while redacting local extension and executable paths, so the report is safe to share in IT support tickets. SketchUp 2023.1 and newer copy it to the clipboard; on SketchUp 2017 through 2023.0 it opens in your text editor (usually Notepad).

## External Helpers / Any-PC Behavior

The importer must run on a supported PC without hardcoded local paths. Helpers
are detected at runtime and reported through **Extensions > PDF Vector
Importer > Compatibility Report**.

Windows releases ship free Poppler and Ghostscript runtimes inside the RBZ,
with separate integrity manifests and third-party notices. Clean-machine users
do not need to download them separately for helper-dependent text, item Raster,
or SVG paths. MuPDF remains an optional free/system install when used.
Use **Compatibility Report** to verify the exact helper path before importing.

| Helper | Used for | If missing |
|--------|----------|------------|
| MuPDF `mutool` | Same-representation SVG/glyph text geometry when Poppler is not installed | Poppler may supply the same representation; otherwise that requested SVG representation stops |
| Poppler `pdftocairo` | SVG/glyph text geometry and explicit raster page rendering | A separately verified same-representation source may be tried; otherwise that requested helper path stops |
| Poppler `pdftotext` | Higher-fidelity text bounding boxes and line reconstruction | Internal text parser fallback is used |
| Poppler `pdffonts` | Detecting non-embedded fonts before SVG text rendering | Font preflight is unavailable |
| Ghostscript | Verified transparent page rendering for item Raster; embedding non-embedded fonts into a temporary SVG render copy when needed | Item Raster stops if its renderer is unavailable; an outline attempt with unresolved or skipped glyphs fails its fidelity proof |

Poppler return code zero and a nonempty output file do not prove complete text.
The one qualified Adobe-GB1 diagnostic exception is tied to an exact public
fixture PDF, page, and SVG fingerprint, and is finalized only after real
source-span matching and host placement. All five failure collections must be
present arrays and empty; missing evidence is a rejection. This does not claim
general CID completeness.

Environment overrides are supported for managed PCs: `BC_PDFTOCAIRO_PATH`,
`BC_MUTOOL_PATH`, `BC_PDFTOTEXT_PATH`, and `BC_GHOSTSCRIPT_PATH`.

---

## Scale Tool

The Scale by Reference tool lets you correct imported geometry to real-world dimensions. Select any edge, type the known real dimension, and all imported geometry scales proportionally.

### Quick Scale

Imports arrive at paper size. **Quick Scale** takes the drawing's scale typed
the way it is printed and multiplies the drawing up to real size. A plain
number is used as the multiplier itself (`0.5` halves the drawing). Before
anything moves, a box says which way the drawing changes, for example
"This makes the drawing 48x LARGER", and Undo puts it back.

| You type | Multiplier | Common use |
|----------|------------|------------|
| `1:1` | 1 | Full-size details |
| `1:2` | 2 | Large details |
| `1:4` or `3"=1'-0"` | 4 | Construction details |
| `1:8` or `1-1/2"=1'-0"` | 8 | Details |
| `1:10` | 10 | Detailed plans (metric) |
| `1:16` or `3/4"=1'-0"` | 16 | Section drawings |
| `1:24` or `1/2"=1'-0"` | 24 | Plans |
| `1:32` or `3/8"=1'-0"` | 32 | Plans |
| `1:48` or `1/4"=1'-0"` | 48 | Plans |
| `1:50` | 50 | General plans (metric) |
| `1:96` or `1/8"=1'-0"` | 96 | Plans |
| `1:100` | 100 | Site plans (metric) |
| `1"=10'` | 120 | Civil and site plans |
| `1:192` or `1/16"=1'-0"` | 192 | Site plans |

`1/48` is read the same as `1:48`.

---

## Import Report

No box pops up after an import. When it finishes, one line on SketchUp's status
bar says how many pages came in, any page delivered as a picture (with the reason)
and any page that failed. **Extensions > PDF Vector Importer > Import Health...**
shows the full summary of the last import in this SketchUp session, and every
import writes a detailed `import_report.json`.

### Warnings

The report flags common issues:

- Clipping paths that may hide geometry
- Extremely thin or zero-width strokes
- Unsupported blend modes or transparency
- Font-based geometry that could not be converted
- Coordinate values outside the SketchUp modeling range
- Pages with no extractable vector content (raster-only)

### Performance Metrics

Every import logs timing and throughput data:

- Total import time (seconds)
- Objects imported (edges, arcs, faces)
- Throughput (objects/sec)
- PDF stream decompression time
- Bezier subdivision iterations
- Arc fitting attempts and successes

Headless runs also write `import_report.json` (`bcs.import_report/1.1`) beside the log path.
See **Import report / scale trust** below.

### Import report / scale trust

When reading `extra.resolved_scale` from `import_report.json` (or the in-app report):

- Use `factor` for scaling **only when** `confidence >= 0.70` **and** `fallback_reason` is not `no_scale_detected`.
- Otherwise treat scale as unknown and apply Scale by Reference or a manual preset.

### Bad-PDF open gate (SketchUp vs Python hosts)

All hosts show the same actionable messages for encrypted, non-PDF, and truncated files.
Python importers (**FreeCAD, LibreCAD, Blender**) **fail closed** at open time via `safe_open` / `PdfOpenError`.
SketchUp runs the same cheap byte-level checks and also **fails closed** if the gate itself errors (`reason: unreadable`), recording an open-failure `import_report.json` instead of admitting the file. Salvage may still override encrypted/truncated refusals when Poppler can normalize the PDF.
Do not assume identical refusal behavior across hosts; compare `fallback.reason` in each host's import report.

---

## Document Profiling

The importer analyzes each PDF and classifies it into one of five categories to optimize parsing:

| Profile | Characteristics |
|---------|----------------|
| **Fabrication** | Shop drawings, cut lists, weld callouts, BOM tables |
| **CAD** | Exported from AutoCAD, Revit, SolidWorks, or similar |
| **Architectural** | Floor plans, elevations, sections with dimension strings |
| **Vector Art** | Illustrator/Inkscape artwork, logos, complex fills |
| **Raster** | Scanned documents with embedded images, minimal vectors |

---

## Source Structure

```
bc_pdf_vector_importer.rb            # Root loader
bc_pdf_vector_importer/
  main.rb                            # Extension entry point
  pdf_parser.rb                      # Top-level PDF object parser
  content_stream_parser.rb           # PDF content stream interpreter
  geometry_builder.rb                # SketchUp geometry construction
  arc_fitter.rb                      # Kasa circle fitting
  bezier.rb                          # Adaptive Bezier subdivision
  scale_tool.rb                      # Scale by Reference tool
  report_dialog.rb                   # Import report UI
  import_dialog.rb                   # Import options UI
  unit_parser.rb                     # Architectural notation parser
  geometry_cleanup.rb                # Post-import cleanup utilities
  ocg_parser.rb                      # Optional Content Group parser
  text_parser.rb                     # Text extraction and rendering
  dimension_parser.rb                # Dimension string recognition
  document_profiler.rb               # PDF document classification
  generic_recognizer.rb              # Generic shape recognition
  generic_classifier.rb              # Generic element classification
  region_segmenter.rb                # Spatial region segmentation
  primitive_extractor.rb             # Low-level drawing primitive extraction
  primitives.rb                      # Primitive data structures
  recognizer.rb                      # Pattern recognizer
  hatch_detector.rb                  # Hatch pattern detection
  svg_text_renderer.rb               # SVG text path renderer
  svg_3d_text_renderer.rb            # Source-glyph 3D text extrusion
  representation_fidelity.rb         # Finite representation/fallback contract
  poppler_result_validator.rb        # Fail-closed helper result validation
  external_text_extractor.rb         # External text extraction support
  validator.rb                       # Input validation
  xobject_parser.rb                  # Form XObject recursion
  logger.rb                          # Logging utilities
  metadata.rb                        # Version and extension metadata
```

---

## Known Limitations

| Limitation | Details |
|-----------|---------|
| **Encrypted PDFs** | Password-protected PDFs cannot be imported. Remove encryption first using Adobe Acrobat, Preview (macOS), or qpdf. |
| **Compression filters** | FlateDecode, LZWDecode, ASCII85Decode, ASCIIHexDecode, and RunLengthDecode streams are decoded. JBIG2 and CCITT fax images are still skipped. Inline images that use LZW are reported as omitted. |
| **Font-dependent text** | Text rendered with embedded subset fonts, non-embedded fonts, or platform-missing display fonts may require Poppler and Ghostscript for maximum fidelity. Without a source that can certify the requested representation, the importer reports the unavailable capability and stops that representation instead of silently substituting another one. |
| **Clipped/XObject-heavy PDFs** | Deeply nested form XObjects and aggressive clipping can lead to partial geometry recovery. |
| **Raster-only scans** | Pure image/scanned PDFs with no vector operators will not produce SketchUp edges. |
| **Very large PDFs** | Files over 500 MB are rejected. Dense drawings with over 1 million path operators per stream are truncated. Split large documents before importing. |

---

## Compatibility

See **[HOST_COMPATIBILITY.md](HOST_COMPATIBILITY.md)** (SketchUp hosts) and **[COMPATIBILITY.md](COMPATIBILITY.md)** (Ruby 2.2 language rules). Summary:

| SketchUp Version | Ruby Version | Status |
|-----------------|-------------|--------|
| Make 2017 | 2.2.4 | ✅ Verified for the v3.7.100 live-host gate; current source passes exact Ruby 2.2.4 CI parse/smoke |
| Pro 2017 | 2.2.4 | ⚠️ Expected — exact Ruby 2.2.4 CI parse/smoke, no dedicated Pro host evidence |
| 2018–2019 | 2.5.x | ⚠️ Expected |
| 2020–2023 | 2.7.x | ⚠️ Expected |
| 2024 | 3.2.2 | ⚠️ Expected |
| 2025 | 3.2.x+ | ⚠️ Expected |
| Current Pro release | verify actual Ruby | ⚠️ Expected until host-tested |
| 2014–2016 | 2.0.x | ⚠️ Expected only after dedicated host verification |

Evidence levels:
- `✅ Verified`: named host/version validation evidence captured; later source
  revisions still rely on their stated CI evidence until that host is rerun.
- `⚠️ Expected`: exact-runtime CI or syntax compatibility exists, but no named
  host-run evidence has been captured.
- `❌ Not supported`: outside maintained/tested compatibility scope.

---

## Free Structural Steel Shapes (CC0)

This repository also hosts the public-domain AISC v16.0 SketchUp shape packs
previously distributed from `Structural-Steel-SU-Shapes`.

| Location | Contents |
|----------|----------|
| [`steel_shapes/family_packs/`](steel_shapes/family_packs/) | 14 `.skp` family files (2L, C, HP, HSS, L, M, MC, MT, PIPE, S, ST, W, WT) |
| [`steel_shapes/README.md`](steel_shapes/README.md) | Usage, license, checksum notes |
| [`steel_shapes/ATTRIBUTION.md`](steel_shapes/ATTRIBUTION.md) | Merge provenance from the former standalone repo |

**Releases:** tag `steel-v1.0.0` (etc.) to publish
`Structural-Steel-SU-Shapes-*.zip` via the `steel-shapes-release` workflow.
PDF Importer extension releases continue to use `v3.x.x` tags.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

## AI Contributors

This project was developed with significant contributions from AI assistants:

- **Claude & Claude Code** (Anthropic) — Architecture, code generation, debugging, and code review
- **ChatGPT & Codex** (OpenAI) — Code generation and problem-solving assistance
- **Gemini** (Google) — Development assistance and code suggestions
- **Microsoft Copilot** — Code completion and development support

These AI tools were used as collaborative development partners throughout the project lifecycle.

---

## Author

**BlueCollar-Systems** -- BUILT. NOT BOUGHT.

### Source stroke clipping

Crossing vector strokes are clipped to verified rectangular PDF clips and the
visible page box without moving the remaining source vertices or adding boundary
connectors. Trimmed dashed strokes keep the source phase across the original
subpath and measure dash lengths before its transform. Contained paths retain the
existing native arc/style behavior. Fill contours and compound holes are separate.

SketchUp centerline edges do not model physical PDF stroke width, joins, or caps.
A nonrectangular/text clip or a cap-only painted intersection retains the existing
source centerline and records an unresolved warning, rather than silently deleting
possible paint. Per-page counts and reasons are retained under
`extra.geometry_staging[].stroke_clipping`; those warnings are not paint-fidelity
acceptance. Text mode and text representation are unchanged.

Large annotated PDF sets use a finite preparation budget based on verified page
count (at least two minutes, five seconds per page, up to thirty minutes), so a
valid large set is not rejected solely by the former fixed two-minute timeout.
Source identity, complete page count, and annotation-flattening checks still apply;
timeouts and partial output remain explicit failures with diagnostic causes.
