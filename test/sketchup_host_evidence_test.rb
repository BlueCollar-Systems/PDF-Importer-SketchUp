#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'
require 'zlib'

module Sketchup; end unless defined?(Sketchup)

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
EVIDENCE_TOOL = File.join(
  REPO_ROOT, 'tools', 'sketchup_host_evidence.rb'
) unless defined?(EVIDENCE_TOOL)

class SketchupHostEvidenceTest < Minitest::Test
  class FakePoint
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x
      @y = y
      @z = z
    end
  end

  class FakeBounds
    attr_reader :min, :max

    def initialize(minimum, maximum)
      @min = minimum
      @max = maximum
    end
  end

  class FakeEntity
    attr_reader :entityID, :persistent_id, :typename, :bounds, :transformation

    def initialize(entity_id, typename, options = {})
      @entityID = entity_id
      @persistent_id = options.fetch(:persistent_id, entity_id + 1000)
      @typename = typename
      @valid = options.fetch(:valid, true)
      @deleted = options.fetch(:deleted, false)
      @bounds = options[:bounds]
      @transformation = options[:transformation]
      @attributes = options.fetch(:attributes, {})
    end

    def valid?
      @valid
    end

    def deleted?
      @deleted
    end

    def get_attribute(dictionary, key, default_value = nil)
      @attributes.fetch([dictionary, key], default_value)
    end

    def set_attribute(dictionary, key, value)
      @attributes[[dictionary, key]] = value
    end
  end

  class FakeGroup < FakeEntity
    attr_reader :entities

    def initialize(entity_id, children, options = {})
      super(entity_id, 'Group', options)
      @entities = children
    end
  end

  class CountingBoundsEntity < FakeEntity
    attr_reader :bounds_calls

    def initialize(entity_id, typename, options = {})
      super
      @bounds_calls = 0
    end

    def bounds
      @bounds_calls += 1
      @bounds
    end
  end

  class CountingCollection
    attr_reader :to_a_calls

    def initialize(values)
      @values = values
      @to_a_calls = 0
    end

    def to_a
      @to_a_calls += 1
      @values.dup
    end
  end

  class FakeText < FakeEntity
    attr_reader :text, :point

    def initialize(entity_id, options = {})
      super(entity_id, 'Text', options)
      @text = options.fetch(:text, 'A')
      @point = options.fetch(:point, FakePoint.new(1, 2, 0))
      @leader_visible = options.fetch(:leader_visible, false)
    end

    def display_leader?
      @leader_visible
    end
  end

  class FakeDefinition
    attr_reader :entities

    def initialize(children)
      @entities = children
    end
  end

  class FakeComponent < FakeEntity
    attr_reader :definition

    def initialize(entity_id, children, options = {})
      super(entity_id, 'ComponentInstance', options)
      @definition = options[:definition] || FakeDefinition.new(children)
    end
  end

  class FakeImage < FakeEntity
    attr_reader :width, :height

    def initialize(entity_id, options = {})
      super(entity_id, 'Image', options)
      @width = options.fetch(:width, 8.5)
      @height = options.fetch(:height, 11.0)
      @attributes = options.fetch(:attributes, {})
    end

    def get_attribute(dictionary, key, default_value = nil)
      @attributes.fetch([dictionary, key], default_value)
    end
  end

  class FakeTextureWriter
    attr_accessor :source_path

    def initialize(source_path, options = {})
      @source_path = source_path
      @status = options.fetch(:status, 0)
      @load_result = options.fetch(:load_result, 1)
      @write_file = options.fetch(:write_file, true)
    end

    def load(_entity)
      @load_result
    end

    def write(_entity, destination)
      FileUtils.cp(@source_path, destination) if @write_file
      @status
    end
  end

  def setup
    assert File.file?(EVIDENCE_TOOL),
           'tools/sketchup_host_evidence.rb must exist'
    load EVIDENCE_TOOL unless defined?(SketchupHostEvidence)
  end

  def with_texture_writer(writer)
    singleton = class << Sketchup; self; end
    original = Sketchup.method(:create_texture_writer) if
      Sketchup.respond_to?(:create_texture_writer)
    singleton.send(:define_method, :create_texture_writer) { writer }
    yield
  ensure
    if original
      singleton.send(:define_method, :create_texture_writer, original)
    elsif singleton && Sketchup.respond_to?(:create_texture_writer)
      singleton.send(:remove_method, :create_texture_writer)
    end
  end

  def png_chunk(type, payload)
    [payload.bytesize].pack('N') + type + payload +
      [Zlib.crc32(type + payload)].pack('N')
  end

  def write_rgba_png(path, width, height, pixels)
    rows = ''.dup
    rows.force_encoding(Encoding::BINARY) if rows.respond_to?(:force_encoding)
    height.times do |row|
      rows << "\x00"
      rows << pixels.slice(row * width, width).flatten.pack('C*')
    end
    signature = "\x89PNG\r\n\x1a\n".dup
    signature.force_encoding(Encoding::BINARY) if
      signature.respond_to?(:force_encoding)
    ihdr = [width, height, 8, 6, 0, 0, 0].pack('N2C5')
    File.open(path, 'wb') do |file|
      file.write(signature)
      file.write(png_chunk('IHDR', ihdr))
      file.write(png_chunk('IDAT', Zlib::Deflate.deflate(rows)))
      file.write(png_chunk('IEND', ''.dup))
    end
  end

  def raster_image_with_visual_sha(visual_sha)
    dictionary = 'BC_PDF_Importer'
    FakeImage.new(70, :persistent_id => 7070, :attributes => {
      [dictionary, 'raster_page_number'] => 1,
      [dictionary, 'raster_pixel_width'] => 2,
      [dictionary, 'raster_pixel_height'] => 1,
      [dictionary, 'raster_content_sha256'] => 'a' * 64,
      [dictionary, 'raster_visual_pixel_sha256'] => visual_sha,
      [dictionary, 'raster_content_bytes'] => 100,
      [dictionary, 'raster_source_pdf_sha256'] => 'b' * 64
    })
  end

  def test_texture_writer_pixels_are_physical_and_survive_reopen_verification
    Dir.mktmpdir('bc_texture_writer_test_') do |directory|
      first_path = File.join(directory, 'first.png')
      second_path = File.join(directory, 'second.png')
      first_pixels = [[255, 0, 0, 255], [0, 255, 0, 255]]
      second_pixels = [[0, 0, 255, 255], [0, 255, 0, 255]]
      write_rgba_png(first_path, 2, 1, first_pixels)
      write_rgba_png(second_path, 2, 1, second_pixels)
      expected_sha = Digest::SHA256.hexdigest(first_pixels.flatten.pack('C*'))
      writer = FakeTextureWriter.new(first_path)
      image = raster_image_with_visual_sha(expected_sha)

      saved = with_texture_writer(writer) do
        SketchupHostEvidence.snapshot_entities([image])
      end
      content = saved.first['content_evidence']
      assert_equal true, content['host_texture_export_verified']
      assert_equal expected_sha, content['host_visual_pixel_sha256']
      assert_equal 2, content['host_pixel_width']
      assert_equal 1, content['host_pixel_height']

      writer.source_path = second_path
      reopened = with_texture_writer(writer) do
        SketchupHostEvidence.snapshot_entities([image])
      end
      error = assert_raises(StandardError) do
        SketchupHostEvidence.verify_reopen_continuity!(saved, reopened)
      end
      assert_match(/content/i, error.message)
    end
  end

  def test_texture_writer_nonzero_status_fails_closed
    Dir.mktmpdir('bc_texture_writer_test_') do |directory|
      png_path = File.join(directory, 'source.png')
      pixels = [[255, 0, 0, 255], [0, 255, 0, 255]]
      write_rgba_png(png_path, 2, 1, pixels)
      image = raster_image_with_visual_sha(
        Digest::SHA256.hexdigest(pixels.flatten.pack('C*'))
      )
      error = assert_raises(StandardError) do
        with_texture_writer(FakeTextureWriter.new(png_path, :status => 7)) do
          SketchupHostEvidence.snapshot_entities([image])
        end
      end
      assert_match(/status 7/, error.message)
    end
  end

  def test_texture_writer_missing_output_fails_closed
    image = raster_image_with_visual_sha('c' * 64)
    writer = FakeTextureWriter.new('unused.png', :write_file => false)
    error = assert_raises(StandardError) do
      with_texture_writer(writer) do
        SketchupHostEvidence.snapshot_entities([image])
      end
    end
    assert_match(/without an output file/, error.message)
  end

  def test_texture_writer_decoder_rejection_fails_closed
    Dir.mktmpdir('bc_texture_writer_test_') do |directory|
      invalid_path = File.join(directory, 'invalid.png')
      File.open(invalid_path, 'wb') { |file| file.write('not a PNG') }
      error = assert_raises(StandardError) do
        with_texture_writer(FakeTextureWriter.new(invalid_path)) do
          SketchupHostEvidence.snapshot_entities([
            raster_image_with_visual_sha('d' * 64)
          ])
        end
      end
      assert_match(/PNG|texture pixel evidence/i, error.message)
    end
  end

  def test_source_location_must_be_genuinely_below_expected_root
    expected = 'C:/work/sketchup_ext'
    inside = 'c:\\WORK\\SKETCHUP_EXT\\bc_pdf_vector_importer\\main.rb'
    sibling = 'C:/work/sketchup_ext-old/bc_pdf_vector_importer/main.rb'

    assert SketchupHostEvidence.verify_source_locations!(
      expected,
      'run_pipeline' => [inside, 42]
    )
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_source_locations!(
        expected,
        'run_pipeline' => [sibling, 42]
      )
    end
    assert_match(/outside expected source root/, error.message)
  end

  def test_missing_source_location_fails_closed
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_source_locations!(
        'C:/work/sketchup_ext', 'renderer' => nil
      )
    end
    assert_match(/source location/, error.message)

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_source_locations!(
        'C:/work/sketchup_ext',
        'renderer' => ['C:/work/sketchup_ext/renderer.rb', 4.5]
      )
    end
    assert_match(/source location|Integer|line/i, error.message)
  end

  def test_nested_groups_and_components_produce_recursive_manifest_rows
    bounds = FakeBounds.new(
      FakePoint.new(1, 2, 3), FakePoint.new(4, 5, 6)
    )
    matrix = (0..15).to_a
    edge = FakeEntity.new(11, 'Edge', :bounds => bounds)
    face = FakeEntity.new(13, 'Face', :valid => false, :deleted => true)
    component = FakeComponent.new(12, [face])
    group = FakeGroup.new(
      10, [edge, component],
      :bounds => bounds, :transformation => matrix
    )

    manifest = SketchupHostEvidence.snapshot_entities([group])
    root = manifest.first
    assert_equal 10, root['entity_id']
    assert_equal 'Group', root['typename']
    assert_equal true, root['valid']
    assert_equal false, root['deleted']
    assert_equal({
      'min' => [1.0, 2.0, 3.0],
      'max' => [4.0, 5.0, 6.0]
    }, root['bounds'])
    assert_equal matrix.map { |value| value.to_f }, root['transformation']
    assert_equal [11, 12],
                 root['children'].map { |row| row['entity_id'] }
    nested = root['children'].last['children'].first
    assert_equal 13, nested['entity_id']
    assert_equal false, nested['valid']
    assert_equal true, nested['deleted']
    assert_equal [10, 11, 12, 13],
                 SketchupHostEvidence.manifest_entity_ids(manifest).sort
  end

  def test_snapshot_enumerates_each_nested_collection_once
    leaf = FakeEntity.new(31, 'Edge')
    nested_entities = CountingCollection.new([leaf])
    nested = FakeGroup.new(30, nested_entities)
    root_entities = CountingCollection.new([nested])
    root = FakeGroup.new(29, root_entities)

    manifest = SketchupHostEvidence.snapshot_entities([root])

    assert_equal [29, 30, 31],
                 SketchupHostEvidence.manifest_entity_ids(manifest)
    assert_equal 1, root_entities.to_a_calls,
                 'root host children must be enumerated once per snapshot'
    assert_equal 1, nested_entities.to_a_calls,
                 'nested host children must be enumerated once per snapshot'
  end

  def test_compact_snapshot_reuses_shared_component_definition_tree
    dictionary = 'BC_PDF_Importer'
    definition_entities = CountingCollection.new([
      FakeEntity.new(35, 'Face'),
      FakeEntity.new(36, 'Edge')
    ])
    definition = FakeDefinition.new(definition_entities)
    first = FakeComponent.new(
      37, [], :definition => definition,
      :transformation => [1, 0, 0, 0, 0, 1, 0, 0,
                          0, 0, 1, 0, 10, 20, 0, 1]
    )
    second = FakeComponent.new(
      38, [], :definition => definition,
      :transformation => [1, 0, 0, 0, 0, 1, 0, 0,
                          0, 0, 1, 0, 30, 40, 0, 1]
    )
    claim = FakeGroup.new(
      34, [first, second],
      :attributes => {
        [dictionary, 'source_span_id'] => 'text_span:1:0',
        [dictionary, 'source_kind'] => 'text_span',
        [dictionary, 'representation'] => 'text3d',
        [dictionary, 'renderer'] => 'svg_source_3d_text',
        [dictionary, 'source_claim_root'] => true
      }
    )

    row = SketchupHostEvidence.snapshot_entities(
      [claim], :compact => true
    ).first

    assert_equal 1, definition_entities.to_a_calls,
                 'a shared definition must be read once per compact snapshot'
    topology = row['geometry_evidence']['topology']
    assert_equal ['ComponentInstance', 'ComponentInstance'],
                 topology['direct_child_types']
    assert_equal 2, topology['descendant_type_counts']['ComponentInstance']
    assert_equal 2, topology['descendant_type_counts']['Face']
    assert_equal 2, topology['descendant_type_counts']['Edge']
    assert_empty row['children']
  end

  def test_physical_evidence_cache_reuses_definition_but_keeps_instance_transform
    definition_entities = CountingCollection.new([
      FakeEntity.new(135, 'Face'),
      FakeEntity.new(136, 'Edge')
    ])
    definition = FakeDefinition.new(definition_entities)
    first = FakeComponent.new(
      137, [], :definition => definition,
      :transformation => [1, 0, 0, 0, 0, 1, 0, 0,
                          0, 0, 1, 0, 10, 20, 0, 1]
    )
    second = FakeComponent.new(
      138, [], :definition => definition,
      :transformation => [1, 0, 0, 0, 0, 1, 0, 0,
                          0, 0, 1, 0, 30, 40, 0, 1]
    )
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    cache = {}

    first_physical = fidelity.physical_evidence([first], cache)
    second_physical = fidelity.physical_evidence([second], cache)

    assert_equal 1, definition_entities.to_a_calls,
                 'shared immutable definition must be enumerated once'
    refute_equal first_physical[:physical_geometry_sha256],
                 second_physical[:physical_geometry_sha256],
                 'each component instance transform remains independently hashed'
    assert_equal 1, cache.length
  end

  def test_snapshot_reads_each_entity_bounds_once
    bounds = FakeBounds.new(
      FakePoint.new(1, 2, 3), FakePoint.new(4, 5, 6)
    )
    entity = CountingBoundsEntity.new(32, 'Face', :bounds => bounds)

    row = SketchupHostEvidence.snapshot_entities([entity]).first

    assert_equal({
      'min' => [1.0, 2.0, 3.0],
      'max' => [4.0, 5.0, 6.0]
    }, row['bounds'])
    assert_equal 1, entity.bounds_calls,
                 'physical evidence and manifest must share one bounds read'
  end

  def test_compact_snapshot_partitions_raw_geometry_under_claim_roots
    dictionary = 'BC_PDF_Importer'
    claim = FakeGroup.new(
      42, [FakeEntity.new(43, 'Face')],
      :attributes => {
        [dictionary, 'source_span_id'] => 'text_span:1:0',
        [dictionary, 'source_kind'] => 'text_span',
        [dictionary, 'representation'] => 'text3d',
        [dictionary, 'renderer'] => 'svg_source_3d_text',
        [dictionary, 'source_claim_root'] => true
      }
    )
    page = FakeGroup.new(40, [FakeEntity.new(41, 'Edge'), claim])

    manifest = SketchupHostEvidence.snapshot_entities(
      [page], :compact => true
    )

    assert_equal [40, 42],
                 SketchupHostEvidence.manifest_entity_ids(manifest).sort
    assert_equal [42], manifest.first['children'].map { |row| row['entity_id'] }
    assert_empty manifest.first['children'].first['children']
    assert_equal 2,
                 manifest.first['geometry_evidence']['physical_entity_count']
    assert_equal 2,
                 manifest.first['children'].first['geometry_evidence'][
                   'physical_entity_count'
                 ]
    assert_equal({
      'root_type' => 'Group',
      'direct_child_types' => ['Face'],
      'descendant_type_counts' => { 'Face' => 1 },
      'descendant_entity_count' => 1,
      'live_entity_count' => 2
    }, manifest.first['children'].first['geometry_evidence']['topology'])
    refute manifest.first['geometry_evidence'].key?('payload')
  end

  def test_compact_snapshot_keeps_native_face_and_edge_claim_roots_expanded
    dictionary = 'BC_PDF_Importer'
    attributes = {
      [dictionary, 'source_span_id'] => 'text_span:1:0',
      [dictionary, 'source_kind'] => 'text_span',
      [dictionary, 'representation'] => 'text3d',
      [dictionary, 'renderer'] => 'sketchup_native_3d_text',
      [dictionary, 'source_claim_root'] => true
    }
    bounds = FakeBounds.new(
      FakePoint.new(0, 0, 0), FakePoint.new(1, 1, 0.1)
    )
    face = FakeEntity.new(
      44, 'Face', :attributes => attributes.dup, :bounds => bounds
    )
    edge = FakeEntity.new(
      45, 'Edge', :attributes => attributes.dup, :bounds => bounds
    )

    manifest = SketchupHostEvidence.snapshot_entities(
      [face, edge], :compact => true
    )

    assert_equal [44, 45], manifest.map { |row| row['entity_id'] }
    manifest.each do |row|
      refute_equal 'bcs.host_physical_partition/1.0',
                   row['geometry_evidence']['schema']
      assert row['geometry_evidence']['payload'].is_a?(Array)
      assert row['style_evidence']['payload'].is_a?(Array)
    end
  end

  def test_nested_item_raster_claim_survives_compact_snapshot_and_binding
    dictionary = 'BC_PDF_Importer'
    sha256 = 'a' * 64
    source_sha256 = 'b' * 64
    image = FakeImage.new(52, :attributes => {
      [dictionary, 'source_claim_root'] => true,
      [dictionary, 'source_span_id'] => 'text_span:1:0',
      [dictionary, 'source_kind'] => 'text_span',
      [dictionary, 'representation'] => 'raster',
      [dictionary, 'renderer'] => 'pdftocairo_transparent_page_crop',
      [dictionary, 'raster_page_number'] => 1,
      [dictionary, 'raster_pixel_width'] => 120,
      [dictionary, 'raster_pixel_height'] => 40,
      [dictionary, 'raster_content_sha256'] => sha256,
      [dictionary, 'raster_content_bytes'] => 4800,
      [dictionary, 'raster_source_pdf_sha256'] => source_sha256,
      [dictionary, 'raster_alpha_verified'] => true,
      [dictionary, 'raster_transparent_background_verified'] => true,
      [dictionary, 'raster_visible_pixel_verified'] => true,
      [dictionary, 'raster_page_render_once_verified'] => true,
      [dictionary, 'raster_page_render_sha256'] => sha256
    })
    page = FakeGroup.new(50, [image])
    manifest = SketchupHostEvidence.snapshot_entities(
      [page], :compact => true
    )
    row = manifest.first['children'].first
    record = {
      :page => 1, :source_span_id => 'text_span:1:0',
      :requested_mode => :labels, :delivered_mode => :raster,
      :created_entity_type => 'raster_image',
      :real_raster_verified => true, :visual_fidelity_verified => true,
      :source_crop_binding_verified => true,
      :delivery_scope => :item_raster, :cleanup_outcome => :not_required,
      :artifact_evidence => {
        :source_span_id => 'text_span:1:0', :page_number => 1,
        :png_signature_verified => true, :page_binding_verified => true,
        :source_crop_binding_verified => true,
        :source_pdf_path => 'C:/fixtures/source.pdf',
        :source_pdf_sha256 => source_sha256,
        :source_pdf_binding_verified => true,
        :source_box => [10.0, 20.0, 40.0, 30.0],
        :pixel_crop => [100, 200, 120, 40],
        :pixel_width => 120, :pixel_height => 40,
        :alpha_channel_verified => true,
        :transparent_background_verified => true,
        :visible_pixel_verified => true,
        :page_render_once_verified => true,
        :page_render_content_sha256 => sha256,
        :content_sha256 => sha256, :content_byte_size => 4800
      }
    }

    assert_equal true,
                 row['representation_evidence']['source_claim_root']
    assert_equal 'raster', row['representation_evidence']['representation']
    assert_equal 'pdftocairo_transparent_page_crop',
                 row['representation_evidence']['renderer']
    assert SketchupHostEvidence.send(
      :verify_raster_artifact_binding!, record, row, 'entity_id:52', [1],
      { :normalized_input_sha256 => source_sha256 }
    )
  end

  def test_source_evidence_is_attached_to_owned_root_not_every_face
    child = FakeEntity.new(51, 'Face')
    root = FakeGroup.new(50, [child])
    evidence = {
      :schema => 'bcs.source_expected/1.0',
      :source_span_id => 'text_span:1:0',
      :representation => :text3d,
      :source_text_sha256 => 'a' * 64,
      :physical_geometry_sha256 => 'b' * 64,
      :physical_style_sha256 => 'c' * 64,
      :evidence_sha256 => 'd' * 64
    }
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity

    assert fidelity.attach_source_evidence!([root], evidence, 'fixture')

    assert_equal true,
                 root.get_attribute('BC_PDF_Importer', 'source_claim_root')
    assert_equal 'text_span:1:0',
                 root.get_attribute('BC_PDF_Importer', 'source_span_id')
    assert_nil child.get_attribute('BC_PDF_Importer', 'source_span_id')
  end

  def test_snapshot_preserves_representation_identity_attributes
    entity = FakeGroup.new(20, [FakeEntity.new(21, 'Edge')],
      :attributes => {
        ['BC_PDF_Importer', 'source_span_id'] => 'text_span:1:0',
        ['BC_PDF_Importer', 'source_kind'] => 'text_span',
        ['BC_PDF_Importer', 'representation'] => 'geometry',
        ['BC_PDF_Importer', 'renderer'] => 'svg_item_flat_geometry_renderer'
      })

    row = SketchupHostEvidence.snapshot_entities([entity]).first
    assert_equal({
      'source_span_id' => 'text_span:1:0',
      'source_unit_id' => nil,
      'source_kind' => 'text_span',
      'representation' => 'geometry',
      'renderer' => 'svg_item_flat_geometry_renderer'
    }, row['representation_evidence'])
  end

  def test_duplicate_manifest_identities_fail_even_when_typenames_match
    duplicate_entity_id = [{
      'entity_id' => 10, 'persistent_id' => 1010, 'typename' => 'Group',
      'children' => [{
        'entity_id' => 10, 'persistent_id' => 1011, 'typename' => 'Group',
        'children' => []
      }]
    }]
    duplicate_persistent_id = [{
      'entity_id' => 10, 'persistent_id' => 1010, 'typename' => 'Group',
      'children' => [{
        'entity_id' => 11, 'persistent_id' => 1010, 'typename' => 'Group',
        'children' => []
      }]
    }]

    [duplicate_entity_id, duplicate_persistent_id].each do |rows|
      error = assert_raises(StandardError) do
        SketchupHostEvidence.manifest_identity_sets(rows)
      end
      assert_match(/duplicate/i, error.message)
    end
  end

  def test_delivery_ids_are_cross_checked_against_nested_manifest
    stats = ready_stats(
      :terminal_text_delivery_records => [{
        :resulting_entity_ids => [13]
      }]
    )
    assert SketchupHostEvidence.verify_delivery_evidence!(stats, manifest)
  end

  def test_tagged_entity_id_delivery_is_cross_checked_against_manifest
    stats = ready_stats(
      :terminal_text_delivery_records => [{
        :resulting_entity_ids => ['entity_id:13']
      }]
    )
    assert SketchupHostEvidence.verify_delivery_evidence!(stats, manifest)
  end

  def test_persistent_id_delivery_does_not_substitute_for_entity_id
    stats = ready_stats(
      :terminal_text_delivery_records => [{
        :resulting_entity_ids => ['persistent_id:13']
      }]
    )
    assert SketchupHostEvidence.verify_delivery_evidence!(stats, manifest)
  end

  def test_manifest_records_both_identity_namespaces_and_checks_each_claim
    rows = SketchupHostEvidence.snapshot_entities([
      FakeText.new(13, :persistent_id => 7013)
    ])
    assert_equal 13, rows[0]['entity_id']
    assert_equal 7013, rows[0]['persistent_id']
    decorate_fixture_manifest!(rows, :labels, 'text_span:1:0', 'A')

    valid = ready_stats(:terminal_text_delivery_records => [{
        :resulting_entity_ids => ['persistent_id:7013'],
        :source_span_ids => ['text_span:1:0'],
        :source_text_sha256 => Digest::SHA256.hexdigest('A'),
        :requested_mode => :labels, :delivered_mode => :labels
      }])
    valid[:text_attempts][0][:resulting_entity_ids] = ['persistent_id:7013']
    valid[:text_attempts][0][:attempt_history][0][:resulting_entity_ids] =
      ['persistent_id:7013']
    valid[:source_provenance_objects][0][:resulting_entity_ids] =
      ['persistent_id:7013']
    assert SketchupHostEvidence.verify_delivery_evidence!(
      valid,
      rows,
      :labels,
      [1]
    )
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        ready_stats(:terminal_text_delivery_records => [{
          :resulting_entity_ids => ['persistent_id:13'],
          :source_span_ids => ['text_span:1:0'],
          :source_text_sha256 => Digest::SHA256.hexdigest('A'),
          :requested_mode => :labels, :delivered_mode => :labels
        }]),
        rows,
        :labels,
        [1]
      )
    end
    assert_match(/persistent_id/, error.message)
  end

  def test_reopen_continuity_uses_persistent_id_not_changed_entity_id
    before = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(10, [
        FakeEntity.new(11, 'Face', :persistent_id => 7011)
      ], :persistent_id => 7010)
    ])
    reopened = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(90, [
        FakeEntity.new(91, 'Face', :persistent_id => 7011)
      ], :persistent_id => 7010)
    ])

    assert SketchupHostEvidence.verify_reopen_continuity!(before, reopened)
  end

  def test_reopen_continuity_rejects_changed_transform_for_same_persistent_id
    before = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(10, [],
                    :persistent_id => 7010,
                    :transformation => (0..15).to_a)
    ])
    reopened = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(90, [],
                    :persistent_id => 7010,
                    :transformation => (1..16).to_a)
    ])
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_reopen_continuity!(before, reopened)
    end
    assert_match(/transformation/, error.message)
  end

  def test_reopen_continuity_rejects_deleted_rows_and_changed_parentage
    saved = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(10, [
        FakeEntity.new(11, 'Edge', :persistent_id => 7011)
      ], :persistent_id => 7010)
    ])
    deleted = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(90, [
        FakeEntity.new(91, 'Edge', :persistent_id => 7011,
                       :valid => false, :deleted => true)
      ], :persistent_id => 7010)
    ])
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_reopen_continuity!(saved, deleted)
    end
    assert_match(/live|deleted|valid/i, error.message)

    reparented = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(90, [], :persistent_id => 7010),
      FakeEntity.new(91, 'Edge', :persistent_id => 7011)
    ])
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_reopen_continuity!(saved, reparented)
    end
    assert_match(/child|parent|structure/i, error.message)
  end

  def test_owned_reopen_continuity_ignores_preexisting_template_entities
    owned = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(10, [], :persistent_id => 7010)
    ])
    reopened = SketchupHostEvidence.snapshot_entities([
      FakeEntity.new(50, 'Edge', :persistent_id => 5000),
      FakeGroup.new(90, [], :persistent_id => 7010)
    ])

    assert SketchupHostEvidence.verify_owned_reopen_continuity!(
      owned, reopened
    )
  end

  def test_recursive_ownership_rejects_preexisting_nested_entities
    before = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(1, [FakeEntity.new(2, 'Edge')])
    ])
    after = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(1, [FakeEntity.new(2, 'Edge')]),
      FakeGroup.new(10, [FakeEntity.new(11, 'Face')])
    ])
    owned = SketchupHostEvidence.owned_manifest(before, after)
    assert_equal [10, 11],
                 SketchupHostEvidence.manifest_entity_ids(owned).sort
  end

  def test_missing_ledger_is_not_coerced_to_empty
    stats = ready_stats
    stats.delete(:text_source_span_ids)
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(stats, label_manifest, :labels, [1])
    end
    assert_match(/text_source_span_ids.*missing/, error.message)
  end

  def test_empty_text_ledger_requires_decoded_stream_no_text_proof
    immutable_sha = 'a' * 64
    rendered_sha = 'b' * 64
    stats = ready_stats(
      :text_source_span_ids => [],
      :text_attempts => [],
      :source_provenance_objects => [],
      :empty_page_source_inspections => [],
      :source_input_sha256 => immutable_sha,
      :normalized_input_sha256 => rendered_sha
    )
    error = assert_raises(StandardError) do
        SketchupHostEvidence.verify_delivery_evidence!(stats, label_manifest, :labels, [1])
    end
    assert_match(/decoded-stream no-text proof/, error.message)

    stats[:empty_page_source_inspections] = [{
      :page => 1,
      :source_page_number => 1,
      :canonical_text_item_count => 0,
      :immutable_pdf_sha256 => immutable_sha,
      :rendered_pdf_sha256 => rendered_sha,
      :semantic_text_extraction_complete => true,
      :decoded_stream_text_operators => false,
      :decoded_form_stream_text_operators => false
    }]
    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, label_manifest, :labels, [1]
    )

    terminal_schema = Marshal.load(Marshal.dump(stats))
    terminal_schema[:immutable_pdf_sha256] =
      terminal_schema.delete(:source_input_sha256)
    terminal_schema[:normalized_pdf_sha256] =
      terminal_schema.delete(:normalized_input_sha256)
    assert SketchupHostEvidence.verify_delivery_evidence!(
      terminal_schema, label_manifest, :labels, [1]
    )

    conflicting_schema = Marshal.load(Marshal.dump(stats))
    conflicting_schema[:immutable_pdf_sha256] = 'c' * 64
    conflicting_schema[:normalized_pdf_sha256] = 'd' * 64
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        conflicting_schema, label_manifest, :labels, [1]
      )
    end
    assert_match(/source|sha|conflict/i, error.message)

    mutations = {
      :source_page_number => 2,
      :canonical_text_item_count => 1,
      :immutable_pdf_sha256 => 'c' * 64,
      :rendered_pdf_sha256 => 'd' * 64
    }
    mutations.each do |field, value|
      invalid = Marshal.load(Marshal.dump(stats))
      invalid[:empty_page_source_inspections][0][field] = value
      error = assert_raises(StandardError, "#{field} must be source-bound") do
        SketchupHostEvidence.verify_delivery_evidence!(
          invalid, label_manifest, :labels, [1]
        )
      end
      assert_match(/empty|source|page|canonical|sha/i, error.message)
    end
  end

  def test_source_span_attempt_and_delivery_sets_must_be_equal
    stats = ready_stats(
      :text_source_span_ids => ['text_span:1:0', 'text_span:1:1'],
      :text_attempts => [{
        :source_span_id => 'text_span:1:0',
        :requested_mode => :labels,
        :resulting_entity_ids => ['entity_id:13']
      }],
      :source_provenance_objects => [{
        :span_id => 'text_span:1:0',
        :resulting_entity_ids => ['entity_id:13']
      }]
    )
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(stats, label_manifest, :labels, [1])
    end
    assert_match(/source.*set mismatch/, error.message)
  end

  def test_geometry_and_glyph_ledgers_reject_count_only_plural_source_span_ids
    [:geometry, :glyphs].each do |mode|
      stats = ready_stats(
        :requested_text_mode => mode,
        :text_source_span_ids => ['text_span:1:0', 'text_span:1:1'],
        :text_attempts => [{
          :page => 1,
          :source_span_ids => ['text_span:1:0', 'text_span:1:1'],
          :requested_mode => mode, :delivered_mode => mode,
          :resulting_entity_ids => ['entity_id:13'],
          :visual_fidelity_verified => true,
          :attempt_history => [{
            :mode => mode, :outcome => :complete,
            :resulting_entity_ids => ['entity_id:13'],
            :visual_fidelity_verified => true,
            :cleanup_outcome => :not_required
          }]
        }],
        :source_provenance_objects => [],
        :page_text_delivery_records => [{
          :page => 1,
          :source_span_ids => ['text_span:1:0', 'text_span:1:1'],
          :requested_mode => mode, :delivered_mode => mode,
          :created_entity_type => mode == :geometry ?
            'page_path_geometry' : 'glyph_outline',
          :visual_fidelity_verified => true,
          :resulting_entity_ids => ['entity_id:13']
        }]
      )

      error = assert_raises(StandardError) do
        SketchupHostEvidence.verify_delivery_evidence!(
          stats, mode == :geometry ? geometry_manifest : glyph_manifest,
          mode, [1]
        )
      end
      assert_match(/independently owned source item|one.*source/i, error.message)
    end
  end

  def test_strict_evidence_rejects_self_declared_geometry_for_labels_job
    stats = strict_page_mode_stats(:labels, :geometry, 1)

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, label_manifest, :labels, [1]
      )
    end
    assert_match(/requested.*mode/i, error.message)
  end

  def test_strict_evidence_rejects_span_evidence_outside_selected_pages
    stats = strict_page_mode_stats(:labels, :labels, 2)

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, label_manifest, :labels, [1]
      )
    end
    assert_match(/selected page/i, error.message)
  end

  def test_strict_page_identities_reject_lossy_numeric_coercion
    stats = strict_page_mode_stats(:labels, :labels, 1)
    stats[:text_attempts][0][:page] = 1.5
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, label_manifest, :labels, [1]
      )
    end
    assert_match(/page/i, error.message)

    stats = strict_page_mode_stats(:labels, :labels, 1)
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, label_manifest, :labels, [1.5]
      )
    end
    assert_match(/page/i, error.message)

    stats = strict_item_fallback_stats
    proof = stats[:text_attempts][0][:attempt_history][0][:transition_proof]
    proof[:page_number] = 1.5
    stats[:fallback_transitions] = [proof.dup]
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, text3d_manifest, :labels, [1]
      )
    end
    assert_match(/proof|page|transition/i, error.message)
  end

  def test_nonraster_delivery_must_match_actual_host_representation
    labels = strict_page_mode_stats(:labels, :labels, 1)
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        labels, geometry_manifest, :labels, [1]
      )
    end
    assert_match(/Labels|Text|representation|typename/i, error.message)

    text3d = strict_text3d_stats
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        text3d, geometry_manifest, :text3d, [1]
      )
    end
    assert_match(/3D|representation|depth|identity/i, error.message)

    geometry = strict_page_mode_stats(:geometry, :geometry, 1)
    glyphs = strict_page_mode_stats(:glyphs, :glyphs, 1)
    assert SketchupHostEvidence.verify_delivery_evidence!(
      geometry, geometry_manifest, :geometry, [1]
    )
    assert SketchupHostEvidence.verify_delivery_evidence!(
      glyphs, glyph_manifest, :glyphs, [1]
    )
    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        geometry, glyph_manifest, :geometry, [1]
      )
    end
    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        glyphs, geometry_manifest, :glyphs, [1]
      )
    end
  end

  def test_label_delivery_is_bound_to_the_saved_text_content
    stats = ready_stats
    stats[:text_attempts][0][:source_text_sha256] =
      Digest::SHA256.hexdigest('A')
    wrong = Marshal.load(Marshal.dump(label_manifest))
    wrong[0]['content_evidence']['text'] = 'B'

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, wrong, :labels, [1]
      )
    end
    assert_match(/content|digest|text/i, error.message)
  end

  def test_duplicate_source_identity_inside_one_delivery_record_fails
    stats = strict_page_mode_stats(:geometry, :geometry, 1)
    stats[:text_attempts][0][:source_span_ids] = [
      'text_span:1:0', 'text_span:1:0'
    ]

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, geometry_manifest, :geometry, [1]
      )
    end
    assert_match(/duplicate|source span/i, error.message)
  end

  def test_two_item_sources_cannot_claim_the_same_host_entity
    first = 'text_span:1:0'
    second = 'text_span:1:1'
    entity_id = 'entity_id:13'
    completed = lambda do |source_id|
      {
        :source_span_id => source_id, :page => 1,
        :source_text_sha256 => Digest::SHA256.hexdigest('A'),
        :requested_mode => :labels, :delivered_mode => :labels,
        :resulting_entity_ids => [entity_id],
        :visual_fidelity_verified => true,
        :attempt_history => [{
          :mode => :labels, :outcome => :complete,
          :resulting_entity_ids => [entity_id],
          :visual_fidelity_verified => true,
          :cleanup_outcome => :not_required
        }]
      }
    end
    stats = ready_stats(
      :text_source_span_ids => [first, second],
      :text_attempts => [completed.call(first), completed.call(second)],
      :source_provenance_objects => [
        { :span_id => first, :page => 1,
          :resulting_entity_ids => [entity_id] },
        { :span_id => second, :page => 1,
          :resulting_entity_ids => [entity_id] }
      ]
    )

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, label_manifest, :labels, [1]
      )
    end
    assert_match(/alias|duplicate|ownership|same host entity/i, error.message)

    stats[:text_attempts][1][:resulting_entity_ids] = ['persistent_id:1013']
    stats[:text_attempts][1][:attempt_history][0][:resulting_entity_ids] =
      ['persistent_id:1013']
    stats[:source_provenance_objects][1][:resulting_entity_ids] =
      ['persistent_id:1013']
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, label_manifest, :labels, [1]
      )
    end
    assert_match(/alias|duplicate|ownership|same host entity/i, error.message)
  end

  def test_delivery_rejects_deleted_or_invalid_nested_physical_entities
    stats = strict_page_mode_stats(:geometry, :geometry, 1)
    rows = Marshal.load(Marshal.dump(geometry_manifest))
    rows[0]['children'][0]['valid'] = false
    rows[0]['children'][0]['deleted'] = true

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, rows, :geometry, [1]
      )
    end
    assert_match(/live|deleted|physical/i, error.message)
  end

  def test_requested_raster_requires_real_image_manifest_content_binding
    sha256 = 'a' * 64
    source_sha256 = 'b' * 64
    artifact = {
      :page_number => 1, :pixel_width => 1200, :pixel_height => 1600,
      :png_signature_verified => true, :page_binding_verified => true,
      :box_binding_verified => true, :content_sha256 => sha256,
      :content_byte_size => 48_000,
      :source_pdf_sha256 => source_sha256,
      :source_pdf_binding_verified => true
    }
    record = {
      :page => 1, :source_span_ids => [], :requested_mode => :raster,
      :delivered_mode => :raster, :resulting_entity_ids => ['entity_id:13'],
      :created_entity_type => 'raster_image', :real_raster_verified => true,
      :visual_fidelity_verified => true, :cleanup_outcome => :not_required,
      :delivery_scope => :page_raster,
      :delivery_basis => :explicit_full_page_raster,
      :full_page_raster_request => true,
      :semantic_text_evaluated => false,
      :artifact_evidence => artifact
    }
    stats = ready_stats(
      :requested_text_mode => :raster, :text_source_span_ids => [],
      :text_attempts => [], :source_provenance_objects => [],
      :source_input_sha256 => source_sha256,
      :normalized_input_sha256 => source_sha256,
      :terminal_text_delivery_records => [record],
      :raster_delivery_records => [record]
    )
    group_manifest = SketchupHostEvidence.snapshot_entities([
      FakeGroup.new(13, [])
    ])

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, group_manifest, :raster, [1]
      )
    end
    assert_match(/image/i, error.message)

    image_manifest = SketchupHostEvidence.snapshot_entities([
      FakeImage.new(13, :attributes => {
        ['BC_PDF_Importer', 'raster_page_number'] => 1,
        ['BC_PDF_Importer', 'raster_pixel_width'] => 1200,
        ['BC_PDF_Importer', 'raster_pixel_height'] => 1600,
        ['BC_PDF_Importer', 'raster_content_sha256'] => sha256,
        ['BC_PDF_Importer', 'raster_content_bytes'] => 48_000,
        ['BC_PDF_Importer', 'raster_source_pdf_sha256'] => source_sha256
      })
    ])
    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, image_manifest, :raster, [1]
    )

    false_zero_text_claim = Marshal.load(Marshal.dump(stats))
    false_zero_text_claim[:terminal_text_delivery_records][0].merge!(
      :delivery_basis => :verified_zero_canonical_text,
      :full_page_raster_request => false,
      :semantic_text_evaluated => true,
      :no_semantic_text => true,
      :canonical_text_item_count => 0
    )
    false_zero_text_claim[:raster_delivery_records][0] =
      Marshal.load(Marshal.dump(
        false_zero_text_claim[:terminal_text_delivery_records][0]
      ))
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        false_zero_text_claim, image_manifest, :raster, [1]
      )
    end
    assert_match(/zero|semantic|source|inspection|basis/i, error.message)

    terminal_schema = Marshal.load(Marshal.dump(stats))
    terminal_schema[:immutable_pdf_sha256] =
      terminal_schema.delete(:source_input_sha256)
    terminal_schema[:normalized_pdf_sha256] =
      terminal_schema.delete(:normalized_input_sha256)
    assert SketchupHostEvidence.verify_delivery_evidence!(
      terminal_schema, image_manifest, :raster, [1]
    )

    artifact[:source_pdf_sha256] = 'c' * 64
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, image_manifest, :raster, [1]
      )
    end
    assert_match(/source|sha|raster/i, error.message)
    artifact[:source_pdf_sha256] = source_sha256

    record[:page] = 1.5
    artifact[:page_number] = 1.5
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, image_manifest, :raster, [1]
      )
    end
    assert_match(/page|integer/i, error.message)

    record[:page] = 1
    artifact[:page_number] = 1
    string_dimensions = Marshal.load(Marshal.dump(image_manifest))
    string_dimensions[0]['content_evidence']['display_width'] = '8.5'
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, string_dimensions, :raster, [1]
      )
    end
    assert_match(/content|display|raster/i, error.message)
  end

  def test_requested_raster_accepts_exact_item_crops_without_fallback_relabeling
    stats, image_manifest = strict_requested_item_raster_fixture

    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, image_manifest, :raster, [1]
    )

    fallback = Marshal.load(Marshal.dump(stats))
    fallback[:raster_fallback_used] = true
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        fallback, image_manifest, :raster, [1]
      )
    end
    assert_match(/fallback|Raster/i, error.message)

    wrong_source = Marshal.load(Marshal.dump(stats))
    artifact = wrong_source[:text_attempts][0][:artifact_evidence]
    artifact[:source_pdf_sha256] = 'c' * 64
    wrong_source[:text_attempts][0][:attempt_history][0][
      :artifact_evidence
    ] = artifact
    wrong_source[:terminal_text_delivery_records][0][
      :artifact_evidence
    ] = artifact
    wrong_source[:raster_delivery_records][0][:artifact_evidence] = artifact
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        wrong_source, image_manifest, :raster, [1]
      )
    end
    assert_match(/source|sha|PDF|raster/i, error.message)

    opaque = Marshal.load(Marshal.dump(stats))
    opaque_artifact = opaque[:text_attempts][0][:artifact_evidence]
    opaque_artifact[:transparent_background_verified] = false
    opaque[:text_attempts][0][:attempt_history][0][:artifact_evidence] =
      opaque_artifact
    opaque[:terminal_text_delivery_records][0][:artifact_evidence] =
      opaque_artifact
    opaque[:raster_delivery_records][0][:artifact_evidence] = opaque_artifact
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        opaque, image_manifest, :raster, [1]
      )
    end
    assert_match(/alpha|transparent|raster/i, error.message)
  end

  def test_terminal_item_raster_accepts_only_a_complete_finite_fallback_chain
    stats, image_manifest = strict_terminal_item_raster_fallback_fixture

    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, image_manifest, :labels, [1]
    )

    missing_transition = Marshal.load(Marshal.dump(stats))
    missing_transition[:fallback_transitions].pop
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        missing_transition, image_manifest, :labels, [1]
      )
    end
    assert_match(/fallback|transition|ledger/i, error.message)

    direct_stats, direct_manifest = strict_requested_item_raster_fixture
    direct_stats[:terminal_text_delivery_records][0][:explicit_request] = false
    direct_stats[:raster_delivery_records][0][:explicit_request] = false
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        direct_stats, direct_manifest, :raster, [1]
      )
    end
    assert_match(/explicit|fallback|Raster/i, error.message)
  end

  def test_requested_text_rebinds_capability_proof_and_global_ledger_to_source
    stats = strict_flat_text_to_label_stats
    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, label_manifest, :text, [1]
    )

    source_mismatch = Marshal.load(Marshal.dump(stats))
    local = source_mismatch[:text_attempts][0][:attempt_history][0][
      :transition_proof
    ]
    local[:evidence][:source_text_sha256] = 'c' * 64
    unsigned = local[:evidence].dup
    unsigned.delete(:evidence_sha256)
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    local[:evidence][:evidence_sha256] = fidelity.canonical_sha256(unsigned)
    source_mismatch[:fallback_transitions] = [Marshal.load(Marshal.dump(local))]
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        source_mismatch, label_manifest, :text, [1]
      )
    end
    assert_match(/source|Text|capability|transition/i, error.message)

    ledger_mismatch = Marshal.load(Marshal.dump(stats))
    global = ledger_mismatch[:fallback_transitions][0]
    global[:evidence][:source_text_sha256] = 'd' * 64
    unsigned = global[:evidence].dup
    unsigned.delete(:evidence_sha256)
    global[:evidence][:evidence_sha256] = fidelity.canonical_sha256(unsigned)
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        ledger_mismatch, label_manifest, :text, [1]
      )
    end
    assert_match(/ledger|transition|source/i, error.message)
  end

  def test_empty_semantic_page_raster_requires_affirmative_source_bound_fallback
    stats, image_manifest = strict_empty_page_raster_fixture
    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, image_manifest, :text3d, [1]
    )

    mutations = {
      :affirmative_impossibility => false,
      :reason_code => :helper_failed,
      :canonical_text_item_count => 1,
      :source_page_number => 2,
      :immutable_pdf_sha256 => 'c' * 64,
      :rendered_pdf_sha256 => 'd' * 64,
      :embedded_image_placed_count => 1
    }
    mutations.each do |field, value|
      invalid = Marshal.load(Marshal.dump(stats))
      invalid[:page_representation_fallbacks][0][field] = value
      error = assert_raises(StandardError, "#{field} must be enforced") do
        SketchupHostEvidence.verify_delivery_evidence!(
          invalid, image_manifest, :text3d, [1]
        )
      end
      assert_match(/fallback|source|page|raster|impossib/i, error.message)
    end

    invalid = Marshal.load(Marshal.dump(stats))
    invalid[:page_representation_fallbacks][0][:source_summary][
      :source_glyph_placements
    ] = 1
    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        invalid, image_manifest, :text3d, [1]
      )
    end

    missing = Marshal.load(Marshal.dump(stats))
    missing[:page_representation_fallbacks] = []
    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        missing, image_manifest, :text3d, [1]
      )
    end
  end

  def test_fallback_requires_adjacent_item_bound_proof_and_owned_cleanup
    mutations = [
      proc do |proof|
        proof[:to_mode] = :geometry
      end,
      proc do |proof|
        proof[:source_span_id] = 'text_span:1:99'
      end,
      proc do |proof|
        proof[:created_entity_ids] = ['entity_id:99']
        proof[:cleaned_entity_ids] = []
        proof[:cleanup_outcome] = :verified
      end
    ]
    mutations.each do |mutate|
      stats = strict_item_fallback_stats
      proof = stats[:text_attempts][0][:attempt_history][0][:transition_proof]
      mutate.call(proof)
      stats[:fallback_transitions] = [proof.dup]

      error = assert_raises(StandardError) do
        SketchupHostEvidence.verify_delivery_evidence!(
          stats, text3d_manifest, :labels, [1]
        )
      end
      assert_match(/fallback|transition|source item/i, error.message)
    end
  end

  def test_report_copy_is_parsed_bound_and_atomic
    Dir.mktmpdir('su-report-binding') do |dir|
      pdf = File.join(dir, 'source.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      source = File.join(dir, 'production.json')
      destination = File.join(dir, 'evidence', 'import_report.json')
      report = bound_report(pdf)
      File.write(source, JSON.generate(report))

      copied = SketchupHostEvidence.copy_verified_report!(
        source,
        destination,
        :pdf_path => pdf,
        :requested_mode => :labels,
        :schema => 'bcs.import_report/1.1',
        :worktree_version => '3.7.98',
        :loaded_version => '3.7.98',
        :host_version => '17.3.116',
        :import_session_id => 'session-1'
      )
      assert_equal destination, copied
      assert_equal File.binread(source), File.binread(destination)
    end
  end

  def test_stale_corrupt_and_concurrently_replaced_reports_fail_closed
    Dir.mktmpdir('su-report-binding') do |dir|
      pdf = File.join(dir, 'source.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      source = File.join(dir, 'production.json')
      destination = File.join(dir, 'copy.json')
      expectations = {
        :pdf_path => pdf,
        :requested_mode => :labels,
        :schema => 'bcs.import_report/1.1',
        :worktree_version => '3.7.98',
        :loaded_version => '3.7.98',
        :host_version => '17.3.116',
        :import_session_id => 'session-1'
      }

      stale = bound_report(pdf)
      stale['extra']['import_session_id'] = 'old-session'
      stale['extra']['source_provenance']['import_session_id'] = 'old-session'
      File.write(source, JSON.generate(stale))
      assert_raises(StandardError) do
        SketchupHostEvidence.copy_verified_report!(source, destination, expectations)
      end

      File.write(source, '{broken')
      assert_raises(StandardError) do
        SketchupHostEvidence.copy_verified_report!(source, destination, expectations)
      end

      File.write(source, JSON.generate(bound_report(pdf)))
      assert_raises(StandardError) do
        SketchupHostEvidence.copy_verified_report!(source, destination, expectations) do
          File.write(source, JSON.generate(bound_report(pdf).merge('schema' => 'replaced')))
        end
      end
    end
  end

  def test_every_delivery_collection_is_cross_checked
    [
      :text_attempts,
      :page_text_delivery_records,
      :terminal_text_delivery_records,
      :page_representation_fallbacks,
      :raster_delivery_records,
      :source_glyph_physical_deliveries
    ].each do |collection|
      stats = ready_stats(collection => [{
        'resulting_entity_ids' => [13]
      }])
      assert SketchupHostEvidence.verify_delivery_evidence!(stats, manifest)

      error = assert_raises(StandardError) do
        SketchupHostEvidence.verify_delivery_evidence!(
          ready_stats(collection => [{
            'resulting_entity_ids' => [999]
          }]),
          manifest
        )
      end
      assert_match(/manifest/, error.message)
    end
  end

  def test_missing_empty_nonpositive_or_unknown_delivery_ids_fail_closed
    invalid_claims = [
      {},
      { :resulting_entity_ids => [] },
      { :resulting_entity_ids => [0] },
      { :resulting_entity_ids => [-1] },
      { :resulting_entity_ids => [999] }
    ]
    invalid_claims.each do |record|
      error = assert_raises(StandardError) do
        SketchupHostEvidence.verify_delivery_evidence!(
          ready_stats(:terminal_text_delivery_records => [record]),
          manifest
        )
      end
      assert_match(/entity IDs|manifest/, error.message)
    end
  end

  def test_empty_manifest_fails_closed
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(ready_stats, [])
    end
    assert_match(/manifest/, error.message)
  end

  def test_representation_and_import_contract_gates_must_be_ready
    [:representation_fidelity, :import_contract_ready].each do |gate|
      [nil, {}, { :ready => false }, { 'ready' => false }].each do |value|
        stats = ready_stats(gate => value)
        error = assert_raises(StandardError) do
          SketchupHostEvidence.verify_delivery_evidence!(stats, manifest)
        end
        assert_match(/#{gate}/, error.message)
      end
    end
  end

  def test_compact_claim_root_hashes_verify_without_face_rows
    rows = text3d_manifest
    stats = strict_text3d_stats
    expected = stats[:text_attempts].first[:expected_evidence]
    root = rows.first
    root['children'] = []
    root['representation_evidence']['source_claim_root'] = true
    schema = 'bcs.host_physical_partition/1.0'
    root['geometry_evidence'] = {
      'schema' => schema,
      'sha256' => expected[:physical_geometry_sha256],
      'physical_entity_count' => expected[:physical_entity_count],
      'topology' => {
        'root_type' => 'Group',
        'direct_child_types' => ['Edge', 'Face'],
        'descendant_type_counts' => { 'Edge' => 1, 'Face' => 1 },
        'descendant_entity_count' => 2,
        'live_entity_count' => 3
      }
    }
    root['style_evidence'] = {
      'schema' => schema,
      'sha256' => expected[:physical_style_sha256],
      'physical_entity_count' => expected[:physical_entity_count]
    }

    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, rows, :text3d, [1]
    )

    root['geometry_evidence']['sha256'] = '0' * 64
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, rows, :text3d, [1]
      )
    end
    assert_match(/physical geometry differs/, error.message)
  end

  def test_compact_text3d_rejects_flat_or_edge_only_topology
    rows, stats = compact_fixture(:text3d)
    topology = rows.first['geometry_evidence']['topology']
    topology['direct_child_types'] = ['Edge', 'Edge']
    topology['descendant_type_counts'] = { 'Edge' => 2 }

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, rows, :text3d, [1]
      )
    end
    assert_match(/3D Text|topology|Face/i, error.message)
  end

  def test_compact_text3d_accepts_tolerance_safe_nested_group
    rows = text3d_manifest
    root = rows.first
    raw_children = root['children']
    root['children'] = [{
      'entity_id' => 16, 'persistent_id' => 1016,
      'typename' => 'Group', 'valid' => true, 'deleted' => false,
      'children' => raw_children
    }]
    expected = decorate_fixture_manifest!(
      rows, :text3d, 'text_span:1:0', 'A'
    )
    stats = strict_text3d_stats
    attempt = stats[:text_attempts].first
    attempt[:expected_evidence] = expected
    attempt[:attempt_history].last[:expected_evidence] = expected
    root['children'] = []
    root['representation_evidence']['source_claim_root'] = true
    schema = 'bcs.host_physical_partition/1.0'
    root['geometry_evidence'] = {
      'schema' => schema,
      'sha256' => expected[:physical_geometry_sha256],
      'physical_entity_count' => expected[:physical_entity_count],
      'topology' => {
        'root_type' => 'Group',
        'direct_child_types' => ['Group'],
        'descendant_type_counts' => {
          'Edge' => 1, 'Face' => 1, 'Group' => 1
        },
        'descendant_entity_count' => 3,
        'live_entity_count' => 4
      }
    }
    root['style_evidence'] = {
      'schema' => schema,
      'sha256' => expected[:physical_style_sha256],
      'physical_entity_count' => expected[:physical_entity_count]
    }

    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, rows, :text3d, [1]
    )
  end

  def test_compact_text3d_accepts_exact_component_instance_topology
    rows = text3d_manifest
    root = rows.first
    raw_children = root['children']
    root['children'] = [{
      'entity_id' => 16, 'persistent_id' => 1016,
      'typename' => 'ComponentInstance', 'valid' => true, 'deleted' => false,
      'children' => raw_children
    }]
    expected = decorate_fixture_manifest!(
      rows, :text3d, 'text_span:1:0', 'A'
    )
    stats = strict_text3d_stats
    attempt = stats[:text_attempts].first
    attempt[:expected_evidence] = expected
    attempt[:attempt_history].last[:expected_evidence] = expected
    root['children'] = []
    root['representation_evidence']['source_claim_root'] = true
    schema = 'bcs.host_physical_partition/1.0'
    root['geometry_evidence'] = {
      'schema' => schema,
      'sha256' => expected[:physical_geometry_sha256],
      'physical_entity_count' => expected[:physical_entity_count],
      'topology' => {
        'root_type' => 'Group',
        'direct_child_types' => ['ComponentInstance'],
        'descendant_type_counts' => {
          'ComponentInstance' => 1, 'Face' => 1, 'Edge' => 1
        },
        'descendant_entity_count' => 3,
        'live_entity_count' => 4
      }
    }
    root['style_evidence'] = {
      'schema' => schema,
      'sha256' => expected[:physical_style_sha256],
      'physical_entity_count' => expected[:physical_entity_count]
    }

    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, rows, :text3d, [1]
    )
  end

  def test_compact_geometry_rejects_face_or_nested_container_topology
    rows, stats = compact_fixture(:geometry)
    topology = rows.first['geometry_evidence']['topology']
    topology['direct_child_types'] = ['Face']
    topology['descendant_type_counts'] = { 'Face' => 1 }

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, rows, :geometry, [1]
      )
    end
    assert_match(/Geometry|topology|edge/i, error.message)
  end

  def test_compact_glyphs_rejects_direct_edge_without_glyph_container
    rows, stats = compact_fixture(:glyphs)
    topology = rows.first['geometry_evidence']['topology']
    topology['direct_child_types'] = ['Edge']
    topology['descendant_type_counts'] = { 'Edge' => 2 }

    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, rows, :glyphs, [1]
      )
    end
    assert_match(/Glyphs|topology|hierarchy|container/i, error.message)
  end

  def test_multiple_native_3d_text_claim_roots_verify_as_one_source_partition
    rows = Marshal.load(Marshal.dump(text3d_manifest.first['children']))
    rows[0]['bounds'] = {
      'min' => [0.0, 0.0, 0.0], 'max' => [1.0, 1.0, 0.1]
    }
    rows[1]['bounds'] = {
      'min' => [0.0, 0.0, 0.0], 'max' => [1.0, 1.0, 0.1]
    }
    identity = [
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ]
    rows.each { |row| row['transformation'] = identity }
    expected = decorate_fixture_manifest!(
      rows, :text3d, 'text_span:1:0', 'A'
    )
    stats = strict_text3d_stats
    claim_ids = rows.map { |row| "entity_id:#{row['entity_id']}" }
    attempt = stats[:text_attempts].first
    attempt[:resulting_entity_ids] = claim_ids
    attempt[:expected_evidence] = expected
    attempt[:attempt_history].last[:resulting_entity_ids] = claim_ids
    attempt[:attempt_history].last[:expected_evidence] = expected
    stats[:source_provenance_objects].first[:resulting_entity_ids] = claim_ids
    stats[:source_provenance_objects].first[:created_entity_type] =
      'native_3d_text'
    stats[:source_provenance_objects].first[:renderer] =
      'sketchup_native_3d_text'

    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, rows, :text3d, [1]
    )
  end

  def test_native_label_verifier_preserves_exact_whitespace_content
    row = label_manifest.first
    text = '   '
    digest = Digest::SHA256.hexdigest(text)
    row['content_evidence']['text'] = text
    row['content_evidence']['text_sha256'] = digest
    record = {
      :source_text_sha256 => digest,
      :expected_evidence => {
        :source_anchor => row['content_evidence']['anchor'],
        :source_rotation_radians => 0.0
      }
    }

    assert SketchupHostEvidence.send(
      :verify_native_labels!, [row], record, 'whitespace label'
    )
  end

  private

  def compact_fixture(mode)
    rows = case mode
           when :text3d then text3d_manifest
           when :geometry then geometry_manifest
           when :glyphs then glyph_manifest
           else raise ArgumentError, "unsupported compact fixture #{mode}"
           end
    stats = mode == :text3d ? strict_text3d_stats :
      strict_page_mode_stats(mode, mode, 1)
    expected = stats[:text_attempts].first[:expected_evidence]
    root = rows.first
    child_types = Array(root['children']).map { |child| child['typename'] }.sort
    counts = {}
    fixture_visit_rows(root['children']) do |child|
      type = child['typename'].to_s
      counts[type] = counts.fetch(type, 0) + 1
    end
    root['children'] = []
    root['representation_evidence']['source_claim_root'] = true
    schema = 'bcs.host_physical_partition/1.0'
    root['geometry_evidence'] = {
      'schema' => schema,
      'sha256' => expected[:physical_geometry_sha256],
      'physical_entity_count' => expected[:physical_entity_count],
      'topology' => {
        'root_type' => root['typename'],
        'direct_child_types' => child_types,
        'descendant_type_counts' => counts,
        'descendant_entity_count' => counts.values.inject(0, :+),
        'live_entity_count' => expected[:physical_entity_count]
      }
    }
    root['style_evidence'] = {
      'schema' => schema,
      'sha256' => expected[:physical_style_sha256],
      'physical_entity_count' => expected[:physical_entity_count]
    }
    [rows, stats]
  end

  def manifest
    [{
      'entity_id' => 10,
      'persistent_id' => 10,
      'typename' => 'Group',
      'valid' => true,
      'deleted' => false,
      'children' => [{
        'entity_id' => 13,
        'persistent_id' => 13,
        'typename' => 'Text',
        'valid' => true,
        'deleted' => false,
        'content_evidence' => {
          'text_like' => true, 'text' => 'A',
          'anchor' => [1.0, 2.0, 0.0], 'leader_visible' => false
        },
        'children' => []
      }]
    }]
  end

  def label_manifest
    rows = [{
      'entity_id' => 13, 'persistent_id' => 1013,
      'typename' => 'Text', 'valid' => true, 'deleted' => false,
      'content_evidence' => {
        'text_like' => true, 'text' => 'A',
        'text_sha256' => Digest::SHA256.hexdigest('A'),
        'anchor' => [1.0, 2.0, 0.0], 'leader_visible' => false
      },
      'children' => []
    }]
    decorate_fixture_manifest!(rows, :labels, 'text_span:1:0', 'A')
    rows
  end

  def geometry_manifest
    rows = [{
      'entity_id' => 13, 'persistent_id' => 1013,
      'typename' => 'Group', 'valid' => true, 'deleted' => false,
      'bounds' => { 'min' => [0.0, 0.0, 0.0],
                    'max' => [1.0, 1.0, 0.0] },
      'transformation' => [1.0, 0.0, 0.0, 0.0,
                           0.0, 1.0, 0.0, 0.0,
                           0.0, 0.0, 1.0, 0.0,
                           0.0, 0.0, 0.0, 1.0],
      'representation_evidence' => {
        'source_span_id' => 'text_span:1:0', 'source_unit_id' => nil,
        'source_kind' => 'text_span', 'representation' => 'geometry',
        'renderer' => 'svg_item_flat_geometry_renderer'
      },
      'children' => [{
        'entity_id' => 14, 'persistent_id' => 1014,
        'typename' => 'Edge', 'valid' => true, 'deleted' => false,
        'children' => []
      }]
    }]
    decorate_fixture_manifest!(rows, :geometry, 'text_span:1:0', 'A')
    rows
  end

  def glyph_manifest
    rows = [{
      'entity_id' => 13, 'persistent_id' => 1013,
      'typename' => 'Group', 'valid' => true, 'deleted' => false,
      'bounds' => { 'min' => [0.0, 0.0, 0.0],
                    'max' => [1.0, 1.0, 0.0] },
      'transformation' => [1.0, 0.0, 0.0, 0.0,
                           0.0, 1.0, 0.0, 0.0,
                           0.0, 0.0, 1.0, 0.0,
                           0.0, 0.0, 0.0, 1.0],
      'representation_evidence' => {
        'source_span_id' => 'text_span:1:0', 'source_unit_id' => nil,
        'source_kind' => 'text_span', 'representation' => 'glyphs',
        'renderer' => 'svg_item_glyph_group_renderer'
      },
      'children' => [{
        'entity_id' => 14, 'persistent_id' => 1014,
        'typename' => 'ComponentInstance', 'valid' => true, 'deleted' => false,
        'children' => [{
          'entity_id' => 15, 'persistent_id' => 1015,
          'typename' => 'Edge', 'valid' => true, 'deleted' => false,
          'children' => []
        }]
      }]
    }]
    decorate_fixture_manifest!(rows, :glyphs, 'text_span:1:0', 'A')
    rows
  end

  def text3d_manifest
    rows = [{
      'entity_id' => 13, 'persistent_id' => 1013,
      'typename' => 'Group', 'valid' => true, 'deleted' => false,
      'bounds' => { 'min' => [0.0, 0.0, 0.0],
                    'max' => [1.0, 1.0, 0.1] },
      'transformation' => [1.0, 0.0, 0.0, 0.0,
                           0.0, 1.0, 0.0, 0.0,
                           0.0, 0.0, 1.0, 0.0,
                           0.0, 0.0, 0.0, 1.0],
      'representation_evidence' => {
        'source_span_id' => 'text_span:1:0',
        'source_unit_id' => 'text_span:1:0',
        'source_kind' => 'text_span', 'representation' => 'text3d',
        'renderer' => 'svg_source_3d_text'
      },
      'children' => [{
        'entity_id' => 14, 'persistent_id' => 1014,
        'typename' => 'Face', 'valid' => true, 'deleted' => false,
        'children' => []
      }, {
        'entity_id' => 15, 'persistent_id' => 1015,
        'typename' => 'Edge', 'valid' => true, 'deleted' => false,
        'children' => []
      }]
    }]
    decorate_fixture_manifest!(rows, :text3d, 'text_span:1:0', 'A')
    rows
  end

  def ready_stats(overrides = {})
    expected = fixture_expected_evidence(:labels, 'text_span:1:0', 'A')
    {
      :requested_text_mode => :labels,
      :import_session_id => 'test-session',
      :text_source_span_ids => ['text_span:1:0'],
      :text_attempts => [{
        :source_span_id => 'text_span:1:0',
        :source_text_sha256 => Digest::SHA256.hexdigest('A'),
        :requested_mode => :labels, :delivered_mode => :labels,
        :resulting_entity_ids => [13],
        :visual_fidelity_verified => true,
        :placement_verified => true, :rotation_verified => true,
        :content_verified => true, :entity_type_verified => true,
        :leader_verified => true,
        :physical_geometry_verified => true,
        :physical_style_verified => true, :transform_verified => true,
        :expected_evidence => expected,
        :attempt_history => [{
          :mode => :labels, :outcome => :complete,
          :resulting_entity_ids => [13],
          :visual_fidelity_verified => true,
          :placement_verified => true, :rotation_verified => true,
          :content_verified => true, :entity_type_verified => true,
          :leader_verified => true,
          :physical_geometry_verified => true,
          :physical_style_verified => true, :transform_verified => true,
          :expected_evidence => expected,
          :cleanup_outcome => :not_required
        }]
      }],
      :source_provenance_objects => [{
        :span_id => 'text_span:1:0',
        :resulting_entity_ids => [13]
      }],
      :page_text_delivery_records => [],
      :terminal_text_delivery_records => [],
      :page_representation_fallbacks => [],
      :raster_delivery_records => [],
      :source_glyph_physical_deliveries => [],
      :fallback_transitions => [],
      :terminal_cleanup_events => [],
      :empty_page_source_inspections => [],
      :representation_fidelity => { :ready => true },
      :import_contract_ready => { :ready => true }
    }.merge(overrides)
  end

  def strict_page_mode_stats(job_mode, record_mode, page_number)
    source_id = "text_span:#{page_number}:0"
    entity_id = 'entity_id:13'
    expected = fixture_expected_evidence(record_mode, source_id, 'A')
    flags = fixture_mode_flags(record_mode)
    ready_stats(
      :requested_text_mode => job_mode,
      :text_source_span_ids => [source_id],
      :text_attempts => [{
        :page => page_number, :source_span_id => source_id,
        :source_text_sha256 => Digest::SHA256.hexdigest('A'),
        :requested_mode => record_mode, :delivered_mode => record_mode,
        :resulting_entity_ids => [entity_id],
        :visual_fidelity_verified => true,
        :expected_evidence => expected,
        :attempt_history => [{
          :mode => record_mode, :outcome => :complete,
          :resulting_entity_ids => [entity_id],
          :visual_fidelity_verified => true,
          :expected_evidence => expected,
          :cleanup_outcome => :not_required
        }.merge(flags)]
      }.merge(flags)],
      :source_provenance_objects => [],
      :page_text_delivery_records => [{
        :page => page_number, :source_span_ids => [source_id],
        :source_text_sha256 => Digest::SHA256.hexdigest('A'),
        :requested_mode => record_mode, :delivered_mode => record_mode,
        :resulting_entity_ids => [entity_id],
         :created_entity_type => case record_mode
                                 when :geometry then 'page_path_geometry'
                                 when :glyphs then 'glyph_outline'
                                 when :text3d then 'source_glyph_3d_text'
                                 else 'native_label'
                                 end,
        :visual_fidelity_verified => true
      }]
    )
  end

  def strict_item_fallback_stats
    source_id = 'text_span:1:0'
    entity_id = 'entity_id:13'
    proof = {
      :source_span_id => source_id,
      :importer_id => 'sketchup_pdf_vector_importer',
      :page_number => 1, :scope => :item,
      :category => :exact_representation_impossible,
      :affirmative_impossibility => true, :generic_failure => false,
      :from_mode => :labels, :to_mode => :text3d,
      :reason_code => :source_item_identity_unavailable,
      :attempted_renderer => 'native_label_renderer',
      :evidence => { :fresh_inventory_evaluation => true },
      :created_entity_ids => [], :cleaned_entity_ids => [],
      :cleanup_outcome => :not_required
    }
    expected = fixture_expected_evidence(:text3d, source_id, 'A')
    flags = fixture_mode_flags(:text3d)
    ready_stats(
      :text_attempts => [{
        :source_span_id => source_id, :requested_mode => :labels,
        :delivered_mode => :text3d, :resulting_entity_ids => [entity_id],
        :source_text_sha256 => Digest::SHA256.hexdigest('A'),
        :expected_evidence => expected,
        :attempt_history => [{
          :mode => :labels, :outcome => :failed,
          :resulting_entity_ids => [], :transition_proof => proof
        }, {
          :mode => :text3d, :outcome => :complete,
          :resulting_entity_ids => [entity_id],
          :visual_fidelity_verified => true,
          :expected_evidence => expected,
          :cleanup_outcome => :not_required
        }.merge(flags)]
      }.merge(flags)],
      :source_provenance_objects => [{
        :span_id => source_id, :resulting_entity_ids => [entity_id]
      }],
      :fallback_transitions => [proof.dup]
    )
  end

  def strict_flat_text_to_label_stats
    source_id = 'text_span:1:0'
    source_text = 'A'
    source_bbox = [0.0, 0.0, 72.0, 72.0]
    proof = flat_text_capability_proof(source_id, source_text, source_bbox)
    expected = fixture_expected_evidence(:labels, source_id, source_text)
    flags = fixture_mode_flags(:labels)
    ready_stats(
      :requested_text_mode => :text,
      :text_source_span_ids => [source_id],
      :text_attempts => [{
        :source_span_id => source_id, :page => 1,
        :source_text_sha256 => Digest::SHA256.hexdigest(source_text),
        :source_bbox_pdf => source_bbox,
        :requested_mode => :text, :delivered_mode => :labels,
        :resulting_entity_ids => ['entity_id:13'],
        :expected_evidence => expected,
        :attempt_history => [{
          :mode => :text, :outcome => :failed,
          :resulting_entity_ids => [], :created_entity_ids => [],
          :cleaned_entity_ids => [], :cleanup_outcome => :not_required,
          :transition_proof => proof
        }, {
          :mode => :labels, :outcome => :complete,
          :resulting_entity_ids => ['entity_id:13'],
          :expected_evidence => expected,
          :cleanup_outcome => :not_required
        }.merge(flags)]
      }.merge(flags)],
      :source_provenance_objects => [{
        :span_id => source_id, :page => 1,
        :source_text_sha256 => Digest::SHA256.hexdigest(source_text),
        :created_entity_type => 'native_label',
        :resulting_entity_ids => ['entity_id:13']
      }],
      :fallback_transitions => [Marshal.load(Marshal.dump(proof))]
    )
  end

  def flat_text_capability_proof(source_id, source_text, source_bbox)
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    evidence = {
      :schema => fidelity::FLAT_TEXT_CAPABILITY_SCHEMA,
      :source_span_id => source_id,
      :importer_id => fidelity::IMPORTER_ID,
      :page_number => 1, :requested_mode => :text,
      :source_text_sha256 => Digest::SHA256.hexdigest(source_text),
      :source_bbox_pdf => source_bbox,
      :host_product => 'SketchUp', :host_version => '17.3.116',
      :host_major_version => 17,
      :entities_add_text_observed => true,
      :sketchup_text_class_observed => true,
      :sketchup_text_annotation_api_observed => true,
      :observed_entities_text_methods => ['add_3d_text', 'add_text'],
      :observed_sketchup_text_annotation_methods => ['point', 'text', 'vector'],
      :distinct_flat_text_constructor_observed => false,
      :native_flat_editable_text_available => false,
      :capability_observation_only => true,
      :host_api_fact => fidelity::FLAT_TEXT_HOST_API_FACT
    }
    evidence[:evidence_sha256] = fidelity.canonical_sha256(evidence)
    {
      :source_span_id => source_id, :importer_id => fidelity::IMPORTER_ID,
      :page_number => 1, :requested_mode => :text, :scope => :item,
      :category => :exact_representation_impossible,
      :affirmative_impossibility => true, :generic_failure => false,
      :from_mode => :text, :to_mode => :labels,
      :reason_code => :host_representation_unsupported,
      :attempted_renderer =>
        'sketchup_flat_editable_text_capability_observation',
      :created_entity_ids => [], :cleaned_entity_ids => [],
      :cleanup_outcome => :not_required, :evidence => evidence
    }
  end

  def strict_requested_item_raster_fixture
    source_id = 'text_span:1:0'
    source_sha = 'b' * 64
    png_sha = 'a' * 64
    artifact = {
      :source_span_id => source_id, :page_number => 1,
      :source_pdf_path => 'C:/fixtures/source.pdf',
      :source_pdf_sha256 => source_sha,
      :source_pdf_binding_verified => true,
      :source_box => [10.0, 20.0, 40.0, 32.0],
      :display_box => [10.0, 20.0, 40.0, 32.0],
      :pixel_crop => [100, 200, 300, 120],
      :pixel_width => 300, :pixel_height => 120,
      :content_sha256 => png_sha, :content_byte_size => 48_000,
      :png_signature_verified => true, :page_binding_verified => true,
      :source_crop_binding_verified => true, :aspect_verified => true,
      :alpha_channel_verified => true,
      :transparent_background_verified => true,
      :visible_pixel_verified => true,
      :page_render_once_verified => true,
      :page_render_content_sha256 => 'c' * 64
    }
    completed = {
      :mode => :raster, :outcome => :complete,
      :resulting_entity_ids => ['entity_id:13'],
      :cleanup_outcome => :not_required,
      :visual_fidelity_verified => true, :real_raster_verified => true,
      :source_crop_binding_verified => true, :entity_type_verified => true,
      :artifact_evidence => artifact
    }
    attempt = {
      :source_span_id => source_id, :requested_mode => :raster,
      :delivered_mode => :raster, :resulting_entity_ids => ['entity_id:13'],
      :visual_fidelity_verified => true, :real_raster_verified => true,
      :source_crop_binding_verified => true, :entity_type_verified => true,
      :artifact_evidence => artifact, :attempt_history => [completed]
    }
    record = {
      :page => 1, :source_span_ids => [source_id],
      :requested_mode => :raster, :delivered_mode => :raster,
      :created_entity_type => 'raster_image',
      :resulting_entity_ids => ['entity_id:13'],
      :real_raster_verified => true, :visual_fidelity_verified => true,
      :source_crop_binding_verified => true, :artifact_evidence => artifact,
      :cleanup_outcome => :not_required, :delivery_scope => :item_raster,
      :explicit_request => true
    }
    stats = ready_stats(
      :requested_text_mode => :raster,
      :source_input_sha256 => source_sha,
      :normalized_input_sha256 => source_sha,
      :text_source_span_ids => [source_id], :text_attempts => [attempt],
      :source_provenance_objects => [], :page_text_delivery_records => [],
      :terminal_text_delivery_records => [record],
      :raster_delivery_records => [record.dup],
      :raster_fallback_used => false,
      :text_renderers => [{
        :requested_mode => :raster, :delivered_mode => :raster,
        :degraded => false, :resulting_entity_ids => ['entity_id:13']
      }]
    )
    manifest = SketchupHostEvidence.snapshot_entities([
      FakeImage.new(13, :attributes => {
        ['BC_PDF_Importer', 'source_span_id'] => source_id,
        ['BC_PDF_Importer', 'raster_page_number'] => 1,
        ['BC_PDF_Importer', 'raster_pixel_width'] => 300,
        ['BC_PDF_Importer', 'raster_pixel_height'] => 120,
        ['BC_PDF_Importer', 'raster_content_sha256'] => png_sha,
        ['BC_PDF_Importer', 'raster_content_bytes'] => 48_000,
        ['BC_PDF_Importer', 'raster_source_pdf_sha256'] => source_sha,
        ['BC_PDF_Importer', 'raster_alpha_verified'] => true,
        ['BC_PDF_Importer', 'raster_transparent_background_verified'] => true,
        ['BC_PDF_Importer', 'raster_visible_pixel_verified'] => true,
        ['BC_PDF_Importer', 'raster_page_render_once_verified'] => true,
        ['BC_PDF_Importer', 'raster_page_render_sha256'] => 'c' * 64
      })
    ])
    [stats, manifest]
  end

  def strict_terminal_item_raster_fallback_fixture
    stats, manifest = strict_requested_item_raster_fixture
    source_id = 'text_span:1:0'
    artifact = stats[:text_attempts][0][:artifact_evidence]
    entity_ids = ['entity_id:13']
    ladder = [:labels, :text3d, :glyphs, :geometry, :raster]
    proofs = []
    history = ladder.each_with_index.map do |mode, index|
      if mode == :raster
        {
          :mode => :raster, :outcome => :complete,
          :resulting_entity_ids => entity_ids,
          :cleanup_outcome => :not_required,
          :visual_fidelity_verified => true, :real_raster_verified => true,
          :source_crop_binding_verified => true,
          :entity_type_verified => true, :artifact_evidence => artifact
        }
      else
        proof = {
          :source_span_id => source_id,
          :importer_id => 'sketchup_pdf_vector_importer',
          :page_number => 1, :scope => :item,
          :category => :exact_representation_impossible,
          :affirmative_impossibility => true, :generic_failure => false,
          :from_mode => mode, :to_mode => ladder[index + 1],
          :reason_code => :verified_source_representation_impossible,
          :attempted_renderer => "#{mode}_renderer",
          :evidence => { :fresh_inventory_evaluation => true },
          :created_entity_ids => [], :cleaned_entity_ids => [],
          :cleanup_outcome => :not_required
        }
        proofs << proof
        {
          :mode => mode, :outcome => :failed,
          :resulting_entity_ids => [], :transition_proof => proof
        }
      end
    end
    attempt = stats[:text_attempts][0]
    attempt[:requested_mode] = :labels
    attempt[:delivered_mode] = :raster
    attempt[:attempt_history] = history
    record = stats[:terminal_text_delivery_records][0]
    record[:requested_mode] = :labels
    record[:explicit_request] = false
    record[:degraded] = true
    stats[:raster_delivery_records] = [Marshal.load(Marshal.dump(record))]
    stats[:requested_text_mode] = :labels
    stats[:fallback_transitions] = Marshal.load(Marshal.dump(proofs))
    stats[:raster_fallback_used] = true
    stats[:text_renderers] = [{
      :requested_mode => :labels, :delivered_mode => :raster,
      :degraded => true, :resulting_entity_ids => entity_ids
    }]
    [stats, manifest]
  end

  def strict_empty_page_raster_fixture
    png_sha = 'a' * 64
    source_sha = 'b' * 64
    entity_id = 'entity_id:13'
    artifact = {
      :page_number => 1, :pixel_width => 1200, :pixel_height => 1600,
      :png_signature_verified => true, :page_binding_verified => true,
      :box_binding_verified => true, :content_sha256 => png_sha,
      :content_byte_size => 48_000, :source_pdf_sha256 => source_sha,
      :source_pdf_binding_verified => true
    }
    record = {
      :page => 1, :source_span_ids => [], :requested_mode => :text3d,
      :delivered_mode => :raster, :resulting_entity_ids => [entity_id],
      :created_entity_type => 'raster_image', :real_raster_verified => true,
      :visual_fidelity_verified => true, :cleanup_outcome => :not_required,
      :delivery_scope => :page_raster, :no_semantic_text => true,
      :delivery_basis => :verified_zero_canonical_text,
      :semantic_text_evaluated => true,
      :canonical_text_item_count => 0, :source_page_number => 1,
      :immutable_pdf_sha256 => source_sha,
      :rendered_pdf_sha256 => source_sha,
      :artifact_evidence => artifact
    }
    fallback = {
      :page => 1, :scope => :page,
      :reason_code => :visible_nontext_source_only,
      :affirmative_impossibility => true,
      :requested_text_mode => :text3d,
      :source_text_items => 0, :canonical_text_item_count => 0,
      :source_page_number => 1, :immutable_pdf_sha256 => source_sha,
      :rendered_pdf_sha256 => source_sha,
      :embedded_image_asset_count => 1,
      :embedded_image_placed_count => 0,
      :source_summary => {
        :source_glyph_placements => 0,
        :visible_nontext_source => true
      },
      :delivered_mode => :raster, :resulting_entity_ids => [entity_id],
      :real_raster_verified => true, :visual_fidelity_verified => true
    }
    inspection = {
      :page => 1, :source_page_number => 1,
      :canonical_text_item_count => 0,
      :immutable_pdf_sha256 => source_sha,
      :rendered_pdf_sha256 => source_sha,
      :semantic_text_extraction_complete => true,
      :decoded_stream_text_operators => false,
      :decoded_form_stream_text_operators => false
    }
    stats = ready_stats(
      :requested_text_mode => :text3d,
      :source_input_sha256 => source_sha,
      :normalized_input_sha256 => source_sha,
      :text_source_span_ids => [], :text_attempts => [],
      :source_provenance_objects => [], :page_text_delivery_records => [],
      :terminal_text_delivery_records => [record],
      :page_representation_fallbacks => [fallback],
      :raster_delivery_records => [record.dup],
      :empty_page_source_inspections => [inspection]
    )
    manifest = SketchupHostEvidence.snapshot_entities([
      FakeImage.new(13, :attributes => {
        ['BC_PDF_Importer', 'raster_page_number'] => 1,
        ['BC_PDF_Importer', 'raster_pixel_width'] => 1200,
        ['BC_PDF_Importer', 'raster_pixel_height'] => 1600,
        ['BC_PDF_Importer', 'raster_content_sha256'] => png_sha,
        ['BC_PDF_Importer', 'raster_content_bytes'] => 48_000,
        ['BC_PDF_Importer', 'raster_source_pdf_sha256'] => source_sha
      })
    ])
    [stats, manifest]
  end

  def strict_text3d_stats
    source_id = 'text_span:1:0'
    entity_id = 'entity_id:13'
    expected = fixture_expected_evidence(:text3d, source_id, 'A')
    flags = fixture_mode_flags(:text3d)
    ready_stats(
      :requested_text_mode => :text3d,
      :text_attempts => [{
        :source_span_id => source_id, :page => 1,
        :requested_mode => :text3d, :delivered_mode => :text3d,
        :source_text_sha256 => Digest::SHA256.hexdigest('A'),
        :resulting_entity_ids => [entity_id],
        :visual_fidelity_verified => true,
        :expected_evidence => expected,
        :attempt_history => [{
          :mode => :text3d, :outcome => :complete,
          :resulting_entity_ids => [entity_id],
          :visual_fidelity_verified => true,
          :expected_evidence => expected,
          :cleanup_outcome => :not_required
        }.merge(flags)]
      }.merge(flags)],
      :source_provenance_objects => [{
        :span_id => source_id, :page => 1,
        :created_entity_type => 'source_glyph_3d_text',
        :renderer => 'svg_source_3d_text',
        :resulting_entity_ids => [entity_id]
      }]
    )
  end

  def fixture_mode_flags(mode)
    common = {
      :visual_fidelity_verified => true,
      :placement_verified => true, :rotation_verified => true,
      :content_verified => true, :entity_type_verified => true,
      :physical_geometry_verified => true,
      :physical_style_verified => true, :transform_verified => true
    }
    case mode
    when :labels
      common.merge(:leader_verified => true)
    when :text3d
      common.merge(
        :width_verified => true, :height_verified => true,
        :depth_verified => true, :source_glyph_identity_verified => true,
        :positive_z_depth_verified => true
      )
    when :glyphs, :geometry
      common.merge(
        :width_verified => true, :height_verified => true,
        :identity_verified => true, :visibility_verified => true
      )
    else
      common
    end
  end

  def fixture_expected_evidence(mode, source_id, text)
    rows = case mode
           when :geometry then geometry_manifest
           when :glyphs then glyph_manifest
           when :text3d then text3d_manifest
           else label_manifest
           end
    decorate_fixture_manifest!(rows, mode, source_id, text)
  end

  def decorate_fixture_manifest!(rows, mode, source_id, text)
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    geometry_payload = Array(rows).map do |row|
      fixture_geometry_payload(row)
    end.sort_by { |entry| fidelity.canonical_json(entry) }
    style_payload = Array(rows).map do |row|
      fixture_style_payload(row)
    end.sort_by { |entry| fidelity.canonical_json(entry) }
    root = Array(rows).first || {}
    bounds = root['bounds']
    anchor = if mode == :labels
               hash = root['content_evidence'] || {}
               hash['anchor'] || [1.0, 2.0, 0.0]
             elsif bounds
               bounds['min']
             else
               [0.0, 0.0, 0.0]
             end
    width = bounds ? bounds['max'][0].to_f - bounds['min'][0].to_f : 1.0
    height = bounds ? bounds['max'][1].to_f - bounds['min'][1].to_f : 1.0
    depth = bounds ? bounds['max'][2].to_f - bounds['min'][2].to_f : 0.0
    expected = {
      :schema => 'bcs.source_expected/1.0',
      :source_span_id => source_id,
      :representation => mode,
      :source_text_sha256 => Digest::SHA256.hexdigest(text),
      :source_bbox_pdf => [0.0, 0.0, 72.0, 72.0],
      :source_anchor => anchor,
      :source_rotation_radians => 0.0,
      :source_font_sha256 => fidelity.canonical_sha256(
        :fixture => 'source-font'
      ),
      :expected_width => width.abs > 0.0 ? width.abs : 1.0,
      :expected_height => height.abs > 0.0 ? height.abs : 1.0,
      :expected_depth => mode == :text3d ? depth.abs : 0.0,
      :expected_bounds => [:text3d, :glyphs, :geometry].include?(mode) ?
        bounds : nil,
      :expected_transformation => [:text3d, :glyphs, :geometry].include?(mode) ?
        root['transformation'] : { :kind => 'native_text_anchor', :anchor => anchor },
      :physical_geometry_sha256 => fidelity.canonical_sha256(geometry_payload),
      :physical_style_sha256 => fidelity.canonical_sha256(style_payload),
      :physical_entity_count => Array(rows).inject(0) do |total, row|
        total + fixture_row_count(row)
      end
    }
    expected[:evidence_sha256] = fidelity.canonical_sha256(expected)
    renderer = case mode
               when :geometry then 'svg_item_flat_geometry_renderer'
               when :glyphs then 'svg_item_glyph_group_renderer'
               when :text3d then 'svg_source_3d_text'
               else 'sketchup_native_text'
               end
    fixture_visit_rows(rows) do |row|
      evidence = row['representation_evidence'] || {}
      evidence['source_span_id'] = source_id
      evidence['source_kind'] = 'text_span'
      evidence['representation'] = mode.to_s
      evidence['renderer'] = renderer
      evidence['source_evidence_sha256'] = expected[:evidence_sha256]
      evidence['source_text_sha256'] = expected[:source_text_sha256]
      evidence['physical_geometry_sha256'] =
        expected[:physical_geometry_sha256]
      evidence['physical_style_sha256'] = expected[:physical_style_sha256]
      row['representation_evidence'] = evidence
      geometry = fixture_geometry_payload(row)
      style = fixture_style_payload(row)
      row['geometry_evidence'] = {
        'sha256' => fidelity.canonical_sha256([geometry]),
        'payload' => [geometry]
      }
      row['style_evidence'] = {
        'sha256' => fidelity.canonical_sha256([style]),
        'payload' => [style],
        'layer_name' => style[:layer_name],
        'layer_visible' => style[:layer_visible],
        'entity_visible' => style[:entity_visible],
        'material' => style[:material],
        'back_material' => style[:back_material]
      }
    end
    expected
  end

  def fixture_geometry_payload(row)
    payload = {
      :type => row['typename'].to_s,
      :bounds => row['bounds'],
      :transformation => row['transformation']
    }
    if row['typename'].to_s == 'Text'
      content = row['content_evidence'] || {}
      payload[:anchor] = content['anchor']
      payload[:text_sha256] = Digest::SHA256.hexdigest(content['text'].to_s)
    end
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    payload[:children] = Array(row['children']).map do |child|
      fixture_geometry_payload(child)
    end.sort_by { |entry| fidelity.canonical_json(entry) }
    payload
  end

  def fixture_style_payload(row)
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    payload = {
      :type => row['typename'].to_s,
      :entity_visible => true,
      :layer_name => nil, :layer_visible => nil,
      :material => nil, :back_material => nil,
      :casts_shadows => nil, :receives_shadows => nil
    }
    payload[:children] = Array(row['children']).map do |child|
      fixture_style_payload(child)
    end.sort_by { |entry| fidelity.canonical_json(entry) }
    payload
  end

  def fixture_row_count(row)
    1 + Array(row['children']).inject(0) do |total, child|
      total + fixture_row_count(child)
    end
  end

  def fixture_visit_rows(rows, &block)
    Array(rows).each do |row|
      block.call(row)
      fixture_visit_rows(row['children'], &block)
    end
  end

  def bound_report(pdf)
    {
      'schema' => 'bcs.import_report/1.1',
      'host' => { 'app' => 'sketchup', 'version' => '17.3.116' },
      'importer' => { 'version' => '3.7.98' },
      'input' => {
        'file' => pdf,
        'sha256' => Digest::SHA256.file(pdf).hexdigest
      },
      'report_meta' => {
        'host' => 'sketchup',
        'semver' => '3.7.98',
        'build_stamp' => 'sketchup 3.7.98'
      },
      'extra' => {
        'requested_text_mode' => 'labels',
        'import_session_id' => 'session-1',
        'representation_fidelity' => { 'ready' => true },
        'import_contract_ready' => { 'ready' => true },
        'source_provenance' => {
          'schema' => 'bcs.source_provenance/1.0',
          'import_session_id' => 'session-1',
          'object_count' => 0,
          'objects' => []
        }
      }
    }
  end
end
