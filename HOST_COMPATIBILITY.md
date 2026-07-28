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

If a helper is missing, the Compatibility Report must say which capability is
unavailable. A same-representation source may be tried only when it is
independently verified; missing helpers do not authorize changing the requested
representation.

### Text rendering

| Option | SketchUp result |
|--------|-----------------|
| **Text** | Distinct flat editable model text when the host exposes a constructor; SketchUp 2017 does not, so an exact item-bound capability proof may advance only to Labels |
| **Labels** | Editable `Sketchup::Text` when the host can represent the item; nonzero glyph rotation enters the verified closest fallback ladder |
| **3D Text** | Source-glyph solid text with verified positive Z depth; preserves model-space size and PDF rotation |
| **Glyphs** | Per-glyph edges; high-fidelity outline path when exact geometry is preferred |
| **Geometry** | Text as edges only; outline geometry when the user selects that option |
| **Raster** | Verified source-bound item crop, or a verified page image for a selected zero-canonical-text page |

Explicit full-page Raster records semantic text not evaluated and never
masquerades as a no-text finding. A page image selected by the text-rendering
Raster path requires verified zero-canonical-text proof for the exact PDF bytes
and page. Item images retain the RGBA provenance of one transparent page render
per page and contain visible pixels. A crop can validly be fully opaque; absence
of an `alpha < 255` pixel inside that crop is not a failure. Cropping is streaming
Ruby 2.2-safe code and adds no paid dependency. The importer caches one reference
PDF digest, verifies the full bytes immediately before and after each renderer,
and verifies them again before commit; it never renders or hashes once per item.
Saved/reopened Raster evidence is physical: SketchUp `TextureWriter` must export
the actual image, and its decoded visual-pixel digest and dimensions must match.
Self-authored attributes alone cannot certify the texture.

The dialog defaults to 3D Text on first run and restores the last text rendering option used after that. Labels are an editability tradeoff, not the default visual sign-off mode.

**Mode fidelity:** honor the selected text option first. Fix alignment/rotation/scale inside that mode — do not switch representation to paper over transform bugs. A missing helper, generic exception, empty artifact, or broken implementation cannot authorize fallback. The exact ladders are Text → Labels → 3D Text → Glyphs → Geometry → item Raster; Labels → 3D Text → Glyphs → Geometry → item Raster; 3D Text → Glyphs → Geometry → item Raster; Glyphs → Geometry → item Raster; and Geometry → item Raster. Raster has no next rung. Requested Raster uses verified item crops when canonical text spans exist and a verified page image for a selected zero-canonical-text page; fallback Raster is item-scoped. Each adjacent rung requires its own renderer and type/visual certificate. Terminal Raster can still fail verification, in which case the exact failure is reported and delivery stops. Successful peer spans and page geometry remain intact. See [AGENTS.md](AGENTS.md) and `.cursor/rules/text-mode-fidelity.mdc`.

Native Labels are certified only after the host reads back a `Text` entity with
the exact content, all three anchor/direction coordinates, and its leader hidden.
`Text#vector` controls the leader, not glyph orientation. A nonzero requested
glyph rotation is an affirmative host-representation impossibility for that item,
so the closest next attempt is source-glyph 3D Text—not a direct geometry swap.
If both text extractors return no spans, the importer checks page and referenced
Form-XObject streams for real painting text-show operands before accepting a
no-text page; undecodable text is not silently omitted.

**Poppler proof scope:** process exit status and a nonempty SVG are transport
evidence, not semantic completeness. The known Adobe-GB1 diagnostic cluster may
be deferred only for the exact public fixture PDF/page/output certificate, then
must also pass the current page's real Cairo source-span match and host-placement
checks. `unmatched_source_runs`, `unmatched_placements`,
`missing_language_packs`, `skipped_placements`, and `placement_failures` must
each be present as arrays and empty. A missing collection fails closed. This is
a fixture-scoped exception, not a general CID-completeness claim.

**Zero-ceremony Poppler and legacy runtime trust:** Windows release RBZ files
ship a free integrity-checked Poppler runtime under `Library/bin` and
`share/poppler`. Selection is fail-closed: a runtime is eligible only after its
canonical member digest, exact files/directories, sizes, and hashes validate. A
direct `bin` tree, an extra member, or a symlinked manifest/path component
disables selection. Only a successful full verification is cached, and symlink
trust paths are still checked before each selection. System/env helpers remain
available as overrides.

### PDF layers / SketchUp Tags

**Match PDF Layers** defaults to **Yes**. When a PDF has Optional Content Group layer data, the importer creates matching SketchUp Tags from the PDF layer names. Content without a PDF layer falls back to `PDF Import`; disabling the option intentionally routes content to the single import layer.

## CI coverage

GitHub Actions: `ruby -c` on extension sources under Ruby **2.2, 2.7, 3.2**; smoke tests under **2.2, 2.7, 3.0, 3.2** (Docker for 2.2). Graceful degradation paths exist for SU 2017 (line_styles absent, zoom extents fallback, UI.inputbox dialog fallback).
