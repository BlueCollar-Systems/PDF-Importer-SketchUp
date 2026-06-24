#!/usr/bin/env ruby
# frozen_string_literal: true

# Headless golden-oracle gate: named Tier-1 PDFs vs numeric ranges in golden_oracles.json.
# Skips oracles whose PDF is not on disk (manifest-only / user-desktop).

require 'json'
require 'minitest/autorun'

require_relative 'support/corpus_harness'
require_relative '../corpus_paths'

class GoldenOracleTest < Minitest::Test
  ORACLE_PATH = File.join(__dir__, 'fixtures', 'golden_oracles.json')

  def setup
    @doc = JSON.parse(File.read(ORACLE_PATH))
    @oracles = @doc.fetch('oracles')
  end

  def test_oracle_schema
    assert_equal 'bcs.golden_oracles/1', @doc['schema']
    assert @oracles.length >= 5
  end

  def test_named_oracles_against_corpus
    failures = []
    @oracles.each do |oracle|
      pdf = resolve_oracle_pdf(oracle)
      unless pdf
        warn "SKIP #{oracle['id']} — PDF not on disk (#{oracle['name']})"
        next
      end

      info = {
        path: pdf,
        corpus_key: oracle['corpus_key'] || "golden_oracle/#{File.basename(pdf)}"
      }
      result = CorpusHarness.analyze_pdf(info)
      expect = oracle['expect'] || {}
      failures.concat(check_oracle(oracle, result, expect))
    end

    assert_empty failures, failures.join("\n")
  end

  private

  def resolve_oracle_pdf(oracle)
    key = oracle['corpus_key']
    if key && !key.to_s.empty?
      rel = key.sub(%r{\A[^/]+/}, '')
      found = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf(rel)
      return found if found
      found = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf(key)
      return found if found
    end

    Array(oracle['pdf_candidates']).each do |name|
      found = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf(name)
      return found if found
    end
    nil
  end

  def check_oracle(oracle, result, expect)
    out = []
    id = oracle['id']
    allowed = expect['allow_status']
    if allowed.is_a?(Array) && !allowed.empty?
      return out if allowed.include?(result[:status].to_s)
      return out << "#{id}: expected status in #{allowed.inspect}, got #{result[:status]}"
    end
    return out << "#{id}: status #{result[:status]} — #{result[:error]}" unless result[:status] == 'OK'

    {
      paths_min: :paths,
      text_items_min: :text_items,
      pages_min: :pages,
      bbox_pct_min: :bbox_pct,
      placement_ok_min: :placement_rate,
      placement_rate_min: :placement_rate
    }.each do |exp_key, res_key|
      next unless expect.key?(exp_key.to_s)
      floor = expect[exp_key.to_s]
      val = result[res_key]
      val = val.to_f if res_key == :placement_rate
      next if val.to_f >= floor.to_f
      out << "#{id}: #{exp_key} expected >= #{floor}, got #{val}"
    end

    if expect['scale_crosscheck_absent']
      # Scale oracle placeholder — headless harness does not run scale detection yet.
    end

    if expect['scale_crosscheck_reasons_any']
      # Requires import_report pipeline — validated in human confirmation.
    end

    out
  end
end
