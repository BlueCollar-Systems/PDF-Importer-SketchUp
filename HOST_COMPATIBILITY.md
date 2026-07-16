# Host Compatibility — PDF Vector Importer (SketchUp)

Modes are extraction **strategy** (Auto / Vector / Raster / Hybrid), not quality tiers.

**GUI:** Single **professional import** dialog — **Auto** per page by default. **Advanced** exposes explicit Vector/Raster/Hybrid and layout options.

## SketchUp

| SketchUp | Ruby | Status |
|----------|------|--------|
| Current Pro (verify Ruby at install) | 3.2.x+ | ⚠️ Expected |
| 2024 | 3.2.2 | ⚠️ Expected |
| 2020–2023 | 2.7.x | ⚠️ Expected |
| 2018–2019 | 2.5.x | ⚠️ Expected |
| Make / Pro 2017 | 2.2.4 | ⚠️ Expected (CI syntax-checked) |
| 2014–2016 | 2.0.x | ⚠️ Expected only after dedicated host verification |
| 2013 and earlier | | ❌ Not supported |

See also [COMPATIBILITY.md](COMPATIBILITY.md) for Ruby 2.2 language constraints.

## Any-PC helper policy

Core vector import must run inside supported SketchUp versions without Ruby gems
or C extensions. Optional helper executables may improve fidelity, but the
importer must detect them rather than assume this workstation's paths.

| Helper | Capability unlocked |
|--------|---------------------|
| MuPDF `mutool` | SVG/glyph text rendering when Poppler is absent |
| Poppler `pdftocairo` | SVG/glyph text rendering, raster page placement, SVG-assisted geometry recovery |
| Poppler `pdftotext` | Higher-fidelity external text extraction and bbox placement |
| Poppler `pdffonts` | Non-embedded font preflight before SVG rendering |
| Ghostscript | Temporary font embedding repair for PDFs with non-embedded fonts |

If a helper is missing, the feature must degrade through the built-in parser or a
documented host-native fallback, and the Compatibility Report must say what was
disabled.

### Text rendering

| Option | SketchUp result |
|--------|-----------------|
| **3D Text** | Default visual-parity path; preserves model-space size and PDF rotation for Adobe-like review |
| **Glyphs** | Per-glyph edges; high-fidelity outline path when exact geometry is preferred |
| **Geometry** | Text as edges only; outline geometry when the user selects that option |
| **Labels** | Editable text entities; horizontal and screen-space by SketchUp host behavior |

The dialog defaults to 3D Text on first run and restores the last text rendering option used after that. Labels are an editability tradeoff, not the default visual sign-off mode.

**Mode fidelity:** honor the selected text option. Fix alignment/rotation/scale inside that mode — do not switch representation to paper over transform bugs. If Geometry/Glyphs cannot run (no Poppler/MuPDF SVG), degrade **Glyphs ↔ Geometry → 3D Text → Labels → page raster** (Glyphs/Geometry share one SVG renderer today, so failure skips the peer rung and goes to 3D Text), report `degraded`, and stay free/bundled. See [AGENTS.md](AGENTS.md) and `.cursor/rules/text-mode-fidelity.mdc`.

### PDF layers / SketchUp Tags

**Match PDF Layers** defaults to **Yes**. When a PDF has Optional Content Group layer data, the importer creates matching SketchUp Tags from the PDF layer names. Content without a PDF layer falls back to `PDF Import`; disabling the option intentionally routes content to the single import layer.

## CI coverage

GitHub Actions: `ruby -c` on extension sources under Ruby **2.2, 2.7, 3.2**; smoke tests under **2.2, 2.7, 3.0, 3.2** (Docker for 2.2). Graceful degradation paths exist for SU 2017 (line_styles absent, zoom extents fallback, UI.inputbox dialog fallback).
