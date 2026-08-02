#!/usr/bin/env ruby

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def distance(other)
      dx = x - other.x.to_f
      dy = y - other.y.to_f
      dz = z - other.z.to_f
      Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    end

    # SketchUp 2017 treats points within its modeling tolerance as equal before
    # Entities#add_face validates a polygon.
    def ==(other)
      other.respond_to?(:x) && distance(other) < 0.001
    end
  end unless const_defined?(:Point3d)

  class Transformation
    attr_reader :scale, :origin, :translation, :matrix
    def initialize(value, origin = nil, translation = nil)
      if value.is_a?(Array) && value.length == 16
        @matrix = value.map { |entry| entry.to_f }
        @scale = 1.0
        @origin = nil
        @translation = @matrix.values_at(12, 13, 14)
      else
        @matrix = nil
        @scale = value.to_f
        @origin = origin
        @translation = translation
      end
    end
    def self.scaling(*args)
      return new(args[0]) if args.length == 1
      new(args[1], args[0])
    end
    def self.translation(values)
      new(1.0, nil, Array(values).map { |value| value.to_f })
    end

    def transform_point(point)
      return Geom::Point3d.new(
        point.x.to_f + Array(@translation).fetch(0, 0.0),
        point.y.to_f + Array(@translation).fetch(1, 0.0),
        point.z.to_f + Array(@translation).fetch(2, 0.0)
      ) unless @matrix

      x = point.x.to_f
      y = point.y.to_f
      z = point.z.to_f
      Geom::Point3d.new(
        (x * @matrix[0]) + (y * @matrix[4]) + (z * @matrix[8]) + @matrix[12],
        (x * @matrix[1]) + (y * @matrix[5]) + (z * @matrix[9]) + @matrix[13],
        (x * @matrix[2]) + (y * @matrix[6]) + (z * @matrix[10]) + @matrix[14]
      )
    end
  end unless const_defined?(:Transformation)
end

require 'bc_pdf_vector_importer/svg_3d_text_renderer'
require 'bc_pdf_vector_importer/import_run_control'

class Svg3DBounds
  attr_reader :min, :max

  def initialize(points)
    @min = Geom::Point3d.new(points.map(&:x).min, points.map(&:y).min,
                             points.map(&:z).min)
    @max = Geom::Point3d.new(points.map(&:x).max, points.map(&:y).max,
                             points.map(&:z).max)
  end
end

class Svg3DNormal
  attr_accessor :z
  def initialize(z = 1.0); @z = z; end
end

class Svg3DFace
  attr_reader :persistent_id, :pushpull_calls, :points

  def initialize(owner, id, points)
    @owner = owner
    @persistent_id = id
    @points = points
    @normal = Svg3DNormal.new(1.0)
    @depth = 0.0
    @pushpull_calls = []
  end

  def typename; 'Face'; end
  def normal; @normal; end
  def reverse!; @normal.z *= -1.0; self; end

  def pushpull(depth)
    @pushpull_calls << depth.to_f
    @depth = depth.to_f
  end

  def bounds
    raised = @points.map { |p| Geom::Point3d.new(p.x, p.y, @depth) }
    Svg3DBounds.new(@points + raised)
  end

  def erase!
    @owner.erase_entities(self)
    true
  end

  def scale_by!(factor, origin = nil)
    ox = origin ? origin.x.to_f : 0.0
    oy = origin ? origin.y.to_f : 0.0
    oz = origin ? origin.z.to_f : 0.0
    @points.each do |point|
      point.x = ox + ((point.x - ox) * factor.to_f)
      point.y = oy + ((point.y - oy) * factor.to_f)
      point.z = oz + ((point.z - oz) * factor.to_f)
    end
    @depth = oz + ((@depth - oz) * factor.to_f)
  end
end

class Svg3DEntities
  attr_reader :erased, :groups, :transform_entity_calls

  def initialize(options = {})
    @options = options
    @items = []
    @erased = []
    @groups = []
    @transform_entity_calls = []
    @next_id = options[:first_id] || 100
  end

  def next_id
    @next_id += 1
  end

  def to_a; @items.dup; end
  def model; @options[:model]; end

  def add_group
    group = Svg3DGroup.new(self, next_id, @options)
    @items << group
    @groups << group
    group
  end

  def add_instance(definition, transformation)
    instance = Svg3DInstance.new(
      self, next_id, definition, transformation, @options
    )
    @items << instance
    definition.register_instance(instance)
    instance
  end

  def add_face(points)
    raise 'synthetic face creation failure' if @options[:fail_add_face]
    if @options[:reject_host_equal_points]
      Array(points).each_with_index do |left, index|
        duplicate = Array(points)[(index + 1)..-1].to_a.any? do |right|
          left == right
        end
        raise ArgumentError, 'Duplicate points in array' if duplicate
      end
    end
    if @options[:translate_created_faces]
      dx, dy = @options[:translate_created_faces]
      points = Array(points).map do |point|
        Geom::Point3d.new(point.x + dx.to_f, point.y + dy.to_f, point.z)
      end
    end
    face = Svg3DFace.new(self, next_id, points)
    @items << face
    face
  end

  def erase_entities(*entities)
    entities.flatten.each do |entity|
      entity.erase_owned_children! if entity.respond_to?(:erase_owned_children!)
      @items.delete(entity)
      @groups.delete(entity)
      @erased << entity
    end
  end

  def erase_all!
    erase_entities(@items.dup)
  end


  def scale_by!(factor)
    @items.each do |entity|
      entity.scale_by!(factor) if entity.respond_to?(:scale_by!)
    end
  end

  def transform_entities(transformation, entities)
    @transform_entity_calls << [transformation, Array(entities).dup]
    Array(entities).each do |entity|
      entity.scale_by!(transformation.scale, transformation.origin) if
        entity.respond_to?(:scale_by!)
    end
    true
  end
end

class Svg3DGroup
  attr_accessor :name, :layer, :material
  attr_reader :persistent_id, :entities, :attributes, :transform_calls

  def initialize(owner, id, options)
    @owner = owner
    @persistent_id = id
    @options = options
    @entities = Svg3DEntities.new(options.merge(first_id: id * 100))
    @attributes = {}
    @transform_calls = []
    @transformation = nil
  end

  def typename; 'Group'; end

  def model; @options[:model]; end

  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end

  def bounds
    points = []
    @entities.to_a.each do |entity|
      next unless entity.respond_to?(:bounds)
      box = entity.bounds
      points << box.min << box.max
    end
    raise 'empty group bounds' if points.empty?
    if @transformation
      scale = @transformation.scale
      origin = @transformation.origin
      ox = origin ? origin.x.to_f : 0.0
      oy = origin ? origin.y.to_f : 0.0
      oz = origin ? origin.z.to_f : 0.0
      points = points.map do |point|
        Geom::Point3d.new(
          ox + ((point.x.to_f - ox) * scale),
          oy + ((point.y.to_f - oy) * scale),
          oz + ((point.z.to_f - oz) * scale)
        )
      end
    end
    Svg3DBounds.new(points)
  end

  def erase!
    @owner.erase_entities(self)
    true
  end

  def erase_owned_children!
    @entities.erase_all!
  end


  def transform!(transformation)
    @transform_calls << transformation
    @transformation = transformation
    self
  end
end

class Svg3DDefinition
  attr_reader :name, :entities, :instances

  def initialize(name, model, options = {})
    @name = name
    @entities = Svg3DEntities.new(options.merge(:model => model))
    @instances = []
  end

  def register_instance(instance)
    @instances << instance
  end

  def unregister_instance(instance)
    @instances.delete(instance)
  end
end

class Svg3DDefinitions
  def initialize(model, options = {})
    @model = model
    @options = options
    @items = []
  end

  def add(name)
    definition = Svg3DDefinition.new(name, @model, @options)
    @items << definition
    definition
  end

  def remove(definition)
    raise 'definition still has instances' unless definition.instances.empty?
    @items.delete(definition)
    true
  end

  def to_a
    @items.dup
  end
end

class Svg3DInstance
  attr_reader :persistent_id, :definition, :transformation

  def initialize(owner, id, definition, transformation, options)
    @owner = owner
    @persistent_id = id
    @definition = definition
    @transformation = transformation
    @options = options
  end

  def typename; 'ComponentInstance'; end
  def model; @options[:model]; end

  def bounds
    points = []
    @definition.entities.to_a.each do |entity|
      next unless entity.respond_to?(:bounds)
      box = entity.bounds
      low = box.min
      high = box.max
      [
        [low.x, low.y, low.z], [low.x, low.y, high.z],
        [low.x, high.y, low.z], [low.x, high.y, high.z],
        [high.x, low.y, low.z], [high.x, low.y, high.z],
        [high.x, high.y, low.z], [high.x, high.y, high.z]
      ].each do |x, y, z|
        points << transformed_point(Geom::Point3d.new(x, y, z))
      end
    end
    raise 'empty component instance bounds' if points.empty?
    Svg3DBounds.new(points)
  end

  def erase_owned_children!
    @definition.unregister_instance(self)
  end

  private

  def transformed_point(point)
    if @transformation.respond_to?(:transform_point)
      @transformation.transform_point(point)
    else
      values = Array(@transformation.translation)
      Geom::Point3d.new(
        point.x.to_f + values.fetch(0, 0.0),
        point.y.to_f + values.fetch(1, 0.0),
        point.z.to_f + values.fetch(2, 0.0)
      )
    end
  end
end

# Minimal host material fakes: a group painted with a named colored material
# is the render-weight evidence for delivered 3D text ink (ghosting RED).
class Svg3DMaterial
  attr_reader :name
  attr_accessor :color

  def initialize(name)
    @name = name
  end
end

class Svg3DMaterials
  def initialize
    @by_name = {}
  end

  def [](name)
    @by_name[name]
  end

  def add(name)
    @by_name[name] ||= Svg3DMaterial.new(name)
  end
end

class Svg3DModel
  attr_reader :materials, :definitions

  def initialize(options = {})
    @materials = Svg3DMaterials.new
    @definitions = if options[:with_definitions]
                     Svg3DDefinitions.new(self, options)
                   end
  end
end

module Sketchup
  class Color
    attr_reader :red, :green, :blue

    def initialize(red, green, blue)
      @red = red
      @green = green
      @blue = blue
    end
  end unless const_defined?(:Color)
end

Svg3DSpan = Struct.new(:text, :font_name, :source_span_id,
                       :bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1, :angle)

class SvgText3DRendererTest < Minitest::Test
  RENDERER = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer
  FIDELITY = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
  MEDIA_BOX = [0.0, 0.0, 100.0, 100.0].freeze

  def complete_source_context(page_number = 1)
    {
      importer_id: FIDELITY::IMPORTER_ID,
      page_number: page_number,
      render_status: :complete,
      font_inventory_status: :complete,
      page_failures: []
    }
  end

  def square_svg(transform = nil)
    transform_attr = transform ? " transform=\"#{transform}\"" : ''
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0 0 L 10 0 L 10 -10 L 0 -10 Z"/></g></defs><g>' \
      "<use href=\"#glyph-0-0\" x=\"10\" y=\"80\"#{transform_attr}/></g></svg>"
  end

  def colored_square_svg
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0 0 L 10 0 L 10 -10 L 0 -10 Z"/></g></defs>' \
      '<g fill="rgb(18.562317%, 35.928345%, 59.213257%)">' \
      '<use href="#glyph-0-0" x="10" y="80"/></g></svg>'
  end

  def square_svg_with_unjoined_source_glyph
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0 0 L 10 0 L 10 -10 L 0 -10 Z"/></g></defs><g>' \
      '<use href="#glyph-0-0" x="10" y="80"/>' \
      '<use href="#glyph-0-0" x="70" y="20"/></g></svg>'
  end

  def square_svg_with_affine_reuse
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0 0 L 10 0 L 10 -10 L 0 -10 Z"/></g></defs><g>' \
      '<use href="#glyph-0-0" x="10" y="80"/>' \
      '<use href="#glyph-0-0" x="70" y="20" ' \
      'transform="matrix(0,1,-1,0,0,0)"/></g></svg>'
  end

  def square_svg_with_host_tolerance_edge
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0.04 0 L 0 0 L 10 0 L 10 -10 L 0.04 -10 Z"/>' \
      '</g></defs><g><use href="#glyph-0-0" x="10" y="80"/></g></svg>'
  end

  def span(id = 'text_span:1:0', box = [8.0, 18.0, 25.0, 35.0])
    Svg3DSpan.new('A', 'pdftotext', id, *box)
  end

  def contour_points(coordinates)
    coordinates.map { |x, y| Geom::Point3d.new(x, y, 0.0) }
  end

  def source_loop_entry(index, glyph, loop_box, reported_box, pen)
    x0, y0, x1, y1 = loop_box
    points = [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]].map do |x, y|
      Geom::Point3d.new(x.to_f / 72.0, y.to_f / 72.0, 0.0)
    end
    {
      :glyph_id => glyph, :placement_index => index,
      :svg_matrix => [1.0, 0.0, 0.0, 1.0, pen[0], 100.0 - pen[1]],
      :source_primary_axis => :x, :pen_pdf => pen,
      :ink_bbox_pdf => reported_box, :loops => [points]
    }
  end

  def test_exact_svg_outline_becomes_owned_filled_positive_depth_3d_text
    entities = Svg3DEntities.new
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], depth: 0.05
    )

    assert result[:ok], result[:failures].inspect
    assert_equal :svg_source_3d_text, result[:renderer]
    assert_equal 1, result[:span_results].length
    delivered = result[:span_results][0]
    assert_equal 'text_span:1:0', delivered[:source_span_id]
    assert delivered[:identity_verified]
    assert delivered[:placement_verified]
    assert delivered[:rotation_verified]
    assert delivered[:size_verified]
    assert delivered[:depth_verified]
    assert_operator delivered[:face_count], :>=, 1
    assert_operator delivered[:extruded_face_count], :>=, 1
    assert_in_delta 10.0 / 72.0, delivered[:width], 1.0e-7
    assert_in_delta 10.0 / 72.0, delivered[:height], 1.0e-7
    assert_in_delta 0.05, delivered[:depth], 1.0e-7
    assert_equal 'text_span:1:0',
      delivered[:group].attributes[['BC_PDF_Importer', 'source_span_id']]
    assert_empty result[:transition_proofs]
  end

  def test_exact_svg_outline_orientation_is_not_overridden_by_semantic_hint
    unless Geom::Transformation.respond_to?(:rotation)
      Geom::Transformation.define_singleton_method(:rotation) do |_pivot, _axis, _radians|
        new(1.0)
      end
    end
    unless defined?(Geom::Vector3d)
      Geom.const_set(:Vector3d, Class.new do
        def initialize(*); end
      end)
    end
    source = span
    source.angle = -33.699810049
    entities = Svg3DEntities.new

    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [source], :depth => 0.05
    )

    assert result[:ok], result[:failures].inspect
    delivered = result[:span_results][0]
    assert_empty delivered[:group].transform_calls
    assert_empty delivered[:group].entities.transform_entity_calls,
                 'the PDF renderer source outline already contains its orientation'
  end

  def test_partial_render_uses_authoritative_full_page_match_inventory
    horizontal = span('text_span:1:0', [8.0, 18.0, 25.0, 35.0])
    rotated = span('text_span:1:1', [68.0, 78.0, 85.0, 95.0])
    captured_items = nil
    synthetic_match = {
      :matched_items => [horizontal, rotated],
      :placement_matches => [{
        :source_span_id => rotated.source_span_id,
        :placement_index => 1
      }],
      :unmatched_source_runs => [],
      :unmatched_placements => [],
      :coverage_failures => [],
      :source_ink_matches => [],
      :runs_matched => 2,
      :runs_unmatched => 0,
      :placements_unmatched => 0
    }
    matcher = lambda do |_pens, items, _media_box|
      captured_items = items
      synthetic_match
    end

    result = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.stub(
      :match_spans, matcher
    ) do
      RENDERER.render_svg(
        Svg3DEntities.new, square_svg_with_unjoined_source_glyph,
        MEDIA_BOX, [rotated],
        :match_text_items => [horizontal, rotated],
        :preserve_unmatched_source_placements => false,
        :depth => 0.05
      )
    end

    assert_equal [horizontal, rotated], captured_items
    assert result[:ok], result[:failures].inspect
    assert_equal [1], result[:span_results][0][:placement_indices]
    assert_equal 2, result[:authoritative_match_span_count]
    assert_equal 1, result[:render_target_span_count]
    assert_equal true, result[:match_scope_verified]
  end

  def test_repeated_source_glyph_builds_one_exact_solid_and_two_instances
    model = Svg3DModel.new(:with_definitions => true)
    entities = Svg3DEntities.new(:model => model)
    wide = Svg3DSpan.new(
      'AA', 'pdftotext', 'text_span:1:0',
      8.0, 18.0, 85.0, 95.0
    )
    synthetic_match = {
      :matched_items => [wide],
      :placement_matches => [
        { :source_span_id => wide.source_span_id, :placement_index => 0 },
        { :source_span_id => wide.source_span_id, :placement_index => 1 }
      ],
      :unmatched_source_runs => [],
      :unmatched_placements => [],
      :coverage_failures => [],
      :source_ink_matches => [],
      :runs_matched => 1,
      :runs_unmatched => 0,
      :placements_unmatched => 0
    }

    result = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.stub(
      :match_spans, synthetic_match
    ) do
      RENDERER.render_svg(
        entities, square_svg_with_unjoined_source_glyph,
        MEDIA_BOX, [wide], :depth => 0.05
      )
    end

    assert result[:ok], result[:failures].inspect
    assert_equal 1, result[:solid_cache][:definition_builds]
    assert_equal 1, result[:solid_cache][:cache_misses]
    assert_equal 1, result[:solid_cache][:cache_hits]
    assert_equal 2, result[:solid_cache][:instance_placements]
    assert_equal 1, model.definitions.to_a.length
    assert_equal(
      [
        :definition_build_ms, :instance_placement_ms, :match_ms,
        :parse_ms, :span_build_ms, :total_ms, :verification_ms
      ],
      result[:performance].keys.sort
    )
    result[:performance].each_value do |milliseconds|
      assert_kind_of Numeric, milliseconds
      assert_operator milliseconds, :>=, 0.0
    end
    assert_equal result[:source_placements],
                 result[:solid_cache][:instance_placements]
    assert_operator result[:solid_cache][:definition_builds], :<,
                    result[:solid_cache][:instance_placements]
    instances = result[:span_results][0][:group].entities.to_a.select do |entity|
      entity.typename == 'ComponentInstance'
    end
    assert_equal 2, instances.length
  end

  def test_affine_placements_reuse_one_exact_solid_without_changing_world_bounds
    model = Svg3DModel.new(:with_definitions => true)
    entities = Svg3DEntities.new(:model => model)
    wide = Svg3DSpan.new(
      'AA', 'pdftotext', 'text_span:1:0',
      0.0, 0.0, 100.0, 100.0
    )
    synthetic_match = {
      :matched_items => [wide],
      :placement_matches => [
        { :source_span_id => wide.source_span_id, :placement_index => 0 },
        { :source_span_id => wide.source_span_id, :placement_index => 1 }
      ],
      :unmatched_source_runs => [],
      :unmatched_placements => [],
      :coverage_failures => [],
      :source_ink_matches => [],
      :runs_matched => 1,
      :runs_unmatched => 0,
      :placements_unmatched => 0
    }

    result = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.stub(
      :match_spans, synthetic_match
    ) do
      RENDERER.render_svg(
        entities, square_svg_with_affine_reuse,
        MEDIA_BOX, [wide], :depth => 0.05
      )
    end

    assert result[:ok], result[:failures].inspect
    assert_equal 1, result[:solid_cache][:definition_builds],
                 'one glyph outline must not be rebuilt for each affine placement'
    assert_equal 2, result[:solid_cache][:instance_placements]
    delivered = result[:span_results][0]
    assert_in_delta 10.0 / 72.0, delivered[:bounds][:min_x], 1.0e-9
    assert_in_delta 20.0 / 72.0, delivered[:bounds][:min_y], 1.0e-9
    assert_in_delta 80.0 / 72.0, delivered[:bounds][:max_x], 1.0e-9
    assert_in_delta 80.0 / 72.0, delivered[:bounds][:max_y], 1.0e-9
    assert_in_delta 0.05, delivered[:bounds][:max_z], 1.0e-9
  end

  def test_exact_cache_key_ignores_translation_and_affine_but_separates_depth
    entries = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.
      model_space_loops(
        square_svg_with_unjoined_source_glyph, MEDIA_BOX
      )
    model = Svg3DModel.new(:with_definitions => true)
    cache = BlueCollarSystems::PDFVectorImporter::Svg3DTextSolidCache.new(
      model, 0.05
    )

    assert_equal cache.key_for(entries[0]), cache.key_for(entries[1]),
                 'identical source solids at different translations must reuse'

    rotated = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.
      model_space_loops(
        square_svg('matrix(0,1,-1,0,20,-10)'), MEDIA_BOX
      )[0]
    assert_equal cache.key_for(entries[0]), cache.key_for(rotated),
                 'affine placement belongs on the instance, not its solid definition'

    other_depth = BlueCollarSystems::PDFVectorImporter::Svg3DTextSolidCache.new(
      model, 0.025
    )
    refute_equal cache.key_for(entries[0]), other_depth.key_for(entries[0]),
                 'different extrusion depths must not alias'
  end

  def test_explicit_import_model_enables_cache_on_older_entities_api
    model = Svg3DModel.new(:with_definitions => true)
    entities_without_model_lookup = Svg3DEntities.new

    result = RENDERER.render_svg(
      entities_without_model_lookup, square_svg, MEDIA_BOX, [span],
      :depth => 0.05, :model => model
    )

    assert result[:ok], result[:failures].inspect
    assert_equal true, result[:solid_cache][:enabled]
    assert_equal 1, result[:solid_cache][:definition_builds]
    assert_equal 1, result[:solid_cache][:instance_placements]
  end

  def test_cached_definition_is_removed_when_exact_face_creation_fails
    model = Svg3DModel.new(
      :with_definitions => true, :fail_add_face => true
    )
    entities = Svg3DEntities.new(
      :model => model, :with_definitions => true, :fail_add_face => true
    )
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], :depth => 0.05
    )

    refute result[:ok]
    assert_equal :host_face_creation_exception,
                 result[:failures][0][:reason_code]
    assert_empty entities.groups
    assert_empty model.definitions.to_a
    assert_equal :verified, result[:solid_cache][:cleanup_outcome]
  end

  # Ghosting behavior contract: extruded source glyphs delivered with nil
  # materials render as
  # white-filled outlines — edges only, no face ink. Delivered 3D Text must
  # carry the shared black text-ink material on its owned span group so the
  # glyph caps and walls render with visible weight.
  def test_delivered_3d_text_carries_visible_source_ink
    model = Svg3DModel.new
    entities = Svg3DEntities.new(:model => model)
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], :depth => 0.05
    )

    assert result[:ok], result[:failures].inspect
    delivered = result[:span_results][0]
    assert_equal true, delivered[:ink_applied],
                 'delivered 3D Text must record applied face ink'
    group = delivered[:group]
    refute_nil group.material,
               'owned span group must be painted with the text ink material'
    assert_equal 'PDF_0_0_0', group.material.name
    color = group.material.color
    refute_nil color, 'text ink material must carry an explicit color'
    assert_equal [0, 0, 0], [color.red, color.green, color.blue]
  end

  def test_delivered_3d_text_uses_the_renderer_source_fill_color
    model = Svg3DModel.new
    entities = Svg3DEntities.new(:model => model)
    result = RENDERER.render_svg(
      entities, colored_square_svg, MEDIA_BOX, [span], :depth => 0.05
    )

    assert result[:ok], result[:failures].inspect
    delivered = result[:span_results][0]
    assert_equal true, delivered[:ink_applied]
    assert_equal [47, 92, 151], delivered[:source_ink_rgb]
    assert_equal 'PDF_47_92_151', delivered[:group].material.name
    color = delivered[:group].material.color
    assert_equal [47, 92, 151], [color.red, color.green, color.blue]
  end

  def test_byte_domain_source_material_does_not_turn_near_black_white
    model = Svg3DModel.new
    group = Svg3DEntities.new(:model => model).add_group

    assert_equal true, RENDERER.apply_source_text_ink!(group, [1, 1, 1])
    assert_equal 'PDF_1_1_1', group.material.name
    color = group.material.color
    assert_equal [1, 1, 1], [color.red, color.green, color.blue]
  end

  def test_non_solid_source_fill_fails_closed_instead_of_becoming_black
    error = assert_raises(RuntimeError) do
      RENDERER.source_text_ink_rgb([
        { :glyph_id => 'glyph-0-0', :fill_rgb => nil }
      ])
    end
    assert_match(/non-solid or unsupported fill color/, error.message)
  end

  def test_translucent_source_fill_fails_closed_instead_of_becoming_opaque
    error = assert_raises(RuntimeError) do
      RENDERER.source_text_ink_rgb([
        {
          :glyph_id => 'glyph-0-0',
          :fill_rgb => [0.2, 0.4, 0.6],
          :fill_opacity => 0.5
        }
      ])
    end
    assert_match(/opacity/, error.message)
  end

  # R20-2: a host (or fake) without material support must not silently claim
  # painted ink — the row records ink_applied false while the geometry
  # delivery itself remains valid.
  def test_host_without_material_support_reports_unpainted_ink_truthfully
    entities = Svg3DEntities.new
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], :depth => 0.05
    )

    assert result[:ok], result[:failures].inspect
    delivered = result[:span_results][0]
    assert_equal false, delivered[:ink_applied],
                 'host without materials must report unpainted ink truthfully'
  end

  def test_host_equal_vertices_are_preserved_by_baked_scaled_construction
    entities = Svg3DEntities.new(:reject_host_equal_points => true)
    result = RENDERER.render_svg(
      entities, square_svg_with_host_tolerance_edge, MEDIA_BOX, [span],
      :depth => 0.05
    )

    assert result[:ok], result[:failures].inspect
    delivered = result[:span_results][0]
    assert_equal :svg_source_3d_text, delivered[:renderer]
    assert_in_delta 10.0 / 72.0, delivered[:width], 1.0e-7
    assert_in_delta 10.0 / 72.0, delivered[:height], 1.0e-7
    assert delivered[:host_tolerance_adapted]
    assert_operator delivered[:construction_scale], :>, 1.0
    assert_equal 0, delivered[:collapsed_host_equal_vertices]
    assert_empty delivered[:group].transform_calls,
                 'outer semantic group must remain free of construction scale'
    assert_empty delivered[:group].entities.transform_entity_calls
    construction_group = delivered[:group].entities.groups.first
    refute_nil construction_group
    assert_equal 1, construction_group.transform_calls.length
    inverse = construction_group.transform_calls[0]
    refute_nil inverse.origin
    refute_in_delta 0.0, inverse.origin.x, 1.0e-12
    refute_in_delta 0.0, inverse.origin.y, 1.0e-12
    face = construction_group.entities.to_a.find do |entity|
      entity.respond_to?(:typename) && entity.typename == 'Face'
    end
    assert_equal 5, delivered[:source_outline_vertex_count]
    assert_equal delivered[:source_outline_vertex_count], face.points.length
  end

  def test_nonzero_submicron_source_edge_is_not_silently_normalized_away
    points = [
      Geom::Point3d.new(0.0, 0.0, 0.0),
      Geom::Point3d.new(0.0000005, 0.0000005, 0.0),
      Geom::Point3d.new(1.0, 0.0, 0.0),
      Geom::Point3d.new(1.0, 1.0, 0.0),
      Geom::Point3d.new(0.0, 1.0, 0.0)
    ]
    normalized = RENDERER.normalized_contour(points)
    assert_equal 5, normalized.length

    parent = Svg3DEntities.new(:reject_host_equal_points => true)
    group = parent.add_group
    entry = {
      :glyph_id => 'tiny-edge', :placement_index => 7,
      :svg_matrix => [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
      :loops => [points]
    }
    delivered = RENDERER.build_span_group(
      group, [entry], 'text_span:1:tiny', 0.05
    )

    assert_equal 5, delivered[:source_outline_vertex_count]
    assert_operator delivered[:construction_scale], :>, 1.0
    construction_group = group.entities.groups.first
    face = construction_group.entities.to_a.find do |entity|
      entity.typename == 'Face'
    end
    assert_equal 5, face.points.length
  end

  def test_nonzero_fill_keeps_same_winding_nested_region_filled
    outer = contour_points([[0, 0], [10, 0], [10, 10], [0, 10]])
    inner = contour_points([[2, 2], [8, 2], [8, 8], [2, 8]])
    entities = Svg3DEntities.new

    faces = RENDERER.build_filled_glyph(entities, [outer, inner])

    assert_equal 1, faces.length,
                 'same-winding inner path must not create overlapping solids'
    assert_empty entities.erased,
                 'same-winding nested contours are filled under nonzero rule'
  end

  def test_nonzero_fill_erases_opposite_winding_nested_region_as_hole
    outer = contour_points([[0, 0], [10, 0], [10, 10], [0, 10]])
    inner = contour_points([[2, 2], [8, 2], [8, 8], [2, 8]]).reverse
    entities = Svg3DEntities.new

    faces = RENDERER.build_filled_glyph(entities, [outer, inner])

    assert_equal 1, faces.length
    assert_equal 1, entities.erased.length
  end

  def test_reported_ink_bbox_cannot_bind_far_away_physical_loops
    source = Svg3DSpan.new(
      'A', 'pdftotext', 'text_span:1:0', 8.0, 8.0, 22.0, 22.0
    )
    forged = source_loop_entry(
      0, 'glyph-0-0', [70.0, 70.0, 80.0, 80.0],
      [10.0, 10.0, 20.0, 20.0], [10.0, 10.0]
    )

    result = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.stub(
      :model_space_loops, [forged]
    ) do
      RENDERER.render_svg(
        Svg3DEntities.new, '<svg/>', MEDIA_BOX, [source], :depth => 0.05
      )
    end

    refute result[:ok]
    assert_equal :source_loop_binding_mismatch, result[:failures][0][:reason_code]
  end

  def test_reported_placements_cannot_certify_physically_swapped_loops
    first = Svg3DSpan.new(
      'A', 'pdftotext', 'text_span:1:0', 8.0, 8.0, 22.0, 22.0
    )
    second = Svg3DSpan.new(
      'B', 'pdftotext', 'text_span:1:1', 68.0, 68.0, 82.0, 82.0
    )
    entries = [
      source_loop_entry(0, 'glyph-0-0', [70.0, 70.0, 80.0, 80.0],
                        [10.0, 10.0, 20.0, 20.0], [10.0, 10.0]),
      source_loop_entry(1, 'glyph-0-1', [10.0, 10.0, 20.0, 20.0],
                        [70.0, 70.0, 80.0, 80.0], [70.0, 70.0])
    ]

    result = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.stub(
      :model_space_loops, entries
    ) do
      RENDERER.render_svg(
        Svg3DEntities.new, '<svg/>', MEDIA_BOX, [first, second], :depth => 0.05
      )
    end

    refute result[:ok]
    assert_equal :source_loop_binding_mismatch, result[:failures][0][:reason_code]
  end

  def test_unmatched_source_span_never_claims_that_source_outlines_are_absent
    entities = Svg3DEntities.new
    missing = span('text_span:1:7', [60.0, 60.0, 70.0, 70.0])
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [missing], depth: 0.05,
      source_context: complete_source_context
    )

    refute result[:ok]
    assert_empty result[:span_results]
    assert_equal 1, result[:transition_proofs].length
    proof = result[:transition_proofs][0]
    assert_equal 'text_span:1:7', proof[:source_span_id]
    assert_equal :text3d, proof[:from_mode]
    assert_equal :glyphs, proof[:to_mode]
    assert_equal :source_item_identity_unavailable, proof[:reason_code]
    assert_equal FIDELITY::IMPORTER_ID, proof[:importer_id]
    assert_equal 1, proof[:page_number]
    assert proof[:affirmative_impossibility]
    refute proof[:generic_failure]
    assert_equal :not_required, proof[:cleanup_outcome]
    refute_match(/no glyph placement|outlines? absent/i,
                 proof[:evidence][:source_observation])
    assert_equal 1, proof[:evidence][:unmatched_renderer_placement_count]
  end


  def test_full_source_outline_is_not_rejected_by_unicode_count_guess
    long_span = Svg3DSpan.new(
      'TENLETTERS', 'pdftotext', 'text_span:1:0', 8.0, 18.0, 25.0, 35.0
    )
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg, MEDIA_BOX, [long_span], depth: 0.05,
      source_context: complete_source_context
    )

    assert result[:ok]
    assert_equal 1, result[:span_results].length
    assert_empty result[:unmatched_source_results]
    assert_empty result[:transition_proofs]
    assert_empty result[:match][:coverage_failures]
    coverage = result[:match][:source_ink_matches][0]
    assert_equal 10, coverage[:expected_glyph_count]
    assert_equal 1, coverage[:observed_glyph_count]
    assert_equal false, coverage[:character_count_parity]
    assert coverage[:source_ink_coverage_verified]
    assert coverage[:shaped_glyph_count_telemetry_only]
  end

  def test_each_transition_proof_contains_only_its_item_coverage_evidence
    first = Svg3DSpan.new(
      'FIRST', 'pdftotext', 'text_span:1:0', 8.0, 18.0, 25.0, 35.0
    )
    second = Svg3DSpan.new(
      'SECOND', 'pdftotext', 'text_span:1:1', 8.0, 18.0, 25.0, 35.0
    )
    synthetic_match = {
      placement_matches: [],
      unmatched_placements: [{ placement_index: 0 }],
      coverage_failures: [
        {
          source_span_id: 'text_span:1:0', expected_glyph_count: 5,
          observed_glyph_count: 1, placement_indices: [0]
        },
        {
          source_span_id: 'text_span:1:1', expected_glyph_count: 6,
          observed_glyph_count: 1, placement_indices: [0]
        }
      ]
    }

    result = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.stub(
      :match_spans, synthetic_match
    ) do
      RENDERER.render_svg(
        Svg3DEntities.new, square_svg, MEDIA_BOX, [first, second],
        depth: 0.05, source_context: complete_source_context,
        preserve_unmatched_source_placements: false
      )
    end

    assert_equal 2, result[:transition_proofs].length
    result[:transition_proofs].each do |proof|
      coverage = proof[:evidence][:glyph_coverage_failures]
      assert_equal [proof[:source_span_id]],
                   coverage.map { |failure| failure[:source_span_id] }.uniq
    end
  end

  def test_empty_key_page_font_inventory_failure_stops_without_absence_proof
    missing = span('text_span:1:7', [60.0, 60.0, 70.0, 70.0])
    context = complete_source_context.merge(
      page_failures: {
        '' => {
          scope: :page, page_number: 1,
          reason_code: :font_inventory_runtime_error,
          detail: 'page font inventory raised'
        }
      }
    )
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg, MEDIA_BOX, [missing], depth: 0.05,
      source_context: context
    )

    refute result[:ok]
    assert_empty result[:transition_proofs]
    assert_equal 1, result[:failures].length
    failure = result[:failures][0]
    assert_equal :source_page_inventory_failed, failure[:reason_code]
    assert_equal true, failure[:generic_failure]
    assert_equal false, failure[:affirmative_impossibility]
  end

  def test_source_page_context_must_match_item_importer_and_page
    missing = span('text_span:1:7', [60.0, 60.0, 70.0, 70.0])
    contexts = [
      complete_source_context.merge(importer_id: 'different_importer'),
      complete_source_context(2)
    ]

    contexts.each do |context|
      result = RENDERER.render_svg(
        Svg3DEntities.new, square_svg, MEDIA_BOX, [missing], depth: 0.05,
        source_context: context
      )
      assert_empty result[:transition_proofs]
      assert_equal :source_page_evidence_mismatch,
                   result[:failures][0][:reason_code]
    end
  end

  def test_host_face_creation_exception_is_a_hard_failure_not_a_fallback_proof
    entities = Svg3DEntities.new(fail_add_face: true)
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], depth: 0.05
    )

    refute result[:ok]
    assert_empty result[:transition_proofs]
    assert_equal :host_face_creation_exception, result[:failures][0][:reason_code]
    assert_match(/add_face failed for glyph glyph-0-0 placement 0/i,
                 result[:failures][0][:detail])
    assert_match(/host_equal_pairs=none/i, result[:failures][0][:detail])
    assert result[:failures][0][:generic_failure]
    assert_empty entities.groups, 'partially created owned group must be erased'
  end

  def test_zero_or_negative_depth_cannot_be_reported_as_3d_text
    [0.0, -0.01].each do |depth|
      result = RENDERER.render_svg(
        Svg3DEntities.new, square_svg, MEDIA_BOX, [span], depth: depth
      )
      refute result[:ok]
      assert_empty result[:transition_proofs]
      assert_equal :nonpositive_extrusion_depth, result[:failures][0][:reason_code]
    end
  end

  def test_same_size_3d_text_at_wrong_coordinates_is_rejected_and_cleaned
    entities = Svg3DEntities.new(
      :translate_created_faces => [3.0, -2.0]
    )

    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], :depth => 0.05
    )

    refute result[:ok]
    assert_empty result[:transition_proofs]
    assert_match(/width\/height verification failed/i,
                 result[:failures][0][:detail])
    assert_empty entities.groups
  end

  def test_final_evidence_rejects_post_verification_3d_translation
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg, MEDIA_BOX, [span], :depth => 0.05
    )
    row = result[:span_results][0]
    row[:source_page_transformation] = [
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ]
    row[:page_transform_verified] = true
    row[:group].entities.to_a.each do |face|
      face.instance_variable_get(:@points).each { |point| point.y -= 2.0 }
    end

    error = assert_raises(FIDELITY::ContractError) do
      RENDERER.finalize_source_evidence!(row, span)
    end

    assert_match(/final bounds differ from source outlines/i, error.message)
  end

  def test_svg_rotation_matrix_is_preserved_and_reported
    # Matrix translates the original use by (+20,-10) and rotates its local
    # x-axis into model -y. The source transform itself is the identity proof;
    # no substitute font metrics participate.
    item = span('text_span:1:0', [28.0, 28.0, 45.0, 45.0])
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg('matrix(0,1,-1,0,20,-10)'),
      MEDIA_BOX, [item], depth: 0.025
    )

    assert result[:ok], result[:failures].inspect
    delivered = result[:span_results][0]
    assert delivered[:rotation_verified]
    assert_equal [[0.0, 1.0, -1.0, 0.0, 20.0, -10.0]],
                 delivered[:source_matrices]
    assert_in_delta 0.025, delivered[:depth], 1.0e-7
  end

  def test_unjoined_svg_placement_is_preserved_as_verified_source_outline_3d
    entities = Svg3DEntities.new
    result = RENDERER.render_svg(
      entities, square_svg_with_unjoined_source_glyph, MEDIA_BOX, [span],
      depth: 0.05, page_number: 1
    )

    assert result[:ok], result[:failures].inspect
    assert_equal 1, result[:span_results].length
    assert_equal 1, result[:unmatched_source_results].length
    source = result[:unmatched_source_results][0]
    assert_equal :svg_glyph_placement, source[:source_kind]
    assert_nil source[:source_span_id]
    assert_equal 'svg_glyph_placements:page:1', source[:source_unit_id]
    assert_equal [1], source[:placement_indices]
    assert source[:identity_verified]
    assert source[:placement_verified]
    assert source[:rotation_verified]
    assert source[:size_verified]
    assert source[:depth_verified]
    assert_equal 'svg_glyph_placement',
      source[:group].attributes[['BC_PDF_Importer', 'source_kind']]
    assert_empty result[:transition_proofs]
    assert_empty result[:failures]
  end

  def test_subset_fallback_does_not_materialize_other_page_glyphs
    entities = Svg3DEntities.new
    result = RENDERER.render_svg(
      entities, square_svg_with_unjoined_source_glyph, MEDIA_BOX, [span],
      depth: 0.05, page_number: 1,
      preserve_unmatched_source_placements: false
    )

    assert result[:ok], result[:failures].inspect
    assert_equal 1, result[:span_results].length
    assert_empty result[:unmatched_source_results]
    assert_equal 1, entities.groups.length,
                 'item-subset fallback must not duplicate unrelated page text'
  end

  def test_svg_glyphs_without_semantic_spans_are_not_silently_discarded
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg, MEDIA_BOX, [],
      depth: 0.025, page_number: 4
    )

    assert result[:ok], result[:failures].inspect
    refute result[:no_semantic_text]
    assert_empty result[:span_results]
    assert_equal 1, result[:unmatched_source_results].length
    assert_equal [0], result[:unmatched_source_results][0][:placement_indices]
    assert result[:unmatched_source_results][0][:depth_verified]
  end

  def test_cached_glyph_cancellation_cleans_owned_span_and_propagates
    model = Svg3DModel.new(:with_definitions => true)
    entities = Svg3DEntities.new(:model => model, :with_definitions => true)
    controller =
      BlueCollarSystems::PDFVectorImporter::ImportRunControl::Controller.new(
        :pages => [1],
        :requested_mode => :text3d,
        :cancel_probe => lambda do |snapshot|
          snapshot[:stage] == :glyph_placement
        end,
        :clock => lambda { 0.0 }
      )

    error = assert_raises(
      BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled
    ) do
      RENDERER.render_svg(
        entities, square_svg, MEDIA_BOX, [span],
        :depth => 0.05, :model => model, :run_controller => controller,
        :page_number => 1
      )
    end

    assert_equal :glyph_placement, error.snapshot[:stage]
    assert_empty entities.groups,
                 'the partial source-span group must not survive cancellation'
    assert_empty model.definitions.to_a,
                 'the partial exact-glyph definition must not survive cancellation'
  end

end
