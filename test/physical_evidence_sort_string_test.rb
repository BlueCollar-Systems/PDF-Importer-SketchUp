#!/usr/bin/env ruby
# 3D Text evidence readback: same bytes, same hashes, cheaper ordering.
#
# Every glyph face and edge payload is still read and encoded once per glyph
# definition. What changed is how payloads are put in canonical byte order:
# small payloads are encoded once as one exact string and sorted natively
# instead of being compared chunk by chunk in Ruby, repeated number tokens are
# reused, and a call without a cache reads each shared definition once.
# The golden hashes below were produced by v3.7.180 + PR #118 (86dce48) on
# these same made-up solids, so an unchanged hash proves an unchanged
# evidence decision.
#
# All fixtures are made up: regular polygons, nothing from a real drawing.

require 'minitest/autorun'
require 'json'
require 'digest'

module Sketchup; end unless defined?(Sketchup)
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/representation_fidelity'

module MadeUpSolids
  class Pt
    attr_reader :x, :y, :z
    def initialize(x, y, z)
      @x = x
      @y = y
      @z = z
    end
  end

  class Box
    attr_reader :min, :max
    def initialize(points)
      @min = Pt.new(points.map(&:x).min, points.map(&:y).min, points.map(&:z).min)
      @max = Pt.new(points.map(&:x).max, points.map(&:y).max, points.map(&:z).max)
    end
  end

  class Vertex
    attr_reader :position
    def initialize(point)
      @position = point
    end
  end

  class Layer
    attr_reader :name
    def initialize(name)
      @name = name
    end

    def visible?
      true
    end
  end
  LAYER = Layer.new('Made Up Layer')

  class Collection
    attr_reader :reads
    def initialize(values)
      @values = values
      @reads = 0
    end

    def to_a
      @reads += 1
      @values.dup
    end
  end

  class Entity
    @@next_id = 7000
    attr_reader :entityID, :persistent_id
    def initialize
      @@next_id += 1
      @entityID = @@next_id
      @persistent_id = @@next_id + 100_000
    end

    def valid?; true; end
    def deleted?; false; end
    def hidden?; false; end
    def visible?; true; end
    def layer; LAYER; end
    def casts_shadows?; true; end
    def receives_shadows?; true; end
    def material; nil; end
  end

  class Edge < Entity
    attr_reader :start, :end
    def initialize(a, b)
      super()
      @start = a
      @end = b
    end

    def typename; 'Edge'; end
    def bounds; Box.new([@start.position, @end.position]); end
    def soft?; false; end
    def smooth?; false; end
  end

  class Loop
    attr_reader :vertices
    def initialize(vertices)
      @vertices = vertices
    end
  end

  class Face < Entity
    attr_reader :loops
    def initialize(loops)
      super()
      @loops = loops
    end

    def typename; 'Face'; end
    def bounds; Box.new(@loops[0].vertices.map(&:position)); end
    def back_material; nil; end
  end

  class Matrix
    def initialize(values)
      @values = values
    end

    def to_a
      @values.dup
    end
  end

  class Group < Entity
    attr_reader :entities
    def initialize(children)
      super()
      @entities = Collection.new(children)
    end

    def typename; 'Group'; end

    def transformation
      Matrix.new([1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0])
    end

    def bounds
      points = []
      @entities.to_a.each do |child|
        next unless child.respond_to?(:bounds) && !child.is_a?(Instance)
        box = child.bounds
        points << box.min << box.max
      end
      points.empty? ? nil : Box.new(points)
    end
  end

  class Definition
    attr_reader :entities
    def initialize(children)
      @entities = Collection.new(children)
    end
  end

  class Instance < Entity
    attr_reader :definition
    def initialize(definition, values)
      super()
      @definition = definition
      @values = values
    end

    def typename; 'ComponentInstance'; end
    def transformation; Matrix.new(@values); end
  end

  # An extruded regular polygon (optionally with a square hole): two caps,
  # one quad per side, three edges per side. Coordinates are irrational-ish
  # so the canonical rounding and number tokens are exercised.
  def self.glyph(sides, radius, depth, hole)
    rings = [Array.new(sides) do |index|
      angle = (2.0 * Math::PI * index / sides) + (0.1 * sides)
      Pt.new(Math.cos(angle) * radius, Math.sin(angle) * radius, 0.0)
    end]
    if hole
      rings << [[-1, -1], [1, -1], [1, 1], [-1, 1]].map do |sx, sy|
        Pt.new(sx * radius / 5.0, sy * radius / 7.0, 0.0)
      end
    end
    ring_vertices = rings.map do |ring|
      [ring.map { |point| Vertex.new(point) },
       ring.map { |point| Vertex.new(Pt.new(point.x, point.y, depth)) }]
    end
    entities = []
    entities << Face.new(ring_vertices.map { |bottom, _top| Loop.new(bottom) })
    entities << Face.new(ring_vertices.map { |_bottom, top| Loop.new(top.reverse) })
    ring_vertices.each do |bottom, top|
      count = bottom.length
      count.times do |index|
        other = (index + 1) % count
        entities << Face.new([Loop.new([bottom[index], bottom[other], top[other], top[index]])])
        entities << Edge.new(bottom[index], bottom[other])
        entities << Edge.new(top[index], top[other])
        entities << Edge.new(bottom[index], top[index])
      end
    end
    # A host does not keep entities in any canonical order.
    Definition.new([Group.new(entities.each_with_index.sort_by { |_e, i| (i * 7) % 11 }.map(&:first))])
  end

  def self.page
    definitions = [
      glyph(5, 0.0731, 0.0625, false), glyph(7, 0.0412, 0.0625, true),
      glyph(9, 0.1007, 0.0625, false), glyph(12, 0.0555, 0.0625, true),
      glyph(4, 0.0333, 0.0625, false), glyph(6, 0.0871, 0.03125, false)
    ]
    groups = Array.new(4) do |group_index|
      Group.new(Array.new(3) do |slot|
        definition = definitions[(group_index * 3 + slot) % definitions.length]
        Instance.new(definition, [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0,
                                  0.137 * (slot + 1) + group_index, 1.0 / 3.0 * group_index, 0, 1.0])
      end)
    end
    [definitions, groups]
  end
end

class PhysicalEvidenceSortStringTest < Minitest::Test
  RF = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity

  # v3.7.180 + #118 (86dce48) on MadeUpSolids.page: [geometry, style, count]
  # per group through the importer's cached path (shared caches and root
  # style keys, as record_svg_3d_text_delivery! calls it).
  GOLDEN = [
    %w[bde5c3c036a74f8059c1cef7d58392e32bc50d31afb1a53dc065abffb81c65a4
       492b52fda4cc81f92ed673b0350210ce81c1aa93dad0f84bafa5686c5823260b],
    %w[5f78b79f509ceed6ce93d568128f97ed76f5ca8204da407ba580b98ccf8e1128
       5655b4a224f038c0cc19229fdb0b3e39480f09ba9908f0bc66156aa97377b077],
    %w[1a3cb598de4efad6d54e5017a43a8597bf68c61c132b74be51d1e257dd0c2f9f
       492b52fda4cc81f92ed673b0350210ce81c1aa93dad0f84bafa5686c5823260b],
    %w[15519de0201debaa1b65a482e5b12a2cb80047d5a63fd13e6918b8964ff13b5e
       5655b4a224f038c0cc19229fdb0b3e39480f09ba9908f0bc66156aa97377b077]
  ].freeze
  GOLDEN_COUNTS = [113, 117, 113, 117].freeze

  def importer_path_evidence(groups)
    definition_cache = {}
    json_cache = {}
    groups.map do |group|
      keys = {}
      group.entities.to_a.each { |instance| keys[instance.definition.object_id] = true }
      RF.physical_evidence([group], definition_cache, json_cache, keys)
    end
  end

  def test_cached_importer_path_hashes_match_the_previous_release
    _definitions, groups = MadeUpSolids.page
    importer_path_evidence(groups).each_with_index do |evidence, index|
      assert_equal GOLDEN[index][0], evidence[:physical_geometry_sha256], "group #{index} geometry"
      assert_equal GOLDEN[index][1], evidence[:physical_style_sha256], "group #{index} style"
      assert_equal GOLDEN_COUNTS[index], evidence[:physical_entity_count], "group #{index} count"
    end
  end

  def test_uncached_recheck_hashes_match_and_each_definition_is_read_once
    definitions, groups = MadeUpSolids.page
    groups.each_with_index do |group, index|
      evidence = RF.physical_evidence([group])
      assert_equal GOLDEN[index][0], evidence[:physical_geometry_sha256]
      assert_equal GOLDEN[index][1], evidence[:physical_style_sha256]
      assert_equal GOLDEN_COUNTS[index], evidence[:physical_entity_count]
    end
    # Group 0 places definitions 0, 1, 2; group 2 places 0, 1, 2 again.
    # Each call reads each definition it places once, never once per
    # placement.
    reads = definitions.map { |definition| definition.entities.reads }
    assert_equal [2, 2, 2, 2, 2, 2], reads
  end

  def test_uncached_recheck_reads_a_repeated_glyph_once_not_once_per_placement
    definition = MadeUpSolids.glyph(8, 0.05, 0.0625, true)
    instances = Array.new(5) do |index|
      MadeUpSolids::Instance.new(definition, [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0,
                                              0.11 * index, 0.0, 0, 1.0])
    end
    group = MadeUpSolids::Group.new(instances)
    full_walk = RF.physical_evidence_from_trees([RF.physical_entity_tree(group)])
    reads_before = definition.entities.reads
    assert_equal 5, reads_before, 'the reference walk reads every placement'
    assert_equal full_walk, RF.physical_evidence([group])
    assert_equal 1, definition.entities.reads - reads_before,
                 'one fresh read of the shared glyph per recheck'
  end

  def test_uncached_recheck_equals_the_full_per_placement_walk
    _definitions, groups = MadeUpSolids.page
    group = groups.first
    full_walk = RF.physical_evidence_from_trees([RF.physical_entity_tree(group)])
    assert_equal full_walk, RF.physical_evidence([group])
  end

  def test_a_changed_face_still_changes_the_hash
    definitions, groups = MadeUpSolids.page
    before = RF.physical_evidence([groups.first])
    face = definitions.first.entities.to_a.first.entities.to_a.find { |entity| entity.is_a?(MadeUpSolids::Face) }
    point = face.loops.first.vertices.first.position
    point.instance_variable_set(:@x, point.x + 1.0e-6)
    after = RF.physical_evidence([groups.first])
    refute_equal before[:physical_geometry_sha256], after[:physical_geometry_sha256]
    assert_equal before[:physical_style_sha256], after[:physical_style_sha256]
  end

  def chunk_order(values, cache = nil)
    values.sort_by { |value| RF.canonical_json_order_key(value, cache, false) }
  end

  def test_string_order_equals_canonical_byte_order
    samples = [
      { 'n' => 1 }, { 'n' => 1.0 }, { 'n' => 12 }, { 'n' => -1.5 },
      { 'n' => 1, 'z' => 0 }, { 'n' => 1.0e-09 }, { 'n' => 1.0 / 72.0 },
      { :children => [], :type => 'Edge', :bounds => nil },
      { :children => [{ :type => 'Face' }], :type => 'Group' },
      { 'a"b' => 'c\\d' }, { 'a' => 'é' }, { 'a' => nil }, { 'a' => true },
      { 'a' => false }, { 'a' => [[0.0, -0.0, 3]] }, { 'a' => [[0.0, 0.0, 3.0]] },
      { :x => :sym }, { 'x' => 'sym' }
    ]
    samples.permutation(2).first(40).each do |pair|
      list = pair + samples
      assert_equal JSON.generate(chunk_order(list).map { |v| RF.canonical_value(v) }),
                   JSON.generate(RF.sort_canonical_payloads(list).map { |v| RF.canonical_value(v) })
    end
    samples.each do |sample|
      assert_equal JSON.generate(RF.canonical_value(sample)), RF.canonical_json_sort_string(sample)
    end
  end

  def test_a_large_cached_fragment_keeps_the_streamed_comparison
    shared = Array.new(400) { |index| { :type => 'Edge', :n => index * 0.001 } }
    cache = {}
    RF.store_canonical_json_fragment!(shared, cache)
    assert_operator cache[shared.object_id][1].length, :>, RF::CANONICAL_SORT_STRING_LIMIT
    first = { :type => 'ComponentInstance', :children => shared, :transformation => [2.0] }
    second = { :type => 'ComponentInstance', :children => shared, :transformation => [1.0] }
    assert_nil RF.canonical_json_sort_string(first, cache),
               'a sort key must not copy a whole cached definition'
    sorted = RF.sort_canonical_payloads([first, second], cache)
    assert_equal [second, first].map(&:object_id), sorted.map(&:object_id)
    assert_equal chunk_order([first, second], cache).map(&:object_id), sorted.map(&:object_id)
  end

  def test_number_tokens_are_the_exact_canonical_bytes_and_bounded
    [0.0, -0.0, 1, 1.0, 12.5, -3.25, 1.0e-9, 4.9e-10, 1.0 / 72.0, 123_456.789_012_345,
     1.234567891234, 7.0e20, 2 ** 40].each do |value|
      assert_equal RF.canonical_json_scalar(RF.canonical_number(value)),
                   RF.canonical_number_token(value), value.inspect
    end
    assert_raises(RF::ContractError) { RF.canonical_number_token(Float::NAN) }
    (RF::CANONICAL_NUMBER_TOKEN_LIMIT + 5).times { |index| RF.canonical_number_token(index + 0.5) }
    assert_operator RF::CANONICAL_NUMBER_TOKENS.length, :<=, RF::CANONICAL_NUMBER_TOKEN_LIMIT
  end

  def test_point_order_is_the_old_text_order
    points = [[0.5, 0.25, 0.0], [-0.5, 2.0, 1.0], [12.0, 1.0e-5, 0.0], [1.5, 0.0, -0.0],
              [0.05, 3.0, 0.0], [0.5, 0.25, -1.0]].map { |x, y, z| MadeUpSolids::Pt.new(x, y, z) }
    old = points.map { |p| [p.x, p.y, p.z].map { |n| RF.canonical_number(n) } }.sort_by { |p| p.join(',') }
    assert_equal old, RF.ordered_points(points)
    assert_equal [], RF.ordered_points([])
  end

  def test_sorting_writes_the_cache_only_when_asked
    values = [{ :type => 'Edge', :n => 2.0 }, { :type => 'Edge', :n => 1.0 }]
    cache = {}
    RF.sort_canonical_payloads(values, cache, false)
    assert_empty cache
    RF.sort_canonical_payloads(values, cache, true)
    assert_equal values.map { |v| JSON.generate(RF.canonical_value(v)) },
                 values.map { |v| cache[v.object_id][1] }
  end
end
