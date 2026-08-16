#!/usr/bin/env ruby

# Visual-oracle regression (sheet 1011, SketchUp v3.7.140, 2026-08-16):
# Glyphs and Geometry modes delivered text as raw outline EDGES only, so every
# glyph tall enough to see inside rendered HOLLOW (white with a 1 px black
# outline) while the PDF shows filled black glyphs. Under the owner's visual
# ruling (100% = no visible difference side by side) hollow text is a visible
# difference. The item renderer must fill each placement's outer loops with
# faces (holes kept for counters like O/A/B), keep the edges, paint the faces
# with the source ink through the same material path 3D Text uses, and record
# -- never raise on -- a loop the host cannot face.

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
  end unless const_defined?(:Point3d)

  class Transformation
    attr_reader :matrix

    def initialize(values)
      @matrix = Array(values).map(&:to_f)
    end
  end unless const_defined?(:Transformation)
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

require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/svg_item_representation_renderer'

class FilledGlyphBounds
  attr_reader :min, :max

  def initialize(points)
    @min = Geom::Point3d.new(
      points.map(&:x).min, points.map(&:y).min, points.map(&:z).min
    )
    @max = Geom::Point3d.new(
      points.map(&:x).max, points.map(&:y).max, points.map(&:z).max
    )
  end
end

class FilledGlyphNormal
  attr_accessor :z
  def initialize(z); @z = z; end
end

class FilledGlyphEdge
  attr_accessor :layer
  attr_reader :persistent_id, :attributes, :points

  def initialize(id, first, last)
    @persistent_id = id
    @points = [first, last]
    @attributes = {}
  end

  def typename; 'Edge'; end
  def bounds; FilledGlyphBounds.new(@points); end
  def hidden?; false; end

  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end
end

FilledGlyphVertex = Struct.new(:position)

class FilledGlyphFace
  attr_accessor :layer, :material, :back_material
  attr_reader :persistent_id, :attributes, :points, :reversed

  def initialize(owner, id, points, normal_z)
    @owner = owner
    @persistent_id = id
    @points = points
    @attributes = {}
    @normal = FilledGlyphNormal.new(normal_z)
    @reversed = 0
  end

  def typename; 'Face'; end
  def bounds; FilledGlyphBounds.new(@points); end
  def hidden?; false; end
  def normal; @normal; end
  def vertices; @points.map { |point| FilledGlyphVertex.new(point) }; end

  def reverse!
    @normal.z *= -1.0
    @reversed += 1
    self
  end

  def erase!
    @owner.erase_entities(self)
    true
  end

  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end
end

class FilledGlyphMaterial
  attr_reader :name
  attr_accessor :color, :alpha

  def initialize(name)
    @name = name
    @alpha = 1.0
  end
end

class FilledGlyphMaterials
  def initialize; @by_name = {}; end
  def [](name); @by_name[name]; end
  def add(name); @by_name[name] ||= FilledGlyphMaterial.new(name); end
end

class FilledGlyphDefinition
  attr_reader :name, :entities

  def initialize(name, options, counter)
    @name = name
    @entities = FilledGlyphEntities.new(self, options, counter)
  end
end

class FilledGlyphDefinitions
  attr_reader :items

  def initialize(options, counter)
    @options = options
    @counter = counter
    @items = []
  end

  def add(name)
    definition = FilledGlyphDefinition.new(name, @options, @counter)
    @items << definition
    definition
  end
end

class FilledGlyphModel
  attr_reader :materials, :definitions

  def initialize(options = {}, counter = [100])
    @materials = FilledGlyphMaterials.new
    @definitions = FilledGlyphDefinitions.new(options, counter)
  end
end

class FilledGlyphInstance
  attr_accessor :layer, :material
  attr_reader :persistent_id, :definition, :transformation, :attributes

  def initialize(id, definition, transformation, options)
    @persistent_id = id
    @definition = definition
    @transformation = transformation
    @attributes = {}
    @options = options
  end

  def typename; 'ComponentInstance'; end
  def hidden?; false; end
  def model; @options[:model]; end

  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end

  def bounds
    matrix = transformation.matrix
    points = definition.entities.to_a.inject([]) do |all, entity|
      all + Array(entity.points)
    end.map do |point|
      Geom::Point3d.new(
        (point.x * matrix[0]) + (point.y * matrix[4]) + matrix[12],
        (point.x * matrix[1]) + (point.y * matrix[5]) + matrix[13],
        (point.z * matrix[10]) + matrix[14]
      )
    end
    FilledGlyphBounds.new(points)
  end
end

# Host fake: add_face on the ground plane returns a face whose normal points
# DOWN (SketchUp documents exactly that for z=0 faces); add_face over the
# edges of an already-created face returns that face again (SketchUp reuses
# the existing face) so a hole contour can be created then erased.
class FilledGlyphEntities
  attr_reader :erased, :add_face_calls

  def initialize(owner = nil, options = {}, counter = nil)
    @owner = owner
    @options = options
    @counter = counter || [100]
    @items = []
    @erased = []
    @add_face_calls = []
  end

  def next_id
    @counter[0] += 1
  end

  def to_a; @items.dup; end
  def model; @options[:model]; end

  def add_group
    group = FilledGlyphGroup.new(self, next_id, @options, @counter)
    @items << group
    group
  end

  def add_edges(points)
    created = []
    Array(points).each_cons(2) do |first, last|
      edge = FilledGlyphEdge.new(next_id, first, last)
      @items << edge
      created << edge
    end
    created
  end

  def add_face(points)
    @add_face_calls << Array(points).map { |p| [p.x, p.y] }
    raise 'synthetic host face failure' if @options[:fail_add_face]
    return nil if @options[:nil_add_face]
    key = face_key(points)
    existing = @items.find do |entity|
      entity.is_a?(FilledGlyphFace) && face_key(entity.points) == key
    end
    if existing
      # Some hosts decline to re-add a face that already exists.
      return nil if @options[:nil_add_face_for_existing]
      return existing
    end
    if @options[:split_on_outer_face]
      # SketchUp splits a new face along pre-existing coplanar inner edges:
      # the counter square inside this outer square gets its own face too.
      inner = @options[:split_on_outer_face]
      unless inner_present?(inner)
        @items << FilledGlyphFace.new(self, next_id, inner.dup, -1.0)
      end
    end
    if @options[:split_edges_on_face]
      # SketchUp also splits existing EDGES when it heals the face boundary
      # (an edge gets a vertex at a touching point and becomes two edges), so
      # the group holds more edges after add_face than add_edges returned. The
      # in-host 3.7.141 regression: verify_structure! compared the pre-face
      # add_edges count with the post-face group and refused every Geometry
      # import. Emulate one split per add_face call.
      first_edge = @items.find { |entity| entity.is_a?(FilledGlyphEdge) }
      if first_edge
        a, b = first_edge.points
        mid = Geom::Point3d.new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0, 0.0)
        @items << FilledGlyphEdge.new(next_id, mid, b)
      end
    end
    face = FilledGlyphFace.new(self, next_id, Array(points).dup, -1.0)
    @items << face
    face
  end

  def add_instance(definition, transformation)
    instance = FilledGlyphInstance.new(
      next_id, definition, transformation, @options
    )
    @items << instance
    instance
  end

  def erase_entities(*entities)
    entities.flatten.each do |entity|
      @items.delete(entity)
      @erased << entity
    end
  end

  private

  def face_key(points)
    Array(points).map { |p| [p.x.round(6), p.y.round(6)] }.sort
  end

  def inner_present?(inner)
    key = face_key(inner)
    @items.any? do |entity|
      entity.is_a?(FilledGlyphFace) && face_key(entity.points) == key
    end
  end
end

class FilledGlyphGroup
  attr_accessor :name, :layer, :material
  attr_reader :persistent_id, :entities, :attributes

  def initialize(owner, id, options, counter)
    @owner = owner
    @persistent_id = id
    @options = options
    @entities = FilledGlyphEntities.new(self, options, counter)
    @attributes = {}
  end

  def typename; 'Group'; end
  def hidden?; false; end
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
    FilledGlyphBounds.new(points)
  end
end

class SvgItemFilledGlyphFacesTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  RENDERER = IMP::SvgItemRepresentationRenderer
  FIDELITY = IMP::RepresentationFidelity
  ITEM = IMP::TextParser::TextItem
  MEDIA_BOX = [0.0, 0.0, 100.0, 100.0].freeze

  def item(source_id = 'text_span:1:0')
    ITEM.new('O', 10.0, 20.0, 12.0, 0.0, 'F1', 12.0,
             9.0, 19.0, 22.0, 32.0, nil, source_id)
  end

  # One glyph: a 10x10 outer square with a 4x4 counter (hole) inside it,
  # like the letter "O". Optional fill colour on the <use>.
  def ring_svg(fill = nil)
    fill_attr = fill ? " fill=\"#{fill}\"" : ''
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0 0 L 10 0 L 10 -10 L 0 -10 Z M 3 -3 L 3 -7 L 7 -7 L 7 -3 Z"/>' \
      "</g></defs><g><use href=\"#glyph-0-0\" x=\"10\" y=\"80\"#{fill_attr}/>" \
      '</g></svg>'
  end

  def source_context
    {
      importer_id: FIDELITY::IMPORTER_ID,
      page_number: 1,
      render_status: :complete,
      font_inventory_status: :complete,
      page_failures: []
    }
  end

  def render(entities, mode, svg = ring_svg, extra = {})
    RENDERER.render_svg(
      entities, svg, MEDIA_BOX, item, mode,
      { :scale => 1.0, :svg_page_box => MEDIA_BOX,
        :source_context => source_context }.merge(extra)
    )
  end

  def entities_with_model(options = {})
    model = FilledGlyphModel.new(options)
    [FilledGlyphEntities.new(nil, options.merge(:model => model)), model]
  end

  def edges_and_faces(collection)
    members = collection.to_a
    [
      members.select { |entity| entity.typename == 'Edge' },
      members.select { |entity| entity.typename == 'Face' }
    ]
  end

  def test_geometry_fills_outer_loop_and_keeps_the_hole
    entities, model = entities_with_model
    result = render(entities, :geometry)

    assert_equal true, result[:ok]
    edges, faces = edges_and_faces(result[:group].entities)
    assert_equal 8, edges.length, 'all outline edges are kept'
    assert_equal 8, result[:edge_count]
    assert_equal 1, faces.length,
                 'one filled face for the outer loop; the counter is a hole'
    assert_equal 1, result[:face_count]
    assert_equal 1, result[:hole_count]
    assert_empty result[:face_fill_failures]
    # The hole contour was faced then erased so the outer face keeps its hole.
    assert_equal 1, result[:group].entities.erased.length
    assert_equal 'Face', result[:group].entities.erased.first.typename
    # Face was reversed so its front points up (add_face on z=0 faces down).
    assert_operator faces.first.normal.z, :>, 0.0
    # Ink through the 3D Text material path: group painted with PDF_0_0_0.
    assert_equal true, result[:ink_applied]
    assert_equal 'PDF_0_0_0', result[:source_ink_material_name]
    refute_nil result[:group].material
    assert_equal 'PDF_0_0_0', result[:group].material.name
    assert_equal [0, 0, 0], [model.materials['PDF_0_0_0'].color.red,
                             model.materials['PDF_0_0_0'].color.green,
                             model.materials['PDF_0_0_0'].color.blue]
    assert_equal 'text_span:1:0', faces.first.attributes[
      ['BC_PDF_Importer', 'source_span_id']
    ]
    assert_equal 'geometry', faces.first.attributes[
      ['BC_PDF_Importer', 'representation']
    ]
  end

  def test_glyph_groups_fill_each_glyph_and_keep_the_hole
    entities, = entities_with_model
    result = render(entities, :glyphs)

    assert_equal true, result[:ok]
    assert_equal :svg_item_glyph_groups, result[:renderer]
    glyph = result[:group].entities.to_a.first
    assert_equal 'Group', glyph.typename
    edges, faces = edges_and_faces(glyph.entities)
    assert_equal 8, edges.length
    assert_equal 1, faces.length
    assert_equal 1, result[:face_count]
    assert_equal true, result[:ink_applied]
    assert_equal 'PDF_0_0_0', result[:group].material.name
  end

  def test_glyph_components_fill_the_shared_definition_once
    entities, model = entities_with_model
    cache = {}
    extra = { :model => model, :glyph_component_cache => cache }

    first = render(entities, :glyphs, ring_svg, extra)
    second = render(entities, :glyphs, ring_svg, extra)

    assert_equal true, first[:ok]
    assert_equal true, second[:ok]
    assert_equal :svg_item_glyph_components, first[:renderer]
    assert_equal 1, model.definitions.items.length
    definition = model.definitions.items.first
    edges, faces = edges_and_faces(definition.entities)
    assert_equal 8, edges.length
    assert_equal 1, faces.length, 'definition carries the filled face'
    assert_equal 1, first[:face_count]
    assert_equal 1, second[:face_count], 'cache hit reports the definition faces'
    [first, second].each do |result|
      assert_equal true, result[:ink_applied]
      assert_equal 'PDF_0_0_0', result[:group].material.name
    end
  end

  def test_source_fill_colour_selects_the_ink_material
    entities, model = entities_with_model
    result = render(entities, :geometry, ring_svg('#ff0000'))

    assert_equal true, result[:ok]
    assert_equal true, result[:ink_applied]
    assert_equal 'PDF_255_0_0', result[:source_ink_material_name]
    assert_equal 'PDF_255_0_0', result[:group].material.name
    assert_equal 255, model.materials['PDF_255_0_0'].color.red
  end

  def test_host_face_failure_keeps_edges_and_is_recorded_not_raised
    entities, = entities_with_model(:fail_add_face => true)
    result = render(entities, :geometry)

    assert_equal true, result[:ok], 'edges-only delivery still succeeds'
    edges, faces = edges_and_faces(result[:group].entities)
    assert_equal 8, edges.length
    assert_empty faces
    assert_equal 0, result[:face_count]
    refute_empty result[:face_fill_failures]
    assert_match(/synthetic host face failure/, result[:face_fill_failures].first)
  end

  # SketchUp splits the outer face along the pre-existing counter edges as
  # soon as it is created and may decline to "add" the counter face again;
  # the already-split counter face must still be found and erased.
  def test_hole_is_kept_when_host_splits_outer_face_and_declines_readd
    placed = IMP::CairoGlyphSource.model_space_loops(
      ring_svg, MEDIA_BOX, :scale => 1.0, :svg_page_box => MEDIA_BOX
    )
    loops = placed.first[:loops].sort_by do |loop|
      IMP::Svg3DTextRenderer.signed_area(loop[0...-1]).abs
    end
    inner = loops.first[0...-1] # counter contour without the closing point
    assert_equal 4, inner.length
    assert_in_delta 4.0 * 4.0 / 72.0 / 72.0,
                    IMP::Svg3DTextRenderer.signed_area(inner).abs, 1e-9
    entities, = entities_with_model(
      :split_on_outer_face => inner, :nil_add_face_for_existing => true
    )
    result = render(entities, :geometry)

    assert_equal true, result[:ok]
    edges, faces = edges_and_faces(result[:group].entities)
    assert_equal 8, edges.length
    assert_equal 1, faces.length, 'only the outer face remains'
    assert_equal 1, result[:hole_count]
    assert_empty result[:face_fill_failures]
    erased = result[:group].entities.erased
    assert_equal 1, erased.length
    assert_equal inner.map { |p| [p.x.round(6), p.y.round(6)] }.sort,
                 erased.first.points.map { |p| [p.x.round(6), p.y.round(6)] }.sort
  end

  def test_host_returning_no_face_is_recorded_not_raised
    entities, = entities_with_model(:nil_add_face => true)
    result = render(entities, :glyphs)

    assert_equal true, result[:ok]
    assert_equal 0, result[:face_count]
    refute_empty result[:face_fill_failures]
  end

  def test_host_without_materials_reports_ink_not_applied
    entities = FilledGlyphEntities.new
    result = render(entities, :geometry)

    assert_equal true, result[:ok]
    assert_equal 1, result[:face_count]
    assert_equal false, result[:ink_applied]
  end

  def test_geometry_contract_survives_the_host_splitting_edges_while_facing
    # In-host regression on 3.7.141: SketchUp split outline edges while building
    # the glyph faces, the group then held more Edge entities than add_edges had
    # returned, and verify_structure! raised "Geometry is not a flat raw-edge
    # representation" for EVERY Geometry item. The reported edge_count must be
    # the edges that exist after the build, and the structure check must pass.
    entities, = entities_with_model(:split_edges_on_face => true)
    result = render(entities, :geometry)

    assert_equal true, result[:ok], result.inspect
    edges, faces = edges_and_faces(result[:group].entities)
    assert_operator edges.length, :>, 8, 'the host split at least one edge'
    assert_equal edges.length, result[:edge_count],
                 'edge_count reflects the edges that exist after facing'
    assert_operator faces.length, :>=, 1
    assert RENDERER.verify_structure!(
      result[:group], :geometry, 1, result[:edge_count], 'text_span:1:0'
    )
  end

  def test_structure_contract_accepts_faces_but_still_counts_edges
    entities, = entities_with_model
    result = render(entities, :geometry)

    assert RENDERER.verify_structure!(
      result[:group], :geometry, 1, result[:edge_count], 'text_span:1:0'
    )
    error = assert_raises(FIDELITY::ContractError) do
      RENDERER.verify_structure!(
        result[:group], :geometry, 1, result[:edge_count] + 1, 'text_span:1:0'
      )
    end
    assert_match(/flat/i, error.message)
  end
end
