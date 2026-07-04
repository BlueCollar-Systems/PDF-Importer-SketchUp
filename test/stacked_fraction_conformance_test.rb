#!/usr/bin/env ruby

require 'json'
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/text_parser'

class StackedFractionConformanceTest < Minitest::Test
  TP = BlueCollarSystems::PDFVectorImporter::TextParser

  def vector_file
    corpus_root = ENV['BCS_CORPUS_ROOT'] || 'C:/1pdf-test-corpus'
    File.join(corpus_root, 'conformance-vectors', 'stacked-fraction-merge-vectors.json')
  end

  def vectors
    skip "conformance vector file missing: #{vector_file}" unless File.exist?(vector_file)
    data = JSON.parse(File.read(vector_file))
    assert_equal 'bcs.conformance_vectors/1.0', data['schema']
    data['vectors']
  end

  def text_items(vector)
    vector['input']['spans'].map do |span|
      TP::TextItem.new(
        span['text'].to_s,
        span['x'].to_f,
        span['y'].to_f,
        span['font_size'].to_f,
        span.fetch('rotation', 0.0).to_f,
        span['font_name'].to_s,
        span['font_size'].to_f
      )
    end
  end

  def run_parser_pipeline(items)
    parser = TP.new([], {})
    out = parser.send(:reconstruct_fractions, items)
    out = parser.send(:merge_text_runs, out)
    parser.send(:fix_merged_fractions, out)
  end

  def test_stacked_fraction_vectors
    vectors.each do |vector|
      expected = vector['expected'] || {}
      output = run_parser_pipeline(text_items(vector))
      texts = output.map { |item| item.text.to_s }

      if expected['should_merge']
        assert_includes texts, expected['merged_text'], vector['id']
        refute_includes texts, '2/4', vector['id']
      elsif expected['merged_text']
        refute_includes texts, expected['merged_text'], vector['id']
      end
      Array(expected['forbidden_texts'] || []).each do |forbidden|
        refute_includes texts, forbidden, vector['id']
      end
    end
  end
end
