#!/usr/bin/env ruby
# test/qa_report_affirmative_transition_test.rb
#
# Owner ruling 2026-08-15: on SketchUp, text -> text3d is the CORRECT rung, not a
# degradation. The host exposes no flat editable model-text constructor
# (RepresentationFidelity::FLAT_TEXT_HOST_API_FACT), so every text span's ladder
# advance carries an affirmative host_representation_unsupported proof.
#
# Before this ruling the report labeled that transition degraded, which (a) inflated
# the warnings count by one per page, (b) set fallback.used=true, and (c) emitted
# text_degraded_svg_unavailable -- an ENVIRONMENT-fault reason code -- for a host
# CAPABILITY fact. On 1011/text that meant 791 spans reported as degraded for years of
# runs while acceptance said OK. These tests pin the corrected semantics and, just as
# importantly, that genuine degradation is still reported as degradation.
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

class QAReportAffirmativeTransitionTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::QAReport

  def affirmative_renderer
    { page: 1, renderer: :svg_source_3d_text, mode: :text3d,
      requested_mode: :text, delivered_mode: :text3d,
      degraded: false, affirmative_transition: true,
      affirmative_transition_reason_code: :host_representation_unsupported,
      reason: 'affirmative item-specific requested-representation impossibility',
      count: 791 }
  end

  def genuinely_degraded_renderer
    { page: 1, renderer: :labels, mode: :labels,
      requested_mode: :text3d, delivered_mode: :labels,
      degraded: true, note: 'Poppler/MuPDF not found', count: 12 }
  end

  def build(renderers)
    stats = { text_renderers: renderers, pipeline_performance: {}, elapsed_seconds: 1.0 }
    R.build_from_stats('x.pdf', {}, stats)
  end

  def test_affirmative_text_to_text3d_is_not_fallback
    report = build([affirmative_renderer])
    fb = report[:fallback]
    assert_equal false, fb[:used], 'a certified affirmative transition is delivered representation, not fallback'
    assert_nil fb[:reason]
    refute_equal 'text_degraded_svg_unavailable', fb[:reason],
                 'environment-fault reason code must not describe a host capability fact'
  end

  def test_affirmative_transition_is_still_visible_to_the_reader
    fb = build([affirmative_renderer])[:fallback]
    at = fb[:affirmative_transitions]
    refute_nil at, 'the reader must be able to see the host chose an adjacent rung'
    assert_equal 1, at.length
    assert_equal 'text', at.first[:requested_mode]
    assert_equal '3d_text', at.first[:delivered_mode]
    assert_equal 'host_representation_unsupported', at.first[:reason_code]
    assert_equal 791, at.first[:count]
    assert_equal false, at.first[:degraded]
  end

  def test_affirmative_transition_does_not_count_as_a_warning
    with = build([affirmative_renderer])
    without = build([])
    assert_equal without[:result][:warnings], with[:result][:warnings],
                 'a correct rung must not inflate the warnings count'
  end

  def test_genuine_degradation_is_still_reported_as_degradation
    # The ruling must not blind the report to real environment faults.
    report = build([genuinely_degraded_renderer])
    fb = report[:fallback]
    assert_equal true, fb[:used]
    assert_equal 'text_degraded_missing_svg_renderer', fb[:reason]
    assert_nil fb[:affirmative_transitions]
    assert report[:result][:warnings] >= 1
  end

  def test_mixed_page_separates_the_two
    fb = build([affirmative_renderer, genuinely_degraded_renderer])[:fallback]
    assert_equal true, fb[:used], 'the genuine degradation still governs used/reason'
    assert_equal 'text_degraded_missing_svg_renderer', fb[:reason]
    # ...while the affirmative one is NOT folded into the degraded set
    # (only the degraded renderer contributes to warnings/reason).
  end

  def test_no_transition_when_text3d_was_requested
    r = affirmative_renderer.merge(requested_mode: :text3d, affirmative_transition: false,
                                   affirmative_transition_reason_code: nil, reason: nil)
    fb = build([r])[:fallback]
    assert_equal false, fb[:used]
    assert_nil fb[:affirmative_transitions]
  end
end
