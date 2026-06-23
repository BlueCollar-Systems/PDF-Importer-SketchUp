# Corpus stress opt-out inventory

Round-2 action #6: document PDFs excluded from CI timing via `CORPUS_STRESS_OPTOUT`.

## Mechanism

`test/support/corpus_harness.rb` reads:

```powershell
$env:CORPUS_STRESS_OPTOUT = 'heavy-shop.pdf|another.pdf'
```

Pipe-separated **basenames only** (not full paths). Matching PDFs return `TIMEOUT` immediately with message `Stress PDF opt-out (manual QA only; exceeds CI budget)`.

## Current inventory (default checkout)

| Basename | Reason | Added |
|----------|--------|-------|
| *(none)* | Default empty — no opt-outs unless CI sets the env var | — |

Update this table when adding entries. **Require a PR note** explaining why the PDF exceeds CI budget and what manual QA covers.

## Soft cap

Harness warns once when the list exceeds **5** basenames (`CORPUS_STRESS_OPTOUT_CAP` overrides). Prefer manual Tier-1 QA over growing the opt-out list.

## Related

- `test/CORPUS_CI.md` — full corpus gate
- `test/corpus_strict_timing_test.rb` — strict timing on named PDF (`CORPUS_STRICT_TIMING=1`)
