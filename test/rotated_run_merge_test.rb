#!/usr/bin/env ruby
# test/rotated_run_merge_test.rb
#
# P0-3 value lock: rotated multi-character runs must merge and order along
# the RUN axis (the reading direction), not raw X/Y. Before this lock, a
# 45-degree diagonal beam label arrived as one fragment per glyph in reverse
# reading order (the owner's scrambled diagonal label class, e.g. "1800"
# rendered as "1 8/0 0" style fragments), because rows were grouped by raw Y
# and ordered by raw X.
#
# TextParser#emit_text stores angle = -atan2(m1, m0) in degrees, so the
# reading direction of a bucket in item space is (cos(-angle), sin(-angle)).

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'

class RotatedRunMergeTest < Minitest::Test
  TP = BlueCollarSystems::PDFVectorImporter::TextParser

  def make_item(text, x, y, angle, font_size = 8.0, span_id = nil)
    item = TP::TextItem.new(text, x, y, font_size, angle, 'F1', font_size)
    item.source_span_id = span_id if span_id
    item
  end

  def parser
    @parser ||= TP.new([], {})
  end

  # One glyph per item along a +45-degree diagonal (stored angle -45 per the
  # emit_text convention), advancing 4pt along the reading direction.
  def diagonal_glyphs(text, angle_deg_stored = -45.0)
    step = 4.0
    dir = -angle_deg_stored * Math::PI / 180.0
    dx = Math.cos(dir) * step
    dy = Math.sin(dir) * step
    items = []
    text.chars.each_with_index do |ch, i|
      items << make_item(ch, 100.0 + (i * dx), 200.0 + (i * dy),
                         angle_deg_stored, 8.0, "text_span:1:#{i}")
    end
    items
  end

  def test_45_degree_multichar_label_merges_to_one_ordered_run
    out = parser.send(:merge_text_runs, diagonal_glyphs('1800'))

    assert_equal 1, out.length,
                 "diagonal label must merge into ONE run (got #{out.map { |t| t.text }.inspect})"
    assert_equal '1800', out.first.text,
                 'diagonal label glyphs must keep exact reading order'
  end

  def test_45_degree_label_single_placement_anchor_and_angle
    items = diagonal_glyphs('1800')
    first = items.first
    out = parser.send(:merge_text_runs, items)

    assert_equal 1, out.length, 'exactly one placement for the diagonal label'
    merged = out.first
    assert_in_delta first.x.to_f, merged.x.to_f, 1e-9,
                    'merged run must anchor at the FIRST glyph in reading order (X)'
    assert_in_delta first.y.to_f, merged.y.to_f, 1e-9,
                    'merged run must anchor at the FIRST glyph in reading order (Y)'
    assert_in_delta(-45.0, merged.angle.to_f, 1e-9,
                    'merged run keeps the source rotation')
    assert_equal 'text_span:1:0', merged.source_span_id,
                 'merged run keeps the leading glyph span identity'
  end

  def test_45_degree_label_full_pipeline_produces_no_phantom_fraction
    # The owner-visible artifact class: scrambled diagonal digits re-glued by
    # fraction heuristics into "1 8/0 0" style text. The full non-strict
    # pipeline stage order must deliver the exact label instead.
    items = diagonal_glyphs('1800')
    out = parser.send(:reconstruct_fractions, items)
    out = parser.send(:merge_text_runs, out)
    out = parser.send(:fix_merged_fractions, out)
    texts = out.map { |t| t.text.to_s }

    assert_includes texts, '1800', "expected exact label, got #{texts.inspect}"
    texts.each do |txt|
      refute_match(/\//, txt, "no phantom fraction may appear (got #{texts.inspect})")
    end
  end

  def test_near_90_degree_order_is_stable_against_x_jitter
    # Reading straight up (stored angle -89.6): raw X is nearly constant with
    # sub-point jitter, so an X-only sort scrambles the glyph order.
    xs = [50.0, 49.98, 50.03]
    items = []
    '750'.chars.each_with_index do |ch, i|
      items << make_item(ch, xs[i], 100.0 + (i * 4.0), -89.6)
    end

    out = parser.send(:merge_text_runs, items)
    assert_equal 1, out.length,
                 "near-vertical label must merge into ONE run (got #{out.map { |t| t.text }.inspect})"
    assert_equal '750', out.first.text,
                 'near-vertical glyph order must follow the run axis, not raw X'
  end

  def test_upside_down_run_reads_along_its_own_axis
    # Stored angle 180: reading direction is (-1, 0), so reading order is
    # DESCENDING raw X.
    items = []
    'ABC'.chars.each_with_index do |ch, i|
      items << make_item(ch, 100.0 - (i * 4.0), 200.0, 180.0)
    end

    out = parser.send(:merge_text_runs, items)
    assert_equal 1, out.length
    assert_equal 'ABC', out.first.text,
                 'upside-down text must merge in its own reading order'
    assert_in_delta 100.0, out.first.x.to_f, 1e-9,
                    'upside-down run anchors at its first glyph'
  end

  def test_horizontal_merge_behavior_is_unchanged
    items = []
    'QUAN'.chars.each_with_index do |ch, i|
      items << make_item(ch, 100.0 + (i * 4.0), 200.0, 0.0)
    end
    # A second, separate row far below must NOT join the first.
    items << make_item('7', 100.0, 100.0, 0.0)

    out = parser.send(:merge_text_runs, items)
    texts = out.map { |t| t.text.to_s }.sort
    assert_equal %w[7 QUAN], texts,
                 'horizontal rows must merge exactly as before the run-frame fix'
    quan = out.find { |t| t.text == 'QUAN' }
    assert_in_delta 100.0, quan.x.to_f, 1e-9
    assert_in_delta 200.0, quan.y.to_f, 1e-9
  end
end
