# Agent guidance — PDF Vector Importer (SketchUp)

## Standing product doctrine: text-mode fidelity

**Cursor rule (authoritative, always-on):** [`.cursor/rules/text-mode-fidelity.mdc`](.cursor/rules/text-mode-fidelity.mdc)

**Owner ruling (2026-10-05): deliver, step down, report.** One failing item never
costs the page or the file. Deliver the page. When one item cannot be delivered in
the requested mode, step that item down (text → glyphs → outlines → picture), and
when no rung can deliver it yet, leave that item out, erase only that item's partial
artifacts, and keep everything else on the page. List every step-down and every
item left out, with its reason, in the import report (`fallback.used`,
`extra.human_summary`, `extra.text_delivery_failures`, `extra.text_step_downs`,
`extra.page_step_downs`), in Import Health, and in the end-of-import status line.
Proofs (impossibility proofs, certification digests, full-file re-hashes) belong in
the optional Audit setting (`BC_PDF_AUDIT=1`, "Audit import (slow self-checks)",
default off) or in CI. A missing proof, a missing or blocked helper, a host/API
limit, or an exception is **never** a reason to stop the import or to drop a page
or a file. Esc, an uncertain host rollback, and a changed resume journal still stop
the run, and a page whose own geometry build fails (or whose partial artifacts
cannot be removed) is still rolled back and listed as a failed page.

**Hard contract:** requested text mode (Text / Labels / 3D Text / Glyphs / Geometry / Raster) is the deliverable. Alignment, rotation, and scale are fixed **in that mode** — never by switching representation, especially when those transforms worked before. A step-down is for an item that actually failed in the requested mode, never a fix for a transform bug, and it is always listed. Visually accurate, host-native/bundled, **no paid path**.

**Agent trap:** “text looks wrong” ≠ “change the mode.” Wrong position/angle/size → transform fix. Mode change to hide a transform bug = reject.

### Current SketchUp text-mode execution rule

UI / code names from `ImportDialog::TEXT_MODE_CHOICES` / symbols `:text`, `:labels`, `:text3d`, `:glyphs`, `:geometry`, `:raster`:

| Requested mode | Required first attempt | Finite closest fallback after affirmative item proof |
|----------------|------------------------|-----------------------------------------------------|
| **Text** | Distinct flat editable model Text; never a Label alias | 3D Text → Glyphs → Geometry → item Raster |
| **Labels** | Item-bound capability observation; on SketchUp 2017 every finite-bbox source proves size/run width or rotation unsupported before native `Sketchup::Text` creation, then advances to the source-outline 3D visual equivalent (not a native editable annotation) | 3D Text → Glyphs → Geometry → item Raster |
| **3D Text** | Source-glyph solid text with positive Z depth | Glyphs → Geometry → item Raster |
| **Glyphs** | Source glyph outlines | Geometry → item Raster |
| **Geometry** | Page/source path geometry | Item Raster |
| **Raster** | Verified item crop, or verified page image for a selected zero-canonical-text page | None; Raster is already terminal |

The exact ladders are Text → 3D Text → Glyphs → Geometry → item Raster;
Labels → 3D Text → Glyphs → Geometry → item Raster; 3D Text → Glyphs → Geometry
→ item Raster; Glyphs → Geometry → item Raster; and Geometry → item Raster.
Raster has no next rung. Terminal Raster can still fail verification; a failed
render, crop, ownership, placement, or visual check lists that item as not
delivered with the exact failure (never recorded as a successful delivery), and
the rest of the page stays.

Do not merge the two page-Raster evidence states. Explicit full-page Raster means
semantic text not evaluated; it is not affirmative no-text proof. Text-rendering
Raster may create a page image only from verified zero-canonical-text proof bound
to the exact PDF bytes and page. Item Raster starts from one transparent RGBA page
render and every crop must retain that alpha-channel provenance and at least one
visible pixel. A crop may legitimately be fully covered by opaque source ink; never
require an `alpha < 255` pixel inside every crop. Keep one cached reference digest per
import, and verify the full PDF digest immediately before and after every renderer
command. The full re-hash before each page commit (and every other per-page re-read
of the whole PDF) runs only with Audit import on (`BC_PDF_AUDIT=1`, `--audit`, or the
saved setting); with Audit off the PDF is hashed once per import and the commit gate
trusts its size and times. Do not launch Poppler or hash the PDF per text item;
stream item crops in Ruby 2.2-safe code.

Raster acceptance must export the saved/reopened `Sketchup::Image` through the real
`TextureWriter`, require a successful file, decode its RGB/RGBA pixels, and compare
canonical visual-pixel digest and dimensions. Importer-written attributes and PNG
headers describe a claim; they are not physical host-image proof.

Missing/skipped helpers, generic host/API limits, exceptions, empty artifacts,
or currently broken code are reasons to **step that item down and list it**, never
reasons to stop the import or drop the page or file (owner ruling 2026-10-05).
Advance one rung at a time, check what the new rung actually built, and repeat
finitely. When no rung can deliver the item (or the next rung is not built yet),
erase only that item's partial artifacts, list the exact source span and reason,
and keep going: the page's lines, fills, pictures and other text stay. Never
silently omit text, and never erase successful peer spans or page geometry to
make a step-down easier. Heavy proofs run only with Audit on or in CI.

For helper semantic gates, absence is failure—not an empty success collection.
Every required source-match, language-pack, skipped-placement, and
host-placement evidence field must be present with the documented type before
it may certify a page. Build final completeness proof only after real current
source spans have been matched to created host entities; return code zero,
nonempty output, or pre-placement SVG structure is never sufficient.

SketchUp 2017 `Sketchup::Text` is a screen annotation: it exposes neither
source-glyph size nor run-width control, and `Text#vector` controls the leader,
not glyph rotation. A canonical finite-bbox Labels item therefore produces an
affirmative, item-bound host-representation proof before `add_text`: nonzero
rotation uses the rotation proof and a horizontal item uses the source-size/run-
width proof. Both advance exactly one rung to verified source-outline 3D Text.
The fallback must retain the exact semantic text hash, source span, placement,
and provenance. It must never silently skip to Raster. Missing or invalid source
dimensions cannot support this proof; that item is listed as not delivered,
without creating an entity, and the rest of the page stays.

An empty extractor result is a no-text proof only when decoded page streams and
referenced Form XObjects contain no nonempty painting text-show operands. Ignore
inline-image bytes and `Tr 3` non-painting OCR text; otherwise list the page's text
as not read (`text_not_read`) and still deliver the page's lines, fills and
pictures.

### Do not misread these as “change the mode”

| Contract | Means |
|----------|--------|
| **SIZE-1** | Nominal PDF pt height only — no bbox-fit shrink/grow. Still inside the selected mode. |
| **R20-2** | Ruby 2.2-safe height bounds + loud telemetry. Still 3D Text (or whatever was requested). |
| Labels host limits | Attempt the Labels rung first. For a finite source bbox, prove the SketchUp 2017 size/run-width or rotation limitation before native entity creation, then advance one rung to verified source-outline 3D Text. |

### Conflict notes (reconciled)

- Older peer-swapping ladders such as Geometry/Glyphs → 3D Text → Labels → page raster are **superseded**. Use only the finite closest ladders above, one proven item transition at a time.
- “Labels can remain native and editable while matching the PDF” is wrong for finite-bbox source spans in SketchUp 2017. The item-bound Labels capability proof advances only to verified source-outline 3D Text; it never jumps directly to Geometry or Raster.

## Text this PDF cannot turn into characters

A `/Type0` font with an Identity CMap and **no** `/ToUnicode` leaves the content stream holding glyph indices
into an embedded subset, and nothing in the PDF says what they mean. This importer draws them anyway, because
that is all the document gives it. The bytes are frequently printable ASCII, so what lands on the sheet is
legible and **wrong** - a member mark reads `06-3` where the drawing says `MS-3`.

`PDFParser#page_font_glyph_code_status` classifies every font on a page from the PDF's own font dictionaries,
and `GlyphCodeReport` publishes `extra.text_glyph_codes` (`bcs.text_glyph_codes/1.0`) plus one warning line per
import. Nothing about what is drawn changes: this reports the defect, it does not fix it.

Three rules if you touch this:

- **The trigger is that exact structure, not "no `/ToUnicode`".** Measured on 120 corpus sheets: 297 fonts on
  page 1, 4 affected, and **155 with no `/ToUnicode` that decode perfectly**, because WinAnsi and MacRoman are
  real encodings. Widening the trigger condemns all of them.
- **Never detect by scanning the delivered text for control characters.** That check misses exactly the spans
  that read as plausible, which are the dangerous ones. The verdict comes from the font dictionaries.
- **Per-item records exist only where this host parsed the content stream itself.** Poppler's `-bbox-layout`
  output carries no font identity, so on that path the fonts are named and the items are not, and the block
  says `attribution: fonts_only`. That is a limit of the run, never something the document failed to say, and
  the two are not reported in the same sentence.

Recovery is a separate change and is deliberately not attempted here. On the measured sheet the embedded subset
carries neither a `cmap` nor a `post` table, so the only route that can succeed is comparing the subset's own
outlines against a reference face - a TrueType parser in Ruby 2.2.4, not a small addition.

## Other pointers

- Host / text-mode matrix: [`HOST_COMPATIBILITY.md`](HOST_COMPATIBILITY.md), [`COMPATIBILITY.md`](COMPATIBILITY.md), [`README.md`](README.md)
- Acceptance must cover mixed per-span success/fallback, requested item Raster, requested zero-canonical-text page Raster, rotated Labels, and save/reopen/source-file deletion in SketchUp 2017 and a current SketchUp release. Raster failure remains an allowed truthful terminal result when verification cannot pass.
