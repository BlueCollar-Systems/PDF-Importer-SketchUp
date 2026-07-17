#!/usr/bin/env ruby
require 'minitest/autorun'

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
    attr_reader :entityID, :typename, :bounds, :transformation

    def initialize(entity_id, typename, options = {})
      @entityID = entity_id
      @typename = typename
      @valid = options.fetch(:valid, true)
      @deleted = options.fetch(:deleted, false)
      @bounds = options[:bounds]
      @transformation = options[:transformation]
    end

    def valid?
      @valid
    end

    def deleted?
      @deleted
    end
  end

  class FakeGroup < FakeEntity
    attr_reader :entities

    def initialize(entity_id, children, options = {})
      super(entity_id, 'Group', options)
      @entities = children
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
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(stats, manifest)
    end
    assert_match(/entity IDs/, error.message)
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
      'children' => [{
        'entity_id' => 13,
        'children' => []
      }]
    }]
  end

  def ready_stats(overrides = {})
    {
      :page_text_delivery_records => [],
      :terminal_text_delivery_records => [],
      :page_representation_fallbacks => [],
      :raster_delivery_records => [],
      :source_glyph_physical_deliveries => [],
      :representation_fidelity => { :ready => true },
      :import_contract_ready => { :ready => true }
    }.merge(overrides)
  end
end
