#!/usr/bin/env ruby
# test/test_text_mode_routing.rb
# Import-dialog text-mode choices lock (BCS-ARCH-001).
#
# Owner-directive fix item 13 (2026-07-13, TEXTMODE-1): this file previously
# re-implemented svg_text?/native_renderer helpers inside the test, so it
# exercised its own copy of the routing logic and locked nothing in main.rb
# (plus one vacuous always-true raster assert). The production-path locks are:
#   * test/textmode1_invariant_test.rb  — requested == delivered OR reported
#     fallback, driven through the shipped QAReport.build_from_stats
#   * test/text_mode_routing_test.rb    — source locks on the shipped routing
#   * test/geometry_builder_text_fallback_test.rb — per-item fallback delivery
# Only the real production assertion is kept here: the dialog's choices.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/import_dialog'

class TextModeDialogChoicesTest < Minitest::Test
  def test_import_dialog_exposes_the_four_text_mode_choices
    dialog = BlueCollarSystems::PDFVectorImporter::ImportDialog
    assert_equal ['Geometry', 'Glyphs', 'Labels', '3D Text'],
                 dialog::TEXT_MODE_CHOICES,
                 'dialog text-mode choices are the BCS-ARCH-001 contract'
  end
end
