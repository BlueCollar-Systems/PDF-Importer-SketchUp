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
  # Standalone bare number (no unit) is inches.
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

  # Boundary fixtures exercise only String#to_l dispatch/type handling;
  # they are not native SketchUp acceptance evidence.
  class HostInput < String
    attr_reader :host_calls
    def initialize(text, result, error = nil)
      super(text); @result=result; @error=error; @host_calls=0
    end
    def to_l
      @host_calls+=1
      raise @error if @error
      @result
    end
  end
  class StandaloneInput < String
    def respond_to?(name, *args)
      name == :to_l ? false : super
    end
  end

  def test_unknown_units_and_trailing_junk_return_nil
    ['10bananas','10inx','10mm junk','1in trailing','1" extra',"2'-",
      '1.2.3in','1 2','1e999','Infinity','NaN','-1mm',"1\n2", "1\0mm",
      '1,000','1,5 mm'].each { |input| assert_nil UP.parse_inches(input),input }
  end

  def test_all_fraction_forms_reject_zero_denominators
    ['1/0','0/0','2 1/0','1/00in',"5' 1/0\"", "5' 6 1/0\"",
      '3 1/0 feet'].each { |input| assert_nil UP.parse_inches(input),input }
  end

  def test_invalid_grammar_never_reaches_a_permissive_host_parser
    ['10bananas','1/0','0/0','2 1/0',"5' 1/0\"",'1in trailing',"2'-",
      '1,5','1 2',"1\n2",'9'*129].each do |text|
      input=HostInput.new(text,123.0)
      assert_nil UP.parse_model_units(input),text
      assert_equal 0,input.host_calls,text
    end
  end

  def test_bare_values_use_host_model_units_in_internal_inches
    # Millimeter model:25.4 means1in. Feet model:1/2 means6in,
    # and1 1/2 means18in. Native units remain authoritative for bare input.
    {'25.4'=>1.0,'1/2'=>6.0,'1 1/2'=>18.0,'  +25.4  '=>1.0,'+ 25.4'=>1.0}.each do |text,host_inches|
      input=HostInput.new(text,host_inches)
      assert_in_delta host_inches,UP.parse_model_units(input),1e-12
      assert_equal 1,input.host_calls
    end
  end

  def test_explicit_units_use_exact_arithmetic_without_host_prefix_interpretation
    {'10mm'=>10/25.4,"5'-6 1/2\""=>66.5,'1 1/2 ft'=>18.0,
      '1/2 centimeter'=>5/25.4}.each do |text,inches|
      input=HostInput.new(text,999.0)
      assert_in_delta inches,UP.parse_model_units(input),1e-12
      assert_equal 0,input.host_calls
    end
  end

  def test_invalid_host_results_do_not_become_inches_or_zero
    [nil,false,'12',Float::INFINITY,Float::NAN,-1.0,Object.new].each do |result|
      input=HostInput.new('25.4',result)
      assert_nil UP.parse_model_units(input)
      assert_equal 1,input.host_calls
    end
  end

  def test_host_failure_on_a_valid_bare_value_does_not_fall_back_to_inches
    input=HostInput.new('25.4',nil,ArgumentError.new('host rejected length'))
    assert_nil UP.parse_model_units(input)
    assert_equal 1,input.host_calls
  end

  def test_standalone_model_parser_preserves_existing_inch_fallback
    assert_in_delta 0.375,UP.parse_model_units(StandaloneInput.new('3/8')),1e-12
    assert_in_delta 1.5,UP.parse_model_units(StandaloneInput.new('1 1/2')),1e-12
  end

  def test_zero_is_a_legitimate_parsed_dimension
    assert_equal 0.0,UP.parse_inches('0')
    assert_equal 0.0,UP.parse_inches('0/8 mm')
    input=HostInput.new('0',0.0)
    assert_equal 0.0,UP.parse_model_units(input)
    assert_equal 1,input.host_calls
  end

  def test_positive_sign_and_fractional_feet_inches_remain_valid
    {'.25in'=>0.25,'+3/8'=>0.375,"5'1/2\""=>60.5,
      '1foot 4in'=>16.0,"5'\t6\""=>66.0}.each do |input,value|
      assert_in_delta value,UP.parse_inches(input),1e-12,input
    end
  end

  def test_bounded_or_invalid_encoding_input_is_nil_before_host
    ['9'*129, "1\xFF".dup.force_encoding('UTF-8'), '25.4'.encode('UTF-16LE'),
      "\xFF".dup.force_encoding('ASCII-8BIT')].each do |text|
      input=HostInput.new(text,1.0)
      assert_nil UP.parse_inches(input)
      assert_nil UP.parse_model_units(input)
      assert_equal 0,input.host_calls
    end
    assert UP.parse_inches('9'*128).finite?
    assert_in_delta 1/25.4,UP.parse_inches(' '*120+'1mm'),1e-12
  end

  def test_model_parser_nonstring_inputs_keep_nil_contract
    [nil,123,Float::INFINITY].each { |value| assert_nil UP.parse_model_units(value) }
  end

  def test_native_length_type_need_not_inherit_numeric
    had_length=Object.const_defined?(:Length)
    previous=Object.const_get(:Length) if had_length
    Object.send(:remove_const,:Length) if had_length
    fixture=Class.new do
      def initialize(value); @value=value; end
      def to_f; @value; end
    end
    Object.const_set(:Length,fixture)
    input=HostInput.new('25.4',fixture.new(1.0))
    assert_in_delta 1.0,UP.parse_model_units(input),1e-12
    assert_equal 1,input.host_calls
    assert_nil UP.parse_model_units(HostInput.new('25.4',fixture.new(Float::INFINITY)))
    assert_nil UP.parse_model_units(HostInput.new('25.4',fixture.new('invalid')))
  ensure
    Object.send(:remove_const,:Length) if defined?(fixture) && Object.const_defined?(:Length) && Object.const_get(:Length)==fixture
    Object.const_set(:Length,previous) if had_length
  end

end
