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
    def initialize(*); end
    def self.rotation(*); new; end
  end
end

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
    attr_reader :labels, :mesh
    def initialize
      @labels = []
      @mesh = []
    end

    def add_text(text, pt, dir = nil)
      @labels << { text: text, pt: pt, dir: dir }
      Object.new.tap { |o| def o.valid?; true; end }
    end

    def add_3d_text(text, _align, _font, _bold, _italic, height, _tol, _extrusion, _filled, _z)
      @mesh << { text: text, height: height }
      true
    end

    def to_a
      []
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
      assert texts.any? { |t| t.casecmp?(hdr) }, "missing BOM header #{hdr}"
    end
    row_count = texts.count { |t| t =~ BOM_SAMPLE_RE }
    assert_operator row_count, :>=, 25, 'expected BOM table row/header sample strings'
  end

  def test_labels_mode_places_bom_strings
    skip_unless_pdf!
    ents = simulate_placement(use_3d_text: false)
    placed = ents.labels.map { |e| e[:text].to_s.strip }
    BOM_HEADERS.each do |hdr|
      assert placed.any? { |t| t.casecmp?(hdr) }, "Labels mode missing #{hdr}"
    end
    assert_operator ents.labels.length, :>=, 250, 'Labels mode should place most extracted strings'
  end

  def test_text3d_mode_uses_readable_nominal_heights
    skip_unless_pdf!
    ents = simulate_placement(use_3d_text: true)
    placed = ents.mesh.map { |e| e[:text].to_s.strip }
    BOM_HEADERS.each do |hdr|
      assert placed.any? { |t| t.casecmp?(hdr) }, "3D Text mode missing #{hdr}"
    end
    tiny = ents.mesh.count { |e| e[:height].to_f < 0.02 }
    assert_equal 0, tiny, '3D Text must not shrink to microscopic heights'
    header = BOM_HEADERS.map { |hdr| ents.mesh.find { |e| e[:text].to_s.strip.casecmp?(hdr) } }.compact.first
    assert header, '3D Text missing BOM header mesh'
    assert_operator header[:height], :>=, 0.08,
                    "BOM header 3D height too small (#{header[:height].round(4)} in)"
    assert_operator header[:height], :<=, 0.30,
                    "BOM header 3D height too large (#{header[:height].round(4)} in)"
  end
end
