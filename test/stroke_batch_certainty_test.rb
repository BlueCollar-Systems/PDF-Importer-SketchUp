require_relative 'geometry_builder_staging_test'

# Native API doubles; the queue, coverage, style and cancellation paths are real.
class StrokeBatchCertaintyTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Builder = IMP::GeometryBuilder
  Base = GeometryBuilderStagingTest

  class Entities < Base::Entities
    attr_accessor :response, :line_returns_nil
    attr_reader :native_calls, :line_calls, :build_calls

    def initialize
      super(false)
      @native_calls = @line_calls = @build_calls = 0
    end

    def advertise_build!
      holder = self
      define_singleton_method(:build) do |&block|
        @build_calls += 1
        bulk = Object.new
        bulk.define_singleton_method(:add_edges) { |points| holder.add_edges(points) }
        block.call(bulk)
      end
    end

    def add_edges(points)
      @native_calls += 1
      raise response if response.is_a?(Exception)
      raise 'native add_edges unavailable before mutation' if response == :no_change_error
      if response == :partial_error
        append_edge(points[0], points[1])
        raise 'native error after partial mutation'
      end
      return response.call(self, points) if response.respond_to?(:call)
      super(points)
    end

    def add_line(a, b)
      @line_calls += 1
      return nil if line_returns_nil
      append_edge(a, b)
    end

    def append_edge(a, b)
      edge = Base::Edge.new(a, b)
      @items << edge
      edge
    end
  end

  class Controller
    def initialize(error, phase, item_index = nil, comparator_only = false)
      @error, @phase, @item_index = error, phase, item_index
      @comparator_only = comparator_only
    end
    def checkpoint!(stage, detail)
      return unless stage == :stroke_edge_flush && detail[:phase] == @phase
      return if @item_index && detail[:item_index] != @item_index
      return if @comparator_only && !detail.key?(:comparison_index)
      raise @error
    end
  end

  def p3(x, y = 0)
    Geom::Point3d.new(x, y, 0)
  end

  def fixture(controller = nil)
    model = Base::Model.new
    entities = Entities.new
    model.instance_variable_set(:@active_entities, entities)
    builder = Builder.new(model, [], [], [0, 0, 100, 80],
                          :merge_tolerance => 0, :run_controller => controller)
    style = builder.send(:source_stroke_style, [1, 0, 0])
    [entities, builder, style]
  end

  def queue(builder, entities, points, style)
    builder.send(:draw_edges, entities, points, nil, nil, nil, false, style)
  end

  def flush(builder)
    builder.send(:flush_stroke_edge_batches!)
  end

  def test_host_without_build_keeps_the_verified_add_edges_route
    entities, builder, style = fixture
    refute entities.respond_to?(:build)
    queue(builder, entities, [p3(0), p3(1), p3(2)], style)
    assert flush(builder)
    assert_equal 0, entities.build_calls
    assert_equal 1, entities.native_calls
    assert_equal 2, entities.length
    assert entities.to_a.all? { |e| e.material == style[:material] }
  end

  def test_advertised_build_covers_source_and_does_not_retry
    entities, builder, style = fixture
    entities.advertise_build!
    queue(builder, entities, [p3(0), p3(1), p3(2)], style)
    assert flush(builder)
    assert_equal 1, entities.build_calls
    assert_equal 1, entities.native_calls
    assert_equal 2, entities.length
    assert entities.to_a.all? { |edge| edge.material == style[:material] }

    entities, builder, style = fixture
    entities.advertise_build!
    entities.response = proc do |es, _points|
      [es.append_edge(p3(0), p3(0.25)), es.append_edge(p3(0.5), p3(1))]
    end
    queue(builder, entities, [p3(0), p3(1)], style)
    assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
    assert_equal 0, entities.line_calls
    assert entities.to_a.all? { |edge| edge.material.nil? }

    entities, builder, style = fixture
    entities.advertise_build!
    entities.response = :no_change_error
    queue(builder, entities, [p3(0), p3(1)], style)
    error = assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
    assert_match(/Entities#build/, error.message)
    assert_equal 0, entities.line_calls
    assert_equal 1, entities.build_calls

    entities, builder, style = fixture
    entities.advertise_build!
    old = entities.append_edge(p3(10), p3(11))
    foreign = Base::Material.new
    old.material = foreign
    entities.response = :partial_error
    queue(builder, entities, [p3(0), p3(1)], style)
    assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
    assert_equal 0, entities.line_calls
    assert_includes entities.to_a, old
    assert_same foreign, old.material
    assert_nil entities.to_a.last.material

    error = IMP::ImportRunControl::ImportCancelled.new([1], 2, { :stage => :build })
    entities, builder, style = fixture
    entities.advertise_build!
    entities.response = error
    queue(builder, entities, [p3(0), p3(1)], style)
    actual = assert_raises(IMP::ImportRunControl::ImportCancelled) { flush(builder) }
    assert_same error, actual
    assert_equal 0, entities.line_calls
    assert_equal 1, entities.build_calls
    assert_empty builder.instance_variable_get(:@stroke_edge_batches)
  end

  def test_mixed_valid_and_nil_cannot_silently_drop_nonzero_source
    entities, builder, style = fixture
    entities.response = proc do |es, points|
      [es.append_edge(points[0], points[1]), nil]
    end
    queue(builder, entities, [p3(0), p3(1), p3(2)], style)
    error = assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
    assert_match(/omitted a nonzero/, error.message)
    refute_kind_of IMP::ImportRunControl::ResumeMismatch, error
    assert_equal 0, entities.line_calls
    assert_nil entities.to_a.first.material
  end

  def test_empty_short_and_unknown_return_rosters_are_not_success
    [[], :short, Object.new].each do |outcome|
      entities, builder, style = fixture
      entities.response = proc do |es, points|
        first = es.append_edge(points[0], points[1])
        outcome == :short ? [first] : outcome
      end
      queue(builder, entities, [p3(0), p3(1), p3(2)], style)
      assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
      assert_equal 0, entities.line_calls
      assert_nil entities.to_a.first.material
    end
  end

  def test_literal_repeated_endpoint_nil_is_bound_to_its_exact_api_slot
    entities, builder, style = fixture
    entities.response = proc do |es, points|
      [nil, es.append_edge(points[1], points[2])]
    end
    queue(builder, entities, [p3(0), p3(0), p3(1)], style)
    assert flush(builder)
    assert_equal 1, entities.length
    assert_same style[:material], entities.to_a.first.material
  end

  def test_nil_at_a_nonzero_slot_is_not_excused_by_another_repeated_endpoint
    entities, builder, style = fixture
    entities.response = proc do |es, points|
      [es.append_edge(points[0], points[1]), nil]
    end
    queue(builder, entities, [p3(0), p3(0), p3(1)], style)
    assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
  end

  def test_genuine_tiny_source_segment_is_not_deleted_or_rounded_away
    entities, builder, style = fixture
    points = [p3(0), p3(1.0e-12)]
    entities.response = proc { |_es, _points| [nil] }
    queue(builder, entities, points, style)
    assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
    assert_equal 0, builder.instance_variable_get(:@merge_tol)
    assert_equal 1.0e-12, points[1].x
    assert_equal 0, entities.line_calls
  end

  def test_exact_native_split_intervals_preserve_complete_source
    entities, builder, style = fixture
    entities.response = proc do |es, _points|
      [es.append_edge(p3(0), p3(0.25)), es.append_edge(p3(0.25), p3(1))]
    end
    queue(builder, entities, [p3(0), p3(1)], style)
    assert flush(builder)
    assert_equal 2, entities.length
    assert entities.to_a.all? { |e| e.material == style[:material] }
  end

  def test_exact_collinear_coalescing_preserves_complete_source
    entities, builder, style = fixture
    entities.response = proc { |es, _points| [es.append_edge(p3(0), p3(2))] }
    queue(builder, entities, [p3(0), p3(1), p3(2)], style)
    assert flush(builder)
    assert_equal 1, entities.length
  end

  def test_uncovered_gap_and_unexplained_extra_interval_are_rejected
    [:gap, :extra].each do |kind|
      entities, builder, style = fixture
      entities.response = proc do |es, _points|
        if kind == :gap
          [es.append_edge(p3(0), p3(0.25)), es.append_edge(p3(0.5), p3(1))]
        else
          [es.append_edge(p3(0), p3(1)), es.append_edge(p3(2), p3(3))]
        end
      end
      queue(builder, entities, [p3(0), p3(1)], style)
      assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
      assert entities.to_a.all? { |e| e.material.nil? }
    end
  end

  def test_native_error_with_certain_empty_no_mutation_can_use_verified_line_route
    entities, builder, style = fixture
    entities.response = :no_change_error
    queue(builder, entities, [p3(0), p3(1), p3(2)], style)
    assert flush(builder)
    assert_equal 2, entities.line_calls
    assert_equal 2, entities.length
    assert entities.to_a.all? { |e| e.material == style[:material] }
  end

  def test_failed_line_fallback_is_not_reported_as_complete
    entities, builder, style = fixture
    entities.response = :no_change_error
    entities.line_returns_nil = true
    queue(builder, entities, [p3(0), p3(1)], style)
    assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
    assert_equal 1, entities.line_calls
  end

  def test_partial_native_error_does_not_retry_erase_or_recolor_existing_peer
    entities, builder, style = fixture
    old = entities.append_edge(p3(10), p3(11))
    foreign = Base::Material.new
    old.material = foreign
    entities.response = :partial_error
    queue(builder, entities, [p3(0), p3(1)], style)
    assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
    assert_equal 0, entities.line_calls
    assert_includes entities.to_a, old
    assert_same foreign, old.material
    assert_nil entities.to_a.last.material
  end

  def test_terminal_native_cancel_is_same_object_and_never_line_fallback
    entities, builder, style = fixture
    error = IMP::ImportRunControl::ImportCancelled.new([1], 2, { :stage => :native })
    entities.response = error
    queue(builder, entities, [p3(0), p3(1)], style)
    actual = assert_raises(IMP::ImportRunControl::ImportCancelled) { flush(builder) }
    assert_same error, actual
    assert_equal 0, entities.line_calls
    assert_empty builder.instance_variable_get(:@stroke_edge_batches)
  end

  def test_cancel_before_native_flush_abandons_only_pending_queue
    error = IMP::ImportRunControl::ImportCancelled.new([1], 2, { :stage => :before_flush })
    entities, builder, style = fixture(Controller.new(error, :before_batch))
    queue(builder, entities, [p3(0), p3(1)], style)
    actual = assert_raises(IMP::ImportRunControl::ImportCancelled) { flush(builder) }
    assert_same error, actual
    assert_equal 0, entities.native_calls
    assert_empty builder.instance_variable_get(:@stroke_edge_batches)
  end

  def test_cancel_or_resume_mismatch_during_native_flush_never_retries
    [IMP::ImportRunControl::ImportCancelled, IMP::ImportRunControl::ResumeMismatch,
     IMP::ImportRunControl::RollbackFailure].each do |type|
      error = if type == IMP::ImportRunControl::ImportCancelled
                type.new([1], 2, { :stage => :native_flush })
              else
                type.new('stop during native flush')
              end
      entities, builder, style = fixture(Controller.new(error, :before_item, 32))
      33.times { |n| queue(builder, entities, [p3(0, n), p3(1, n)], style) }
      actual = assert_raises(type) { flush(builder) }
      assert_same error, actual
      assert_equal 32, entities.native_calls
      assert_equal 0, entities.line_calls
      assert_empty builder.instance_variable_get(:@stroke_edge_batches)
    end
  end

  def test_cancel_during_exact_coverage_preserves_exception_and_defers_styling
    error = IMP::ImportRunControl::ImportCancelled.new([1], 2, { :stage => :coverage })
    entities, builder, style = fixture(Controller.new(error, :coverage_scan))
    entities.response = proc do |es, _points|
      [es.append_edge(p3(0), p3(0.25)), es.append_edge(p3(0.25), p3(1))]
    end
    queue(builder, entities, [p3(0), p3(1)], style)
    actual = assert_raises(IMP::ImportRunControl::ImportCancelled) { flush(builder) }
    assert_same error, actual
    assert_equal 0, entities.line_calls
    assert entities.to_a.all? { |e| e.material.nil? }
    assert_empty builder.instance_variable_get(:@stroke_edge_batches)
  end

  def test_material_setter_terminal_error_is_not_relabelled_as_style_failure
    entities, builder, style = fixture
    error = IMP::ImportRunControl::ImportCancelled.new([1], 2, { :stage => :style })
    entities.response = proc do |es, points|
      edge = es.append_edge(points[0], points[1])
      edge.define_singleton_method(:material=) { |_value| raise error }
      [edge]
    end
    queue(builder, entities, [p3(0), p3(1)], style)
    actual = assert_raises(IMP::ImportRunControl::ImportCancelled) { flush(builder) }
    assert_same error, actual
    assert_equal 0, entities.line_calls
    assert_empty builder.instance_variable_get(:@stroke_edge_batches)
  end

  def test_supporting_lines_distinguish_crossing_and_parallel_displaced_segments
    [:crossing, :parallel].each do |kind|
      entities, builder, style = fixture
      entities.response = proc do |es, _points|
        if kind == :crossing
          [es.append_edge(p3(0, 0), p3(1, 1)), es.append_edge(p3(1, 1), p3(2, 2)),
           es.append_edge(p3(0, 2), p3(2, 0))]
        else
          [es.append_edge(p3(0, 0), p3(1, 1)), es.append_edge(p3(1, 1), p3(2, 2)),
           es.append_edge(p3(0, 1.0e-12), p3(2, 2 + 1.0e-12))]
        end
      end
      queue(builder, entities, [p3(0, 0), p3(2, 2)], style)
      assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
      assert entities.to_a.all? { |edge| edge.material.nil? }
    end
  end

  def test_reversed_diagonal_and_z_axis_splits_preserve_source
    [[p3(4, 4), p3(0, 0), p3(2, 2)],
     [Geom::Point3d.new(0, 0, 4), Geom::Point3d.new(0, 0, 0),
      Geom::Point3d.new(0, 0, 2)]].each do |last, first, middle|
      entities, builder, style = fixture
      entities.response = proc do |es, _points|
        [es.append_edge(middle, first), es.append_edge(last, middle)]
      end
      queue(builder, entities, [first, last], style)
      assert flush(builder)
      assert_equal 2, entities.length
    end
  end

  def test_disconnected_collinear_intervals_do_not_fill_a_real_gap
    entities, builder, style = fixture
    entities.response = proc do |es, _points|
      [es.append_edge(p3(0), p3(1)), es.append_edge(p3(2), p3(3))]
    end
    queue(builder, entities, [p3(0), p3(3)], style)
    assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
  end

  def test_collinear_overlaps_and_duplicate_traversals_preserve_interval_union
    entities, builder, style = fixture
    entities.response = proc do |es, _points|
      [es.append_edge(p3(0), p3(0.75)), es.append_edge(p3(0.25), p3(1))]
    end
    queue(builder, entities, [p3(0), p3(1), p3(0.25), p3(0.75)], style)
    assert flush(builder)
    assert_equal 1, entities.native_calls
    assert_equal 2, entities.length
    assert entities.to_a.all? { |edge| edge.material == style[:material] }
  end

  def test_a_tiny_nonzero_interval_gap_is_never_rounded_closed
    entities, builder, style = fixture
    entities.response = proc do |es, _points|
      [es.append_edge(p3(0), p3(0.5)), es.append_edge(p3(0.5 + 1.0e-12), p3(1))]
    end
    queue(builder, entities, [p3(0), p3(1)], style)
    assert_raises(Builder::StrokeBatchFailure) { flush(builder) }
    assert entities.to_a.all? { |edge| edge.material.nil? }
    assert_equal 0, entities.line_calls
  end

  def test_many_split_intervals_keep_complete_source_without_size_cutoff
    entities, builder, style = fixture
    entities.response = proc do |es, _points|
      (0...2048).map { |n| es.append_edge(p3(n + 0.5), p3(n)) } +
        (0...2048).map { |n| es.append_edge(p3(n + 1), p3(n + 0.5)) }
    end
    queue(builder, entities, (0..2048).map { |n| p3(n) }, style)
    assert flush(builder)
    assert_equal 4096, entities.length
    assert entities.to_a.all? { |edge| edge.material == style[:material] }
  end

  def test_coincident_source_items_keep_multiplicity_order_and_later_style
    entities, builder, red = fixture
    blue = builder.send(:source_stroke_style, [0, 0, 1])
    retained = nil
    entities.response = proc do |es, points|
      retained ||= es.append_edge(points[0], points[1])
      [retained]
    end
    points = [p3(0), p3(1)]
    queue(builder, entities, points, red)
    queue(builder, entities, points.reverse, blue)
    assert flush(builder)
    assert_equal 2, entities.native_calls
    assert_equal 1, entities.length
    assert_same blue[:material], retained.material
    assert_equal 2, builder.instance_variable_get(:@edge_count)
  end

  def test_cancel_during_line_union_sort_or_merge_preserves_terminal_identity
    [:coverage_sort, :coverage_merge].each do |phase|
      error = IMP::ImportRunControl::ImportCancelled.new([1], 2, { :stage => phase })
      entities, builder, style = fixture(Controller.new(error, phase, nil, phase == :coverage_sort))
      entities.response = proc do |es, _points|
        [es.append_edge(p3(1), p3(0.5)), es.append_edge(p3(0), p3(0.5))]
      end
      queue(builder, entities, [p3(0), p3(1)], style)
      actual = assert_raises(IMP::ImportRunControl::ImportCancelled) { flush(builder) }
      assert_same error, actual
      assert_equal 0, entities.line_calls
      assert entities.to_a.all? { |edge| edge.material.nil? }
      assert_empty builder.instance_variable_get(:@stroke_edge_batches)
    end
  end

  def test_real_controller_flush_cancel_keeps_current_page_and_retained_pages
    controller = IMP::ImportRunControl::Controller.new(
      :pages => [1, 2], :requested_mode => :geometry,
      :clock => proc { 0.0 }, :cancel_probe => proc { true }
    )
    controller.retain_page!(1)
    entities, builder, style = fixture(controller)
    builder.instance_variable_set(:@page_number, 2)
    queue(builder, entities, [p3(0), p3(1)], style)
    error = assert_raises(IMP::ImportRunControl::ImportCancelled) { flush(builder) }
    assert_equal [1], error.retained_pages
    assert_equal 2, error.next_page
    assert_equal 2, error.snapshot[:page]
    assert_equal :stroke_edge_flush, error.snapshot[:stage]
    assert_equal 0, entities.native_calls
    assert_empty builder.instance_variable_get(:@stroke_edge_batches)
  end

  def test_checkpoint_default_page_does_not_replace_an_explicit_caller_page
    seen = []
    controller = Object.new
    controller.define_singleton_method(:checkpoint!) { |_stage, detail| seen << detail }
    _entities, builder, _style = fixture(controller)
    builder.send(:run_checkpoint!, :explicit_page, :page => 9)
    assert_equal 9, seen.first[:page]
  end

  def test_layer_setter_terminal_error_is_not_swallowed_by_best_effort_layering
    entities, builder, style = fixture
    error = IMP::ImportRunControl::RollbackFailure.new('uncertain host rollback')
    entities.response = proc do |es, points|
      edge = es.append_edge(points[0], points[1])
      edge.define_singleton_method(:layer=) { |_value| raise error }
      [edge]
    end
    builder.send(:draw_edges, entities, [p3(0), p3(1)], Base::Layer.new('test'),
                 nil, nil, false, style)
    actual = assert_raises(IMP::ImportRunControl::RollbackFailure) { flush(builder) }
    assert_same error, actual
    assert_nil entities.to_a.first.material
    assert_equal 0, entities.line_calls
    assert_empty builder.instance_variable_get(:@stroke_edge_batches)
  end
end
