# Only status-bar drawing is throttled: the real controller must still publish
# each checkpoint and poll Escape. No native host, PDF or model is opened.
require 'minitest/autorun'
require 'minitest/mock'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class ImportStatusSinkThrottleTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  IRC = IMP::ImportRunControl

  class ManualClock
    attr_accessor :now
    def initialize; @now = 0.0; end
    def call; @now; end
  end

  class RecordingHost
    class << self
      attr_accessor :writes, :clock
      def status_text=(text)
        writes << [clock.call, text]
      end
    end
  end

  class FakeParser
    def parse; true; end
    def page_count; 1; end
    def release; true; end
  end

  def setup
    @clock = ManualClock.new
    RecordingHost.writes = []
    RecordingHost.clock = @clock
    IMP.const_set(:Sketchup, RecordingHost)
  end

  def teardown
    IMP.send(:remove_const, :Sketchup)
  end

  def with_clock(&block)
    Process.stub(:clock_gettime, lambda { |_kind| @clock.call }, &block)
  end

  def with_interactive(&block)
    IMP::BatchHostPolicy.stub(:noninteractive?, false, &block)
  end

  def test_2500_real_checkpoints_publish_and_cancel_while_gui_writes_are_bounded
    observed = []
    probed = []
    sink_results = []
    formatted = []
    formatter = IMP::ImportDialog.method(:progress_status)
    with_interactive do
      with_clock do
        gui_sink = IMP.import_status_sink({})
        sink = lambda do |snapshot|
          observed << snapshot
          sink_results << gui_sink.call(snapshot)
        end
        controller = IRC::Controller.new(
          :pages => [1], :requested_mode => :text3d, :clock => @clock,
          :status_sink => sink,
          :cancel_probe => lambda { |snapshot|
            probed << snapshot
            snapshot[:completed] == 2500
          }
        )
        IMP::ImportDialog.stub(:progress_status, lambda { |snapshot|
          formatted << snapshot
          formatter.call(snapshot)
        }) do
          error = assert_raises(IRC::ImportCancelled) do
            2500.times do |index|
              # Exact binary fractions span almost ten seconds without sleeps.
              @clock.now = index / 256.0
              controller.checkpoint!(:white_mask_cells, :page => 1,
                :completed => index + 1, :total => 2500)
              assert_equal 1, RecordingHost.writes.length if index == 0
            end
          end
          assert_equal 2500, error.snapshot[:completed]
          assert_equal 100.0, error.snapshot[:percentage]
          assert_equal 1, error.next_page
        end
      end
    end
    assert_equal (1..2500).to_a, observed.map { |snapshot| snapshot[:completed] }
    assert_equal observed, probed, 'every published checkpoint must still reach cancellation'
    assert_equal 5, RecordingHost.writes.length
    assert sink_results.all? { |result| result == true }, 'suppressed writes are successful sink calls'
    assert_equal 5, formatted.length, 'suppressed updates must not format GUI text either'
    assert_equal 0.0, RecordingHost.writes.first[0], 'first update must be immediate'
    RecordingHost.writes.each_cons(2) do |previous, current|
      assert_operator current[0] - previous[0], :>=, 2.0
    end
    assert_includes RecordingHost.writes.first[1], 'building fill cutouts 1/2500'
    assert_includes RecordingHost.writes.first[1], 'Esc to cancel'
  end

  def test_boundary_new_sink_and_completion_are_independent
    with_interactive do
      with_clock do
        sink = IMP.import_status_sink({})
        snapshot = {:stage => :white_mask_cells, :completed => 1, :total => 8,
                    :percentage => 100.0, :elapsed_seconds => 0.0, :eta_seconds => 0.0}
        sink.call(snapshot)
        @clock.now = 1.999
        assert_equal true, sink.call(snapshot.merge(:completed => 2))
        assert_equal 1, RecordingHost.writes.length
        @clock.now = 2.0
        assert_equal true, sink.call(snapshot.merge(:completed => 3))
        assert_equal 2, RecordingHost.writes.length
        assert_includes RecordingHost.writes.last[1], '37.5%'
        refute_includes RecordingHost.writes.last[1], 'ETA'
        assert_equal true, sink.call(snapshot.merge(:completed => 8))
        assert_equal 2, RecordingHost.writes.length,
          'per-stage N/N progress stays throttled; it is not the final import outcome'
        # The final import announcement is separate from controller progress.
        IMP::ReportDialog.announce(:pages => 1, :edges => 2, :text => 3)
        assert_equal 3, RecordingHost.writes.length
        assert_includes RecordingHost.writes.last[1], 'PDF import complete'
        next_import = IMP.import_status_sink({})
        assert_equal true, next_import.call(snapshot)
        assert_equal 4, RecordingHost.writes.length, 'each import gets an immediate first update'
      end
    end
  end

  def test_injected_sink_receives_every_checkpoint_without_throttling
    observed = []
    probed = []
    injected = lambda { |snapshot| observed << snapshot }
    with_interactive do
      with_clock do
        assert_same injected, IMP.import_status_sink(:status_sink => injected)
        controller = IRC::Controller.new(:clock => @clock,
          :status_sink => IMP.import_status_sink(:status_sink => injected),
          :cancel_probe => lambda { |snapshot| probed << snapshot; false })
        2500.times do |index|
          controller.checkpoint!(:geometry_path, :completed => index + 1, :total => 2500)
        end
      end
    end
    assert_equal (1..2500).to_a, observed.map { |snapshot| snapshot[:completed] }
    assert_equal observed, probed
    assert_empty RecordingHost.writes
  end

  def test_batch_sink_avoids_gui_but_preserves_helper_injection_precedence
    IMP::BatchHostPolicy.stub(:noninteractive?, true) do
      sink = IMP.import_status_sink({})
      25.times { assert_equal true, sink.call(:stage => :page) }
      injected = lambda { |_snapshot| :injected }
      assert_same injected, IMP.import_status_sink(:status_sink => injected)
    end
    assert_empty RecordingHost.writes
  end

  # Keep source preparation and model construction outside this regression,
  # but execute the production resumable wrapper and a real Controller.
  def run_resumable_with_sink(injected, batch)
    helper_calls = []
    probed = []
    captured = nil
    helper = IMP.method(:import_status_sink)
    identity = {}
    IRC::IDENTITY_KEYS.each { |key| identity[key] = 'a' * 64 }
    orchestrator = Object.new
    orchestrator.define_singleton_method(:run) do
      {:stats => {}, :requested_pages => [1], :result_status => 'success',
       :retained_pages => [], :resumed_pages => [], :new_pages => []}
    end
    options = {:pages => [1], :text_mode => :text3d, :import_mode => 'auto',
               :resumable => true, :group_per_page => true, :import_text => true,
               :large_pdf_confirmed => true,
               :cancel_probe => lambda { |snapshot| probed << snapshot; false }}
    options[:status_sink] = injected if injected
    factory = lambda do |actual|
      captured = actual[:controller].instance_variable_get(:@status_sink)
      3.times { |index| actual[:controller].checkpoint!(:white_mask_cells,
        :completed => index + 1, :total => 3, :page => 1) }
      orchestrator
    end
    stubs = [
      [IMP::BatchHostPolicy, :noninteractive?, batch],
      [IMP::PdfSalvage, :prepare_if_needed, ['fictional.pdf', nil]],
      [IMP::PdfSalvage, :cleanup, nil],
      [IMP::PDFParser, :new, FakeParser.new],
      [IRC, :identity_for, identity],
      [IRC::PageOrchestrator, :new, factory],
      [IMP, :import_status_sink, lambda { |opts| helper_calls << opts; helper.call(opts) }],
      [IMP, :fit_retained_pages, nil],
      [IMP, :finalize_import_diagnostics!, nil],
      [IMP::Logger, :reset, nil], [IMP::Logger, :info, nil],
      [IMP::Logger, :flush_log, nil], [IMP::Logger, :log_path, nil]
    ]
    with_clock do
      with_stubs(stubs) { IMP.run_resumable_pipeline(Object.new, 'fictional.pdf', options) }
    end
    assert_equal 1, helper_calls.length, 'default resumable imports must use the same GUI sink factory'
    assert_equal [1, 2, 3], probed.map { |snapshot| snapshot[:completed] }
    captured
  end

  def with_stubs(stubs, index = 0, &block)
    return block.call if index == stubs.length
    object, name, value = stubs[index]
    object.stub(name, value) { with_stubs(stubs, index + 1, &block) }
  end

  def test_default_resumable_pipeline_uses_throttled_gui_sink
    run_resumable_with_sink(nil, false)
    assert_equal 1, RecordingHost.writes.length
  end

  def test_default_resumable_pipeline_preserves_injected_sink
    observed = []
    injected = lambda { |snapshot| observed << snapshot }
    assert_same injected, run_resumable_with_sink(injected, false)
    assert_equal [1, 2, 3], observed.map { |snapshot| snapshot[:completed] }
    assert_empty RecordingHost.writes
  end

  def test_default_resumable_batch_override_preserves_no_gui_behavior
    run_resumable_with_sink(nil, true)
    observed = []
    injected = lambda { |snapshot| observed << snapshot }
    refute_same injected, run_resumable_with_sink(injected, true)
    assert_empty observed, 'existing resumable batch override must remain a no-op'
    assert_empty RecordingHost.writes
  end
end
