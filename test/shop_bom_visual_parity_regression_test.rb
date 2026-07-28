#!/usr/bin/env ruby
# test/shop_bom_visual_parity_regression_test.rb
# Go-live regression anchor for a private shop BOM drawing.
# Verifies BOM table text is extracted and placed in Labels and 3D Text modes.
# Skips when the private PDF is not configured.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)
$LOAD_PATH.unshift(REPO_ROOT)

require 'corpus_paths'
require 'bc_pdf_vector_importer/external_text_extractor'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/main'
require 'bc_pdf_vector_importer/geometry_builder'

TextAlignLeft = 0

class Numeric
  def degrees
    to_f * Math::PI / 180.0
  end
end

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
    attr_reader :args, :kind
    def initialize(*args); @args = args; @kind = :translation; end
    def self.rotation(*args)
      transform = new(*args)
      transform.instance_variable_set(:@kind, :rotation)
      transform
    end
    def self.scaling(*args)
      transform = new(*args)
      transform.instance_variable_set(:@kind, :scaling)
      transform
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)

class ShopBomVisualParityRegressionTest < Minitest::Test
  PDF_CANDIDATES = [
    ENV['BCS_SHOP_BOM_REGRESSION_PDF'],
    BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_manifest_pdf('PRIVATE-01'),
    BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf('PRIVATE-01.pdf', subdir: 'private/user')
  ].compact.uniq.freeze

  BOM_HEADERS = %w[QUAN MARK DESCRIPTION LENGTH].freeze
  BOM_SAMPLE_RE = /\A(QUAN|MARK|DESCRIPTION|LENGTH|\d{1,2})\z/i

  def pdf_path
    @pdf_path ||= PDF_CANDIDATES.find { |p| p && File.file?(p) }
  end

  def skip_unless_pdf!
    skip 'Private shop BOM regression PDF not configured (set BCS_SHOP_BOM_REGRESSION_PDF or BCS_PRIVATE_VALIDATION_ROOT)' unless pdf_path
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
    BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(items, angle_items)
  end

  def media_box
    parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf_path)
    parser.parse
    parser.page_data(1)[:media_box]
  end

  class PlacementEntities
    class Bounds
      attr_reader :min, :max
      def initialize(width, height)
        @min = Geom::Point3d.new(0, 0, 0)
        @max = Geom::Point3d.new(width, height, 0)
      end
    end

    class Entity
      attr_accessor :layer, :material, :back_material
      attr_reader :persistent_id

      @@next_persistent_id = 90_000

      def initialize(typename, width, height)
        @@next_persistent_id += 1
        @persistent_id = @@next_persistent_id
        @typename = typename
        @bounds = Bounds.new(width, height)
      end
      def typename; @typename; end
      def bounds; @bounds; end
    end

    attr_reader :labels, :mesh, :transforms, :entities
    def initialize
      @labels = []
      @mesh = []
      @transforms = []
      @entities = []
    end

    def add_text(text, pt, dir = nil)
      @labels << { text: text, pt: pt, dir: dir }
      entity = Entity.new('Text', 0.1, 0.1)
      @entities << entity
      entity
    end

    def add_3d_text(text, _align, _font, _bold, _italic, height, _tol, _extrusion, _filled, _z)
      @mesh << { text: text, height: height }
      @entities << Entity.new('Edge', height * 3.0, height)
      @entities << Entity.new('Face', height * 3.0, height)
      true
    end

    def to_a
      @entities.dup
    end

    def transform_entities(*args)
      @transforms << args
      true
    end
  end

  def simulate_placement(use_3d_text:)
    ents = PlacementEntities.new
    mb = media_box
    items = merged_items
    builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
      nil, [], items, mb, import_text: true, use_3d_text: use_3d_text
    )
    builder.send(:prepare_bom_table_context, items)
    items.each do |it|
      builder.send(:place_text, ents, it, mb[0], mb[1], mb[3], nil)
    end
    ents
  end

  def test_extracts_bom_table_text
    skip_unless_pdf!
    items = merged_items
    texts = items.map { |it| it.text.to_s.strip }
    assert_operator items.length, :>=, 250, 'expected dense shop-drawing text coverage'
    BOM_HEADERS.each do |hdr|
      assert texts.any? { |t| t.casecmp(hdr) == 0 }, "missing BOM header #{hdr}"
    end
    row_count = texts.count { |t| t =~ BOM_SAMPLE_RE }
    assert_operator row_count, :>=, 25, 'expected BOM table row/header sample strings'
  end

  def test_labels_mode_places_bom_strings
    skip_unless_pdf!
    ents = simulate_placement(use_3d_text: false)
    placed = ents.labels.map { |e| e[:text].to_s.strip }
    BOM_HEADERS.each do |hdr|
      assert placed.any? { |t| t.casecmp(hdr) == 0 }, "Labels mode missing #{hdr}"
    end
    assert_operator ents.labels.length, :>=, 250, 'Labels mode should place most extracted strings'
  end

  def test_text3d_mode_uses_readable_nominal_heights
    skip_unless_pdf!
    ents = simulate_placement(use_3d_text: true)
    placed = ents.mesh.map { |e| e[:text].to_s.strip }
    BOM_HEADERS.each do |hdr|
      assert placed.any? { |t| t.casecmp(hdr) == 0 }, "3D Text mode missing #{hdr}"
    end
    tiny = ents.mesh.count { |e| e[:height].to_f < 0.02 }
    assert_equal 0, tiny, '3D Text must not shrink to microscopic heights'
    header = BOM_HEADERS.map do |hdr|
      ents.mesh.find { |e| e[:text].to_s.strip.casecmp(hdr) == 0 }
    end.compact.first
    assert header, '3D Text missing BOM header mesh'
    assert_operator header[:height], :>=, 0.08,
                    "BOM header 3D height too small (#{header[:height].round(4)} in)"
    assert_operator header[:height], :<=, 0.30,
                    "BOM header 3D height too large (#{header[:height].round(4)} in)"
    assert_empty ents.labels,
                 '3D Text regression must not pass through empty-mesh Label fallback'
    assert_operator ents.entities.length, :>, 0,
                    '3D Text regression fake must retain generated native entities'
  end
end
