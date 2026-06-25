# QA-2026-06-24 — Ruby 2.2 compatibility gate

**Verdict:** GO — hotfix shipped + CI gate active  
**Date:** 2026-06-25  
**Release:** PDF Vector Importer **v3.7.68** current public release (fix introduced in v3.7.66)  
**Customer:** Joe Campbell — extension blocked on SketchUp 2017 until fixed RBZ

## Incident

| Item | Detail |
|------|--------|
| Reporter | Joe Campbell (field) |
| Host | SketchUp **2017** (Ruby **2.2**) |
| Symptom | Extension fails to load — Ruby syntax error at parse time |
| Impact | **P0** — customer cannot use importer at all |

## Root cause

`import_health.rb` used an endless range literal (`text[-69..]`) in `short_path`.
Endless ranges require Ruby 2.6+; SketchUp 2017 ships Ruby 2.2, so the loader
fails before the extension registers.

Secondary risk: `qa_report.rb` used `.positive?` (Ruby 2.3+) — runtime failure
when scale/QA summary paths execute.

## Fix (introduced in v3.7.66; current release v3.7.68)

| File | Change |
|------|--------|
| `import_health.rb` | `text[-69..]` → `text[-69, 69]` (two-arg `String#[]`) |
| `qa_report.rb` | `.positive?` → `> 0` comparisons (Ruby 2.2 safe) |
| `metadata.rb` / loader | Version **3.7.68** current release |

Commit: `c9b4578` — `fix(sketchup): Ruby 2.2 endless range in import_health v3.7.66`

## Prevention (shipped same release train)

| Artifact | Purpose |
|----------|---------|
| `tools/ruby22_syntax_check.rb` | Standalone forbidden-syntax scanner |
| `test/ruby22_compat_test.rb` | CI unit gate — scans `extracted/sketchup_ext/` + `test/` |
| `test/import_health_test.rb` | Unit tests for `short_path` without SketchUp |
| `.github/workflows/su-pdfimporter-ci.yml` | Runs compat gate on Ruby 2.2 Docker + 2.7/3.0/3.2 |
| `test/CORPUS_CI.md` | Documents gate commands |

Forbidden patterns: `&.`, `.positive?`/`.negative?`/`.match?`/`.dig`/`.sum`,
`.then`, `.yield_self`, `.filter_map`, beginless/endless ranges (`[..`, `..]`).

## Customer impact

- **v3.7.65 and earlier:** extension may fail to load on SketchUp 2017.
- **v3.7.66+:** load-safe on Ruby 2.2 baseline.

**Customer message:** Install **v3.7.68** from Releases — the extension will not
load on **v3.7.65** for SketchUp 2017 users.

## Verification

```powershell
cd C:\1PDF-Importer-SketchUp
ruby tools/ruby22_syntax_check.rb --include-tests
ruby test/ruby22_compat_test.rb
ruby test/import_health_test.rb
ruby test/smoke_test.rb
python build_release.py
```

| Gate | Result |
|------|--------|
| `ruby22_compat_test.rb` | 0 failures |
| `import_health_test.rb` | 0 failures |
| `build_release.py` | `SketchUp-PDF-Importer_v3.7.68.rbz` |

## Manual retest (Joe / field)

1. Install RBZ **v3.7.68** on SketchUp 2017.
2. Extensions → enable PDF Vector Importer — no Ruby Console syntax error.
3. Import a PDF with a long path; open Import Health — truncated paths show `...` prefix.

## Commit (prevention slice)

`fix(ci): Ruby 2.2 compatibility gate — prevent SketchUp 2017 load failures`
