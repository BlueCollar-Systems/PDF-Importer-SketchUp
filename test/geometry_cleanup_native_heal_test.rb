require 'minitest/mock'
# Reuse the small host API fakes (and run their existing stroke-union checks).
require_relative 'geometry_cleanup_collinear_coverage_test'

# SketchUp heals when an erase leaves a vertex with exactly two edges and
# that vertex lies within its 0.001 in tolerance of the segment between their
# far ends: it merges them into one longer edge. Measured in SketchUp 2017 on a
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

  # SketchUp 2017 heals by distance, not by angle. Measured on made-up edges
  # in a throwaway group (2026-10-23): the two edges left at a vertex are
  # merged whenever the vertex lies within about 0.001 in of the segment
  # between their far ends, at any angle. It healed at 0.000999 in and never
  # at 0.0015 in or more. This fake heals everything closer than 0.0015 in,
  # the worst case that measurement leaves open. An angled heal moves the
  # vertex onto the far end, so the line is bent.
  class DistanceHealingEntities < HealingEntities
    HEAL_DISTANCE = 0.0015

    def collinear_junction?(vertex)
      pair = vertex.edges
      return false unless pair.length == 2
      first, last = far(pair[0], vertex), far(pair[1], vertex)
      return false if first.equal?(last)
      segment_distance(vertex.position, first.position, last.position) < HEAL_DISTANCE
    end

    def segment_distance(point, first, last)
      axis = last - first
      along = axis.dot(point - first) / axis.dot(axis)
      along = [[along, 0.0].max, 1.0].min
      nearest = Geom::Point3d.new(first.x + axis.x * along, first.y + axis.y * along,
                                  first.z + axis.z * along)
      point.distance(nearest)
    end
  end

  # A short segment V-W drawn twice, as on a flattened curve: the older
  # neighbour leaves V turning +turn+ radians from the segment's line, and W
  # is a free end. V lies length * sin(turn / 2) from the neighbour-W chord.
  def angled_shape(length, turn, heal = :older_grows)
    entities = DistanceHealingEntities.new(heal)
    v = [8.0, 3.0, 0.0]
    w = [8.0 - length, 3.0, 0.0]
    n = [8.0 + length * Math.cos(turn), 3.0 + length * Math.sin(turn), 0.0]
    neighbour = entities.line(n, v)
    kept = entities.line(v, w)
    duplicate = entities.line(w, v)
    [entities, kept, duplicate, neighbour]
  end

  ANGLED_LENGTHS = [0.005, 0.02, 0.05, 0.1, 1.0, 10.0].freeze
  ANGLED_TURNS = [0.0005, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1].freeze

  def ends_of(edge)
    [edge.start.position, edge.end.position].map(&:to_a_for_test)
  end

  def test_the_distance_fake_heals_and_bends_angled_junctions_like_the_host
    healed = 0
    ANGLED_LENGTHS.product(ANGLED_TURNS).each do |length, turn|
      entities, kept, duplicate, neighbour = angled_shape(length, turn)
      duplicate.erase!
      near = length * Math.sin(turn / 2.0) < DistanceHealingEntities::HEAL_DISTANCE
      label = "length #{length} turn #{turn}"
      assert_equal !near, kept.valid?, label
      next unless near
      healed += 1
      assert neighbour.valid?, label
      assert_equal 1, entities.live.length, label
      assert_includes ends_of(neighbour), [8.0 - length, 3.0, 0.0], label
    end
    assert_operator healed, :>=, 20
  end

  # Before this rule the precheck called these :none whenever the sine was
  # above 0.001, let the erase run, SketchUp merged the junction, and the
  # post-erase check raised CleanupFailure, which rolled the page back.
  def test_an_angled_junction_that_may_heal_keeps_both_copies
    [:older_grows, :newer_grows, :new_edge].each do |heal|
      ANGLED_LENGTHS.product(ANGLED_TURNS).each do |length, turn|
        entities, kept, duplicate, neighbour = angled_shape(length, turn, heal)
        before = entities.map { |edge| ends_of(edge) }
        gap = length * Math.sin(turn / 2.0)
        label = "#{heal} length #{length} turn #{turn} gap #{gap}"
        erased = Cleanup.remove_exact_duplicate_loose_edges(entities)
        assert [kept, neighbour].all?(&:valid?), label
        assert_equal before.values_at(0, 1), [ends_of(neighbour), ends_of(kept)], label
        if gap > Cleanup::HEAL_POSSIBLE_DISTANCE
          assert_equal 1, erased, label
          refute duplicate.valid?, label
        else
          assert_equal 0, erased, label
          assert duplicate.valid?, label
        end
      end
    end
  end

  # The trigger on real sheets: one short segment of a flattened arc drawn
  # twice. A straight duplicate on the same page is still swept.
  def test_a_duplicated_segment_on_a_flattened_curve_keeps_both_copies
    entities = DistanceHealingEntities.new
    points = (0..12).map do |step|
      angle = 0.01 * step
      [30.0 + 2.0 * Math.sin(angle), 10.0 - 2.0 * Math.cos(angle), 0.0]
    end
    arc = points.each_cons(2).map { |first, last| entities.line(first, last) }
    copy = entities.line(points[6], points[5])
    straight = entities.line([0, 0, 0], [4, 0, 0])
    entities.line([4, 0, 0], [7, 0, 0])
    straight_copy = entities.line([7, 0, 0], [4, 0, 0])
    entities.line([7, 0, 0], [7, 2, 0])
    before = arc.map { |edge| ends_of(edge) }
    assert_equal 1, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert arc.all?(&:valid?)
    assert_equal before, arc.map { |edge| ends_of(edge) }
    assert copy.valid?
    refute straight_copy.valid?
    assert straight.valid?
    assert_equal [[0.0, 0.0, 0.0], [7.0, 0.0, 0.0]], ends_of(straight)
  end

  # An other edge lying along the kept edge from the same vertex, in the
  # same direction and overlapping it, is no junction SketchUp merges: on
  # the host, erasing such a duplicate changed nothing else. Made-up lengths.
  def test_a_same_direction_overlap_is_swept_without_a_heal
    [HealingEntities, DistanceHealingEntities].product([1.25, 3.5]).each do |kind, reach|
      label = "#{kind.name.split('::').last} overlap to #{reach}"
      entities = kind.new
      overlap = entities.line([0, 3, 0], [reach, 3, 0])
      kept = entities.line([0, 3, 0], [2, 3, 0])
      duplicate = entities.line([2, 3, 0], [0, 3, 0])
      entities.line([2, 3, 0], [2, 7, 0])
      entities.line([2, 3, 0], [2, -1, 0])
      before = entities.map { |edge| ends_of(edge) }
      assert_equal 1, Cleanup.remove_exact_duplicate_loose_edges(entities), label
      refute duplicate.valid?, label
      assert kept.valid?, label
      assert overlap.valid?, label
      assert_equal 4, entities.live.length, label
      survivors = entities.each_with_index.reject { |edge, _| edge.equal?(duplicate) }
      survivors.each { |edge, index| assert_equal before[index], ends_of(edge), label }
      assert_equal 0, exact_pairs(entities), label
    end
  end

  def test_the_heal_precheck_decides_by_distance_from_the_chord
    far = lambda { |length, turn| [length * Math.cos(turn), length * Math.sin(turn), 0.0] }
    [[[-1.0, 0, 0], [1.0, 0, 0], :joins],
     [[-1.0, 0, 0], far.call(1.0, 0.002), :uncertain],
     [[-0.02, 0, 0], far.call(0.02, 0.1), :uncertain],
     [[-1.0, 0, 0], far.call(1.0, 0.005), :none],
     [[-10.0, 0, 0], far.call(10.0, 0.0005), :none],
     [[2.0, 0, 0], [1.25, 0, 0], :none],
     [[2.0, 0, 0], [3.5, 0, 0], :none],
     [[-1.0, 0, 0], [0, 1.0, 0], :none]].each do |kept_end, other_end, expected|
      entities = Base.new
      kept = entities.line([0, 0, 0], kept_end)
      other = entities.line(other_end, [0, 0, 0])
      vertex = entities.vertex([0, 0, 0])
      assert_equal expected, Cleanup.native_heal_relation(kept, other, vertex),
                   "#{kept_end.inspect} #{other_end.inspect}"
    end
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

  def exact_pairs(entities)
    signatures = entities.live.map { |edge| Cleanup.exact_loose_edge_signature(edge) }.compact
    signatures.length - signatures.uniq.length
  end

  # A heal can grow an edge onto two vertices that another same-style edge
  # already joins. Here a long stroke F-W lies over neighbour F-V and the
  # kept V-W, with a branch at W, so the heal at V makes a second F-W. A
  # host count on a handrail sheet found one exact pair left after the
  # sweep; this made-up shape left one too, until the edges around each
  # erase were checked again under their new vertices.
  def test_a_heal_that_makes_a_new_exact_pair_is_swept_in_the_same_pass
    [:older_grows, :newer_grows, :new_edge].each do |heal|
      [:long_first, :long_last].each do |order|
        label = "#{heal} #{order}"
        entities = HealingEntities.new(heal)
        long = entities.line([0, 3, 0], [12, 3, 0]) if order == :long_first
        entities.line([0, 3, 0], [5, 3, 0])
        entities.line([5, 3, 0], [12, 3, 0])
        duplicate = entities.line([12, 3, 0], [5, 3, 0])
        entities.line([12, 3, 0], [12, 9, 0])
        long = entities.line([0, 3, 0], [12, 3, 0]) if order == :long_last
        assert_equal 2, Cleanup.remove_exact_duplicate_loose_edges(entities), label
        refute duplicate.valid?, label
        assert_equal 0, exact_pairs(entities), "#{label}: an exact duplicate pair is left"
        assert_equal 2, entities.live.length, label
        (0..12).each { |x| assert covered?(entities, x, 3, long), "#{label} lost x=#{x}" }
        (3..9).each { |y| assert covered?(entities, 12, y, long), "#{label} lost y=#{y}" }
        entities.live.each do |edge|
          [edge.start.position, edge.end.position].each do |point|
            inside = (point.y == 3 && point.x >= 0 && point.x <= 12) ||
                     (point.x == 12 && point.y >= 3 && point.y <= 9)
            assert inside, "#{label} drew outside the source: #{point.x},#{point.y}"
          end
        end
        assert_equal 0, Cleanup.remove_exact_duplicate_loose_edges(entities), label
      end
    end
  end

  # A native erase never adds edges. A host that did, making a fresh copy
  # each time a copy is erased, must still not keep the sweep running.
  class CopyingEntities < HealingEntities
    def line(first, last)
      edge = super
      owner = self
      healing_erase = edge.method(:erase!)
      edge.define_singleton_method(:erase!) do
        healing_erase.call
        owner.line(first, last)
      end
      edge
    end
  end

  def test_rechecks_end_even_if_every_erase_made_a_new_copy
    entities = CopyingEntities.new(:none)
    kept = entities.line([0, 3, 0], [6, 3, 0])
    entities.line([6, 3, 0], [0, 3, 0])
    entities.line([6, 3, 0], [6, 9, 0])
    swept = entities.length
    assert_equal swept + 1, Cleanup.remove_exact_duplicate_loose_edges(entities)
    assert kept.valid?
    assert_equal 1, exact_pairs(entities)
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
