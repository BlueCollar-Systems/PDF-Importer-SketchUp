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
| **Labels** | Editable text entities |
| **3D Text** | 3D / extruded text geometry |
| **Glyphs** | Per-glyph edges |
| **Geometry** | Text as edges only |

## CI coverage

GitHub Actions: `ruby -c` on extension sources under Ruby **2.2, 2.7, 3.2**.
