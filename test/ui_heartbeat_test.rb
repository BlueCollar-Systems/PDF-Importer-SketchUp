# The window heartbeat keeps SketchUp answering Windows during an import
# without letting any queued click, key or menu command run. These tests use
# made-up user32 fixtures only: no SketchUp, no real window, no PDF.
require 'minitest/autorun'
require 'rbconfig'
require 'weakref'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/command_runner'

class UiHeartbeatTest < Minitest::Test
  IRC = BlueCollarSystems::PDFVectorImporter::ImportRunControl
  Heartbeat = IRC::UiHeartbeat

  class ManualClock
    attr_accessor :now
    def initialize; @now = 0.0; end
    def call; @now; end
  end

  class RecordingLogger
    attr_reader :lines
    def initialize; @lines = []; end
    def warn(context, message); @lines << [context, message]; end
  end

  # Real loader code over fake Win32API / Fiddle modules.
  class Harness < Heartbeat
    def initialize(fixture, options = {})
      @fixture = fixture
      super(options)
    end

    private

    def windows_platform?; @fixture[:windows] != false; end

    def load_key_library(name)
      @fixture[:requires] << name
      raise LoadError, "#{name} unavailable" if @fixture[:missing].include?(name)
      true
    end

    def win32api_class; @fixture[:legacy]; end
    def fiddle_module; @fixture[:fiddle]; end
  end

  def fixture(options = {})
    data = { :requires => [], :missing => ['Win32API'], :calls => [],
             :looked_up => [], :constructors => [], :dll_paths => [],
             :windows => true }.merge(options)
    legacy = Class.new
    legacy.define_singleton_method(:new) do |*args|
      data[:legacy_signature] = args
      api = Object.new
      api.define_singleton_method(:call) { |*call_args| data[:calls] << call_args; 0 }
      api
    end
    handle_class = Class.new do
      define_method(:[]) do |name|
        data[:looked_up] << name
        0x1000 + data[:looked_up].length
      end
    end
    function = Class.new
    function.const_set(:DEFAULT, 11)
    function.define_singleton_method(:new) do |*args|
      data[:constructors] << args
      api = Object.new
      api.define_singleton_method(:call) do |*call_args|
        raise 'DLL handle was collected before use' unless data[:dll_reference].weakref_alive?
        data[:calls] << call_args
        0
      end
      api
    end
    fiddle = Module.new
    fiddle.const_set(:TYPE_INT, 4)
    fiddle.const_set(:TYPE_VOIDP, 1)
    fiddle.const_set(:SIZEOF_VOIDP, 8)
    fiddle.const_set(:Function, function)
    fiddle.define_singleton_method(:dlopen) do |path|
      data[:dll_paths] << path
      library = handle_class.new
      data[:dll_reference] = WeakRef.new(library)
      library
    end
    data[:legacy] = legacy
    data[:fiddle] = fiddle
    data
  end

  def heartbeat_with(clock, peeks = [], options = {})
    Heartbeat.new({ :clock => clock, :peek => lambda { peeks << clock.now } }.merge(options))
  end

  # --- what is called -----------------------------------------------------

  def test_fiddle_loader_binds_only_peek_message_with_no_remove_flags
    data = fixture
    clock = ManualClock.new
    beat = Harness.new(data, :clock => clock, :env => {})
    assert_equal :fiddle, beat.adapter_kind
    assert_equal ['Win32API', 'fiddle'], data[:requires]
    assert_equal ['PeekMessageW'], data[:looked_up],
                 'no TranslateMessage/DispatchMessage/GetMessage is ever loaded'
    assert_equal 1, data[:constructors].length
    _address, arg_types, return_type, abi = data[:constructors].first
    assert_equal [1, 1, 4, 4, 4], arg_types
    assert_equal 4, return_type
    assert_equal 11, abi
    assert beat.pulse!(:first)
    GC.start
    clock.now = 0.3
    assert beat.pulse!(:second)
    assert_equal 2, data[:calls].length
    data[:calls].each do |buffer, window, first, last, flags|
      assert_equal Heartbeat::MESSAGE_BUFFER_BYTES, buffer.bytesize
      assert_equal 0, window, 'all of this thread\'s windows'
      assert_equal [0, 0], [first, last], 'every message type'
      assert_equal Heartbeat::PM_NOREMOVE | Heartbeat::PM_NOYIELD, flags
      assert_equal 0, flags & Heartbeat::PM_REMOVE, 'a queued message is never removed'
    end
  end

  def test_win32api_is_first_choice_where_sketchup_ships_it
    data = fixture(:missing => [])
    beat = Harness.new(data, :clock => ManualClock.new, :env => {})
    assert_equal :win32api, beat.adapter_kind
    assert_equal ['Win32API'], data[:requires], 'Fiddle is not loaded when Win32API works'
    assert_equal ['user32', 'PeekMessageW', ['P', 'P', 'I', 'I', 'I'], 'I'],
                 data[:legacy_signature]
    assert beat.pulse!
    buffer, window, first, last, flags = data[:calls].first
    assert_equal Heartbeat::MESSAGE_BUFFER_BYTES, buffer.bytesize
    assert_equal [0, 0, 0], [window, first, last]
    assert_equal Heartbeat::PEEK_FLAGS, flags
    assert_equal 0, flags & Heartbeat::PM_REMOVE
  end

  def test_other_platforms_are_a_quiet_no_op
    logger = RecordingLogger.new
    beat = Harness.new(fixture(:windows => false), :clock => ManualClock.new,
                       :env => {}, :logger => logger)
    assert_equal :none, beat.adapter_kind
    refute beat.available?
    refute beat.pulse!
    assert_equal 0, beat.pulses
    assert_empty logger.lines
  end

  def test_missing_readers_are_reported_once_and_never_raise
    logger = RecordingLogger.new
    data = fixture(:missing => ['Win32API', 'fiddle'])
    beat = Harness.new(data, :clock => ManualClock.new, :env => {}, :logger => logger)
    assert_equal :none, beat.adapter_kind
    5.times { refute beat.pulse! }
    assert_equal 1, logger.lines.length
    assert_match(/Not Responding/, logger.lines.first[1])
    assert_empty data[:calls]
  end

  def test_environment_switch_turns_it_off
    peeks = []
    beat = heartbeat_with(ManualClock.new, peeks, :env => { 'BC_PDF_UI_HEARTBEAT' => '0' })
    assert_equal :disabled, beat.adapter_kind
    refute beat.pulse!
    assert_empty peeks
  end

  def test_a_failing_peek_turns_the_heartbeat_off_without_raising
    logger = RecordingLogger.new
    clock = ManualClock.new
    calls = 0
    beat = Heartbeat.new(:clock => clock, :logger => logger,
                         :peek => lambda { calls += 1; raise 'native call failed' })
    refute beat.pulse!
    clock.now = 1.0
    refute beat.pulse!
    assert_equal 1, calls
    assert_equal :none, beat.adapter_kind
    assert_equal 1, logger.lines.length
  end

  # --- the rate limit -----------------------------------------------------

  def test_peeks_at_most_once_per_250_ms
    clock = ManualClock.new
    peeks = []
    beat = heartbeat_with(clock, peeks)
    2001.times do |index|
      clock.now = index / 1000.0 # 0.000 .. 2.000 s in 1 ms steps
      beat.pulse!(:busy)
    end
    assert_equal 2001, beat.requests
    assert_equal [0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], peeks
    assert_equal peeks.length, beat.pulses
    peeks.each_cons(2) { |a, b| assert_operator b - a, :>=, 0.25 }
  end

  def test_a_message_delivered_during_the_peek_cannot_start_another_peek
    clock = ManualClock.new
    nested = []
    beat = nil
    peek = lambda do
      clock.now += 1.0 # Windows ran something slow during the peek
      nested << beat.pulse!(:nested)
    end
    beat = Heartbeat.new(:clock => clock, :peek => peek)
    assert beat.pulse!(:outer)
    assert_equal [false], nested
    assert_equal 1, beat.pulses
  end

  # --- self-measurement ---------------------------------------------------

  def test_summary_names_the_progress_points_around_the_longest_gap
    clock = ManualClock.new
    beat = heartbeat_with(clock)
    beat.start!(:import_started)
    clock.now = 0.1
    beat.pulse!(:text_item) # rate-limited, still the last point before the gap
    clock.now = 3.1
    beat.pulse!(:text_evidence)
    clock.now = 3.4
    beat.pulse!(:cleanup)
    clock.now = 9.5
    beat.pulse!(:certify_page)
    data = beat.summary(9.5)
    assert_equal 6100.0, data[:longest_gap_ms]
    assert_equal 'cleanup', data[:longest_gap_after]
    assert_equal 'certify_page', data[:longest_gap_before]
    assert_equal 2, data[:gaps_over_1s]
    assert_equal 1, data[:gaps_over_5s]
    assert_equal [6100.0, 3100.0], data[:slow_gaps].map { |gap| gap[:gap_ms] }
    assert_equal 'text_item', data[:slow_gaps].last[:after]
    assert_equal 'text_evidence', data[:slow_gaps].last[:before]
    assert_equal 4, data[:pulses]
    assert_equal 5, data[:requests]
    assert_equal 9500.0, data[:active_ms]
    assert_equal 250.0, data[:interval_ms]
  end

  def test_summary_reports_what_status_bar_writes_cost
    beat = heartbeat_with(ManualClock.new)
    beat.record_status_write(0.004)
    beat.record_status_write(0.25)
    beat.record_status_write(-1.0)
    beat.record_status_write(Float::NAN)
    data = beat.summary(0.0)
    assert_equal 2, data[:status_writes]
    assert_equal 254.0, data[:status_write_ms]
    assert_equal 250.0, data[:status_write_max_ms]
  end

  # SketchUp 2017's first SecureRandom call froze an import for 6.7 s while
  # OpenSSL seeded itself; import ids no longer touch SecureRandom.
  def test_import_ids_are_unique_well_formed_and_skip_secure_random
    require 'securerandom'
    failing = lambda { |*_args| raise 'SecureRandom must not be called' }
    ids = nil
    hexes = nil
    SecureRandom.stub(:uuid, failing) do
      SecureRandom.stub(:hex, failing) do
        SecureRandom.stub(:random_bytes, failing) do
          ids = Array.new(2000) { IRC.unique_uuid }
          hexes = Array.new(2000) { IRC.unique_hex(16) }
        end
      end
    end
    assert_equal 2000, ids.uniq.length
    assert_equal 2000, hexes.uniq.length
    ids.each do |id|
      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, id)
    end
    hexes.each { |hex| assert_match(/\A[0-9a-f]{32}\z/, hex) }
  end

  # --- one heartbeat per import -------------------------------------------

  def test_module_scope_installs_and_restores_the_active_heartbeat
    clock = ManualClock.new
    outer_peeks = []
    inner_peeks = []
    outer = heartbeat_with(clock, outer_peeks)
    inner = heartbeat_with(clock, inner_peeks)
    refute IRC.heartbeat!(:outside), 'no import, no peek'
    controller = Object.new
    IRC.active_controller = controller
    assert_nil IRC.active_controller, 'a controller outside an import is not kept'
    IRC.with_ui_heartbeat(outer) do
      assert_same outer, IRC.active_heartbeat
      assert_equal [0.0], outer_peeks, 'the scope peeks once when it starts'
      IRC.active_controller = controller
      assert_same controller, IRC.active_controller
      IRC.with_ui_heartbeat(inner) do
        assert_same inner, IRC.active_heartbeat
        assert_nil IRC.active_controller
      end
      assert_same outer, IRC.active_heartbeat
      assert_same controller, IRC.active_controller
      clock.now = 1.0
      assert IRC.heartbeat!(:inside)
    end
    assert_nil IRC.active_heartbeat
    assert_nil IRC.active_controller
    assert_equal [0.0, 1.0], outer_peeks
    assert_equal [0.0], inner_peeks
  end

  def test_scope_is_restored_when_the_import_raises
    beat = heartbeat_with(ManualClock.new)
    assert_raises(RuntimeError) do
      IRC.with_ui_heartbeat(beat) { raise 'page failed' }
    end
    assert_nil IRC.active_heartbeat
  end

  class LabelRecordingHeartbeat < Heartbeat
    def requested
      @requested ||= []
    end

    def pulse!(label = nil)
      requested << label
      super
    end
  end

  def test_every_controller_progress_point_reaches_the_heartbeat
    clock = ManualClock.new
    beat = LabelRecordingHeartbeat.new(:clock => clock, :peek => lambda { true })
    requested = beat.requested
    controller = IRC::Controller.new(:pages => [4, 7], :requested_mode => :text3d,
                                     :clock => clock, :cancel_probe => lambda { false })
    IRC.with_ui_heartbeat(beat) do
      controller.checkpoint!(:text_item, :page => 7, :completed => 1, :total => 3)
      snapshot = controller.progress(:text_evidence, :completed => 2, :total => 3)
      assert_nil snapshot[:page], 'the cancel/resume page is not invented'
      assert_equal 7, snapshot[:current_page]
      assert_equal 2, snapshot[:page_index]
      assert_equal 2, snapshot[:page_total]
    end
    assert_equal [:import_started, :text_item, :text_evidence], requested
  end

  def test_deep_progress_points_never_read_esc_and_never_raise
    clock = ManualClock.new
    peeks = []
    beat = heartbeat_with(clock, peeks)
    probe_calls = 0
    controller = IRC::Controller.new(:pages => [1], :clock => clock,
                                     :cancel_probe => lambda { probe_calls += 1; true },
                                     :status_sink => lambda { |_s| raise 'status bar failed' })
    IRC.with_ui_heartbeat(beat) do
      IRC.active_controller = controller
      clock.now = 0.5
      assert IRC.progress!(:text_evidence, 3, 10)
      clock.now = 0.6
      assert_equal false, IRC.progress!(:text_evidence, -1, 10), 'bad counts are swallowed'
    end
    assert_equal 0, probe_calls, 'progress! is never a cancellation point'
    assert_equal [0.0, 0.5], peeks
    assert IRC.progress!(:outside, 1, 2), 'outside an import it is a no-op'
    assert_equal [0.0, 0.5], peeks
  end

  def test_tick_reads_the_clock_on_every_64th_call_only
    clock = ManualClock.new
    reads = 0
    counting_clock = lambda { reads += 1; clock.now }
    beat = Heartbeat.new(:clock => counting_clock, :peek => lambda { true })
    IRC.with_ui_heartbeat(beat) do
      reads = 0
      640.times { IRC.heartbeat_tick!(:walk) }
    end
    assert_operator reads, :<=, 10 * 2, 'at most one read per pulse request (plus peek timing)'
    assert_operator reads, :>=, 10
  end

  # --- waiting on a child process -----------------------------------------

  def test_waiting_for_a_thread_keeps_peeking_and_honours_the_timeout
    peeks = 0
    beat = Heartbeat.new(:peek => lambda { peeks += 1 })
    IRC.with_ui_heartbeat(beat) do
      peeks = 0
      worker = Thread.new { sleep 0.8 }
      assert IRC.wait_with_heartbeat(worker, 5.0)
      assert_operator peeks, :>=, 2, 'the window was answered during the wait'
      slow = Thread.new { sleep 5 }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      refute IRC.wait_with_heartbeat(slow, 0.3)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.0
      slow.kill
    end
    plain = Thread.new { :done }
    assert IRC.wait_with_heartbeat(plain, 1.0), 'outside an import it is a plain join'
  end

  def test_command_runner_peeks_while_a_child_program_runs_and_still_times_out
    peeks = 0
    beat = Heartbeat.new(:peek => lambda { peeks += 1 })
    runner = BlueCollarSystems::PDFVectorImporter::CommandRunner
    IRC.with_ui_heartbeat(beat) do
      peeks = 0
      run = runner.run([RbConfig.ruby, '-e', 'sleep 0.8; print "made up"'],
                       :timeout_s => 30, :context => 'test')
      assert run[:ok], run.inspect
      assert_equal 'made up', run[:stdout]
      assert_operator peeks, :>=, 2
      slow = runner.run([RbConfig.ruby, '-e', 'sleep 20'], :timeout_s => 0.5,
                        :context => 'test')
      assert slow[:timed_out]
      refute slow[:ok]
    end
  end

  def test_capture3_keeps_peeking_and_returns_the_child_result
    peeks = 0
    beat = Heartbeat.new(:peek => lambda { peeks += 1 })
    out = err = status = nil
    IRC.with_ui_heartbeat(beat) do
      peeks = 0
      out, err, status = IRC.capture3_with_heartbeat(
        RbConfig.ruby, '-e', 'sleep 0.8; print "x"; warn "y"'
      )
    end
    assert_equal 'x', out
    assert_equal "y\n", err
    assert status.success?
    assert_operator peeks, :>=, 2
  end
end
