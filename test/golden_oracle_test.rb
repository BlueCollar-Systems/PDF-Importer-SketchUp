#!/usr/bin/env ruby
# frozen_string_literal: true

# Headless golden-oracle gate: named private validation PDFs vs numeric ranges in validation_oracles.json.
# Skips oracles whose PDF is not on disk (manifest-only / user-desktop).

require 'json'
require 'digest'
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
  end

  def test_go_07_is_identity_and_historical_signature_locked
    oracle = @oracles.find { |item| item['id'] == 'GO-07' }
    refute_nil oracle
    assert_equal '5f7c157349c1ebf5caedab4524bad2e37abf7a02bf4727cf65c2398e8466a130',
                 oracle['sha256']
    expect = oracle.fetch('expect')
    assert_equal 642, expect['paths_min']
    assert_equal 365, expect['text_items_min']
    assert_equal 1.0, expect['placement_rate_min']
    assert_equal 'f16cf8bca472573ebc1d53c78bd1551087823b118a8e3f91cb4512e46f9e57e6',
                 expect['text_hash']
  end

  def test_text_hash_expectation_fails_closed_on_mismatch
    oracle = { 'id' => 'GO-HASH' }
    result = {
      status: 'OK',
      paths: 0,
      text_items: 1,
      pages: 1,
      placement_rate: 1.0,
      text_hash: 'actual'
    }

    failures = send(:check_oracle, oracle, result, 'text_hash' => 'expected')
    assert_equal ['GO-HASH: text_hash expected expected, got actual'], failures
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
      expected_sha = oracle['sha256'].to_s.downcase
      unless expected_sha.empty?
        actual_sha = Digest::SHA256.file(pdf).hexdigest.downcase
        if actual_sha != expected_sha
          failures << "#{oracle['id']}: sha256 expected #{expected_sha}, got #{actual_sha}"
        end
      end
      failures.concat(check_oracle(oracle, result, expect))
    end

    assert_empty failures, failures.join("\n")
  end

  private

  def resolve_oracle_pdf(oracle)
    entry_id = oracle['manifest_entry_id']
    if entry_id && !entry_id.to_s.empty?
      found = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_manifest_pdf(entry_id)
      return found if found
    end

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
      placement_rate_min: :placement_rate,
      rotated_pages_min: :rotated_pages,
      rotated_placement_rate_min: :rotated_placement_rate
    }.each do |exp_key, res_key|
      next unless expect.key?(exp_key.to_s)
      floor = expect[exp_key.to_s]
      val = result[res_key]
      val = val.to_f if res_key == :placement_rate
      next if val.to_f >= floor.to_f
      out << "#{id}: #{exp_key} expected >= #{floor}, got #{val}"
    end

    expected_text_hash = expect['text_hash'].to_s.downcase
    unless expected_text_hash.empty?
      actual_text_hash = result[:text_hash].to_s.downcase
      if actual_text_hash != expected_text_hash
        out << "#{id}: text_hash expected #{expected_text_hash}, got #{actual_text_hash}"
      end
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
