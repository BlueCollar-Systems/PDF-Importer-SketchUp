require 'minitest/mock'
# Reuse the small host API fakes (and run their existing stroke-union checks).
require_relative 'geometry_cleanup_collinear_coverage_test'

# SketchUp heals when an erase leaves a vertex with exactly two collinear
# edges: it merges them into one longer edge. Measured in SketchUp 2017 on a
# handrail sheet (2026-10-23), 3 of the 7 duplicates the final sweep erased
# sat at such a vertex. The older neighbour grew over the kept edge and the
# kept object was deleted, although its segment was still drawn, so the old
# "the kept object must keep its exact signature" check stopped the page.
# These shapes are made up; they only copy that topology.
class GeometryCleanupNativeHealTest < Minitest::Test
  Cleanup = BlueCollarSystems::PDFVectorImporter::GeometryCleanup
  Base = GeometryCleanupCollinearCoverageTest::Entities
  STYLE_FIELDS = [:layer, :material, :hidden, :soft, :smooth, :casts_shadows].freeze

  class HealingEntities < Base
    attr_accessor :heal
    def initialize(heal = :older_grows)
      super()
      @heal = heal
      @made = 0
    end

    def vertex(coordinates)
      value = super
      unless value.respond_to?(:entityID)
        @made += 1
        identity = @made
        value.define_singleton_method(:entityID) { identity }
      end
      value
    end

    def line(first, last)
      edge = super
      @made += 1
      order = @made
      owner = self
      edge.define_singleton_method(:made) { order }
      edge.define_singleton_method(:erase!) do
        @valid = false
        ends = [start, self.end]
        ends.each { |point| point.detach(self) }
        ends.each { |point| owner.heal_at(point) }
      end
      edge
    end

    def far(edge, vertex)
      edge.start.equal?(vertex) ? edge.end : edge.start
    end

    def collinear_junction?(vertex)
      pair = vertex.edges
      return false unless pair.length == 2
      a = far(pair[0], vertex).position - vertex.position
      b = far(pair[1], vertex).position - vertex.position
      a.cross(b).length < 1.0e-9 * a.length * b.length && a.dot(b) < 0
    end

    def copy_style(from, to)
      STYLE_FIELDS.each do |field|
        reader = [:hidden, :soft, :smooth, :casts_shadows].include?(field) ? "#{field}?" : field
        to.public_send("#{field}=", from.public_send(reader))
      end
    end

    def regrow(edge, vertex, replacement)
      vertex.detach(edge)
      if edge.start.equal?(vertex)
        edge.instance_variable_set(:@start, replacement)
      else
        edge.instance_variable_set(:@end, replacement)
      end
      replacement.attach(edge)
    end

    def heal_at(vertex)
      return if @heal == :none || !collinear_junction?(vertex)
      older, newer = vertex.edges.sort_by(&:made)
      case @heal
      when :older_grows, :newer_grows, :restyled, :overreach, :lost
        grows, goes = @heal == :newer_grows ? [newer, older] : [older, newer]
        target = far(goes, vertex)
        goes.instance_variable_set(:@valid, false)
        goes.start.detach(goes)
        goes.end.detach(goes)
        if @heal == :overreach
          x, y, z = target.position.to_a_for_test
          target = vertex([x + (x < vertex.position.x ? -5 : 5), y, z])
        end
        regrow(grows, vertex, target) unless @heal == :lost
        grows.material = :changed_by_heal if @heal == :restyled
        grows.instance_variable_set(:@valid, false) if @heal == :lost
      when :new_edge
        a, b = far(older, vertex), far(newer, vertex)
        [older, newer].each do |edge|
          edge.instance_variable_set(:@valid, false)
          edge.start.detach(edge)
          edge.end.detach(edge)
        end
        merged = line(a.position.to_a_for_test, b.position.to_a_for_test)
        copy_style(older, merged)
      end
    end
  end

  def setup
    Geom::Point3d.send(:define_method, :to_a_for_test) { [x, y, z] } unless
      Geom::Point3d.method_defined?(:to_a_for_test)
  end

  # A short stroke drawn twice between the same two native vertices, with an
  # older same-style stroke continuing it on one side: the handrail shape.
  def handrail_shape(heal = :older_grows)
    entities = HealingEntities.new(heal)
    neighbour = entities.line([20, 3, 0], [8, 3, 0])
    kept = entities.line([8, 3, 0], [2, 3, 0])
    duplicate = entities.line([2, 3, 0], [8, 3, 0])
    branch = entities.line([2, 3, 0], [2, 9, 0])
    [entities, kept, duplicate, neighbour, branch]
  end

  def covered?(entities, x, y, style_of)
    point = Geom::Point3d.new(x, y, 0)
    entities.live.any? do |edge|
      first, last = edge.start.position, edge.end.position
      on = (first.distance(point) + point.distance(last) - first.distance(last)).abs < 1.0e-9
      on && STYLE_FIELDS.all? do |field|
        reader = [:hidden, :soft, :smooth, :casts_shadows].include?(field) ? "#{field}?" : field
        edge.public_send(reader) == style_of.public_send(reader)
      end
    end
  end

  def assert_handrail_drawn(entities, style_of)
    (2..20).each { |x| assert covered?(entities, x, 3, style_of), "lost stroke point x=#{x}" }
    (3..9).each { |y| assert covered?(entities, 2, y, style_of), "lost branch point y=#{y}" }
    entities.live.each do |edge|
      [edge.start.position, edge.end.position].each do |point|
        inside = (point.y == 3 && point.x >= 2 && point.x <= 20) ||
                 (point.x == 2 && point.y >= 3 && point.y <= 9)
        assert inside, "ink drawn outside the source strokes: #{point.x},#{point.y}"
      end
    end
  end

  def test_the_handrail_heal_no_longer_stops_the_page
    entities, kept, duplicate, neighbour, _branch = handrail_shape
    style_of = neighbour
    assert_equal 1, Cleanup.remove_exact_duplicate_loose_edges(entities)
    refute duplicate.valid?
    refute kept.valid?, 'the fake must heal the kept edge into its neighbour, as SketchUp 2017 did'
    assert neighbour.valid?
    assert_in_delta 18.0, neighbour.length, 1.0e-12
    assert_handrail_drawn(entities, style_of)
    assert_equal 2, entities.live.length
    assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities)
  end

  def test_every_heal_shape_keeps_the_strokes_and_their_style
    [:older_grows, :newer_grows, :new_edge, :none].each do |heal|
      entities, _kept, duplicate, neighbour, _branch = handrail_shape(heal)
      entities.each do |edge|
        edge.layer = :source_layer
        edge.material = :source_ink
        edge.hidden = true
        edge.casts_shadows = false
      end
      assert_equal 1, Cleanup.remove_exact_duplicate_loose_edges(entities), heal.to_s
      refute duplicate.valid?, heal.to_s
      assert_handrail_drawn(entities, neighbour)
      assert entities.live.all? { |edge| edge.material == :source_ink && edge.layer == :source_layer }
    end
  end

  def test_heals_at_both_ends_of_the_duplicate
    entities = HealingEntities.new
    left = entities.line([0, 5, 0], [4, 5, 0])
    entities.line([4, 5, 0], [9, 5, 0])
    duplicate = entities.line([9, 5, 0], [4, 5, 0])
    entities.line([9, 5, 0], [15, 5, 0])
    assert_equal 1, Cleanup.remove_exact_duplicate_loose_edges(entities)
    refute duplicate.valid?
    assert_equal 1, entities.live.length
    survivor = entities.live.first
    assert_equal [0.0, 15.0], [survivor.start.position.x, survivor.end.position.x].sort
    (0..15).each { |x| assert covered?(entities, x, 5, left), "lost x=#{x}" }
  end

  def test_a_heal_into_a_different_style_is_never_started
    STYLE_FIELDS.each do |field|
      entities, kept, duplicate, neighbour, _branch = handrail_shape
      value = [:layer, :material].include?(field) ? :other_source : !neighbour.public_send(
        [:hidden, :soft, :smooth, :casts_shadows].include?(field) ? "#{field}?" : field)
      neighbour.public_send("#{field}=", value)
      assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities), field.to_s
      assert [kept, duplicate, neighbour].all?(&:valid?), field.to_s
      assert_in_delta 12.0, neighbour.length, 1.0e-12
    end
  end

  def test_a_heal_into_an_owned_neighbour_is_never_started
    [:face, :curve, :attributes].each do |kind|
      entities, kept, duplicate, neighbour, _branch = handrail_shape
      case kind
      when :face then neighbour.define_singleton_method(:faces) { [:source_face] }
      when :curve then neighbour.curve = Object.new
      when :attributes then neighbour.attributes = [{ 'source_span_id' => 'owned' }]
      end
      assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities), kind.to_s
      assert [kept, duplicate, neighbour].all?(&:valid?), kind.to_s
    end
  end

  def test_a_nearly_straight_junction_keeps_both_copies
    entities = HealingEntities.new
    neighbour = entities.line([20, 3.00001, 0], [8, 3, 0])
    kept = entities.line([8, 3, 0], [2, 3, 0])
    duplicate = entities.line([2, 3, 0], [8, 3, 0])
    entities.line([2, 3, 0], [2, 9, 0])
    assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert [kept, duplicate, neighbour].all?(&:valid?)
  end

  def test_a_bent_or_branching_junction_has_nothing_to_heal
    entities = HealingEntities.new
    entities.line([8, 3, 0], [8, 10, 0])
    kept = entities.line([8, 3, 0], [2, 3, 0])
    duplicate = entities.line([2, 3, 0], [8, 3, 0])
    entities.line([2, 3, 0], [-4, 3, 0])
    entities.line([2, 3, 0], [2, 9, 0])
    assert_equal 1, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert kept.valid?
    refute duplicate.valid?
    assert_equal 4, entities.live.length
  end

  def test_a_heal_that_changes_moves_or_loses_ink_still_aborts
    [:restyled, :overreach, :lost].each do |heal|
      entities, = handrail_shape(heal)
      assert_raises(Cleanup::CleanupFailure, heal.to_s) do
        Cleanup.remove_exact_duplicate_loose_edges(entities)
      end
    end
  end

  def test_full_cleanup_finishes_when_a_late_duplicate_heals
    entities = HealingEntities.new
    neighbour = entities.line([20, 3, 0], [8, 3, 0])
    entities.line([8, 3, 0], [2, 3, 0])
    entities.line([2, 3, 0], [2, 9, 0])
    # The collinear join is where the measured duplicates appeared.
    join = lambda { |target, _tol| target.line([2, 3, 0], [8, 3, 0]); 1 }
    stats = nil
    Cleanup.stub(:join_collinear_edges, join) do
      Cleanup.stub(:close_face_gaps, lambda { |_target, _gap| 0 }) do
        stats = Cleanup.cleanup(entities, :merge_tolerance => 0.0005)
      end
    end
    assert_equal 1, stats[:removed_dupes]
    assert_handrail_drawn(entities, neighbour)
    assert_equal 2, entities.live.length
  end
end
