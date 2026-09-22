#!/usr/bin/env ruby
# A page's content streams are one stream, and the graphics state spans them.
#
# PDF 32000-1 7.8.2: "the streams shall be concatenated to form a single
# stream". A `q` opened in one content stream is closed by a `Q` in the next.
#
# The parser used to reset @ctm and @gs_stack at the start of EVERY stream, so
# that `Q` found an empty stack, did nothing, and every `cm` translation before
# it leaked into all later text. Measured on a real sheet whose producer split
# the page this way: five `1 0 0 1 0 6.71 cm` operators accumulated to 33.56 pt
# that nothing undid, and every text item came out 33.56 pt from where the
# renderer draws it.
#
# All fixtures are fictional.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/text_parser'

TPX = BlueCollarSystems::PDFVectorImporter::TextParser

class ContentStreamGraphicsStateTest < Minitest::Test
  # One text show at Tm (0,0), so the delivered position IS whatever the
  # graphics state contributes.
  SHOW = "BT /F1 10 Tf 1 0 0 1 0 0 Tm (A) Tj ET\n".freeze

  def positions(streams)
    TPX.new(streams, {}, { :strict_text_fidelity => true, :merge_text_runs => false }, {})
       .parse.map { |i| [i.x.round(3), i.y.round(3)] }
  end

  # ── the bug ──

  def test_a_q_in_one_stream_is_closed_by_a_Q_in_the_next
    # Split exactly as a producer may: the q/cm in one stream, the Q in the
    # next. Concatenated, the translation is undone before the text.
    streams = ["q\n1 0 0 1 0 33.56 cm\n", "Q\n" + SHOW]

    assert_equal [[0.0, 0.0]], positions(streams),
                 'the Q must undo the cm opened in the previous stream'
  end

  def test_an_unclosed_cm_still_applies_to_later_streams
    # The mirror image: no Q at all, so the translation legitimately stands.
    streams = ["1 0 0 1 0 33.56 cm\n", SHOW]

    assert_equal [[0.0, 33.56]], positions(streams)
  end

  def test_the_measured_leak_no_longer_accumulates
    # Five translations then their Q, split across the boundary - the shape of
    # the real sheet.
    cms = (["q\n"] + Array.new(5) { "1 0 0 1 0 6.712 cm\n" }).join
    streams = [cms, "Q\n" + SHOW]

    assert_equal [[0.0, 0.0]], positions(streams),
                 'five leaked translations must not survive the Q'
    refute_equal [[0.0, 33.56]], positions(streams)
  end

  # ── a single stream must behave exactly as before ──

  def test_one_stream_is_unaffected
    assert_equal [[0.0, 0.0]], positions(["q\n1 0 0 1 0 33.56 cm\nQ\n" + SHOW])
    assert_equal [[0.0, 33.56]], positions(["1 0 0 1 0 33.56 cm\n" + SHOW])
  end

  def test_nested_save_and_restore_still_balances
    streams = ["q\n1 0 0 1 5 5 cm\nq\n1 0 0 1 7 7 cm\nQ\n", "Q\n" + SHOW]

    assert_equal [[0.0, 0.0]], positions(streams)
  end

  # ── an unmatched Q must not corrupt the state ──

  def test_an_unmatched_Q_is_survivable
    streams = ["Q\n", "1 0 0 1 0 12.0 cm\n" + SHOW]

    assert_equal [[0.0, 12.0]], positions(streams)
  end

  # ── the state is per parse, not per parser instance reuse ──

  def test_each_parse_starts_from_an_identity_state
    parser = TPX.new(["1 0 0 1 0 50.0 cm\n" + SHOW], {},
                     { :strict_text_fidelity => true, :merge_text_runs => false }, {})
    first = parser.parse.map { |i| i.y.round(3) }
    second = parser.parse.map { |i| i.y.round(3) }

    assert_equal first, second, 'a second parse must not inherit the first'
  end
end
