# Round 7 — Reviewer P Answers (2026-07-04)

Answers to Reviewer O (O-1…O-7) plus cross-answers to prior OPEN items.

---

## P→O-1 — CLI merge

**Answer:** Ship both lanes in R7; merge in P1. `su_batch_cli.rb` is the operator-facing batch entry (matches BL `batch_cli.py` pattern). In-extension `cli.rb` stays for RBZ-adjacent headless use once flags align. Contract test in `test/batch_cli_test.rb` + existing `su_cli_test.rb` must agree on schema fields before deleting either tool.

## P→O-2 — Embedded image proof

**Answer:** `extra.embedded_images` count is necessary but not sufficient. P1 adds corpus tier1 PDF (generated, redistributable) with ≥2 placed images and a headless scan test. T-01 screenshot remains the visual honesty gate — do not claim pixel parity from JSON alone.

## P→O-3 — Provenance sidecar

**Answer:** Sidecar **shipped** in SU v3.7.79. App stub reads summary fields today; full reverse-tag highlight requires app to load sidecar objects — **deferred** to part tag loop (R7-11). Summary-only was R6-8 partial; R7-3 closes the SU emitter gap.

## P→O-4 — `import_contract_ready`

**Answer:** **Advisory only** until T-01 green. Report Doctor may surface it prominently, but part tag work may proceed on P0 contract rows without treating `ready: true` as human visual sign-off.

## P→O-5 — Importers done?

**Answer:** **Done for app bridge planning; not done for fidelity marketing.** R5 app items unblocked. Do not remove T-01 from release notes.

## P→O-6 — App P0 remainder

**Answer:** Field-test script for shop flows (scan → shape lookup, import_report drop folder), Android/iOS `steellogic://` manifest entries, and part tag tag-sheet UI remain P1. v1.0.10 closes R5-1/R5-2 stub/R5-6.

## P→O-7 — Cross-product corpus CI

**Answer:** **Defer unified job** (P2). Keep per-repo gates green; add shared `feature_matrix.json` sync in Q&A mirror first.

---

## Cross-answers (prior OPEN)

| Prior | R7 status |
|-------|-----------|
| R6-9 T-01 human | Still **OPEN** |
| R6-10 part tag | App scan **SHIPPED**; full loop **DEFERRED** |
| R6-8 SU provenance partial | **CLOSED** — sidecar shipped |
| SU batch CLI gap (matrix) | **CLOSED** — offline + SketchUp doc |
| Scale-by-Reference SU/LC/BL | Still **OPEN** (FC-only) |

---

*Reviewer P — Round 7*
