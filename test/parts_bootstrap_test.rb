#!/usr/bin/env ruby
# test/parts_bootstrap_test.rb
# Regression tests for PartsBootstrap BOM row extractor (R5-2).

$LOAD_PATH.unshift File.join(__dir__, '..', 'extracted', 'sketchup_ext')
require 'minitest/autorun'
require 'bc_pdf_vector_importer/parts_bootstrap'

PB = BlueCollarSystems::PDFVectorImporter::PartsBootstrap

# Minimal text-item stub compatible with PartsBootstrap
MockText = Struct.new(:text, :page_number, :bbox_x0, :bbox_y0, :id)

class PartsBootstrapTest < Minitest::Test

  def make_bom_page
    # Simulate a simple BOM table at y≈500 with header row then 2 data rows
    header_y = 500.0
    [
      MockText.new('QUAN',        1, 50.0,  header_y, 'h1'),
      MockText.new('MARK',        1, 120.0, header_y, 'h2'),
      MockText.new('DESCRIPTION', 1, 220.0, header_y, 'h3'),
      # row 1
      MockText.new('2',           1, 50.0,  460.0, 'r1a'),
      MockText.new('p7302',         1, 120.0, 460.0, 'r1b'),
      MockText.new("PL5/8X9X2'-6\"", 1, 220.0, 460.0, 'r1c'),
      # row 2
      MockText.new('1',           1, 50.0,  430.0, 'r2a'),
      MockText.new('7309FR4',     1, 120.0, 430.0, 'r2b'),
      MockText.new('W10X22',      1, 220.0, 430.0, 'r2c'),
    ]
  end

  def test_schema_present
    result = PB.build({})
    assert_equal PB::SCHEMA, result[:schema]
  end

  def test_empty_pages_map_returns_empty_tables
    result = PB.build({})
    assert_equal 0, result[:table_count]
    assert_equal 0, result[:row_count]
    assert_empty result[:tables]
  end

  def test_bom_page_extracts_two_rows
    items = make_bom_page
    result = PB.build({ 1 => items })
    assert_equal 1, result[:table_count], 'expected 1 table'
    assert_equal 2, result[:row_count],   'expected 2 rows'
  end

  def test_first_row_mark
    items = make_bom_page
    result = PB.build({ 1 => items })
    marks = result[:tables].first[:rows].map { |r| r[:piece_mark] }
    assert_includes marks, 'p7302'
  end

  def test_second_row_mark
    items = make_bom_page
    result = PB.build({ 1 => items })
    marks = result[:tables].first[:rows].map { |r| r[:piece_mark] }
    assert_includes marks, '7309FR4'
  end

  def test_quantity_extracted
    items = make_bom_page
    result = PB.build({ 1 => items })
    row = result[:tables].first[:rows].find { |r| r[:piece_mark] == 'p7302' }
    assert_equal 2, row[:quantity]
  end

  def test_profile_hint_plate
    items = make_bom_page
    result = PB.build({ 1 => items })
    row = result[:tables].first[:rows].find { |r| r[:piece_mark] == 'p7302' }
    assert_equal 'PL', row[:profile_hint]
  end

  def test_profile_hint_wide_flange
    items = make_bom_page
    result = PB.build({ 1 => items })
    row = result[:tables].first[:rows].find { |r| r[:piece_mark] == '7309FR4' }
    assert_equal 'W', row[:profile_hint]
  end

  def test_length_extracted_from_plate_description
    items = make_bom_page
    result = PB.build({ 1 => items })
    row = result[:tables].first[:rows].find { |r| r[:piece_mark] == 'p7302' }
    assert_in_delta 30.0, row[:length_in].to_f, 0.01
  end

  def test_span_ids_populated
    items = make_bom_page
    result = PB.build({ 1 => items })
    row = result[:tables].first[:rows].find { |r| r[:piece_mark] == 'p7302' }
    assert_kind_of Array, row[:span_ids]
    assert row[:span_ids].any? { |id| id.to_s.include?('r1') }
  end

  def test_session_id_passed_through
    result = PB.build({}, session_id: 'sess-xyz')
    assert_equal 'sess-xyz', result[:import_session_id]
  end

  def test_page_with_no_headers_yields_no_table
    items = [
      MockText.new('Some random text', 1, 100.0, 300.0, 'x1'),
      MockText.new('More text',        1, 200.0, 280.0, 'x2'),
    ]
    result = PB.build({ 1 => items })
    assert_equal 0, result[:table_count]
    assert_empty result[:tables]
  end

  def test_parse_fraction_whole
    assert_in_delta 12.0, PB.parse_fraction('12'), 0.001
  end

  def test_parse_fraction_simple
    assert_in_delta 0.5, PB.parse_fraction('1/2'), 0.001
  end

  def test_parse_fraction_mixed
    assert_in_delta 4.75, PB.parse_fraction('4 3/4'), 0.001
  end

  def test_parse_fraction_nil_on_garbage
    assert_nil PB.parse_fraction('ABC')
  end

  def test_extract_length_feet_inches
    assert_in_delta 28.0, PB.extract_length("2'-4\""), 0.01
  end

  def test_extract_length_nil_when_absent
    assert_nil PB.extract_length('PL5/8X9')
  end

  def test_profile_hint_hss
    assert_equal 'HSS', PB.profile_hint('HSS6X6X1/4')
  end

  def test_profile_hint_pipe
    assert_equal 'PIPE', PB.profile_hint('PIPE4 STD')
  end

  def test_profile_hint_nil_unknown
    assert_nil PB.profile_hint('some random text')
  end

  def test_multiple_pages_builds_multiple_tables
    page1 = [
      MockText.new('QUAN', 1, 50.0, 500.0, 'p1h1'),
      MockText.new('MARK', 1, 120.0, 500.0, 'p1h2'),
      MockText.new('1',    1, 50.0, 460.0, 'p1r1'),
      MockText.new('a001', 1, 120.0, 460.0, 'p1r2'),
    ]
    page2 = [
      MockText.new('QUAN', 2, 50.0, 500.0, 'p2h1'),
      MockText.new('MARK', 2, 120.0, 500.0, 'p2h2'),
      MockText.new('3',    2, 50.0, 460.0, 'p2r1'),
      MockText.new('b002', 2, 120.0, 460.0, 'p2r2'),
    ]
    result = PB.build({ 1 => page1, 2 => page2 })
    assert_equal 2, result[:table_count]
    assert_equal 2, result[:row_count]
  end
end
