# Non-resumable modes must retain the same Escape cancellation contract.
# Fake host only: no SketchUp process, renderer, user PDF or model is opened.
# Ruby 2.2-compatible behavioral regressions.
require 'minitest/autorun'
require 'minitest/mock'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class NonResumableImportCancelTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  IRC = IMP::ImportRunControl
  DIALOG = IMP::ImportDialog
  MAIN_RB = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__)

  def assert_non_resumable_cancel(raw)
    probe_calls = 0
    opts = DIALOG.send(:build_opts, raw.merge(:pages => '1'))
    opts[:cancel_probe] = lambda { probe_calls += 1; true }
    opts[:status_sink] = lambda { |_| }
    refute IMP.resumable_import?(opts)
    observed = nil
    cancelled = nil
    result = nil
    # This boundary replaces the expensive host build with its real checkpoint.
    # The public wrapper must equip it with a controller before construction.
    pipeline = lambda do |_model, _path, inner|
      observed = inner
      begin
        IMP.run_control_checkpoint!(inner, :page, :page => 1, :completed => 0, :total => 1)
      rescue IRC::ImportCancelled => error
        cancelled = error
        raise
      end
      {:pages => 1}
    end
    IMP.stub(:confirm_large_pdf_once!, true) do
      IMP.stub(:run_pipeline, pipeline) do
        result = IMP.run_resumable_pipeline(Object.new, 'fictional.pdf', opts)
      end
    end
    assert_equal opts[:text_mode], observed[:text_mode], 'cancellation cannot switch the requested text mode'
    assert_equal opts[:force_raster], observed[:force_raster], 'cancellation cannot switch full-page representation'
    assert_instance_of IRC::ImportCancelled, cancelled,
                       'Escape must reach the pipeline when this mode is non-resumable'
    assert_equal 1, probe_calls
    assert_equal true, result[:cancelled]
    assert_equal 'cancelled', result[:result_status]
    assert_equal false, result[:resume_supported]
    assert_empty result[:retained_pages]
    assert_nil result[:next_page]
    assert_equal opts[:text_mode], result[:text_mode]
    assert_equal opts[:force_raster] ? :raster : opts[:text_mode],
                 observed[:run_controller].requested_mode
  end

  def test_import_text_no_still_has_escape_controller
    assert_non_resumable_cancel(:import_mode => 'auto', :import_text => 'No', :text_mode => '3D Text')
  end

  def test_requested_item_raster_still_has_escape_controller
    assert_non_resumable_cancel(:import_mode => 'auto', :import_text => 'Yes', :text_mode => 'Raster')
  end

  def test_requested_full_page_raster_still_has_escape_controller
    assert_non_resumable_cancel(:import_mode => 'raster', :import_text => 'No', :text_mode => 'Raster')
  end

  def test_public_pipeline_routes_non_resumable_modes_through_controller_wrapper
    ['auto', 'raster'].each do |mode|
      opts = DIALOG.send(:build_opts, :import_mode => mode, :import_text => 'No')
      expected = {:cancelled => true, :result_status => 'cancelled'}
      calls = 0
      wrapper = lambda do |_model, path, actual|
        calls += 1
        assert_equal 'fictional.pdf', path
        assert_same opts, actual
        expected
      end
      IMP.stub(:run_resumable_pipeline, wrapper) do
        assert_same expected, IMP.run_pipeline(Object.new, 'fictional.pdf', opts)
      end
      assert_equal 1, calls
    end
  end

  def test_existing_controller_is_preserved_without_a_resume_journal
    opts = DIALOG.send(:build_opts, :import_mode => 'auto', :import_text => 'No')
    controller = IRC::Controller.new(:pages => [], :requested_mode => :none,
      :cancel_probe => lambda { true })
    opts[:run_controller] = controller
    opts[:cancel_probe] = lambda { flunk 'caller-supplied controller was replaced' }
    pipeline = lambda do |_model, _path, inner|
      assert_same controller, inner[:run_controller]
      IMP.run_control_checkpoint!(inner, :page, :page => 1)
    end
    IMP.stub(:confirm_large_pdf_once!, true) do
      IMP.stub(:run_pipeline, pipeline) do
        result = IMP.run_resumable_pipeline(Object.new, 'fictional.pdf', opts)
        assert_equal true, result[:cancelled]
        assert_equal false, result[:resume_supported]
      end
    end
  end

  def test_failed_rollback_cannot_be_reported_as_cancellation
    opts = DIALOG.send(:build_opts, :import_mode => 'raster', :import_text => 'No')
    failure = IRC::RollbackFailure.new('host did not confirm rollback')
    IMP.stub(:confirm_large_pdf_once!, true) do
      IMP.stub(:run_pipeline, lambda { |*_| raise failure }) do
        assert_same failure, assert_raises(IRC::RollbackFailure) {
          IMP.run_resumable_pipeline(Object.new, 'fictional.pdf', opts)
        }
      end
    end
  end

  class FakeEntities
    attr_reader :items
    def initialize; @items = [:existing_geometry]; end
    def to_a; @items.dup; end
  end

  class FakeModel
    attr_reader :active_entities, :commits, :aborts
    def initialize
      @active_entities = FakeEntities.new
      @commits = 0
      @aborts = 0
    end
    def start_operation(*_); @before = @active_entities.items.dup; true; end
    def commit_operation; @commits += 1; true; end
    def abort_operation
      @aborts += 1
      @active_entities.items.replace(@before)
      true
    end
  end

  class FakeParser
    def initialize(_path); end
    def parse; true; end
    def page_count; 1; end
    def page_data(_page); {:media_box => [0, 0, 72, 72], :rotation => 0}; end
    def release; true; end
  end

  def raster_scope
    scope = Module.new
    geom = Module.new
    geom.const_set(:BoundingBox, Class.new)
    host = Module.new
    host.define_singleton_method(:status_text=) { |_| }
    scope.const_set(:Geom, geom)
    scope.const_set(:Sketchup, host)
    scope.const_set(:PDFParser, FakeParser)
    scope.const_set(:PageTransform, IMP::PageTransform)
    scope.const_set(:ImportRunControl, IRC)
    scope.const_set(:RepresentationFidelity, IMP::RepresentationFidelity)
    scope.const_set(:Logger, IMP::Logger)
    [:reset_ownership_bookkeeping!, :record_source_lineage!, :record_raster_performance!,
     :record_text_renderer, :add_page_fit_bounds, :cleanup_item_raster_page_cache!,
     :verify_cached_source_pdf_bindings!, :apply_top_view_fit, :finalize_import_diagnostics!].each do |name|
      scope.define_singleton_method(name) { |*_| true }
    end
    scope.define_singleton_method(:normalized_requested_pages) { |spec, count| IMP::PageSelection.resolve(spec, count) }
    scope.define_singleton_method(:normalize_page_arrangement) { |_| :spread }
    scope.define_singleton_method(:normalize_page_gap_ratio) { |_| 0.2 }
    scope.define_singleton_method(:new_import_session_id) { 'fictional-cancel-test' }
    scope.define_singleton_method(:raster_display_dimensions) { |*_| [72, 72] }
    scope.define_singleton_method(:page_stack_step) { |*_| 1.2 }
    # A fresh import into this empty fake model starts at the origin.
    scope.define_singleton_method(:fresh_import_start_offset) { |*_| 0.0 }
    scope.define_singleton_method(:import_contract_ready?) { |_| true }
    scope.define_singleton_method(:start_import_operation!) { |model, name| IMP.start_import_operation!(model, name) }
    scope.define_singleton_method(:abort_open_operation!) { |*args| IMP.abort_open_operation!(*args) }
    scope.define_singleton_method(:preserve_terminal_import_error) { |error, &block| IMP.preserve_terminal_import_error(error, &block) }
    scope.define_singleton_method(:run_control_checkpoint!) { |*args| IMP.run_control_checkpoint!(*args) }
    scope.define_singleton_method(:verified_raster_entity!) do |model, *_|
      model.active_entities.items << :new_raster_image
      {:entity_id => 2, :artifact_evidence => {}, :performance => {}}
    end
    source = File.read(MAIN_RB)[/^    def self\.run_forced_raster_pipeline\(.*?^    end\n/m]
    raise 'Raster pipeline source not found' unless source
    scope.module_eval(source, MAIN_RB)
    scope
  end

  def test_full_page_raster_checkpoint_cancels_before_creation_and_rolls_back
    assert_raster_transaction_cancel(1)
  end

  def test_full_page_raster_cancel_after_creation_rolls_back_image
    assert_raster_transaction_cancel(2)
  end

  def test_full_page_raster_cancel_at_precommit_rolls_back_image
    assert_raster_transaction_cancel(3)
  end

  def assert_raster_transaction_cancel(cancel_at)
    model = FakeModel.new
    probes = 0
    controller = IRC::Controller.new(:pages => [1], :requested_mode => :raster,
      :cancel_probe => lambda { probes += 1; probes >= cancel_at }, :status_sink => lambda { |_| })
    opts = DIALOG.send(:build_opts, :import_mode => 'raster', :pages => '1',
      :import_text => 'No', :text_mode => 'Raster')
    opts[:run_controller] = controller
    cancelled = nil
    begin
      raster_scope.run_forced_raster_pipeline(model, 'fictional.pdf', opts)
    rescue IRC::ImportCancelled => error
      cancelled = error
    end
    assert_instance_of IRC::ImportCancelled, cancelled,
                       'a supplied controller must be checked before creating a Raster page'
    assert_equal cancel_at, probes
    assert_equal [:existing_geometry], model.active_entities.to_a
    assert_equal 0, model.commits
    assert_equal 1, model.aborts
    assert_equal :none, opts[:text_mode]
    assert_equal true, opts[:force_raster]
  end
end
