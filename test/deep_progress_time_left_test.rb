# test/deep_progress_time_left_test.rb
# The status line's time left during the 3D Text evidence check and the
# text step-downs. Those progress points sit deep in a page, so they once
# passed no page: the stage clock of page 2 kept page 1's start, and a second
# evidence pass on the same page kept the first pass's start. The line then
# showed "about 38 min left" with 18 s to go, and a false long wait is what
# leads to a force close. These tests drive the real importer functions with
# made-up spans, counts and times only: no SketchUp, no PDF.
# Ruby 2.2 compatible.

require 'minitest/autorun'
require 'minitest/mock'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class DeepProgressTimeLeftTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  IRC = IMP::ImportRunControl
  BID = IMP::ImportDialog

  Item = Struct.new(:source_span_id)

  class ManualClock
    attr_accessor :now
    def initialize; @now = 100.0; end
    def call; @now; end
  end

  ROW_SECONDS = 0.5

  def setup
    @clock = ManualClock.new
    @snapshots = []
    @lines = []
  end

  def controller(pages)
    IRC::Controller.new(
      :pages => pages, :requested_mode => :text3d, :clock => @clock,
      :cancel_probe => lambda { false },
      :status_sink => lambda { |snapshot|
        @snapshots << snapshot
        @lines << BID.progress_status(snapshot)
      }
    )
  end

  def within_import(run)
    beat = IRC::UiHeartbeat.new(:clock => @clock, :peek => lambda { true },
                                :env => {})
    IRC.with_ui_heartbeat(beat) do
      IRC.active_controller = run
      yield
    end
  end

  def span_row(page, index)
    { :source_span_id => "text_span:#{page}:#{index}",
      :group_entity_id => "persistent_id:#{9000 + index}",
      :identity_verified => true, :placement_verified => true,
      :rotation_verified => true, :size_verified => true,
      :depth_verified => true, :content_verified => true,
      :physical_geometry_verified => true, :physical_style_verified => true,
      :transform_verified => true,
      :depth => 0.1, :extruded_face_count => 1, :width => 1.0, :height => 0.2,
      :expected_evidence => { :source_text_sha256 => 'a' * 64 } }
  end

  def unjoined_row(index)
    { :source_kind => :svg_glyph_placement,
      :source_unit_id => "made_up_unit_#{index}",
      :source_span_id => nil, :group_entity_id => "persistent_id:#{8000 + index}",
      :identity_verified => true, :placement_verified => true,
      :rotation_verified => true, :size_verified => true,
      :depth_verified => true, :physical_source_identity_verified => true,
      :physical_geometry_verified => true, :physical_style_verified => true,
      :transform_verified => true,
      :depth => 0.1, :extruded_face_count => 1, :placement_indices => [index],
      :source_placement_count => 1, :expected_evidence => {} }
  end

  # One real evidence pass over `count` made-up spans (plus `unjoined`
  # source-glyph rows) on `page`, each taking ROW_SECONDS. Returns the status
  # line shown before row `watch_row` was checked.
  def evidence_pass(page, count, watch_row = nil, unjoined = 0)
    rows = Array.new(count) { |index| span_row(page, index) }
    items = rows.map { |row| Item.new(row[:source_span_id]) }
    physical = Array.new(unjoined) { |index| unjoined_row(index) }
    first_line = @lines.length
    spend = lambda { |*_args| @clock.now += ROW_SECONDS; true }
    IMP::Svg3DTextRenderer.stub(:finalize_source_evidence!, spend) do
      IMP::Svg3DTextRenderer.stub(:finalize_source_unit_evidence!, spend) do
        IMP.record_svg_3d_text_delivery!(
          {}, page, items,
          { :span_results => rows, :unmatched_source_results => physical },
          :text3d, {}, 0.0
        )
      end
    end
    watch_row.nil? ? nil : @lines[first_line + watch_row]
  end

  def test_page_two_time_left_is_measured_on_page_two
    run = controller([1, 2])
    line = nil
    within_import(run) do
      run.checkpoint!(:page_parse, :page => 1)
      evidence_pass(1, 100)
      @clock.now += 200.0 # the rest of page 1, then page 2 up to its text
      run.checkpoint!(:page_parse, :page => 2)
      @clock.now += 30.0
      line = evidence_pass(2, 100, 10)
    end
    # 90 rows left at 0.5 s each.
    assert_equal 'Importing page 2 of 2: checking text 10 of 100 ' \
                 '(about 45 s left), press Esc to cancel', line
    evidence = @snapshots.select { |snap| snap[:stage] == :text_evidence }
    assert_equal [1, 2], evidence.map { |snap| snap[:page] }.uniq,
                 'every evidence point names its own page'
  end

  def test_a_second_evidence_pass_on_the_same_page_has_its_own_time_left
    run = controller([1])
    early = nil
    line = nil
    within_import(run) do
      run.checkpoint!(:page_parse, :page => 1)
      evidence_pass(1, 100)
      @clock.now += 30.0 # step-downs before the second evidence pass
      before = @lines.length
      line = evidence_pass(1, 40, 8)
      early = @lines[before + 2]
    end
    assert_equal 'Importing page 1 of 1: checking text 2 of 40, ' \
                 'press Esc to cancel', early,
                 'no time left until this pass has run 2 s'
    # 32 rows left at 0.5 s each.
    assert_equal 'Importing page 1 of 1: checking text 8 of 40 ' \
                 '(about 15 s left), press Esc to cancel', line
  end

  def test_unjoined_glyph_evidence_names_the_page_too
    run = controller([3, 4])
    within_import(run) do
      run.checkpoint!(:page_parse, :page => 3)
      evidence_pass(4, 2, nil, 2)
    end
    evidence = @snapshots.select { |snap| snap[:stage] == :text_evidence }
    assert_equal [[0, 4], [1, 4], [2, 4], [3, 4]],
                 evidence.map { |snap| [snap[:completed], snap[:total]] }
    assert_equal [4], evidence.map { |snap| snap[:page] }.uniq
    assert_match(/\AImporting page 4 \(2 of 2\): checking text 3 of 4/,
                 @lines.last)
  end

  def test_text_step_down_progress_names_the_page
    run = controller([1, 2])
    within_import(run) do
      run.checkpoint!(:page_parse, :page => 1)
      IMP.stub(:prepare_item_page_match_and_peer_boxes, [nil, nil, nil, nil]) do
        # No source item for the proof: the step-down stops right after its
        # progress point, which is all this test needs.
        assert_raises(IMP::RepresentationFidelity::ContractError) do
          IMP.complete_text3d_item_fallbacks!(
            {}, nil, nil, 'made-up.pdf', 2, [], [0, 0, 100, 100],
            [0, 0, 100, 100], 0, {}, Time.now, 0.0, { :svg => '' },
            [{ :source_span_id => 'text_span:2:0' }]
          )
        end
      end
    end
    step = @snapshots.last
    assert_equal :text_step_down, step[:stage]
    assert_equal 2, step[:page]
    assert_equal 'Importing page 2 of 2: stepping down text that did not ' \
                 'build 0 of 1, press Esc to cancel', @lines.last
  end
end
