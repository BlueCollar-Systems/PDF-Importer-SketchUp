#!/usr/bin/env ruby

require_relative 'representation_fidelity_contract_test'

class Native3DTextSubstitutionContractTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  GB = IMP::GeometryBuilder
  TI = IMP::TextParser::TextItem

  def source_item(font_name, source_id)
    TI.new(
      'WELD', 20.0, 30.0, 9.0, 0.0, font_name, nil,
      20.0, 30.0, 44.0, 39.0, nil, source_id
    )
  end

  def builder
    GB.new(
      nil, [], [], [0, 0, 612, 792],
      :import_text => true,
      :use_3d_text => true,
      :requested_text_mode => :text3d,
      :page_number => 1,
      :native_3d_text_font_candidates => ['Arial']
    )
  end

  def assert_resource_key_uses_truthful_arial_substitute(resource_key, source_id)
    subject = builder
    entities = FidelityEntities.new

    assert subject.send(
      :place_mesh_text, entities, source_item(resource_key, source_id),
      0.0, 0.0, nil
    ), "#{resource_key} must still deliver requested 3D Text"

    attempt = subject.text_attempts.fetch(0)
    rung = attempt[:attempt_history].fetch(0)
    assert_equal :text3d, attempt[:delivered_mode]
    assert_equal 'Arial', attempt[:native_font_family_argument]
    assert_equal :configured_free_substitute, attempt[:font_candidate_source]
    assert_equal false, attempt[:source_font_equivalence]
    assert_equal true, attempt[:font_substitution_applied]
    assert_equal false, attempt[:font_identity_verified]
    assert_equal 'Arial', rung[:native_font_family_argument]
    refute_equal resource_key, attempt[:native_font_family_argument]
    refute attempt.key?(:installed_family)
    refute attempt.key?(:pdf_font_identity)
  end

  def test_pdf_resource_key_f1_uses_same_rung_arial_substitute
    assert_resource_key_uses_truthful_arial_substitute('F1', 'text_span:1:0')
  end

  def test_pdftotext_marker_uses_same_rung_arial_substitute
    assert_resource_key_uses_truthful_arial_substitute(
      'pdftotext', 'text_span:1:1'
    )
  end
end
