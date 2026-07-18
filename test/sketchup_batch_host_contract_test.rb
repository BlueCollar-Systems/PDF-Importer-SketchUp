#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

class SketchupBatchHostContractTest < Minitest::Test
  class FakeSession
    attr_reader :performed, :discarded, :quit, :started_payload

    def initialize(raise_error = false)
      @raise_error = raise_error
      @discarded = false
      @quit = false
    end

    def perform(job, binding)
      @performed = [job, binding]
      @started_payload = JSON.parse(File.read(job[:result_path]))
      raise 'fake pipeline failure' if @raise_error
      { 'requested_text_mode' => job[:text_mode].to_s, 'verified' => true }
    end

    def discard!
      @discarded = true
    end

    def quit!
      @quit = true
    end
  end

  def source
    File.read(
      File.join(REPO_ROOT, 'tools', 'sketchup_batch_import.rb'),
      :encoding => 'UTF-8'
    )
  end

  def importer_source
    File.read(
      File.join(
        REPO_ROOT, 'extracted', 'sketchup_ext',
        'bc_pdf_vector_importer', 'main.rb'
      ),
      :encoding => 'UTF-8'
    )
  end

  def test_runner_uses_one_job_argument_and_never_blocks_on_messagebox
    assert_includes source, 'arguments.length == 1'
    assert_includes source, 'SketchupHostJob.load(arguments[0])'
    assert_includes source, 'SketchupBatchImport.run_argv!(ARGV)'
    assert_includes source, 'rescue Exception => error'
    assert_includes source, 'active_session.quit!'
    assert_includes source, '@model.save(job[:model_path])'
    assert_includes source, 'File.file?(job[:model_path])'
    assert_includes source, "'run_pipeline' => importer.method(:run_pipeline).source_location"
    assert_includes source, "'source_root_verified' => true"
    assert_includes source, 'Sketchup.plugins_disabled?'
    assert_includes source, "'plugins_disabled_verified' => true"
    refute_includes source, 'UI.messagebox'
    refute_match(/ARGV\[1\]/, source)
  end

  def test_callable_orchestration_writes_bound_started_then_ok_and_quits
    load_runner_library
    with_job do |job_path, result_path, environment|
      session = FakeSession.new
      result = SketchupBatchImport.run_argv!(
        [job_path], session, environment
      )
      assert_equal 'STARTED', session.started_payload['status']
      assert_equal environment['BC_HOST_JOB_ID'],
                   session.started_payload['job_id']
      assert_equal 'OK', result['status']
      assert_equal true, result['verified']
      assert_equal true, session.quit
      assert_equal false, session.discarded
      assert_equal result, JSON.parse(File.read(result_path))
    end
  end

  def test_callable_orchestration_discards_closes_and_writes_error
    load_runner_library
    with_job do |job_path, result_path, environment|
      session = FakeSession.new(true)
      result = SketchupBatchImport.run_argv!(
        [job_path], session, environment
      )
      assert_equal 'ERROR', result['status']
      assert_match(/fake pipeline failure/, result['error'])
      assert session.discarded
      assert session.quit
      assert_equal result, JSON.parse(File.read(result_path))
    end
  end

  def test_callable_orchestration_rejects_zero_or_multiple_arguments
    load_runner_library
    [[], ['one', 'two']].each do |arguments|
      error = assert_raises(ArgumentError) do
        SketchupBatchImport.run_argv!(arguments, FakeSession.new, {})
      end
      assert_match(/exactly one/, error.message)
    end
  end

  def test_runner_maps_requested_modes_without_substitution
    assert_includes source, 'opts[:text_mode] = job[:text_mode]'
    assert_includes source,
                    'opts[:force_raster] = (job[:text_mode] == :raster)'
    assert_includes source,
                    'opts[:import_text] = (job[:text_mode] != :raster)'
    assert_includes source,
                    "'requested_text_mode' => job[:text_mode].to_s"
  end

  def test_real_session_uses_public_import_config_mode_factory
    load_runner_library
    value = Struct.new(:raw) do
      def to_opts
        raw.dup
      end
    end.new({ :factory_sentinel => true })
    config = Class.new
    config.singleton_class.send(:attr_accessor, :requested_mode)
    config.define_singleton_method(:from_mode) do |name|
      self.requested_mode = name
      value
    end
    importer = Module.new
    importer.const_set(:ImportConfig, config)
    job = {
      :pages => [1], :import_mode => 'vector', :text_mode => :text3d,
      :original_pdf_path => 'C:/source.pdf',
      :original_pdf_sha256 => 'a' * 64,
      :immutable_pdf_path => 'C:/snapshot.pdf',
      :immutable_pdf_sha256 => 'b' * 64
    }

    opts = SketchupBatchImport::RealHostSession.new.send(
      :import_options, importer, job
    )

    assert_equal 'Vector', config.requested_mode
    assert_equal true, opts[:factory_sentinel]
    assert_equal :text3d, opts[:text_mode]
    assert_equal true, opts[:use_3d_text]
    assert_equal false, opts[:force_raster]
  end

  def test_runner_preserves_complete_evidence_and_source_provenance
    assert_includes source,
                    'SketchupHostEvidence.verify_delivery_evidence!'
    assert_includes source,
                    "'representation_fidelity' => stats[:representation_fidelity]"
    assert_includes source,
                    "'import_contract_ready' => stats[:import_contract_ready]"
    assert_includes source,
                    "'terminal_text_delivery_records' =>"
    assert_includes source,
                    "'page_representation_fallbacks' =>"
    assert_includes source,
                    "'source_glyph_physical_deliveries' =>"
    assert_includes source,
                    "'text_renderers' => Array(stats[:text_renderers])"
    assert_includes source, "'worktree_metadata_version' =>"
    assert_includes source, "'loaded_importer_version' =>"
    assert_includes source, "'source_locations' => source_locations"
    assert_includes source,
                    'importer::CairoGlyphSource.method(:render_page_svg).source_location'
    assert_includes source,
                    'importer.method(:verified_item_raster_entity!).source_location'
    assert_includes source, "'original_pdf_path' => job[:original_pdf_path]"
    assert_includes source, "'immutable_pdf_path' => job[:immutable_pdf_path]"
    assert_includes source, "'normalized_pdf_path' =>"
    assert_includes source, "'salvage_note' =>"
    assert_includes source,
                    'after_manifest, reopened_manifest'
    assert_includes source, "'post_import_evidence_snapshot_started'"
    assert_includes source, "'post_import_evidence_snapshot_completed'"
    assert_includes source, "'reopen_evidence_snapshot_started'"
    assert_includes source, "'reopen_evidence_snapshot_completed'"
  end

  def test_pipeline_binds_report_to_immutable_input_and_records_salvage_lineage
    assert_includes importer_source, 'source_input_path = path'
    assert_includes importer_source, 'record_source_lineage!('
    assert_includes importer_source,
                    'finalize_import_diagnostics!(source_input_path, opts, stats)'
  end


  private

  def load_runner_library
    Object.send(:remove_const, :SketchupBatchImport) if
      defined?(SketchupBatchImport)
    load File.join(REPO_ROOT, 'tools', 'sketchup_batch_import.rb')
  end

  def with_job
    Dir.mktmpdir('su-runner-contract') do |dir|
      pdf = File.join(dir, 'input.pdf')
      output = File.join(dir, 'out')
      FileUtils.mkdir_p(output)
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      job_path = File.join(dir, 'job.json')
      File.write(job_path, JSON.generate(
        'pdf_path' => pdf,
        'output_dir' => output,
        'text_mode' => 'labels',
        'pages' => [1]
      ))
      environment = {
        'BC_HOST_JOB_ID' => 'job-123',
        'BC_HOST_JOB_SHA256' => Digest::SHA256.file(job_path).hexdigest,
        'BC_PDF_IMPORTER_BATCH_NONINTERACTIVE' => '1'
      }
      yield job_path, File.join(output, 'host_acceptance.json'), environment
    end
  end
end
