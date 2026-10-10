#!/usr/bin/env ruby
# test/unattended_multipage_import_test.rb
#
# Owner rule (2026-09-28): a multi-page import runs unattended. No per-page
# OK/confirm modal, one page that
# fails is logged and skipped while the rest import, and the single
# end-of-import summary names raster fallbacks (with the reason) and any
# failed pages.

require 'minitest/autorun'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

unless defined?(UI) && UI.respond_to?(:messagebox)
  module UI
    def self.messagebox(*_args); 0; end
  end
end
unless UI.respond_to?(:inputbox)
  module UI
    def self.inputbox(*_args); nil; end
  end
end
MB_OKCANCEL = 1 unless defined?(MB_OKCANCEL)
IDOK = 1 unless defined?(IDOK)
MB_YESNO = 4 unless defined?(MB_YESNO)
IDYES = 6 unless defined?(IDYES)

# Minimal host stand-ins for driving the real non-resumable and Raster
# pipelines up to an Esc checkpoint.
unless defined?(Sketchup) && Sketchup.respond_to?(:status_text=)
  module Sketchup
    def self.status_text=(_text); end
    def self.active_model; nil; end
  end
end
unless defined?(Geom::BoundingBox)
  module Geom
    class BoundingBox
      def add(*_args); self; end
    end
  end
end

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

  def test_host_callback_is_still_honored
    seen = []
    opts = { :run_controller => FakeController.new(:large),
             :complexity_confirm => lambda { |a, _m| seen << a[:class]; true } }
    IMP.confirm_page_complexity!(opts, 1, 5_000, 10)
    assert_equal [:large], seen
  end

  def test_stop_on_page_error_does_not_change_resume_identity
    assert_includes IRC::TRANSIENT_OPTION_KEYS, :stop_on_page_error
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

  class TransactionModel < Model
    attr_reader :abort_count, :operation_calls
    attr_accessor :abort_result
    def initialize
      super
      @abort_count = 0
      @operation_calls = []
      @abort_result = true
    end
    def start_operation(*args)
      @operation_calls << args
      @before_operation = @active_entities.to_a
      true
    end
    def abort_operation
      @abort_count += 1
      raise @abort_result if @abort_result.is_a?(Exception)
      if @abort_result == true
        @active_entities = Entities.new(@before_operation)
      end
      @abort_result
    end
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
    assert_equal 'incomplete', result[:result_status]
    assert_equal [1, 2, 3], result[:requested_pages]
    assert_equal [1, 2, 3], result[:stats][:selected_pages]
    assert_equal result[:failed_pages], result[:stats][:failed_pages]
  end

  def test_failed_page_is_retried_on_resume
    model = Model.new
    orchestrate(model, runner(model, [], 2 => RuntimeError.new('transient')))
    calls = []
    resumed = orchestrate(model, runner(model, calls))
    assert_equal [2], calls.map { |c| c[0] }
    assert_equal [1, 2, 3], resumed[:retained_pages]
    assert_empty resumed[:failed_pages]
    assert_equal 'success', resumed[:result_status]
    assert_equal [1, 2, 3], resumed[:stats][:requested_pages]
    assert_equal [1, 2, 3], resumed[:stats][:selected_pages]
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
    assert_equal 'cancelled', result[:result_status]
    assert_equal [1, 2, 3], result[:requested_pages]
    assert_equal [1, 2, 3], result[:stats][:selected_pages]
    assert_equal [1], result[:stats][:retained_pages]
  end

  def test_normalized_request_is_preserved_without_expanding_page_journal_stats
    model = Model.new
    ctrl = controller(model)
    run = lambda do |page, offset, certify|
      group = model.active_entities.add(Group.new(100 + page, page))
      stats = { :pages => 1, :selected_pages => [page] }
      certify.call(group, offset + 10.0, stats)
      { :stats => stats, :next_y_offset => offset + 10.0 }
    end
    result = IRC::PageOrchestrator.new(
      :controller => ctrl, :pages => ['3', 1, 3, 2], :runner => run
    ).run
    assert_equal [1, 2, 3], result[:requested_pages]
    assert_equal [1, 2, 3], result[:stats][:selected_pages]
    assert_equal [2], ctrl.page_stats(2)[:selected_pages]
  end

  def test_import_operation_does_not_chain_to_a_previously_committed_page
    model = TransactionModel.new
    IMP.start_import_operation!(model, 'Import page')
    assert_equal [['Import page', true, false, false]], model.operation_calls
  end

  # Exercise the production page and outer rescue clauses together. Host
  # construction is represented by a partial group and a build exception;
  # the nested cleanup/propagation behavior is the actual main.rb source.
  def pipeline_failure_boundary
    source = File.read(MAIN_RB)
    page_rescues = source[/^      rescue ImportRunControl::RollbackFailure\n.*?(?=^      end\n      end)/m]
    outer_rescues = source[/^    rescue ImportRunControl::RollbackFailure\n      # A failed rollback.*?(?=^    end\n)/m]
    refute_nil page_rescues
    refute_nil outer_rescues
    boundary = Module.new
    boundary.const_set(:ImportRunControl, IRC)
    boundary.const_set(:RepresentationFidelity, IMP::RepresentationFidelity)
    logger = Module.new
    logger.define_singleton_method(:error) { |*_| }
    logger.define_singleton_method(:flush_log) { }
    boundary.const_set(:Logger, logger)
    boundary.define_singleton_method(:abort_open_operation!) do |*args|
      IMP.abort_open_operation!(*args)
    end
    boundary.define_singleton_method(:preserve_terminal_import_error) do |error, &block|
      IMP.preserve_terminal_import_error(error, &block)
    end
    boundary.define_singleton_method(:report_pipeline_progress) { |*_| }
    boundary.define_singleton_method(:cleanup_item_raster_page_cache!) do |opts|
      raise IMP::RepresentationFidelity::ContractError, 'cache cleanup failed' if opts[:cleanup_failure]
    end
    boundary.module_eval("def self.fail_page(model, error, cleanup_failure)\n" \
      "opts = {:preserve_prepared_parser => true, :cleanup_failure => cleanup_failure}\n" \
      "operation_open = true\npage_num = 2\nbegin\nraise error\n" +
      page_rescues + "end\n" + outer_rescues + "end\n", MAIN_RB)
    boundary
  end

  def run_with_failed_page_transaction(model, calls, error = RuntimeError.new('build failed'), cleanup_failure = false)
    boundary = pipeline_failure_boundary
    normal_runner = runner(model, calls)
    run = lambda do |page, offset, certify|
      if page == 2
        calls << [page, offset]
        IMP.start_import_operation!(model, 'Import page 2')
        model.active_entities.add(Group.new(999, page))
        boundary.fail_page(model, error, cleanup_failure)
      end
      normal_runner.call(page, offset, certify)
    end
    orchestrate(model, run)
  end

  def test_failed_or_unconfirmed_rollback_stops_without_retry_or_later_page
    [RuntimeError.new('host abort failed'), false, nil].each do |failure|
      model = TransactionModel.new
      model.abort_result = failure
      calls = []
      error = assert_raises(IRC::RollbackFailure) do
        run_with_failed_page_transaction(model, calls)
      end
      assert_match(/could not confirm rollback/, error.message)
      assert_equal [1, 2], calls.map { |call| call[0] }
      assert_equal 1, model.abort_count, 'outer rescue must not retry uncertain rollback'
      assert_equal [101, 999], model.active_entities.to_a.map(&:persistent_id)
    end
  end

  def test_confirmed_rollback_removes_partial_page_and_keeps_committed_pages
    model = TransactionModel.new
    result = run_with_failed_page_transaction(model, [])
    assert_equal [1, 3], result[:retained_pages]
    assert_equal [101, 103], model.active_entities.to_a.map(&:persistent_id)
    assert_equal 1, model.abort_count
    assert_equal 'incomplete', result[:result_status]
  end

  def test_cancel_with_failed_rollback_is_terminal_instead_of_resumable
    model = TransactionModel.new
    model.abort_result = false
    calls = []
    assert_raises(IRC::RollbackFailure) do
      run_with_failed_page_transaction(model, calls, IRC::ImportCancelled.new([1], 2, {}))
    end
    assert_equal [1, 2], calls.map { |call| call[0] }
    assert_equal 1, model.abort_count
  end

  def test_cleanup_error_cannot_hide_failed_rollback_or_start_another_page
    model = TransactionModel.new
    model.abort_result = false
    calls = []
    assert_raises(IRC::RollbackFailure) do
      run_with_failed_page_transaction(model, calls, RuntimeError.new('build failed'), true)
    end
    assert_equal [1, 2], calls.map { |call| call[0] }
    assert_equal 1, model.abort_count
  end

  def test_cleanup_error_cannot_turn_cancel_or_resume_mismatch_into_a_skipped_page
    model = TransactionModel.new
    calls = []
    cancelled = run_with_failed_page_transaction(
      model, calls, IRC::ImportCancelled.new([1], 2, {}), true
    )
    assert_equal 'cancelled', cancelled[:result_status]
    assert_equal [1, 2], calls.map { |call| call[0] }
    assert_equal [101], model.active_entities.to_a.map(&:persistent_id)
    model = TransactionModel.new
    calls = []
    mismatch = IRC::ResumeMismatch.new('retained group changed')
    error = assert_raises(IRC::ResumeMismatch) do
      run_with_failed_page_transaction(model, calls, mismatch, true)
    end
    assert_same mismatch, error
    assert_equal [1, 2], calls.map { |call| call[0] }
  end

  def test_resumable_cleanup_preserves_the_active_terminal_error
    source = File.read(MAIN_RB)
    method = source[/^    def self\.run_resumable_pipeline.*?(?=^    def self\.release_original_annotation_cache!)/m]
    ensure_body = method[/^      ensure\n(.*)(?=^      end\n    end\n)/m, 1]
    refute_nil ensure_body
    boundary = Module.new
    boundary.define_singleton_method(:preserve_terminal_import_error) do |error, &block|
      IMP.preserve_terminal_import_error(error, &block)
    end
    boundary.define_singleton_method(:release_original_annotation_cache!) do |_|
      raise IMP::RepresentationFidelity::ContractError, 'annotation cache cleanup failed'
    end
    boundary.module_eval("def self.unwind(error)\noriginal_annotation_cache = {}\n" \
      "begin\nraise error\nensure\n" + ensure_body + "end\nend\n", MAIN_RB)
    [IRC::RollbackFailure.new('rollback failed'), IRC::ResumeMismatch.new('journal changed'),
     IRC::ImportCancelled.new([1], 2, {})].each do |terminal|
      raised = assert_raises(terminal.class) { boundary.unwind(terminal) }
      assert_same terminal, raised
    end
    cleanup = assert_raises(IMP::RepresentationFidelity::ContractError) do
      boundary.unwind(RuntimeError.new('ordinary failure'))
    end
    assert_equal 'annotation cache cleanup failed', cleanup.message
  end

  # Execute the real native-import and folder-batch entrypoints with only
  # their host/UI/pipeline boundaries replaced; no SketchUp process is needed.
  def entrypoint_scope(outcomes, folder = nil, answers = [],
                       policy = IMP::BatchHostPolicy)
    calls, messages, aborts, seen_opts, events = [], [], [], [], []
    scope = Module.new
    host = Module.new
    importer = Class.new
    importer.const_set(:ImportSuccess, 0)
    importer.const_set(:ImportFail, 1)
    importer.const_set(:ImportCanceled, 2)
    host.const_set(:Importer, importer)
    host.define_singleton_method(:active_model) { Object.new }
    host.define_singleton_method(:status_text=) { |_| }
    ui = Module.new
    ui.define_singleton_method(:inputbox) { |*_| [folder] }
    ui.define_singleton_method(:messagebox) do |message, *_|
      messages << message
      events << [:ask, message]
      answers.empty? ? 6 : answers.shift
    end
    dialog = Module.new
    dialog.const_set(:MODES, {'Auto' => {}})
    dialog.define_singleton_method(:show) { |_| {} }
    dialog.define_singleton_method(:build_opts) { |opts| opts }
    logger = Module.new
    logger.define_singleton_method(:error) { |*_| }
    logger.define_singleton_method(:log_path) { nil }
    report = Module.new
    report.define_singleton_method(:announce) { |*_| }
    report.define_singleton_method(:announce_cancelled) { |*_| }
    namespace = Module.new
    namespace.const_set(:PDFVectorImporter, scope)
    scope.const_set(:BlueCollarSystems, namespace)
    scope.const_set(:Sketchup, host)
    scope.const_set(:UI, ui)
    scope.const_set(:ImportDialog, dialog)
    scope.const_set(:ImportRunControl, IRC)
    scope.const_set(:Logger, logger)
    scope.const_set(:ReportDialog, report)
    scope.const_set(:MB_YESNO, 4)
    scope.const_set(:IDYES, 6)
    scope.const_set(:BatchHostPolicy, policy)
    scope.define_singleton_method(:handle_open_gate) { |*_| false }
    scope.define_singleton_method(:import_result_status) { |stats| IMP.import_result_status(stats) }
    scope.define_singleton_method(:safe_abort_operation) { |*args| aborts << args }
    run = lambda do |_model, path, opts|
      calls << path
      seen_opts << opts
      events << [:import, File.basename(path)]
      outcome = outcomes.shift
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
    scope.define_singleton_method(:run_pipeline, &run)
    scope.define_singleton_method(:run_resumable_pipeline, &run)
    source = File.read(MAIN_RB)
    load_file = source[/^      def load_file\(.*?^      end\n/m]
    batch = source[/^    def self\.batch_import\n.*?^    end\n/m]
    helpers = %w[batch_large_pdfs batch_confirm_large_pdfs import_pdf_path].map do |name|
      source[/^    def self\.#{name}\(.*?^    end\n/m]
    end
    refute_nil load_file
    refute_nil batch
    helpers.each { |helper| refute_nil helper }
    scope.module_eval("class NativeImporter\n" + load_file + "end\n" + batch +
                      helpers.join, MAIN_RB)
    [scope, calls, messages, aborts, seen_opts, events]
  end

  def test_native_importer_reports_explicit_outcomes_and_preserves_legacy_success
    outcomes = [{:result_status => 'incomplete'}, {:cancelled => true},
      {:result_status => 'cancelled'}, {:failed_pages => [{:page => 2}]},
      {:result_status => 'success'}, {:pages => 1}, nil,
      IRC::ImportCancelled.new([1], 2, {})]
    scope, = entrypoint_scope(outcomes)
    importer = scope.const_get(:NativeImporter).new
    results = 8.times.map { importer.load_file('fixture.pdf', nil) }
    assert_equal [1, 2, 2, 1, 0, 0, 1, 2], results
  end

  def test_native_importer_does_not_retry_failed_rollback
    scope, _calls, _messages, aborts = entrypoint_scope([IRC::RollbackFailure.new('rollback failed')])
    assert_equal 1, scope.const_get(:NativeImporter).new.load_file('fixture.pdf', nil)
    assert_empty aborts
  end

  def with_batch_fixture(outcomes)
    Dir.mktmpdir('batch-outcome') do |folder|
      3.times { |index| File.binwrite(File.join(folder, "#{index}.pdf"), '%PDF-test') }
      scope, calls, messages, aborts = entrypoint_scope(outcomes, folder)
      scope.batch_import
      yield calls, messages.last, aborts
    end
  end

  # Treats any file over 20 bytes as "very large" so a fixture can be one.
  module SmallLargePolicy
    LARGE_PDF_BYTES = 20

    def self.confirm_large_pdf!(file_size_bytes)
      return true unless file_size_bytes.to_i > LARGE_PDF_BYTES
      block_given? ? yield : false
    end
  end

  def with_large_file_batch(answers, outcomes)
    Dir.mktmpdir('batch-large') do |folder|
      File.binwrite(File.join(folder, '0.pdf'), '%PDF-test')
      File.binwrite(File.join(folder, '1.pdf'), '%PDF-test' + ('x' * 60))
      File.binwrite(File.join(folder, '2.pdf'), '%PDF-test')
      scope, calls, messages, _aborts, seen_opts, events =
        entrypoint_scope(outcomes, folder, answers, SmallLargePolicy)
      scope.batch_import
      yield calls.map { |path| File.basename(path) }, messages, seen_opts, events
    end
  end

  def test_folder_batch_confirm_says_what_every_file_gets
    with_batch_fixture([{:pages => 1}, {:pages => 1}, {:pages => 1}]) do |_calls, summary, _|
      assert_includes summary, '3 imported, 0 failed, 0 cancelled, 0 skipped, 3 total'
    end
    Dir.mktmpdir('batch-confirm') do |folder|
      File.binwrite(File.join(folder, '0.pdf'), '%PDF-test')
      scope, _calls, messages = entrypoint_scope([{:pages => 1}], folder)
      scope.batch_import
      assert_equal 'Import 1 PDF(s): all pages, 3D Text, scale 1.0 (Auto)?', messages.first
    end
  end

  # One stuck file (its earlier import record no longer matches the model)
  # is counted as failed; the rest of the folder still imports.
  def test_folder_batch_continues_past_a_file_whose_resume_record_does_not_match
    mismatch = IRC::ResumeMismatch.new('page 1 has 0 retained groups; expected exactly one')
    with_batch_fixture([mismatch, {:pages => 1}, {:pages => 1}]) do |calls, summary, _|
      assert_equal 3, calls.length
      assert_includes summary, '2 imported, 1 failed, 0 cancelled'
      refute_includes summary, 'Stopped'
    end
  end

  def test_folder_batch_asks_about_large_files_once_up_front_and_skips_on_no
    with_large_file_batch([6, 7], [{:pages => 1}, {:pages => 1}]) do |calls, messages, _opts, events|
      assert_equal %w[0.pdf 2.pdf], calls
      assert_equal 3, messages.length, 'confirm, one large-file question, summary'
      assert_match(/1 PDF\(s\) in this folder are very large/, messages[1])
      assert_includes messages[1], '1.pdf'
      assert_equal [:ask, :ask], events.first(2).map(&:first),
                   'the large-file question comes before any import'
      assert_includes messages.last, '2 imported, 0 failed, 0 cancelled, 1 skipped, 3 total'
    end
  end

  def test_folder_batch_imports_confirmed_large_files_without_asking_again
    with_large_file_batch([6, 6], [{:pages => 1}, {:pages => 1}, {:pages => 1}]) do |calls, messages, seen_opts, _|
      assert_equal %w[0.pdf 1.pdf 2.pdf], calls
      assert_equal 3, messages.length
      assert_equal true, seen_opts[1][:large_pdf_confirmed]
      assert_nil seen_opts[0][:large_pdf_confirmed]
      assert_includes messages.last, '3 imported, 0 failed, 0 cancelled, 0 skipped'
    end
  end

  # ---- new imports land beside earlier ones ------------------------------

  class BoundedGroup < Group
    Box = Struct.new(:min, :max)

    def initialize(id, page, bottom, top)
      super(id, page)
      @box = Box.new(Leaf::Point.new(0.0, bottom, 0.0),
                     Leaf::Point.new(8.5, top, 0.0))
    end

    def bounds; @box; end
  end

  def test_empty_model_starts_at_the_origin_and_ignores_non_pdf_geometry
    model = Model.new
    assert_equal 0.0, IMP.import_base_y_offset(model, 11.0)
    person = model.active_entities.add(BoundedGroup.new(5, 1, 0.0, 70.0))
    person.name = 'Template person'
    assert_equal 0.0, IMP.import_base_y_offset(model, 11.0),
                 "a template's person figure must not move the drawing"
  end

  def test_model_with_an_earlier_pdf_page_starts_above_it
    model = Model.new
    group = model.active_entities.add(BoundedGroup.new(7, 1, 0.0, 13.2))
    group.name = 'Renamed by the user'
    IMP.mark_pdf_page_group!(group)
    offset = IMP.import_base_y_offset(model, 11.0)
    assert_operator offset, :>, 13.2
    assert_in_delta 13.2 + 11.0 * 0.2, offset, 1e-9
    # Older imports are found by their "PDF Page N" name.
    legacy = Model.new
    legacy.active_entities.add(BoundedGroup.new(8, 3, 0.0, 30.0))
    assert_in_delta 30.0 + 2.2, IMP.import_base_y_offset(legacy, 11.0), 1e-9
  end

  def placement_page_runner(model, log, cancel_at, id_base)
    lambda do |_model, path, page_opts|
      unless page_opts[:resumable_page_call]
        # The real run_pipeline hands a resumable request to
        # run_resumable_pipeline.
        next IMP.run_resumable_pipeline(model, path, page_opts)
      end
      page = page_opts[:pages].first
      offset = page_opts[:initial_y_offset]
      log << [File.basename(path), page, offset]
      raise IRC::ImportCancelled.new([], page, {}) if cancel_at == [File.basename(path), page]
      group = model.active_entities.add(
        BoundedGroup.new(id_base[0] += 1, page, offset, offset + 11.0)
      )
      IMP.mark_pdf_page_group!(group)
      following = offset + IMP.page_stack_step(11.0, :spread, 0.2)
      stats = { :pages => 1, :next_y_offset => following }
      page_opts[:page_certifier].call(group, following, stats)
      stats
    end
  end

  def with_placement_host(model, log, cancel_at = nil, &block)
    id_base = [100]
    with_stubs([[IMP::PdfSalvage, :prepare_if_needed, lambda { |path| [path, nil] }],
                [IMP::PdfSalvage, :cleanup, nil],
                [IMP::PDFParser, :new, FakeParser.new(2)],
                [IMP, :run_pipeline, placement_page_runner(model, log, cancel_at, id_base)],
                [IMP, :fit_retained_pages, nil],
                [IMP, :finalize_import_diagnostics!, nil],
                [IMP, :handle_open_gate, false]], &block)
  end

  def placement_opts
    dialog_opts('Auto').merge(:cancel_probe => lambda { false },
                              :status_sink => lambda { |_snapshot| true })
  end

  def write_pdf(dir, name)
    path = File.join(dir, name)
    File.binwrite(path, "%PDF-1.4\n% #{name}\n%%EOF\n")
    path
  end

  def test_second_pdf_lands_above_the_first_and_a_resume_keeps_its_journal_offsets
    model = Model.new
    log = []
    Dir.mktmpdir('placement') do |dir|
      first = write_pdf(dir, 'D042-a.pdf')
      second = write_pdf(dir, 'D042-b.pdf')
      with_placement_host(model, log, ['D042-a.pdf', 2]) do
        partial = IMP.run_resumable_pipeline(model, first, placement_opts)
        assert_equal true, partial[:cancelled]
      end
      assert_equal [['D042-a.pdf', 1, 0.0], ['D042-a.pdf', 2, 13.2]], log
      with_placement_host(model, log) do
        IMP.run_resumable_pipeline(model, second, placement_opts)
      end
      b_first = log.find { |row| row[0] == 'D042-b.pdf' && row[1] == 1 }
      assert_in_delta 11.0 + 2.2, b_first[2], 1e-9, 'second PDF starts above the first'
      with_placement_host(model, log) do
        resumed = IMP.run_resumable_pipeline(model, first, placement_opts)
        assert_equal [1], resumed[:resumed_pages]
      end
      a_page2 = log.select { |row| row[0] == 'D042-a.pdf' && row[1] == 2 }.last
      assert_in_delta 13.2, a_page2[2], 1e-9,
                      'a resume continues from the journal offset, not from the bounds'
    end
  end

  def test_folder_batch_gives_each_pdf_its_own_stack
    model = Model.new
    log = []
    Dir.mktmpdir('placement-batch') do |dir|
      %w[D100-1.pdf D100-2.pdf D100-3.pdf].each { |name| write_pdf(dir, name) }
      with_placement_host(model, log) do
        with_stubs([[Sketchup, :active_model, model],
                    [UI, :inputbox, [dir]],
                    [UI, :messagebox, IDYES]]) do
          IMP.batch_import
        end
      end
    end
    starts = log.select { |row| row[1] == 1 }.map { |row| row[2] }
    tops = log.select { |row| row[1] == 2 }.map { |row| row[2] + 11.0 }
    assert_equal 3, starts.length
    assert_equal 0.0, starts[0]
    assert_operator starts[1], :>, tops[0]
    assert_operator starts[2], :>, tops[1]
  end

  def test_folder_batch_does_not_count_incomplete_or_nil_results_as_success
    with_batch_fixture([{:result_status => 'incomplete'}, {:pages => 1}, nil]) do |calls, summary, _|
      assert_equal 3, calls.length
      assert_includes summary, '1 imported, 2 failed, 0 cancelled'
    end
  end

  def test_folder_batch_stops_after_cancellation_or_uncertain_rollback
    with_batch_fixture([{:cancelled => true}, {:pages => 1}]) do |calls, summary, _|
      assert_equal 1, calls.length
      assert_includes summary, '0 imported, 0 failed, 1 cancelled'
      assert_includes summary, 'remaining PDFs were not started'
    end
    with_batch_fixture([IRC::RollbackFailure.new('rollback could not be confirmed'), {:pages => 1}]) do |calls, summary, aborts|
      assert_equal 1, calls.length
      assert_includes summary, '0 imported, 1 failed, 0 cancelled'
      assert_includes summary, 'Stopped: rollback could not be confirmed'
      assert_empty aborts
    end
  end

  # ---- Esc stops imports that cannot resume ------------------------------

  class FakeParser
    def initialize(page_count); @page_count = page_count; end
    def parse; true; end
    def page_count; @page_count; end
    def page_data(_page); { :media_box => [0, 0, 612, 792] }; end
    def release; true; end
  end

  class FakeOCG
    def parse; true; end
    def layer_list; []; end
  end

  # Stands in for the first geometry a page build leaves inside the open
  # operation before Esc is seen at the page checkpoint.
  class PartialLayerManager
    def initialize(model); @model = model; end
    def precreate_pdf_layers(_layers)
      @model.active_entities.add(Group.new(900, 1))
    end
    def register_imported_names!; end
  end

  def dialog_opts(mode, extra = {})
    raw = {}
    IMP::ImportDialog::MODES[mode].each { |key, value| raw[key.to_sym] = value }
    IMP::ImportDialog.send(:build_opts, raw.merge(:import_mode => raw[:import_mode],
                                                  :pages => 'All').merge(extra))
  end

  def with_stubs(stubs, &block)
    return yield if stubs.empty?
    target, name, value = stubs.first
    target.stub(name, value) { with_stubs(stubs[1..-1], &block) }
  end

  def with_pdf_fixture
    Dir.mktmpdir('esc-cancel') do |dir|
      path = File.join(dir, 'D042-esc.pdf')
      File.binwrite(path, "%PDF-1.4\n%%EOF\n")
      yield path
    end
  end

  def page_groups(model)
    model.active_entities.to_a.select { |entity| entity.is_a?(Group) }
  end

  def test_esc_stops_an_import_text_no_import_and_leaves_the_model_unchanged
    opts = dialog_opts('Auto', :import_text => 'No')
    refute IMP.resumable_import?(opts), 'Import Text = No must take the non-resumable path'
    model = TransactionModel.new
    stats = nil
    with_pdf_fixture do |path|
      with_stubs([[IMP::PdfSalvage, :prepare_if_needed, [path, nil]],
                  [IMP::PdfSalvage, :cleanup, nil],
                  [IMP::PDFParser, :new, FakeParser.new(2)],
                  [IMP::OCGParser, :new, FakeOCG.new],
                  [IMP::LayerManager, :new, PartialLayerManager.new(model)]]) do
        stats = IMP.run_resumable_pipeline(
          model, path,
          opts.merge(:cancel_probe => lambda { true },
                     :extract_embedded_images => false,
                     :status_sink => lambda { |_snapshot| true })
        )
      end
    end
    assert_equal true, stats[:cancelled]
    assert_equal 'cancelled', IMP.import_result_status(stats)
    assert_operator model.abort_count, :>=, 1
    assert_empty page_groups(model), 'the open operation must be rolled back'
    assert_match(/stopped with Esc/, stats[:message])
    assert_match(/stopped with Esc/, R.cancelled_status(stats))
  end

  def test_esc_stops_a_raster_import_and_rolls_back_finished_pages
    opts = dialog_opts('Raster')
    assert_equal true, opts[:force_raster]
    refute IMP.resumable_import?(opts)
    model = TransactionModel.new
    probe_calls = 0
    probe = lambda { probe_calls += 1; probe_calls >= 2 }
    raster = lambda do |*_args|
      model.active_entities.add(Group.new(700, 1))
      { :entity_id => 700, :artifact_evidence => {}, :performance => {} }
    end
    stats = nil
    with_pdf_fixture do |path|
      with_stubs([[IMP::PDFParser, :new, FakeParser.new(2)],
                  [IMP, :verified_raster_entity!, raster],
                  [IMP, :add_page_fit_bounds, nil]]) do
        stats = IMP.run_resumable_pipeline(
          model, path,
          opts.merge(:cancel_probe => probe,
                     :status_sink => lambda { |_snapshot| true })
        )
      end
    end
    assert_equal 2, probe_calls, 'Esc is checked before every Raster page'
    assert_equal true, stats[:cancelled]
    assert_equal 1, model.abort_count
    assert_empty page_groups(model), 'page 1 is rolled back with the operation'
    assert_match(/model unchanged/, R.cancelled_status(stats))
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

  def test_inline_images_left_out_on_vector_pages_are_named
    stats = { :pages => 6, :edges => 1, :text => 1,
              :inline_image_vector_retentions => [
                { :page => 5, :inline_image_instance_count => 2175,
                  :vector_path_count => 15_012, :delivery => :editable_geometry },
                { 'page' => 6, 'inline_image_instance_count' => 2175 }
              ] }
    assert_includes R.completion_status(stats),
                    'Inline images not placed on pages 5-6 (vectors kept).'
    summary = R.build_summary(stats)
    assert_includes summary, 'Page 5: 2175 inline image piece(s)'
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
