#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/primitives'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/dimension_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/resolved_scale'

class ResolvedScaleTest < Minitest::Test
  M = BlueCollarSystems::PDFVectorImporter

  def page_with_text(raw, insertion, tags = [])
    txt = M::NormalizedText.new(
      1, raw, raw.upcase, insertion, nil, 0.12, 0.0, 'Arial', 1, tags
    )
    M::PageData.new(1, 36.0, 24.0, [], [txt], [], [])
  end

  def test_ratio_scale_1_to_50
    page = page_with_text('SCALE 1:50', [30.0, 4.0], [:scale_like, :titleblock_like])
    scale = M::ResolvedScaleDetect.resolve(page)
    assert scale.confidence > 0.7
    assert_in_delta 50.0, scale.factor, 0.01
  end

  def test_architectural_scale_quarter_inch
    page = page_with_text('1/4" = 1\'-0"', [30.0, 3.0], [:scale_like, :titleblock_like])
    scale = M::ResolvedScaleDetect.resolve(page)
    assert scale.confidence > 0.7
    assert_in_delta 48.0, scale.factor, 0.5
  end

  def test_default_when_no_scale_text
    page = M::PageData.new(1, 36.0, 24.0, [], [], [], [])
    scale = M::ResolvedScaleDetect.resolve(page)
    assert_equal 1.0, scale.factor
    assert_equal 'no_scale_detected', scale.fallback_reason
  end

  def test_merge_best_keeps_higher_confidence
    low = M::ResolvedScale.new(1.0, '1:1', 'default', 0.0, 'no_scale_detected')
    high = M::ResolvedScale.new(50.0, '1:50', 'titleblock', 0.9, nil)
    merged = M::ResolvedScaleDetect.merge_best(
      M::ResolvedScaleDetect.to_hash(low),
      high
    )
    assert_in_delta 50.0, merged[:factor], 0.01
  end
end
