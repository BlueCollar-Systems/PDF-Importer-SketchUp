#!/usr/bin/env ruby
# TEXTMODE-1: native SketchUp text APIs may fail per span.  The importer must
# deliver the nearest viable representation and record the substitution.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'

TextAlignLeft = 0 unless defined?(TextAlignLeft)

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
    def initialize(*)
    end

    def self.rotation(*)
      new
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)

class TextFallbackEntity
  attr_accessor :layer, :display_leader, :vector
end

class TextFallbackEntities
  attr_reader :labels, :mesh_calls

  def initialize(mesh_result, label_result)
    @mesh_result = mesh_result
    @label_result = label_result
    @labels = []
    @mesh_calls = []
    @entities = []
  end

  def to_a
    @entities
  end

  def add_3d_text(*)
    @mesh_calls << true
    raise 'forced mesh failure' if @mesh_result == :raise
    return false if @mesh_result == :false
    return true if @mesh_result == :empty

    @entities << TextFallbackEntity.new
    true
  end

  def add_text(*)
    raise 'forced label failure' if @label_result == :raise
    return nil if @label_result == :nil

    entity = TextFallbackEntity.new
    @labels << entity
    entity
  end

  def transform_entities(*)
  end
end

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

class GeometryBuilderTextFallbackTest < Minitest::Test
  Item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem

  def make_item
    Item.new('A1', 10.0, 20.0, 9.0, 0.0, 'Arial', nil, 10.0, 20.0, 25.0, 30.0)
  end

  def make_builder(use_3d_text, provenance, requested_text_mode = nil)
    BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
      nil, [], [], [0, 0, 612, 792],
      import_text: true,
      use_3d_text: use_3d_text,
      provenance_bucket: provenance,
      requested_text_mode: requested_text_mode
    )
  end

  def assert_mesh_to_label_fallback(mesh_result, reason)
    provenance = []
    builder = make_builder(true, provenance)
    entities = TextFallbackEntities.new(mesh_result, :success)

    builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    assert_equal 1, entities.labels.length
    assert_equal [
      { requested: :text3d, delivered: :labels, reason: reason, count: 1 }
    ], builder.text_fallbacks
    assert_equal 'native_label', provenance.last[:created_entity_type]
  end

  def test_false_mesh_result_delivers_a_label_and_records_the_fallback
    assert_mesh_to_label_fallback(:false, 'text3d_mesh_unavailable')
  end

  def test_empty_mesh_result_delivers_a_label_and_records_the_fallback
    assert_mesh_to_label_fallback(:empty, 'text3d_mesh_empty')
  end

  def test_mesh_exception_delivers_a_label_and_records_honest_provenance
    assert_mesh_to_label_fallback(:raise, 'text3d_exception')
  end

  def test_chained_geometry_mesh_failure_reports_the_original_requested_mode
    provenance = []
    builder = make_builder(true, provenance, :geometry)
    entities = TextFallbackEntities.new(:false, :success)

    builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    assert_equal [
      {
        requested: :geometry,
        delivered: :labels,
        reason: 'text3d_mesh_unavailable',
        count: 1
      }
    ], builder.text_fallbacks
  end

  def test_both_native_text_apis_failing_is_exposed_for_the_page_raster_terminal
    provenance = []
    builder = make_builder(true, provenance)
    entities = TextFallbackEntities.new(:false, :nil)

    delivered = builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    refute delivered
    assert_empty builder.text_fallbacks
    assert_equal [
      {
        requested: :text3d,
        reason: 'text3d_mesh_unavailable_labels_unavailable',
        count: 1
      }
    ], builder.text_delivery_failures
  end

  def test_unavailable_label_api_delivers_3d_text_and_records_honest_provenance
    provenance = []
    builder = make_builder(false, provenance)
    entities = TextFallbackEntities.new(:success, :nil)

    builder.send(:place_annotation_label, entities, make_item, 0.0, 0.0, 'Text')

    assert_equal 1, entities.mesh_calls.length
    assert_equal [
      { requested: :labels, delivered: :text3d, reason: 'add_text_unavailable', count: 1 }
    ], builder.text_fallbacks
    assert_equal 'native_3d_text', provenance.last[:created_entity_type]
  end
end
