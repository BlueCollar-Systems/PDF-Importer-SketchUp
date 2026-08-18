#!/usr/bin/env ruby

require 'minitest/autorun'
require 'digest'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'tools', 'sketchup_host_evidence')

class LabelsVisualEquivalentHostAcceptanceTest < Minitest::Test
  FIDELITY = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
  EXPECTED_COUNT = 791
  SIZE_COUNT = 653
  ROTATION_COUNT = 138

  def test_exact_reopened_labels_visual_equivalent_census_is_accepted
    stats, reopened = acceptance_fixture

    census = verify_or_nil(stats, reopened)

    assert_equal({
      'schema' => 'bcs.labels_visual_equivalent_acceptance/1.0',
      'requested_mode' => 'labels',
      'reopened_sketchup_text_count' => 0,
      'reopened_raster_count' => 0,
      'source_glyph_3d_delivery_count' => EXPECTED_COUNT,
      'unique_source_span_count' => EXPECTED_COUNT,
      'unique_persistent_id_count' => EXPECTED_COUNT,
      'unique_provenance_id_count' => EXPECTED_COUNT,
      'labels_to_text3d_transition_count' => EXPECTED_COUNT,
      'label_source_size_transition_count' => SIZE_COUNT,
      'label_rotation_transition_count' => ROTATION_COUNT,
      'filled_visible_faces_verified' => true,
      'persisted_hidden_contour_edges_verified' => true,
      'external_live_gates_required' => [
        'import_elapsed_seconds_lte_30',
        'fixed_frame_side_by_side_no_visible_difference'
      ]
    }, census)
  end

  def test_reopened_census_rejects_native_text_and_raster
    stats, reopened = acceptance_fixture
    reopened.first['children'] = [manifest_leaf('Text')]
    assert_contract_rejected(stats, reopened, /Text|native/i)

    stats, reopened = acceptance_fixture
    stats[:raster_delivery_records] = [{ :source_span_id => 'text_span:1:0' }]
    assert_contract_rejected(stats, reopened, /raster/i)
  end

  def test_reopened_census_rejects_duplicate_or_mismatched_identity
    stats, reopened = acceptance_fixture
    stats[:source_provenance_objects][1][:resulting_entity_ids] =
      stats[:source_provenance_objects][0][:resulting_entity_ids].dup
    assert_contract_rejected(stats, reopened, /duplicate|one-to-one|identity/i)

    stats, reopened = acceptance_fixture
    reopened[1]['persistent_id'] = reopened[0]['persistent_id']
    assert_contract_rejected(stats, reopened, /duplicate|persistent/i)

    stats, reopened = acceptance_fixture
    reopened[0]['representation_evidence']['source_text_sha256'] = 'f' * 64
    assert_contract_rejected(stats, reopened, /SHA|digest|source text/i)
  end

  def test_reopened_census_rejects_wrong_transition_accounting
    stats, reopened = acceptance_fixture
    stats[:text_attempts][0][:attempt_history][0][:reason] =
      'label_rotation_unsupported_by_host'
    assert_contract_rejected(stats, reopened, /653|size|rotation|reason/i)

    stats, reopened = acceptance_fixture
    stats[:fallback_transitions].pop
    assert_contract_rejected(stats, reopened, /transition|791/i)
  end

  def test_acceptance_rejects_unbound_transition_proofs_and_raster_ledgers
    stats, reopened = acceptance_fixture
    stats[:fallback_transitions][0][:reason_code] = :renderer_exception
    assert_contract_rejected(stats, reopened, /transition|host representation/i)

    stats, reopened = acceptance_fixture
    stats[:text_attempts][0][:attempt_history][0][
      :transition_proof
    ][:source_span_id] = 'text_span:1:790'
    assert_contract_rejected(stats, reopened, /transition|source|bound/i)

    stats, reopened = acceptance_fixture
    stats[:terminal_text_delivery_records] << {
      :source_span_id => 'text_span:1:0', :delivered_mode => :raster
    }
    assert_contract_rejected(stats, reopened, /raster/i)
  end

  def test_acceptance_rejects_generic_or_reason_mismatched_labels_proof
    stats, reopened = acceptance_fixture
    local = stats[:text_attempts][0][:attempt_history][0][:transition_proof]
    local[:reason_subtype] = :label_rotation_unsupported_by_host
    resign_transition!(local)
    stats[:fallback_transitions][0] = Marshal.load(Marshal.dump(local))
    assert_contract_rejected(stats, reopened, /reason|subtype|size|rotation/i)

    stats, reopened = acceptance_fixture
    [
      stats[:text_attempts][0][:attempt_history][0][:transition_proof],
      stats[:fallback_transitions][0]
    ].each do |proof|
      proof.delete(:reason_subtype)
      proof.delete(:proof_sha256)
      proof[:evidence] = { :source_text_sha256 =>
        proof[:evidence][:source_text_sha256] }
    end
    assert_contract_rejected(stats, reopened, /proof|schema|reason|subtype/i)
  end

  def test_acceptance_rejects_full_payload_global_only_divergence
    stats, reopened = acceptance_fixture
    global = stats[:fallback_transitions][0]
    global[:evidence][:source_anchor][0] += 1.0
    resign_transition!(global)

    assert_contract_rejected(stats, reopened, /global|ledger|bound|payload/i)
  end

  def test_reopened_census_requires_visible_materialized_faces_and_hidden_edges
    stats, reopened = acceptance_fixture
    readback = reopened[0]['style_evidence']['visual_readback']
    readback['visible_edge_count'] = 1
    readback['hidden_edge_count'] = readback['edge_count'] - 1
    readback['all_contour_edges_hidden'] = false
    assert_contract_rejected(stats, reopened, /edge|contour/i)

    stats, reopened = acceptance_fixture
    readback = reopened[0]['style_evidence']['visual_readback']
    readback['materialized_visible_face_count'] = 0
    assert_contract_rejected(stats, reopened, /face|material|fill/i)

    stats, reopened = acceptance_fixture
    reopened[0]['representation_evidence'].delete('contour_edge_policy')
    assert_contract_rejected(stats, reopened, /policy|govern|contour/i)

    stats, reopened = acceptance_fixture
    reopened[0]['representation_evidence']['contour_edge_count'] = 7
    assert_contract_rejected(stats, reopened, /edge|count|readback/i)

    stats, reopened = acceptance_fixture
    reopened[0]['style_evidence']['visual_readback'][
      'root_layer_visible'
    ] = false
    assert_contract_rejected(stats, reopened, /layer|visible|readback/i)
  end

  def test_reopened_census_requires_exact_opaque_untextured_source_ink
    {
      :wrong_color => lambda do |row|
        row['style_evidence']['material']['color']['red'] = 255
      end,
      :transparent => lambda do |row|
        row['style_evidence']['material']['alpha'] = 0.0
      end,
      :textured => lambda do |row|
        row['style_evidence']['material']['texture_present'] = true
      end
    }.each do |kind, mutate|
      stats, reopened = acceptance_fixture
      mutate.call(reopened[0])
      assert_contract_rejected(
        stats, reopened, /ink|material|color|alpha|texture|opaque/i
      )
    end
  end

  def test_reopened_source_claim_roots_must_be_ancestry_disjoint
    stats, reopened = acceptance_fixture
    nested = reopened.pop
    reopened[0]['children'] << nested

    assert_contract_rejected(stats, reopened, /nested|ancestor|claim root/i)
  end

  private

  def verify_or_nil(stats, reopened)
    return nil unless SketchupHostEvidence.respond_to?(
      :verify_labels_visual_equivalent_acceptance!
    )
    SketchupHostEvidence.verify_labels_visual_equivalent_acceptance!(
      stats, reopened
    )
  end

  def assert_contract_rejected(stats, reopened, pattern)
    error = assert_raises(SketchupHostEvidence::EvidenceError) do
      if SketchupHostEvidence.respond_to?(
        :verify_labels_visual_equivalent_acceptance!
      )
        SketchupHostEvidence.verify_labels_visual_equivalent_acceptance!(
          stats, reopened
        )
      end
    end
    assert_match(pattern, error.message)
  end

  def acceptance_fixture
    spans = []
    attempts = []
    provenance = []
    transitions = []
    reopened = []
    EXPECTED_COUNT.times do |index|
      source_id = "text_span:1:#{index}"
      persistent_id = 10_000 + index
      identity = "persistent_id:#{persistent_id}"
      digest = Digest::SHA256.hexdigest("source-#{index}")
      reason = index < SIZE_COUNT ?
        'label_source_size_unsupported_by_host' :
        'label_rotation_unsupported_by_host'
      proof = transition_proof(source_id, digest, reason, index)
      expected = {
        :source_span_id => source_id,
        :source_text_sha256 => digest,
        :representation => :text3d,
        :evidence_sha256 => Digest::SHA256.hexdigest("evidence-#{index}")
      }
      spans << source_id
      attempts << {
        :source_span_id => source_id,
        :source_text_sha256 => digest,
        :requested_mode => :labels,
        :delivered_mode => :text3d,
        :renderer => :svg_source_3d_text,
        :resulting_entity_ids => [identity],
        :expected_evidence => expected,
        :attempt_history => [{
          :mode => :labels, :outcome => :failed, :reason => reason,
          :resulting_entity_ids => [], :transition_proof => proof
        }, {
          :mode => :text3d, :outcome => :complete,
          :resulting_entity_ids => [identity],
          :visual_fidelity_verified => true,
          :expected_evidence => expected
        }]
      }
      provenance << {
        :object_id => source_id, :span_id => source_id,
        :created_entity_type => 'source_glyph_3d_text',
        :renderer => 'svg_source_3d_text',
        :resulting_entity_ids => [identity],
        :expected_evidence => expected
      }
      transitions << Marshal.load(Marshal.dump(proof))
      reopened << manifest_claim(
        index + 1, persistent_id, source_id, digest,
        expected[:evidence_sha256]
      )
    end
    [{
      :requested_text_mode => :labels,
      :text_source_span_ids => spans,
      :text_attempts => attempts,
      :source_provenance_objects => provenance,
      :fallback_transitions => transitions,
      :page_text_delivery_records => [],
      :terminal_text_delivery_records => [],
      :raster_delivery_records => [],
      :inline_image_page_raster_fallbacks => [],
      :page_representation_fallbacks => [],
      :raster_fallback_used => false
    }, reopened]
  end

  def transition_proof(source_id, digest, reason, index)
    rotated = reason == 'label_rotation_unsupported_by_host'
    rotation_degrees = rotated ? 90.0 : 0.0
    proof_subtype = rotated ?
      'source_glyph_rotation_unsupported' :
      'finite_bbox_source_size_run_width_unsupported'
    evidence = {
      :schema => 'bcs.sketchup_labels_capability/1.0',
      :proof_subtype => proof_subtype,
      :source_span_id => source_id,
      :requested_mode => :labels,
      :source_text_sha256 => digest,
      :source_bbox_pdf => [0.0, 0.0, 72.0, 12.0],
      :source_dimensions_pdf => [72.0, 12.0],
      :source_anchor => [index.to_f / 72.0, 0.0, 0.0],
      :source_rotation_degrees => rotation_degrees,
      :source_rotation_radians => rotation_degrees * Math::PI / 180.0,
      :pdf_point_to_inch => 1.0 / 72.0,
      :import_scale => 1.0,
      :expected_width => 1.0,
      :expected_height => 1.0 / 6.0,
      :host_product => 'SketchUp',
      :host_api_contract => 'SketchUp 2017 Ruby API',
      :host_entity_type => 'Sketchup::Text',
      :host_constructor => 'Sketchup::Entities#add_text',
      :native_label_finite_bbox_control_available => false,
      :native_label_run_width_control_available => false,
      :native_label_glyph_rotation_control_available => false,
      :text_vector_role => 'leader_vector',
      :capability_observation_only => true,
      :host_api_fact => rotated ?
        'Text vector controls the leader and does not rotate label glyphs' :
        'Sketchup::Text exposes neither glyph-size nor source run-width control',
      :verification => rotated ?
        'source rotation is nonzero and native label orientation is unsupported' :
        'native annotation width and height cannot be matched to the source PDF'
    }
    evidence[:evidence_sha256] = FIDELITY.canonical_sha256(evidence)
    proof = {
      :source_span_id => source_id,
      :importer_id => FIDELITY::IMPORTER_ID,
      :page_number => 1,
      :requested_mode => :labels,
      :from_mode => :labels, :to_mode => :text3d,
      :scope => :item, :category => :exact_representation_impossible,
      :affirmative_impossibility => true, :generic_failure => false,
      :reason_code => :host_representation_unsupported,
      :reason_subtype => reason.to_sym,
      :attempted_renderer => 'sketchup_native_text',
      :created_entity_ids => [], :cleaned_entity_ids => [],
      :cleanup_outcome => :not_required,
      :evidence => evidence
    }
    resign_transition!(proof)
  end

  def resign_transition!(proof)
    evidence = proof[:evidence]
    if evidence.is_a?(Hash) && evidence.key?(:evidence_sha256)
      unsigned_evidence = evidence.dup
      unsigned_evidence.delete(:evidence_sha256)
      evidence[:evidence_sha256] = FIDELITY.canonical_sha256(unsigned_evidence)
    end
    unsigned = proof.dup
    unsigned.delete(:proof_sha256)
    unsigned.delete(:page)
    proof[:proof_sha256] = FIDELITY.canonical_sha256(unsigned)
    proof
  end

  def manifest_claim(entity_id, persistent_id, source_id, digest, evidence_sha)
    {
      'entity_id' => entity_id, 'persistent_id' => persistent_id,
      'typename' => 'Group', 'valid' => true, 'deleted' => false,
      'representation_evidence' => {
        'source_claim_root' => true,
        'source_span_id' => source_id, 'source_kind' => 'text_span',
        'representation' => 'text3d', 'renderer' => 'svg_source_3d_text',
        'source_text_sha256' => digest,
        'source_evidence_sha256' => evidence_sha,
        'source_ink_material_owned' => true,
        'source_ink_material_name' => 'PDF_0_0_0',
        'source_ink_rgb' => [0, 0, 0],
        'source_ink_alpha' => 1.0,
        'source_ink_color_readback_verified' => true,
        'source_ink_alpha_readback_verified' => true,
        'source_ink_texture_absent_verified' => true,
        'contour_edge_policy' => 'persisted_hidden',
        'contour_edge_count' => 8,
        'contour_edges_hidden_verified' => true,
        'fixed_frame_style_policy' =>
          'source_outline_filled_faces_with_hidden_contour_edges'
      },
      'style_evidence' => {
        'entity_visible' => true, 'layer_visible' => true,
        'material' => {
          'name' => 'PDF_0_0_0',
          'color' => { 'red' => 0, 'green' => 0, 'blue' => 0 },
          'alpha' => 1.0, 'texture_present' => false
        },
        'visual_readback' => {
          'edge_count' => 8, 'hidden_edge_count' => 8,
          'visible_edge_count' => 0, 'all_contour_edges_hidden' => true,
          'face_count' => 6, 'visible_face_count' => 6,
          'materialized_visible_face_count' => 6,
          'root_entity_visible' => true, 'root_layer_visible' => true
        }
      },
      'children' => []
    }
  end

  def manifest_leaf(type)
    {
      'entity_id' => 900_001, 'persistent_id' => 990_001,
      'typename' => type, 'valid' => true, 'deleted' => false,
      'children' => []
    }
  end
end
