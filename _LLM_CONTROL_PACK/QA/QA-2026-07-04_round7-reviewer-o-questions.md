# Round 7 — Reviewer O Questions (2026-07-04)

**Focus:** SU CLI merge, embedded images, importer closure honesty, app bridge

---

## O-1 — SU CLI: one contract or two?

We now have `tools/su_batch_cli.rb`, `tools/su_pdf_cli.rb`, and in-extension `cli.rb`. Should Round 7 merge to **one flag surface** (`--preflight`, `--report-dir`, `--geometry-sidecar`, `--json`) with a single contract test, or keep dev vs RBZ-shippable split?

## O-2 — Embedded images: proof bar

`ImageExtractor` + `EmbeddedImageExtractor` landed in SU v3.7.79. What is the minimum acceptance proof before we claim parity with FC/BL — corpus PDF with ≥2 images, T-01 screenshot, or `extra.embedded_images` count only?

## O-3 — `source_provenance` sidecar

SU now writes `*_source_provenance.json` when provenance objects exist. Is summary-only still acceptable for part tag reverse-tag, or must app ingest sidecar before R5-1 is "done"?

## O-4 — `import_contract_ready` stub

All hosts now emit a diagnostics stub in `extra.import_contract_ready`. Should Report Doctor treat `ready: true` as a hard gate for part tag work, or advisory only until T-01 visual sign-off?

## O-5 — Are importers "done"?

Given T-01 OPEN (FC-2 fill, BL-1 lineweight), SU batch CLI (offline only for geometry), and deferred `parts_bootstrap` — can we honestly mark importer phase complete for app planning?

## O-6 — App Round 7 scope

Steel Logic v1.0.10 adds barcode scan on Omni-Box (mobile), `import_report` ingestion stub, and `steellogic://` deep links. What P0 remains before shop-floor field test?

## O-7 — Outside the box

Should the corpus repo host **cross-product** golden vectors (importer `import_report` + app omni phrase → shape lookup) in one CI job, or keep repos gated separately?

---

*Reviewer O — Round 7 importer + app kickoff*
