# test/unit_parser_test.rb
# Unit tests for UnitParser dimension parsing.
# Ruby 2.2 compatible — no &., #sum, #filter, #then, etc.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/unit_parser'

class UnitParserTest < Minitest::Test

  UP = BlueCollarSystems::PDFVectorImporter::UnitParser

  # ------------------------------------------------------------------
  # Feet-inches compound
  # ------------------------------------------------------------------
  def test_feet_inches_basic
    assert_in_delta 66.0, UP.parse_inches("5'-6\""), 1e-6
  end

  def test_feet_only
    assert_in_delta 12.0, UP.parse_inches("1'"), 1e-6
  end

  def test_feet_inches_no_inch_mark
    assert_in_delta 16.0, UP.parse_inches("1'-4"), 1e-6
  end

  def test_feet_inches_with_fraction
    assert_in_delta 66.5, UP.parse_inches("5' 6 1/2\""), 1e-6
  end

  # ------------------------------------------------------------------
  # Mixed number + unit
  # ------------------------------------------------------------------
  def test_mixed_inches
    assert_in_delta 1.5, UP.parse_inches("1 1/2 in"), 1e-6
  end

  def test_mixed_feet
    assert_in_delta 45.0, UP.parse_inches("3 3/4 ft"), 1e-6
  end

  # ------------------------------------------------------------------
  # Pure fraction
  # ------------------------------------------------------------------
  def test_fraction_bare
    assert_in_delta 0.375, UP.parse_inches("3/8"), 1e-6
  end

  def test_fraction_with_unit
    assert_in_delta 0.5, UP.parse_inches("1/2 in"), 1e-6
  end

  def test_quarter_inch
    assert_in_delta 0.25, UP.parse_inches("1/4\""), 1e-6
  end

  # ------------------------------------------------------------------
  # Decimal + unit
  # ------------------------------------------------------------------
  def test_decimal_mm
    # 406.4 mm = 16 inches
    assert_in_delta 16.0, UP.parse_inches("406.4 mm"), 1e-4
  end

  def test_decimal_inches
    assert_in_delta 4.92, UP.parse_inches("4.92 in"), 1e-6
  end

  def test_decimal_feet
    assert_in_delta 30.0, UP.parse_inches("2.5 ft"), 1e-6
  end

  def test_decimal_cm
    # 10 cm = 100 mm = 100/25.4 inches
    assert_in_delta(100.0 / 25.4, UP.parse_inches("10 cm"), 1e-4)
  end

  def test_decimal_meters
    # 1 m = 1000 mm = 1000/25.4 inches
    assert_in_delta(1000.0 / 25.4, UP.parse_inches("1 m"), 1e-4)
  end

  # ------------------------------------------------------------------
  # Bare number (no unit) — assumes model units (passes through as-is)
  # ------------------------------------------------------------------
  def test_bare_number
    assert_in_delta 120.0, UP.parse_inches("120"), 1e-6
  end

  # ------------------------------------------------------------------
  # Edge cases
  # ------------------------------------------------------------------
  def test_empty_string_returns_nil
    assert_nil UP.parse_inches("")
  end

  def test_whitespace_only_returns_nil
    assert_nil UP.parse_inches("   ")
  end

  def test_garbage_returns_nil
    assert_nil UP.parse_inches("not a dimension")
  end

  def test_nil_input_returns_nil
    assert_nil UP.parse_inches(nil)
  end

  def test_integer_input_returns_nil
    assert_nil UP.parse_inches(42)
  end

  # ------------------------------------------------------------------
  # Architectural scale notation (these parse as feet-inches or
  # fractions depending on format).
  # ------------------------------------------------------------------
  def test_one_quarter_inch
    # 1/4" should parse as 0.25 inches
    assert_in_delta 0.25, UP.parse_inches('1/4"'), 1e-6
  end

  def test_three_eighths_inch
    assert_in_delta 0.375, UP.parse_inches('3/8"'), 1e-6
  end

  def test_one_inch
    assert_in_delta 1.0, UP.parse_inches('1"'), 1e-6
  end

  def test_one_inch_word
    assert_in_delta 1.0, UP.parse_inches("1 inch"), 1e-6
  end

end
