# Task 2 Report: Fail-Closed SketchUp Real-Host Runner

## Status

Complete on `codex/sketchup-week-defect-sweep-2`.

- Commit: `05acc9e` — `feat(su): add fail-closed host acceptance runner [skip release]`
- Authorized committed files: four Task 2 files only.
- SketchUp was not launched; the real-host matrix remains Task 3.
- The externally managed worktree and branch were preserved. Nothing was
  merged, pushed, installed, or copied into the canonical checkout.

## Boundary Check

Before editing:

```text
git rev-parse --show-toplevel
C:/TMP/sketchup-week-defect-sweep-2

git branch --show-current
codex/sketchup-week-defect-sweep-2

git status --short --untracked-files=all
(no entries)

git status --short --ignored --untracked-files=all
!! .superpowers/sdd/.gitignore
!! .superpowers/sdd/progress.md
!! .superpowers/sdd/review-b0d7e2b..382b76d.diff
!! .superpowers/sdd/task-1-brief.md
!! .superpowers/sdd/task-1-report.md
```

The only pre-existing entries were ignored `.superpowers/sdd` records.

## RED Evidence

### Initial helper RED

Command:

```text
ruby test/sketchup_host_evidence_test.rb
```

Output:

```text
Run options: --seed 1031

# Running:

FFFFFFFF

Finished in 0.003263s, 2452.0321 runs/s, 2452.0321 assertions/s.

Each failure: tools/sketchup_host_evidence.rb must exist

8 runs, 8 assertions, 8 failures, 0 errors, 0 skips
```

This was the intended RED: the pure evidence helper did not exist.

### Initial runner-contract RED

Command:

```text
ruby test/sketchup_batch_host_contract_test.rb
```

Output summary:

```text
Run options: --seed 45356

# Running:

FFF

Failures included:
- Expected source to include SketchupHostJob.load(ARGV[0])
- Expected source to include SketchupHostEvidence.verify_delivery_evidence!
- Expected source to include opts[:text_mode] = job[:text_mode]

3 runs, 6 assertions, 3 failures, 0 errors, 0 skips
```

The legacy runner still read `ARGV[1]`, hard-coded Labels, displayed message
boxes, did not save a model, and did not emit fail-closed host evidence.

### Production entity-ID format regression RED

Source review found that production renderers can encode an `entityID` claim
as `entity_id:13`. A focused test was added before changing the helper.

Command:

```text
ruby test/sketchup_host_evidence_test.rb
```

Output:

```text
Run options: --seed 48566

# Running:

..E.......

1) Error:
SketchupHostEvidenceTest#test_tagged_entity_id_delivery_is_cross_checked_against_manifest:
SketchupHostEvidence::EvidenceError: terminal_text_delivery_records[0] has missing or invalid entity IDs

10 runs, 77 assertions, 0 failures, 1 errors, 0 skips
```

The minimal fix accepts raw positive integers and exact `entity_id:<positive>`
claims, normalizing both to the manifest's raw `entityID`. It deliberately
rejects `persistent_id:` claims because the Task 2 contract requires direct
SketchUp 2017 `entityID` cross-checking.

### Missing delivery collections and renderer provenance RED

Review found that Glyphs/Geometry use `page_text_delivery_records`, raster has
its own duplicate delivery array, and SVG source/item-raster paths needed
source-location evidence.

Commands and output:

```text
ruby test/sketchup_host_evidence_test.rb
Run options: --seed 48730
F.........
StandardError expected but nothing was raised.
10 runs, 77 assertions, 1 failures, 0 errors, 0 skips

ruby test/sketchup_batch_host_contract_test.rb
Run options: --seed 233
..F
Expected source to include "'text_renderers' => Array(stats[:text_renderers])".
3 runs, 42 assertions, 1 failures, 0 errors, 0 skips
```

The helper was extended to cross-check page/raster deliveries. The runner now
records `CairoGlyphSource.render_page_svg`, the item-raster renderer, and the
complete `text_renderers` array.

### Native text-attempt cross-check RED

Review found that native Labels/3D Text delivery IDs live in `text_attempts`.

```text
ruby test/sketchup_host_evidence_test.rb
Run options: --seed 61218
..F.......
StandardError expected but nothing was raised.
10 runs, 77 assertions, 1 failures, 0 errors, 0 skips
```

`text_attempts` was added to the same manifest cross-check after this RED.

## Final GREEN Evidence

Focused tests, run fresh after the last implementation edit:

```text
ruby test/sketchup_host_job_test.rb
Run options: --seed 1296
..........
10 runs, 41 assertions, 0 failures, 0 errors, 0 skips

ruby test/sketchup_host_evidence_test.rb
Run options: --seed 37560
..........
10 runs, 99 assertions, 0 failures, 0 errors, 0 skips

ruby test/sketchup_batch_host_contract_test.rb
Run options: --seed 18697
...
3 runs, 52 assertions, 0 failures, 0 errors, 0 skips
```

Syntax checks:

```text
ruby -c tools/sketchup_host_evidence.rb
Syntax OK
ruby -c tools/sketchup_batch_import.rb
Syntax OK
ruby -c test/sketchup_host_evidence_test.rb
Syntax OK
ruby -c test/sketchup_batch_host_contract_test.rb
Syntax OK
```

Ruby 2.2 compatibility gate:

```text
ruby test/ruby22_compat_test.rb
Run options: --seed 39203
...
3 runs, 5 assertions, 0 failures, 0 errors, 0 skips
```

Diff checks:

```text
git diff --check
(no output; exit 0)

git diff --cached --check
(no findings; exit 0)
```

## Changed Files

- `tools/sketchup_batch_import.rb`
  - Consumes exactly `SketchupHostJob.load(ARGV[0])`.
  - Writes `STARTED`, then a truthful `OK` or `ERROR` result.
  - Loads the worktree source, validates the pipeline, fidelity controller,
    normalizer, metadata writer, and all potential renderer source locations.
  - Records and compares worktree/loaded metadata versions.
  - Preserves requested representation options without substitution.
  - Saves and confirms the `.skp`, copies and confirms `import_report.json`,
    writes and confirms `entity_manifest.json`, and verifies delivery evidence.
  - Contains no `UI.messagebox` and schedules `Sketchup.quit` in `ensure`.
- `tools/sketchup_host_evidence.rb`
  - Performs case-insensitive, separator-aware source-root validation.
  - Recursively snapshots Group and Component-like entity trees with
    `entityID`, typename, valid/deleted state, bounds, transform, and children.
  - Collects nested manifest IDs and cross-checks every claimed delivery ID in
    text attempts, page/terminal/raster deliveries, page fallbacks, and
    physical source-glyph deliveries.
  - Requires both `representation_fidelity.ready` and
    `import_contract_ready.ready` to be exactly true.
- `test/sketchup_batch_host_contract_test.rb`
  - Locks the one-argument, non-modal, source-provenance, save/result, and
    requested-mode contracts.
- `test/sketchup_host_evidence_test.rb`
  - Covers source-root boundaries, recursive fakes, nested manifest IDs,
    raw/tagged `entityID` claims, all delivery collections, and readiness gates.

Staged/committed scope was exactly:

```text
A  test/sketchup_batch_host_contract_test.rb
A  test/sketchup_host_evidence_test.rb
M  tools/sketchup_batch_import.rb
A  tools/sketchup_host_evidence.rb
```

## Concerns / Task 3 Watch Items

- No SketchUp process was launched, as required. Model save/reopen behavior,
  timer-driven shutdown, and the five-mode real-host matrix remain unproven
  until Task 3.
- The Task 2 startup script itself has no message box. The existing production
  `run_pipeline` still contains modal branches for an unavailable SVG renderer,
  PDFs over 100 MB, and salvage errors. The planned owner fixtures may not hit
  them, but Task 3 should treat any modal host branch as a failure rather than
  dismissing it.
- Production `RepresentationFidelity.stable_entity_id` prefers
  `persistent_id` when the host exposes it, while this plan explicitly requires
  `entityID` manifest cross-checks. The helper therefore rejects
  `persistent_id:` claims. If SketchUp Make 2017 emits those claims, Task 3 will
  correctly produce ERROR and expose a production-contract defect for Task 4.
- Only Ruby 3.4.4 is installed locally. The repository's Ruby 2.2 compatibility
  scan and all syntax checks passed; the exact Ruby 2.2.4-p230 parser/build gate
  remains part of the plan's Task 4 full verification.
- Git printed a permission warning for the user's global ignore file during
  status/staging checks. Repository status and staged scope remained readable
  and clean.

## Independent Review Correction (2026-07-17)

The first Task 2 implementation was rejected after independent review. This
correction closes every finding before any real SketchUp launch.

### Corrected contracts

- `tools/sketchup_host_launcher.rb` now owns a disposable APPDATA,
  LOCALAPPDATA, and PROGRAMDATA profile whose SketchUp 2017 user plugin root is
  empty. It never reads, launches, modifies, activates, or purchases the
  installed Prognosoft PDFImport plugin. It passes exactly one
  `-RubyStartupArg`, binds STARTED/OK/ERROR to a random job ID plus the immutable
  job SHA-256, waits for the exact child PID, and kills only that PID on timeout
  or launcher failure.
- The production missing-renderer, first-run notice, >100 MB confirmation, and
  salvage-error paths now honor one explicit noninteractive policy. Batch runs
  fail closed rather than showing a prompt. The in-host session also installs a
  last-resort modal guard before loading `main.rb`.
- `SketchupBatchImport.run_argv!` is callable with behavioral session fakes.
  Tests observe bound STARTED before work, bound OK, bound ERROR, discard, quit,
  and exact-one-argument rejection. Error cleanup aborts any open operation,
  closes the batch model while ignoring changes, writes ERROR atomically, and
  schedules quit; the external watchdog remains authoritative if quit stalls.
- Ownership is a recursive before/after difference. Every manifest row carries
  both `entityID` and `persistent_id`; delivery claims are checked against their
  declared namespace in the live session. Save/reopen continuity uses
  `persistent_id`, tolerates changed `entityID`, and rejects changed typename,
  transform, bounds, or persistent-ID sets.
- Missing ledgers no longer become empty through `Array(nil)`. Text requests
  require exact source/attempt/delivery span-set equality. A genuinely empty
  non-Raster text ledger requires explicit per-page proof that semantic
  extraction completed and decoded page/form streams contained no text
  operators. Raster requires exact selected-page raster delivery.
- The complete source-provenance object array and nonempty import session are
  copied into both report evidence and the host result. The report is parsed
  and bound to source path/SHA-256, schema, requested mode, SketchUp host,
  worktree/loaded/report version, full provenance/session, representation
  readiness, and import-contract readiness before an atomic byte-for-byte
  copy. Stale, corrupt, mismatched, or concurrently replaced reports fail.
- The implementation plan no longer mandates `entityID`-only evidence or
  postpones modal/process control to Task 3. The rejected minimal skeleton was
  removed so it cannot become a future regression instruction.

### RED evidence captured before production corrections

```text
ruby test/sketchup_host_evidence_test.rb
18 runs, 118 assertions, 4 failures, 4 errors
Missing APIs/behavior included persistent IDs, recursive ownership,
save/reopen continuity, strict missing-vs-empty ledgers, decoded-stream proof,
source-set equality, and bound report copy.

ruby test/sketchup_host_launcher_test.rb
3 runs, 0 assertions, 3 errors
tools/sketchup_host_launcher.rb did not exist.

ruby test/sketchup_batch_host_contract_test.rb
6 runs, 53 assertions, 1 failure, 2 errors
SketchupBatchImport callable orchestration did not exist.

ruby test/batch_host_nonmodal_policy_test.rb
3 runs, 0 assertions, 3 errors
batch_host_policy.rb did not exist.

ruby test/qa_report_test.rb --name /binds_requested_mode/
1 run, 1 assertion, 1 failure
requested_text_mode was absent from the production report.

ruby test/sketchup_host_evidence_test.rb --name /changed_transform/
1 run, 2 assertions, 1 failure
reopen continuity initially accepted a changed transform.
```

### Fresh GREEN evidence after final edits

```text
ruby test/sketchup_host_job_test.rb
10 runs, 41 assertions, 0 failures, 0 errors

ruby test/sketchup_host_evidence_test.rb
19 runs, 132 assertions, 0 failures, 0 errors

ruby test/sketchup_host_launcher_test.rb
3 runs, 28 assertions, 0 failures, 0 errors

ruby test/sketchup_batch_host_contract_test.rb
6 runs, 73 assertions, 0 failures, 0 errors

ruby test/batch_host_nonmodal_policy_test.rb
4 runs, 18 assertions, 0 failures, 0 errors

ruby test/qa_report_test.rb --name /binds_requested_mode/
1 run, 4 assertions, 0 failures, 0 errors

ruby test/ruby22_compat_test.rb
3 runs, 5 assertions, 0 failures, 0 errors

python tools/check_su2017_ruby_compat.py <all changed runtime Ruby files>
SketchUp 2017 Ruby compatibility: PASS

git diff --check
no findings
```

The broader production suites were also run after the production edits:

```text
ruby test/qa_report_test.rb
31 runs, 166 assertions, 0 failures, 0 errors

ruby test/representation_fidelity_contract_test.rb
55 runs, 530 assertions, 0 failures, 0 errors

ruby test/dependency_resolver_test.rb
7 runs, 21 assertions, 0 failures, 0 errors
```

No real SketchUp host or installed third-party plugin was launched during this
correction task. Real-host execution remains behind the next independent review
gate, as required.

## Second Independent Review Correction (2026-07-17)

The second review found five remaining acceptance holes. This pass corrects
them without launching SketchUp or changing any installed plugin/license file.

### Root causes and corrected contracts

- Environment-only APPDATA/PROGRAMDATA redirection was not authoritative on
  Windows because SketchUp may resolve Known Folders independently, and it hid
  the real license state. The launcher now leaves all real profile and machine
  paths intact. It captures the exact persisted SketchUp 2017
  `RubyManager_DisablePlugins` value (existence, registry type, and value),
  writes the official next-start disabled state, proves it by readback, and
  restores the exact prior state in the launcher ensure path. The in-host
  runner must independently observe `Sketchup.plugins_disabled? == true`.
  Suppression/readback/restoration failure is ERROR and prevents acceptance.
- Process completion formerly collapsed to `:exited`, so a crashing/nonzero
  child could reuse a bound OK file. `ProcessBackend` now captures exit status;
  OK requires exit code zero plus a complete, bound model/report/manifest,
  artifact hashes, source-root/version/session evidence, full ledgers,
  representation/import readiness, and save/reopen continuity. Nonzero,
  unknown exit status, minimal OK, stale binding, missing/corrupt artifacts,
  or incomplete evidence is ERROR.
- Geometry/Glyph attempt ledgers use plural `source_span_ids` while native
  paths may use singular `source_span_id`. Evidence normalization now flattens
  both shapes (and provenance `span_id`/`span_ids`) before exact source-set
  comparison. The Geometry and Glyphs regression covers both source spans.
- Reopen validation previously compared the owned subset with the whole
  reopened model, which rejected valid preexisting/template entities. The host
  now compares the complete post-import model with the complete reopened model;
  the reusable owned-subset verifier filters reopened rows by persistent ID.
- The host formerly opened the owner's mutable PDF path. Before suppression or
  spawn, the launcher now writes a unique read-only per-job copy, verifies its
  bytes/SHA-256, and creates a controlled one-argument job that names only that
  copy. The pipeline report remains bound to the immutable bytes even when
  salvage produces a normalized temporary PDF. Result and report separately
  record original, immutable, normalized, and salvage lineage. An adversarial
  test replaces the original from inside the spawn boundary and proves the host
  input/result remain bound to the earlier immutable bytes.

The implementation plan was corrected to remove the false isolated-profile
claim so a future round cannot reintroduce that license/plugin roadblock.

### RED evidence captured before implementation

```text
ruby test/sketchup_host_evidence_test.rb
21 runs, 134 assertions, 0 failures, 2 errors
- plural Geometry/Glyph attempts reported source attempt set mismatch
- owned/template reopen verifier did not exist

ruby test/sketchup_host_job_test.rb
11 runs, 42 assertions, 1 failure, 0 errors
- controlled original/immutable lineage was absent

ruby test/sketchup_host_launcher_test.rb
9 runs, 20 assertions, 7 failures, 2 errors
- no plugin state guard, no exit code, no immutable snapshot, and minimal OK
  was not rejected by a complete terminal contract

ruby test/sketchup_batch_host_contract_test.rb
6 runs, 73 assertions, 2 failures, 0 errors
- no in-host plugins-disabled proof or source lineage/full reopen contract

ruby test/qa_report_test.rb --name /preserves_immutable_normalized/
1 run, 1 assertion, 1 failure, 0 errors
- source_lineage was absent from the production report
```

### Fresh GREEN evidence after implementation

```text
ruby test/sketchup_host_job_test.rb
11 runs, 45 assertions, 0 failures, 0 errors

ruby test/sketchup_host_evidence_test.rb
21 runs, 137 assertions, 0 failures, 0 errors

ruby test/sketchup_host_launcher_test.rb
11 runs, 57 assertions, 0 failures, 0 errors

ruby test/sketchup_batch_host_contract_test.rb
7 runs, 93 assertions, 0 failures, 0 errors

ruby test/batch_host_nonmodal_policy_test.rb
4 runs, 18 assertions, 0 failures, 0 errors

ruby test/qa_report_test.rb
32 runs, 167 assertions, 0 failures, 0 errors

ruby test/representation_fidelity_contract_test.rb
55 runs, 530 assertions, 0 failures, 0 errors

ruby test/dependency_resolver_test.rb
7 runs, 21 assertions, 0 failures, 0 errors

ruby test/ruby22_compat_test.rb
3 runs, 5 assertions, 0 failures, 0 errors
```

The actual registry preference backend was exercised read-only and returned the
current absent state; only injected fake preference backends were mutated.
No real SketchUp executable or paid/installed extension was launched.

## Third Independent Review Correction (2026-07-17)

The third review rejected the remaining false-green evidence paths. This pass
binds every representation record to the job request, makes fallback proof
independently verifiable in the host runner, proves Raster is an actual host
image with bound content, and restricts all semantic span evidence to the
selected PDF pages.

### Corrected contracts

- `QAReport` now derives one authoritative requested mode from the pipeline and
  import options. Every attempt, page delivery, terminal delivery, raster
  delivery, renderer, and page fallback that declares a request must match it.
  A Labels job can no longer pass by self-declaring Geometry inside its records.
- The host evidence verifier independently replays every item fallback ladder.
  Only the next adjacent rung is legal, and every transition requires the exact
  source span/importer/page, item scope, affirmative impossibility evidence,
  attempted renderer, and complete cleanup of every created identity. The
  global transition ledger must exactly equal the per-attempt proofs.
- Requested Raster requires exactly one raster delivery for every selected
  page. Each record must request and deliver Raster, identify one live manifest
  entity, and cross-link to the terminal ledger. The entity typename must be an
  Image/Image-like host type, never Group, and its importer attributes must
  match the verified PNG page, dimensions, SHA-256, and byte count.
- Raster fallbacks use the same image/content verification and must also have
  exact terminal/raster-ledger identity cross-links. Temporary PNG content is
  hashed before placement and the binding is persisted on the Image entity.
- Normalized selected pages are recorded in pipeline stats. Every non-Raster
  source span, attempt, provenance delivery, page delivery, terminal delivery,
  and fallback proof is checked against that exact page set and against the
  page embedded in `text_span:<page>:<index>`.

### Adversarial RED evidence before correction

```text
ruby test/qa_report_test.rb --name
  /requested_mode_spoof|outside_selected_pages|requested_raster_rejects/
3 runs, 3 assertions, 3 failures, 0 errors
- self-declared Geometry passed a Labels request
- page-2-only span evidence passed a page-1 request
- a non-raster Raster record passed

ruby test/sketchup_host_evidence_test.rb --name
  /self_declared_geometry|outside_selected_pages|real_image_manifest/
3 runs, 6 assertions, 3 failures, 0 errors
- host evidence trusted ready flags and entity IDs without semantic binding

The adjacent/item/cleanup regression was also executed against cf5f20d:
1 run, 2 assertions, 1 failure, 0 errors
- non-adjacent, wrong-item, and incomplete-cleanup proofs were accepted
```

### Fresh GREEN evidence after correction

```text
ruby test/qa_report_test.rb
35 runs, 174 assertions, 0 failures, 0 errors

ruby test/sketchup_host_evidence_test.rb
25 runs, 160 assertions, 0 failures, 0 errors

ruby test/representation_fidelity_contract_test.rb
55 runs, 530 assertions, 0 failures, 0 errors

ruby test/sketchup_host_launcher_test.rb
11 runs, 57 assertions, 0 failures, 0 errors

ruby test/sketchup_batch_host_contract_test.rb
7 runs, 93 assertions, 0 failures, 0 errors

ruby test/sketchup_host_job_test.rb
11 runs, 45 assertions, 0 failures, 0 errors

ruby test/batch_host_nonmodal_policy_test.rb
4 runs, 18 assertions, 0 failures, 0 errors

ruby test/dependency_resolver_test.rb
7 runs, 21 assertions, 0 failures, 0 errors

ruby test/ruby22_compat_test.rb
3 runs, 5 assertions, 0 failures, 0 errors

Seven changed Ruby files: Syntax OK
SketchUp 2017 Ruby compatibility: PASS
git diff --check: clean
```

No real SketchUp host, installed plugin, paid extension, license file, or real
registry preference was launched or modified during this correction.
