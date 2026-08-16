#!/usr/bin/env ruby
# test/svg_3d_text_whitespace_span_test.rb
#
# A text span whose content is entirely whitespace has no glyph outline; no host can
# extrude a space into a 3D solid. Before this change such spans reached
# build_filled_glyph, raised 'source span produced no filled face', were classified as
# the catch-all host_3d_text_exception (a STOP reason), and the fidelity contract --
# correctly -- refused to descend and failed the whole page. text_heavy_tracemonkey
# carries 5,546 such spans (41% of 13,377) and failed on the first two it met.
#
# The correct treatment is an AFFIRMATIVE item-specific impossibility
# (source_vector_geometry_absent) recorded before any host call, so the ladder may
# lawfully advance. These tests pin the predicate, the proof shape (which the
# FallbackController validates strictly), and that non-whitespace spans are untouched.
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/representation_fidelity'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer'

class Svg3DTextWhitespaceSpanTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer
  RF = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity

  Item = Struct.new(:text, :source_span_id)

  def item(text)
    Item.new(text, 'text_span:10:80')
  end

  # --- predicate ------------------------------------------------------------------

  def test_single_space_is_whitespace_only
    assert R.whitespace_only_item?(item(' ')), 'the tracemonkey 10:80 / 10:82 case'
  end

  def test_multiple_and_unicode_spaces_are_whitespace_only
    ["  ", "\t", " \t ", " ", "  ", "​", "　"].each do |t|
      assert R.whitespace_only_item?(item(t)), "expected whitespace-only for #{t.inspect}"
    end
  end

  def test_empty_text_is_not_treated_as_whitespace
    # Empty text is a different case (identity/inventory), and must keep its own path.
    refute R.whitespace_only_item?(item(''))
  end

  def test_real_text_is_not_whitespace_only
    ['a', 'TraceMonkey', ' must ', '.', " x"].each do |t|
      refute R.whitespace_only_item?(item(t)), "expected NOT whitespace-only for #{t.inspect}"
    end
  end

  def test_predicate_never_raises_on_bad_items
    refute R.whitespace_only_item?(nil)
    refute R.whitespace_only_item?(Object.new)
  end

  # --- proof shape (must satisfy the FallbackController's strict validator) ----------

  def build_proof
    R.whitespace_only_proof('text_span:10:80', item(' '), 0.015625,
                            { renderer: 'poppler' })
  end

  def test_proof_is_affirmative_and_item_scoped
    p = build_proof
    assert_equal true, p[:affirmative_impossibility]
    assert_equal false, p[:generic_failure]
    assert_equal :item, p[:scope]
    assert_equal :exact_representation_impossible, p[:category]
  end

  def test_proof_uses_an_approved_affirmative_reason_code
    p = build_proof
    assert_equal :source_vector_geometry_absent, p[:reason_code]
    assert_includes RF::AFFIRMATIVE_REASON_CODES, p[:reason_code]
    refute_includes RF::STOP_REASON_CODES, p[:reason_code]
  end

  def test_proof_advances_exactly_one_rung_from_text3d
    p = build_proof
    assert_equal :text3d, p[:from_mode]
    assert_equal :glyphs, p[:to_mode]
    ladder = RF::LADDERS[:text3d]
    assert_equal ladder[ladder.index(:text3d) + 1], p[:to_mode]
  end

  def test_proof_carries_checkable_evidence_and_no_host_side_effects
    p = build_proof
    assert_equal [], p[:created_entity_ids]
    assert_equal [], p[:cleaned_entity_ids]
    assert_equal :not_required, p[:cleanup_outcome]
    ev = p[:evidence]
    assert_equal 1, ev[:source_text_length]
    assert_equal ['U+0020'], ev[:source_text_codepoints]
    assert_match(/no host call attempted/, ev[:verification])
  end

  def test_proof_is_accepted_by_the_fallback_controller
    # The load-bearing check: the FallbackController is the sole authority that may
    # advance the ladder, and it validates every field. If it accepts this proof,
    # a whitespace span lawfully descends text3d -> glyphs.
    controller = RF::FallbackController.new(:text3d, 'text_span:10:80')
    assert_equal :text3d, controller.current_mode
    controller.advance!(build_proof)
    assert_equal :glyphs, controller.current_mode
    assert_equal 1, controller.transitions.length
  end
end
