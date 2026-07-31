require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'open3'

require File.expand_path(
  '../tools/sketchup_full_corpus_sweep', __dir__
)

class SketchupFullCorpusSweepTest < Minitest::Test
  def test_default_source_root_is_the_versioned_importer_tree
    expected = File.expand_path(
      '../extracted/sketchup_ext', File.join(__dir__, '..', 'tools')
    )

    assert_equal expected, SketchupFullCorpusSweep.default_source_root
    assert File.directory?(SketchupFullCorpusSweep.default_source_root)
  end

  def test_private_pdf_under_steel_shapes_remains_git_ignored
    repository = File.expand_path('..', __dir__)
    private_pdf = File.join(repository, 'steel_shapes', 'private-corpus.pdf')
    _output, status = Open3.capture2e(
      'git', 'check-ignore', '--no-index', '-q', private_pdf,
      :chdir => repository
    )

    assert status.success?, 'steel_shapes private PDF must remain ignored'
  end

  def test_discovers_every_pdf_but_excludes_generated_evidence
    Dir.mktmpdir('su-full-corpus') do |root|
      FileUtils.mkdir_p(File.join(root, 'nested'))
      FileUtils.mkdir_p(File.join(root, 'Imported Evidence', 'SketchUp'))
      File.binwrite(File.join(root, 'a.pdf'), '%PDF-a')
      File.binwrite(File.join(root, 'nested', 'b.PDF'), '%PDF-b')
      File.binwrite(
        File.join(root, 'Imported Evidence', 'SketchUp', 'generated.pdf'),
        '%PDF-generated'
      )

      discovered = SketchupFullCorpusSweep.discover_pdfs(root)

      assert_equal(
        [
          File.join(root, 'a.pdf'),
          File.join(root, 'nested', 'b.PDF')
        ].map { |path| File.expand_path(path) },
        discovered
      )
    end
  end

  def test_discovery_prunes_generated_evidence_before_inspecting_its_files
    Dir.mktmpdir('su-full-corpus') do |root|
      evidence = File.join(root, 'Imported Evidence', 'SketchUp')
      FileUtils.mkdir_p(evidence)
      File.binwrite(File.join(root, 'source.pdf'), '%PDF-source')
      File.binwrite(File.join(evidence, 'large-generated.skp'), 'generated')
      original_file_query = File.method(:file?)

      guarded_file_query = lambda do |path|
        if File.expand_path(path).start_with?(File.expand_path(evidence))
          raise 'generated evidence was traversed'
        end
        original_file_query.call(path)
      end

      discovered = File.stub(:file?, guarded_file_query) do
        SketchupFullCorpusSweep.discover_pdfs(root)
      end

      assert_equal [File.expand_path(File.join(root, 'source.pdf'))], discovered
    end
  end

  def test_default_matrix_covers_all_twenty_four_import_representation_cells
    cells = SketchupFullCorpusSweep.matrix

    assert_equal 24, cells.length
    assert_equal(
      %w[auto hybrid raster vector],
      cells.map { |cell| cell['import_mode'] }.uniq.sort
    )
    assert_equal(
      %w[geometry glyphs labels raster text text3d],
      cells.map { |cell| cell['text_mode'] }.uniq.sort
    )
  end

  def test_runner_is_source_immutable_hash_keyed_and_resumable
    Dir.mktmpdir('su-full-corpus') do |root|
      corpus = File.join(root, 'corpus')
      evidence = File.join(root, 'evidence')
      FileUtils.mkdir_p(corpus)
      first = File.join(corpus, 'same name.pdf')
      second_dir = File.join(corpus, 'nested')
      FileUtils.mkdir_p(second_dir)
      second = File.join(second_dir, 'same name.pdf')
      File.binwrite(first, '%PDF-first')
      File.binwrite(second, '%PDF-second')
      original_hashes = [first, second].map do |path|
        Digest::SHA256.file(path).hexdigest
      end

      calls = []
      launcher = lambda do |job_path|
        job = JSON.parse(File.read(job_path, :encoding => 'UTF-8'))
        calls << job
        fake_host_result(job_path)
      end
      runner = SketchupFullCorpusSweep::Runner.new(
        :corpus_root => corpus,
        :evidence_root => evidence,
        :launcher => launcher,
        :import_modes => %w[auto vector],
        :text_modes => %w[text]
      )

      first_summary = runner.run

      assert_equal 4, first_summary['total']
      assert_equal 4, first_summary['passed']
      assert_equal 0, first_summary['failed']
      assert_equal 4, calls.length
      assert_equal 4, calls.map { |job| job.fetch('output_dir') }.uniq.length
      assert_equal(
        original_hashes,
        [first, second].map { |path| Digest::SHA256.file(path).hexdigest }
      )

      second_summary = runner.run

      assert_equal 4, second_summary['resumed']
      assert_equal 4, calls.length

      first_cell_path = second_summary.fetch('results').first
        .fetch('cell_result_path')
      first_cell = JSON.parse(File.read(first_cell_path, :encoding => 'UTF-8'))
      File.delete(first_cell.fetch('host_acceptance_path'))

      third_summary = runner.run

      assert_equal 3, third_summary['resumed']
      assert_equal 5, calls.length
    end
  end

  def test_summary_references_full_cell_evidence_without_embedding_it
    Dir.mktmpdir('su-full-corpus-summary') do |root|
      corpus = File.join(root, 'corpus')
      evidence = File.join(root, 'evidence')
      FileUtils.mkdir_p(corpus)
      File.binwrite(File.join(corpus, 'source.pdf'), '%PDF-source')
      large_evidence = 'x' * (2 * 1024 * 1024)
      launcher = lambda do |job_path|
        job = JSON.parse(File.read(job_path, :encoding => 'UTF-8'))
        fake_host_result(job_path).merge(
          'full_host_evidence' => large_evidence
        )
      end
      runner = SketchupFullCorpusSweep::Runner.new(
        :corpus_root => corpus,
        :evidence_root => evidence,
        :launcher => launcher,
        :import_modes => %w[auto],
        :text_modes => %w[text]
      )

      summary = runner.run
      summary_path = File.join(evidence, 'full_sweep_summary.latest.json')
      cell_path = summary.fetch('results').first.fetch('cell_result_path')
      cell = JSON.parse(File.read(cell_path, :encoding => 'UTF-8'))
      acceptance_path = cell.fetch('host_acceptance_path')

      assert_operator File.size(summary_path), :<, 32 * 1024
      refute_includes File.binread(summary_path), large_evidence
      assert_operator File.size(cell_path), :<, 32 * 1024
      refute_includes File.binread(cell_path), large_evidence
      assert_includes File.binread(acceptance_path), large_evidence
      assert_equal Digest::SHA256.file(acceptance_path).hexdigest,
                   cell.fetch('host_acceptance_sha256')
      assert_equal File.size(acceptance_path),
                   cell.fetch('host_acceptance_bytes')
      assert_equal 'PASS', summary.fetch('results').first.fetch('status')
    end
  end

  def test_launcher_ok_without_complete_artifacts_cannot_be_a_pass
    Dir.mktmpdir('su-full-corpus-incomplete-ok') do |root|
      corpus = File.join(root, 'corpus')
      evidence = File.join(root, 'evidence')
      FileUtils.mkdir_p(corpus)
      File.binwrite(File.join(corpus, 'source.pdf'), '%PDF-source')

      summary = SketchupFullCorpusSweep::Runner.new(
        :corpus_root => corpus,
        :evidence_root => evidence,
        :launcher => lambda { |_job_path| { 'status' => 'OK' } },
        :import_modes => %w[auto],
        :text_modes => %w[text]
      ).run

      assert_equal 0, summary['passed']
      assert_equal 1, summary['failed']
      assert_equal 'FAIL', summary['results'].first['status']
    end
  end

  def test_full_verification_is_default_and_does_not_resume_export_only_acceptance
    Dir.mktmpdir('su-full-corpus-verification-level') do |root|
      corpus = File.join(root, 'corpus')
      evidence = File.join(root, 'evidence')
      FileUtils.mkdir_p(corpus)
      File.binwrite(File.join(corpus, 'source.pdf'), '%PDF-source')
      jobs = []
      launcher = lambda do |job_path|
        job = JSON.parse(File.read(job_path, :encoding => 'UTF-8'))
        jobs << job
        fake_host_result(job_path)
      end
      common = {
        :corpus_root => corpus,
        :evidence_root => evidence,
        :launcher => launcher,
        :import_modes => %w[auto],
        :text_modes => %w[text]
      }

      full_summary = SketchupFullCorpusSweep::Runner.new(common).run
      resumed_full = SketchupFullCorpusSweep::Runner.new(common).run
      export_summary = SketchupFullCorpusSweep::Runner.new(
        common.merge(:skp_export_only => true)
      ).run

      assert_equal 2, jobs.length
      assert_equal [false, true], jobs.map { |job| job['skp_export_only'] }
      assert_equal 0, full_summary['resumed']
      assert_equal 1, resumed_full['resumed']
      assert_equal 0, export_summary['passed']
      assert_equal 1, export_summary['exported']
      assert_equal 'EXPORTED', export_summary['results'].first['status']
    end
  end

  def test_resume_is_invalidated_when_importer_source_tree_changes
    Dir.mktmpdir('su-full-corpus-source-tree') do |root|
      corpus = File.join(root, 'corpus')
      evidence = File.join(root, 'evidence')
      source_root = File.join(root, 'source')
      FileUtils.mkdir_p(corpus)
      FileUtils.mkdir_p(source_root)
      File.binwrite(File.join(corpus, 'source.pdf'), '%PDF-source')
      source_file = File.join(source_root, 'main.rb')
      File.binwrite(source_file, "VERSION = 1\n")
      calls = 0
      launcher = lambda do |job_path|
        calls += 1
        fake_host_result(job_path)
      end
      common = {
        :corpus_root => corpus,
        :evidence_root => evidence,
        :source_root => source_root,
        :launcher => launcher,
        :import_modes => %w[auto],
        :text_modes => %w[text]
      }

      first = SketchupFullCorpusSweep::Runner.new(common).run
      resumed = SketchupFullCorpusSweep::Runner.new(common).run
      File.binwrite(source_file, "VERSION = 2\n")
      changed = SketchupFullCorpusSweep::Runner.new(common).run

      assert_equal 2, calls
      assert_equal 0, first['resumed']
      assert_equal 1, resumed['resumed']
      assert_equal 0, changed['resumed']
      refute_equal first['source_tree_sha256'], changed['source_tree_sha256']
      cell = JSON.parse(File.read(
        changed.fetch('results').first.fetch('cell_result_path'),
        :encoding => 'UTF-8'
      ))
      assert_equal changed['source_tree_sha256'], cell['source_tree_sha256']
    end
  end

  def test_pause_file_stops_between_cells_without_starting_a_host
    Dir.mktmpdir('su-full-corpus-pause') do |root|
      corpus = File.join(root, 'corpus')
      evidence = File.join(root, 'evidence')
      pause_file = File.join(root, 'PAUSE')
      FileUtils.mkdir_p(corpus)
      File.binwrite(File.join(corpus, 'source.pdf'), '%PDF-source')
      File.binwrite(pause_file, 'coordinated pause')
      calls = 0
      launcher = lambda do |_job_path|
        calls += 1
        { 'status' => 'OK' }
      end
      runner = SketchupFullCorpusSweep::Runner.new(
        :corpus_root => corpus,
        :evidence_root => evidence,
        :launcher => launcher,
        :import_modes => %w[auto vector],
        :text_modes => %w[text],
        :pause_file => pause_file
      )

      summary = runner.run

      assert_equal 0, calls
      assert_equal true, summary['paused']
      assert_equal 2, summary['not_run']
      assert_equal 0, summary['results'].length
    end
  end

  def test_empty_corpus_fails_closed
    Dir.mktmpdir('su-full-corpus-empty') do |root|
      corpus = File.join(root, 'corpus')
      evidence = File.join(root, 'evidence')
      FileUtils.mkdir_p(corpus)

      error = assert_raises(ArgumentError) do
        SketchupFullCorpusSweep::Runner.new(
          :corpus_root => corpus,
          :evidence_root => evidence,
          :launcher => lambda { |_job_path| flunk('host must not launch') },
          :import_modes => %w[auto],
          :text_modes => %w[text]
        ).run
      end
      assert_match(/no PDF/i, error.message)
    end
  end

  def test_resume_revalidates_model_report_and_manifest_hashes
    Dir.mktmpdir('su-full-corpus-resume-artifacts') do |root|
      corpus = File.join(root, 'corpus')
      evidence = File.join(root, 'evidence')
      FileUtils.mkdir_p(corpus)
      File.binwrite(File.join(corpus, 'source.pdf'), '%PDF-source')
      calls = 0
      launcher = lambda do |job_path|
        calls += 1
        fake_host_result(job_path)
      end
      options = {
        :corpus_root => corpus,
        :evidence_root => evidence,
        :launcher => launcher,
        :import_modes => %w[auto],
        :text_modes => %w[text]
      }

      first = SketchupFullCorpusSweep::Runner.new(options).run
      cell = JSON.parse(File.read(
        first['results'].first['cell_result_path'], :encoding => 'UTF-8'
      ))
      acceptance = JSON.parse(File.read(
        cell['host_acceptance_path'], :encoding => 'UTF-8'
      ))
      File.open(acceptance.fetch('model_path'), 'ab') { |file| file.write('drift') }

      rerun = SketchupFullCorpusSweep::Runner.new(options).run

      assert_equal 2, calls
      assert_equal 0, rerun['resumed']
    end
  end

  def test_exit_code_rejects_paused_summary_with_prior_failure
    assert_equal 1, SketchupFullCorpusSweep.exit_code(
      'paused' => true, 'failed' => 1, 'not_run' => 2,
      'passed' => 0, 'exported' => 0, 'total' => 3,
      'skp_export_only' => false
    )
    assert_equal 0, SketchupFullCorpusSweep.exit_code(
      'paused' => true, 'failed' => 0, 'not_run' => 2,
      'passed' => 1, 'exported' => 0, 'total' => 3,
      'skp_export_only' => false
    )
  end

  private

  def fake_host_result(job_path)
    job = JSON.parse(File.read(job_path, :encoding => 'UTF-8'))
    output = job.fetch('output_dir')
    pdf = File.expand_path(job.fetch('pdf_path'))
    pdf_sha = Digest::SHA256.file(pdf).hexdigest
    model = File.join(output, 'model.skp')
    report = File.join(output, 'import_report.json')
    manifest = File.join(output, 'entity_manifest.json')
    File.binwrite(model, 'verified-model')
    lineage = {
      'original_pdf_path' => pdf,
      'original_pdf_sha256' => pdf_sha,
      'immutable_pdf_path' => pdf,
      'immutable_pdf_sha256' => pdf_sha,
      'normalized_pdf_path' => pdf,
      'normalized_pdf_sha256' => pdf_sha,
      'salvage_note' => nil
    }
    File.write(report, JSON.generate(
      'input' => { 'file' => pdf, 'sha256' => pdf_sha },
      'extra' => {
        'requested_text_mode' => job.fetch('text_mode'),
        'source_lineage' => lineage,
        'source_tree_sha256_before_load' => job['source_tree_sha256'],
        'source_tree_sha256_after_import' => job['source_tree_sha256']
      }
    ))
    unless job.fetch('skp_export_only')
      File.write(manifest, JSON.generate(
        'source_pdf_path' => pdf,
        'source_pdf_sha256' => pdf_sha,
        'source_lineage' => lineage,
        'source_tree_sha256_before_load' => job['source_tree_sha256'],
        'source_tree_sha256_after_import' => job['source_tree_sha256']
      ))
    end
    result = {
      'status' => 'OK',
      'skp_export_only' => job.fetch('skp_export_only'),
      'requested_text_mode' => job.fetch('text_mode'),
      'effective_text_mode' => job.fetch('text_mode'),
      'source_pdf_path' => pdf,
      'source_pdf_sha256' => pdf_sha,
      'original_pdf_path' => pdf,
      'original_pdf_sha256' => pdf_sha,
      'immutable_pdf_path' => pdf,
      'immutable_pdf_sha256' => pdf_sha,
      'normalized_pdf_path' => pdf,
      'normalized_pdf_sha256' => pdf_sha,
      'salvage_note' => nil,
      'source_tree_sha256_before_load' => job['source_tree_sha256'],
      'source_tree_sha256_after_import' => job['source_tree_sha256'],
      'model_path' => model,
      'model_sha256' => Digest::SHA256.file(model).hexdigest,
      'import_report_path' => report,
      'import_report_sha256' => Digest::SHA256.file(report).hexdigest
    }
    unless job.fetch('skp_export_only')
      result['entity_manifest_path'] = manifest
      result['entity_manifest_sha256'] = Digest::SHA256.file(manifest).hexdigest
    end
    result
  end
end
