# Q&A Index

Updated: 2026-06-24 (Field screenshot review — SU 3.7.59, BL 1.0.36, LC launcher)

## Source Instructions

- `Instructions 0607202613216.txt`

---

## Field screenshot review (2026-06-24) — **FIXED / DOCUMENTED**

Eleven field screenshots — BOM vertical text, Blender 5.1 PyMuPDF, LC launcher, SketchUp 2017 installer policy.

| File | Role |
|------|------|
| `QA-2026-06-24_screenshot-review-synthesis.md` | Per-screenshot symptoms, root causes, fixes |
| `QA-2026-06-24_text-mode-verification-matrix.md` | Host × text mode expected output + verify steps |
| `QA-2026-06-24_sketchup-2017-installer-website-policy.md` | **Do not host** SketchUp Make 2017 installer |

**Headline:** SU v3.7.59 BOM quantity rotation/anchor; BL v1.0.36 PyMuPDF bootstrap for Blender 5.x; LC launcher + portable-first docs; website non-redistribution note.

---

## Text & leader alignment (2026-06-23) — **FIXED**

SketchUp Labels + 3D Text placement/leader alignment root cause and verification.

| File | Role |
|------|------|
| `QA-2026-06-23_text-leader-alignment-rootcause.md` | What was wrong (leader vector vs rotation; double 3D anchor shift) |
| `QA-2026-06-23_text-leader-alignment-fix.md` | What changed, how to verify, test commands |

**Headline:** SketchUp v3.7.58 — horizontal labels use zero leader vector; rotated labels route to mesh text; 3D Text shares single left/baseline anchor with Labels. FreeCAD/LibreCAD text paths unchanged; Blender gained headless import-report robustness during validation.

---

## Round 3 — Full-repo scan (2026-06-23) — **CLOSED**

**Status:** All questions **RESOLVED** (Q1–Q5). **GO** to push — see `QA-2026-06-23_round3-resolution.md`.

| File | Role |
|------|------|
| `QA-2026-06-23_round3-reviewer-A-errors.md` | Errors/bugs (or evidence of none) |
| `QA-2026-06-23_round3-reviewer-B-improvements.md` | Improvement opportunities, Round-2 deferred items |
| `QA-2026-06-23_round3-reviewer-C-cross-repo.md` | pdfcadcore sync, parity, CI across repos |
| `QA-2026-06-23_round3-reviewer-D-app-website.md` | Steel Logic app + BlueCollar website |
| `QA-2026-06-23_round3-synthesis.md` | Consolidated findings, disagreements, commit plan |
| `QA-2026-06-23_round3-resolution.md` | **Final agreement** — all disagreements closed, GO to push |
| `QA-2026-06-23_round3-awaiting-feedback.md` | Feedback phase (**CLOSED**) |
| `QA-2026-06-23_round3-user-rulings.md` | User rulings log (Q1–Q5) |

**Round-3 headline:** Automated tests and pdfcadcore sync green; Q1–Q5 ruled via Round 2 defaults; QA mirrors committed to all six repos.

---

## Mirror note

Desktop folder (`PDFTest Files\Q&A`) is the **anonymous reviewer drop zone**. In-repo copies live under `_LLM_CONTROL_PACK/QA/`.

---

*Index maintained for anonymous Q&A workflow.*
