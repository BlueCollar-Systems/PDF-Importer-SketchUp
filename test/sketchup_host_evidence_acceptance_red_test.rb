#!/usr/bin/env ruby

# Focused RED acceptance regressions found during the independent host-evidence
# review. These intentionally remain uncommitted until the production verifier
# can prove the requested representation against the physical SketchUp entity.
require_relative 'sketchup_host_evidence_test'

class SketchupHostEvidenceTest < Minitest::Test
  class RedLayer
    attr_reader :name

    def initialize(name, visible)
      @name = name
      @visible = visible
    end

    def visible?; @visible; end
  end

  class RedVertex
    attr_reader :position

    def initialize(point)
      @position = point
    end
  end

  class RedStyledEdge < FakeEntity
    attr_reader :start, :end, :layer

    def initialize(entity_id)
      super(entity_id, 'Edge')
      @start = RedVertex.new(FakePoint.new(0.0, 0.0, 0.0))
      @end = RedVertex.new(FakePoint.new(2.0, 3.0, 0.0))
      @layer = RedLayer.new('PDF Text', true)
    end

    def hidden?; false; end
    def visible?; true; end
    def material; nil; end
  end

  def test_red_same_text_labels_cannot_swap_source_anchors
    digest = Digest::SHA256.hexdigest('A')
    first = Marshal.load(Marshal.dump(label_manifest.first))
    second = Marshal.load(Marshal.dump(label_manifest.first))
    second['entity_id'] = 14
    second['persistent_id'] = 1014
    second['content_evidence']['anchor'] = [10.0, 20.0, 0.0]

    attempts = [
      label_attempt_with_anchor(
        'text_span:1:0', 'entity_id:14', digest, [1.0, 2.0, 0.0]
      ),
      label_attempt_with_anchor(
        'text_span:1:1', 'entity_id:13', digest, [10.0, 20.0, 0.0]
      )
    ]
    stats = ready_stats(
      :text_source_span_ids => ['text_span:1:0', 'text_span:1:1'],
      :text_attempts => attempts,
      :source_provenance_objects => [{
        :span_id => 'text_span:1:0',
        :resulting_entity_ids => ['entity_id:14']
      }, {
        :span_id => 'text_span:1:1',
        :resulting_entity_ids => ['entity_id:13']
      }]
    )

    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, [first, second], :labels, [1]
      )
    end
  end

  def test_red_snapshot_captures_deterministic_geometry_style_and_visibility
    row = SketchupHostEvidence.snapshot_entities([RedStyledEdge.new(31)]).first

    refute_nil row['geometry_evidence']
    assert_match(/\A[0-9a-f]{64}\z/, row['geometry_evidence']['sha256'])
    assert_equal 'PDF Text', row['style_evidence']['layer_name']
    assert_equal true, row['style_evidence']['layer_visible']
    assert_equal true, row['style_evidence']['entity_visible']
  end

  def test_red_text3d_requires_source_content_style_and_transform_binding
    stats = strict_text3d_stats
    attempt = stats[:text_attempts][0]
    attempt[:source_text_sha256] = Digest::SHA256.hexdigest('WELD')
    attempt[:source_anchor] = [4.0, 5.0, 0.0]
    attempt[:source_rotation_radians] = 0.7853981633974483
    attempt[:expected_width] = 2.5
    attempt[:expected_height] = 0.75
    attempt[:expected_depth] = 0.1
    attempt[:source_style_sha256] = Digest::SHA256.hexdigest('font/style/red')
    attempt[:expected_evidence] = source_expected_evidence(
      :text3d, 'text_span:1:0', 'WELD',
      :anchor => [4.0, 5.0, 0.0],
      :rotation_radians => 0.7853981633974483,
      :width => 2.5, :height => 0.75, :depth => 0.1,
      :geometry_sha256 => Digest::SHA256.hexdigest('not-the-host-geometry'),
      :style_sha256 => Digest::SHA256.hexdigest('not-the-host-style')
    )

    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, text3d_manifest, :text3d, [1]
      )
    end
  end

  def test_red_plural_sources_cannot_be_satisfied_by_one_count_only_group
    accepted = []
    [:geometry, :glyphs].each do |mode|
      stats = plural_page_claim_stats(mode)
      manifest = mode == :geometry ? geometry_manifest : glyph_manifest
      begin
        SketchupHostEvidence.verify_delivery_evidence!(
          stats, manifest, mode, [1]
        )
        accepted << mode
      rescue StandardError
        # Correct behavior: every source item needs independently bound physical
        # evidence, even when multiple items contain the same text.
      end
    end

    assert_empty accepted
  end

  def test_red_geometry_and_glyphs_require_physical_transform_and_style_proof
    accepted = []
    [:geometry, :glyphs].each do |mode|
      stats = strict_page_mode_stats(mode, mode, 1)
      stats[:text_attempts][0][:source_geometry_sha256] =
        Digest::SHA256.hexdigest('source/path/geometry')
      stats[:text_attempts][0][:expected_transform] =
        [1.0, 0.0, 0.0, 1.0, 12.0, 8.0]
      stats[:text_attempts][0][:source_style_sha256] =
        Digest::SHA256.hexdigest('stroke/style')
      stats[:text_attempts][0][:expected_evidence] = source_expected_evidence(
        mode, 'text_span:1:0', 'A',
        :anchor => [12.0, 8.0, 0.0],
        :rotation_radians => 0.0,
        :width => 1.0, :height => 1.0, :depth => 0.0,
        :geometry_sha256 => Digest::SHA256.hexdigest('source/path/geometry'),
        :style_sha256 => Digest::SHA256.hexdigest('stroke/style')
      )
      manifest = mode == :geometry ? geometry_manifest : glyph_manifest
      begin
        SketchupHostEvidence.verify_delivery_evidence!(
          stats, manifest, mode, [1]
        )
        accepted << mode
      rescue StandardError
        # Correct behavior: a type/count-only hierarchy is not physical proof.
      end
    end

    assert_empty accepted
  end

  def test_red_reopen_continuity_must_reject_style_changes
    saved = [{
      'entity_id' => 1, 'persistent_id' => 1001,
      'typename' => 'Edge', 'valid' => true, 'deleted' => false,
      'bounds' => { 'min' => [0.0, 0.0, 0.0],
                    'max' => [1.0, 1.0, 0.0] },
      'transformation' => [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
      'representation_evidence' => {
        'source_span_id' => 'text_span:1:0',
        'representation' => 'geometry'
      },
      'content_evidence' => nil,
      'style_evidence' => { 'layer' => 'PDF', 'material' => 'red' },
      'children' => []
    }]
    reopened = Marshal.load(Marshal.dump(saved))
    reopened[0]['style_evidence']['material'] = 'blue'

    assert_raises(StandardError) do
      SketchupHostEvidence.verify_reopen_continuity!(saved, reopened)
    end
  end

  def test_red_completed_claim_cannot_override_failed_mode_specific_checks
    stats = ready_stats
    attempt = stats[:text_attempts][0]
    attempt[:visual_fidelity_verified] = false
    attempt[:placement_verified] = false
    attempt[:rotation_verified] = false
    attempt[:content_verified] = false
    attempt[:entity_type_verified] = false
    rung = attempt[:attempt_history][0]
    rung[:placement_verified] = false
    rung[:rotation_verified] = false
    rung[:content_verified] = false
    rung[:entity_type_verified] = false

    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, label_manifest, :labels, [1]
      )
    end
  end

  def test_review_red_source_fields_cannot_disagree_with_bound_expected_evidence
    stats = strict_text3d_stats
    attempt = stats[:text_attempts][0]
    attempt[:source_anchor] = [99.0, 98.0, 97.0]
    attempt[:source_rotation_radians] = 1.2345
    attempt[:expected_width] = 91.0
    attempt[:expected_height] = 92.0
    attempt[:expected_depth] = 93.0
    attempt[:source_style_sha256] = Digest::SHA256.hexdigest('different-style')
    attempt[:source_geometry_sha256] = Digest::SHA256.hexdigest('different-geometry')
    attempt[:expected_transform] = [2.0, 0.0, 0.0, 2.0, 50.0, 60.0]

    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, text3d_manifest, :text3d, [1]
      )
    end
  end

  def test_review_red_completed_rung_cannot_swap_bound_expected_evidence
    stats = strict_text3d_stats
    rung = stats[:text_attempts][0][:attempt_history][0]
    swapped = Marshal.load(Marshal.dump(rung[:expected_evidence]))
    swapped[:source_anchor] = [99.0, 98.0, 97.0]
    swapped.delete(:evidence_sha256)
    swapped[:evidence_sha256] =
      BlueCollarSystems::PDFVectorImporter::RepresentationFidelity.
        canonical_sha256(swapped)
    rung[:expected_evidence] = swapped

    assert_raises(StandardError) do
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, text3d_manifest, :text3d, [1]
      )
    end
  end

  private

  def label_attempt_with_anchor(source_id, entity_id, digest, source_anchor)
    expected = source_expected_evidence(
      :labels, source_id, 'A',
      :anchor => source_anchor, :rotation_radians => 0.0,
      :width => 0.0, :height => 0.0, :depth => 0.0,
      :geometry_sha256 => nil,
      :style_sha256 => Digest::SHA256.hexdigest('native-label-style')
    )
    {
      :page => 1,
      :source_span_id => source_id,
      :source_text_sha256 => digest,
      :source_anchor => source_anchor,
      :source_rotation_radians => 0.0,
      :requested_mode => :labels,
      :delivered_mode => :labels,
      :resulting_entity_ids => [entity_id],
      :visual_fidelity_verified => true,
      :placement_verified => true,
      :rotation_verified => true,
      :content_verified => true,
      :entity_type_verified => true,
      :expected_evidence => expected,
      :attempt_history => [{
        :mode => :labels, :outcome => :complete,
        :resulting_entity_ids => [entity_id],
        :visual_fidelity_verified => true,
        :placement_verified => true,
        :rotation_verified => true,
        :content_verified => true,
        :entity_type_verified => true,
        :expected_evidence => expected,
        :cleanup_outcome => :not_required
      }]
    }
  end

  def plural_page_claim_stats(mode)
    source_ids = ['text_span:1:0', 'text_span:1:1']
    digest = Digest::SHA256.hexdigest('SAME')
    item_digests = {
      source_ids[0] => digest,
      source_ids[1] => digest
    }
    ready_stats(
      :requested_text_mode => mode,
      :text_source_span_ids => source_ids,
      :text_attempts => [{
        :page => 1, :source_span_ids => source_ids,
        :source_item_text_sha256 => item_digests,
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
        :page => 1, :source_span_ids => source_ids,
        :source_item_text_sha256 => item_digests,
        :requested_mode => mode, :delivered_mode => mode,
        :created_entity_type => mode == :geometry ?
          'page_path_geometry' : 'glyph_outline',
        :visual_fidelity_verified => true,
        :resulting_entity_ids => ['entity_id:13']
      }]
    )
  end


  def source_expected_evidence(mode, source_id, text, values)
    {
      :schema => 'bcs.source_expected/1.0',
      :source_span_id => source_id,
      :representation => mode,
      :source_text_sha256 => Digest::SHA256.hexdigest(text),
      :source_bbox_pdf => [0.0, 0.0, 1.0, 1.0],
      :source_anchor => values[:anchor],
      :source_rotation_radians => values[:rotation_radians],
      :source_font_sha256 => Digest::SHA256.hexdigest('source-font'),
      :expected_width => values[:width],
      :expected_height => values[:height],
      :expected_depth => values[:depth],
      :expected_bounds => nil,
      :expected_transformation => nil,
      :physical_geometry_sha256 => values[:geometry_sha256],
      :physical_style_sha256 => values[:style_sha256],
      :physical_entity_count => 1
    }
  end
end
