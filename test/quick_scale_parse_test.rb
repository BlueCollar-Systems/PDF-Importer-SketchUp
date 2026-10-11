#!/usr/bin/env ruby
# test/quick_scale_parse_test.rb
#
# Quick Scale reads a drawing scale the way it is printed and turns it into
# the multiplier that brings a paper-size import up to real size: 1:48 and
# 1/4"=1'-0" both mean "make it 48 times larger". Before, '1:48' shrank the
# drawing 48 times and architectural notation was refused.
# Ruby 2.2 compatible -- no keyword arguments or safe navigation.

require 'minitest/autorun'

MB_YESNO = 4 unless defined?(MB_YESNO)
IDYES = 6 unless defined?(IDYES)
IDNO = 7 unless defined?(IDNO)

module Sketchup
  class << self
    attr_accessor :fake_model
  end

  def self.active_model
    fake_model
  end
end

module UI
  class << self
    attr_accessor :inputs, :messages, :answer
  end
  self.inputs = []
  self.messages = []
  self.answer = IDNO

  def self.inputbox(*_args)
    inputs.shift
  end

  def self.messagebox(message, *_rest)
    messages << message
    answer
  end
end

%w[logger primitives unit_parser dimension_parser resolved_scale scale_tool].each do |name|
  require_relative "../extracted/sketchup_ext/bc_pdf_vector_importer/#{name}"
end

class QuickScaleParseTest < Minitest::Test
  M = BlueCollarSystems::PDFVectorImporter

  def setup
    Sketchup.fake_model = Object.new
    UI.inputs = []
    UI.messages = []
    UI.answer = IDNO
  end

  def factor(text)
    M::ResolvedScaleDetect.enlargement_from_text(text)
  end

  def test_printed_drawing_scales_become_the_enlargement_to_real_size
    ['48', '1:48', '1/4"=1\'-0"', '1/48', ' 1 : 48 '].each do |text|
      assert_in_delta 48.0, factor(text), 1e-9, text
    end
    assert_in_delta 32.0, factor('3/8"=1\''), 1e-9
    assert_in_delta 120.0, factor('1"=10\''), 1e-9
    assert_in_delta 24.0, factor('1/2"=1\'-0"'), 1e-9
    assert_in_delta 8.0, factor('1-1/2"=1\'-0"'), 1e-9
    assert_in_delta 4.0, factor('3"=1\'-0"'), 1e-9
    assert_in_delta 50.0, factor('1:50'), 1e-9
  end

  def test_plain_numbers_and_decimal_ratios_keep_their_meaning
    assert_in_delta 0.5, factor('0.5'), 1e-9
    assert_in_delta 2.0, factor('2'), 1e-9
    assert_in_delta 0.4, factor('2.5:1'), 1e-9
    assert_in_delta 2.5, factor('1:2.5'), 1e-9
  end

  def test_unreadable_zero_and_negative_entries_are_refused
    ['abc', '0', '-2', '', '0:48', '1:0', '48x'].each do |text|
      assert_nil factor(text), text.inspect
    end
  end

  # A real side with only an inch mark is inches, not feet: 1/4"=12" is the
  # same scale as 1/4"=1'-0". Before, it read as 576.
  def test_inch_marked_real_side_is_read_as_inches
    assert_in_delta 48.0, factor('1/4"=12"'), 1e-9
    assert_in_delta 48.0, factor('1/4" = 12 in'), 1e-9
    assert_in_delta 12.0, factor('1/2"=6"'), 1e-9
    assert_in_delta 1.0, factor('1"=1"'), 1e-9
    assert_in_delta 1.0, factor('12"=1\''), 1e-9
    assert_in_delta 48.0, factor('1/4 in = 1 ft'), 1e-9
    assert_in_delta 18.0, factor('1"=1\'-6"'), 1e-9
  end

  def test_bare_numbers_on_both_sides_are_a_ratio
    assert_in_delta 48.0, factor('1=48'), 1e-9
    assert_in_delta 48.0, factor('1 = 48'), 1e-9
    assert_in_delta 0.5, factor('2=1'), 1e-9
    # A unit on the paper side keeps the engineering-scale reading.
    assert_in_delta 120.0, factor('1"=10'), 1e-9
  end

  def test_extra_ratio_or_equals_parts_are_refused
    ['1:48:2', '1=1=48', '1/4"=1\'-0"=2', '1:48=2:1'].each do |text|
      assert_nil factor(text), text.inspect
    end
  end

  def test_typed_scales_consume_the_whole_entry_and_reject_invalid_dimensions
    ['1:48garbage', 'junk 1:48', 'SCALED 1:48', '1:48mm',
     '1"=1\'-6 1/0"', '1/4"=1\'-0" trailing', '1"=10 unknown',
     "1:48\n", "1:48\x00", '9' * 129].each do |text|
      assert_nil factor(text), text.inspect
    end
  end

  def test_strict_real_dimensions_keep_printed_units_and_fractions
    assert_in_delta 18.5, factor('1"=1\'-6 1/2"'), 1e-9
    assert_in_delta 8.0, factor('1-1/2"=12"'), 1e-9
    assert_in_delta 48.0, factor('1/4 in. = 1 ft.'), 1e-9
    assert_in_delta 48.0, factor("1/4\u2033=1\u2032-0\u2033"), 1e-9
    assert_in_delta 50.0, factor('SCL. 1:50'), 1e-9
    assert_in_delta 10.0, factor('1"=254mm'), 1e-9
  end

  def test_a_pasted_scale_label_is_ignored
    assert_in_delta 48.0, factor('SCALE: 1/4"=1\'-0"'), 1e-9
    assert_in_delta 50.0, factor('SCALE: 1:50'), 1e-9
    assert_in_delta 48.0, factor('Scale 1:48'), 1e-9
    assert_in_delta 128.0, factor('3/32"=1\'-0"'), 1e-9
    assert_in_delta 1.0 / 48.0, factor('48:1'), 1e-12
  end

  def test_parse_scale_factor_uses_the_same_reading
    assert_in_delta 48.0, M::ScaleTool.parse_scale_factor('1:48'), 1e-9
    assert_nil M::ScaleTool.parse_scale_factor('abc')
  end

  def test_quick_scale_says_which_way_the_drawing_changes_before_anything_moves
    UI.inputs << ['1:48', 'All Groups']
    M::ScaleTool.quick_scale

    assert_equal 1, UI.messages.length
    assert_includes UI.messages.first, '48'
    assert_includes UI.messages.first, 'LARGER'
  end

  def test_quick_scale_names_a_shrink_as_smaller
    UI.inputs << ['0.5', 'All Groups']
    M::ScaleTool.quick_scale

    assert_includes UI.messages.first, '2x smaller'
  end

  def test_quick_scale_refuses_unreadable_text_with_examples
    UI.inputs << ['abc', 'All Groups']
    M::ScaleTool.quick_scale

    assert_equal 1, UI.messages.length
    assert_includes UI.messages.first, '"abc"'
    assert_includes UI.messages.first, '1/4"=1\'-0"'
  end

  def test_quick_scale_prompt_shows_printed_scale_examples
    seen = nil
    UI.stub(:inputbox, lambda { |prompts, *_rest| seen = prompts; nil }) do
      M::ScaleTool.quick_scale
    end
    assert_includes seen.first, '1:48'
    assert_includes seen.first, '1/4"=1\'-0"'
  end
end
