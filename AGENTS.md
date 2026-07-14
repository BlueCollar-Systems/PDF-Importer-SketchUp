# Agent guidance — PDF Vector Importer (SketchUp)

## Standing product doctrine: text-mode fidelity

**Cursor rule (authoritative, always-on):** [`.cursor/rules/text-mode-fidelity.mdc`](.cursor/rules/text-mode-fidelity.mdc)

Owner doctrine (paraphrase): if the importer is told to bring text in as text, labels, glyphs, 3D Text, geometry, or raster, that is what it must be. Do **not** alter the desired representation to correct alignment, rotation, or scaling — especially when those transforms worked in past versions. Fallback only when a specific *(importer, option, PDF)* cannot achieve the requested option. Then use the **most logical** next option (closest related first). There will be an option. Goal: visually accurate imports as close as possible to the user’s desired outcome, **at no financial cost**.

### SketchUp text-mode fallback chain

UI / code names from `ImportDialog::TEXT_MODE_CHOICES` / symbols `:geometry`, `:glyphs`, `:labels`, `:text3d`:

| Priority | Mode | When to use as fallback |
|----------|------|-------------------------|
| 0 | **Requested mode** | Always first; fix transforms here |
| 1 | **Glyphs ↔ Geometry** | Peer outline paths (both need Poppler/MuPDF SVG today) |
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
