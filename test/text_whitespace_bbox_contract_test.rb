#!/usr/bin/env ruby
# Whitespace-only PDF text-show operands have no pdftotext word bbox. Text mode
# still requires a complete source bbox for in-mode certification / ladder
# proofs — synthesize from text-matrix origin + nominal size, never switch mode.

require 'minitest/autorun'
require 'digest'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/representation_fidelity'
require 'bc_pdf_vector_importer/main'

module Sketchup
  def self.version
    '17.2.2555'
  end unless respond_to?(:version)

  class Entities
    def add_text(*_args); end
    def add_3d_text(*_args); end
  end unless const_defined?(:Entities)

  class Text
    def text; end
    def point; end
    def vector; end
    def display_leader?; end
  end unless const_defined?(:Text)
end

class TextWhitespaceBboxContractTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Fidelity = IMP::RepresentationFidelity
  TI = IMP::TextParser::TextItem

  def whitespace_item(text = ' ')
    item = TI.new(
      text, 130.0, 200.0, 10.0, 0.0, '/F6', 10.0,
      nil, nil, nil, nil, nil, 'text_span:1:0'
    )
    item.source_decode_complete = true
    item
  end

  def test_synthesize_source_bbox_from_origin_and_size
    box = IMP.synthesize_source_text_bbox_pdf(whitespace_item('   '))
    assert_equal 4, box.length
    assert box.all? { |v| v.is_a?(Numeric) && v.finite? }
    assert_in_delta 130.0, box[0], 1.0e-9
    assert_in_delta 200.0, box[1], 1.0e-9
    assert box[2] > box[0]
    assert box[3] > box[1]
  end

  def test_ensure_complete_preserves_existing_bbox
    item = TI.new(
      'A', 10.0, 20.0, 12.0, 0.0, 'pdftotext', nil,
      10.0, 20.0, 22.0, 32.0, nil, 'text_span:1:1'
    )
    out = IMP.ensure_complete_source_text_bbox(item)
    assert_same item, out
    assert_equal [10.0, 20.0, 22.0, 32.0],
                 [out.bbox_x0, out.bbox_y0, out.bbox_x1, out.bbox_y1]
  end

  def test_ensure_complete_fills_nil_whitespace_bbox
    out = IMP.ensure_complete_source_text_bbox(whitespace_item)
    refute_nil out.bbox_x0
    refute_nil out.bbox_y0
    refute_nil out.bbox_x1
    refute_nil out.bbox_y1
    assert_equal true, out.source_decode_complete
    assert_equal 'text_span:1:0', out.source_span_id
  end

  def test_strict_source_bbox_accepts_synthesized_whitespace
    filled = IMP.ensure_complete_source_text_bbox(whitespace_item)
    box = Fidelity.strict_source_bbox_pdf(filled)
    assert_equal 4, box.length
    box.each { |v| assert v.finite? }
  end

  def test_prepare_flat_text_fallback_accepts_whitespace_without_poppler_bbox
    filled = IMP.ensure_complete_source_text_bbox(whitespace_item)
    prepared = IMP.prepare_flat_text_fallback_controllers!([filled])
    assert prepared.key?('text_span:1:0')
    proof = prepared['text_span:1:0'][:proof]
    assert_equal :text, proof[:from_mode] || proof.dig(:evidence, :requested_mode)
    assert_equal 4, Array(proof.dig(:evidence, :source_bbox_pdf)).length
  end

  def test_angle_hints_append_whitespace_with_complete_bbox
    external = [
      TI.new('A', 100.0, 200.0, 10.0, 0.0, 'pdftotext', nil,
             100.0, 200.0, 110.0, 212.0, nil)
    ]
    internal = [
      TI.new(' A ', 100.0, 200.0, 10.0, 0.0, 'F1', 10.0,
             nil, nil, nil, nil, nil),
      TI.new(' ', 265.0, 2387.0, 9.75, 0.0, '/F6', 9.75,
             nil, nil, nil, nil, nil)
    ]
    internal[1].source_decode_complete = true
    merged = IMP.apply_internal_text_angle_hints(external, internal)
    ws = merged.find { |item| item.text == ' ' }
    refute_nil ws
    assert IMP.source_text_bbox_complete?(ws),
           'Alvord-style whitespace span must not reach Text proofs with nil bbox'
    Fidelity.strict_source_bbox_pdf(ws)
  end
end
