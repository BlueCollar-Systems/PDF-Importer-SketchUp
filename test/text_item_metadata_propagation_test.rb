#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class TextItemMetadataPropagationTest < Minitest::Test
  TP = BlueCollarSystems::PDFVectorImporter::TextParser
  TI = TP::TextItem

  def canary(text = 'A')
    item = TI.new(text, 10, 20, 12, 0, 'F1', 12, 10, 20, 30, 32, nil, 'span:1')
    item.source_font_family = 'Arial Narrow'
    item.source_font_bold = true
    item.source_font_italic = false
    item.font_to_sketchup_letter_ratio = 1491.0 / 2048.0
    item.font_to_sketchup_letter_ratio_source = :known_arial_family
    item.trusted_text_matrix_x_scale = 1.436458
    item
  end

  def assert_canary(item)
    assert_equal 'span:1', item.source_span_id
    assert_equal 'Arial Narrow', item.source_font_family
    assert_equal true, item.source_font_bold
    assert_in_delta 1.436458, item.trusted_text_matrix_x_scale, 1.0e-6
  end

  def test_copy_helpers_preserve_identity_and_all_render_metadata
    source = canary
    target = TI.new('B', 0, 0, 8, 0, 'pdftotext')
    TP.copy_text_item_final_fields!(target, source)
    assert_canary(target)
  end

  def test_external_bbox_identity_survives_internal_hint_overlay
    external = canary
    external.font_name = 'pdftotext'
    internal = canary
    internal.source_span_id = 'internal-span'
    merged = BlueCollarSystems::PDFVectorImporter.clone_text_item_with_hints(external, internal)
    assert_equal 'pdftotext', merged.font_name
    assert_equal external.bbox_x0, merged.bbox_x0
    assert_canary(merged)
  end

  def test_every_rebuild_file_uses_the_central_final_field_copy
    root = File.expand_path('..', __dir__)
    expected_minimums = {
      'extracted/sketchup_ext/bc_pdf_vector_importer/text_parser.rb' => 4,
      'extracted/sketchup_ext/bc_pdf_vector_importer/external_text_extractor.rb' => 3,
      'extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb' => 1,
      'extracted/sketchup_ext/bc_pdf_vector_importer/main.rb' => 1
    }
    expected_minimums.each do |relative, minimum|
      source = File.read(File.join(root, relative))
      assert_operator source.scan('copy_text_item_final_fields!').length, :>=, minimum, relative
    end
  end
end
