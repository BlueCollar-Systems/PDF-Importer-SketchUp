# Agent guidance — PDF Vector Importer (SketchUp)

## Standing product doctrine: text-mode fidelity

**Cursor rule (authoritative, always-on):** [`.cursor/rules/text-mode-fidelity.mdc`](.cursor/rules/text-mode-fidelity.mdc)

**Hard contract:** requested text mode (Geometry / Glyphs / Labels / 3D Text / raster) is the deliverable. Alignment, rotation, and scale are fixed **in that mode** — never by switching representation, especially when those transforms worked before. Fallback only when that *(importer, option, PDF)* cannot produce the mode; then closest free option first (ladder below). Visually accurate, host-native/bundled, **no paid path**.

**Agent trap:** “text looks wrong” ≠ “change the mode.” Wrong position/angle/size → transform fix. Mode change without proven impossibility = reject.

### SketchUp text-mode fallback chain

UI / code names from `ImportDialog::TEXT_MODE_CHOICES` / symbols `:geometry`, `:glyphs`, `:labels`, `:text3d`:

| Priority | Mode | When to use as fallback |
|----------|------|-------------------------|
| 0 | **Requested mode** | Always first; fix transforms here |
| 1 | **Glyphs ↔ Geometry** | Peer outline family (same `SvgTextRenderer` today — no distinct peer engine yet; on SVG failure skip to 3D Text) |
| 2 | **3D Text** | Next free model-space representation |
| 3 | **Labels** | Editable native text when mesh/outline unavailable |
| 4 | **Page raster** | Completeness last resort (`raster_fallback` / Raster import strategy) |

Report every degradation (`degraded: true`, import report / Import Health). Never silently omit text.

### Do not misread these as “change the mode”

| Contract | Means |
|----------|--------|
| **SIZE-1** | Nominal PDF pt height only — no bbox-fit shrink/grow. Still inside the selected mode. |
| **R20-2** | Ruby 2.2-safe height bounds + loud telemetry. Still 3D Text (or whatever was requested). |
| Labels host limits | SketchUp `Text` is screen-space / limited rotation — stay in Labels; do not silently mesh-convert. |

### Conflict notes (reconciled)

- Older pipeline comments that “Geometry/Glyphs fail closed to labels so mesh stays accurate” are **superseded**: after SVG failure, fall to **3D Text** before Labels (mode-fidelity doctrine). Fix mesh transforms separately; do not skip 3D Text to avoid facing them.
- Test wording that “rotated labels prefer geometry mesh” is wrong: Labels mode keeps native labels; `angle_needs_geometry_text?` only chooses a direction vector for `add_text`.

## Other pointers

- Host / text-mode matrix: [`HOST_COMPATIBILITY.md`](HOST_COMPATIBILITY.md), [`COMPATIBILITY.md`](COMPATIBILITY.md), [`README.md`](README.md)
- Q&A corpus (external): contributor handoff SIZE-1 / R20-2 / Labels contract — do not reopen bbox-fit without live-host evidence
- **Not on main yet:** worktree/branch `codex/sketchup-3d-text-parity` (plan/spec under `docs/superpowers/` for **3.7.95** 3D Text visual parity). Do not merge until live SketchUp 2017 acceptance; keep SIZE-1 locks on main until that design lands with updated tests.
