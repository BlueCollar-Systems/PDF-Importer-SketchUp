#!/usr/bin/env ruby
# test/svg_3d_text_font_gap_attribution_test.rb
#
# A 48x36 markup sheet failed to import with "page renderer/font inventory
# failed; exact source absence is unproven". The page had 291 text items and
# 32,463 paths that had already built successfully. The entire cause was one
# span -- a date stamp -- set in non-embedded base-14 Helvetica, which the
# Windows renderer could not display. poppler reported it by name ("No display
# font for 'Helvetica'"), that set font_inventory_status to :failed, and the
# page-scoped gap then made EVERY span's absence unprovable.
#
# The strict rule exists for a good reason: a page failure must not be mistaken
# for an item-specific fact. But the converse is also true. A gap that NAMES
# the font it is missing is item-attributable evidence -- it says nothing about
# a span set in an embedded face the renderer drew perfectly.
#
# These tests pin both halves: an unaffected span is certifiable, and the span
# that actually uses the missing font is NOT -- that is the guarantee the rule
# was written for and it must survive.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/representation_fidelity'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer'

class Svg3DTextFontGapAttributionTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer
  RF = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity

  SPAN = 'text_span:1:84'.freeze

  def font_gap(names = ['Helvetica'], packs = [])
    [{
      :scope => :page, :page_number => 1,
      :reason_code => :font_inventory_runtime_error,
      :missing_fonts => names, :missing_language_packs => packs
    }]
  end

  def context(failures, render: 'complete')
    binding = RF.proof_binding(SPAN)
    {
      :importer_id => binding[:importer_id],
      :page_number => binding[:page_number],
      :renderer => 'pdftocairo',
      :render_status => render,
      :font_inventory_status => failures.empty? ? 'complete' : 'failed',
      :page_failures => failures
    }
  end

  # --- what a named font gap is, and is not --------------------------------

  def test_a_gap_that_names_fonts_is_item_attributable
    assert R.font_attributable_page_gap?(font_gap)
  end

  def test_a_renderer_runtime_error_names_nothing_an_item_can_be_cleared_against
    failures = [{ :scope => :page, :reason_code => :renderer_runtime_error,
                  :detail => 'exception' }]
    refute R.font_attributable_page_gap?(failures)
  end

  def test_a_language_pack_gap_still_voids_the_page
    # A CID language pack cannot be attributed to a span by font family, so it
    # keeps the strict behaviour.
    refute R.font_attributable_page_gap?(font_gap(['Helvetica'], ['Adobe-GB1']))
    refute R.font_attributable_page_gap?(font_gap([], ['Adobe-GB1']))
  end

  def test_an_evidence_exception_is_not_a_font_name
    # An exception entry inspects to "{:reason=>:evidence_exception}". Treating
    # that as a name would clear every span against a gap naming nothing.
    refute R.font_attributable_page_gap?(
      font_gap(['{:reason=>:evidence_exception}'])
    )
    refute R.font_attributable_page_gap?(font_gap(['   ']))
    refute R.font_attributable_page_gap?([])
  end

  # --- which spans a named gap actually covers ------------------------------

  def test_an_embedded_subset_is_not_covered_by_a_helvetica_gap
    refute R.item_font_in_gap?({ :font_name => 'KVPHMY+Arial' }, font_gap)
    refute R.item_font_in_gap?({ :font_name => 'NNZECN+ArialNarrow' }, font_gap)
  end

  def test_the_span_that_uses_the_missing_font_is_covered
    assert R.item_font_in_gap?({ :font_name => 'Helvetica' }, font_gap)
    assert R.item_font_in_gap?({ :font_name => 'ABCDEF+Helvetica' }, font_gap)
  end

  def test_a_style_variant_of_a_missing_family_is_covered
    # If the renderer cannot display Arial it cannot be trusted for Arial,Bold.
    assert R.item_font_in_gap?({ :font_name => 'Arial,Bold' }, font_gap(['Arial']))
  end

  def test_an_item_that_does_not_say_its_font_stays_strict
    # An unknown font is not evidence of anything.
    assert R.item_font_in_gap?({}, font_gap)
    assert R.item_font_in_gap?({ :font_name => '' }, font_gap)
    assert R.item_font_in_gap?(nil, font_gap)
  end

  # --- the gate itself ------------------------------------------------------

  def test_a_clean_inventory_certifies_absence
    assert_nil R.source_page_failure(SPAN, context([]), { :font_name => 'Arial' })
  end

  def test_an_unaffected_span_survives_a_named_font_gap
    # The regression: this returned a hard failure and aborted the whole sheet.
    assert_nil R.source_page_failure(
      SPAN, context(font_gap), { :font_name => 'KVPHMY+Arial' }
    )
  end

  def test_the_span_using_the_missing_font_is_still_refused
    failure = R.source_page_failure(
      SPAN, context(font_gap), { :font_name => 'Helvetica' }
    )
    refute_nil failure
    assert_equal :source_page_inventory_failed, failure[:reason_code]
    assert_equal false, failure[:affirmative_impossibility]
  end

  def test_a_failed_render_still_voids_every_span
    # Nothing was drawn, so no span's absence means anything.
    refute_nil R.source_page_failure(
      SPAN, context(font_gap, render: 'failed'), { :font_name => 'KVPHMY+Arial' }
    )
  end

  def test_without_an_item_the_gate_keeps_its_original_strictness
    refute_nil R.source_page_failure(SPAN, context(font_gap))
  end

  # --- the message the operator actually reads ------------------------------

  def test_the_failure_names_the_font_that_is_missing
    # The original message said only "page renderer/font inventory failed",
    # which gave the operator nothing to act on.
    failure = R.source_page_failure(
      SPAN, context(font_gap), { :font_name => 'Helvetica' }
    )
    assert_includes failure[:detail], 'Helvetica'
    assert_includes failure[:detail], 'no display font for'
  end

  def test_extractor_and_resource_labels_do_not_prove_a_different_font
    ['pdftotext', 'unknown', 'TT2', 'F12'].each do |name|
      refute_nil R.source_page_failure(SPAN, context(font_gap), { :font_name => name })
    end
  end

  def test_the_message_names_a_missing_language_pack_too
    detail = R.inventory_failure_detail(font_gap(['Helvetica'], ['Adobe-GB1']))
    assert_includes detail, 'Helvetica'
    assert_includes detail, 'Adobe-GB1'
  end

  def test_an_unnamed_gap_still_reads_as_the_plain_failure
    detail = R.inventory_failure_detail(
      [{ :reason_code => :renderer_runtime_error, :detail => 'boom' }]
    )
    assert_includes detail, 'page renderer/font inventory failed'
    refute_includes detail, '('
  end

  # --- evidence shape unchanged --------------------------------------------

  def test_missing_and_mismatched_evidence_still_fail_closed
    assert_equal :source_page_evidence_missing,
                 R.source_page_failure(SPAN, nil, { :font_name => 'Arial' })[:reason_code]
    bad = context(font_gap)
    bad[:page_number] = 99
    assert_equal :source_page_evidence_mismatch,
                 R.source_page_failure(SPAN, bad, { :font_name => 'Arial' })[:reason_code]
  end
end
