# test/import_run_control_test.rb
# Deterministic complexity/progress/cancel contracts for expensive imports.
# Ruby 2.2 compatible -- no keyword arguments, safe navigation, or newer APIs.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'

class ImportRunControlTest < Minitest::Test
  IRC = BlueCollarSystems::PDFVectorImporter::ImportRunControl

  class FakeClock
    def initialize(values)
      @values = values.dup
      @last = @values.first || 0.0
    end

    def call
      @last = @values.shift unless @values.empty?
      @last
    end
  end

  def controller(opts = {})
    defaults = {
      :pages => [1, 2],
      :requested_mode => :text3d,
      :clock => FakeClock.new([0.0])
    }
    IRC::Controller.new(defaults.merge(opts))
  end

  def test_assessment_has_exact_thresholds_and_mode_weight
    normal = controller.assess(:paths => 1_999)
    large = controller.assess(:paths => 2_000)
    very_large = controller.assess(:paths => 8_000)

    assert_equal :normal, normal[:class]
    assert_equal :large, large[:class]
    assert_equal :very_large, very_large[:class]
    assert_equal 8_000, very_large[:work_units]

    text3d = controller.assess(
      :text_items => 1_200,
      :glyph_placements => 5_000
    )
    assert_equal :very_large, text3d[:class]
    assert_equal 9_800, text3d[:work_units]
    assert_equal 4, text3d[:mode_weight]
  end

  def test_assessment_rejects_negative_non_integer_and_unknown_counts
    assert_raises(ArgumentError) { controller.assess(:paths => -1) }
    assert_raises(ArgumentError) { controller.assess(:paths => 1.5) }
    assert_raises(ArgumentError) { controller.assess(:surprise => 1) }
  end

  def test_progress_is_monotonic_and_eta_requires_measured_completed_work
    events = []
    clock = FakeClock.new([0.0, 10.0, 20.0, 30.0])
    run = controller(:clock => clock, :status_sink => lambda { |s| events << s })

    first = run.progress(:text_item, :completed => 0, :total => 100)
    second = run.progress(:text_item, :completed => 25, :total => 100)
    third = run.progress(:text_item, :completed => 20, :total => 100)

    assert_equal 0.0, first[:percentage]
    assert_nil first[:eta_seconds]
    assert_equal 25.0, second[:percentage]
    assert_in_delta 30.0, second[:eta_seconds], 0.001
    assert_equal 25.0, third[:percentage], 'progress must never move backwards'
    assert_equal [first, second, third], events
  end

  # The same [stage, page] can run more than once: a progress point that
  # does not know its page, one pass per white mask, or the 3D Text evidence
  # check running again for items that stepped down. Each pass is timed from
  # its own start. Made-up counts and times.
  def test_time_left_is_measured_from_the_current_pass_of_a_stage
    now = [0.0]
    run = controller(:clock => lambda { now[0] })

    # First pass: 100 rows at 0.5 s each, then 200 s of other work.
    100.times do |index|
      run.progress(:text_evidence, :completed => index, :total => 100)
      now[0] += 0.5
    end
    now[0] += 200.0

    # Next pass of the same stage (no page given): 40 rows at 0.5 s each.
    later = nil
    9.times do |index|
      later = run.progress(:text_evidence, :completed => index, :total => 40)
      now[0] += 0.5
    end
    assert_equal 8, later[:completed]
    assert_in_delta 4.0, later[:stage_elapsed_seconds], 1e-9
    assert_in_delta 16.0, later[:eta_seconds], 1e-9,
                    '32 rows left at 0.5 s each, not timed from the first pass'

    # A pass with the same total starts again when its count goes back.
    now[0] += 100.0
    again = nil
    5.times do |index|
      again = run.progress(:text_evidence, :completed => index, :total => 40)
      now[0] += 0.5
    end
    assert_in_delta 2.0, again[:stage_elapsed_seconds], 1e-9
    assert_in_delta 18.0, again[:eta_seconds], 1e-9
    assert_equal 99.0, again[:percentage], 'the stage percentage stays monotonic'
  end

  def test_a_count_held_at_zero_keeps_the_clock_and_a_late_start_is_not_credited
    now = [10.0]
    run = controller(:clock => lambda { now[0] })
    run.progress(:white_mask_cells, :page => 1, :completed => 0, :total => 10)
    now[0] += 3.0
    run.progress(:white_mask_cells, :page => 1, :completed => 0, :total => 10)
    now[0] += 1.0
    slow_first = run.progress(:white_mask_cells, :page => 1, :completed => 1,
                              :total => 10)
    assert_in_delta 4.0, slow_first[:stage_elapsed_seconds], 1e-9,
                    'the slow first item counts toward the pace'
    assert_in_delta 36.0, slow_first[:eta_seconds], 1e-9

    # First seen part-way (a resumed page): only work done since then counts.
    run.progress(:geometry_path, :page => 2, :completed => 50, :total => 100)
    now[0] += 1.0
    partway = run.progress(:geometry_path, :page => 2, :completed => 60,
                           :total => 100)
    assert_in_delta 4.0, partway[:eta_seconds], 1e-9, '40 left at 10 per second'
  end

  def test_progress_clamps_completion_and_has_stable_page_context
    run = controller(:clock => FakeClock.new([5.0, 7.0]))
    snapshot = run.progress(
      :geometry_path,
      :completed => 120,
      :total => 100,
      :page => 2,
      :page_index => 2,
      :page_total => 2
    )

    assert_equal :geometry_path, snapshot[:stage]
    assert_equal 100, snapshot[:completed]
    assert_equal 100, snapshot[:total]
    assert_equal 100.0, snapshot[:percentage]
    assert_equal 2, snapshot[:page]
    assert_equal 2, snapshot[:page_index]
    assert_equal 2, snapshot[:page_total]
    assert_equal 0.0, snapshot[:eta_seconds]
  end

  def test_checkpoint_raises_dedicated_cancellation_with_retained_pages
    probes = 0
    run = controller(
      :cancel_probe => lambda { probes += 1; true },
      :clock => FakeClock.new([0.0, 1.0])
    )
    run.retain_page!(1)

    error = assert_raises(IRC::ImportCancelled) do
      run.checkpoint!(
        :text_item,
        :completed => 1,
        :total => 1_200,
        :page => 2
      )
    end

    assert_equal 1, probes
    assert_equal [1], error.retained_pages
    assert_equal 2, error.next_page
    assert_equal :text_item, error.snapshot[:stage]
    assert_equal true, error.cancelled?
  end

  def test_cancelled_result_explicitly_says_what_was_kept
    run = controller(:cancel_probe => lambda { true })
    run.retain_page!(1)
    error = assert_raises(IRC::ImportCancelled) do
      run.checkpoint!(:page, :page => 2, :completed => 1, :total => 2)
    end
    result = run.cancelled_result(error)

    assert_equal true, result[:cancelled]
    assert_equal [1], result[:retained_pages]
    assert_equal 2, result[:next_page]
    assert_match(/Page 1 was kept/, result[:message])
    assert_match(/Resume starts at page 2/, result[:message])
  end

  def test_escape_probe_uses_high_bit_without_requiring_windows_in_tests
    values = [0, 0x8000]
    probe = IRC::EscapeCancelProbe.new(lambda { |_key| values.shift })

    refute probe.call
    assert probe.call
    assert_equal :injected, probe.adapter_kind
  end

  # A quick Esc tap between two checkpoints sets only the low
  # "pressed since the last call" bit; it must still cancel while
  # SketchUp is confirmed to be the program in front.
  def test_escape_probe_counts_a_tap_between_checkpoints
    probe = IRC::EscapeCancelProbe.new(lambda { |_key| 0x0001 }, nil, lambda { true })

    assert probe.call
  end

  # Windows does not tie the low bit to one program, so a tap counts only
  # when SketchUp is known to be in front; held Esc (high bit) is unchanged.
  def test_escape_tap_needs_sketchup_confirmed_in_front
    tap = lambda { |_key| 0x0001 }

    refute IRC::EscapeCancelProbe.new(tap).call, 'no foreground check'
    refute IRC::EscapeCancelProbe.new(tap, nil, lambda { nil }).call, 'front unknown'
    refute IRC::EscapeCancelProbe.new(tap, nil, lambda { false }).call, 'another program in front'
    assert IRC::EscapeCancelProbe.new(lambda { |_key| 0x8000 }).call, 'held Esc'
  end

  # Fiddle returns GetAsyncKeyState as a signed short.
  def test_escape_probe_accepts_a_signed_short_key_state
    probe = IRC::EscapeCancelProbe.new(lambda { |_key| -32_768 })

    assert probe.call
  end

  # SketchUp 2024+ ships Ruby 3.2 without Win32API. The default probe must
  # still build a real key reader on Windows, never the always-zero stub.
  def test_default_escape_probe_reads_the_real_key_on_windows
    skip 'Windows only' unless Gem.win_platform?
    probe = IRC::EscapeCancelProbe.new

    assert_includes [:fiddle, :win32api], probe.adapter_kind
    assert_includes [true, false], probe.call
  end

  # Esc pressed in another program must not stop the import.
  def test_escape_counts_only_while_sketchup_is_in_front
    pressed = lambda { |_key| 0x8001 }

    refute IRC::EscapeCancelProbe.new(pressed, nil, lambda { false }).call
    assert IRC::EscapeCancelProbe.new(pressed, nil, lambda { true }).call
    # Windows could not say which program is in front: the press counts.
    assert IRC::EscapeCancelProbe.new(pressed, nil, lambda { nil }).call
    assert IRC::EscapeCancelProbe.new(pressed, nil, lambda { raise 'lookup failed' }).call
    # No press: the foreground is never asked.
    asked = false
    idle = IRC::EscapeCancelProbe.new(lambda { |_key| 0 }, nil, lambda { asked = true })
    refute idle.call
    refute asked
  end

  def test_foreground_check_knows_sketchup_its_ghost_and_other_programs
    ours = 4242
    owners = { 10 => ours, 20 => 777, 30 => 888 }
    owner = lambda { |window| owners.fetch(window, 0) }
    ghosts = { 30 => 10 } # window 30 is the "Not Responding" ghost of 10
    ghost = lambda { |window| ghosts.fetch(window, 0) }
    check = lambda do |front, with_ghost = true|
      IRC::EscapeCancelProbe::ForegroundCheck.new(
        lambda { front }, owner, with_ghost ? ghost : nil, ours
      ).call
    end

    assert_equal true, check.call(10)
    assert_equal false, check.call(20)
    assert_equal true, check.call(30), 'the ghost of a busy SketchUp is SketchUp'
    assert_nil check.call(0), 'no foreground window: unknown'
    assert_nil check.call(99), 'owner lookup failed: unknown'
    assert_nil check.call(20, false), 'no ghost lookup: another program is unknown'
    assert_nil IRC::EscapeCancelProbe::ForegroundCheck.new(
      lambda { raise 'boom' }, owner, ghost, ours
    ).call
  end

  def test_default_escape_probe_checks_the_window_in_front_on_windows
    skip 'Windows only' unless Gem.win_platform?
    probe = IRC::EscapeCancelProbe.new

    assert probe.foreground_check?
    check = probe.instance_variable_get(:@foreground)
    assert_includes [true, false, nil], check.call
  end

  # The unattended host harness passes its own never-cancel probe.
  def test_batch_host_never_listens_for_escape
    source = File.read(File.expand_path('../tools/sketchup_batch_import.rb', __dir__))

    assert_match(/opts\[:cancel_probe\]\s*=\s*lambda\s*\{\s*false\s*\}/, source)
  end

  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(context, message)
      @warnings << [context, message]
    end
  end

  class NoKeyLibraryProbe < IRC::EscapeCancelProbe
    private

    def require(name)
      raise LoadError, "cannot load such file -- #{name}"
    end
  end

  class FakeWin32API
    def initialize(*_args); end

    def call(_key)
      0x8000
    end
  end

  class FiddleMissingProbe < IRC::EscapeCancelProbe
    private

    # A Windows host without Fiddle, also when the test runs on Linux CI:
    # the reader only looks for Win32API and Fiddle on Windows.
    def windows_platform?
      true
    end

    def require(name)
      raise LoadError, "cannot load such file -- #{name}" if name == 'fiddle'
      true
    end
  end

  # SketchUp 2017-2023 also ship Win32API; it stays as the fallback.
  def test_win32api_is_the_fallback_when_fiddle_is_missing
    defined_here = !defined?(::Win32API)
    Object.const_set(:Win32API, FakeWin32API) if defined_here
    skip 'a real Win32API is loaded' unless ::Win32API == FakeWin32API
    probe = FiddleMissingProbe.new(nil, RecordingLogger.new)

    assert_equal :win32api, probe.adapter_kind
    assert probe.call
  ensure
    Object.send(:remove_const, :Win32API) if defined_here && defined?(::Win32API)
  end

  def test_missing_key_libraries_log_once_and_never_cancel
    logger = RecordingLogger.new
    probe = NoKeyLibraryProbe.new(nil, logger)

    assert_equal :none, probe.adapter_kind
    3.times { assert_equal false, probe.call }
    assert_equal 1, logger.warnings.length
    assert_match(/Escape-key cancellation is unavailable/, logger.warnings.first[1])
  end

  def test_controller_accepts_a_callable_object_without_proc_arity
    probe = Class.new do
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def call
        @calls += 1
        false
      end
    end.new
    run = controller(
      :cancel_probe => probe,
      :clock => FakeClock.new([0.0, 1.0])
    )

    snapshot = run.checkpoint!(:page, :page => 1, :completed => 0, :total => 1)

    assert_equal :page, snapshot[:stage]
    assert_equal 1, probe.calls
  end

  def test_journal_stats_omit_per_span_evidence_payloads
    group = FakeCertGroup.new(7)
    model = FakeCertModel.new(group)
    run = journal_controller(model)
    bulky = {
      :edges => 5649,
      :text => 791,
      :text_renderers => [{ :group => group, :depths => [0.015625] * 791 }],
      :text_attempts => [{ :expected_evidence => { :geometry_payload => { :n => 1 } } }],
      :source_provenance_objects => [{ :expected_evidence => { :style_payload => { :n => 2 } } }],
      :pipeline_performance => { :commit_ms => 12.5 }
    }

    run.certify_page!(group, 1, :stats => bulky)
    stored = run.journal['pages'][0]['stats']

    assert_equal 5649, stored['edges']
    assert_equal 791, stored['text']
    assert_in_delta 12.5, stored['pipeline_performance']['commit_ms'], 0.001
    refute stored.key?('text_renderers'),
           'resume journal must not clone 3D Text renderer rows'
    refute stored.key?('text_attempts'),
           'resume journal must not clone per-span expected_evidence trees'
    refute stored.key?('source_provenance_objects'),
           'resume journal must not clone provenance expected_evidence trees'
  end

  def test_entity_signature_uses_numeric_point_order_and_detects_geometry_change
    run = journal_controller(FakeCertModel.new)
    left = FakeCertGroup.new(
      1,
      [FakeCertEdge.new(11, [0.0, 0.0, 0.0], [10.0, 9.0, 0.0])]
    )
    right = FakeCertGroup.new(
      1,
      [FakeCertEdge.new(11, [0.0, 0.0, 0.0], [10.0, 9.0, 0.0])]
    )
    moved = FakeCertGroup.new(
      1,
      [FakeCertEdge.new(11, [0.0, 0.0, 0.0], [10.0, 10.0, 0.0])]
    )

    first = run.send(:entity_signature, left)
    second = run.send(:entity_signature, right)
    changed = run.send(:entity_signature, moved)

    assert_match(/\A[0-9a-f]{64}\z/, first)
    assert_equal first, second
    refute_equal first, changed
  end

  def journal_controller(model)
    digest = 'ab' * 32
    IRC::Controller.new(
      :pages => [1],
      :requested_mode => :text3d,
      :model => model,
      :identity => {
        'pdf_sha256' => digest,
        'options_sha256' => digest,
        'importer_sha256' => digest,
        'package_sha256' => digest,
        'source_tree_sha256' => digest
      },
      :clock => FakeClock.new([0.0])
    )
  end

  class FakeCertPoint
    attr_reader :x, :y, :z

    def initialize(values)
      @x = values[0].to_f
      @y = values[1].to_f
      @z = values[2].to_f
    end

    def to_a
      [@x, @y, @z]
    end
  end

  class FakeCertEdge
    attr_reader :start, :end

    def initialize(persistent_id, start_xyz, end_xyz)
      @persistent_id = persistent_id
      @start = FakeCertPoint.new(start_xyz)
      @end = FakeCertPoint.new(end_xyz)
    end

    def persistent_id
      @persistent_id
    end

    def typename
      'Edge'
    end

    def name
      ''
    end

    def bounds
      FakeCertBounds.new(@start, @end)
    end
  end

  class FakeCertBounds
    attr_reader :min, :max

    def initialize(min_point, max_point)
      @min = min_point
      @max = max_point
    end
  end

  class FakeCertGroup
    attr_reader :entities

    def initialize(persistent_id, children = [])
      @persistent_id = persistent_id
      @entities = children
      @attrs = {}
    end

    def persistent_id
      @persistent_id
    end

    def typename
      'Group'
    end

    def name
      'PDF Page 1'
    end

    def valid?
      true
    end

    def bounds
      FakeCertBounds.new(
        FakeCertPoint.new([0.0, 0.0, 0.0]),
        FakeCertPoint.new([1.0, 1.0, 0.0])
      )
    end

    def set_attribute(_dict, key, value)
      @attrs[key.to_s] = value
    end

    def get_attribute(_dict, key, default = nil)
      @attrs.key?(key.to_s) ? @attrs[key.to_s] : default
    end
  end

  class FakeCertModel
    def initialize(group = nil)
      @group = group
      @attrs = {}
    end

    def get_attribute(dict, key, default = nil)
      @attrs[[dict, key]] || default
    end

    def set_attribute(dict, key, value)
      @attrs[[dict, key]] = value
    end

    def active_entities
      @group ? [@group] : []
    end
  end
end
