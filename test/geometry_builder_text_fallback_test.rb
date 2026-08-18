#!/usr/bin/env ruby
# TEXTMODE-1: a generic host/API failure is not proof that the requested
# representation is impossible for this source span.  It must stop in the
# requested mode, with exact cleanup, rather than substituting another type.

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
        Point3d.new(
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
        Point3d.new(
          pivot.x + (dx * c) - (dy * s),
          pivot.y + (dx * s) + (dy * c),
          point.z
        )
      else
        delta = @args.first || Vector3d.new
        Point3d.new(point.x + delta.x, point.y + delta.y, point.z + delta.z)
      end
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)

class TextFallbackEntity
  attr_accessor :layer, :display_leader, :vector
  attr_reader :persistent_id, :point

  def initialize(id, point = nil, vector = nil, width = nil, height = nil)
    @persistent_id = id
    @point = point
    @vector = vector
    if width && height
      @points = [
        Geom::Point3d.new(0, 0, 0),
        Geom::Point3d.new(width, 0, 0),
        Geom::Point3d.new(width, height, 0),
        Geom::Point3d.new(0, height, 0)
      ]
    end
  end

  def bounds
    points = @points
    Struct.new(:min, :max).new(
      Geom::Point3d.new(points.map(&:x).min, points.map(&:y).min, 0),
      Geom::Point3d.new(points.map(&:x).max, points.map(&:y).max, 0)
    )
  end

  def transform!(transformation)
    @points = @points.map { |point| transformation.apply(point) } if @points
  end

  def typename
    'Edge'
  end
end

class TextFallbackStagingEntities
  def initialize(parent)
    @parent = parent
    @entities = []
  end

  def add_3d_text(*args)
    before = Array(@parent.to_a).dup
    begin
      @parent.add_3d_text(*args)
    ensure
      generated = @parent.to_a.reject { |entity| before.include?(entity) }
      @parent.detach_staged_entities(generated)
      @entities.concat(generated)
    end
  end

  def to_a
    @entities.dup
  end
end

class TextFallbackStagingGroup
  attr_reader :entities, :persistent_id

  def initialize(id, parent)
    @persistent_id = id
    @parent = parent
    @entities = TextFallbackStagingEntities.new(parent)
  end

  def typename
    'Group'
  end

  def explode
    @parent.explode_staging_group(self, @entities.to_a)
  end
end

class TextFallbackEntities
  attr_reader :labels, :mesh_calls, :added_texts

  def initialize(mesh_result, label_result)
    @mesh_result = mesh_result
    @label_result = label_result
    @labels = []
    @mesh_calls = []
    @added_texts = []
    @entities = []
    @next_id = 100
  end

  def to_a
    @entities
  end

  def add_group
    @next_id += 1
    group = TextFallbackStagingGroup.new(@next_id, self)
    @entities << group
    group
  end

  def detach_staged_entities(entities)
    @entities.reject! { |entity| entities.include?(entity) }
  end

  def explode_staging_group(group, children)
    @entities.delete(group)
    @entities.concat(children)
    children
  end

  def add_3d_text(*)
    @mesh_calls << true
    raise 'forced mesh failure' if @mesh_result == :raise
    return false if @mesh_result == :false
    return true if @mesh_result == :empty

    @next_id += 1
    @entities << TextFallbackEntity.new(
      @next_id, nil, nil, 15.0 / 72.0, 9.0 / 72.0
    )
    true
  end

  def add_text(text, point, vector = nil)
    @added_texts << text
    raise 'forced label failure' if @label_result == :raise
    return nil if @label_result == :nil

    @next_id += 1
    entity = TextFallbackEntity.new(@next_id, point, vector)
    @entities << entity
    @labels << entity
    entity
  end

  def transform_entities(transformation, *entities)
    entities.each { |entity| entity.transform!(transformation) }
  end

  def erase_entities(*entities)
    entities.flatten.each { |entity| @entities.delete(entity) }
  end
end

class AnnotationSignatureProbe
  attr_reader :argument_counts

  def initialize
    @argument_counts = []
  end

  def to_a
    []
  end

  def add_text(*args)
    @argument_counts << args.length
    nil
  end
end

class HiddenLabelMutationProbe
  attr_reader :vector, :vector_writes
  attr_accessor :display_leader

  def initialize
    @vector = Geom::Vector3d.new(0, 0, 0)
    @vector_writes = []
    @display_leader = true
  end

  def vector=(value)
    @vector_writes << value
    @vector = value
  end
end

class AnnotationReadbackProbe
  attr_reader :text, :point, :vector

  def initialize(text, point, vector)
    @text = text
    @point = point
    @vector = vector
  end

  def typename
    'Text'
  end

  def display_leader?
    false
  end
end

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

class GeometryBuilderTextFallbackTest < Minitest::Test
  Item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem

  def make_item
    Item.new('A1', 10.0, 20.0, 9.0, 0.0, 'Arial', nil,
             10.0, 20.0, 25.0, 29.0, nil, 'text_span:1:0')
  end

  def make_rotated_item
    Item.new('A1', 10.0, 20.0, 9.0, 90.0, 'Arial', nil,
             10.0, 20.0, 19.0, 35.0, nil, 'text_span:1:0')
  end

  def make_builder(use_3d_text, provenance, requested_text_mode = nil)
    BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
      nil, [], [], [0, 0, 612, 792],
      import_text: true,
      use_3d_text: use_3d_text,
      provenance_bucket: provenance,
      requested_text_mode: requested_text_mode,
      native_font_identity_resolver: lambda { |source|
        {
          source_span_id: source.source_span_id,
          pdf_font_identity: 'embedded:test-font',
          installed_family: 'Test Exact Font',
          exact_family_match: true,
          verified: true
        }
      }
    )
  end

  def assert_mesh_failure_stops_in_requested_mode(mesh_result, reason)
    provenance = []
    builder = make_builder(true, provenance)
    entities = TextFallbackEntities.new(mesh_result, :success)

    delivered = builder.send(
      :place_mesh_text, entities, make_item, 0.0, 0.0, 'Text'
    )

    refute delivered
    assert_empty entities.labels
    refute_respond_to builder, :text_fallbacks
    assert_empty provenance
    failure = builder.text_delivery_failures.fetch(0)
    assert_equal :text3d, failure[:requested]
    assert_equal reason, failure[:reason]
    assert_equal [:text3d],
                 failure[:attempt_history].map { |rung| rung[:mode] }
  end

  def test_false_mesh_result_stops_without_a_label_substitution
    assert_mesh_failure_stops_in_requested_mode(
      :false, 'text3d_mesh_unavailable'
    )
  end

  def test_empty_mesh_result_stops_without_a_label_substitution
    assert_mesh_failure_stops_in_requested_mode(:empty, 'text3d_mesh_empty')
  end

  def test_mesh_exception_stops_without_a_label_substitution
    assert_mesh_failure_stops_in_requested_mode(:raise, 'text3d_exception')
  end

  def test_wrong_mode_entry_does_not_authorize_geometry_to_label_substitution
    provenance = []
    builder = make_builder(true, provenance, :geometry)
    entities = TextFallbackEntities.new(:false, :success)

    delivered = builder.send(
      :place_mesh_text, entities, make_item, 0.0, 0.0, 'Text'
    )

    refute delivered
    assert_empty entities.labels
    refute_respond_to builder, :text_fallbacks
    assert_empty provenance
    failure = builder.text_delivery_failures.fetch(0)
    assert_equal :geometry, failure[:requested]
    assert_equal [:text3d],
                 failure[:attempt_history].map { |rung| rung[:mode] }
  end

  def test_text3d_failure_never_attempts_labels_or_authorizes_page_raster
    provenance = []
    builder = make_builder(true, provenance)
    entities = TextFallbackEntities.new(:false, :nil)

    delivered = builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    refute delivered
    refute_respond_to builder, :text_fallbacks
    failure = builder.text_delivery_failures.fetch(0)
    assert_equal :text3d, failure[:requested]
    assert_equal 'text3d_mesh_unavailable', failure[:reason]
    assert_equal 'text_span:1:0', failure[:source_span_id]
    assert_equal [:text3d],
                 failure[:attempt_history].map { |rung| rung[:mode] }
    assert failure[:attempt_history].all? { |rung| rung[:outcome] == :failed }
    assert_empty entities.labels
  end

  def test_horizontal_label_size_proof_precedes_native_api_and_3d_substitution
    provenance = []
    builder = make_builder(false, provenance)
    entities = TextFallbackEntities.new(:success, :nil)

    delivered = builder.send(
      :place_annotation_label, entities, make_item, 0.0, 0.0, 'Text'
    )

    refute delivered
    assert_empty entities.added_texts
    assert_empty entities.mesh_calls
    refute_respond_to builder, :text_fallbacks
    assert_empty provenance
    failure = builder.text_delivery_failures.fetch(0)
    assert_equal :labels, failure[:requested]
    assert_equal 'label_source_size_unsupported_by_host', failure[:reason]
    proof = failure[:transition_proof]
    assert_equal :labels, proof[:from_mode]
    assert_equal :text3d, proof[:to_mode]
    assert_equal [:labels],
                 failure[:attempt_history].map { |rung| rung[:mode] }
  end

  def test_label_rejects_missing_degenerate_and_nonpositive_source_dimensions
    invalid_boxes = [
      [nil, 20.0, 25.0, 29.0],
      [10.0, 20.0, 10.0, 29.0],
      [10.0, 20.0, 25.0, 20.0],
      [25.0, 20.0, 10.0, 29.0],
      [10.0, 29.0, 25.0, 20.0],
      [Float::INFINITY, 20.0, 25.0, 29.0]
    ]

    invalid_boxes.each_with_index do |box, index|
      provenance = []
      builder = make_builder(false, provenance, :labels)
      entities = TextFallbackEntities.new(:success, :success)
      item = Item.new(
        'A1', 10.0, 20.0, 9.0, 0.0, 'Arial', nil,
        box[0], box[1], box[2], box[3], nil,
        "text_span:1:#{index}"
      )

      delivered = builder.send(
        :place_annotation_label, entities, item, 0.0, 0.0, 'Text'
      )

      refute delivered, box.inspect
      assert_empty entities.added_texts,
                   'invalid source dimensions must fail before add_text'
      assert_empty entities.to_a
      assert_empty provenance
      failure = builder.text_delivery_failures.fetch(0)
      assert_equal 'label_source_dimensions_unavailable', failure[:reason]
      rung = failure[:attempt_history].fetch(0)
      assert_equal :failed, rung[:outcome]
      assert_empty rung[:created_entity_ids]
      assert_empty rung[:cleaned_entity_ids]
      assert_equal :not_required, rung[:cleanup_outcome]
    end
  end

  def test_whitespace_only_label_fallback_preserves_exact_source_content
    provenance = []
    builder = make_builder(false, provenance, :labels)
    entities = TextFallbackEntities.new(:success, :nil)
    item = Item.new('   ', 10.0, 20.0, 9.0, 0.0, 'Arial', nil,
                    10.0, 20.0, 25.0, 29.0, nil, 'text_span:1:1')

    delivered = builder.send(
      :place_text, entities, item, 0.0, 0.0, 792.0, 'Text'
    )

    refute delivered
    assert_empty entities.added_texts,
                 'source-size fallback must occur before native add_text'
    failure = builder.text_delivery_failures.fetch(0)
    assert_equal 'text_span:1:1', failure[:source_span_id]
    assert_equal :labels, failure[:requested]
    assert_equal 'label_source_size_unsupported_by_host', failure[:reason]
    assert_equal Digest::SHA256.hexdigest('   '),
                 failure[:transition_proof][:evidence][:source_text_sha256]
  end

  def test_empty_label_span_is_ignored_without_entities_or_fallback
    provenance = []
    builder = make_builder(false, provenance, :labels)
    entities = TextFallbackEntities.new(:success, :success)
    item = Item.new('', 10.0, 20.0, 9.0, 0.0, 'Arial', nil,
                    10.0, 20.0, 25.0, 29.0, nil, 'text_span:1:2')

    assert_nil builder.send(
      :place_text, entities, item, 0.0, 0.0, 792.0, 'Text'
    )
    assert_empty entities.to_a
    assert_empty entities.added_texts
    assert_empty builder.text_delivery_failures
    assert_empty builder.text_attempts
    assert_empty provenance
  end

  def test_sketchup_2017_label_leader_vector_is_never_certified_as_rotation
    provenance = []
    builder = make_builder(false, provenance, :labels)
    entities = TextFallbackEntities.new(:success, :success)

    delivered = builder.send(
      :place_annotation_label, entities, make_rotated_item,
      0.0, 0.0, 'Text'
    )

    refute delivered
    assert_empty entities.to_a,
                 'known host impossibility must not leave a misleading label'
    assert_empty provenance
    failure = builder.text_delivery_failures.fetch(0)
    assert_equal 'label_rotation_unsupported_by_host', failure[:reason]
    proof = failure[:transition_proof]
    assert_equal :labels, proof[:from_mode]
    assert_equal :text3d, proof[:to_mode]
    assert_equal :host_representation_unsupported, proof[:reason_code]
    assert_equal true, proof[:affirmative_impossibility]
    assert_equal false, proof[:generic_failure]
    assert_equal :not_required, proof[:cleanup_outcome]
  end

  def test_sketchup_2017_never_receives_a_zero_length_add_text_vector
    builder = make_builder(false, [], :labels)
    entities = AnnotationSignatureProbe.new

    result = builder.send(
      :try_add_annotation_text, entities, 'A1', Geom::Point3d.new,
      Geom::Vector3d.new(0, 0, 0)
    )

    assert_nil result
    assert_equal [2], entities.argument_counts,
                 'a failed plain add_text call must stop without the crashing zero-vector signature'
  end

  def test_hiding_a_native_label_does_not_assign_a_zero_length_vector
    builder = make_builder(false, [], :labels)
    label = HiddenLabelMutationProbe.new
    original_vector = label.vector

    builder.send(:hide_annotation_leader, label)

    assert_equal false, label.display_leader
    assert_same original_vector, label.vector
    assert_empty label.vector_writes,
                 'SketchUp 2017 can crash when a Text leader is assigned a zero-length vector'
  end

  def test_label_certification_requires_three_coordinate_vector_readback
    builder = make_builder(false, [], :labels)
    point = Geom::Point3d.new(1, 2, 3)
    label = AnnotationReadbackProbe.new('A1', point, nil)

    assert_raises(BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError) do
      builder.send(:verify_annotation_label, label, 'A1', point, 0.0, true)
    end
  end
end
