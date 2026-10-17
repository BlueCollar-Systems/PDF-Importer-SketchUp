require 'minitest/mock'
# Reuse the small host API fakes and run their existing stroke-union checks.
require_relative 'geometry_cleanup_collinear_coverage_test'

class GeometryCleanupFinalDuplicatesTest < Minitest::Test
  Cleanup = BlueCollarSystems::PDFVectorImporter::GeometryCleanup

  class Entities < GeometryCleanupCollinearCoverageTest::Entities
    def next_identity
      @next_identity = (@next_identity || 0) + 1
    end
    def vertex(coordinates)
      value = super
      unless value.respond_to?(:entityID)
        identity = next_identity
        value.define_singleton_method(:entityID) { identity }
      end
      value
    end
    def separate_line(first, last)
      vertices = [first, last].map do |coordinates|
        value = Sketchup::Vertex.new(Geom::Point3d.new(*coordinates))
        identity = next_identity
        value.define_singleton_method(:entityID) { identity }
        value
      end
      edge = Sketchup::Edge.new(*vertices)
      self << edge
      edge
    end
  end

  def duplicate_pair
    entities = Entities.new
    first = entities.line([0, 2, 0], [12, 2, 0])
    second = entities.line([12, 2, 0], [0, 2, 0])
    [entities, first, second]
  end

  def assert_source_union(entities)
    (0..12).each do |x|
      assert entities.live.any? { |edge|
        first, last = edge.start.position, edge.end.position
        point = Geom::Point3d.new(x, 2, 0)
        (first.distance(point) + point.distance(last) - first.distance(last)).abs < 1.0e-10
      }, "lost source point #{x}"
    end
  end

  def test_reversed_shared_vertex_duplicate_preserves_the_source_union
    entities, first, second = duplicate_pair
    assert_equal 1, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert_equal [first], entities.live
    refute second.valid?
    assert_source_union(entities)
    assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities)
  end

  def test_same_coordinates_with_distinct_native_vertices_are_preserved
    entities = Entities.new
    first = entities.line([0, 2, 0], [12, 2, 0])
    second = entities.separate_line([12, 2, 0], [0, 2, 0])
    assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert_equal [first, second], entities.live
    assert_source_union(entities)
  end

  def test_nearby_and_partially_overlapping_strokes_are_preserved
    entities = Entities.new
    entities.line([0, 2, 0], [12, 2, 0])
    entities.line([0, 2.000001, 0], [12, 2.000001, 0])
    entities.line([0, 2, 0], [7, 2, 0])
    assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert_equal 3, entities.live.length
    assert_source_union(entities)
  end

  def test_faces_curves_and_attributes_keep_their_ownership
    [:face, :curve, :attributes].each do |kind|
      entities, first, second = duplicate_pair
      case kind
      when :face then first.define_singleton_method(:faces) { [:source_face] }
      when :curve then first.curve = Object.new
      when :attributes then first.attributes = [{'source_span_id' => 'owned'}]
      end
      assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities), kind.to_s
      assert_equal [first, second], entities.live
    end
  end

  def test_distinct_full_native_styles_are_preserved
    [:layer, :material, :hidden, :soft, :smooth, :casts_shadows].each do |field|
      entities, first, second = duplicate_pair
      value = [:layer, :material].include?(field) ? :other_source : !first.public_send(field)
      second.public_send("#{field}=", value)
      assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities), field.to_s
      assert_equal [first, second], entities.live
    end
  end

  def test_multiple_styles_can_each_keep_one_exact_survivor
    entities, first, second = duplicate_pair
    second.material = :second_ink
    third = entities.line([0, 2, 0], [12, 2, 0])
    third.material = :second_ink
    assert_equal 1, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert_equal [first, second], entities.live
    assert_source_union(entities)
  end

  def test_source_width_ancestor_is_preserved_even_for_direct_sweep
    entities, first, second = duplicate_pair
    owner = GeometryCleanupCollinearCoverageTest::OwnedStroke.new(entities)
    definition = GeometryCleanupCollinearCoverageTest::Definition.new([owner])
    entities.define_singleton_method(:parent) { definition }
    assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert_equal [first, second], entities.live
  end

  def test_nonfinite_coordinates_and_missing_native_identity_are_not_erased
    entities, first, second = duplicate_pair
    first.end.position = Geom::Point3d.new(Float::INFINITY, 2, 0)
    assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert_equal [first, second], entities.live
    entities, first, second = duplicate_pair
    first.start.define_singleton_method(:entityID) { nil }
    assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert_equal [first, second], entities.live
  end

  def test_uncertain_native_erase_must_abort_the_caller_operation
    [:raise, :still_valid, :lost_survivor, :moved_survivor, :restyled_survivor].each do |failure|
      entities, first, second = duplicate_pair
      second.define_singleton_method(:erase!) do
        raise 'native erase failed' if failure == :raise
        @valid = false unless failure == :still_valid
        first.erase! if failure == :lost_survivor
        first.end.position = Geom::Point3d.new(20, 2, 0) if failure == :moved_survivor
        first.material = :changed if failure == :restyled_survivor
      end
      assert_raises(Cleanup::CleanupFailure, failure.to_s) do
        Cleanup.remove_exact_duplicate_loose_edges(entities)
      end
    end
  end

  def test_sweep_runs_after_both_late_geometry_mutations
    entities = Entities.new
    original = entities.line([0, 2, 0], [12, 2, 0])
    join = lambda { |target, _tol| target.line([0, 2, 0], [12, 2, 0]); 1 }
    bridge = lambda { |target, _tol| target.line([12, 2, 0], [0, 2, 0]); 1 }
    stats = nil
    Cleanup.stub(:join_collinear_edges, join) do
      Cleanup.stub(:close_face_gaps, bridge) do
        stats = Cleanup.cleanup(entities, :merge_tolerance => 0.0005)
      end
    end
    assert_equal 2, stats[:removed_dupes]
    assert_equal [original], entities.live
    assert_source_union(entities)
  end
end
