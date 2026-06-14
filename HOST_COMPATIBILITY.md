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

### Text rendering

| Option | SketchUp result |
|--------|-----------------|
| **Geometry** | Text as edges only; first-run fallback and recommended production path |
| **Glyphs** | Per-glyph edges; same high-fidelity SVG path pipeline |
| **Labels** | Editable text entities; required to meet the same visual accuracy gate |
| **3D Text** | 3D / extruded text geometry; required to meet the same visual accuracy gate |

The dialog restores the last text rendering option used. It does not force Geometry after the user chooses another valid mode.

### PDF layers / SketchUp Tags

**Match PDF Layers** defaults to **Yes**. When a PDF has Optional Content Group layer data, the importer creates matching SketchUp Tags from the PDF layer names. Content without a PDF layer falls back to `PDF Import`; disabling the option intentionally routes content to the single import layer.

## CI coverage

GitHub Actions: `ruby -c` on extension sources under Ruby **2.2, 2.7, 3.2**; smoke tests under **2.2, 2.7, 3.0, 3.2** (Docker for 2.2). Graceful degradation paths exist for SU 2017 (line_styles absent, zoom extents fallback, UI.inputbox dialog fallback).
