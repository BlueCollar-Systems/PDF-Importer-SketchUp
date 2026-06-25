# Corpus Placement CI (SketchUp)

Phase 1 headless gate: parse corpus PDFs, extract text (pdftotext when
available), simulate `GeometryBuilder` label placement, and compare against
committed baselines.

## Corpus scan paths

Resolved via `corpus_paths.rb` / `BCS_CORPUS_ROOT` (fallback `PDF_TEST_CORPUS`):

1. `C:\1pdf-test-corpus\PDFTest Files\` — non-recursive
2. `C:\1pdf-test-corpus\New folder (2)\` — recursive
3. `%USERPROFILE%\Desktop\PDFTest Files\` — non-recursive (legacy mirror)
4. `%USERPROFILE%\Desktop\New folder (2)\` — recursive (legacy mirror)

Duplicate `corpus_key` collisions keep the first match.

## Local run

```powershell
# Optional: point at canonical corpus
$env:BCS_CORPUS_ROOT = 'C:\1pdf-test-corpus'

# Requires pdftotext on PATH (Poppler / MiKTeX / FreeCAD bundle)
ruby test/corpus_placement_test.rb
```

## Public web-acquired corpus

The repo includes a local-only manifest for public stress PDFs:

- `tools/public_pdf_corpus_manifest.json` — source URLs, feature tags,
  license notes, and local target paths.
- `tools/download_public_pdf_corpus.py` — dependency-free downloader that writes
  PDFs under `C:\1pdf-test-corpus\web-acquired\` by default.
- `C:\1pdf-test-corpus\web-acquired\PUBLIC_PDF_CORPUS.lock.json` — local hash
  and size inventory written after acquisition; intentionally not committed.

Acquire the enabled public set:

```powershell
python tools/download_public_pdf_corpus.py --root C:\1pdf-test-corpus
```

These PDFs are not redistributed from this repository. The manifest records the
upstream source and whether a file should remain local-only or manually
acquired because of license or download restrictions.

## Update baselines (intentional changes)

After reviewing placement or text-hash drift:

```powershell
ruby tools/generate_corpus_baselines.rb --update
# or
$env:CORPUS_UPDATE_BASELINES = '1'
ruby test/corpus_placement_test.rb
```

Commit updated JSON under `test/fixtures/corpus_baselines/`.

Baseline fields per PDF:

| Field | Meaning |
|-------|---------|
| `pdf_name` | File basename |
| `corpus_key` | Stable scan key (`tag/relative/path.pdf`) |
| `pages` | Page count |
| `paths` | Vector path count |
| `text_items` | Extracted text item count |
| `bbox_pct` | Percent of text items with bbox metadata |
| `placement_ok` / `placement_total` | Simulated label placements |
| `text_hash` | SHA256 of sorted placed label strings |

## Thresholds

- Parser failure or timeout → fail
- Placement rate &lt; 95% when text exists (general sheets)
- Placement rate &lt; 100% for vector sheets (`bbox_pct` ≥ 50 and `text_items` ≥ 10)
- Any baseline field mismatch → fail (unless updating baselines)
- Expected bad-PDF refusals (currently encrypted open-password samples) → pass
  only when the importer reports the matching refusal reason.

## CI workflow

Workflow: **corpus-placement** (`.github/workflows/corpus-placement.yml`)

- Runs on push/PR to `main` / `master`
- Installs Ruby 3.2 and `poppler-utils` (`pdftotext` on PATH)
- Always validates committed baseline JSON structure
- Full corpus gate runs when `BCS_CORPUS_ROOT` points at a mounted corpus
  (self-hosted runner or repository variable). GitHub-hosted runners without
  the corpus still pass baseline structure checks and emit a warning.

## Related tests

- `test/text_label_placement_test.rb` — golden 1017 coordinate assertions (not corpus-wide)
- `test/corpus_strict_timing_test.rb` — opt-in strict timing on named PDF (`CORPUS_STRICT_TIMING=1`)
- `test/CORPUS_STRESS_OPTOUT.md` — stress PDF opt-out inventory
- `test_all_pdfs.rb` — legacy parser-only sweep (paths only)

## Status

**Phase 1 complete** — headless corpus placement CI with baseline regression (36 PDFs locally; heavy PDFs warn-only on timeout).

Heavy-lane knobs (defaults: 8 MB, 30+ pages, 300 s timeout):

- `CORPUS_HEAVY_PDF_MB`
- `CORPUS_HEAVY_PAGE_COUNT`
- `CORPUS_HEAVY_PDF_TIMEOUT`
Phase 2 (future): SketchUp GUI visual acceptance on Tier-1 subset.
