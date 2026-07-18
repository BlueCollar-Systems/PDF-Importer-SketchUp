#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'

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
  end

  class FakeGroup < FakeEntity
    attr_reader :entities

    def initialize(entity_id, children, options = {})
      super(entity_id, 'Group', options)
      @entities = children
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
      @definition = FakeDefinition.new(children)
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

  def setup
    assert File.file?(EVIDENCE_TOOL),
           'tools/sketchup_host_evidence.rb must exist'
    load EVIDENCE_TOOL unless defined?(SketchupHostEvidence)
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
    stats = ready_stats(
      :text_source_span_ids => [],
      :text_attempts => [],
      :source_provenance_objects => [],
      :empty_page_source_inspections => []
    )
    error = assert_raises(StandardError) do
        SketchupHostEvidence.verify_delivery_evidence!(stats, label_manifest, :labels, [1])
    end
    assert_match(/decoded-stream no-text proof/, error.message)

    stats[:empty_page_source_inspections] = [{
      :page => 1,
      :semantic_text_extraction_complete => true,
      :decoded_stream_text_operators => false,
      :decoded_form_stream_text_operators => false
    }]
    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, label_manifest, :labels, [1]
    )
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

  def test_geometry_and_glyph_ledgers_accept_plural_source_span_ids
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

      assert SketchupHostEvidence.verify_delivery_evidence!(
        stats, mode == :geometry ? geometry_manifest : glyph_manifest, mode, [1]
      )
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
    artifact = {
      :page_number => 1, :pixel_width => 1200, :pixel_height => 1600,
      :png_signature_verified => true, :page_binding_verified => true,
      :box_binding_verified => true, :content_sha256 => sha256,
      :content_byte_size => 48_000
    }
    record = {
      :page => 1, :source_span_ids => [], :requested_mode => :raster,
      :delivered_mode => :raster, :resulting_entity_ids => ['entity_id:13'],
      :created_entity_type => 'raster_image', :real_raster_verified => true,
      :visual_fidelity_verified => true, :cleanup_outcome => :not_required,
      :delivery_scope => :page_raster, :no_semantic_text => true,
      :artifact_evidence => artifact
    }
    stats = ready_stats(
      :requested_text_mode => :raster, :text_source_span_ids => [],
      :text_attempts => [], :source_provenance_objects => [],
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
        ['BC_PDF_Importer', 'raster_content_bytes'] => 48_000
      })
    ])
    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, image_manifest, :raster, [1]
    )

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

  private

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
    [{
      'entity_id' => 13, 'persistent_id' => 1013,
      'typename' => 'Text', 'valid' => true, 'deleted' => false,
      'content_evidence' => {
        'text_like' => true, 'text' => 'A',
        'text_sha256' => Digest::SHA256.hexdigest('A'),
        'anchor' => [1.0, 2.0, 0.0], 'leader_visible' => false
      },
      'children' => []
    }]
  end

  def geometry_manifest
    [{
      'entity_id' => 13, 'persistent_id' => 1013,
      'typename' => 'Group', 'valid' => true, 'deleted' => false,
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
  end

  def glyph_manifest
    [{
      'entity_id' => 13, 'persistent_id' => 1013,
      'typename' => 'Group', 'valid' => true, 'deleted' => false,
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
  end

  def text3d_manifest
    [{
      'entity_id' => 13, 'persistent_id' => 1013,
      'typename' => 'Group', 'valid' => true, 'deleted' => false,
      'bounds' => { 'min' => [0.0, 0.0, 0.0],
                    'max' => [1.0, 1.0, 0.1] },
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
  end

  def ready_stats(overrides = {})
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
        :attempt_history => [{
          :mode => :labels, :outcome => :complete,
          :resulting_entity_ids => [13],
          :visual_fidelity_verified => true,
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
    ready_stats(
      :requested_text_mode => job_mode,
      :text_source_span_ids => [source_id],
      :text_attempts => [{
        :page => page_number, :source_span_ids => [source_id],
        :source_text_sha256 => Digest::SHA256.hexdigest('A'),
        :requested_mode => record_mode, :delivered_mode => record_mode,
        :resulting_entity_ids => [entity_id],
        :visual_fidelity_verified => true,
        :attempt_history => [{
          :mode => record_mode, :outcome => :complete,
          :resulting_entity_ids => [entity_id],
          :visual_fidelity_verified => true,
          :cleanup_outcome => :not_required
        }]
      }],
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
    ready_stats(
      :text_attempts => [{
        :source_span_id => source_id, :requested_mode => :labels,
        :delivered_mode => :text3d, :resulting_entity_ids => [entity_id],
        :attempt_history => [{
          :mode => :labels, :outcome => :failed,
          :resulting_entity_ids => [], :transition_proof => proof
        }, {
          :mode => :text3d, :outcome => :complete,
          :resulting_entity_ids => [entity_id],
          :visual_fidelity_verified => true,
          :cleanup_outcome => :not_required
        }]
      }],
      :source_provenance_objects => [{
        :span_id => source_id, :resulting_entity_ids => [entity_id]
      }],
      :fallback_transitions => [proof.dup]
    )
  end

  def strict_text3d_stats
    source_id = 'text_span:1:0'
    entity_id = 'entity_id:13'
    ready_stats(
      :requested_text_mode => :text3d,
      :text_attempts => [{
        :source_span_id => source_id, :page => 1,
        :requested_mode => :text3d, :delivered_mode => :text3d,
        :resulting_entity_ids => [entity_id],
        :visual_fidelity_verified => true,
        :attempt_history => [{
          :mode => :text3d, :outcome => :complete,
          :resulting_entity_ids => [entity_id],
          :visual_fidelity_verified => true,
          :cleanup_outcome => :not_required
        }]
      }],
      :source_provenance_objects => [{
        :span_id => source_id, :page => 1,
        :created_entity_type => 'source_glyph_3d_text',
        :renderer => 'svg_source_3d_text',
        :resulting_entity_ids => [entity_id]
      }]
    )
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
