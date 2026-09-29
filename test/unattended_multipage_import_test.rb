#!/usr/bin/env ruby
# test/unattended_multipage_import_test.rb
#
# Owner rule (2026-09-28): a multi-page import runs unattended. No per-page
# OK/confirm modal by default (per-page review is an opt-in), one page that
# fails is logged and skipped while the rest import, and the single
# end-of-import summary names raster fallbacks (with the reason) and any
# failed pages.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

unless defined?(UI) && UI.respond_to?(:messagebox)
  module UI
    def self.messagebox(*_args); 0; end
  end
end
MB_OKCANCEL = 1 unless defined?(MB_OKCANCEL)
IDOK = 1 unless defined?(IDOK)

class UnattendedMultipageImportTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  IRC = IMP::ImportRunControl
  R = IMP::ReportDialog
  MAIN_RB = File.expand_path(
    '../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__
  )

  class FakeController
    attr_reader :retained_pages
    def initialize(work_class)
      @work_class = work_class
      @retained_pages = []
    end

    def assess(counts)
      { :class => @work_class, :work_units => 9_000, :mode_weight => 4,
        :counts => counts }
    end

    def progress(*_args); {}; end
  end

  # ---- per-page prompt is gone by default --------------------------------

  def with_messagebox_recorder
    calls = []
    UI.stub(:messagebox, lambda { |*args| calls << args; IDOK }) do
      yield calls
    end
  end

  def test_large_page_does_not_open_a_modal_by_default
    with_messagebox_recorder do |calls|
      opts = { :run_controller => FakeController.new(:very_large) }
      assessment = IMP.confirm_page_complexity!(opts, 3, 76_403, 900)
      assert_equal :very_large, assessment[:class]
      assert_empty calls, 'unattended import must not stop on a per-page modal'
    end
  end

  def test_per_page_review_is_an_explicit_opt_in
    with_messagebox_recorder do |calls|
      opts = { :run_controller => FakeController.new(:large),
               :per_page_review => true }
      IMP::BatchHostPolicy.stub(:prompt_allowed?, true) do
        IMP.confirm_page_complexity!(opts, 1, 5_000, 10)
      end
      refute_empty calls, 'opt-in per-page review still asks'
    end
  end

  def test_host_callback_is_still_honored
    seen = []
    opts = { :run_controller => FakeController.new(:large),
             :complexity_confirm => lambda { |a, _m| seen << a[:class]; true } }
    IMP.confirm_page_complexity!(opts, 1, 5_000, 10)
    assert_equal [:large], seen
  end

  def test_import_dialog_defaults_per_page_review_off
    refute IMP::ImportDialog.per_page_review_preference?
  end

  def test_per_page_review_does_not_change_resume_identity
    assert_includes IRC::TRANSIENT_OPTION_KEYS, :per_page_review
    assert_includes IRC::TRANSIENT_OPTION_KEYS, :stop_on_page_error
  end

  def test_large_pdf_question_is_asked_once_per_import_not_per_page
    main = File.read(MAIN_RB)
    resumable = main[/def self\.run_resumable_pipeline.*?def self\.run_pipeline/m]
    refute_nil resumable
    assert_includes resumable, 'confirm_large_pdf_once!(source_path)'
    assert_includes resumable, 'page_opts[:large_pdf_confirmed] = true'
    pipeline = main[/def self\.run_pipeline\(model, path, opts\).*?PdfSalvage\.prepare_if_needed/m]
    refute_nil pipeline
    assert_includes pipeline, 'opts[:large_pdf_confirmed] == true'
  end

  # ---- one failed page does not stop the rest ----------------------------

  class AttrObject
    def initialize; @attributes = {}; end
    def set_attribute(dict, key, value); @attributes[[dict, key]] = value; end
    def get_attribute(dict, key, default = nil)
      @attributes.fetch([dict, key], default)
    end
  end

  class Leaf
    Point = Struct.new(:x, :y, :z)
    Vertex = Struct.new(:position)
    attr_reader :persistent_id
    def initialize(id)
      @persistent_id = id
      @start = Vertex.new(Point.new(0.0, 0.0, 0.0))
      @end = Vertex.new(Point.new(1.0, 0.0, 0.0))
    end
    def valid?; true; end
    def typename; 'Edge'; end
    def start; @start; end
    def end; @end; end
  end

  class Entities
    def initialize(items = []); @items = items; end
    def to_a; @items.dup; end
    def add(item); @items << item; item; end
  end

  class Group < AttrObject
    attr_accessor :name
    attr_reader :persistent_id, :entities
    def initialize(id, page)
      super()
      @persistent_id = id
      @name = "PDF Page #{page}"
      @entities = Entities.new([Leaf.new(id * 10)])
    end
    def valid?; true; end
    def typename; 'Group'; end
  end

  class Model < AttrObject
    attr_reader :active_entities
    def initialize; super; @active_entities = Entities.new; end
  end

  NoninteractiveError = Class.new(StandardError)

  def controller(model)
    IRC::Controller.new(
      :model => model, :pages => [1, 2, 3], :requested_mode => :text3d,
      :identity => { :pdf_sha256 => 'a' * 64, :options_sha256 => 'b' * 64,
                     :importer_sha256 => 'c' * 64, :package_sha256 => 'd' * 64,
                     :source_tree_sha256 => 'e' * 64 },
      :clock => lambda { 0.0 }
    )
  end

  def runner(model, calls, failing = {})
    lambda do |page, offset, certify|
      calls << [page, offset]
      raise failing[page] if failing[page] && !failing[page].is_a?(Array)
      group = model.active_entities.add(Group.new(100 + page, page))
      stats = { :pages => 1, :edges => page }
      certify.call(group, offset + 10.0, stats)
      raise failing[page][0] if failing[page].is_a?(Array)
      { :stats => stats, :next_y_offset => offset + 10.0 }
    end
  end

  def orchestrate(model, run, continue = true)
    IRC::PageOrchestrator.new(
      :model => model, :controller => controller(model),
      :pages => [1, 2, 3], :runner => run,
      :continue_on_page_error => continue
    ).run
  end

  def test_failed_page_is_recorded_and_remaining_pages_import
    model = Model.new
    calls = []
    result = orchestrate(model, runner(model, calls,
      2 => IMP::RepresentationFidelity::ContractError.new('Page 2: boom')))
    refute result[:cancelled]
    assert_equal [1, 3], result[:retained_pages]
    assert_equal [[1, 0.0], [2, 10.0], [3, 10.0]], calls
    assert_equal 1, result[:failed_pages].length
    failure = result[:failed_pages].first
    assert_equal 2, failure[:page]
    assert_match(/boom/, failure[:message])
    assert_equal 4, result[:stats][:edges]
  end

  def test_failed_page_is_retried_on_resume
    model = Model.new
    orchestrate(model, runner(model, [], 2 => RuntimeError.new('transient')))
    calls = []
    resumed = orchestrate(model, runner(model, calls))
    assert_equal [2], calls.map { |c| c[0] }
    assert_equal [1, 2, 3], resumed[:retained_pages]
    assert_empty resumed[:failed_pages]
  end

  def test_bare_orchestrator_stays_strict
    model = Model.new
    assert_raises(RuntimeError) do
      orchestrate(model, runner(model, [], 2 => RuntimeError.new('x')), false)
    end
  end

  def test_every_page_failing_raises_the_real_error
    model = Model.new
    err = RuntimeError.new('all bad')
    error = assert_raises(RuntimeError) do
      orchestrate(model, runner(model, [], 1 => err, 2 => err, 3 => err))
    end
    assert_equal 'all bad', error.message
  end

  def test_batch_policy_stop_and_post_certify_errors_are_not_swallowed
    model = Model.new
    assert_raises(NoninteractiveError) do
      orchestrate(model, runner(model, [], 2 => NoninteractiveError.new('batch')))
    end
    model = Model.new
    assert_raises(RuntimeError) do
      orchestrate(model, runner(model, [], 2 => [RuntimeError.new('late')]))
    end
  end

  def test_cancel_still_propagates_as_cancel
    model = Model.new
    cancel = IRC::ImportCancelled.new([1], 2, {})
    result = orchestrate(model, runner(model, [], 2 => cancel))
    assert result[:cancelled]
    assert_equal [1], result[:retained_pages]
  end

  # ---- single end-of-import summary --------------------------------------

  def summary_stats
    {
      :pages => 5, :edges => 1234, :text => 50, :elapsed_seconds => 42.0,
      :page_representation_fallbacks => [
        { :page => 5, :delivered_mode => :raster, :explicit_request => false,
          :reason_code => :inline_image_paint_order_requires_terminal_page_raster },
        { 'page' => 6, 'delivered_mode' => 'raster',
          'reason_code' => 'inline_image_paint_order_requires_terminal_page_raster' }
      ],
      :failed_pages => [{ :page => 4, :error_class => 'RuntimeError',
                          :message => 'Page 4: renderer failed' }],
      :complexity_notices => [{ :page => 1 }, { :page => 2 }]
    }
  end

  def test_completion_status_lists_raster_pages_and_failures
    line = R.completion_status(summary_stats)
    assert_includes line, 'PDF import finished with problems'
    assert_includes line, '5 pages'
    assert_includes line, 'Raster image pages: 5 (inline images), 6 (inline images).'
    assert_includes line, 'Failed page skipped: 4.'
    assert_includes line, 'Import Health'
  end

  def test_clean_completion_status_is_unchanged_in_spirit
    line = R.completion_status(:pages => 2, :edges => 10, :text => 3)
    assert_match(/\APDF import complete — 2 pages, 10 edges, 3 text\./, line)
    refute_includes line, 'Raster'
    refute_includes line, 'Failed'
  end

  def test_explicit_raster_request_is_not_reported_as_fallback
    stats = { :page_representation_fallbacks => [
      { :page => 1, :delivered_mode => :raster, :explicit_request => true }
    ] }
    assert_empty R.raster_fallback_pages(stats)
  end

  def test_summary_explains_raster_reason_failures_and_heavy_pages
    summary = R.build_summary(summary_stats)
    assert_includes summary, '2 page(s) were imported as a raster image'
    assert_includes summary, 'Page 5: the page contains inline images'
    assert_includes summary, '1 page(s) failed and were skipped'
    assert_includes summary, 'Page 4: Page 4: renderer failed'
    assert_includes summary, 'Large page(s) imported without stopping for confirmation: 1-2.'
  end
end
