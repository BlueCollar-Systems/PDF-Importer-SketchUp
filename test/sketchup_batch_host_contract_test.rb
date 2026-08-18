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
    assert_includes source,
                    'opts[:text_mode] = effective_requested_mode(job)'
    assert_includes source,
                    "full_page_raster = (job[:import_mode].to_s == 'raster')"
    assert_includes source,
                    'opts[:force_raster] = full_page_raster'
    assert_includes source,
                    'opts[:import_text] = !full_page_raster'
    assert_includes source, ':progress_callback => lambda'
    assert_includes source,
                    "SketchupBatchImport.write_progress!("
    assert_includes source, 'requested_mode = effective_requested_mode(job)'
    assert_includes source,
                    "'requested_text_mode' => requested_mode.to_s"
  end

  def test_runner_defaults_source_root_to_repository_extension
    load_runner_library
    expected = File.expand_path(
      File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
    )

    assert_equal expected, SketchupBatchImport.plugin_root({})
  end

  def test_runner_accepts_explicit_installed_source_root
    load_runner_library
    Dir.mktmpdir('su-installed-source') do |dir|
      configured = File.join(dir, 'Plugins')

      assert_equal File.expand_path(configured), SketchupBatchImport.plugin_root(
        'BC_SKETCHUP_IMPORTER_SOURCE_ROOT' => configured
      )
    end
  end

  def test_full_page_raster_job_uses_raster_as_effective_evidence_mode
    load_runner_library
    session = SketchupBatchImport::RealHostSession.new

    assert_equal :raster, session.send(
      :effective_requested_mode,
      :import_mode => 'raster', :text_mode => :text3d
    )
    assert_equal :text3d, session.send(
      :effective_requested_mode,
      :import_mode => 'vector', :text_mode => :text3d
    )
  end

  def test_pure_terminal_page_raster_accepts_only_exact_explicit_raster_contract
    load_runner_library
    session = SketchupBatchImport::RealHostSession.new
    stats = pure_terminal_raster_stats([1, 2])
    raster_job = {
      :import_mode => 'raster', :text_mode => :text3d, :pages => [1, 2]
    }

    assert session.send(:pure_terminal_page_raster?, stats, raster_job)
  end

  def test_pure_terminal_page_raster_rejects_non_explicit_and_non_raster_modes
    load_runner_library
    session = SketchupBatchImport::RealHostSession.new
    stats = pure_terminal_raster_stats([1])
    cases = [
      ['auto labels', { :import_mode => 'auto', :text_mode => :labels,
                        :pages => [1] }],
      ['vector raster text strategy', { :import_mode => 'vector',
                                        :text_mode => :raster, :pages => [1] }]
    ]

    cases.each do |label, job|
      refute session.send(:pure_terminal_page_raster?, stats, job), label
    end
  end

  def test_pure_terminal_page_raster_rejects_incomplete_or_nonimage_records
    load_runner_library
    session = SketchupBatchImport::RealHostSession.new
    job = { :import_mode => 'raster', :text_mode => :labels, :pages => [1] }
    mutations = [
      ['requested labels', lambda { |record| record[:requested_mode] = :labels }],
      ['item Raster', lambda { |record| record[:delivery_scope] = :item_raster }],
      ['Geometry', lambda { |record| record[:created_entity_type] = 'Geometry' }],
      ['Text', lambda { |record| record[:created_entity_type] = 'Text' }],
      ['3D Text', lambda { |record| record[:created_entity_type] = 'Text3d' }],
      ['wrong basis', lambda do |record|
        record[:delivery_basis] = 'verified_zero_canonical_text'
      end],
      ['not full page', lambda { |record| record[:full_page_raster_request] = false }],
      ['semantic text', lambda { |record| record[:semantic_text_evaluated] = true }],
      ['source spans', lambda { |record| record[:source_span_ids] = ['span-1'] }],
      ['no real proof', lambda { |record| record[:real_raster_verified] = false }],
      ['no visual proof', lambda { |record| record[:visual_fidelity_verified] = false }],
      ['cleanup performed', lambda { |record| record[:cleanup_outcome] = 'removed' }],
      ['not explicit', lambda { |record| record[:explicit_request] = false }],
      ['degraded', lambda { |record| record[:degraded] = true }],
      ['missing artifact', lambda { |record| record[:artifact_evidence] = nil }],
      ['multiple entities', lambda do |record|
        record[:resulting_entity_ids] = [101, 102]
      end]
    ]

    mutations.each do |label, mutation|
      stats = pure_terminal_raster_stats([1])
      mutation.call(stats[:raster_delivery_records][0])
      refute session.send(:pure_terminal_page_raster?, stats, job), label
    end
  end

  def test_pure_terminal_page_raster_rejects_nonempty_or_missing_empty_ledgers
    load_runner_library
    session = SketchupBatchImport::RealHostSession.new
    job = { :import_mode => 'raster', :text_mode => :labels, :pages => [1] }
    empty_ledgers = [
      :text_source_span_ids, :text_attempts, :page_text_delivery_records,
      :source_glyph_physical_deliveries, :fallback_transitions,
      :page_representation_fallbacks, :inline_image_page_raster_fallbacks,
      :empty_page_source_inspections
    ]

    empty_ledgers.each do |key|
      nonempty = pure_terminal_raster_stats([1])
      nonempty[key] = [{ :unexpected => true }]
      refute session.send(:pure_terminal_page_raster?, nonempty, job),
             "nonempty #{key}"

      missing = pure_terminal_raster_stats([1])
      missing.delete(key)
      refute session.send(:pure_terminal_page_raster?, missing, job),
             "missing #{key}"
    end

    fallback = pure_terminal_raster_stats([1])
    fallback[:raster_fallback_used] = true
    refute session.send(:pure_terminal_page_raster?, fallback, job),
           'raster fallback marker'
  end

  def test_pure_raster_batch_path_defers_texture_proof_until_final_reopen
    assert_includes source, ':texture_proof => !pure_terminal_page_raster'
    assert_includes source, "'host_heal_required' => host_heal_required"
    assert_includes source, 'verify_lightweight_reopen_continuity!('
    assert_includes source, 'stats, reopened_owned_manifest, requested_mode, job[:pages]'
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
    assert_equal true, opts[:resumable]
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
                    "'inline_image_page_raster_fallbacks' =>"
    assert_includes source,
                    "'inline_images_detected' => stats[:inline_images_detected].to_i"
    assert_includes source,
                    "'text_renderers' => Array(stats[:text_renderers])"
    assert_includes source,
                    "'raster_fallback_used' => stats[:raster_fallback_used] == true"
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
    assert_includes source, "'stabilized_owned_entities'"
    assert_includes source,
                    'SketchupHostEvidence.verify_host_heal_preservation!'
    assert_includes source, "'reopen_evidence_snapshot_started'"
    assert_includes source, "'reopen_evidence_snapshot_completed'"
    assert_equal 4, source.scan(':compact => true').length,
                 'baseline, pre-heal, stabilized, and reopen must use compact physical partitions'
  end

  def test_labels_visual_equivalent_profile_uses_authoritative_reopened_ownership
    load_runner_library
    session = SketchupBatchImport::RealHostSession.new
    job = { :labels_visual_equivalent_acceptance => true }
    stats = { :sentinel => 'stats' }
    reopened = [{ 'sentinel' => 'reopened-owned' }]
    census = { 'schema' => 'bcs.labels_visual_equivalent_acceptance/1.0' }
    received = nil

    if session.respond_to?(:verify_labels_visual_equivalent_profile!, true) &&
       SketchupHostEvidence.respond_to?(:verify_labels_visual_equivalent_acceptance!)
      verifier = lambda do |actual_stats, actual_reopened|
        received = [actual_stats, actual_reopened]
        census
      end
      result = SketchupHostEvidence.stub(
        :verify_labels_visual_equivalent_acceptance!, verifier
      ) do
        session.send(
          :verify_labels_visual_equivalent_profile!, job, stats, reopened
        )
      end
    end

    assert_equal census, result
    assert_equal [stats, reopened], received
    assert_includes source,
                    "manifest_payload['labels_visual_equivalent_acceptance'] = true"
    assert_includes source, "'labels_visual_equivalent_census' =>"
    assert_includes source,
                    "manifest_payload['reopened_owned_entities'] = reopened_owned_manifest"
  end

  def test_runner_hashes_the_source_tree_before_load_and_after_import
    before = source.index('source_tree_sha256_before_load =')
    plugin_load = source.index("load File.join(plugin_root")
    pipeline = source.index('stats = importer.run_pipeline(')
    after = source.index('source_tree_sha256_after_import =')

    refute_nil before
    refute_nil plugin_load
    refute_nil pipeline
    refute_nil after
    assert_operator before, :<, plugin_load
    assert_operator pipeline, :<, after
    assert_includes source,
                    "'source_tree_sha256_before_load' =>"
    assert_includes source,
                    "'source_tree_sha256_after_import' =>"
    assert_includes source, ':source_tree_sha256_before_load =>'
    assert_includes source, ':source_tree_sha256_after_import =>'
  end

  def test_pipeline_binds_report_to_immutable_input_and_records_salvage_lineage
    assert_includes importer_source, 'source_input_path = path'
    assert_includes importer_source, 'record_source_lineage!('
    assert_includes importer_source,
                    'finalize_import_diagnostics!(source_input_path, opts, stats)'
    assert_includes importer_source,
                    'progress_callback: opts[:progress_callback]'
  end

  def test_pipeline_reports_and_times_every_post_build_phase
    assert_includes importer_source, 'report_pipeline_progress('
    %w[
      post_build_commit_started
      post_build_commit_completed
      post_commit_cleanup_started
      post_commit_cleanup_completed
      entity_diff_started
      entity_diff_completed
      view_fit_started
      view_fit_completed
      diagnostics_started
      diagnostics_completed
      post_build_completed
    ].each do |phase|
      assert_includes importer_source, "'#{phase}'"
    end
    %w[
      commit_ms
      post_commit_cleanup_ms
      entity_diff_ms
      view_fit_ms
      diagnostics_ms
      post_build_ms
    ].each do |metric|
      assert_includes importer_source, "[:#{metric}]"
    end
  end


  private

  def pure_terminal_raster_stats(pages)
    records = pages.map do |page|
      {
        :page => page,
        :source_span_ids => [],
        :requested_mode => :raster,
        :delivered_mode => :raster,
        :created_entity_type => 'raster_image',
        :delivery_scope => :page_raster,
        :delivery_basis => 'explicit_full_page_raster',
        :full_page_raster_request => true,
        :semantic_text_evaluated => false,
        :real_raster_verified => true,
        :visual_fidelity_verified => true,
        :cleanup_outcome => 'not_required',
        :explicit_request => true,
        :degraded => false,
        :artifact_evidence => {},
        :resulting_entity_ids => [100 + page]
      }
    end
    {
      :text_mode => :raster,
      :text => 0,
      :selected_pages => pages,
      :text_source_span_ids => [],
      :text_attempts => [],
      :page_text_delivery_records => [],
      :source_glyph_physical_deliveries => [],
      :fallback_transitions => [],
      :page_representation_fallbacks => [],
      :inline_image_page_raster_fallbacks => [],
      :empty_page_source_inspections => [],
      :raster_fallback_used => false,
      :raster_delivery_records => records,
      :terminal_text_delivery_records => Marshal.load(Marshal.dump(records))
    }
  end

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
