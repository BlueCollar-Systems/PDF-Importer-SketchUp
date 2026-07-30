# Agent guidance — PDF Vector Importer (SketchUp)

## Standing product doctrine: text-mode fidelity

**Cursor rule (authoritative, always-on):** [`.cursor/rules/text-mode-fidelity.mdc`](.cursor/rules/text-mode-fidelity.mdc)

**Hard contract:** requested text mode (Text / Labels / 3D Text / Glyphs / Geometry / Raster) is the deliverable. Alignment, rotation, and scale are fixed **in that mode** — never by switching representation, especially when those transforms worked before. A different representation is unauthorized unless affirmative, item-scoped evidence proves the requested representation impossible **and** the alternative has its own certified type-and-visual attempt. Visually accurate, host-native/bundled, **no paid path**.

**Agent trap:** “text looks wrong” ≠ “change the mode.” Wrong position/angle/size → transform fix. Mode change without proven impossibility = reject.

### Current SketchUp text-mode execution rule

UI / code names from `ImportDialog::TEXT_MODE_CHOICES` / symbols `:text`, `:labels`, `:text3d`, `:glyphs`, `:geometry`, `:raster`:

| Requested mode | Required first attempt | Finite closest fallback after affirmative item proof |
|----------------|------------------------|-----------------------------------------------------|
| **Text** | Distinct flat editable model Text; never a Label alias | Labels → 3D Text → Glyphs → Geometry → item Raster |
| **Labels** | Native `Sketchup::Text` Label | 3D Text → Glyphs → Geometry → item Raster |
| **3D Text** | Source-glyph solid text with positive Z depth | Glyphs → Geometry → item Raster |
| **Glyphs** | Source glyph outlines | Geometry → item Raster |
| **Geometry** | Page/source path geometry | Item Raster |
| **Raster** | Verified item crop, or verified page image for a selected zero-canonical-text page | None; Raster is already terminal |

The exact ladders are Text → 3D Text → Glyphs → Geometry → item Raster;
Labels → 3D Text → Glyphs → Geometry → item Raster; 3D Text → Glyphs → Geometry
→ item Raster; Glyphs → Geometry → item Raster; and Geometry → item Raster.
Raster has no next rung. Terminal Raster can still fail verification; a failed
render, crop, ownership, placement, or visual check reports the exact failure and
stops rather than recording a successful delivery.

Do not merge the two page-Raster evidence states. Explicit full-page Raster means
semantic text not evaluated; it is not affirmative no-text proof. Text-rendering
Raster may create a page image only from verified zero-canonical-text proof bound
to the exact PDF bytes and page. Item Raster starts from one transparent RGBA page
render and every crop must retain that alpha-channel provenance and at least one
visible pixel. A crop may legitimately be fully covered by opaque source ink; never
require an `alpha < 255` pixel inside every crop. Keep one cached reference digest per
import, but verify the full PDF digest immediately before and after every renderer
command and again before commit. Do not launch Poppler or hash the PDF per text item;
stream item crops in Ruby 2.2-safe code.

Raster acceptance must export the saved/reopened `Sketchup::Image` through the real
`TextureWriter`, require a successful file, decode its RGB/RGBA pixels, and compare
canonical visual-pixel digest and dimensions. Importer-written attributes and PNG
headers describe a claim; they are not physical host-image proof.

Missing/skipped helpers, generic host/API limits, exceptions, empty artifacts,
or currently broken code do **not** prove item-specific impossibility and do not
authorize another rung. If an affirmative item-specific impossibility proof is
available, advance exactly one rung, verify the new entity type and visual
result, and repeat finitely. Otherwise erase partial artifacts, report the exact
source-span failure, and stop the operation. Never silently omit text or erase
successful peer spans/page geometry to make a fallback easier.

For helper semantic gates, absence is failure—not an empty success collection.
Every required source-match, language-pack, skipped-placement, and
host-placement evidence field must be present with the documented type before
it may certify a page. Build final completeness proof only after real current
source spans have been matched to created host entities; return code zero,
nonempty output, or pre-placement SVG structure is never sufficient.

For native Labels, certification includes readback of entity type, exact text,
all three anchor/direction coordinates, and hidden-leader state. SketchUp's
`Text#vector` is a leader vector, not glyph rotation. A nonzero model-space
rotation is therefore an affirmative host-representation impossibility for that
item after the Labels attempt; it enters Labels → 3D Text, not a geometry shortcut.

An empty extractor result is a no-text proof only when decoded page streams and
referenced Form XObjects contain no nonempty painting text-show operands. Ignore
inline-image bytes and `Tr 3` non-painting OCR text; otherwise stop explicitly.

### Do not misread these as “change the mode”

| Contract | Means |
|----------|--------|
| **SIZE-1** | Nominal PDF pt height only — no bbox-fit shrink/grow. Still inside the selected mode. |
| **R20-2** | Ruby 2.2-safe height bounds + loud telemetry. Still 3D Text (or whatever was requested). |
| Labels host limits | Try and certify native Labels first; a proven nonzero-rotation host limit advances one rung to verified 3D Text. |

### Conflict notes (reconciled)

- Older peer-swapping ladders such as Geometry/Glyphs → 3D Text → Labels → page raster are **superseded**. Use only the finite closest ladders above, one proven item transition at a time.
- “Rotated labels prefer geometry mesh” is wrong. Native Labels are attempted first; when the host cannot express that item rotation, the next rung is verified 3D Text.

## Other pointers

- Host / text-mode matrix: [`HOST_COMPATIBILITY.md`](HOST_COMPATIBILITY.md), [`COMPATIBILITY.md`](COMPATIBILITY.md), [`README.md`](README.md)
- Acceptance must cover mixed per-span success/fallback, requested item Raster, requested zero-canonical-text page Raster, rotated Labels, and save/reopen/source-file deletion in SketchUp 2017 and a current SketchUp release. Raster failure remains an allowed truthful terminal result when verification cannot pass.
