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
  class ExplodingProvenanceBucket < Array
    def <<(_entry)
      raise 'forced provenance append failure'
    end
  end

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

    builder.send(
      :record_text_span_provenance, item, 'native_label',
      ['persistent_id:2001']
    )
    assert_equal 1, bucket.length
    entry = bucket[0]
    assert_equal 'text_span:2:7', entry[:span_id]
    assert_equal 'text_span:2:0', entry[:object_id],
                 'object_id stays a separate created-entity label'
    assert_equal [10.0, 20.0, 30.0, 40.0], entry[:source_bbox_pdf]

    builder.send(
      :record_text_span_provenance, item, 'native_label',
      ['persistent_id:2002']
    )
    assert_equal 'text_span:2:7', bucket[1][:span_id]
    assert_equal 'text_span:2:1', bucket[1][:object_id]
  end

  # An item with no assigned identity (legacy callers only) must not get a
  # fabricated bucket-index span_id — absence is honest and lets consumers
  # fall back to an explicit page-level result.
  def test_record_text_span_provenance_omits_span_id_when_unassigned
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

    builder.send(
      :record_text_span_provenance, item, 'native_label',
      ['persistent_id:1001']
    )
    assert_equal 1, bucket.length
    refute bucket[0].key?(:span_id),
           'no fabricated span_id for unassigned items (RB-01)'
    assert_equal 'text_span:1:0', bucket[0][:object_id]
  end

  def test_record_text_span_provenance_failure_is_counted
    builder = GB.allocate
    builder.instance_variable_set(:@provenance_bucket, ExplodingProvenanceBucket.new)
    builder.instance_variable_set(:@page_number, 1)
    builder.instance_variable_set(:@use_3d_text, true)
    builder.instance_variable_set(:@provenance_record_failure_count, 0)

    builder.send(
      :record_text_span_provenance, Object.new, 'native_3d_text',
      ['persistent_id:3001']
    )

    assert_equal 1, builder.provenance_record_failure_count
  end

  def test_record_text_span_provenance_rejects_unstable_resulting_ids
    bucket = []
    builder = GB.allocate
    builder.instance_variable_set(:@provenance_bucket, bucket)
    builder.instance_variable_set(:@page_number, 1)
    builder.instance_variable_set(:@use_3d_text, true)
    builder.instance_variable_set(:@provenance_record_failure_count, 0)

    [
      [],
      ['persistent_id:1', 'persistent_id:1'],
      ['synthetic_bucket:1']
    ].each do |ids|
      builder.send(
        :record_text_span_provenance, Object.new, 'native_3d_text', ids
      )
    end

    assert_empty bucket
    assert_equal 3, builder.provenance_record_failure_count
  end
end
