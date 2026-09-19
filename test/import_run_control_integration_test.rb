#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'digest'

class ImportRunControlIntegrationTest < Minitest::Test
  MAIN = File.read(File.expand_path(
    '../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__
  ))

  def test_main_forwards_controller_to_geometry_and_3d_renderer
    builder = MAIN[/builder = GeometryBuilder\.new.*?builder\.build/m]
    refute_nil builder
    assert_includes builder, 'run_controller: opts[:run_controller]'

    calls = MAIN.scan(/Svg3DTextRenderer\.render_svg\(.*?\n\s*\)/m)
    assert_operator calls.length, :>=, 2
    calls.each do |call|
      assert_includes call, ':run_controller => opts[:run_controller]'
    end
  end

  def test_item_loop_and_verified_commit_have_safe_checkpoints
    item_loop = MAIN[/Array\(text_items\)\.each_with_index.*?item_delivery_ms/m]
    refute_nil item_loop
    assert_includes item_loop, 'run_control_checkpoint!('
    assert_operator item_loop.index('run_control_checkpoint!('), :<,
                    item_loop.index('complete_item_representation_ladder!')

    commit = MAIN[/post_build_commit_started.*?commit_includes_source_binding_verification/m]
    refute_nil commit
    assert_includes commit, "run_control_checkpoint!(opts, :pre_commit"
    assert_operator commit.index('run_control_checkpoint!'), :<,
                    commit.index('verify_cached_source_pdf_bindings!')
    assert_includes commit, ':source_verify_ms'
    assert_includes commit, ':page_certify_ms'
    assert_includes commit, ':commit_operation_ms'
    assert_operator commit.index('model.commit_operation'), :<,
                    commit.index(':commit_operation_ms')
  end

  def test_pipeline_abort_remains_the_partial_page_cleanup_boundary
    start = MAIN.rindex('rescue ImportRunControl::ImportCancelled')
    refute_nil start
    rescue_block = MAIN[start, 700]
    refute_nil rescue_block
    assert_includes rescue_block, 'abort_open_operation!'
    assert_includes rescue_block, 'raise'
  end

  def test_public_pipeline_routes_opted_in_editable_runs_through_page_orchestrator
    pipeline_start = MAIN[/def self\.run_pipeline\(model, path, opts\).*?Logger\.reset/m]
    refute_nil pipeline_start
    assert_includes pipeline_start, 'run_resumable_pipeline(model, path, opts)'
    assert_includes pipeline_start, 'opts[:resumable_page_call]'

    resumable = MAIN[/def self\.run_resumable_pipeline.*?def self\.run_pipeline/m]
    refute_nil resumable
    assert_includes resumable, 'ImportRunControl::PageOrchestrator.new'
    assert_includes resumable, 'page_opts[:resumable_page_call] = true'
    assert_includes resumable, ':page_certifier'
  end

  def test_page_offset_and_certification_are_inside_the_page_transaction
    assert_includes MAIN, 'running_y_offset = opts[:initial_y_offset].to_f'
    loop_setup = MAIN[
      /running_y_offset = opts\[:initial_y_offset\]\.to_f.*?pages\.each_with_index/m
    ]
    refute_nil loop_setup
    assert_includes loop_setup, 'page_group_for_certification = nil'
    pipeline = MAIN[/def self\.run_pipeline\(model, path, opts\).*\z/m]
    refute_nil pipeline
    page_end = pipeline[/running_y_offset \+= page_stack_step.*?model\.commit_operation/m]
    refute_nil page_end
    assert_includes page_end, 'opts[:page_certifier].call'
    certifier_index = page_end.index('opts[:page_certifier].call')
    commit_index = page_end.index('model.commit_operation')
    refute_nil certifier_index
    refute_nil commit_index
    assert_operator certifier_index, :<, commit_index
  end

  def test_interactive_import_uses_resumable_entrypoint_and_reports_cancel
    import_body = MAIN[/def self\.import_pdf\b.*?def self\.import_pdf_safe/m]
    refute_nil import_body
    assert_includes import_body, 'run_resumable_pipeline(model, path, opts)'
    assert_includes import_body, 'ReportDialog.announce_cancelled(stats)'
  end

  def test_exact_page_complexity_is_checked_before_expensive_build
    pipeline = MAIN[/def self\.run_pipeline\(model, path, opts\).*\z/m]
    refute_nil pipeline
    page_work = pipeline[/paths\.length\} paths.*?page_data = PrimitiveExtractor\.extract/m]
    refute_nil page_work
    assessment = page_work.index('confirm_page_complexity!(')
    build = page_work.index('page_data = PrimitiveExtractor.extract')
    refute_nil assessment
    refute_nil build
    assert_operator assessment, :<, build
    assert_includes pipeline, 'run_control_checkpoint!('
    assert_includes pipeline, ':page_parse'
  end

  def test_resumable_pages_retain_real_normalization_lineage
    with_lineage_pipeline(true) do |rows, source, prepared, note|
      assert_equal 2, rows.length
      rows.each do |stats|
        lineage = stats[:source_lineage]
        assert_equal Digest::SHA256.file(source).hexdigest, lineage[:immutable_pdf_sha256]
        assert_equal Digest::SHA256.file(prepared).hexdigest, lineage[:normalized_pdf_sha256]
        refute_equal lineage[:immutable_pdf_sha256], lineage[:normalized_pdf_sha256]
        assert_equal note, lineage[:salvage_note]
        assert_equal note, stats[:salvage_note]
      end
    end
  end

  def test_resumable_unchanged_source_does_not_invent_a_salvage_note
    with_lineage_pipeline(false) do |rows, source, _prepared, _note|
      assert_equal 2, rows.length
      rows.each do |stats|
        lineage = stats[:source_lineage]
        assert_equal source, lineage[:normalized_pdf_path]
        assert_equal lineage[:immutable_pdf_sha256], lineage[:normalized_pdf_sha256]
        assert_nil lineage[:salvage_note]
        assert_nil stats[:salvage_note]
      end
    end
  end

  # Execute the real resumable handoff, normalization branch and lineage writer.
  # Geometry/host orchestration is replaced at its boundary; no CAD work is
  # necessary to reproduce the lost note between these production methods.
  def with_lineage_pipeline(normalized)
    Dir.mktmpdir('resumable-lineage') do |dir|
      source = File.join(dir, 'source.pdf')
      prepared = normalized ? File.join(dir, 'prepared.pdf') : source
      File.binwrite(source, '%PDF-fictional-original')
      File.binwrite(prepared, '%PDF-fictional-normalized') if normalized
      note = normalized ? 'visible annotation appearances normalized as vector page content' : nil
      scope = Module.new
      scope.module_eval(<<-'RUBY')
        module Logger
          def self.reset; end
          def self.info(*); end
          def self.flush_log; end
          def self.log_path; nil; end
        end
        class PDFParser
          def initialize(*); end
          def parse; end
          def page_count; 2; end
          def release; end
        end
        module PdfSalvage
          class << self
            attr_accessor :result
            def prepare_if_needed(*); result; end
            def cleanup(*); end
          end
        end
        module ImportRunControl
          JOURNAL_SCHEMA = 'test'
          def self.identity_for(*); {}; end
          class Controller
            def initialize(*); end
          end
          class PageOrchestrator
            def initialize(options); @options = options; end
            def run
              rows = @options[:pages].map do |page|
                @options[:runner].call(page, 0, nil)[:stats]
              end
              {:stats => rows.last.merge(:observed_pages => rows)}
            end
          end
        end
        def self.resumable_import?(*); true; end
        def self.report_pipeline_progress(*); end
        def self.finalize_import_diagnostics!(*); end
      RUBY
      scope.const_get(:PdfSalvage).result = [prepared, note]
      outer = MAIN[/    def self\.run_resumable_pipeline.*?(?=    def self\.create_resumable_page_group!)/m]
      lineage = MAIN[/    def self\.record_source_lineage!.*?(?=    def self\.finalize_import_diagnostics!)/m]
      preparation = MAIN[/      salvage_note = nil\n      if opts\[:prepared_parser\].*?(?=      if parser\.page_count == 0)/m]
      refute_nil outer
      refute_nil lineage
      refute_nil preparation
      scope.module_eval(outer + lineage, __FILE__, __LINE__)
      scope.module_eval("def self.run_pipeline(model, path, opts)\n" \
        "source_path = path\n" + preparation +
        "stats = {}\nrecord_source_lineage!(stats, source_path, path, salvage_note, opts)\n" \
        "stats[:next_y_offset] = 0\nstats\nend", __FILE__, __LINE__)
      result = scope.run_resumable_pipeline(nil, source,
        :pages => [1, 2], :text_mode => :text3d, :group_per_page => true,
        :cancel_probe => lambda { false }, :status_sink => lambda { |_| })
      yield result[:observed_pages], source, prepared, note
    end
  end
end
