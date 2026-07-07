# Private Validation CI (SketchUp)

Phase 1 headless gate: parse private validation PDFs, extract text when a
local extractor is available, simulate `GeometryBuilder` label placement, and
compare against committed non-sensitive baselines.

## Validation Asset Paths

Private validation assets are never committed to this repository. Local and CI
runs resolve them with `BCS_PRIVATE_VALIDATION_ROOT`.

The root is expected to contain a private manifest with opaque fixture IDs and
relative paths. Do not document client filenames, local mirror paths, or PDF
basenames in this repository.

## Local Run

```powershell
$env:BCS_PRIVATE_VALIDATION_ROOT = '<private-validation-root>'
ruby test/corpus_placement_test.rb
```

`pdftotext` must be available on `PATH` when bbox-backed text validation is
needed.

## Baseline Updates

After reviewing placement or text-hash drift:

```powershell
ruby tools/generate_corpus_baselines.rb --update
# or
$env:CORPUS_UPDATE_BASELINES = '1'
ruby test/corpus_placement_test.rb
```

Only commit sanitized JSON under `test/fixtures/corpus_baselines/`; do not
commit private PDFs, client names, local paths, screenshots, or source URLs.

Baseline fields per PDF:

| Field | Meaning |
|-------|---------|
| `pdf_name` | Opaque fixture ID or redacted basename |
| `corpus_key` | Stable private validation key |
| `pages` | Page count |
| `paths` | Vector path count |
| `text_items` | Extracted text item count |
| `bbox_pct` | Percent of text items with bbox metadata |
| `placement_ok` / `placement_total` | Simulated label placements |
| `text_hash` | SHA256 of sorted placed label strings |

## Thresholds

- Parser failure or timeout fails the private validation gate.
- Placement rate below 95% fails when text exists.
- Vector sheets with strong bbox coverage require 100% simulated placement.
- Baseline field mismatches fail unless baseline update mode is explicit.
- Expected bad-PDF refusals pass only when the importer reports the matching
  refusal reason.

## CI Workflow

Workflow: **corpus-placement** (`.github/workflows/corpus-placement.yml`)

- Runs on push/PR to `main` / `master`.
- Installs Ruby and `pdftotext`.
- Always validates committed sanitized baseline JSON structure.
- Runs the full private validation gate only when
  `BCS_PRIVATE_VALIDATION_ROOT` points at mounted private assets.
- GitHub-hosted runners without private assets still pass structure checks and
  emit a warning.

## Ruby 2.2 Compatibility Gate (SketchUp 2017)

Extension code under `extracted/sketchup_ext/` must parse and run on **Ruby 2.2**
(SketchUp Make 2017). Modern `ruby -c` alone does not catch endless ranges or
Ruby 2.3+ APIs such as `&.`, `.positive?`, or `.sum`.

| Gate | Command |
|------|---------|
| Standalone scanner | `ruby tools/ruby22_syntax_check.rb` |
| Include `test/` tree | `ruby tools/ruby22_syntax_check.rb --include-tests` |
| CI unit gate | `ruby test/ruby22_compat_test.rb` |
| Import Health slice | `ruby test/import_health_test.rb` |

Workflow: **su-pdfimporter-ci** runs the compat gate on Ruby 2.2 (Docker) and
on Ruby 2.7 / 3.0 / 3.2. Failures block merge.

## Related Tests

- `test/text_label_placement_test.rb` - private coordinate assertions when
  validation assets are mounted
- `test/corpus_strict_timing_test.rb` - opt-in strict timing on a private
  fixture ID (`CORPUS_STRICT_TIMING=1`)
- `test/PRIVATE_VALIDATION_STRESS_OPTOUT.md` - stress PDF opt-out inventory
- `test_all_pdfs.rb` - legacy parser-only sweep

## Status

Phase 1 is complete: headless private validation placement CI with sanitized
baseline regression. Heavy PDFs are warn-only on timeout unless strict timing
is enabled.

Heavy-lane knobs:

- `CORPUS_HEAVY_PDF_MB`
- `CORPUS_HEAVY_PAGE_COUNT`
- `CORPUS_HEAVY_PDF_TIMEOUT`

Future visual acceptance should use private fixture IDs only.
