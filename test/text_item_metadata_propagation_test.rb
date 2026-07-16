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
    item.source_font_italic = true
    item.font_to_sketchup_letter_ratio = 1491.0 / 2048.0
    item.font_to_sketchup_letter_ratio_source = :known_arial_family
    item.trusted_text_matrix_x_scale = 1.436458
    item
  end

  def assert_canary(item)
    assert_equal 'span:1', item.source_span_id
    assert_equal 'Arial Narrow', item.source_font_family
    assert_equal true, item.source_font_bold
    assert_equal true, item.source_font_italic
    assert_in_delta 1491.0 / 2048.0,
                    item.font_to_sketchup_letter_ratio, 1.0e-12
    assert_equal :known_arial_family,
                 item.font_to_sketchup_letter_ratio_source
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

  def test_differently_scaled_runs_cannot_merge
    parser = TP.new([], {})
    same_scale = [canary('A'), canary('B')]
    same_scale[1].x = 13.0
    assert_equal 1, parser.send(:merge_text_runs, same_scale).length,
                 'control runs must be close enough to merge'

    different_scale = [canary('A'), canary('B')]
    different_scale[1].x = 13.0
    different_scale[1].trusted_text_matrix_x_scale = 0.8
    merged = parser.send(:merge_text_runs, different_scale)

    assert_equal 2, merged.length,
                 'runs with different trusted matrix-X factors must stay separate'
    assert_equal [0.8, 1.436458],
                 merged.map(&:trusted_text_matrix_x_scale).sort
  end

  def test_every_rebuild_file_invokes_the_central_final_field_copy
    root = File.expand_path('..', __dir__)
    expected_calls = {
      'extracted/sketchup_ext/bc_pdf_vector_importer/text_parser.rb' => [
        'TextParser.copy_text_item_final_fields!(clone, it)',
        'TextParser.copy_text_item_final_fields!(merged, base)',
        'TextParser.copy_text_item_final_fields!(frac_item, base_item)',
        'TextParser.copy_text_item_final_fields!(split_item, item)'
      ],
      'extracted/sketchup_ext/bc_pdf_vector_importer/external_text_extractor.rb' => [
        'TextParser.copy_text_item_final_fields!(merged_item, it)',
        'TextParser.copy_text_item_final_fields!(merged_item, a1)',
        'TextParser.copy_text_item_final_fields!(rebuilt_item, it)'
      ],
      'extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb' => [
        'TextParser.copy_text_item_final_fields!(sub, item)'
      ],
      'extracted/sketchup_ext/bc_pdf_vector_importer/main.rb' => [
        'TextParser.copy_text_item_final_fields!(clone, item)'
      ]
    }
    expected_calls.each do |relative, expected|
      source_lines = File.readlines(File.join(root, relative)).map(&:strip)
      actual = source_lines.select do |line|
        line.start_with?('TextParser.copy_text_item_final_fields!(')
      end
      assert_equal expected, actual, relative
    end
  end
end
