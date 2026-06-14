# SU Strategy Roadmap — Corpus Placement CI

**Status:** Phase 1 complete (2026-06-14)

## Phase 1 — Headless CI (current)

- [x] Multi-root corpus scan (`corpus_paths.rb`)
- [x] Parser + text extraction metrics per PDF
- [x] Headless `GeometryBuilder` label placement simulation
- [x] Baseline JSON regression (`test/fixtures/corpus_baselines/`)
- [x] `tools/generate_corpus_baselines.rb --update`
- [x] GitHub workflow `corpus-placement`
- [ ] Self-hosted runner with `BCS_CORPUS_ROOT` for full GitHub gate

## Phase 2 — Visual acceptance (planned)

- SketchUp GUI import on Tier-1 subset (1017, Alvord, Welding chart, etc.)
- Screenshot diff or manual sign-off checklist wired to release prep

## Generalization principles (Q&A alignment)

Per corpus-access Q&A (contribution-04):

- Corpus paths resolve via `BCS_CORPUS_ROOT`, not Desktop-only absolutes
- Tier-1 subset can gate PRs; full corpus runs nightly/pre-release
- SU mirrors shared QA report schema fields where applicable
- 1017 is one baseline file among many — no 1017-only CI logic

See `test/CORPUS_CI.md` for run/update instructions.
