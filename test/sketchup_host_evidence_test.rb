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
    assert SketchupHostEvidence.verify_delivery_evidence!(stats, manifest)
  end

  def test_manifest_records_both_identity_namespaces_and_checks_each_claim
    rows = SketchupHostEvidence.snapshot_entities([
      FakeEntity.new(13, 'Face', :persistent_id => 7013)
    ])
    assert_equal 13, rows[0]['entity_id']
    assert_equal 7013, rows[0]['persistent_id']

    assert SketchupHostEvidence.verify_delivery_evidence!(
      ready_stats(:terminal_text_delivery_records => [{
        :resulting_entity_ids => ['persistent_id:7013'],
        :source_span_ids => ['p1:s1']
      }]),
      rows,
      :labels,
      [1]
    )
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        ready_stats(:terminal_text_delivery_records => [{
          :resulting_entity_ids => ['persistent_id:13'],
          :source_span_ids => ['p1:s1']
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
      SketchupHostEvidence.verify_delivery_evidence!(stats, manifest, :labels, [1])
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
      SketchupHostEvidence.verify_delivery_evidence!(stats, manifest, :labels, [1])
    end
    assert_match(/decoded-stream no-text proof/, error.message)

    stats[:empty_page_source_inspections] = [{
      :page => 1,
      :semantic_text_extraction_complete => true,
      :decoded_stream_text_operators => false,
      :decoded_form_stream_text_operators => false
    }]
    assert SketchupHostEvidence.verify_delivery_evidence!(
      stats, manifest, :labels, [1]
    )
  end

  def test_source_span_attempt_and_delivery_sets_must_be_equal
    stats = ready_stats(
      :text_source_span_ids => ['p1:s1', 'p1:s2'],
      :text_attempts => [{
        :source_span_id => 'p1:s1',
        :resulting_entity_ids => ['entity_id:13']
      }],
      :source_provenance_objects => [{
        :span_id => 'p1:s1',
        :resulting_entity_ids => ['entity_id:13']
      }]
    )
    error = assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(stats, manifest, :labels, [1])
    end
    assert_match(/source.*set mismatch/, error.message)
  end

  def test_geometry_and_glyph_ledgers_accept_plural_source_span_ids
    [:geometry, :glyphs].each do |mode|
      stats = ready_stats(
        :requested_text_mode => mode,
        :text_source_span_ids => ['p1:s1', 'p1:s2'],
        :text_attempts => [{
          :source_span_ids => ['p1:s1', 'p1:s2'],
          :resulting_entity_ids => ['entity_id:13']
        }],
        :source_provenance_objects => [],
        :page_text_delivery_records => [{
          :source_span_ids => ['p1:s1', 'p1:s2'],
          :resulting_entity_ids => ['entity_id:13']
        }]
      )

      assert SketchupHostEvidence.verify_delivery_evidence!(
        stats, manifest, mode, [1]
      )
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
      'children' => [{
        'entity_id' => 13,
        'persistent_id' => 13,
        'children' => []
      }]
    }]
  end

  def ready_stats(overrides = {})
    {
      :requested_text_mode => :labels,
      :import_session_id => 'test-session',
      :text_source_span_ids => ['p1:s1'],
      :text_attempts => [{
        :source_span_id => 'p1:s1',
        :resulting_entity_ids => [13]
      }],
      :source_provenance_objects => [{
        :span_id => 'p1:s1',
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
