#!/usr/bin/env ruby
# test/qa_report_text_delivery_phase_test.rb
#
# text_delivery_ms encloses the whole exact-3D-Text branch: the text-family counterpart of
# item_delivery_ms on the glyph path.
#
# Before it existed, text / labels / 3d_text reported item_delivery_ms = 0.0 and carried
# 68-70% of elapsed in unaccounted_ms -- measured on the corpus at pin 3.7.145:
#
#   Alvord/text     429.3 s elapsed, 292.0 s unaccounted (68.0%)
#   Alvord/labels   454.3 s elapsed, 318.4 s unaccounted (70.1%)
#   Alvord/3d_text  418.2 s elapsed, 283.3 s unaccounted (67.7%)
#   1011/text        25.4 s elapsed,   4.8 s unaccounted (18.8%)
#
# text3d_render_ms + text3d_record_ms and their sub-stages covered only ~60 s of that
# ~300 s, so the three slowest cells in the corpus were mostly invisible.
#
# These tests pin the classification. The danger is the one this accounting has already
# been bitten by twice: summing an enclosing timer as a leaf makes unaccounted_ms shrink
# toward zero and hides the incompleteness it exists to expose.
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

class QAReportTextDeliveryPhaseTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::QAReport

  def split(stats)
    R.send(:split_pipeline_performance, stats)
  end

  # Shaped like the Alvord text cell: a large enclosing text_delivery_ms with the two
  # already-parented text3d spans inside it, plus one unrelated leaf.
  def alvord_shaped_stats
    {
      :pipeline_performance => {
        :total_ms          => 429_300.0,
        :page_total_ms     => 334_300.0,
        :text_delivery_ms  => 300_000.0,
        :text3d_render_ms  =>  18_400.0,
        :text3d_record_ms  =>  21_700.0,
        :text_extract_ms   =>   4_800.0
      }
    }
  end

  def test_text_delivery_ms_is_declared_a_parent
    assert_includes R::PHASE_PARENTS, :text_delivery_ms,
                    'text_delivery_ms encloses the text3d spans and must be a parent'
  end

  def test_text_delivery_ms_is_a_known_key_so_it_is_not_reported_as_drift
    # The unclassified bucket exists to catch new *_ms keys whose parentage nobody
    # declared. A key that is a declared parent must also be a known key, or it shows up
    # as drift on every run.
    assert_includes R::KNOWN_PHASE_LEAVES, :text_delivery_ms
  end

  def test_it_appears_in_the_phase_table
    phases, = split(alvord_shaped_stats)
    assert_in_delta 300_000.0, phases[:text_delivery_ms], 0.001
  end

  def test_it_is_not_summed_as_a_leaf
    phases, _unclassified, aggregates, = split(alvord_shaped_stats)
    assert_includes aggregates, :text_delivery_ms,
                    'must be reported as an aggregate, not a leaf'
    leaf_sum = phases.reject { |k, _| aggregates.include?(k) }
                     .values.inject(0.0) { |a, b| a + b }
    refute_in_delta 300_000.0, leaf_sum, 1.0,
                    'the enclosing span must not contribute to the leaf sum'
  end

  def test_it_is_not_reported_as_unclassified
    _phases, unclassified, = split(alvord_shaped_stats)
    refute_includes Array(unclassified), :text_delivery_ms
  end

  def test_children_do_not_exceed_the_declared_parent
    # Sanity on the nesting claim itself: text3d_render_ms + text3d_record_ms are inside
    # text_delivery_ms, so together they cannot exceed it on well-formed data.
    stats = alvord_shaped_stats[:pipeline_performance]
    children = stats[:text3d_render_ms] + stats[:text3d_record_ms]
    assert_operator children, :<=, stats[:text_delivery_ms]
  end

  def test_absent_span_is_absent_not_zero
    # Glyph/geometry/raster modes never enter the branch. The phase must then be missing
    # rather than present as 0.0, which would read as "measured and free".
    phases, = split(:pipeline_performance => { :item_delivery_ms => 500_400.0 })
    refute phases.key?(:text_delivery_ms)
  end
end
