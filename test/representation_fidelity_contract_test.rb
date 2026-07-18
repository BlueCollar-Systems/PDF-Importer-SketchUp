#!/usr/bin/env ruby

require 'minitest/autorun'
require 'zlib'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'

TextAlignLeft = 0 unless defined?(TextAlignLeft)

class Numeric
  def degrees
    to_f * Math::PI / 180.0
  end unless method_defined?(:degrees)
end

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

  class Vector3d
    attr_accessor :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end unless const_defined?(:Vector3d)

  class Transformation
    attr_reader :kind, :args

    def initialize(*args)
      @kind = :translation
      @args = args
    end

    def self.scaling(*args)
      value = new(*args)
      value.instance_variable_set(:@kind, :scaling)
      value
    end

    def self.rotation(*args)
      value = new(*args)
      value.instance_variable_set(:@kind, :rotation)
      value
    end

    def apply(point)
      case @kind
      when :scaling
        pivot, sx, sy, sz = @args
        Geom::Point3d.new(
          pivot.x + ((point.x - pivot.x) * sx.to_f),
          pivot.y + ((point.y - pivot.y) * sy.to_f),
          pivot.z + ((point.z - pivot.z) * sz.to_f)
        )
      when :rotation
        pivot, _axis, radians = @args
        dx = point.x - pivot.x
        dy = point.y - pivot.y
        c = Math.cos(radians.to_f)
        s = Math.sin(radians.to_f)
        Geom::Point3d.new(
          pivot.x + (dx * c) - (dy * s),
          pivot.y + (dx * s) + (dy * c),
          point.z
        )
      else
        delta = @args.first || Geom::Vector3d.new
        Geom::Point3d.new(point.x + delta.x, point.y + delta.y, point.z + delta.z)
      end
    end
  end unless const_defined?(:Transformation)
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)

module Sketchup
  def self.version
    '17.2.2555'
  end unless respond_to?(:version)

  class Entities
    def add_text(*_args); end
    def add_3d_text(*_args); end
  end unless const_defined?(:Entities)

  class Text
    def text; end
    def point; end
    def vector; end
    def display_leader?; end
  end unless const_defined?(:Text)
end

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')
require 'bc_pdf_vector_importer/main'

class FidelityBounds
  attr_reader :min, :max

  def initialize(points)
    xs = points.map(&:x)
    ys = points.map(&:y)
    zs = points.map(&:z)
    @min = Geom::Point3d.new(xs.min, ys.min, zs.min)
    @max = Geom::Point3d.new(xs.max, ys.max, zs.max)
  end
end

class FidelityEntity
  attr_accessor :layer, :material, :back_material
  attr_reader :persistent_id, :bounds_reads

  def initialize(id, width, height, typename = 'Edge', depth = 0.0)
    @persistent_id = id
    @typename = typename
    @bounds_reads = 0
    @points = [
      Geom::Point3d.new(0, 0, 0),
      Geom::Point3d.new(width, 0, 0),
      Geom::Point3d.new(width, height, depth),
      Geom::Point3d.new(0, height, 0)
    ]
  end

  def typename
    @typename
  end

  def bounds
    @bounds_reads += 1
    FidelityBounds.new(@points)
  end

  def transform!(transformation)
    @points = @points.map { |point| transformation.apply(point) }
  end
end

class FidelityLabel
  attr_accessor :layer, :vector
  attr_reader :persistent_id, :point, :text, :display_leader

  def initialize(id, point, vector, text, typename = 'Text',
                 ignore_leader_write = false)
    @persistent_id = id
    @point = point
    @vector = vector
    @text = text
    @typename = typename
    @display_leader = true
    @ignore_leader_write = ignore_leader_write
  end

  def typename
    @typename
  end

  def display_leader=(value)
    @display_leader = value unless @ignore_leader_write
  end

  def display_leader?
    @display_leader
  end
end

class FidelityEntities
  attr_reader :erased, :transforms, :created_labels

  def initialize(options = {})
    @options = options
    @entities = Array(options[:preexisting]).dup
    @erased = []
    @transforms = []
    @created_labels = []
    @next_id = 100
  end

  def to_a
    @entities.dup
  end

  def add_3d_text(_text, _align, _font, _bold, _italic, height,
                  _tolerance, _z, _filled, extrusion)
    return false if @options[:mesh] == :false
    width = @options.fetch(:natural_width, height.to_f * 3.0)
    actual_height = height.to_f * @options.fetch(:natural_height_factor, 0.75)
    @next_id += 1
    @entities << FidelityEntity.new(@next_id, width, actual_height, 'Edge', extrusion)
    raise 'mesh API raised after partial creation' if @options[:mesh] == :raise_after_create
    add_test_entity(0.25, 0.25, 'Edge') if @options[:peer_after_mesh]
    true
  end

  def add_group
    @next_id += 1
    group = FidelityMeshGroup.new(@next_id, self)
    @entities << group
    group
  end

  def add_group_mesh(collection, height, extrusion)
    return false if @options[:mesh] == :false
    width = @options.fetch(:natural_width, height.to_f * 3.0)
    actual_height = height.to_f * @options.fetch(:natural_height_factor, 0.75)
    @next_id += 1
    collection.append(
      FidelityEntity.new(@next_id, width, actual_height, 'Edge', extrusion)
    )
    raise 'mesh API raised after partial creation' if @options[:mesh] == :raise_after_create
    add_test_entity(0.25, 0.25, 'Edge') if @options[:peer_after_mesh]
    true
  end

  def explode_mesh_group(group)
    @entities.delete(group)
    children = group.entities.to_a
    @entities.concat(children)
    children
  end

  def add_test_entity(width = 1.0, height = 1.0, typename = 'Edge')
    @next_id += 1
    entity = FidelityEntity.new(@next_id, width, height, typename)
    @entities << entity
    entity
  end

  def add_text(text, point, vector = nil)
    return nil if @options[:label] == :nil
    id = @options[:identityless_label] ? nil : (@next_id += 1)
    delivered_text = @options.fetch(:label_text, text)
    typename = @options.fetch(:label_typename, 'Text')
    delivered_point = if @options.key?(:label_point_z)
                        Geom::Point3d.new(
                          point.x, point.y, @options[:label_point_z]
                        )
                      else
                        point
                      end
    delivered_vector = if vector && @options.key?(:label_vector_z)
                         Geom::Vector3d.new(
                           vector.x, vector.y, @options[:label_vector_z]
                         )
                       else
                         vector
                       end
    label = FidelityLabel.new(
      id, delivered_point, delivered_vector, delivered_text, typename,
      @options[:ignore_leader_write]
    )
    @entities << label
    @created_labels << label
    raise 'label API raised after partial creation' if @options[:label] == :raise_after_create
    add_test_entity(0.25, 0.25, 'Edge') if @options[:peer_after_label]
    label
  end

  def transform_entities(transformation, *entities)
    @transforms << transformation
    return if @options[:ignore_transforms]
    entities.each { |entity| entity.transform!(transformation) }
    nil
  end

  def erase_entities(*entities)
    entities.flatten.each do |entity|
      @entities.delete(entity)
      @erased << entity
    end
    nil
  end
end

class FidelityMeshGroupEntities
  def initialize(parent)
    @parent = parent
    @entities = []
  end

  def add_3d_text(_text, _align, _font, _bold, _italic, height,
                  _tolerance, _z, _filled, extrusion)
    @parent.add_group_mesh(self, height, extrusion)
  end

  def append(entity)
    @entities << entity
  end

  def to_a
    @entities.dup
  end
end

class FidelityMeshGroup
  attr_reader :persistent_id, :entities

  def initialize(id, parent)
    @persistent_id = id
    @parent = parent
    @entities = FidelityMeshGroupEntities.new(parent)
  end

  def typename
    'Group'
  end

  def explode
    @parent.explode_mesh_group(self)
  end
end

class FidelityOwnedCollection
  attr_reader :items, :erased

  def initialize(items)
    @items = items
    @erased = []
  end

  def to_a
    @items.dup
  end

  def erase_entities(*entities)
    entities.flatten.each do |entity|
      @items.delete(entity)
      @erased << entity
    end
  end
end

class FidelityTypedCollection
  def initialize(items)
    @items = items
  end

  def to_a
    @items.dup
  end
end

FidelityTypedEntity = Struct.new(:typename, :entities)
FidelityPageGroup = Struct.new(:entities)

class RepresentationFidelityContractTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  GB = IMP::GeometryBuilder
  TI = IMP::TextParser::TextItem

  def item(text = 'A1', angle = 0.0, width_points = 24.0,
           height_points = 10.0, source_id = 'text_span:1:0')
    radians = angle.to_f * Math::PI / 180.0
    w = width_points.to_f
    h = height_points.to_f
    box_w = (Math.cos(radians).abs * w) + (Math.sin(radians).abs * h)
    box_h = (Math.sin(radians).abs * w) + (Math.cos(radians).abs * h)
    TI.new(text, 20.0, 30.0, height_points.to_f, angle.to_f, 'Arial', nil,
           20.0, 30.0, 20.0 + box_w, 30.0 + box_h, nil, source_id)
  end

  def move_item(source, x, y)
    dx = x.to_f - source.x.to_f
    dy = y.to_f - source.y.to_f
    source.x = source.x.to_f + dx
    source.y = source.y.to_f + dy
    source.bbox_x0 = source.bbox_x0.to_f + dx
    source.bbox_x1 = source.bbox_x1.to_f + dx
    source.bbox_y0 = source.bbox_y0.to_f + dy
    source.bbox_y1 = source.bbox_y1.to_f + dy
    source
  end

  def builder(mode, provenance = [])
    GB.new(nil, [], [], [0, 0, 612, 792],
           import_text: true,
           use_3d_text: mode == :text3d,
           requested_text_mode: mode,
           native_font_identity_resolver: lambda { |source|
             {
               source_span_id: source.source_span_id,
               pdf_font_identity: 'embedded:Arial:test-fixture',
               installed_family: 'Arial',
               exact_family_match: true,
               verified: true
             }
           },
           provenance_bucket: provenance,
           page_number: 1)
  end

  def test_text_and_labels_remain_distinct_across_fidelity_boundaries
    assert_equal :text, IMP.normalize_text_renderer_mode('Text')
    assert_equal :text, IMP::RepresentationFidelity.normalize_mode('Text')
    assert_equal :text,
                 builder(:text).send(:normalize_text_mode_symbol, 'Text')
    assert_equal :labels, IMP.normalize_text_renderer_mode('Labels')
    refute_equal IMP.normalize_text_renderer_mode('Text'),
                 IMP.normalize_text_renderer_mode('Labels')
  end

  def test_explicit_item_raster_is_requested_delivery_not_fallback
    source = item('RASTER', 0.0, 24.0, 10.0)
    artifact = {
      source_span_id: source.source_span_id,
      page_number: 1,
      source_crop_binding_verified: true,
      page_binding_verified: true,
      png_signature_verified: true,
      aspect_verified: true,
      source_pdf_sha256: 'a' * 64,
      source_pdf_binding_verified: true,
      content_sha256: 'b' * 64,
      content_byte_size: 4096,
      pixel_width: 300,
      pixel_height: 120,
      source_box: [20.0, 30.0, 44.0, 40.0],
      pixel_crop: [100, 200, 300, 120],
      alpha_channel_verified: true,
      transparent_background_verified: true,
      visible_pixel_verified: true,
      page_render_once_verified: true,
      page_render_content_sha256: 'c' * 64
    }
    raster = {
      entity_id: 'persistent_id:404', artifact_evidence: artifact,
      real_raster_verified: true, visual_fidelity_verified: true
    }
    stats = {
      requested_text_mode: :raster, text_mode: :raster,
      selected_pages: [1], text_source_span_ids: [source.source_span_id],
      text_attempts: [], terminal_text_delivery_records: [],
      raster_delivery_records: [], text_renderers: [],
      source_provenance_objects: [], page_text_delivery_records: [],
      page_representation_fallbacks: [], source_glyph_physical_deliveries: [],
      fallback_transitions: [], raster_fallback_used: false, text: 0,
      source_input_sha256: 'a' * 64, normalized_input_sha256: 'a' * 64
    }

    assert IMP.record_item_raster_delivery!(
      stats, 1, source, :raster, raster, [], []
    )

    attempt = stats[:text_attempts].first
    record = stats[:terminal_text_delivery_records].first
    renderer = stats[:text_renderers].first
    assert_equal :raster, attempt[:requested_mode]
    assert_equal :raster, attempt[:delivered_mode]
    assert_equal :raster, record[:requested_mode]
    assert_equal :raster, record[:delivered_mode]
    assert_equal false, stats[:raster_fallback_used]
    assert_equal false, renderer[:degraded]
    assert_empty stats[:fallback_transitions]
    assert_equal 'a' * 64,
                 record[:artifact_evidence][:source_pdf_sha256]
    assert_equal true, IMP::QAReport.send(
      :validate_representation_fidelity, stats
    )[:ready]

    mislabeled = Marshal.load(Marshal.dump(stats))
    mislabeled[:raster_fallback_used] = true
    assert_equal false, IMP::QAReport.send(
      :validate_representation_fidelity, mislabeled
    )[:ready]
  end

  def test_item_raster_record_rejects_missing_pdf_sha_binding
    source = item('RASTER', 0.0, 24.0, 10.0)
    raster = {
      entity_id: 'persistent_id:405', real_raster_verified: true,
      visual_fidelity_verified: true,
      artifact_evidence: {
        source_span_id: source.source_span_id, page_number: 1,
        source_crop_binding_verified: true, content_sha256: 'b' * 64
      }
    }
    stats = {}

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.record_item_raster_delivery!(
        stats, 1, source, :raster, raster, [], []
      )
    end
  end

  def test_flat_text_capability_rung_is_bound_before_label_delivery
    source = item('EDITABLE', 0.0, 24.0, 10.0)
    prepared = IMP.prepare_flat_text_fallback_controllers!([source])
    row = prepared.fetch(source.source_span_id)
    attempt = {
      source_span_id: source.source_span_id,
      source_text_sha256: Digest::SHA256.hexdigest(source.text),
      source_bbox_pdf: [source.bbox_x0, source.bbox_y0,
                        source.bbox_x1, source.bbox_y1],
      requested_mode: :text,
      delivered_mode: :labels,
      attempt_history: [{
        mode: :labels, outcome: :complete,
        resulting_entity_ids: ['persistent_id:501']
      }]
    }

    IMP.bind_flat_text_capability_attempt!(attempt, row[:proof])

    assert_equal [:text, :labels],
                 attempt[:attempt_history].map { |entry| entry[:mode] }
    text_rung = attempt[:attempt_history].first
    assert_equal :failed, text_rung[:outcome]
    assert_equal row[:proof], text_rung[:transition_proof]
    assert_equal :labels, row[:controller].current_mode
    assert_equal :text, attempt[:requested_mode]
  end

  def test_flat_text_capability_attempt_rejects_source_sha_mismatch
    source = item('EDITABLE', 0.0, 24.0, 10.0)
    proof = IMP.prepare_flat_text_fallback_controllers!([source]).
      fetch(source.source_span_id).fetch(:proof)
    attempt = {
      source_span_id: source.source_span_id,
      source_text_sha256: 'f' * 64,
      source_bbox_pdf: [source.bbox_x0, source.bbox_y0,
                        source.bbox_x1, source.bbox_y1],
      requested_mode: :text, delivered_mode: :labels,
      attempt_history: []
    }

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.bind_flat_text_capability_attempt!(attempt, proof)
    end
  end

  def test_qa_rebinds_flat_text_capability_proof_to_attempt_source_content
    source = item('EDITABLE', 0.0, 24.0, 10.0)
    proof = IMP.prepare_flat_text_fallback_controllers!([source]).
      fetch(source.source_span_id).fetch(:proof)
    flags = {
      visual_fidelity_verified: true, placement_verified: true,
      rotation_verified: true, content_verified: true,
      entity_type_verified: true, leader_verified: true
    }
    complete = {
      mode: :labels, outcome: :complete,
      resulting_entity_ids: ['persistent_id:601'],
      cleanup_outcome: :not_required
    }.merge(flags)
    failed = IMP.failed_item_rung_from_transition(proof)
    valid = {
      requested_text_mode: :text, text_mode: :text, selected_pages: [1],
      text_source_span_ids: [source.source_span_id],
      source_provenance_objects: [{
        object_id: 'text_delivery:1:0', page: 1, source_kind: 'text_span',
        span_id: source.source_span_id, created_entity_type: 'native_label',
        resulting_entity_ids: ['persistent_id:601']
      }],
      text_attempts: [{
        source_span_id: source.source_span_id,
        source_text_sha256: Digest::SHA256.hexdigest(source.text),
        source_bbox_pdf: [source.bbox_x0, source.bbox_y0,
                          source.bbox_x1, source.bbox_y1],
        requested_mode: :text, delivered_mode: :labels,
        resulting_entity_ids: ['persistent_id:601'],
        attempt_history: [failed, complete]
      }.merge(flags)],
      fallback_transitions: [Marshal.load(Marshal.dump(proof))]
    }
    valid_result = IMP::QAReport.send(:validate_representation_fidelity, valid)
    assert_equal true, valid_result[:ready], valid_result[:errors].inspect

    source_mismatch = Marshal.load(Marshal.dump(valid))
    local = source_mismatch[:text_attempts][0][:attempt_history][0][
      :transition_proof
    ]
    local[:evidence][:source_text_sha256] = 'c' * 64
    unsigned = local[:evidence].dup
    unsigned.delete(:evidence_sha256)
    local[:evidence][:evidence_sha256] =
      IMP::RepresentationFidelity.canonical_sha256(unsigned)
    source_mismatch[:fallback_transitions] = [
      Marshal.load(Marshal.dump(local))
    ]
    assert_equal false, IMP::QAReport.send(
      :validate_representation_fidelity, source_mismatch
    )[:ready]

    ledger_mismatch = Marshal.load(Marshal.dump(valid))
    global = ledger_mismatch[:fallback_transitions][0]
    global[:evidence][:source_text_sha256] = 'd' * 64
    unsigned = global[:evidence].dup
    unsigned.delete(:evidence_sha256)
    global[:evidence][:evidence_sha256] =
      IMP::RepresentationFidelity.canonical_sha256(unsigned)
    assert_equal false, IMP::QAReport.send(
      :validate_representation_fidelity, ledger_mismatch
    )[:ready]
  end

  def test_text_labels_text3d_terminal_record_preserves_source_bbox_chain
    source = item('ROTATED', -90.0, 24.0, 10.0)
    source_id = source.source_span_id
    source_bbox = [source.bbox_x0, source.bbox_y0,
                   source.bbox_x1, source.bbox_y1]
    text_proof = IMP.prepare_flat_text_fallback_controllers!([source]).
      fetch(source_id).fetch(:proof)
    label_builder = builder(:labels)
    label_x, label_y, = label_builder.send(:label_insertion_pdf, source)
    label_anchor = label_builder.send(
      :text_point_to_su, source, label_x, label_y, 0.0, 0.0
    )
    label_proof = label_builder.send(
      :host_unsupported_label_rotation_proof, source, -90.0, label_anchor
    )
    prior = {
      source_span_id: source_id,
      source_text_sha256: Digest::SHA256.hexdigest(source.text),
      source_bbox_pdf: source_bbox,
      requested_mode: :text,
      delivered_mode: nil,
      attempt_history: [
        IMP.failed_item_rung_from_transition(text_proof),
        IMP.failed_item_rung_from_transition(label_proof)
      ]
    }
    expected = {
      source_text_sha256: Digest::SHA256.hexdigest(source.text),
      source_bbox_pdf: source_bbox,
      source_anchor: [1.0, 2.0, 0.0],
      source_rotation_radians: -Math::PI / 2.0,
      expected_width: 10.0 / 72.0,
      expected_height: 24.0 / 72.0,
      expected_depth: 0.015625,
      physical_style_sha256: 'a' * 64,
      physical_geometry_sha256: 'b' * 64,
      expected_transformation: { kind: 'source_glyph_3d_text' }
    }
    row = {
      source_span_id: source_id,
      group_entity_id: 'persistent_id:701',
      identity_verified: true,
      placement_verified: true,
      rotation_verified: true,
      size_verified: true,
      depth_verified: true,
      content_verified: true,
      physical_geometry_verified: true,
      physical_style_verified: true,
      transform_verified: true,
      depth: 0.015625,
      width: 10.0 / 72.0,
      height: 24.0 / 72.0,
      extruded_face_count: 4,
      expected_evidence: expected
    }
    stats = {
      requested_text_mode: :text,
      text_mode: :text,
      selected_pages: [1],
      text_source_span_ids: [source_id],
      text_attempts: [],
      text_renderers: [],
      source_provenance_objects: [],
      fallback_transitions: [
        Marshal.load(Marshal.dump(text_proof)),
        Marshal.load(Marshal.dump(label_proof))
      ]
    }

    IMP::Svg3DTextRenderer.stub(
      :finalize_source_evidence!,
      lambda { |_result, _source, _page_rotation| true }
    ) do
      IMP.record_svg_3d_text_delivery!(
        stats, 1, [source], { span_results: [row] }, :text,
        { source_id => prior }, 0.0
      )
    end

    terminal = stats[:text_attempts].fetch(0)
    assert_equal source_bbox, terminal[:source_bbox_pdf]
    assert_equal [:text, :labels, :text3d],
                 terminal[:attempt_history].map { |rung| rung[:mode] }
    result = IMP::QAReport.send(:validate_representation_fidelity, stats)
    assert_equal true, result[:ready], result[:errors].inspect
  end

  def test_source_extent_bounds_are_derived_from_the_required_page_transform
    matrix = [
      0.0, 1.0, 0.0, 0.0,
      -1.0, 0.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      10.0, 20.0, 0.0, 1.0
    ]

    bounds = IMP::RepresentationFidelity.transformed_extent_bounds(
      [1.0, 2.0, 3.0, 5.0], matrix, 0.0, 0.5
    )

    assert_equal [5.0, 21.0, 0.0], bounds[:min]
    assert_equal [8.0, 23.0, 0.5], bounds[:max]
  end

  def test_native_3d_text_stops_before_creation_without_exact_font_identity_proof
    source = item('NO SUBSTITUTE')
    b = GB.new(nil, [], [], [0, 0, 612, 792],
               import_text: true, use_3d_text: true,
               requested_text_mode: :text3d, page_number: 1)
    entities = FidelityEntities.new

    refute b.send(:place_mesh_text, entities, source, 0, 0, nil)
    assert_empty entities.to_a
    failure = b.text_delivery_failures.last
    assert_match(/font_identity_unverified/, failure[:reason])
    rung = b.text_attempts.last[:attempt_history].last
    assert_equal :not_required, rung[:cleanup_outcome]
  end

  def test_text3d_has_no_arbitrary_height_or_width_factor_roadblocks
    b = builder(:text3d)
    tiny = item('tiny', 0.0, 24.0, 0.1)
    huge = item('huge', 0.0, 24.0, 300.0)
    ratio = GB::ARIAL_LETTER_HEIGHT_TO_EM
    assert_in_delta (0.1 / 72.0) * ratio,
                    b.send(:mesh_text_height_inches, tiny, 0, 792), 1e-12
    assert_in_delta (300.0 / 72.0) * ratio,
                    b.send(:mesh_text_height_inches, huge, 0, 792), 1e-12

    [0.1, 10.0].each do |factor|
      source = item('factor', 0.0, 24.0 * factor, 8.0)
      entities = FidelityEntities.new(natural_width: 24.0 / 72.0)
      assert b.send(:place_mesh_text, entities, source, 0, 0, nil)
      scale = entities.transforms.find { |tr| tr.kind == :scaling }
      refute_nil scale
      assert_in_delta factor, scale.args[1], 1e-6
    end
  end

  def test_diagonal_text_is_fitted_and_true_post_transform_evidence_is_required
    provenance = []
    b = builder(:text3d, provenance)
    entities = FidelityEntities.new(
      natural_width: 80.0 / 72.0,
      natural_height_factor: 0.6
    )

    assert b.send(:place_mesh_text, entities, item('SLOPE', 37.0, 42.0, 9.0), 0, 0, nil)
    attempt = b.text_attempts.last
    assert_equal true, attempt[:visual_fidelity_verified]
    assert_equal true, attempt[:placement_verified]
    assert_equal true, attempt[:rotation_verified]
    assert_equal true, attempt[:width_verified]
    assert_equal true, attempt[:height_verified]
    assert_operator entities.to_a.first.bounds_reads, :>=, 3,
                    'bounds must be re-read after scale and final placement/rotation'
    assert_equal attempt[:resulting_entity_ids], provenance.last[:resulting_entity_ids]
  end

  def test_failed_visual_verification_erases_mesh_and_stops_in_text3d
    provenance = []
    b = builder(:text3d, provenance)
    entities = FidelityEntities.new(ignore_transforms: true)

    refute b.send(:place_mesh_text, entities, item, 0, 0, nil)
    attempt = b.text_attempts.last
    assert_equal 1, attempt[:attempt_history].length
    mesh_rung = attempt[:attempt_history].first
    assert_equal :failed, mesh_rung[:outcome]
    assert_equal :verified, mesh_rung[:cleanup_outcome]
    assert_empty mesh_rung[:resulting_entity_ids]
    refute_empty mesh_rung[:cleaned_entity_ids]
    assert_nil attempt[:delivered_mode]
    assert_empty attempt[:resulting_entity_ids]
    assert_empty entities.to_a
  end

  def test_simplified_stroke_font_cannot_be_certified_as_requested_glyphs
    builder_source = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb'),
      encoding: 'UTF-8'
    )
    refute_match(/glyph_outline_text/, builder_source)
    refute_match(/place_glyph_outline_text/, builder_source)
    refute_match(/StrokeFont\.render/, builder_source)
  end

  def test_dormant_downgrade_renderers_are_not_shipped
    support = File.join(SRC_ROOT, 'bc_pdf_vector_importer')
    %w[stroke_font.rb svg_geometry_renderer.rb].each do |name|
      refute File.exist?(File.join(support, name)),
        "obsolete representation route must remain absent: #{name}"
    end
  end

  def test_text3d_api_exception_cleans_partial_mesh_and_stops_in_text3d
    source = item('partial mesh')
    b = builder(:text3d)
    entities = FidelityEntities.new(mesh: :raise_after_create)

    refute b.send(:place_mesh_text, entities, source, 0, 0, nil)
    failed = b.text_attempts.first[:attempt_history].first
    assert_equal :text3d, failed[:mode]
    assert_equal :failed, failed[:outcome]
    assert_equal ['persistent_id:101'], failed[:created_entity_ids]
    assert_equal failed[:created_entity_ids], failed[:cleaned_entity_ids]
    assert_equal [101], entities.erased.map(&:persistent_id)
    assert_empty b.text_attempts.first[:resulting_entity_ids]
    assert_empty entities.to_a
  end

  def test_text3d_cleanup_erases_only_exploded_owned_geometry_not_a_peer
    source = item('owned mesh')
    b = builder(:text3d)
    entities = FidelityEntities.new(peer_after_mesh: true)

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      b.send(:place_mesh_text, entities, source, 0, 0, nil)
    end
    assert_equal [103], entities.to_a.map(&:persistent_id)
    assert_equal [102], entities.erased.map(&:persistent_id)
  end

  def test_label_api_exception_never_claims_an_unreturned_partial_label
    source = item('partial label')
    b = builder(:labels)
    entities = FidelityEntities.new(label: :raise_after_create)

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      b.send(:place_annotation_label, entities, source, 0, 0, nil)
    end
    assert_equal [101], entities.to_a.map(&:persistent_id)
    assert_empty entities.erased
  end

  def test_label_cleanup_erases_only_the_explicit_label_not_a_peer
    source = item('owned label')
    b = builder(:labels)
    entities = FidelityEntities.new(peer_after_label: true)

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      b.send(:place_annotation_label, entities, source, 0, 0, nil)
    end
    assert_equal [102], entities.to_a.map(&:persistent_id)
    assert_equal [101], entities.erased.map(&:persistent_id)
  end

  def test_identityless_label_is_erased_and_never_certified
    provenance = []
    b = builder(:labels, provenance)
    entities = FidelityEntities.new(identityless_label: true)

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      b.send(:place_annotation_label, entities, item, 0, 0, nil, :labels)
    end
    assert_equal 1, entities.erased.length
    assert_empty entities.to_a
    assert_empty provenance
  end

  def test_missing_source_identity_fails_before_creating_any_entity
    provenance = []
    b = builder(:labels, provenance)
    entities = FidelityEntities.new

    refute b.send(:place_annotation_label, entities,
                  item('NO ID', 0, 24, 10, nil), 0, 0, nil, :labels)
    assert_empty entities.to_a
    assert_empty provenance
    assert_match(/source.*identity/i, b.text_delivery_failures.last[:reason])
  end

  def test_snapshot_or_ownership_failure_escapes_item_fallback_for_atomic_abort
    b = builder(:labels)
    entities = FidelityEntities.new(preexisting: [Object.new])

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      b.send(:place_text, entities, item, 0, 0, 792, nil)
    end

    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'),
      encoding: 'UTF-8'
    )
    assert_match(
      /rescue\s+RepresentationFidelity::ContractError\s*=>.*?raise/m,
      main,
      'page loop must not convert ownership uncertainty into a partial success'
    )
  end

  def test_label_anchor_and_rotation_must_be_observable_after_creation
    provenance = []
    b = builder(:labels, provenance)
    entities = FidelityEntities.new
    source = item('ROT', 31.0)

    refute b.send(:place_annotation_label, entities, source, 0, 0, nil, :labels)
    assert_empty entities.to_a
    assert_empty provenance
    attempt = b.text_attempts.last
    assert_nil attempt[:delivered_mode]
    proof = attempt[:attempt_history].last[:transition_proof]
    assert_equal :labels, proof[:from_mode]
    assert_equal :text3d, proof[:to_mode]
    assert_equal :host_representation_unsupported, proof[:reason_code]
    evidence = proof.fetch(:evidence)
    assert_equal IMP::RepresentationFidelity.strict_source_bbox_pdf(source),
                 evidence.fetch(:source_bbox_pdf)
    assert_equal 3, evidence.fetch(:source_anchor).length
    assert evidence.fetch(:source_anchor).all? { |value| value.is_a?(Numeric) }
    assert_in_delta 31.0 * Math::PI / 180.0,
                    evidence.fetch(:source_rotation_radians), 1.0e-9
    assert_operator evidence.fetch(:expected_width), :>, 0.0
    assert_operator evidence.fetch(:expected_height), :>, 0.0
  end

  def test_native_label_expected_dimensions_use_the_configured_import_scale
    source = item('SCALED LABEL', 0.0, 24.0, 10.0)
    b = GB.new(nil, [], [], [0, 0, 612, 792],
               import_text: true,
               requested_text_mode: :labels,
               scale_factor: 2.5,
               provenance_bucket: [],
               page_number: 1)
    entities = FidelityEntities.new

    assert b.send(
      :place_annotation_label, entities, source, 0.0, 0.0, nil, :labels
    )

    expected = b.text_attempts.fetch(0).fetch(:expected_evidence)
    assert_in_delta 24.0 * 2.5 / 72.0,
                    expected.fetch(:expected_width), 1.0e-9
    assert_in_delta 10.0 * 2.5 / 72.0,
                    expected.fetch(:expected_height), 1.0e-9
    label_x, label_y, = b.send(:label_insertion_pdf, source)
    expected_anchor = IMP::RepresentationFidelity.numeric_point(
      b.send(:text_point_to_su, source, label_x, label_y, 0.0, 0.0)
    )
    assert_equal expected_anchor, expected.fetch(:source_anchor)
    assert_equal 0.0, expected.fetch(:source_rotation_radians)
  end

  def test_label_wrong_visual_or_entity_evidence_is_cleaned_and_never_certified
    [
      { label_text: 'WRONG' },
      { label_typename: 'ComponentInstance' },
      { label_point_z: 3.0 },
      { ignore_leader_write: true }
    ].each do |options|
      b = builder(:labels)
      entities = FidelityEntities.new(options)

      refute b.send(:place_annotation_label, entities, item, 0, 0, nil, :labels)
      assert_empty entities.to_a
      attempt = b.text_attempts.last
      assert_nil attempt[:delivered_mode]
      assert_equal false, attempt[:visual_fidelity_verified]
      assert_equal :verified, attempt[:attempt_history].last[:cleanup_outcome]
    end
  end

  def test_completed_rung_requires_mode_specific_evidence_before_mutating_attempt
    b = builder(:text3d)
    attempt = {
      requested_mode: :text3d, delivered_mode: nil,
      resulting_entity_ids: [], visual_fidelity_verified: false
    }
    rung = { outcome: :attempting, resulting_entity_ids: [] }

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      b.send(
        :complete_text_rung!, attempt, rung, :text3d,
        ['persistent_id:101'],
        placement_verified: true, rotation_verified: true,
        width_verified: false, height_verified: true,
        entity_type_verified: true
      )
    end
    assert_nil attempt[:delivered_mode]
    assert_equal :attempting, rung[:outcome]
  end

  def test_geometry_and_glyphs_have_distinct_production_renderers_and_entity_types
    main = File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'), encoding: 'UTF-8')
    renderer = File.read(
      File.join(
        SRC_ROOT, 'bc_pdf_vector_importer',
        'svg_item_representation_renderer.rb'
      ),
      encoding: 'UTF-8'
    )
    refute_match(/require.*svg_geometry_renderer|SvgGeometryRenderer/, main)
    assert_match(
      /Array\(text_items\)\.each do \|source_item\|.*?FallbackController\.new\(\s*requested_text_mode, source_id\s*\).*?complete_item_representation_ladder!/m,
      main
    )
    assert_match(/SvgItemRepresentationRenderer\.render_svg/, main)
    assert_match(/build_flat_geometry!/, renderer)
    assert_match(/build_glyph_groups!/, renderer)
    assert_match(/assign_identity!\(group, source_id, mode/, renderer)
    assert_match(/assign_identity!\(\s*edge, source_id, mode/m, renderer)
    assert_match(/assign_identity!\(\s*glyph, source_id, :glyphs/m, renderer)

    counts = IMP::QAReport.send(:build_actual_text_entity_types_from_delivered_counts,
      'glyph_outline' => 2, 'page_path_geometry' => 3)
    assert_equal 'mixed', counts[:entity_type]
    assert_equal 2, counts[:glyph_outline]
    assert_equal 3, counts[:page_path_geometry]
  end

  def test_failed_page_representation_attempt_erases_only_its_owned_group
    entity = Struct.new(:persistent_id)
    preexisting = entity.new(801)
    failed_group = entity.new(802)
    collection = FidelityOwnedCollection.new([preexisting, failed_group])

    cleaned = IMP::RepresentationFidelity.erase_owned!(
      collection, [failed_group]
    )

    assert_equal ['persistent_id:802'], cleaned
    assert_equal [preexisting], collection.items
    assert_equal [failed_group], collection.erased
  end

  def test_page_geometry_delivery_uses_one_distinct_group_with_exact_source_set_evidence
    group = Struct.new(:persistent_id, :entities).new(
      707,
      FidelityTypedCollection.new([
        FidelityTypedEntity.new('Edge', nil),
        FidelityTypedEntity.new('Edge', nil)
      ])
    )
    stats = {
      requested_text_mode: :geometry, text_mode: :geometry,
      text_source_span_ids: ['text_span:1:0', 'text_span:1:1'],
      text_attempts: [], source_provenance_objects: [],
      page_text_delivery_records: [], text_renderers: []
    }
    items = [item('A', 0, 12, 8, 'text_span:1:0'),
             move_item(item('B', 0, 12, 8, 'text_span:1:1'), 60, 30)]
    svg_result = {
      glyphs: 2, edges: 2, skipped_glyphs: 0, missing_glyphs: 0,
      placement_failures: 0,
      placements_pdf: [{ x: 21.0, y: 31.0 }, { x: 61.0, y: 31.0 }],
      raw_edge_glyphs: true, component_container: false,
      glyph_instances: 0, flattened_glyph_instances: 0
    }

    assert IMP.record_page_geometry_delivery!(
      stats, 1, items, group, svg_result, [0, 0, 612, 792]
    )
    record = stats[:page_text_delivery_records].first
    assert_equal :geometry, record[:delivered_mode]
    assert_equal 'page_path_geometry', record[:created_entity_type]
    assert_equal ['text_span:1:0', 'text_span:1:1'], record[:source_span_ids]
    assert_equal ['persistent_id:707'], record[:resulting_entity_ids]
    assert_equal true, IMP::QAReport.send(
      :validate_representation_fidelity, stats
    )[:ready]

    missing_rung_visual = Marshal.load(Marshal.dump(stats))
    missing_rung_visual[:text_attempts][0][:attempt_history][0].delete(
      :visual_fidelity_verified
    )
    assert_equal false, IMP::QAReport.send(
      :validate_representation_fidelity, missing_rung_visual
    )[:ready], 'page delivery must prove visual fidelity on its terminal rung'

    invalid_rung_cleanup = Marshal.load(Marshal.dump(stats))
    invalid_rung_cleanup[:text_attempts][0][:attempt_history][0][
      :cleanup_outcome
    ] = :unknown
    assert_equal false, IMP::QAReport.send(
      :validate_representation_fidelity, invalid_rung_cleanup
    )[:ready], 'page delivery must prove that terminal cleanup was not required'

    wrong_group = Struct.new(:persistent_id, :entities).new(
      709,
      FidelityTypedCollection.new([
        FidelityTypedEntity.new('ComponentInstance', nil),
        FidelityTypedEntity.new('ComponentInstance', nil)
      ])
    )
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.record_page_geometry_delivery!(
        stats, 1, items, wrong_group, svg_result, [0, 0, 612, 792]
      )
    end
  end

  def test_page_glyph_delivery_uses_one_component_group_with_exact_source_set_evidence
    instances = FidelityTypedCollection.new([
      FidelityTypedEntity.new('ComponentInstance', nil),
      FidelityTypedEntity.new('ComponentInstance', nil)
    ])
    group = Struct.new(:persistent_id, :entities).new(
      708,
      FidelityTypedCollection.new([
        FidelityTypedEntity.new('Group', instances)
      ])
    )
    stats = {
      requested_text_mode: :glyphs, text_mode: :glyphs,
      text_source_span_ids: ['text_span:1:0', 'text_span:1:1'],
      text_attempts: [], source_provenance_objects: [],
      page_text_delivery_records: [], text_renderers: []
    }
    items = [item('A', 0, 12, 8, 'text_span:1:0'),
             move_item(item('B', 0, 12, 8, 'text_span:1:1'), 60, 30)]
    svg_result = {
      glyphs: 2, edges: 4, skipped_glyphs: 0, missing_glyphs: 0,
      placement_failures: 0,
      placements_pdf: [{ x: 21.0, y: 31.0 }, { x: 61.0, y: 31.0 }],
      raw_edge_glyphs: false, component_container: true,
      glyph_instances: 2, flattened_glyph_instances: 0
    }

    assert IMP.record_page_glyph_delivery!(
      stats, 1, items, group, svg_result, [0, 0, 612, 792]
    )
    record = stats[:page_text_delivery_records].first
    assert_equal :glyphs, record[:delivered_mode]
    assert_equal 'glyph_outline', record[:created_entity_type]
    assert_equal ['text_span:1:0', 'text_span:1:1'], record[:source_span_ids]
    assert_equal ['persistent_id:708'], record[:resulting_entity_ids]
    assert_equal true, IMP::QAReport.send(
      :validate_representation_fidelity, stats
    )[:ready]
  end

  def test_svg_page_visual_evidence_rejects_skips_missing_shapes_and_failed_placements
    source = item('A', 0, 12, 8, 'text_span:1:0')
    complete = {
      glyphs: 1, edges: 1, skipped_glyphs: 0, missing_glyphs: 0,
      placement_failures: 0, placements_pdf: [{ x: 21.0, y: 31.0 }],
      raw_edge_glyphs: true, component_container: false,
      glyph_instances: 0, flattened_glyph_instances: 0
    }
    geometry_group = FidelityPageGroup.new(
      FidelityTypedCollection.new([FidelityTypedEntity.new('Edge', nil)])
    )

    assert IMP.svg_page_visual_fidelity_verified?(
      complete, [source], [0, 0, 612, 792], :geometry, geometry_group
    )
    [:skipped_glyphs, :missing_glyphs, :placement_failures].each do |key|
      incomplete = complete.merge(key => 1)
      refute IMP.svg_page_visual_fidelity_verified?(
        incomplete, [source], [0, 0, 612, 792], :geometry, geometry_group
      ), "#{key} must prevent visual-fidelity certification"
    end
    misplaced = complete.merge(placements_pdf: [{ x: 200.0, y: 300.0 }])
    refute IMP.svg_page_visual_fidelity_verified?(
      misplaced, [source], [0, 0, 612, 792], :geometry, geometry_group
    )

    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'), encoding: 'UTF-8'
    )
    renderer = File.read(
      File.join(
        SRC_ROOT, 'bc_pdf_vector_importer',
        'svg_item_representation_renderer.rb'
      ),
      encoding: 'UTF-8'
    )
    assert_match(
      /build_glyph_groups!\(group, entries, source_id, opts\[:layer\]\)/,
      renderer,
      'Glyphs must use independently owned source-bound physical groups'
    )
    assert_match(/SvgItemRepresentationRenderer\.render_svg/, main)
  end


  def test_svg_page_delivery_reads_back_actual_geometry_and_glyph_entity_types
    source = item('A', 0, 12, 8, 'text_span:1:0')
    common = {
      glyphs: 1, edges: 1, skipped_glyphs: 0, missing_glyphs: 0,
      placement_failures: 0, placements_pdf: [{ x: 21.0, y: 31.0 }],
      flattened_glyph_instances: 0
    }
    raw_edges = FidelityPageGroup.new(
      FidelityTypedCollection.new([FidelityTypedEntity.new('Edge', nil)])
    )
    wrong_geometry = FidelityPageGroup.new(
      FidelityTypedCollection.new([FidelityTypedEntity.new('ComponentInstance', nil)])
    )
    geometry = common.merge(
      raw_edge_glyphs: true, component_container: false, glyph_instances: 0
    )
    assert IMP.svg_page_visual_fidelity_verified?(
      geometry, [source], [0, 0, 612, 792], :geometry, raw_edges
    )
    refute IMP.svg_page_visual_fidelity_verified?(
      geometry, [source], [0, 0, 612, 792], :geometry, wrong_geometry
    )

    components = FidelityTypedCollection.new(
      [FidelityTypedEntity.new('ComponentInstance', nil)]
    )
    container = FidelityTypedEntity.new('Group', components)
    glyph_group = FidelityPageGroup.new(
      FidelityTypedCollection.new([container])
    )
    wrong_glyphs = FidelityPageGroup.new(
      FidelityTypedCollection.new([FidelityTypedEntity.new('Edge', nil)])
    )
    glyphs = common.merge(
      raw_edge_glyphs: false, component_container: true, glyph_instances: 1
    )
    assert IMP.svg_page_visual_fidelity_verified?(
      glyphs, [source], [0, 0, 612, 792], :glyphs, glyph_group
    )
    refute IMP.svg_page_visual_fidelity_verified?(
      glyphs, [source], [0, 0, 612, 792], :glyphs, wrong_glyphs
    )
    refute IMP.svg_page_visual_fidelity_verified?(
      glyphs.merge(glyph_instances: 0), [source], [0, 0, 612, 792],
      :glyphs, glyph_group
    )
  end

  def test_qa_identity_ledger_accepts_exact_cross_links_and_rejects_bad_or_orphan_ids
    valid = {
      requested_text_mode: :text3d, text_mode: :text3d,
      text_source_span_ids: ['text_span:1:0'],
      source_provenance_objects: [{
        object_id: 'text_delivery:1:0', page: 1, source_kind: 'text_span',
        span_id: 'text_span:1:0', created_entity_type: 'native_3d_text',
        resulting_entity_ids: ['persistent_id:101']
      }],
      text_attempts: [{
        source_span_id: 'text_span:1:0', requested_mode: :text3d,
        delivered_mode: :text3d, resulting_entity_ids: ['persistent_id:101'],
        visual_fidelity_verified: true,
        placement_verified: true, rotation_verified: true,
        width_verified: true, height_verified: true,
        entity_type_verified: true,
        attempt_history: [{
          mode: :text3d, outcome: :complete,
          resulting_entity_ids: ['persistent_id:101'], cleanup_outcome: :not_required,
          visual_fidelity_verified: true,
        placement_verified: true, rotation_verified: true,
        width_verified: true, height_verified: true,
        entity_type_verified: true
        }]
      }]
    }
    result = IMP::QAReport.send(:validate_representation_fidelity, valid)
    assert_equal true, result[:ready]

    malformed = Marshal.load(Marshal.dump(valid))
    malformed[:text_attempts][0][:resulting_entity_ids] = ['persistent_id:abc']
    assert_equal false, IMP::QAReport.send(:validate_representation_fidelity, malformed)[:ready]

    wrong_type = Marshal.load(Marshal.dump(valid))
    wrong_type[:source_provenance_objects][0][:created_entity_type] = 'native_label'
    assert_equal false,
                 IMP::QAReport.send(
                   :validate_representation_fidelity, wrong_type
                 )[:ready],
                 'Text3D delivery must cross-link to native_3d_text provenance'

    orphan = Marshal.load(Marshal.dump(valid))
    orphan[:source_provenance_objects][0][:resulting_entity_ids] = ['entity_id:202']
    assert_equal false, IMP::QAReport.send(:validate_representation_fidelity, orphan)[:ready]

    duplicate_rungs = Marshal.load(Marshal.dump(valid))
    duplicate_rungs[:text_attempts][0][:attempt_history].unshift(
      mode: :labels, outcome: :failed, resulting_entity_ids: ['persistent_id:101'],
      cleanup_outcome: :verified
    )
    assert_equal false, IMP::QAReport.send(:validate_representation_fidelity, duplicate_rungs)[:ready]
  end

  def test_qa_requires_mode_specific_text_delivery_evidence_on_attempt_and_completed_rung
    text3d = {
      requested_text_mode: :text3d, text_mode: :text3d,
      text_source_span_ids: ['text_span:1:0'],
      source_provenance_objects: [{
        object_id: 'text_delivery:1:0', page: 1, source_kind: 'text_span',
        span_id: 'text_span:1:0', created_entity_type: 'native_3d_text',
        resulting_entity_ids: ['persistent_id:101']
      }],
      text_attempts: [{
        source_span_id: 'text_span:1:0', requested_mode: :text3d,
        delivered_mode: :text3d, resulting_entity_ids: ['persistent_id:101'],
        visual_fidelity_verified: true,
        placement_verified: true, rotation_verified: true,
        width_verified: true, height_verified: true,
        entity_type_verified: true,
        attempt_history: [{
          mode: :text3d, outcome: :complete,
          resulting_entity_ids: ['persistent_id:101'], cleanup_outcome: :not_required,
          visual_fidelity_verified: true,
          placement_verified: true, rotation_verified: true,
          width_verified: true, height_verified: true,
          entity_type_verified: true
        }]
      }]
    }
    labels = Marshal.load(Marshal.dump(text3d))
    labels[:requested_text_mode] = :labels
    labels[:text_mode] = :labels
    labels[:source_provenance_objects][0][:created_entity_type] = 'native_label'
    labels[:text_attempts][0][:requested_mode] = :labels
    labels[:text_attempts][0][:delivered_mode] = :labels
    labels[:text_attempts][0][:content_verified] = true
    labels[:text_attempts][0][:leader_verified] = true
    labels[:text_attempts][0][:attempt_history][0][:mode] = :labels
    labels[:text_attempts][0][:attempt_history][0][:content_verified] = true
    labels[:text_attempts][0][:attempt_history][0][:leader_verified] = true

    assert_equal true, IMP::QAReport.send(:validate_representation_fidelity, text3d)[:ready]
    assert_equal true, IMP::QAReport.send(:validate_representation_fidelity, labels)[:ready]

    [text3d, labels].each do |valid|
      [:visual_fidelity_verified, :cleanup_outcome].each do |field|
        invalid = Marshal.load(Marshal.dump(valid))
        rung = invalid[:text_attempts][0][:attempt_history][0]
        if field == :visual_fidelity_verified
          rung[field] = false
        else
          rung[field] = :unknown
        end
        result = IMP::QAReport.send(:validate_representation_fidelity, invalid)
        assert_equal false, result[:ready],
                     "invalid terminal #{field} must fail closed"
      end
    end

    conflicting_keys = Marshal.load(Marshal.dump(text3d))
    conflicting_keys[:text_attempts][0][:placement_verified] = false
    conflicting_keys[:text_attempts][0]['placement_verified'] = true
    assert_equal false,
                 IMP::QAReport.send(
                   :validate_representation_fidelity, conflicting_keys
                 )[:ready],
                 'a string key must not override an explicit false symbol value'

    {
      text3d => [:placement_verified, :rotation_verified, :entity_type_verified,
                 :width_verified, :height_verified],
      labels => [:placement_verified, :rotation_verified, :entity_type_verified,
                 :content_verified, :leader_verified]
    }.each do |valid, required_fields|
      required_fields.each do |field|
        [:attempt, :rung].each do |location|
          missing = Marshal.load(Marshal.dump(valid))
          target = location == :attempt ? missing[:text_attempts][0] :
                   missing[:text_attempts][0][:attempt_history][0]
          target.delete(field)
          result = IMP::QAReport.send(:validate_representation_fidelity, missing)
          assert_equal false, result[:ready],
                       "missing #{field} on #{location} must fail closed"

          false_value = Marshal.load(Marshal.dump(valid))
          target = location == :attempt ? false_value[:text_attempts][0] :
                   false_value[:text_attempts][0][:attempt_history][0]
          target[field] = false
          result = IMP::QAReport.send(:validate_representation_fidelity, false_value)
          assert_equal false, result[:ready],
                       "false #{field} on #{location} must fail closed"
        end
      end
    end
  end

  def test_text_source_assignment_and_validation_fail_closed
    bad_item = Object.new
    assert_raises(IMP::TextSourceIdentity::IdentityError) do
      IMP::TextSourceIdentity.assign!([bad_item], 1)
    end

    first = item
    first.source_span_id = 'preexisting-source-id'
    assert_raises(IMP::TextSourceIdentity::IdentityError) do
      IMP::TextSourceIdentity.assign!([first, bad_item], 1)
    end
    assert_equal 'preexisting-source-id', first.source_span_id,
                 'identity assignment must not partially mutate a page ledger'

    good = item
    IMP::TextSourceIdentity.assign!([good], 2)
    assert IMP::TextSourceIdentity.validate!([good], 2)
    good.source_span_id = 'text_span:2:99'
    assert_raises(IMP::TextSourceIdentity::IdentityError) do
      IMP::TextSourceIdentity.validate!([good], 2)
    end
  end

  def test_generic_failures_abort_requested_mode_without_raster_promotion
    failures = [{
      source_span_id: 'text_span:1:0', requested: :labels,
      reason: 'label_native_api_unavailable', count: 1,
      attempt_history: [{ mode: :labels, outcome: :failed }]
    }]

    error = assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.enforce_requested_text_delivery!(1, :labels, failures)
    end
    assert_match(/requested Labels representation was not certified/, error.message)
    assert_match(/no representation fallback is authorized/, error.message)
    assert_match(/text_span:1:0/, error.message)

    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'), encoding: 'UTF-8'
    )
    refute_match(/promote_text_delivery_failures_to_raster!/, main)
    refute_match(/page_raster_required_by_peer_span/, main)
    refute_match(/if\s+opts\[:raster_fallback\]/, main)
    refute_match(/attempting raster fallback|No streams, trying raster|Rendering raster image/i,
                 main)
    refute_match(/next\s+unless\s+raw/, main)
    refute_match(/Continue to next page instead of aborting/, main)
    assert_match(/rescue\s+StandardError\s*=>\s*e.*?safe_abort_operation\(model,\s*'Pipeline'\).*?raise\s+e/m,
                 main)
  end

  def test_detected_svg_text_without_source_spans_stops_explicitly
    assert IMP.enforce_detected_svg_text_delivery!(
      1, :glyphs, { detected_svg_placements: 0 }, []
    )
    assert IMP.enforce_detected_svg_text_delivery!(
      1, :glyphs, { detected_svg_placements: 4 }, [item]
    )

    error = assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.enforce_detected_svg_text_delivery!(
        2, :geometry, { detected_svg_placements: 4 }, []
      )
    end
    assert_match(/Page 2/, error.message)
    assert_match(/Geometry/, error.message)
    assert_match(/source spans/i, error.message)
  end

  def test_content_text_show_operators_cannot_be_silently_omitted
    empty_detector = IMP::TextParser.new(
      ['BT () Tj [] TJ <> Tj ET'], {}, { strict_text_fidelity: true }
    )
    assert_equal 0, empty_detector.nonempty_text_show_operation_count
    inline_image_detector = IMP::TextParser.new(
      ["q BI /W 1 /H 1 ID bytes BT (NOT TEXT) Tj ET\nEI Q"], {},
      { strict_text_fidelity: true }
    )
    assert_equal 0, inline_image_detector.nonempty_text_show_operation_count,
                 'arbitrary inline-image bytes are not page text evidence'
    hidden_ocr_detector = IMP::TextParser.new(
      ['BT 3 Tr (SEARCHABLE OCR) Tj ET'], {},
      { strict_text_fidelity: true }
    )
    assert_equal 0, hidden_ocr_detector.nonempty_text_show_operation_count,
                 'non-painting OCR text must not block a valid raster-only page'
    clip_only_detector = IMP::TextParser.new(
      ['BT 7 Tr (CLIP ONLY) Tj ET'], {},
      { strict_text_fidelity: true }
    )
    assert_equal 0, clip_only_detector.nonempty_text_show_operation_count,
                 'clip-only text has no painted glyphs and is not visible text'

    detector = IMP::TextParser.new(
      ['BT (LABEL) Tj [(GLYPH)] TJ <4142> Tj ET'], {},
      { strict_text_fidelity: true }
    )
    assert_equal 3, detector.nonempty_text_show_operation_count

    assert IMP.enforce_extracted_text_presence!(
      1, :labels, [], ['q 0 0 m 10 10 l S Q'], []
    )
    assert IMP.enforce_extracted_text_presence!(
      1, :text3d, [item], ['BT (LABEL) Tj ET'], []
    )

    error = assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.enforce_extracted_text_presence!(
        2, :text3d, [], ['q Q'], ['BT (XOBJECT TEXT) Tj ET']
      )
    end
    assert_match(/Page 2/, error.message)
    assert_match(/3D Text/, error.message)
    assert_match(/text-show operation/i, error.message)
  end

  def test_runtime_ladders_are_finite_closest_to_farthest_and_end_in_real_raster
    expected = {
      text: [:text, :labels, :text3d, :glyphs, :geometry, :raster],
      labels: [:labels, :text3d, :glyphs, :geometry, :raster],
      text3d: [:text3d, :glyphs, :geometry, :raster],
      glyphs: [:glyphs, :geometry, :raster],
      geometry: [:geometry, :raster],
      raster: [:raster]
    }
    expected.each do |mode, ladder|
      assert_equal ladder, IMP::RepresentationFidelity.ladder_for(mode)
      assert_equal ladder.uniq, ladder, "#{mode} ladder must never cycle"
      assert_equal :raster, ladder.last
    end

    builder_source = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb'),
      encoding: 'UTF-8'
    )
    refute_match(/fallback_mesh_text_to_label/, builder_source)
    refute_match(/falling back to 3D text/, builder_source)
    refute_match(/allow_mesh_fallback/, builder_source)
  end

  def test_requested_page_selection_is_bounded_ordered_and_duplicate_free
    assert_equal [1, 2, 3], IMP.normalized_requested_pages(:all, 3)
    assert_equal [3, 1, 2], IMP.normalized_requested_pages([3, 1, 3, 0, 9, 2], 3)
    assert_equal [], IMP.normalized_requested_pages(nil, 3)
    assert_equal [], IMP.normalized_requested_pages(:all, 0)
  end

  def test_force_raster_path_uses_selected_pages_verified_artifacts_and_rotation
    main = File.read(File.join(
      SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'
    ))
    body = main[/def self\.run_forced_raster_pipeline.*?^    end$/m]
    refute_nil body
    assert_match(/normalized_requested_pages\(opts\[:pages\], parser\.page_count\)/,
                 body)
    assert_match(/pages\.each_with_index/, body)
    assert_match(/verified_raster_entity!/, body)
    assert_match(/page_rotation/, body)
    assert_match(/artifact_evidence/, body)
    assert_match(/delivery_basis\s*=>\s*:explicit_full_page_raster/, body)
    assert_match(/semantic_text_evaluated\s*=>\s*false/, body)
    refute_match(/no_semantic_text\s*=>\s*true/, body)
    refute_match(/page_num\s*=\s*1|pages\.first/, body)
  end

  def test_item_raster_crop_is_bound_to_source_bbox_and_display_rotation
    item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
      'AB', 100, 200, 12, 0, 'F1', 12,
      100, 200, 160, 220, nil, 'text_span:1:0'
    )
    crop = IMP.item_raster_crop_geometry(
      item, [0, 0, 792, 612], 90, 144, 1.5
    )
    assert_equal 90, crop[:page_rotation]
    assert_equal [397, 197, 46, 126], crop[:pixel_crop]
    assert_in_delta 198.5, crop[:display_box][0], 1.0e-9
    assert_in_delta 630.5, crop[:display_box][1], 1.0e-9
    assert_in_delta 23.0, crop[:display_width], 1.0e-9
    assert_in_delta 63.0, crop[:display_height], 1.0e-9
  end

  def test_item_vector_fallback_uses_a_real_distinct_renderer
    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'), encoding: 'UTF-8'
    )
    renderer = File.read(File.join(
      SRC_ROOT, 'bc_pdf_vector_importer',
      'svg_item_representation_renderer.rb'
    ), encoding: 'UTF-8')

    assert_match(/SvgItemRepresentationRenderer\.render_svg/, main)
    refute_match(/stop_unimplemented_item_fallback!/, main)
    assert_match(/build_glyph_groups!/, renderer)
    assert_match(/build_flat_geometry!/, renderer)
  end

  def test_exact_svg_representations_cannot_be_disabled_by_page_group_preference
    fidelity = IMP::RepresentationFidelity

    geometry = fidelity.owned_page_group_policy(false, :svg_text)
    text3d = fidelity.owned_page_group_policy(false, :svg_3d_text)
    ordinary = fidelity.owned_page_group_policy(false, nil)

    assert_equal true, geometry[:effective_group_per_page]
    assert_equal true, geometry[:forced]
    assert_equal :representation_entity_ownership_required,
                 geometry[:reason_code]
    assert_equal true, text3d[:effective_group_per_page]
    assert_equal true, text3d[:forced]
    assert_equal false, ordinary[:effective_group_per_page]
    assert_equal false, ordinary[:forced]
  end

  def test_page_renderer_font_diagnostics_are_not_recast_as_item_absence
    context = IMP.svg_source_context(
      {
        svg: '<svg/>', renderer: :pdftocairo,
        missing_fonts: ['MissingEmbeddedFont'],
        missing_language_packs: []
      },
      3,
      {}
    )

    assert_equal IMP::RepresentationFidelity::IMPORTER_ID,
                 context[:importer_id]
    assert_equal 3, context[:page_number]
    assert_equal :complete, context[:render_status]
    assert_equal :failed, context[:font_inventory_status]
    assert_equal :font_inventory_runtime_error,
                 context[:page_failures][0][:reason_code]
  end

  def test_terminal_raster_must_be_a_new_owned_nonempty_image
    entities = FidelityEntities.new
    model = Struct.new(:active_entities).new(entities)
    pdf_path = File.join(Dir.tmpdir, "bc_terminal_raster_#{Process.pid}.pdf")
    File.binwrite(pdf_path, "%PDF-1.4\n%%EOF\n")
    source_sha = Digest::SHA256.file(pdf_path).hexdigest
    renderer = lambda do |*_args|
      image = entities.add_test_entity(2.0, 3.0, 'Image')
      {
        entity: image,
        artifact_evidence: {
          png_signature_verified: true, page_binding_verified: true,
          box_binding_verified: true, aspect_verified: true,
          page_number: 1, page_rotation: 0,
          source_pdf_path: File.expand_path(pdf_path),
          source_pdf_sha256: source_sha,
          source_pdf_binding_verified: true
        }
      }
    end

    proof = IMP.stub(:import_page_as_raster, renderer) do
      IMP.verified_raster_entity!(
        model, pdf_path, 1, [0, 0, 144, 216], {}, Time.now,
        0.0, [0, 0, 144, 216]
      )
    end

    assert_equal 'persistent_id:101', proof[:entity_id]
    assert_equal ['persistent_id:101'], proof[:created_entity_ids]
    assert_equal true, proof[:real_raster_verified]
    assert_equal true, proof[:visual_fidelity_verified]
    assert_in_delta 2.0, proof[:bounds][:width], 1e-12
    assert_in_delta 3.0, proof[:bounds][:height], 1e-12
  ensure
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  def write_png_header(path, width, height, signature = true)
    bytes = signature ? "\x89PNG\r\n\x1a\n".b : 'NOTAPNG!'.b
    bytes << [13].pack('N') << 'IHDR' << [width, height].pack('N2')
    bytes << "\x08\x06\x00\x00\x00".b
    File.open(path, 'wb') { |file| file.write(bytes) }
  end

  def png_chunk(type, data)
    payload = type.to_s.b + data.to_s.b
    [data.bytesize].pack('N') + payload + [Zlib.crc32(payload)].pack('N')
  end

  def write_rgba_png(path, width, height, pixels)
    rows = (0...height).map do |y|
      "\x00".b + pixels.slice(y * width, width).flatten.pack('C*')
    end.join
    bytes = "\x89PNG\r\n\x1a\n".b
    bytes << png_chunk('IHDR', [width, height, 8, 6, 0, 0, 0].pack('N2C5'))
    bytes << png_chunk('IDAT', Zlib::Deflate.deflate(rows))
    bytes << png_chunk('IEND', ''.b)
    File.open(path, 'wb') { |file| file.write(bytes) }
  end

  def test_rgba_page_crop_preserves_visible_pixels_and_transparent_background
    page = File.join(Dir.tmpdir, "bc_rgba_page_#{Process.pid}.png")
    crop = File.join(Dir.tmpdir, "bc_rgba_crop_#{Process.pid}.png")
    raw = File.join(Dir.tmpdir, "bc_rgba_page_#{Process.pid}.rgba")
    crop_raw = File.join(Dir.tmpdir, "bc_rgba_crop_#{Process.pid}.rgba")
    transparent = [255, 255, 255, 0]
    pixels = Array.new(12) { transparent.dup }
    pixels[5] = [10, 20, 30, 255]
    write_rgba_png(page, 4, 3, pixels)

    prepared = IMP::PngCropper.prepare_rgba!(page, raw)
    proof = IMP::PngCropper.crop_rgba!(
      prepared, [1, 1, 2, 1], crop
    )
    cropped = IMP::PngCropper.prepare_rgba!(crop, crop_raw)

    assert_equal [2, 1], [proof[:pixel_width], proof[:pixel_height]]
    assert_equal true, proof[:alpha_channel_verified]
    assert_equal true, proof[:transparent_background_verified]
    assert_equal true, proof[:visible_pixel_verified]
    assert_equal [2, 1], [cropped[:pixel_width], cropped[:pixel_height]]
    assert_equal true, cropped[:transparent_pixel_present]
  ensure
    [page, crop, raw, crop_raw].each do |path|
      File.delete(path) if path && File.exist?(path)
    end
  end

  def test_rgba_item_crop_rejects_fully_transparent_delivery
    page = File.join(Dir.tmpdir, "bc_rgba_empty_#{Process.pid}.png")
    crop = File.join(Dir.tmpdir, "bc_rgba_empty_crop_#{Process.pid}.png")
    raw = File.join(Dir.tmpdir, "bc_rgba_empty_#{Process.pid}.rgba")
    write_rgba_png(page, 2, 2, Array.new(4) { [255, 255, 255, 0] })
    prepared = IMP::PngCropper.prepare_rgba!(page, raw)

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP::PngCropper.crop_rgba!(prepared, [0, 0, 2, 2], crop)
    end
    refute File.exist?(crop)
  ensure
    [page, crop, raw].each do |path|
      File.delete(path) if path && File.exist?(path)
    end
  end

  def test_rgba_item_crop_accepts_visible_fully_opaque_source_ink
    page = File.join(Dir.tmpdir, "bc_rgba_opaque_#{Process.pid}.png")
    crop = File.join(Dir.tmpdir, "bc_rgba_opaque_crop_#{Process.pid}.png")
    raw = File.join(Dir.tmpdir, "bc_rgba_opaque_#{Process.pid}.rgba")
    crop_raw = File.join(Dir.tmpdir, "bc_rgba_opaque_crop_#{Process.pid}.rgba")
    write_rgba_png(page, 2, 2, Array.new(4) { [10, 20, 30, 255] })
    prepared = IMP::PngCropper.prepare_rgba!(page, raw)

    proof = IMP::PngCropper.crop_rgba!(prepared, [0, 0, 2, 2], crop)
    cropped = IMP::PngCropper.prepare_rgba!(crop, crop_raw)

    assert_equal true, proof[:alpha_channel_verified]
    assert_equal true, proof[:transparent_background_verified]
    assert_equal false, proof[:transparent_pixel_present]
    assert_equal true, proof[:visible_pixel_verified]
    assert_equal false, cropped[:transparent_pixel_present]
    assert_equal true, cropped[:visible_pixel_present]
  ensure
    [page, crop, raw, crop_raw].each do |path|
      File.delete(path) if path && File.exist?(path)
    end
  end

  def test_item_raster_page_cache_fetches_each_exact_page_key_once
    opts = {}
    calls = 0
    first = IMP.fetch_item_raster_page_cache!(opts, 'source:1:400') do
      calls += 1
      { :sentinel => Object.new }
    end
    second = IMP.fetch_item_raster_page_cache!(opts, 'source:1:400') do
      calls += 1
      { :sentinel => Object.new }
    end

    assert_same first, second
    assert_equal 1, calls
  end

  def test_every_text_import_initializes_one_persistent_page_raster_cache
    [:text, :labels, :text3d, :glyphs, :geometry, :raster].each do |_mode|
      opts = {}
      IMP.initialize_item_raster_import_cache!(opts, true)

      assert_kind_of Hash, opts[:item_raster_page_cache]
      assert_kind_of Hash, opts[:source_pdf_digest_cache]
      assert_equal true, opts[:item_raster_cache_persistent]
    end

    disabled = {}
    IMP.initialize_item_raster_import_cache!(disabled, false)
    refute disabled.key?(:item_raster_page_cache)
    refute disabled.key?(:source_pdf_digest_cache)
    refute disabled.key?(:item_raster_cache_persistent)

    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'),
      :encoding => 'UTF-8'
    )
    assert_includes main,
                    'initialize_item_raster_import_cache!(opts, opts[:import_text])'
  end

  def test_item_raster_uses_explicit_import_scope_not_mutable_cache_presence
    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'),
      :encoding => 'UTF-8'
    )
    body = main[/def self\.import_item_as_raster\b.*?(?=^    def self\.)/m]

    refute_nil body
    assert_includes body, 'opts[:item_raster_cache_persistent] != true'
    refute_includes body, '!opts[:item_raster_page_cache].is_a?(Hash)'
  end

  def test_item_raster_source_digest_freezes_and_rejects_source_rebinding
    pdf = File.join(Dir.tmpdir, "bc_digest_cache_#{Process.pid}.pdf")
    File.binwrite(pdf, "%PDF-1.4\nsource-a\n%%EOF\n")
    calls = 0
    original = Digest::SHA256.method(:file)
    Digest::SHA256.define_singleton_method(:file) do |path|
      calls += 1
      original.call(path)
    end
    opts = {}

    first = IMP.cached_source_pdf_sha256!(opts, pdf)
    second = IMP.cached_source_pdf_sha256!(opts, pdf)
    assert_equal first, second
    assert_equal 1, calls

    original_time = File.mtime(pdf)
    File.binwrite(pdf, "%PDF-1.4\nsource-b\n%%EOF\n")
    File.utime(original_time, original_time, pdf)
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_cached_source_pdf_bindings!(opts)
    end
  ensure
    Digest::SHA256.define_singleton_method(:file, original) if original
    File.delete(pdf) if pdf && File.exist?(pdf)
  end

  def test_render_binding_rejects_source_mutation_during_command_window
    pdf = File.join(Dir.tmpdir, "bc_render_binding_#{Process.pid}.pdf")
    File.binwrite(pdf, "%PDF-1.4\nsource-a\n%%EOF\n")
    opts = {}
    binding = IMP.begin_source_pdf_render_binding!(opts, pdf)
    original_time = File.mtime(pdf)

    File.binwrite(pdf, "%PDF-1.4\nsource-b\n%%EOF\n")
    File.utime(original_time, original_time, pdf)

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_source_pdf_render_binding!(binding)
    end
  ensure
    File.delete(pdf) if pdf && File.exist?(pdf)
  end

  def test_full_page_raster_production_binding_decodes_visual_pixels
    png = File.join(Dir.tmpdir, "bc_raster_pixels_#{Process.pid}.png")
    pdf = File.join(Dir.tmpdir, "bc_raster_pixels_#{Process.pid}.pdf")
    pixels = [[255, 0, 0, 255], [0, 255, 0, 255]]
    write_rgba_png(png, 2, 1, pixels)
    File.binwrite(pdf, "%PDF-1.4\nsource\n%%EOF\n")
    opts = {}
    binding = IMP.begin_source_pdf_render_binding!(opts, pdf)
    IMP.verify_source_pdf_render_binding!(binding)
    arguments = [
      'pdftocairo', '-png', '-singlefile', '-r', '300',
      '-f', '1', '-l', '1', pdf, png.sub(/\.png\z/, '')
    ]

    proof = IMP.verify_raster_artifact!(
      png, 1, [0, 0, 2, 1], [0, 0, 2, 1], 0, arguments,
      pdf, binding
    )

    assert_equal Digest::SHA256.hexdigest(pixels.flatten.pack('C*')),
                 proof[:visual_pixel_sha256]
    assert_equal true, proof[:visual_pixel_binding_verified]
  ensure
    File.delete(png) if png && File.exist?(png)
    File.delete(pdf) if pdf && File.exist?(pdf)
  end

  def test_owned_temp_cleanup_failure_is_authoritative
    directory = Dir.mktmpdir('bc_cleanup_failure_')
    original = FileUtils.method(:remove_entry)
    FileUtils.define_singleton_method(:remove_entry) do |path, *args|
      if File.expand_path(path.to_s) == File.expand_path(directory)
        raise IOError, 'forced cleanup refusal'
      end
      original.call(path, *args)
    end

    error = assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.cleanup_owned_temp_artifacts!([], [directory])
    end
    assert_match(/cleanup failed|forced cleanup refusal/i, error.message)
    assert File.directory?(directory)
  ensure
    FileUtils.define_singleton_method(:remove_entry, original) if original
    FileUtils.remove_entry(directory) if directory && File.directory?(directory)
  end

  def test_every_import_commit_cleans_raster_cache_and_rebinds_source_first
    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'),
      :encoding => 'UTF-8'
    )
    guarded_commits = main.scan(
      /cleanup_item_raster_page_cache!\(opts\)\s+
       verify_cached_source_pdf_bindings!\(opts\)\s+
       model\.commit_operation/x
    )

    assert_equal 2, guarded_commits.length,
                 'both import transactions must clean/rebind before commit'
  end

  def test_raster_artifact_verifier_binds_png_page_box_aspect_and_rotation
    path = File.join(Dir.tmpdir, "bc_raster_contract_#{Process.pid}.png")
    pdf_path = File.join(Dir.tmpdir, "bc_raster_contract_#{Process.pid}.pdf")
    other_pdf = File.join(Dir.tmpdir, "bc_raster_contract_other_#{Process.pid}.pdf")
    File.binwrite(pdf_path, "%PDF-1.4\nsource-a\n%%EOF\n")
    File.binwrite(other_pdf, "%PDF-1.4\nsource-b\n%%EOF\n")
    write_png_header(path, 612, 792)
    args = [
      'pdftocairo', '-png', '-singlefile', '-r', '300',
      '-f', '1', '-l', '1', pdf_path, path.sub(/\.png\z/, '')
    ]

    proof = IMP.verify_raster_artifact!(
      path, 1, [0, 0, 792, 612], [0, 0, 792, 612], 90, args,
      pdf_path
    )

    assert_equal 612, proof[:pixel_width]
    assert_equal 792, proof[:pixel_height]
    assert_equal 1, proof[:page_number]
    assert_equal :media_box, proof[:render_box_used]
    assert_equal 90, proof[:page_rotation]
    assert_equal true, proof[:png_signature_verified]
    assert_equal true, proof[:page_binding_verified]
    assert_equal true, proof[:box_binding_verified]
    assert_equal true, proof[:aspect_verified]
    assert_equal Digest::SHA256.file(pdf_path).hexdigest,
                 proof[:source_pdf_sha256]
    assert_equal File.expand_path(pdf_path), proof[:source_pdf_path]

    wrong_source_args = args.dup
    wrong_source_args[-2] = other_pdf
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_raster_artifact!(
        path, 1, [0, 0, 792, 612], [0, 0, 792, 612], 90,
        wrong_source_args, pdf_path
      )
    end

    bad_page = args.dup
    bad_page[bad_page.index('-f') + 1] = '2'
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_raster_artifact!(
        path, 1, [0, 0, 792, 612], [0, 0, 792, 612], 90, bad_page
      )
    end

    write_png_header(path, 792, 612)
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_raster_artifact!(
        path, 1, [0, 0, 792, 612], [0, 0, 792, 612], 90, args
      )
    end
  ensure
    File.delete(path) if path && File.exist?(path)
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
    File.delete(other_pdf) if other_pdf && File.exist?(other_pdf)
  end

  def test_raster_artifact_verifier_rejects_non_png_and_wrong_box_binding
    path = File.join(Dir.tmpdir, "bc_raster_contract_bad_#{Process.pid}.png")
    args = [
      'pdftocairo', '-png', '-singlefile', '-r', '300', '-cropbox',
      '-f', '1', '-l', '1', 'fixture.pdf', path.sub(/\.png\z/, '')
    ]
    write_png_header(path, 100, 200, false)
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_raster_artifact!(
        path, 1, [0, 0, 200, 100], [10, 10, 110, 60], 90, args
      )
    end

    write_png_header(path, 50, 100)
    no_crop = args.reject { |value| value == '-cropbox' }
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_raster_artifact!(
        path, 1, [0, 0, 200, 100], [10, 10, 110, 60], 90, no_crop
      )
    end
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_item_raster_artifact_verifier_binds_source_crop_and_page
    path = File.join(Dir.tmpdir, "bc_item_raster_#{Process.pid}.png")
    pdf_path = File.join(Dir.tmpdir, "bc_item_raster_#{Process.pid}.pdf")
    File.binwrite(pdf_path, "%PDF-1.4\n%%EOF\n")
    item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
      'AB', 100, 200, 12, 0, 'F1', 12,
      100, 200, 160, 220, nil, 'text_span:1:0'
    )
    crop = IMP.item_raster_crop_geometry(
      item, [0, 0, 792, 612], 90, 144, 1.5
    )
    pixels = Array.new(46 * 126) { [255, 255, 255, 0] }
    pixels[47] = [0, 0, 0, 255]
    write_rgba_png(path, 46, 126, pixels)
    args = [
      'pdftocairo', '-png', '-transp', '-singlefile', '-r', '144',
      '-f', '1', '-l', '1', pdf_path, path.sub(/\.png\z/, '')
    ]
    crop_proof = {
      :alpha_channel_verified => true,
      :transparent_background_verified => true,
      :visible_pixel_verified => true,
      :page_render_once_verified => true,
      :page_render_content_sha256 => 'c' * 64,
      :visual_pixel_sha256 => 'd' * 64
    }
    proof = IMP.verify_item_raster_artifact!(
      path, item, 1, crop, args, pdf_path, crop_proof,
      Digest::SHA256.file(pdf_path).hexdigest
    )
    assert_equal 'text_span:1:0', proof[:source_span_id]
    assert_equal true, proof[:source_crop_binding_verified]
    assert_equal true, proof[:page_binding_verified]
    assert_equal [397, 197, 46, 126], proof[:pixel_crop]
    assert_equal true, proof[:alpha_channel_verified]
    assert_equal true, proof[:transparent_background_verified]
    assert_equal true, proof[:page_render_once_verified]
    assert_equal 'd' * 64, proof[:visual_pixel_sha256]
    assert_equal true, proof[:visual_pixel_binding_verified]

    bad = args.dup
    bad.delete('-transp')
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_item_raster_artifact!(
        path, item, 1, crop, bad, pdf_path, crop_proof,
        Digest::SHA256.file(pdf_path).hexdigest
      )
    end
    invisible = crop_proof.merge(:visible_pixel_verified => false)
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.verify_item_raster_artifact!(
        path, item, 1, crop, args, pdf_path, invisible,
        Digest::SHA256.file(pdf_path).hexdigest
      )
    end
  ensure
    File.delete(path) if path && File.exist?(path)
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  def test_item_raster_renderer_persists_source_claim_representation_identity
    main = File.read(
      File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'),
      encoding: 'UTF-8'
    )
    body = main[/def self\.import_item_as_raster\b.*?(?=^    def self\.)/m]

    refute_nil body
    assert_includes body, "'source_claim_root', true"
    assert_includes body, "'source_kind', 'text_span'"
    assert_includes body, "'representation', 'raster'"
    assert_includes body,
                    "'renderer', 'pdftocairo_transparent_page_crop'"
    assert_includes body, "'raster_alpha_verified'"
    assert_includes body, "'raster_transparent_background_verified'"
    assert_includes body, "'raster_visible_pixel_verified'"
    assert_includes body, "'raster_page_render_once_verified'"
  end

  def test_active_docs_lock_page_raster_evidence_and_item_cache_contract
    readme = File.read(File.join(REPO_ROOT, 'README.md'), :encoding => 'UTF-8')
    host = File.read(
      File.join(REPO_ROOT, 'HOST_COMPATIBILITY.md'), :encoding => 'UTF-8'
    )
    agents = File.read(File.join(REPO_ROOT, 'AGENTS.md'), :encoding => 'UTF-8')

    [readme, host, agents].each do |document|
      assert_includes document, 'Explicit full-page Raster'
      assert_includes document, 'semantic text not evaluated'
      assert_includes document, 'verified zero-canonical-text proof'
      assert_match(/(?:transparent.*RGBA|RGBA.*transparent)/m, document)
      assert_includes document, 'alpha < 255'
      assert_match(/(?:reference.*digest|digest.*reference)/m, document)
    end
    assert_includes agents, 'TextureWriter'
    assert_includes host, 'TextureWriter'
    assert_includes readme, 'actual SketchUp texture'
  end

  def test_terminal_item_raster_must_be_new_owned_and_source_bound
    entities = FidelityEntities.new
    model = Struct.new(:active_entities).new(entities)
    item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
      'AB', 10, 20, 12, 0, 'F1', 12,
      9, 19, 20, 30, nil, 'text_span:1:0'
    )
    pdf_path = File.join(Dir.tmpdir, "bc_owned_item_raster_#{Process.pid}.pdf")
    File.binwrite(pdf_path, "%PDF-1.4\n%%EOF\n")
    pdf_sha256 = Digest::SHA256.file(pdf_path).hexdigest
    renderer = lambda do |*_args|
      image = entities.add_test_entity(1.0, 0.5, 'Image')
      {
        entity: image,
        artifact_evidence: {
          source_span_id: 'text_span:1:0', page_number: 1,
          source_pdf_path: pdf_path, source_pdf_sha256: pdf_sha256,
          source_pdf_binding_verified: true,
          page_rotation: 0, png_signature_verified: true,
          page_binding_verified: true, source_crop_binding_verified: true,
          aspect_verified: true, alpha_channel_verified: true,
          transparent_background_verified: true,
          visible_pixel_verified: true, page_render_once_verified: true,
          page_render_content_sha256: 'c' * 64
        }
      }
    end
    proof = IMP.stub(:import_item_as_raster, renderer) do
      IMP.verified_item_raster_entity!(
        model, entities, pdf_path, 1, item, [0, 0, 100, 100],
        {}, Time.now, 0.0, 0
      )
    end
    assert_equal 'persistent_id:101', proof[:entity_id]
    assert_equal 'text_span:1:0', proof[:artifact_evidence][:source_span_id]
    assert_equal true, proof[:real_raster_verified]
  ensure
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  def test_failed_terminal_raster_probe_does_not_claim_an_unreturned_peer
    entities = FidelityEntities.new
    model = Struct.new(:active_entities).new(entities)
    renderer = lambda do |*_args|
      entities.add_test_entity(2.0, 3.0, 'Edge')
    end

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.stub(:import_page_as_raster, renderer) do
        IMP.verified_raster_entity!(
          model, 'fixture.pdf', 1, [0, 0, 144, 216], {}, Time.now,
          0.0, [0, 0, 144, 216]
        )
      end
    end

    assert_equal [101], entities.to_a.map(&:persistent_id)
    assert_empty entities.erased
  end

  def test_terminal_page_raster_rejects_peer_but_cleans_only_returned_image
    entities = FidelityEntities.new
    model = Struct.new(:active_entities).new(entities)
    renderer = lambda do |*_args|
      entities.add_test_entity(0.5, 0.5, 'Edge')
      image = entities.add_test_entity(2.0, 3.0, 'Image')
      {
        entity: image,
        artifact_evidence: {
          png_signature_verified: true, page_binding_verified: true,
          box_binding_verified: true, aspect_verified: true,
          page_number: 1, page_rotation: 0
        }
      }
    end

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.stub(:import_page_as_raster, renderer) do
        IMP.verified_raster_entity!(
          model, 'fixture.pdf', 1, [0, 0, 144, 216], {}, Time.now,
          0.0, [0, 0, 144, 216]
        )
      end
    end
    assert_equal [101], entities.to_a.map(&:persistent_id)
    assert_equal [102], entities.erased.map(&:persistent_id)
  end

  def test_terminal_item_raster_failure_cleans_only_explicit_owned_claim
    entities = FidelityEntities.new
    model = Struct.new(:active_entities).new(entities)
    renderer = lambda do |*_args|
      peer = entities.add_test_entity(0.5, 0.5, 'Edge')
      image = entities.add_test_entity(2.0, 3.0, 'Image')
      {
        failure: true,
        error: 'synthetic post-image failure',
        owned_entities: [image],
        peer: peer
      }
    end

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.stub(:import_item_as_raster, renderer) do
        IMP.verified_item_raster_entity!(
          model, entities, 'fixture.pdf', 1, item, [0, 0, 144, 216],
          {}, Time.now, 0.0, 0
        )
      end
    end

    assert_equal [101], entities.to_a.map(&:persistent_id)
    assert_equal [102], entities.erased.map(&:persistent_id)
  end

  def test_terminal_raster_does_not_claim_unreturned_unverified_image
    entities = FidelityEntities.new
    model = Struct.new(:active_entities).new(entities)
    renderer = lambda do |*_args|
      entities.add_test_entity(2.0, 3.0, 'Image')
    end

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.stub(:import_page_as_raster, renderer) do
        IMP.verified_raster_entity!(
          model, 'fixture.pdf', 1, [0, 0, 144, 216], {}, Time.now,
          0.0, [0, 0, 144, 216]
        )
      end
    end
    assert_equal [101], entities.to_a.map(&:persistent_id)
    assert_empty entities.erased,
                 'an unreturned host artifact is not an importer ownership claim'
  end

  def test_terminal_item_raster_rejects_peer_but_cleans_only_returned_image
    entities = FidelityEntities.new
    model = Struct.new(:active_entities).new(entities)
    source = item('A', 0, 12, 8, 'text_span:1:0')
    renderer = lambda do |*_args|
      entities.add_test_entity(0.5, 0.5, 'Edge')
      image = entities.add_test_entity(1.0, 0.5, 'Image')
      {
        entity: image,
        artifact_evidence: {
          source_span_id: 'text_span:1:0', page_number: 1,
          page_rotation: 0, png_signature_verified: true,
          page_binding_verified: true, source_crop_binding_verified: true,
          aspect_verified: true
        }
      }
    end

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      IMP.stub(:import_item_as_raster, renderer) do
        IMP.verified_item_raster_entity!(
          model, entities, 'fixture.pdf', 1, source, [0, 0, 100, 100],
          {}, Time.now, 0.0, 0
        )
      end
    end
    assert_equal [101], entities.to_a.map(&:persistent_id)
    assert_equal [102], entities.erased.map(&:persistent_id)
  end

  def valid_transition_proof(from_mode, to_mode, source_id = 'text_span:1:0')
    {
      source_span_id: source_id,
      importer_id: IMP::RepresentationFidelity::IMPORTER_ID,
      page_number: source_id.split(':')[1].to_i,
      scope: :item,
      category: :exact_representation_impossible,
      affirmative_impossibility: true,
      generic_failure: false,
      from_mode: from_mode,
      to_mode: to_mode,
      reason_code: :verified_source_representation_impossible,
      attempted_renderer: 'source_outline_renderer',
      created_entity_ids: [],
      cleaned_entity_ids: [],
      cleanup_outcome: :not_required,
      evidence: {
        source_observation: 'the item has no closable source outline for this representation',
        verification: 'source span checked independently'
      }
    }
  end

  def test_fallback_controller_advances_only_one_adjacent_rung_and_terminates
    controller = IMP::RepresentationFidelity::FallbackController.new(
      :text3d, 'text_span:1:0'
    )

    assert_equal :text3d, controller.current_mode
    assert_equal :glyphs,
      controller.advance!(valid_transition_proof(:text3d, :glyphs))
    assert_equal :geometry,
      controller.advance!(valid_transition_proof(:glyphs, :geometry))
    assert_equal :raster,
      controller.advance!(valid_transition_proof(:geometry, :raster))
    assert controller.terminal?
    assert_equal 3, controller.transitions.length

    assert_raises(IMP::RepresentationFidelity::ContractError) do
      controller.advance!(valid_transition_proof(:raster, :raster))
    end
  end

  def test_text3d_item_fallback_delivers_distinct_item_geometry_before_raster
    entities = FidelityEntities.new
    preexisting = entities.add_test_entity(4.0, 4.0, 'Group')
    model = Struct.new(:active_entities).new(entities)
    item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
      'AB', 10, 20, 12, 0, 'F1', 12,
      9, 19, 20, 30, nil, 'text_span:1:0'
    )
    svg = <<-SVG
      <svg viewBox="0 0 100 100" xmlns:xlink="http://www.w3.org/1999/xlink">
        <defs><path id="glyph-0-1" d="M0 0 L1 0 L1 1 Z"/></defs>
        <use xlink:href="#glyph-0-1" transform="matrix(1,0,0,1,10,80)"/>
      </svg>
    SVG
    document = {
      svg: svg, renderer: :pdftocairo, render_box_used: :media_box,
      missing_fonts: [], missing_language_packs: []
    }
    stats = {
      requested_text_mode: :text3d, text_mode: :text3d,
      text_source_span_ids: ['text_span:1:0'],
      fallback_transitions: [], terminal_text_delivery_records: [],
      text_attempts: [], text_renderers: [], page_text_sources: {},
      source_provenance_objects: [], raster_delivery_records: [],
      raster_fallback_used: false, text: 0, edges: 0
    }
    raster_called = false
    raster = lambda do |_model, *_args|
      raster_called = true
      raise 'Raster must not run after verified Geometry delivery'
    end
    modes = []
    vector = lambda do |_entities, _svg, _media_box, _item, mode, _opts|
      modes << mode
      if mode == :glyphs
        {
          ok: false,
          transition_proof: valid_transition_proof(:glyphs, :geometry)
        }
      else
        group = entities.add_test_entity(1.0, 0.5, 'Group')
        {
          ok: true, mode: :geometry, renderer: :svg_item_flat_geometry,
          source_span_id: 'text_span:1:0', group: group,
          group_entity_id: IMP::RepresentationFidelity.stable_entity_id(group),
          created_entity_ids: [IMP::RepresentationFidelity.stable_entity_id(group)],
          physical_entity_ids: ['persistent_id:900'], placement_indices: [0],
          glyph_ids: ['glyph-0-1'], edge_count: 4, glyph_group_count: 0,
          identity_verified: true, placement_verified: true,
          rotation_verified: true, size_verified: true,
          entity_type_verified: true, visibility_verified: true,
          visual_fidelity_verified: true
        }
      end
    end
    IMP::SvgItemRepresentationRenderer.stub(:render_svg, vector) do
      IMP::SvgItemRepresentationRenderer.stub(
        :verify_transformed_delivery!, true
      ) do
        IMP.stub(:apply_and_verify_page_representation_transform, true) do
          IMP.stub(:verified_item_raster_entity!, raster) do
            IMP.complete_text3d_item_fallbacks!(
              stats, model, entities, 'fixture.pdf', 1, [item],
              [0, 0, 100, 100], [0, 0, 100, 100], 0, {}, Time.now,
              0.0, document, [valid_transition_proof(:text3d, :glyphs)]
            )
          end
        end
      end
    end
    assert_equal [:glyphs, :geometry], modes
    refute raster_called
    assert_includes entities.to_a, preexisting
    assert_empty entities.erased
    assert_equal 2, stats[:fallback_transitions].length
    attempt = stats[:text_attempts].first
    assert_equal :text3d, attempt[:requested_mode]
    assert_equal :geometry, attempt[:delivered_mode]
    assert_equal true, attempt[:identity_verified]
    assert_equal [:text3d, :glyphs, :geometry],
                 attempt[:attempt_history].map { |rung| rung[:mode] }
    assert_equal [:failed, :failed, :complete],
                 attempt[:attempt_history].map { |rung| rung[:outcome] }
    assert_equal 'page_path_geometry',
                 stats[:source_provenance_objects].first[:created_entity_type]
    assert_empty stats[:terminal_text_delivery_records]
    assert_equal true, IMP::QAReport.send(
      :validate_representation_fidelity, stats
    )[:ready]
  end

  def test_text3d_item_ladder_reaches_verified_terminal_item_raster
    entities = FidelityEntities.new
    preexisting = entities.add_test_entity(4.0, 4.0, 'Group')
    model = Struct.new(:active_entities).new(entities)
    source = item('A', 0, 12, 8, 'text_span:1:0')
    document = {
      svg: '<svg viewBox="0 0 100 100"></svg>',
      renderer: :pdftocairo, missing_fonts: [], missing_language_packs: []
    }
    stats = {
      requested_text_mode: :text3d, text_mode: :text3d,
      text_source_span_ids: ['text_span:1:0'],
      fallback_transitions: [], terminal_text_delivery_records: [],
      text_attempts: [], text_renderers: [], page_text_sources: {},
      source_provenance_objects: [], raster_delivery_records: [],
      raster_fallback_used: false, text: 0, edges: 0,
      normalized_input_sha256: 'a' * 64
    }
    modes = []
    vector = lambda do |_entities, _svg, _media_box, _item, mode, _opts|
      modes << mode
      next_mode = mode == :glyphs ? :geometry : :raster
      {
        ok: false,
        transition_proof: valid_transition_proof(mode, next_mode)
      }
    end
    raster = lambda do |_model, target, *_args|
      image = target.add_test_entity(1.0, 0.5, 'Image')
      {
        entity: image,
        entity_id: IMP::RepresentationFidelity.stable_entity_id(image),
        created_entity_ids: [IMP::RepresentationFidelity.stable_entity_id(image)],
        artifact_evidence: {
          source_span_id: 'text_span:1:0', page_number: 1,
          source_crop_binding_verified: true,
          source_pdf_path: 'C:/fixtures/source.pdf',
          source_pdf_sha256: 'a' * 64,
          source_pdf_binding_verified: true,
          content_sha256: 'b' * 64,
          content_byte_size: 4096,
          png_signature_verified: true, page_binding_verified: true,
          aspect_verified: true,
          source_box: [20.0, 30.0, 44.0, 40.0],
          pixel_crop: [100, 200, 300, 120],
          pixel_width: 300, pixel_height: 120,
          alpha_channel_verified: true,
          transparent_background_verified: true,
          visible_pixel_verified: true,
          page_render_once_verified: true,
          page_render_content_sha256: 'c' * 64
        },
        visual_fidelity_verified: true,
        real_raster_verified: true
      }
    end

    IMP::SvgItemRepresentationRenderer.stub(:render_svg, vector) do
      IMP.stub(:verified_item_raster_entity!, raster) do
        IMP.complete_text3d_item_fallbacks!(
          stats, model, entities, 'fixture.pdf', 1, [source],
          [0, 0, 100, 100], [0, 0, 100, 100], 0, {}, Time.now,
          0.0, document, [valid_transition_proof(:text3d, :glyphs)]
        )
      end
    end
    assert_equal [:glyphs, :geometry], modes
    assert_includes entities.to_a, preexisting
    assert_empty entities.erased
    assert_equal 3, stats[:fallback_transitions].length
    assert_equal true, stats[:raster_fallback_used]
    terminal = stats[:terminal_text_delivery_records].first
    assert_equal :raster, terminal[:delivered_mode]
    assert_equal 'raster_image', terminal[:created_entity_type]
    assert_equal 'item_raster', terminal[:delivery_scope].to_s
    assert_equal true, terminal[:source_crop_binding_verified]
    assert_equal 'text_span:1:0',
                 terminal[:artifact_evidence][:source_span_id]
    attempt = stats[:text_attempts].first
    assert_equal [:text3d, :glyphs, :geometry, :raster],
                 attempt[:attempt_history].map { |rung| rung[:mode] }
    assert_equal [:failed, :failed, :failed, :complete],
                 attempt[:attempt_history].map { |rung| rung[:outcome] }
    assert_equal true, attempt[:real_raster_verified]
    assert_empty stats[:source_provenance_objects]
    assert_equal true, IMP::QAReport.send(
      :validate_representation_fidelity, stats
    )[:ready]
  end

  def test_invalid_post_transform_vector_evidence_cleans_only_its_owned_group
    entities = FidelityEntities.new
    preexisting = entities.add_test_entity(4.0, 4.0, 'Group')
    model = Struct.new(:active_entities).new(entities)
    source = item('A', 0, 12, 8, 'text_span:1:0')
    stats = {
      fallback_transitions: [], terminal_text_delivery_records: [],
      text_attempts: [], text_renderers: [], source_provenance_objects: [],
      raster_delivery_records: [], raster_fallback_used: false
    }
    created_group = nil
    invalid = lambda do |_parent, _svg, _box, _item, _mode, _options|
      created_group = entities.add_test_entity(1.0, 0.5, 'Group')
      id = IMP::RepresentationFidelity.stable_entity_id(created_group)
      {
        ok: true, mode: :glyphs, renderer: :svg_item_glyph_groups,
        source_span_id: 'text_span:1:0', group: created_group,
        group_entity_id: id, created_entity_ids: [id],
        physical_entity_ids: ['persistent_id:900'], placement_indices: [0],
        glyph_ids: ['glyph-0-1'], edge_count: 4, glyph_group_count: 1,
        identity_verified: true, placement_verified: true,
        rotation_verified: true, size_verified: true,
        entity_type_verified: true, visibility_verified: false,
        visual_fidelity_verified: true
      }
    end
    document = {
      svg: '<svg viewBox="0 0 100 100"></svg>', renderer: :pdftocairo,
      missing_fonts: [], missing_language_packs: []
    }

    IMP::SvgItemRepresentationRenderer.stub(:render_svg, invalid) do
      IMP::SvgItemRepresentationRenderer.stub(
        :verify_transformed_delivery!, true
      ) do
        IMP.stub(:apply_and_verify_page_representation_transform, true) do
          assert_raises(IMP::RepresentationFidelity::ContractError) do
            IMP.complete_text3d_item_fallbacks!(
              stats, model, entities, 'fixture.pdf', 1, [source],
              [0, 0, 100, 100], [0, 0, 100, 100], 0, {}, Time.now,
              0.0, document, [valid_transition_proof(:text3d, :glyphs)]
            )
          end
        end
      end
    end

    assert_equal [preexisting], entities.to_a
    assert_equal [created_group], entities.erased
    assert_empty stats[:text_attempts]
    assert_empty stats[:fallback_transitions]
  end

  def test_mixed_labels_keep_successful_3d_delivery_and_fallback_only_its_peer
    entities = FidelityEntities.new
    model = Struct.new(:active_entities).new(entities)
    first = item('A', 0, 12, 8, 'text_span:1:0')
    second = move_item(item('B', 0, 12, 8, 'text_span:1:1'), 60, 30)
    successful_label_peer = move_item(
      item('C', 0, 12, 8, 'text_span:1:2'), 90, 30
    )
    first_group = entities.add_test_entity(1.0, 0.5, 'Group')
    first_group_id = IMP::RepresentationFidelity.stable_entity_id(first_group)
    label_first = valid_transition_proof(:labels, :text3d,
                                         'text_span:1:0')
    label_second = valid_transition_proof(:labels, :text3d,
                                          'text_span:1:1')
    text3d_second = valid_transition_proof(:text3d, :glyphs,
                                           'text_span:1:1')
    result = {
      failures: [],
      span_results: [{
        source_span_id: 'text_span:1:0', group: first_group,
        group_entity_id: first_group_id, identity_verified: true,
        placement_verified: true, rotation_verified: true,
        size_verified: true, depth_verified: true, depth: 0.02,
        width: 1.0, height: 0.5, face_count: 1,
        extruded_face_count: 1
      }],
      unmatched_source_results: [],
      transition_proofs: [text3d_second]
    }
    prior = [
      {
        source_span_id: 'text_span:1:0', requested_mode: :labels,
        attempt_history: [IMP.failed_item_rung_from_transition(label_first)]
      },
      {
        source_span_id: 'text_span:1:1', requested_mode: :labels,
        attempt_history: [IMP.failed_item_rung_from_transition(label_second)]
      }
    ]
    failures = [
      { source_span_id: 'text_span:1:0', transition_proof: label_first },
      { source_span_id: 'text_span:1:1', transition_proof: label_second }
    ]
    stats = {
      fallback_transitions: [], terminal_text_delivery_records: [],
      text_attempts: [], text_renderers: [], page_text_sources: {},
      source_provenance_objects: [], raster_delivery_records: [],
      raster_fallback_used: false, text: 0, edges: 0, faces: 0
    }
    vector_ids = []
    peer_ids = []
    vector = lambda do |_parent, _svg, _box, source, mode, options|
      vector_ids << source.source_span_id
      peer_ids.concat(Array(options[:peer_items]).map(&:source_span_id))
      if mode == :glyphs
        {
          ok: false,
          transition_proof: valid_transition_proof(
            :glyphs, :geometry, source.source_span_id
          )
        }
      else
        group = entities.add_test_entity(1.0, 0.5, 'Group')
        id = IMP::RepresentationFidelity.stable_entity_id(group)
        {
          ok: true, mode: :geometry, renderer: :svg_item_flat_geometry,
          source_span_id: source.source_span_id, group: group,
          group_entity_id: id, created_entity_ids: [id],
          physical_entity_ids: ['persistent_id:900'], placement_indices: [1],
          glyph_ids: ['glyph-0-2'], edge_count: 4, glyph_group_count: 0,
          identity_verified: true, placement_verified: true,
          rotation_verified: true, size_verified: true,
          entity_type_verified: true, visibility_verified: true,
          visual_fidelity_verified: true
        }
      end
    end
    document = {
      svg: '<svg viewBox="0 0 100 100"></svg>', renderer: :pdftocairo,
      missing_fonts: [], missing_language_packs: []
    }

    IMP::Svg3DTextRenderer.stub(:render_svg, result) do
      IMP::SvgItemRepresentationRenderer.stub(:render_svg, vector) do
        IMP::SvgItemRepresentationRenderer.stub(
          :verify_transformed_delivery!, true
        ) do
          IMP.stub(:apply_and_verify_page_representation_transform, true) do
            IMP.complete_label_item_fallbacks!(
              stats, model, entities, 'fixture.pdf', 1, [first, second],
              [0, 0, 100, 100], [0, 0, 100, 100], 0, {}, Time.now,
              0.0, document, failures, prior, nil,
              [first, second, successful_label_peer]
            )
          end
        end
      end
    end

    assert_equal ['text_span:1:1', 'text_span:1:1'], vector_ids
    assert_includes peer_ids, 'text_span:1:0'
    assert_includes peer_ids, 'text_span:1:2'
    refute_includes peer_ids, 'text_span:1:1'
    assert_includes entities.to_a, first_group
    assert_empty entities.erased
    deliveries = stats[:text_attempts].each_with_object({}) do |attempt, map|
      map[attempt[:source_span_id]] = attempt[:delivered_mode]
    end
    assert_equal :text3d, deliveries['text_span:1:0']
    assert_equal :geometry, deliveries['text_span:1:1']
    assert_empty stats[:terminal_text_delivery_records]
  end

  def test_fallback_controller_rejects_generic_empty_visual_and_cleanup_failures
    controller = IMP::RepresentationFidelity::FallbackController.new(
      :text3d, 'text_span:1:0'
    )
    stop_reasons = [
      :exception, :empty_artifact, :renderer_missing,
      :placement_verification_failed, :visual_verification_failed,
      :cleanup_failed
    ]
    stop_reasons.each do |reason|
      proof = valid_transition_proof(:text3d, :glyphs)
      proof[:reason_code] = reason
      error = assert_raises(IMP::RepresentationFidelity::ContractError) do
        controller.advance!(proof)
      end
      assert_match(/cannot authorize a representation transition/i, error.message)
      assert_equal :text3d, controller.current_mode
    end
  end

  def test_same_association_query_cannot_be_relabelled_as_distinct_rung_attempts
    main = File.read(File.join(
      SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'
    ))

    refute_match(/actual_source_association_impossibility_proof!/, main)
    refute_match(/stop_unimplemented_item_fallback!/, main)
    renderer = File.read(File.join(
      SRC_ROOT, 'bc_pdf_vector_importer',
      'svg_item_representation_renderer.rb'
    ))
    assert_match(/svg_item_glyph_group_renderer/, renderer)
    assert_match(/svg_item_flat_geometry_renderer/, renderer)
    assert_match(/representation_contract_checked/, renderer)
  end

  def test_welding_source_diagnostic_runs_the_real_finite_ladder
    diagnostic = File.read(File.join(
      REPO_ROOT, 'tools', 'verify_welding_svg_3d_source.rb'
    ), encoding: 'UTF-8')

    refute_match(/actual_source_association_impossibility_proof!/, diagnostic)
    refute_match(/proof_rows\s*=\s*\[/, diagnostic)
    assert_match(/RepresentationFidelity::FallbackController\.new/, diagnostic)
    assert_match(/Svg3DTextRenderer\.render_svg/, diagnostic)
    assert_match(/SvgItemRepresentationRenderer\.render_svg/, diagnostic)
    assert_match(/live_host_delivery_required/, diagnostic)
    assert_match(/controller\.terminal\?/, diagnostic)
    refute_match(/:adjacent_transition_proofs_verified\s*=>\s*true/,
                 diagnostic)
    refute_match(/:positive_z_depth_verified\s*=>\s*true/, diagnostic)
    refute_match(/:delivered_mode\s*=>\s*:(?:text3d|raster)/, diagnostic)
    assert_match(/:source_candidate_mode/, diagnostic)
    assert_match(/def transition_proof_summary/, diagnostic)
    assert_match(/:glyph_coverage_failure_count/, diagnostic)
    assert_match(/:placement_index_count/, diagnostic)
    refute_match(
      /:transition_proofs\s*=>\s*probe\[:transition_probe_results\]/,
      diagnostic
    )
  end

  def test_fallback_controller_requires_item_binding_affirmative_proof_and_owned_cleanup
    controller = IMP::RepresentationFidelity::FallbackController.new(
      :text3d, 'text_span:1:0'
    )

    mutations = [
      [:source_span_id, 'text_span:1:1'],
      [:importer_id, 'different_importer'],
      [:page_number, 2],
      [:scope, :page],
      [:category, :helper_failed],
      [:affirmative_impossibility, false],
      [:generic_failure, true],
      [:to_mode, :geometry],
      [:attempted_renderer, ''],
      [:evidence, {}]
    ]
    mutations.each do |key, value|
      proof = valid_transition_proof(:text3d, :glyphs)
      proof[key] = value
      assert_raises(IMP::RepresentationFidelity::ContractError,
                    "#{key} must be validated") do
        controller.advance!(proof)
      end
    end

    cleanup = valid_transition_proof(:text3d, :glyphs)
    cleanup[:created_entity_ids] = ['persistent_id:101']
    cleanup[:cleaned_entity_ids] = []
    cleanup[:cleanup_outcome] = :verified
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      controller.advance!(cleanup)
    end

    cleanup[:cleaned_entity_ids] = ['persistent_id:101']
    assert_equal :glyphs, controller.advance!(cleanup)
    assert_equal cleanup, controller.transitions.first
  end

  def test_empty_page_svg_source_classification_separates_exact_glyphs_from_images
    glyph_svg = '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" ' \
      'height="100pt" viewBox="0 0 100 100">' \
      '<defs><g id="glyph-0-0"><path d="M 0 0 L 10 0 L 10 -10 L 0 -10 Z"/></g></defs>' \
      '<use href="#glyph-0-0" x="10" y="80"/></svg>'
    image_svg = '<svg width="100pt" height="100pt" viewBox="0 0 100 100">' \
      '<defs><image id="source-3" width="10" height="10"/></defs>' \
      '<use href="#source-3" x="0" y="0"/></svg>'

    glyph = IMP.svg_page_source_summary(glyph_svg, [0, 0, 100, 100], {})
    image = IMP.svg_page_source_summary(image_svg, [0, 0, 100, 100], {})

    assert_equal 1, glyph[:source_glyph_placements]
    refute glyph[:visible_nontext_source]
    assert_equal 0, image[:source_glyph_placements]
    assert image[:visible_nontext_source]
    assert_equal 1, image[:source_uses]
    assert_equal 1, image[:image_definitions]
  end

  def test_extracted_embedded_asset_cannot_suppress_empty_artifact_source_inspection
    ccitt_asset = Struct.new(:file_path).new('page_001_image_001.ccitt')

    assert IMP.empty_requested_page_artifacts?([], [])
    assert IMP.empty_requested_page_artifacts?([], [], [ccitt_asset]),
           'extraction is not host delivery and cannot suppress source inspection'
    refute IMP.empty_requested_page_artifacts?([:path], [], [ccitt_asset])
    refute IMP.empty_requested_page_artifacts?([], [:text], [ccitt_asset])
  end

  def test_requested_raster_requires_page_delivery_for_every_zero_canonical_page
    assert IMP.requested_zero_canonical_page_raster?(:raster, true, [])
    assert IMP.requested_zero_canonical_page_raster?('Raster', true, nil)
    refute IMP.requested_zero_canonical_page_raster?(:raster, true, [:text])
    refute IMP.requested_zero_canonical_page_raster?(:labels, true, [])
    refute IMP.requested_zero_canonical_page_raster?(:raster, false, [])

    main = File.read(File.join(
      SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'
    ), :encoding => 'UTF-8')
    assert_match(
      /empty_requested_page_artifacts\?\(paths, text_items, embedded_assets\)\s*\|\|\s*explicit_zero_canonical_page_raster/,
      main
    )
    assert_match(/delivery_basis\s*=>\s*:verified_zero_canonical_text/, main)
    assert_match(/semantic_text_evaluated\s*=>\s*true/, main)
  end

  def test_empty_page_source_inspection_is_one_exact_source_bound_record
    stats = {
      :empty_page_source_inspections => [],
      :source_input_sha256 => 'a' * 64,
      :normalized_input_sha256 => 'b' * 64
    }
    IMP.record_empty_page_source_inspection!(stats, 1, {
      :semantic_text_extraction_complete => true,
      :decoded_stream_text_operators => false,
      :decoded_form_stream_text_operators => false,
      :canonical_text_item_count => 0
    })
    IMP.record_empty_page_source_inspection!(stats, 1, {
      :visible_nontext_source => true,
      :source_glyph_placements => 0,
      :embedded_image_asset_count => 1,
      :embedded_image_placed_count => 0
    })

    assert_equal 1, stats[:empty_page_source_inspections].length
    proof = stats[:empty_page_source_inspections].first
    assert_equal 1, proof[:page]
    assert_equal 1, proof[:source_page_number]
    assert_equal 0, proof[:canonical_text_item_count]
    assert_equal 'a' * 64, proof[:immutable_pdf_sha256]
    assert_equal 'b' * 64, proof[:rendered_pdf_sha256]
    assert_equal true, proof[:visible_nontext_source]
    assert_equal 1, proof[:embedded_image_asset_count]
    assert_equal 0, proof[:embedded_image_placed_count]
  end

  def test_svg_source_classification_includes_direct_and_generic_image_references
    direct_svg = '<svg width="100pt" height="100pt" viewBox="0 0 100 100">' \
      '<image href="data:image/png;base64,AAAA" x="0" y="0" ' \
      'width="20" height="10"/></svg>'
    generic_svg = '<svg width="100pt" height="100pt" viewBox="0 0 100 100">' \
      '<defs><image id="img17" width="20" height="10"/></defs>' \
      '<use href="#img17" x="4" y="5"/></svg>'

    direct = IMP.svg_page_source_summary(direct_svg, [0, 0, 100, 100], {})
    generic = IMP.svg_page_source_summary(generic_svg, [0, 0, 100, 100], {})

    assert_equal 1, direct[:direct_image_placements]
    assert_equal 1, direct[:image_placements]
    assert_equal true, direct[:visible_nontext_source]
    assert_equal true, direct[:visible_source]

    assert_equal 1, generic[:image_definitions]
    assert_equal 1, generic[:referenced_image_placements]
    assert_equal 1, generic[:image_placements]
    assert_equal true, generic[:visible_nontext_source]
    assert_equal true, generic[:visible_source]
  end

  def test_svg_renderer_is_required_only_when_the_page_has_text_or_needs_source_inspection
    item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
      'A', 10, 20, 12, 0, 'F1', 12,
      9, 19, 20, 30, nil, 'text_span:1:0'
    )

    assert IMP.svg_renderer_required_for_page?(:text3d, true, [item], false)
    assert IMP.svg_renderer_required_for_page?(:glyphs, true, [], true)
    assert IMP.svg_renderer_required_for_page?(:geometry, true, [], true)

    refute IMP.svg_renderer_required_for_page?(:text3d, true, [], false),
           'an ordinary page with no text must not be blocked by a missing text renderer'
    refute IMP.svg_renderer_required_for_page?(:labels, true, [item], true)
    refute IMP.svg_renderer_required_for_page?(:raster, true, [item], true)
    refute IMP.svg_renderer_required_for_page?(:text3d, false, [item], true)
  end
end
