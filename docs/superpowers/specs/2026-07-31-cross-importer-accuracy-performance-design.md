# Cross-Importer Accuracy & Performance Design

**Status:** Reconciled with owner doctrine  
**Approved:** 2026-07-31  
**Choice:** Sequenced both — Phase A sweep triage, then Phase B shared fidelity/perf  
**Hosts:** SketchUp, LibreCAD, Blender, FreeCAD  
**Sweep hub (local only):** `C:\TMP\cross-importer-sweep-20260730`  
**Corpus (local only):** `C:\Users\Rowdy Payton\Desktop\PDFTest Files` — never commit PDFs or derived CAD

## 1. Goals & sequencing

**Goal:** Raise accuracy and performance across all four importers for all import modes and text modes, without weakening text-mode fidelity, and without putting Desktop `PDFTest Files` (or derived CAD) into any repository.

| Phase | Focus | Exit criteria |
|-------|--------|----------------|
| **A — Sweep triage** | Fix concrete fail classes from the cross-importer sweep | Fail buckets drop sharply on re-run; artifacts stay under Desktop / `C:\TMP` |
| **B — Shared fidelity + perf** | Port reusable rotation, indexing, caching, and evidence methods while retaining each host's finite contract ladder | Dense shop drawings stay correct *and* faster; no unauthorized mode swaps |

**Hard constraints**
1. Requested text mode wins; wrong position/angle/size is an in-mode transform fix.
2. Finite closest ladders only; item-scoped affirmative impossibility before any rung advance.
3. Free / host-native / bundled only — no paid path.
4. Corpus and CAD counterparts never enter git (see `.gitignore` containment blocks; `steel_shapes/**` remains shipped product).
5. SketchUp 2017 uses verified source-outline 3D Text rather than the unstable native `add_3d_text` path. It is accepted only after saved/reopened host evidence proves placement, rotation, size, positive depth, and source identity.

## 2. Phase A — Sweep triage

### A1 LibreCAD (~30 fails)
| Bucket | Evidence | Plan |
|--------|----------|------|
| Huge map pages (`TX_Alvord…` ×24) | `native DXF text failed type or visual verification` on dense spans | Fix false-negative type/visual verification or placement for map-scale text; page-1 acceptance gate |
| Shop `text_mode=raster` on 1011 | CLI exit 2 | Item-raster text must certify or fail with exact ladder reason — no silent empty DXF |
| `alvord-2013` (×4) | Same stress family | Reuse map-text fix; timeout/memory guardrails without dropping fidelity |

### A2 FreeCAD (~31 fails)
| Bucket | Evidence | Plan |
|--------|----------|------|
| `glyphs` / `geometry` | `svg_item_assignment_empty` (e.g. `p1:b86:l0:s2`) | Fix SVG glyph→item assignment (SketchUp-hardened matching class); only then certified next-rung |
| `labels` (×11) | Ladder/host stops | Zero rotation → native Labels; nonzero → verified 3D Text (no geometry shortcut) |

### A3 SketchUp (partial)
- Keep `skp_export_only` for QA exports; respect exclusive host lock when another controlled sweep owns SketchUp.
- Triage Labels/text signal-11 and `report representation readiness mismatch` after SKP save.
- Validate requested `text3d` through the source-outline renderer on SketchUp 2017; keep the unstable native `add_3d_text` path out of this workflow.

### A4 Blender
- Preserve inline image placements that the former XObject-only path omitted, then rerun the affected Attachment pages in native Blender with saved/reopened `.blend` evidence.

### Phase A done when
The affected matrix is rerun from `C:\TMP`/Desktop Imported Evidence with saved/reopened host models: FreeCAD glyphs/geometry and LibreCAD map-text failures drop materially; SketchUp shop Text/Labels/3D Text evidence remains accurate; Blender's affected inline-image cells are re-proven; no corpus enters a repository.

## 3. Phase B — Shared fidelity + performance

Port methods proven on SketchUp shop drawings (`1011`) and dense-text perf (v3.7.114–120):

1. **Finite host-specific ladders** — all hosts expose the same six requested representations, but each host retains its own justified, tested fallback order. Shared vocabulary does not imply a fleet-global ladder.
2. **Residual semantic rotation** — when SVG glyph matrices are axis-aligned but PDF angle is nonzero, apply residual rotation in 3D/solid text paths (already in SketchUp `Svg3DTextRenderer`; mirror where hosts use SVG outlines).
3. **Angle-hint indexing** — O(N log N) nearest-hint lookup for short tokens; no per-span full scans on dense pages.
4. **Shared outline / instance reuse** — build unique glyph solids once; instance with transforms (SketchUp defs pattern → FreeCAD compounds / LibreCAD block-like reuse where DXF allows).
5. **Import-mode orthogonality** — `auto|vector|raster|hybrid` must not rewrite text-mode contracts.
6. **QA methodology** — page-1 tractable matrix; `skp_export_only` / headless JSON reports; fail classification into buckets; corpus outside git.

### Phase B done when
- Shop PDF text/labels/3d_text/glyphs stay in-mode accurate on all four hosts for page 1.
- Dense pages show measurable time reduction without fidelity loss.
- Blender remains green; LibreCAD/FreeCAD map and glyphs buckets stay fixed under regression.

## 4. Non-goals
- Committing or redistributing `PDFTest Files` or Imported Evidence trees.
- Paying for fonts/APIs.
- Replacing a host-specific finite ladder with a fleet-global shortcut.
- Treating page-1 smoke tests as full-corpus or multipage acceptance.

## 5. Verification
- Unit/integration tests in each repo (synthetic fixtures only in-repo).
- Optional local re-smoke against Desktop corpus → `C:\TMP` only.
- Confirm `git ls-files` has no corpus PDFs/CAD; `.gitignore` containment remains.
