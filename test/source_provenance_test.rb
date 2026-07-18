#!/usr/bin/env ruby

require 'minitest/autorun'
require 'json'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/source_provenance'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false
SP = BlueCollarSystems::PDFVectorImporter::SourceProvenance

# Minimal stubs so GeometryBuilder can load headlessly for provenance unit tests.
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
    def self.scaling(*); new; end
  end
end
ORIGIN = Geom::Point3d.new(0, 0, 0)
Z_AXIS = Geom::Vector3d.new(0, 0, 1)
TextAlignLeft = 0 unless defined?(TextAlignLeft)
class Numeric
  def degrees
    self.to_f * Math::PI / 180.0
  end
end unless Numeric.method_defined?(:degrees)

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')
GB = BlueCollarSystems::PDFVectorImporter::GeometryBuilder

class SourceProvenanceTest < Minitest::Test
  def test_write_sidecar_schema
    Dir.mktmpdir('su_prov_') do |dir|
      pdf = File.join(dir, 'sample.pdf')
      File.write(pdf, 'sample')
      out = File.join(dir, 'sample_source_provenance.json')
      objects = [
        {
          object_id: 'text_span:1:0',
          page: 1,
          source_kind: 'text_span',
          created_entity_type: 'native_label',
          span_id: 'text_span:1:0'
        }
      ]
      path = SP.write_sidecar(
        output_path: out,
        import_session_id: 'test-session',
        pdf_path: pdf,
        objects: objects,
        version: '3.7.79',
        page_count: 1
      )
      assert_equal out, path
      data = JSON.parse(File.read(out))
      assert_equal 'bcs.source_provenance/1.0', data['schema']
      assert_equal 1, data['objects'].length
      assert_equal 'text_span:1:0', data['objects'][0]['span_id']
    end
  end

  # Corrective 2026-07-12 §1 (RB-01): GeometryBuilder emits the item's
  # TextSourceIdentity-assigned source_span_id as span_id — the SAME value
  # PartsBootstrap writes in row span_ids — so the sidecars join. It never
  # fabricates a bucket-index span_id (the shipped v3.7.92 defect).
  def test_record_text_span_provenance_emits_source_span_id
    bucket = []
    builder = GB.allocate
    builder.instance_variable_set(:@provenance_bucket, bucket)
    builder.instance_variable_set(:@page_number, 2)
    builder.instance_variable_set(:@use_3d_text, false)

    item = Object.new
    def item.bbox_x0; 10.0; end
    def item.bbox_y0; 20.0; end
    def item.bbox_x1; 30.0; end
    def item.bbox_y1; 40.0; end
    def item.source_span_id; 'text_span:2:7'; end
    def item.text; 'A'; end

    builder.send(
      :record_text_span_provenance, item, 'native_label',
      ['persistent_id:501'], :labels
    )
    assert_equal 1, bucket.length
    entry = bucket[0]
    assert_equal 'text_span:2:7', entry[:span_id]
    assert_equal Digest::SHA256.hexdigest('A'), entry[:source_text_sha256]
    assert_equal 'text_delivery:2:0', entry[:object_id],
                 'object_id stays a separate created-entity label'
    assert_equal [10.0, 20.0, 30.0, 40.0], entry[:source_bbox_pdf]

    builder.send(
      :record_text_span_provenance, item, 'native_label',
      ['persistent_id:502'], :labels
    )
    assert_equal 'text_span:2:7', bucket[1][:span_id]
    assert_equal 'text_delivery:2:1', bucket[1][:object_id]
  end

  # Missing source or resulting-entity identity cannot be emitted as partial
  # provenance: it must fail closed before contaminating the exact join set.
  def test_record_text_span_provenance_rejects_missing_source_identity
    bucket = []
    builder = GB.allocate
    builder.instance_variable_set(:@provenance_bucket, bucket)
    builder.instance_variable_set(:@page_number, 1)
    builder.instance_variable_set(:@use_3d_text, false)

    item = Object.new
    def item.bbox_x0; 10.0; end
    def item.bbox_y0; 20.0; end
    def item.bbox_x1; 30.0; end
    def item.bbox_y1; 40.0; end

    assert_raises(
      BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError
    ) do
      builder.send(
        :record_text_span_provenance, item, 'native_label',
        ['persistent_id:503'], :labels
      )
    end
    assert_empty bucket
  end

  def test_record_text_span_provenance_rejects_missing_result_identity
    bucket = []
    builder = GB.allocate
    builder.instance_variable_set(:@provenance_bucket, bucket)
    builder.instance_variable_set(:@page_number, 1)
    builder.instance_variable_set(:@use_3d_text, false)

    item = Object.new
    def item.source_span_id; 'text_span:1:0'; end

    assert_raises(
      BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError
    ) do
      builder.send(:record_text_span_provenance, item, 'native_label', [], :labels)
    end
    assert_empty bucket
  end
end
