# PDF Vector Importer for SketchUp

**BUILT. NOT BOUGHT.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-3.6.8-green.svg)]()
[![Platform](https://img.shields.io/badge/Platform-SketchUp%202017%2B-orange.svg)]()
[![Ruby](https://img.shields.io/badge/Ruby-2.2%2B-red.svg)]()

Import PDF vector geometry as native editable SketchUp edges with arc reconstruction, color-based tag grouping, text import, dash patterns, Scale by Reference tool, and full Bezier support. Pure-Ruby PDF parser -- no external dependencies.

---

## Overview

PDF Vector Importer parses PDF content streams directly in Ruby and reconstructs vector geometry as native SketchUp edges. No gems, no external binaries, no C extensions. It runs on every platform SketchUp supports, from SketchUp 2017 Make (Ruby 2.2) through the current Pro release.

The importer profiles each PDF document to identify its origin (fabrication drawings, CAD exports, architectural plans, vector art, or raster scans) and adapts its import strategy accordingly.

---

## Key Features

- **Pure-Ruby PDF parser** -- no gems or external dependencies required
- **Adaptive Bezier subdivision** with configurable flatness tolerance
- **Kasa algebraic circle fitting** for arc reconstruction from point sequences
- **OCG layer support** -- PDF Optional Content Groups map to SketchUp Tags
- **Color-based tag grouping** with dash pattern mapping
- **Scale by Reference** tool -- select an edge, type the real-world dimension
- **Quick Scale** with 15 architectural/engineering presets
- **Architectural scale notation parsing** (1/4"=1'-0", 3/8"=1', etc.)
- **Text import** as geometry or labels
- **Raster fallback** for scanned pages
- **Import quality assessment** with warnings and performance metrics
- **Post-import action workflow** (geometry only, scale, cleanup, feature inventory)
- **Safe Mode import command** (Fast preset) for very dense/problem PDFs
- **Native DXF bridge command** from the extension menu/toolbar
- **Tag visibility controls** for PDF layers
- **Document profiling** (fabrication, CAD, architectural, vector art, raster)
- **FlateDecode decompression** for compressed PDF streams
- **Form XObject recursion** for embedded PDF forms

---

## Installation

1. Download `bc_pdf_vector_importer_v3.6.7.rbz`
2. In SketchUp: **Window > Extension Manager > Install Extension**
3. Select the `.rbz` file
4. Restart SketchUp if prompted

The extension registers under **File > Import** and adds a PDF Vector Importer toolbar.

For SketchUp 2025 users: native PDF import discoverability changed in SketchUp UI,
but this extension still provides dedicated PDF import menu and toolbar commands.

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

### Quality Assessment

Each import receives a quality grade based on geometry fidelity:

- **Excellent** -- All vectors parsed, arcs reconstructed, no anomalies
- **Good** -- Minor issues (small gaps, unclosed paths) that do not affect usability
- **Fair** -- Some geometry lost or degraded; manual review recommended
- **Poor** -- Significant parsing failures; consider alternate export settings

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
| **Embedded fonts** | Text rendered with embedded subset fonts may not extract correctly. The importer can fall back to external pdftotext for higher-fidelity text extraction. |
| **Clipped/XObject-heavy PDFs** | Deeply nested form XObjects and aggressive clipping can lead to partial geometry recovery. |
| **Raster-only scans** | Pure image/scanned PDFs with no vector operators will not produce SketchUp edges. |
| **Very large PDFs** | Files over 500 MB are rejected. Dense drawings with over 1 million path operators per stream are truncated. Split large documents before importing. |

---

## Compatibility

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
