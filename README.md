# PDF Vector Importer for SketchUp

**BUILT. NOT BOUGHT.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-3.7.41-green.svg)]()
[![Platform](https://img.shields.io/badge/Platform-SketchUp%202017%2B-orange.svg)]()
[![Ruby](https://img.shields.io/badge/Ruby-2.2%2B-red.svg)]()

Import PDF vector geometry as native editable SketchUp edges with arc reconstruction, color-based tag grouping, text import, dash patterns, Scale by Reference tool, and full Bezier support. Core vector import uses the built-in Ruby parser; current Windows release RBZ files also bundle Poppler helpers for better text/raster/SVG fidelity. Ghostscript remains optional for non-embedded font repair.

---

## Overview

PDF Vector Importer parses PDF content streams directly in Ruby and reconstructs vector geometry as native SketchUp edges. The core vector path does not require Ruby gems, C extensions, or external binaries. Higher-fidelity helper paths can use MuPDF (`mutool`), Poppler (`pdftocairo`, `pdftotext`) and Ghostscript when present, and degrade to built-in parsing when they are missing. It runs on supported SketchUp PCs from SketchUp 2017 Make (Ruby 2.2) through the current Pro release.

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
- **4 Text Rendering Options** — Geometry, Glyphs, Labels, 3D Text
  (orthogonal to mode) + separate Import text toggle. The dialog reopens
  with the last text rendering option used; first-run fallback is Geometry.
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

For SketchUp 2025 users: native PDF import discoverability changed in SketchUp UI,
but this extension still provides dedicated PDF import menu and toolbar commands.

## Bundled Helpers / Any-PC Behavior

The importer must run on a supported PC without hardcoded local paths. Optional
helpers are detected at runtime and reported through **Extensions > PDF Vector
Importer > Compatibility Report**.

Current Windows release RBZ files include Poppler `pdftocairo`, `pdftotext`,
`pdffonts`, and required DLLs under the extension `bin/` folder. Source builds
must run `tools/fetch_third_party_binaries.ps1` before `python build_release.py`;
the build fails if the bundled helper set is missing.

| Helper | Used for | If missing |
|--------|----------|------------|
| MuPDF `mutool` | SVG/glyph text geometry when Poppler is not installed | Poppler or built-in text fallback is used |
| Poppler `pdftocairo` | SVG/glyph text geometry, raster page rendering, and SVG-assisted geometry recovery | Built-in Ruby parser remains available; SVG/raster helper paths are disabled |
| Poppler `pdftotext` | Higher-fidelity text bounding boxes and line reconstruction | Internal text parser fallback is used |
| Poppler `pdffonts` | Detecting non-embedded fonts before SVG text rendering | Font preflight is unavailable |
| Ghostscript | Embedding non-embedded fonts into a temporary render copy when needed | Text still imports, but unresolved symbols may be skipped or approximated |

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
  stroke_font.rb                     # Single-stroke font rendering
  svg_geometry_renderer.rb           # SVG geometry path renderer
  svg_text_renderer.rb               # SVG text path renderer
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
| **Font-dependent text** | Text rendered with embedded subset fonts, non-embedded fonts, or platform-missing display fonts may require Poppler and Ghostscript for maximum fidelity. Without those helpers, the importer falls back to internal parsing and reports the reduced capability. |
| **Clipped/XObject-heavy PDFs** | Deeply nested form XObjects and aggressive clipping can lead to partial geometry recovery. |
| **Raster-only scans** | Pure image/scanned PDFs with no vector operators will not produce SketchUp edges. |
| **Very large PDFs** | Files over 500 MB are rejected. Dense drawings with over 1 million path operators per stream are truncated. Split large documents before importing. |

---

## Compatibility

See **[HOST_COMPATIBILITY.md](HOST_COMPATIBILITY.md)** (SketchUp hosts) and **[COMPATIBILITY.md](COMPATIBILITY.md)** (Ruby 2.2 language rules). Summary:

| SketchUp Version | Ruby Version | Status |
|-----------------|-------------|--------|
| Make 2017 | 2.2.4 | ⚠️ Expected (CI syntax-checked, not host-verified) |
| Pro 2017 | 2.2.4 | ⚠️ Expected |
| 2018–2019 | 2.5.x | ⚠️ Expected |
| 2020–2023 | 2.7.x | ⚠️ Expected |
| 2024 | 3.2.2 | ⚠️ Expected |
| 2025 | 3.2.x+ | ⚠️ Expected |
| Current Pro release | verify actual Ruby | ⚠️ Expected until host-tested |
| 2014–2016 | 2.0.x | ⚠️ Expected only after dedicated host verification |

Evidence levels:
- `✅ Verified`: host-run validation evidence captured.
- `⚠️ Expected`: syntax/runtime compatible but no host-run evidence yet.
- `❌ Not supported`: outside maintained/tested compatibility scope.

---

## Corpus placement CI

Headless regression gate over the shared PDF corpus: parser metrics, pdftotext
extraction, and simulated label placement vs committed baselines. See
[`test/CORPUS_CI.md`](test/CORPUS_CI.md).

```powershell
ruby test/corpus_placement_test.rb
ruby tools/generate_corpus_baselines.rb --update   # after reviewed changes
```

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
