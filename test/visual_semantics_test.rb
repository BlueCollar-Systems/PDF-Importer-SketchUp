#!/usr/bin/env ruby
# frozen_string_literal: true

# Ruby parity for the page source semantics profile (phase 2, observe-only).
#
# Mirrors tests/test_visual_semantics.py in the FreeCAD canonical repo. The point is
# not that Ruby "also has a profile" -- it is that all four products agree on the
# vocabulary, the measured limits, and the refusal to claim closed-world accounting.
# A limit only three products enforce is a limit the cross-host matrix cannot rely on.

require 'minitest/autorun'
require 'json'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/visual_semantics'

VS = BlueCollarSystems::PDFVectorImporter::VisualSemantics

class VisualSemanticsTest < Minitest::Test
  PY_CORE = File.expand_path(
    '../../1PDF-Importer-FreeCAD/PDFVectorImporter/pdfcadcore/visual_semantics.py',
    __dir__
  )

  # --- the measured caps -----------------------------------------------------

  def test_resolved_object_cap_is_the_retuned_value
    # Measured max across 270 corpus pages was 904 (recursive, depth 8).
    # 128 was exceeded 7.1x by ordinary map sheets.
    assert_equal 4096, VS::CAP_RESOLVED_OBJECTS
    assert VS::CAP_RESOLVED_OBJECTS > 904 * 4
  end

  def test_decoded_byte_cap_has_real_headroom
    # Measured max 7,329,808 -- the old 8 MiB cap left only 12.6% margin.
    assert_equal 16 * 1024 * 1024, VS::CAP_DECODED_BYTES
    assert VS::CAP_DECODED_BYTES > 7_329_808 * 2
  end

  def test_token_and_annotation_caps_are_unchanged
    assert_equal 1_000_000, VS::CAP_OPERATOR_TOKENS
    assert_equal 2048, VS::CAP_ANNOTATIONS
    assert_equal 8, VS::CAP_FORM_DEPTH
  end

  # --- honesty ---------------------------------------------------------------

  def test_schema_is_versioned_and_matches_python
    assert_equal 'bcs.page_source_semantics/2.0', VS::SCHEMA
    assert_equal VS::SCHEMA, VS.new_profile['schema']
  end

  def test_accounting_mode_is_feature_detection_not_closed_world
    p = VS.new_profile
    assert_equal VS::ACCOUNTING_FEATURE_DETECTION, p['accounting_mode']
    refute p['closed_world']
  end

  def test_scan_status_can_never_be_complete
    p = VS.new_profile(scan_status: 'complete')
    assert VS.validate_profile(p).any? { |v| v.include?('complete') },
           'a feature-detection profile must not claim a complete closed-world scan'
  end

  def test_closed_world_claim_is_rejected
    p = VS.new_profile
    p['accounting_mode'] = 'closed_world'
    assert VS.validate_profile(p).any? { |v| v.include?('closed_world') }
  end

  def test_partial_profile_is_never_native_eligible
    p = VS.new_profile(scan_status: 'partial', visible_feature_codes: [])
    refute VS.profile_is_native_eligible?(p),
           'absence of detected features is not proof of completeness'
  end

  def test_routing_field_smuggled_in_is_rejected
    p = VS.new_profile
    p['effective_strategy'] = 'native'
    assert VS.validate_profile(p).any? { |v| v.include?('effective_strategy') }
  end

  # --- shape -----------------------------------------------------------------

  def test_legal_profile_validates_clean
    assert_empty VS.validate_profile(VS.new_profile)
    assert_empty VS.validate_profile(
      VS.new_profile(visible_feature_codes: ['pdf_shading_paint'])
    )
  end

  def test_unknown_feature_code_is_rejected
    p = VS.new_profile(visible_feature_codes: ['pdf_not_a_real_code'])
    assert VS.validate_profile(p).any? { |v| v.include?('pdf_not_a_real_code') }
  end

  def test_feature_codes_are_sorted_and_unique
    p = VS.new_profile(visible_feature_codes:
      %w(pdf_shading_paint pdf_shading_paint pdf_non_normal_blend))
    assert_equal %w(pdf_non_normal_blend pdf_shading_paint), p['visible_feature_codes']
  end

  # --- reason-code split -----------------------------------------------------

  def test_record_limit_breaches_flags_the_right_axis
    p = VS.new_profile(resolved_objects: VS::CAP_RESOLVED_OBJECTS + 1)
    VS.record_limit_breaches(p)
    assert_equal ['resolved_objects'], p['limit_breaches']
    assert_equal 'resource_budget_incomplete', p['status_code']
    assert_equal 'incomplete', p['scan_status']
    assert_empty VS.validate_profile(p)
  end

  def test_within_budget_page_is_not_flagged
    # The measured corpus maxima must all sit inside the re-tuned caps.
    p = VS.new_profile(resolved_objects: 904, decoded_bytes: 7_329_808,
                       operator_tokens: 753_271, annotation_entries: 1)
    VS.record_limit_breaches(p)
    assert_empty p['limit_breaches'],
                 'the re-tuned caps must clear every measured corpus page'
    assert_equal 'partial', p['scan_status']
  end

  # --- cross-language parity -------------------------------------------------

  def test_caps_match_the_python_core
    skip "python core not present at #{PY_CORE}" unless File.file?(PY_CORE)
    py = File.read(PY_CORE)
    {
      'CAP_FORM_DEPTH' => VS::CAP_FORM_DEPTH,
      'CAP_RESOLVED_OBJECTS' => VS::CAP_RESOLVED_OBJECTS,
      'CAP_OPERATOR_TOKENS' => VS::CAP_OPERATOR_TOKENS,
      'CAP_ANNOTATIONS' => VS::CAP_ANNOTATIONS
    }.each do |name, ruby_value|
      m = py[/^#{name}\s*=\s*([0-9_]+)/, 1]
      refute_nil m, "#{name} not found in the Python core"
      assert_equal m.delete('_').to_i, ruby_value,
                   "#{name} diverged between the Ruby port and the Python core"
    end
    # Byte cap is written as an expression in both languages.
    assert_match(/CAP_DECODED_BYTES\s*=\s*16 \* 1024 \* 1024/, py)
  end

  def test_vocabularies_match_the_python_core
    skip "python core not present at #{PY_CORE}" unless File.file?(PY_CORE)
    py = File.read(PY_CORE)
    { 'SCAN_STATUSES' => VS::SCAN_STATUSES,
      'STATUS_CODES' => VS::STATUS_CODES,
      'VISIBLE_FEATURE_CODES' => VS::VISIBLE_FEATURE_CODES,
      'ROUTING_FIELDS' => VS::ROUTING_FIELDS }.each do |name, ruby_values|
      py_name = name == 'ROUTING_FIELDS' ? '_ROUTING_FIELDS' : name
      block = py[/^#{py_name} = \((.*?)\)/m, 1]
      refute_nil block, "#{py_name} not found in the Python core"
      # Strip comments first: these tuples carry explanatory comments that contain
      # quoted phrases, which a naive scan would read as vocabulary entries.
      code_only = block.lines.map { |line| line.sub(/#.*/, '') }.join
      python_values = code_only.scan(/"([^"]+)"/).flatten
      assert_equal python_values.sort, ruby_values.sort,
                   "#{name} diverged between the Ruby port and the Python core"
    end
  end
end
