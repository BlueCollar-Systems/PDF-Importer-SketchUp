# QA-2026-06-24 - SketchUp Ruby 2.2 import_health hotfix

**Verdict:** GO (syntax + unit gate)  
**Date:** 2026-06-24  
**Release:** PDF Vector Importer **v3.7.68** current public release (fix introduced in v3.7.66)

## Summary

SketchUp **2017** ships **Ruby 2.2**, which does not support endless range literals (`start..`). A debug/truncation helper in `import_health.rb` used `text[-69..]`, causing a **syntax error at load time** and preventing the extension from registering.

## Root cause

| Item | Detail |
|------|--------|
| File | `extracted/sketchup_ext/bc_pdf_vector_importer/import_health.rb` |
| Line | 95 (`truncate_path` tail ellipsis) |
| Bad syntax | `"...#{text[-69..]}"` |
| Ruby 2.2 | Endless ranges (`..` without end) added in Ruby 2.6+ |
| Symptom | Extension fails to parse/load on SU 2017; import health UI never available |

## Fix

| Item | Detail |
|------|--------|
| Change | `text[-69..]` → `text[-69, 69]` (two-arg `String#[]`, Ruby 2.2-safe) |
| Version | `3.7.68` in `metadata.rb` and `bc_pdf_vector_importer.rb` (`PLUGIN_VERSION`) |
| README | Version badge updated to 3.7.68 |

## Verification

| Gate | Command | Result |
|------|---------|--------|
| Syntax | `ruby -c extracted/sketchup_ext/bc_pdf_vector_importer/import_health.rb` | Syntax OK |
| QA report | `ruby test/qa_report_test.rb` | 6 runs, 41 assertions, 0 failures |

## Retest steps (manual)

1. Build or install RBZ **v3.7.68** (local `build_release.py` or GitHub release asset).
2. SketchUp **2017** (Ruby 2.2): Extensions → enable **PDF Vector Importer** — confirm no Ruby syntax error in Ruby Console on load.
3. Run a PDF import that triggers import health / path truncation (long file path) and confirm truncated paths display with leading `...` without error.
4. Smoke on a newer SketchUp (Ruby 2.7+) optional — same behavior expected.

## Commit

`fix(sketchup): Ruby 2.2 endless range in import_health v3.7.66`
