# PDF Vector Importer for SketchUp

**BUILT. NOT BOUGHT.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-3.7.140-green.svg)]()
[![Platform](https://img.shields.io/badge/Platform-SketchUp%202017%2B-orange.svg)]()
[![Ruby](https://img.shields.io/badge/Ruby-2.2%2B-red.svg)]()

Import PDF vector geometry as native editable SketchUp edges with arc reconstruction, color-based tag grouping, text import, dash patterns, Scale by Reference tool, and full Bezier support.

### Recent fixes (v3.7.130)

- **Non-ASCII user profiles and file names**: helper output paths now live under an ASCII-safe temporary root, so imports work for accounts and PDF file names containing accented, Cyrillic, or CJK characters. Previously the bundled PDF renderers could not write beneath such paths and affected imports failed silently — including recovery of damaged PDFs whose own file name contained an accent.
- **Actionable runtime diagnostics**: if the bundled PDF runtime cannot start or verify, the importer now names the exact missing piece and the fix, instead of silently disabling itself.


### Recent fixes (v3.7.127)

- **Bounded old-hardware imports**: expensive editable paths now publish deterministic complexity estimates, measured monotonic progress, and Escape checkpoints. Cancelling rolls back only the current partial page while retaining completed page groups.
- **Certified save/reopen resume**: completed pages are journaled by exact PDF, behavior options, importer source, and package identity. Resume rejects missing, duplicated, recertified, or edited page groups—including in-place geometry edits—and continues at the saved page offset.
- **Release and host identity closure**: existing-tag release completion is atomic and idempotent, every asset is post-verified, and release acceptance binds the repository commit/tag, exact RBZ digest and extracted source tree, loaded Ruby modules, requested pages, and live Q&A/host leases.
- **Public deterministic regression corpus**: CI generates a multi-page feature PDF plus malformed-input fixture from literal public instructions, with reproducible manifest digests and no private customer files.

### Recent fixes (v3.7.126)

- **SketchUp 2017 label stability**: native Labels now use the documented two-argument `entities.add_text` form and persist an explicit three-coordinate leader-vector evidence value, avoiding the zero-length-vector host crash while keeping placement verification fail-closed.
- **Rotated label fidelity**: fraction and part-mark labels with source rotation advance through the item-specific ladder to exact source-outline 3D Text when a native SketchUp label cannot preserve their visual orientation.
- **Multi-page accountability**: host QA now records every requested page as delivered, failed, or unaccounted and rejects incomplete page sets instead of allowing a page-one-only result to appear complete.

### Recent fixes (v3.7.125)

- **Byte-reproducible release packages**: RBZ members now use fixed archive metadata and canonical LF Ruby source bytes, so Windows and GitHub checkouts produce the same artifact instead of leaking filesystem timestamps or CRLF/LF differences into a release.

- **Host-proven Raster telemetry**: terminal page-Raster delivery now retains the renderer's measured render, pixel-proof, placement, cleanup, total-time, and temporary-byte evidence through the verification boundary. Release acceptance therefore fails closed if production work cannot be measured and no longer reports a successful real render as zero time.
- **Stable Raster host evidence with external timing telemetry**: TextureWriter phase timings are reported outside persistent content identity, so identical saved/reopened pixels cannot fail strict host-heal continuity merely because an export took a different number of milliseconds. Pure terminal page-Raster controller verification now recognizes only the explicit no-heal/final-texture-proof state, compares its lightweight pre-reopen snapshot to the authoritative physical reopen, and revalidates delivery against the reopened owned images; every other model retains strict heal/reopen validation.
- **Full-page Raster proof without giant raw files**: production PNG verification and saved-model TextureWriter evidence now decode and hash one scanline at a time, write zero temporary RGBA bytes, and retain the exact premultiplied visual digest, dimensions, placement, and source binding. Pure page-Raster QA saves once and performs one authoritative final reopen/texture proof; geometry and text models keep the existing host-heal path. Per-phase render, verify, placement, cleanup, and temporary-byte counters make future slowdowns visible.
- **Dense text performance without placement shortcuts**: repeated text-angle hints are indexed by normalized source text and then resolved by exact nearest-position matching. Exact 3D Text reuses one source definition across translation, rotation, scale, reflection, or shear only when the underlying outline is genuinely identical; physical evidence verifies each shared definition and every instance transform without asking SketchUp to recalculate redundant per-instance bounds.
- **Filled-vector accuracy and legacy-host stability**: filled PDF contours retain their exact sampled source boundary when SketchUp creates the face. Arc reconstruction remains available for unfilled strokes, but can no longer replace part of a fill boundary and cause valid planar faces to disappear. Fills below SketchUp 2017's native face-construction tolerance are batched by destination and style, built as exact faces at safe local scale, and retained through a small number of inverse-scaled component instances. This preserves every world-space contour while avoiding hundreds of microscopic host instances.

### Recent fixes (v3.7.114)

- **Rotated text fidelity**: exact pdftocairo source-glyph outlines keep their own source orientation without a second semantic rotation; native Labels still use the PDF text-matrix angle.
- **Dimension placement**: horizontal wide-short dimensions are no longer misclassified as 90° text, one-digit mixed numbers center only in tight dimension breaks, and split diagonal part marks such as `a1` + `2` + `34` rejoin as `a1234`.
- **Text accuracy**: a Text request no longer accepts an unmeasured SketchUp screen label as visually exact. Because `Sketchup::Text` exposes no source glyph-size or run-width control, the item-bound ladder advances automatically to exact source-outline 3D Text; the explicit Labels option remains native and editable.
- **Older-hardware performance**: source-glyph matching uses exact spatial preselection, single-use host renders avoid retaining a duplicate full-page point graph, and repeated component evidence reuses immutable definition topology and canonical fragments. A large synthetic regression drawing now imports substantially faster without changing its delivered text inventory.

### Recent fixes (v3.7.113)

- **3D Text performance**: glyph contour point culling and spatial-bucket duplicate detection dramatically reduce mesh complexity for large drawings, including the private large-sheet fixture.
- **Flat Text / Labels stacked dimensions**: stacked vertical dimension numerals are no longer split into sub-items in flat Text mode, fixing source-span contract conflicts and improving alignment/rotation handling.

Core vector import uses the built-in Ruby parser. Windows release RBZ files ship a free zero-ceremony Poppler runtime for higher-fidelity text/raster/SVG paths. MuPDF remains an optional free alternate; Ghostscript remains optional for non-embedded font repair.

---

## Overview

PDF Vector Importer parses PDF content streams directly in Ruby and reconstructs vector geometry as native SketchUp edges. The core vector path does not require Ruby gems, C extensions, or external binaries. Higher-fidelity helper paths can use MuPDF (`mutool`), Poppler (`pdftocairo`, `pdftotext`) and Ghostscript when present. A missing helper may change the available source inside the same requested representation, but never by itself authorizes a different representation. Only affirmative item-specific impossibility can enter the finite closest fallback ladder. It runs on supported SketchUp PCs from SketchUp 2017 Make (Ruby 2.2) through the current Pro release.

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

- **4 Import Modes** (BCS-ARCH-001) — Auto (default, picks strategy per page),
  Vector, Raster, Hybrid. Every mode targets maximum fidelity.
- **6 Text Rendering Options** — Text, Labels, 3D Text, Glyphs, Geometry,
  Raster (orthogonal to mode) + separate Import text toggle. The dialog reopens
  with the last text rendering option used; the first-run default is 3D Text for
  full-page visual parity.

  | Requested representation | Delivered object | Fidelity contract |
  |--------------------------|------------------|-------------------|
  | **Text** | Closest verified text representation | Never silently aliases to Labels. SketchUp 2017 exposes no distinct flat editable constructor, and native annotations expose no source glyph-size/run-width control; signed item proofs therefore advance automatically to exact source-outline 3D Text. |
  | **Labels** | Editable `Sketchup::Text` annotation | Exact content/anchor and hidden leader are read back; nonzero glyph rotation is a proven host limit for that item. |
  | **3D Text** | Positive-depth source-glyph solid text | Model-space placement, rotation, size, source glyphs, and depth are verified. |
  | **Glyphs** | Per-glyph grouped source outlines | Outline identity, grouping, placement, rotation, size, and visibility are verified. |
  | **Geometry** | Source/page path edges | Geometry remains separate from Glyph groups and is verified as owned physical edges. |
  | **Raster** | Source-bound image | Canonical text items use verified item crops; a zero-canonical-text selected page uses a verified page image. |

  Evidence keeps two page-image cases distinct. Explicit full-page Raster from
  the Raster import strategy records semantic text not evaluated; it
  must not claim that the page contains no text. Text-rendering Raster may use a
  page image only with verified zero-canonical-text proof bound to the exact PDF
  bytes and page. Item crops come from one transparent RGBA page render per page
  and use streaming Ruby cropping. A crop must retain alpha-channel provenance
  and visible pixels, but may be fully opaque; it is not rejected merely because
  it contains no `alpha < 255` pixel. One reference PDF digest is cached per
  import, while full bytes are checked immediately before/after each renderer and
  before commit—never once per item. Saved/reopened Raster acceptance exports the
  actual SketchUp texture and matches its decoded visual-pixel digest and size;
  importer attributes alone are not proof.

  Use **3D Text** for go-live visual comparison against Adobe at equal zoom.
  Use **Labels** only when you need to edit piece marks or notes after import.
  Use **Text** when you want the closest verified text result automatically;
  SketchUp 2017 reaches exact source-outline 3D Text because its flat annotation
  API cannot preserve source size. Use **Glyphs** or **Geometry** when the
  corresponding exact outline structure is preferred. The selected option is sacred: fix transforms in-mode; do
  not switch representation to paper over alignment/rotation/scale bugs
  just to make a defect less visible.

  ### Text-mode fidelity and failure handling

  The selected text representation is always attempted first and verified in
  that exact type. Placement, rotation, width, and height are read back after
  the final transform. A generic failed proof cleans its exact partial artifacts
  and stops; it cannot trigger a representation change.

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
- **Quick Scale** with 15 architectural/engineering ratio preferences
  (`1/4"=1'-0"`, `3/8"=1'`, etc.)
- **Architectural scale notation parsing**
- **Import quality assessment** with warnings and performance metrics
- **Post-import action workflow** (geometry only, scale, cleanup, feature inventory)
- **Native DXF bridge command** from the extension menu/toolbar
- **Tag visibility controls** for PDF layers
- **Document profiling** (fabrication, CAD, architectural, vector art, raster)
  drives Auto-mode strategy selection
- **FlateDecode decompression** for compressed PDF streams
- **Form XObject recursion** for embedded PDF forms

---

## Installation

1. Download the latest `SketchUp-PDF-Importer_vX.Y.Z.rbz` from [Releases](https://github.com/BlueCollar-Systems/PDF-Importer-SketchUp/releases)
2. In SketchUp: **Window > Extension Manager > Install Extension**
3. Select the `.rbz` file
4. Restart SketchUp if prompted

The extension registers under **File > Import** and adds a PDF Vector Importer toolbar.

**Offline install:** The GitHub Release `.rbz` installs without internet. Core vector import and the bundled free Poppler helpers work offline. MuPDF and Ghostscript are not in the RBZ; only those optional paths need a separate free install when used.

For SketchUp 2025 users: native PDF import discoverability changed in SketchUp UI,
but this extension still provides dedicated PDF import menu and toolbar commands.

## Upgrading / skipping versions

Install the latest `.rbz` from Releases via Extension Manager (overwrites the prior extension). When the version changes, SketchUp shows a **one-time update notice** on next launch — run **Compatibility Report** and retest one of your own representative PDFs before shop use. Skipping intermediate versions (e.g. 3.7.55 → 3.7.70) is supported; there is no incremental migration tool.

## Enterprise / multi-user installs

Install the RBZ **per Windows user** on each PC where SketchUp runs. Avoid roaming only the `Plugins` folder across PCs with different SketchUp years. **Compatibility Report** records extension/helper capability status while redacting local extension and executable paths, so the copied report is safe to share in IT support tickets.

## External Helpers / Any-PC Behavior

The importer must run on a supported PC without hardcoded local paths. Helpers
are detected at runtime and reported through **Extensions > PDF Vector
Importer > Compatibility Report**.

Windows releases ship a free **zero-ceremony** Poppler runtime inside the RBZ
(`Library/bin` + `share/poppler` + integrity manifest). Clean-machine users do
not need to download Poppler separately for helper-dependent text, raster, or
SVG paths. MuPDF and Ghostscript remain optional free/system installs when used.
Use **Compatibility Report** to verify the exact helper path before importing.

| Helper | Used for | If missing |
|--------|----------|------------|
| MuPDF `mutool` | Same-representation SVG/glyph text geometry when Poppler is not installed | Poppler may supply the same representation; otherwise that requested SVG representation stops |
| Poppler `pdftocairo` | SVG/glyph text geometry and explicit raster page rendering | A separately verified same-representation source may be tried; otherwise that requested helper path stops |
| Poppler `pdftotext` | Higher-fidelity text bounding boxes and line reconstruction | Internal text parser fallback is used |
| Poppler `pdffonts` | Detecting non-embedded fonts before SVG text rendering | Font preflight is unavailable |
| Ghostscript | Embedding non-embedded fonts into a temporary render copy when needed | An outline attempt with unresolved or skipped glyphs fails its fidelity proof; it is not silently approximated |

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

### Quick Scale Presets

The Quick Scale dialog provides 15 architectural and engineering presets:

| Preset | Scale Ratio | Factor | Common Use |
|--------|-------------|--------|------------|
| 1:1 | Full size | 1.0 | Detail drawings |
| 1:2 | Half size | 0.5 | Large details |
| 1:4 | Quarter size | 0.25 | Construction details |
| 1:5 | 1/5 size | 0.2 | Detail drawings (metric) |
| 1:8 | 1/8 size | 0.125 | Room plans |
| 1:10 | 1/10 size | 0.1 | Detailed plans (metric) |
| 1:16 | 1/16 size | 0.0625 | Section drawings |
| 1:20 | 1/20 size | 0.05 | Building plans (metric) |
| 1:24 | 1/24 size | 0.04167 | 1/2"=1'-0" plans |
| 1:48 | 1/48 size | 0.02083 | 1/4"=1'-0" plans |
| 1:50 | 1/50 size | 0.02 | General plans (metric) |
| 1:96 | 1/96 size | 0.01042 | 1/8"=1'-0" plans |
| 1:100 | 1/100 size | 0.01 | Site plans (metric) |
| 1:192 | 1/192 size | 0.00521 | 1/16"=1'-0" plans |
| 1:200 | 1/200 size | 0.005 | Site plans (metric) |

The tool also accepts freeform architectural notation such as `1/4"=1'-0"`, `3/8"=1'`, `1"=10'`, and similar formats.

---

## Import Report

After every import, the extension presents a quality assessment report with three sections:

### Quality Assessment (diagnostics only)

The post-import report shows a **quality grade** as a diagnostic summary of what the parser observed — not a user-selectable fidelity tier. Every import targets maximum fidelity (BCS-ARCH-001); the grade helps you decide whether to review the result, not which "speed vs quality" mode to use.

- **Excellent** -- All vectors parsed, arcs reconstructed, no anomalies
- **Good** -- Minor issues (small gaps, unclosed paths) that do not affect usability
- **Fair** -- Some geometry lost or degraded; manual review recommended
- **Poor** -- Significant parsing failures; consider alternate export settings or source PDF export settings

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
| **Compression filters** | FlateDecode is supported. LZWDecode, ASCII85Decode, ASCIIHexDecode, and RunLengthDecode streams are not fully supported and may be skipped. |
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

**BlueCollar Systems** -- BUILT. NOT BOUGHT.
