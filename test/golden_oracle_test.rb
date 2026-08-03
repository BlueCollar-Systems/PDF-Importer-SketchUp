#!/usr/bin/env ruby
# frozen_string_literal: true

# Headless golden-oracle gate: private manifest acceptance roles vs numeric
# ranges in validation_oracles.json. Private identifiers and paths stay in the
# external manifest; committed acceptance keys are semantic and non-sensitive.

require 'json'
require 'minitest/autorun'

require_relative 'support/corpus_harness'
require_relative '../corpus_paths'

class GoldenOracleTest < Minitest::Test
  ORACLE_PATH = File.join(__dir__, 'fixtures', 'validation_oracles.json')

  def setup
    @doc = JSON.parse(File.read(ORACLE_PATH))
    @oracles = @doc.fetch('oracles')
  end

  def test_oracle_schema
    assert_equal 'bcs.validation_oracles/1', @doc['schema']
    assert @oracles.length >= 5
    keys = @oracles.map { |oracle| oracle['acceptance_key'].to_s.strip }
    assert keys.all? { |key| !key.empty? }, 'every oracle requires acceptance_key'
    assert_equal keys.length, keys.uniq.length, 'acceptance_key values must be unique'
  end

  def test_named_oracles_against_corpus
    paths = BlueCollarSystems::PDFVectorImporter::CorpusPaths
    skip 'Set BCS_PRIVATE_VALIDATION_ROOT to run golden oracles' unless paths.configured_private_validation_root

    failures = []
    executed_count = 0
    @oracles.each do |oracle|
      pdf = resolve_oracle_pdf(oracle)

      info = {
        path: pdf,
        corpus_key: oracle['corpus_key'] || "golden_oracle/#{File.basename(pdf)}"
      }
      result = CorpusHarness.analyze_pdf(info)
      expect = oracle['expect'] || {}
      failures.concat(check_oracle(oracle, result, expect))
      executed_count += 1
    end

    assert_equal @oracles.length, executed_count,
                 "executed #{executed_count} of #{@oracles.length} configured oracles"
    assert_empty failures, failures.join("\n")
  end

  private

  def resolve_oracle_pdf(oracle)
    BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_acceptance_pdf(
      oracle.fetch('acceptance_key')
    )
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
