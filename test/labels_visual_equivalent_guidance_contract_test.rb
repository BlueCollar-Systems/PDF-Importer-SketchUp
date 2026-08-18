#!/usr/bin/env ruby

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
require File.join(
  REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer',
  'qa_report'
)
require File.join(
  REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer',
  'import_dialog'
)

class LabelsVisualEquivalentGuidanceContractTest < Minitest::Test
  IMPORTER = BlueCollarSystems::PDFVectorImporter

  def test_import_dialog_explains_finite_bbox_labels_visual_equivalent
    hint = IMPORTER::ImportDialog::TEXT_MODE_HINT

    assert_match(/finite[- ]bbox Labels/i, hint)
    assert_match(/source-outline 3D visual-equivalent/i, hint)
    assert_match(/not (?:a )?native editable annotation/i, hint)
    assert_match(/no silent Raster/i, hint)
  end

  def test_qa_report_never_recommends_labels_as_editable_native_text
    diagnostics = IMPORTER::QAReport.diagnostics_block(
      {
        :primitives => 10, :text => 1, :layers => [],
        :text_mode => :labels, :text_source_spans => 1
      }
    )
    actions = Array(diagnostics[:recommended_actions]).join("\n")

    assert_match(/source-outline 3D visual-equivalent/i, actions)
    assert_match(/not (?:a )?native editable annotation/i, actions)
    refute_match(/Labels or 3D Text mode when editable text/i, actions)
    refute_match(/outlines are more important than editability/i, actions)
  end

  def test_operator_documents_reject_obsolete_editable_labels_advice
    documents = %w[
      AGENTS.md README.md HOST_COMPATIBILITY.md COMPATIBILITY.md
      HUMAN_CONFIRMATION.md
    ].inject({}) do |memo, relative|
      memo[relative] = File.read(File.join(REPO_ROOT, relative), :encoding => 'UTF-8')
      memo
    end
    combined = documents.values.join("\n")

    refute_match(/Use \*\*Labels\*\* only when editable SketchUp text/i, combined)
    refute_match(/\*\*Labels\*\* — editable annotations preserve/i, combined)
    assert_match(/finite[- ]bbox.*Labels/i,
                 documents.fetch('COMPATIBILITY.md'))
    assert_match(/source-outline 3D visual-equivalent/i,
                 documents.fetch('COMPATIBILITY.md'))
    assert_match(/not (?:a )?native editable annotation/i,
                 documents.fetch('HUMAN_CONFIRMATION.md'))
  end

  def test_all_current_superpowers_plans_and_specs_reject_native_finite_bbox_labels
    paths = Dir[
      File.join(REPO_ROOT, 'docs', 'superpowers', '{plans,specs}', '**', '*.md')
    ].sort
    assert_operator paths.length, :>=, 10,
                    'every current approved plan/spec must be in the guidance scan'
    documents = paths.inject({}) do |memo, path|
      memo[path.sub(REPO_ROOT + File::SEPARATOR, '')] =
        File.read(path, :encoding => 'UTF-8')
      memo
    end
    combined = documents.values.join("\n")

    refute_match(/horizontal spans remain native Labels/i, combined)
    refute_match(/Horizontal Text items remain native Labels/i, combined)
    refute_match(/Horizontal Text completes as native Labels/i, combined)

    %w[
      docs/superpowers/plans/2026-07-29-sketchup-text-fidelity-performance.md
      docs/superpowers/specs/2026-07-29-sketchup-text-fidelity-performance-design.md
    ].each do |relative|
      text = documents.fetch(relative.tr('/', File::SEPARATOR)) do
        documents.fetch(relative)
      end
      assert_match(/supersed(?:e|ed)/i, text, relative)
      assert_match(/finite[- ]bbox Labels/i, text, relative)
      assert_match(/source-outline 3D visual-equivalent/i, text, relative)
      assert_match(/not (?:a )?native editable annotation/i, text, relative)
    end
  end

  def test_live_acceptance_documentation_requires_exact_reopened_census
    compatibility = File.read(
      File.join(REPO_ROOT, 'HOST_COMPATIBILITY.md'), :encoding => 'UTF-8'
    )
    confirmation = File.read(
      File.join(REPO_ROOT, 'HUMAN_CONFIRMATION.md'), :encoding => 'UTF-8'
    )
    combined = [compatibility, confirmation].join("\n")

    assert_match(/labels_visual_equivalent_acceptance.*true/i, compatibility)
    assert_match(/reopened.*0 [`*]*Sketchup::Text/im, combined)
    assert_match(/0 Raster/i, combined)
    assert_match(/791 unique source-glyph 3D deliveries/i, combined)
    assert_match(/653 size.*138 rotation/i, combined)
    assert_match(/persistent.*source span.*provenance/im, combined)
    assert_match(/filled visible faces.*material/im, combined)
    assert_match(/hidden contour edges.*readback/im, combined)
    assert_match(/30 seconds.*side-by-side/im, combined)
    assert_match(/external live gates/i, combined)
    refute_match(/host-free.*(?:proves|certifies).*live/i, combined)
  end
end
