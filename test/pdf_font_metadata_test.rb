#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'

class PdfFontMetadataTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::PDFParser

  def parser_for(objects, cmap = nil)
    parser = Parser.new(__FILE__)
    parser.define_singleton_method(:resolve_object) { |ref| objects.fetch(ref, ref) }
    parser.define_singleton_method(:extract_font_to_unicode_map) { |_ref| cmap }
    parser
  end

  def info_for(font, objects = {}, cmap = nil)
    parser_for(objects, cmap).send(:extract_font_resource_info, font)
  end

  def test_subset_arial_variants_and_romant_have_exact_known_metrics
    cases = {
      '/FPAVJU+Arial' => ['Arial', false, false, 1491.0 / 2048.0, :known_arial_family],
      '/FPFAQD+Arial,Bold' => ['Arial', true, false, 1491.0 / 2048.0, :known_arial_family],
      '/FPWADG+ArialNarrow' => ['Arial Narrow', false, false, 1491.0 / 2048.0, :known_arial_family],
      '/FPMZBW+RomanT' => ['RomanT', false, false, 1538.0 / 2048.0, :known_romant]
    }
    cases.each do |name, expected|
      info = info_for('/BaseFont' => name)
      actual = [info[:source_font_family], info[:source_font_bold],
                info[:source_font_italic], info[:font_to_sketchup_letter_ratio],
                info[:font_to_sketchup_letter_ratio_source]]
      assert_equal expected, actual
    end
  end

  def test_romantic_near_match_is_not_treated_as_romant
    info = info_for('/BaseFont' => '/Romantic')
    assert_equal 'Romantic', info[:source_font_family]
    assert_equal :default_arial_family, info[:font_to_sketchup_letter_ratio_source]
    assert_in_delta 1491.0 / 2048.0, info[:font_to_sketchup_letter_ratio], 1.0e-12
  end

  def test_descriptor_ascent_is_bounded_and_capheight_is_ignored
    valid = info_for({'/BaseFont' => '/UnknownCAD', '/FontDescriptor' => 'd'},
                     {'d' => {'/Ascent' => 600, '/CapHeight' => 500}})
    assert_in_delta 0.60, valid[:font_to_sketchup_letter_ratio], 1.0e-12
    assert_equal :font_descriptor_ascent, valid[:font_to_sketchup_letter_ratio_source]

    invalid = info_for({'/BaseFont' => '/UnknownCAD', '/FontDescriptor' => 'd'},
                       {'d' => {'/Ascent' => 500, '/CapHeight' => 900}})
    assert_in_delta 1491.0 / 2048.0, invalid[:font_to_sketchup_letter_ratio], 1.0e-12
    assert_equal :default_arial_family, invalid[:font_to_sketchup_letter_ratio_source]
  end

  def test_font_resource_is_retained_without_tounicode
    info = info_for({'/BaseFont' => '/Arial'}, {}, nil)
    assert_equal({}, info[:map])
    assert_equal [1], info[:code_lengths]
    assert_equal 'Arial', info[:source_font_family]
  end

  def test_page_font_maps_retains_font_without_tounicode_under_both_aliases
    objects = {
      'page' => {'/Resources' => 'resources'},
      'resources' => {'/Font' => 'fonts'},
      'fonts' => {'/F1' => 'font'},
      'font' => {'/BaseFont' => '/Arial'}
    }
    parser = parser_for(objects)
    parser.instance_variable_set(:@pages, ['page'])
    parser.instance_variable_set(:@page_count, 1)

    maps = parser.page_font_maps(1)
    assert maps.key?('/F1')
    assert_same maps['/F1'], maps['F1']
    assert_equal({}, maps['/F1'][:map])
    assert_equal [1], maps['F1'][:code_lengths]
  end

  def test_descriptor_italic_angle_sets_style
    info = info_for({'/BaseFont' => '/Custom', '/FontDescriptor' => 'd'},
                    {'d' => {'/Ascent' => 728, '/ItalicAngle' => -12}})
    assert_equal true, info[:source_font_italic]
  end
end
