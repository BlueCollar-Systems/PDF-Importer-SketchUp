# SketchUp Resilient Import, Release Completion, and Host Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add honest old-hardware progress/cancel/page resume, convergent existing-tag release completion, and strict exact-package host acceptance without changing six-mode fidelity.

**Architecture:** A small Ruby `ImportRunControl` owns deterministic complexity/progress/cancel state and model-backed page journals, while the existing single-page `run_pipeline` remains the rendering authority. A resumable wrapper invokes that pipeline once per page so the existing SketchUp transaction is the page rollback boundary. Separate Python release-control and Ruby host-identity components fail closed around GitHub and real-host evidence.

**Tech Stack:** Ruby 2.2.4, SketchUp Make 2017 Ruby API, Minitest, Python 3.12/unittest, GitHub CLI/API, PowerShell host automation.

## Global Constraints

- Preserve Text / Labels / 3D Text / Glyphs / Geometry / Raster and the exact adjacent ladders in `AGENTS.md`.
- Never relabel, skip, weaken, or convert a representation to improve speed.
- A partial item or page is never certified or retained.
- Resume requires exact PDF, options, importer/package/source-tree, and retained-group identity.
- Ruby `2.2.4-p230` and SketchUp Make 2017 remain blocking gates.
- Release assets are immutable: never overwrite, delete, or rewrite an existing tag/asset.
- No private PDF, generated customer model, or private host report enters git or an RBZ.

---

### Task 1: Deterministic Complexity, Progress, and Cancel Controller

**Files:**
- Create: `extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb`
- Test: `test/import_run_control_test.rb`

**Interfaces:**
- Produces: `ImportRunControl::Controller`, `ImportRunControl::ImportCancelled`, `Controller#assess`, `Controller#progress`, `Controller#checkpoint!`, and `Controller#cancelled_result`.
- Consumes: exact page/span/path/glyph counts and an injectable `cancel_probe`.

- [ ] **Step 1: Write failing unit tests**

Add tests that assert exact threshold behavior, progress snapshots, measured ETA only after completed work, and `ImportCancelled` propagation:

```ruby
controller = ImportRunControl::Controller.new(
  :pages => [1, 2], :requested_mode => :text3d,
  :cancel_probe => lambda { true }, :clock => fake_clock
)
assessment = controller.assess(:text_items => 1200, :glyph_placements => 5000)
assert_equal :very_large, assessment[:class]
error = assert_raises(ImportRunControl::ImportCancelled) do
  controller.checkpoint!(:text_item, :completed => 1, :total => 1200)
end
assert_equal [], error.retained_pages
```

- [ ] **Step 2: Verify RED**

Run `ruby test\import_run_control_test.rb`.

Expected: load failure because `import_run_control.rb` does not exist.

- [ ] **Step 3: Implement the minimum Ruby-2.2-safe controller**

Use positional/Hash arguments only, `Time.now` injection, finite integer counts,
monotonic nondecreasing percentage, and a dedicated exception. Do not rescue
`ImportCancelled` in progress publishing.

- [ ] **Step 4: Verify GREEN and compatibility**

Run:

```powershell
ruby test\import_run_control_test.rb
ruby test\ruby22_compat_test.rb
```

Expected: all tests pass and compatibility gate exits zero.

### Task 2: Bounded Progress and Cancellation in Existing Rendering Loops

**Files:**
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_solid_cache.rb`
- Test: `test/import_run_control_integration_test.rb`
- Test: `test/geometry_builder_staging_test.rb`
- Test: `test/svg_text_3d_renderer_test.rb`

**Interfaces:**
- Consumes: `opts[:run_controller]` and the existing `progress_callback`.
- Produces: bounded `geometry_path`, `text_item`, `glyph_placement`, renderer-stage, and pre-commit checkpoints.

- [ ] **Step 1: Write failing callback/cancel tests**

Prove cancellation at a path batch, semantic item, and cached glyph placement
raises `ImportCancelled`, cleans current owned entities, and is not logged then
ignored as a callback failure.

- [ ] **Step 2: Verify RED**

Run the three focused test files. Expected failures: no run-controller checks and
the current progress wrappers swallow every `StandardError`.

- [ ] **Step 3: Add bounded checkpoints**

Call `controller.checkpoint!` before/after renderer stages, every 100 paths,
every semantic item, during cached placement batches, and immediately before
source verification/commit. Re-raise `ImportCancelled` before generic rescue.
Continue publishing the existing batch-host progress events.

- [ ] **Step 4: Verify GREEN**

Run the focused tests and the exact Ruby 2.2 parse gate.

### Task 3: Certified Model-Backed Page Resume

**Files:**
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/import_dialog.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/report_dialog.rb`
- Test: `test/import_resume_test.rb`
- Test: `test/import_dialog_test.rb`

**Interfaces:**
- Produces: `run_resumable_pipeline(model, path, opts)`, journal schema
  `bcs.sketchup_import_resume/1.0`, `Controller#certify_page!`,
  `Controller#resumable_pages`, and structured cancel/completion results.
- Consumes: unchanged `run_pipeline` with one selected page and
  `opts[:resumable_page_call] == true`.

- [ ] **Step 1: Write failing journal identity tests**

Use model/group fakes to prove a checkpoint is resumable only when PDF SHA,
canonical behavior-option SHA, importer identity SHA, package/source identity,
page number, stable group identity, liveness, and deterministic retained-entity
signature all match.

- [ ] **Step 2: Write failing page-transaction tests**

Inject a single-page runner. Make pages 1 and 2 pass, cancel page 3, and assert
pages 1/2 remain certified while page 3 is absent. Re-run and assert only page 3
executes. Add mismatch, edited-group, duplicate-group, and save/reopen fake cases.

- [ ] **Step 3: Verify RED**

Run `ruby test\import_resume_test.rb`; expected failures are missing journal and
orchestrator APIs.

- [ ] **Step 4: Implement page orchestration and aggregation**

Keep the renderer untouched: call `run_pipeline` once per page, carry forward
the page-arrangement offset, merge exact counters/evidence arrays, and build the
final aggregate diagnostics only after all pages are new or revalidated.
Require Group-per-page for resume; other grouping remains atomic and is labeled
non-resumable.

- [ ] **Step 5: Implement honest UI copy**

For large work, show exact counts and Continue/Cancel. Status text includes
page/item/percent/elapsed/ETA and `Esc to cancel`. On Cancel, state exact retained
pages and next page; never call an all-or-nothing retry Resume.

- [ ] **Step 6: Verify GREEN and adjacent fidelity**

Run resume/dialog tests plus text routing, all-mode placement, raster proof, and
representation-fidelity suites.

### Task 4: Idempotent Existing-Tag Release Completer

**Files:**
- Create: `tools/complete_github_release.py`
- Create: `tools/test_complete_github_release.py`
- Modify: `.github/workflows/auto-release.yml`
- Modify: `tools/test_release_safety.py`
- Modify: `tools/test_workflow_poppler_contract.py`

**Interfaces:**
- Produces: CLI accepting `--repo`, `--tag`, `--target`, `--title`, `--notes`,
  repeated `--asset PATH`, and `--github-output`; JSON result fields
  `completed`, `changed`, `immutable`, `tag`, `target`, `url`, `assets`.
- Consumes: an injectable subprocess runner around `gh api/release` commands.

- [ ] **Step 1: Write failing state-machine tests**

Cover absent Release, existing-tag absent Release, partial mutable Release,
complete immutable no-op, wrong digest, duplicate asset name, immutable
incomplete, wrong tag target, and create-race reinspection.

- [ ] **Step 2: Verify RED**

Run `python -m unittest tools.test_complete_github_release -v`; expected import
failure.

- [ ] **Step 3: Implement fail-closed completion**

Hash every local asset before network mutation. Verify the tag ref. Inspect asset
name/size/digest. Upload only missing files and never pass `--clobber`. Reinspect
after each mutation and after a create conflict. Exit nonzero for any state that
cannot converge without overwriting.

- [ ] **Step 4: Replace workflow shell branch**

Generate exact RBZ/source checksum assets, invoke the helper, and gate website
dispatch on `changed=true && completed=true`. Remove the Release-exists shortcut.

- [ ] **Step 5: Verify GREEN**

Run all three Python release test modules and YAML/static release gates.

### Task 5: Strict Exact-Package Host Acceptance Identity

**Files:**
- Modify: `tools/sketchup_host_job.rb`
- Modify: `tools/sketchup_host_launcher.rb`
- Modify: `tools/sketchup_batch_import.rb`
- Modify: `tools/sketchup_host_evidence.rb`
- Modify: `test/sketchup_host_job_test.rb`
- Modify: `test/sketchup_host_launcher_test.rb`
- Modify: `test/sketchup_batch_host_contract_test.rb`
- Modify: `test/sketchup_host_evidence_test.rb`

**Interfaces:**
- Strict job fields: `release_acceptance`, `repository_root`, `git_commit`,
  `git_tag`, `package_path`, `package_sha256`, `source_tree_sha256`,
  `expected_host_version`, `expected_ruby_target`, `lease_path`.
- Result fields: the strict inputs plus `release_acceptance_verified`,
  `engine_module_files` (`path`/`sha256`), and source PDF hashes before/after.

- [ ] **Step 1: Write failing strict-schema tests**

Require every exact field when `release_acceptance=true`; reject malformed SHA,
tag/commit mismatch, package digest mismatch, wrong host/Ruby, absent lease, and
module paths outside the staged root. Assert legacy jobs explicitly report
`release_acceptance=false`.

- [ ] **Step 2: Verify RED**

Run the four focused host test files; expected failures identify missing schema,
staging, and equality gates.

- [ ] **Step 3: Stage and bind the exact RBZ**

Hash the RBZ, verify local tag-to-commit, extract into the controlled run
directory through an injectable stager, validate RBZ layout, compute source-tree
and per-Ruby-file hashes, and set that isolated tree as the only host source root.

- [ ] **Step 4: Record and verify loaded module hashes**

Convert every critical method source location into an exact file path and
SHA-256. Bind the same identity through result, report, manifest, and reopen
verification. A legacy job remains useful for development but cannot pass the
strict acceptance entry point.

- [ ] **Step 5: Enforce the Q&A lease for strict acceptance**

Validate a live `SketchUp` global/host lease with matching owner/token before
spawn. Keep the verifier injectable in tests. Never kill by process name.

- [ ] **Step 6: Verify GREEN**

Run all host job/launcher/batch/evidence suites and exact Ruby parse.

### Task 6: Remaining Synthetic Coverage and User Documentation

**Files:**
- Modify only missing focused tests under `test/`
- Modify: `README.md`
- Modify: `HOST_COMPATIBILITY.md`
- Modify: `COMPATIBILITY.md`
- Modify: `C:\TMP\run_skp_probe.ps1` if its lease integration is still missing
- Modify: `C:\TMP\host_lock_protocol_test.ps1` only for a failing lease regression

**Interfaces:**
- Produces: a checked coverage map for rotation, clipping, Type3, soft masks,
  zero ink, inline images, malformed input, and page 2+ behavior.

- [ ] **Step 1: Audit current synthetic tests**

Record exact test names for each required case. Add temp-generated fixtures only
for an uncovered case and first prove the new test fails for the missing gate.

- [ ] **Step 2: Bind the guarded probe to the global lease**

If `run_skp_probe.ps1` still bypasses `host_lock.ps1`, write a failing isolated
PowerShell contract, then require an owned lease and PID-scoped cleanup.

- [ ] **Step 3: Document behavior without overclaiming**

Describe exact progress fields, Escape cancellation boundary, retained-page
resume identity, non-resumable grouping, and strict host/release evidence.

- [ ] **Step 4: Run focused coverage and privacy gates**

Ensure all fixtures are generated under test temp directories and no PDF/SKP or
private basename is tracked.

### Task 7: Version, Full Verification, Exact Host, and Immutable Patch

**Files:**
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb`
- Modify: `README.md`
- Modify version mirrors required by `test/version_metadata_test.rb`

**Interfaces:**
- Produces: the next patch version only because shipped Ruby bytes changed.

- [ ] **Step 1: Bump one patch and run version tests**

Update all committed version mirrors to the same next patch and verify exact
metadata consistency.

- [ ] **Step 2: Run every Ruby test and non-Ruby release gate**

Run every `test/*_test.rb`, exact Ruby 2.2 parse/smoke, Python release/runtime
tests, privacy scans, and `git diff --check`.

- [ ] **Step 3: Commit locally, tag the candidate locally, and build twice**

Commit the verified source/version state locally, create the unpushed candidate
tag at that exact commit, build into two fresh `C:\TMP` directories, compare
SHA-256 and archive entries, and reject any mismatch.

- [ ] **Step 4: Run exact-package real-host acceptance**

Claim global/SketchUp leases, launch the exact locally tagged RBZ through the
strict job, exercise cancel/retained-page/save/reopen/resume plus a six-mode
fidelity cell when behavior changed, terminate only recorded PIDs, and release
the exact leases.

- [ ] **Step 5: Push the host-accepted commit and tag**

Fetch/rebase only if needed without discarding user work, rebuild/retest if the
commit changes, then push protected `main` and the exact accepted tag. Wait for
all required workflows.

- [ ] **Step 6: Publish and independently verify the immutable patch**

Allow the idempotent workflow to create/complete the one new patch Release.
Download the public RBZ fresh, verify its SHA-256 equals the CI/local bytes, and
verify immutable state, tag target, asset URL, and clean `main == origin/main`.

- [ ] **Step 7: Append Q&A evidence and release the lane**

Update mutable `RESOURCE_BOARD.md`, append exact commands/results/commits/tags/
digests/run IDs to `WORKER_STATUS_LOG.md`, and do not rewrite prior entries.
