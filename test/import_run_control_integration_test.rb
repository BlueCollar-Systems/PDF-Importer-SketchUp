#!/usr/bin/env ruby

require 'minitest/autorun'

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

    commit = MAIN[/post_build_commit_started.*?model\.commit_operation/m]
    refute_nil commit
    assert_includes commit, "run_control_checkpoint!(opts, :pre_commit"
    assert_operator commit.index('run_control_checkpoint!'), :<,
                    commit.index('verify_cached_source_pdf_bindings!')
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
end
