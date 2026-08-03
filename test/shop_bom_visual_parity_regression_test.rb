#!/usr/bin/env ruby
# test/shop_bom_visual_parity_regression_test.rb
# Opt-in regression anchor for an explicitly supplied shop BOM drawing.
# Verifies BOM table text is extracted and placed in Labels and 3D Text modes.
# Skips when the external reference PDF is not configured.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)
$LOAD_PATH.unshift(REPO_ROOT)

require 'corpus_paths'
require 'bc_pdf_vector_importer/external_text_extractor'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/text_source_identity'
require 'bc_pdf_vector_importer/main'
require 'bc_pdf_vector_importer/geometry_builder'

TextAlignLeft = 0

module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Transformation
    def initialize(*args)
      @args = args
      @kind = :translation
    end
    def self.rotation(*args)
      value = new(*args)
      value.instance_variable_set(:@kind, :rotation)
      value
    end
    def self.scaling(*args)
      value = new(*args)
      value.instance_variable_set(:@kind, :scaling)
      value
    end
    def transform_point(point)
      case @kind
      when :scaling
        pivot, sx, sy, sz = @args
        Point3d.new(
          pivot.x + ((point.x - pivot.x) * sx.to_f),
          pivot.y + ((point.y - pivot.y) * sy.to_f),
          pivot.z + ((point.z - pivot.z) * sz.to_f)
        )
      when :rotation
        pivot, _axis, radians = @args
        dx = point.x - pivot.x
        dy = point.y - pivot.y
        cosine = Math.cos(radians.to_f)
        sine = Math.sin(radians.to_f)
        Point3d.new(
          pivot.x + (dx * cosine) - (dy * sine),
          pivot.y + (dx * sine) + (dy * cosine),
          point.z
        )
      else
        delta = @args[0]
        Point3d.new(point.x + delta.x, point.y + delta.y, point.z + delta.z)
      end
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)
class Numeric
  def degrees
    to_f * Math::PI / 180.0
  end unless method_defined?(:degrees)
end

class ShopBomVisualParityRegressionTest < Minitest::Test
  ACCEPTANCE_KEY = 'shop-bom-tier1'.freeze

  BOM_HEADERS = %w[QUAN MARK DESCRIPTION LENGTH].freeze
  BOM_SAMPLE_RE = /\A(QUAN|MARK|DESCRIPTION|LENGTH|\d{1,2})\z/i

  def pdf_path
    @pdf_path ||= BlueCollarSystems::PDFVectorImporter::CorpusPaths
                  .resolve_acceptance_pdf(
                    ACCEPTANCE_KEY, 'BCS_SHOP_BOM_REGRESSION_PDF'
                  )
  end

  def skip_unless_pdf!
    skip 'Set BCS_PRIVATE_VALIDATION_ROOT or BCS_SHOP_BOM_REGRESSION_PDF' unless pdf_path
  end

  def merged_items
    items = BlueCollarSystems::PDFVectorImporter::ExternalTextExtractor.extract(pdf_path, 1)
    parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf_path)
    parser.parse
    info = parser.page_data(1)
    streams = info ? (info[:content_streams] || []) : []
    font_maps = parser.page_font_maps(1)
    angle_items = BlueCollarSystems::PDFVectorImporter::TextParser.new(
      streams, font_maps, { strict_text_fidelity: true, merge_text_runs: false }, nil
    ).parse
    merged = BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(items, angle_items)
    BlueCollarSystems::PDFVectorImporter::TextSourceIdentity.assign!(merged, 1)
    merged
  end

  def media_box
    parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf_path)
    parser.parse
    parser.page_data(1)[:media_box]
  end

  module PlacementIdentity
    @next_id = 50_000

    def self.next_id
      @next_id += 1
    end
  end

  class PlacementBounds
    attr_reader :min, :max

    def initialize(width, height, depth = 0.0)
      @min = Geom::Point3d.new(0, 0, 0)
      @max = Geom::Point3d.new(width, height, depth)
    end

    def transform!(transformation)
      points = [
        Geom::Point3d.new(@min.x, @min.y, @min.z),
        Geom::Point3d.new(@max.x, @min.y, @min.z),
        Geom::Point3d.new(@max.x, @max.y, @max.z),
        Geom::Point3d.new(@min.x, @max.y, @max.z)
      ].map { |point| transformation.transform_point(point) }
      @min = Geom::Point3d.new(
        points.map(&:x).min, points.map(&:y).min, points.map(&:z).min
      )
      @max = Geom::Point3d.new(
        points.map(&:x).max, points.map(&:y).max, points.map(&:z).max
      )
    end
  end

  class PlacementEntity
    attr_accessor :layer, :vector, :display_leader, :material, :back_material
    attr_reader :text, :point, :persistent_id

    def initialize(type, width = 0.1, height = 0.1, depth = 0.0,
                   text = nil, point = nil, vector = nil)
      @type = type
      @bounds = PlacementBounds.new(width, height, depth)
      @text = text
      @point = point
      @vector = vector
      @display_leader = true
      @persistent_id = PlacementIdentity.next_id
      @attributes = {}
    end

    def typename
      @type
    end

    def bounds
      @bounds
    end

    def transform!(transformation)
      @bounds.transform!(transformation)
    end

    def set_attribute(dictionary, key, value)
      @attributes[[dictionary.to_s, key.to_s]] = value
    end
  end

  class PlacementStagingEntities
    def initialize(parent)
      @parent = parent
      @entities = []
    end

    def add_3d_text(text, _align, _font, _bold, _italic, height, _tol,
                    _z, _filled, extrusion)
      width = [height.to_f * [text.to_s.length, 1].max * 0.6, height.to_f].max
      @entities << PlacementEntity.new('Edge', width, height, extrusion)
      @entities << PlacementEntity.new('Face', width, height, extrusion)
      true
    end

    def to_a
      @entities.dup
    end
  end

  class PlacementStagingGroup
    attr_reader :entities, :persistent_id

    def initialize(parent)
      @parent = parent
      @entities = PlacementStagingEntities.new(parent)
      @persistent_id = PlacementIdentity.next_id
    end

    def typename
      'Group'
    end

    def explode
      @parent.explode_group(self, @entities.to_a)
    end
  end

  class PlacementEntities
    attr_reader :labels, :mesh
    def initialize
      @labels = []
      @mesh = []
      @entities = []
    end

    def add_text(text, pt, dir = nil)
      dir ||= Geom::Vector3d.new(0, 0, 0)
      entity = PlacementEntity.new('Text', 0.1, 0.1, 0.0, text, pt, dir)
      @labels << { text: text, pt: pt, dir: dir }
      @entities << entity
      entity
    end

    def add_group
      group = PlacementStagingGroup.new(self)
      @entities << group
      group
    end

    def explode_group(group, children)
      @entities.delete(group)
      @entities.concat(children)
      children
    end

    def to_a
      @entities.dup
    end

    def transform_entities(transformation, *entities)
      entities.flatten.each { |entity| entity.transform!(transformation) }
    end

    def erase_entities(*entities)
      doomed = entities.flatten
      @entities.reject! { |entity| doomed.include?(entity) }
    end

    def record_mesh(text, height)
      @mesh << { text: text, height: height }
    end
  end

  def simulate_placement(use_3d_text:)
    ents = PlacementEntities.new
    mb = media_box
    items = merged_items
    builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
      nil, [], items, mb, import_text: true, use_3d_text: use_3d_text,
      native_font_identity_resolver: lambda { |source|
        {
          source_span_id: source.source_span_id,
          pdf_font_identity: 'acceptance-source-font',
          installed_family: 'Arial',
          exact_family_match: true,
          verified: true
        }
      }
    )
    builder.send(:prepare_bom_table_context, items)
    items.each do |it|
      before = ents.to_a
      builder.send(:place_text, ents, it, mb[0], mb[1], mb[3], nil)
      if use_3d_text && ents.to_a.length > before.length
        height = builder.send(:mesh_text_height_inches, it, 0.0, mb[3])
        ents.record_mesh(it.text, height) if height
      end
    end
    ents
  end

  def test_extracts_bom_table_text
    skip_unless_pdf!
    items = merged_items
    texts = items.map { |it| it.text.to_s.strip }
    assert_operator items.length, :>=, 250, 'expected dense shop-drawing text coverage'
    BOM_HEADERS.each do |hdr|
      assert texts.any? { |t| t.casecmp(hdr).zero? }, "missing BOM header #{hdr}"
    end
    row_count = texts.count { |t| t =~ BOM_SAMPLE_RE }
    assert_operator row_count, :>=, 25, 'expected BOM table row/header sample strings'
  end

  def test_labels_mode_places_bom_strings
    skip_unless_pdf!
    ents = simulate_placement(use_3d_text: false)
    placed = ents.labels.map { |e| e[:text].to_s.strip }
    BOM_HEADERS.each do |hdr|
      assert placed.any? { |t| t.casecmp(hdr).zero? }, "Labels mode missing #{hdr}"
    end
    assert_operator ents.labels.length, :>=, 250, 'Labels mode should place most extracted strings'
  end

  def test_text3d_mode_uses_readable_nominal_heights
    skip_unless_pdf!
    ents = simulate_placement(use_3d_text: true)
    placed = ents.mesh.map { |e| e[:text].to_s.strip }
    BOM_HEADERS.each do |hdr|
      assert placed.any? { |t| t.casecmp(hdr).zero? }, "3D Text mode missing #{hdr}"
    end
    tiny = ents.mesh.count { |e| e[:height].to_f < 0.02 }
    assert_equal 0, tiny, '3D Text must not shrink to microscopic heights'
    header = BOM_HEADERS.map do |hdr|
      ents.mesh.find { |e| e[:text].to_s.strip.casecmp(hdr).zero? }
    end.compact.first
    assert header, '3D Text missing BOM header mesh'
    assert_operator header[:height], :>=, 0.08,
                    "BOM header 3D height too small (#{header[:height].round(4)} in)"
    assert_operator header[:height], :<=, 0.30,
                    "BOM header 3D height too large (#{header[:height].round(4)} in)"
  end
end
