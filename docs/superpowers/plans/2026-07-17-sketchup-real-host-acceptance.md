# SketchUp Real-Host Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the modal, Labels-only SketchUp batch probe with a Ruby 2.2-compatible, single-job-file real-host acceptance runner that can verify each requested representation, save the model, and emit a truthful machine-readable result.

**Architecture:** SketchUp 2017 reliably supplies one `-RubyStartupArg`, so a small host-independent job parser will load a JSON job from that argument and normalize paths, pages, import mode, and requested representation. The host runner will consume the normalized job, load the source tree, run the production pipeline, save the model, snapshot resulting entities and representation evidence, write `host_acceptance.json` on success or failure, and close only the batch-created SketchUp process without modal UI.

**Tech Stack:** Ruby 2.2.4 / Minitest / SketchUp Ruby API / JSON / existing `run_pipeline` and `QAReport` production paths.

## Global Constraints

- Labels, 3D Text, Glyphs, Geometry, and Raster remain distinct requested outcomes; the runner must never change the requested type to hide a transform defect.
- Fallback remains production-controlled, item-scoped, finite, and evidence-gated; the runner records it but does not manufacture or bypass proof.
- One `-RubyStartupArg` carries one JSON job path; paths containing spaces must remain intact.
- The runner must write an ERROR result for any exception, nil pipeline result, missing report, missing saved model, or incomplete representation evidence.
- The runner must prove the exercised `run_pipeline` implementation and the
  representation-fidelity modules came from this worktree's source root. An
  already loaded installed extension (currently 3.7.96) must never satisfy a
  source-tree acceptance run for 3.7.97 or later.
- The runner must not show message boxes, buy/activate another extension, modify installed plugins, or require paid software.
- Ruby syntax and APIs must remain compatible with SketchUp Make 2017's Ruby 2.2.4-p230.

---

### Task 1: Parse and validate one host job

**Files:**
- Create: `tools/sketchup_host_job.rb`
- Create: `test/sketchup_host_job_test.rb`

**Interfaces:**
- Consumes: a single path from `ARGV[0]`, pointing to either a JSON job or a legacy PDF.
- Produces: `SketchupHostJob.load(argument)` returning a symbol-keyed hash with `:pdf_path`, `:output_dir`, `:text_mode`, `:import_mode`, `:pages`, `:model_path`, and `:result_path`.

- [ ] **Step 1: Write the failing job-parser tests**

```ruby
#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

class SketchupHostJobTest < Minitest::Test
  def load_job_tool
    load File.join(REPO_ROOT, 'tools', 'sketchup_host_job.rb')
  end

  def test_json_job_preserves_spaced_paths_and_requested_mode
    load_job_tool
    Dir.mktmpdir('su host job ') do |dir|
      pdf = File.join(dir, 'drawing with spaces.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      output = File.join(dir, 'host output')
      job_path = File.join(dir, 'job.json')
      File.write(job_path, JSON.generate(
        'pdf_path' => pdf,
        'output_dir' => output,
        'text_mode' => 'text3d',
        'import_mode' => 'vector',
        'pages' => [1]
      ))

      job = SketchupHostJob.load(job_path)
      assert_equal File.expand_path(pdf), job[:pdf_path]
      assert_equal File.expand_path(output), job[:output_dir]
      assert_equal :text3d, job[:text_mode]
      assert_equal 'vector', job[:import_mode]
      assert_equal [1], job[:pages]
      assert_equal File.join(output, 'drawing with spaces-text3d.skp'), job[:model_path]
      assert_equal File.join(output, 'host_acceptance.json'), job[:result_path]
    end
  end

  def test_legacy_pdf_argument_retains_labels_behavior_without_second_argument
    load_job_tool
    Dir.mktmpdir('su-host-job') do |dir|
      pdf = File.join(dir, 'legacy.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      job = SketchupHostJob.load(pdf)
      assert_equal :labels, job[:text_mode]
      assert_equal File.dirname(pdf), job[:output_dir]
    end
  end

  def test_unknown_requested_mode_is_rejected
    load_job_tool
    Dir.mktmpdir('su-host-job') do |dir|
      pdf = File.join(dir, 'drawing.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      job_path = File.join(dir, 'job.json')
      File.write(job_path, JSON.generate(
        'pdf_path' => pdf, 'output_dir' => dir,
        'text_mode' => 'auto_change_type'
      ))
      error = assert_raises(ArgumentError) { SketchupHostJob.load(job_path) }
      assert_match(/text_mode/, error.message)
    end
  end
end
```

- [ ] **Step 2: Run the test and verify RED**

Run: `ruby test/sketchup_host_job_test.rb`

Expected: FAIL because `tools/sketchup_host_job.rb` does not exist.

- [ ] **Step 3: Implement the minimum Ruby 2.2-compatible parser**

```ruby
#!/usr/bin/env ruby
require 'json'

module SketchupHostJob
  TEXT_MODES = [:labels, :text3d, :glyphs, :geometry, :raster].freeze
  IMPORT_MODES = ['auto', 'vector', 'raster', 'hybrid'].freeze

  def self.load(argument)
    raise ArgumentError, 'one job JSON or PDF path is required' if argument.to_s.strip.empty?
    input = File.expand_path(argument.to_s)
    if File.extname(input).downcase == '.json'
      raw = JSON.parse(File.read(input, :encoding => 'UTF-8'))
      pdf_path = File.expand_path(raw.fetch('pdf_path'), File.dirname(input))
      output_dir = File.expand_path(raw.fetch('output_dir'), File.dirname(input))
      text_mode = raw.fetch('text_mode').to_s.downcase.to_sym
      import_mode = raw.fetch('import_mode', 'auto').to_s.downcase
      pages = normalize_pages(raw.fetch('pages', 'all'))
    else
      pdf_path = input
      output_dir = File.dirname(input)
      text_mode = :labels
      import_mode = 'auto'
      pages = :all
    end
    raise ArgumentError, "PDF not found: #{pdf_path}" unless File.file?(pdf_path)
    raise ArgumentError, "unsupported text_mode: #{text_mode}" unless TEXT_MODES.include?(text_mode)
    raise ArgumentError, "unsupported import_mode: #{import_mode}" unless IMPORT_MODES.include?(import_mode)
    base = File.basename(pdf_path, File.extname(pdf_path))
    {
      :pdf_path => pdf_path,
      :output_dir => output_dir,
      :text_mode => text_mode,
      :import_mode => import_mode,
      :pages => pages,
      :model_path => File.join(output_dir, "#{base}-#{text_mode}.skp"),
      :result_path => File.join(output_dir, 'host_acceptance.json')
    }
  end

  def self.normalize_pages(value)
    return :all if value.to_s.downcase == 'all'
    pages = Array(value).map do |page|
      if page.is_a?(Integer)
        page
      elsif page.is_a?(String) && page =~ /\A[1-9][0-9]*\z/
        page.to_i
      else
        raise ArgumentError, 'pages must contain positive integers'
      end
    end
    raise ArgumentError, 'pages must contain positive integers' if pages.empty? || pages.any? { |page| page < 1 }
    pages.uniq.sort
  rescue StandardError
    raise ArgumentError, 'pages must be all or positive integers'
  end
end
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `ruby test/sketchup_host_job_test.rb`

Expected: 10 tests, 41 assertions, 0 failures, 0 errors.

### Task 2: Make the real-host runner non-modal and fail-closed

**Files:**
- Modify: `tools/sketchup_batch_import.rb`
- Create: `tools/sketchup_host_evidence.rb`
- Create: `tools/sketchup_host_launcher.rb`
- Create: `extracted/sketchup_ext/bc_pdf_vector_importer/batch_host_policy.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/dependency_resolver.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/qa_report.rb`
- Create: `test/sketchup_batch_host_contract_test.rb`
- Create: `test/sketchup_host_evidence_test.rb`
- Create: `test/sketchup_host_launcher_test.rb`
- Create: `test/batch_host_nonmodal_policy_test.rb`
- Modify: `test/qa_report_test.rb`

**Interfaces:**
- Consumes: `SketchupHostJob.load(ARGV[0])` and the production importer source tree.
- Produces: `host_acceptance.json`, a saved `.skp`, copied `import_report.json`, and a recursive entity-type/bounds manifest.

The pure `SketchupHostEvidence` helper owns source-root validation, recursive
entity snapshots, manifest ID collection, and delivery-ID cross-checks. Keep
these behaviors outside the top-level startup script so they can be tested with
small host fakes under ordinary Ruby.

- [ ] **Step 1: Write the failing runner contract test**

```ruby
#!/usr/bin/env ruby
require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

class SketchupBatchHostContractTest < Minitest::Test
  def source
    File.read(File.join(REPO_ROOT, 'tools', 'sketchup_batch_import.rb'), :encoding => 'UTF-8')
  end

  def test_runner_uses_one_job_argument_and_never_blocks_on_messagebox
    assert_includes source, 'SketchupHostJob.load(ARGV[0])'
    assert_includes source, "'host_acceptance.json'"
    assert_includes source, 'rescue Exception => error'
    assert_includes source, 'Sketchup.quit'
    assert_includes source, 'model.save(job[:model_path])'
    assert_includes source, 'importer.method(:run_pipeline).source_location'
    assert_includes source, "'source_root_verified' => true"
    refute_includes source, 'UI.messagebox'
    refute_match(/ARGV\[1\]/, source)
  end

  def test_runner_maps_requested_modes_without_substitution
    assert_includes source, 'opts[:text_mode] = job[:text_mode]'
    assert_includes source, "opts[:force_raster] = (job[:text_mode] == :raster)"
    assert_includes source, "opts[:import_text] = (job[:text_mode] != :raster)"
    assert_includes source, "'requested_text_mode' => job[:text_mode].to_s"
  end
end
```

Also write behavioral RED tests for `SketchupHostEvidence` before the runner:

- a source file genuinely below the expected root is accepted, while a sibling
  prefix such as `sketchup_ext-old` is rejected (case-insensitive Windows paths);
- nested Group/Component-like fakes produce recursive rows with entity ID,
  typename, validity/deletion state, bounds, transform, and children;
- a delivery record whose positive entity ID exists in a nested manifest passes;
  missing, zero, negative, or empty claimed delivery IDs fail closed;
- `representation_fidelity.ready` or `import_contract_ready.ready` false/missing
  makes host evidence incomplete rather than successful.

- [ ] **Step 2: Run the contract test and verify RED**

Run: `ruby test/sketchup_batch_host_contract_test.rb`

Expected: FAIL because the existing runner hard-codes Labels, reads `ARGV[1]`, shows message boxes, and does not save or emit a host result.

- [ ] **Step 3: Implement the minimum host runner**

Use callable orchestration with an injected host-session object so ordinary
Ruby behavioral fakes exercise STARTED/OK/ERROR, discard, and quit behavior.
The external launcher, not the startup script, owns reversible next-start plugin
suppression, timeout, and the exact child PID. The startup script owns the production import,
recursive before/after ownership, strict ledgers, report binding, save/reopen,
and atomic bound results. Do not restore the rejected one-file skeleton: it
could hang before rescue, load installed plugins, accept stale reports, and
confuse session-local IDs with reopen-stable IDs.

Capture recursive identity snapshots immediately before and after
`run_pipeline`. Implement `SketchupHostEvidence.snapshot_entities(entities)`
recursively for groups and component instances. Each manifest row must contain
both host `entityID` and `persistent_id` namespaces, typename, valid/deleted
state, bounds min/max when available, transformation matrix when available,
and nested children. Cross-check same-session delivery claims against their
declared namespace; after save/reopen, correlate by `persistent_id` because
`entityID` may legitimately change. Treat a missing/empty manifest,
missing production report, missing copied report, failed model save, or missing
result artifact as ERROR. Include the complete delivery arrays and both
`representation_fidelity` and `import_contract_ready` objects in the result;
do not reduce them to counts or booleans.

Also record the worktree metadata version and source locations for the
representation-fidelity normalizer/controller and each representation renderer
used by the run. Reject any location outside `plugin_root`. This is an
acceptance guard against SketchUp's installed 3.7.96 extension satisfying the
run through already-loaded constants while the worktree is 3.7.97 or newer.

The external `sketchup_host_launcher.rb` preserves the real APPDATA,
LOCALAPPDATA, and PROGRAMDATA paths (including the user's real license state).
Before launch it captures the exact persisted `Sketchup.plugins_disabled`
preference state, enables the official next-start suppression preference,
proves it by readback, and restores the prior value/existence/type on every
normal, error, crash, and timeout path. The host must independently confirm
`Sketchup.plugins_disabled? == true`; otherwise the run is ERROR. The launcher
also creates an immutable per-job PDF copy before the host starts, passes only
that copy through exactly one startup argument, records original/immutable/
normalized-salvage lineage, captures the child exit code, and accepts OK only
when exit code zero accompanies the complete bound model/report/manifest
contract. It kills only the PID it spawned when the host remains STARTED or
fails to exit before timeout. No installed plugin file is read, moved, renamed,
or modified. The in-host runner installs a last-resort modal guard; production
first-run, large-file, missing-renderer, and salvage paths must honor the
explicit noninteractive policy and fail closed without prompting.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `ruby test/sketchup_host_job_test.rb && ruby test/sketchup_host_evidence_test.rb && ruby test/sketchup_batch_host_contract_test.rb`

Expected: all tests pass.

### Task 3: Run real SketchUp 2017 acceptance and preserve evidence

**Files:**
- Create at runtime only: `C:\TMP\su2017-week-sweep\<fixture>\<mode>\job.json`
- Create at runtime only: `host_acceptance.json`, imported `.skp`, copied `import_report.json`

**Interfaces:**
- Consumes: the two owner PDFs and source worktree runner.
- Produces: one independently inspectable artifact set per fixture and requested mode.

- [ ] **Step 1: Create one JSON job per fixture/mode**

Modes: `labels`, `text3d`, `glyphs`, `geometry`, `raster`; import mode `vector` except requested Raster, which uses `raster`.

- [ ] **Step 2: Launch SketchUp through the guarded watchdog**

Run: set `SKETCHUP_EXE` to the SketchUp 2017 executable, then run
`ruby tools/sketchup_host_launcher.rb <job.json>`.

Expected: the launcher proves and later restores the official plugin-disabled
preference, preserves the real user/machine profile and license paths, imports
only an immutable per-job PDF copy, and passes exactly one `-RubyStartupArg`,
`host_acceptance.json` moves atomically from bound STARTED to bound OK or a
specific ERROR, SketchUp closes itself, and no installed third-party plugin or
BlueCollar message box appears. A lingering process is a timeout ERROR, never
an acceptance pass.

- [ ] **Step 3: Validate each artifact fail-closed**

Assert the result's requested mode equals the job's requested mode and was not
mutated. `delivery_summary_mode` may differ only when the complete delivery
records prove affirmative item-specific impossibility and every transition is
the next adjacent representation in the declared fallback ladder. Assert model,
report, and manifest exist; every source delivery has positive host entity IDs
that occur in the manifest; fallback records are item-scoped and adjacent;
ERROR is never reclassified as impossibility; Raster creates a verified image;
save/reopen retains entities and transforms. This fallback rule governs over
any example assertion that would require delivered mode to equal requested
mode unconditionally.

- [ ] **Step 4: Render and visually compare**

Use source PDF PNGs and SketchUp top/parallel-projection exports at a shared aspect ratio. Record alignment, rotation, width, height, clipping, and missing/duplicate-item mismatches. A count-only pass is insufficient.

### Task 4: Full verification and commit

**Files:**
- Modify only if evidence requires: production files named by the real-host failure trace.
- Test first: a focused regression test for every confirmed product defect.

- [ ] **Step 1: For each confirmed mismatch, write and run a failing test before production edits**
- [ ] **Step 2: Implement one root-cause correction at a time and verify RED to GREEN**
- [ ] **Step 3: Re-run all 63 Ruby test files, smoke 65/65, exact Ruby 2.2.4 parse, build, and real-host acceptance**
- [ ] **Step 4: Review the diff, update version/current authority, commit with `[skip release]`, push, and verify zero ahead/behind**
