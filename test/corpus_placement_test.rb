#!/usr/bin/env ruby
# test/corpus_placement_test.rb
# Headless corpus gate: parser + text extraction + label placement simulation.
#
# Usage:
#   ruby test/corpus_placement_test.rb
#   CORPUS_UPDATE_BASELINES=1 ruby test/corpus_placement_test.rb
#
# Exit 0 = pass, non-zero = failure.

require 'fileutils'
require_relative 'support/corpus_harness'

UPDATE_BASELINES = ENV['CORPUS_UPDATE_BASELINES'] == '1' || ARGV.include?('--update-baselines')
STRICT_EMPTY = ENV['CORPUS_CI_STRICT'] != '0'

$failures = []
$warnings = []

def fail!(msg)
  $failures << msg
end

def warn!(msg)
  $warnings << msg
end

pdfs = BlueCollarSystems::PDFVectorImporter::CorpusPaths.collect_corpus_pdfs

if pdfs.empty?
  msg = 'No corpus PDFs found. Set BCS_CORPUS_ROOT or mirror PDFs under Desktop/corpus paths.'
  if STRICT_EMPTY
    fail!(msg)
    puts "FAIL: #{msg}"
    exit 1
  else
    warn!(msg)
    puts "WARN: #{msg}"
    exit 0
  end
end

puts '=' * 100
puts "Corpus Placement CI — #{pdfs.length} PDFs"
puts "Baselines: #{CorpusHarness::BASELINE_DIR}"
puts "Update baselines: #{UPDATE_BASELINES}"
puts '=' * 100

results = []
pdfs.each_with_index do |info, idx|
  print "#{idx + 1}/#{pdfs.length}  #{info[:corpus_key]} ... "
  $stdout.flush
  result = CorpusHarness.analyze_pdf(info)
  results << result

  if result[:status] != 'OK'
    if CorpusHarness.expected_refusal?(info, result)
      CorpusHarness.mark_expected_refusal!(result)
      warn!("Expected refusal: #{info[:corpus_key]} — #{result[:error]}")
      puts "EXPECTED REFUSAL  #{result[:error]}"
    elsif result[:status] == 'TIMEOUT' && result[:heavy]
      warn!("Heavy PDF timeout (warn-only): #{info[:corpus_key]} — #{result[:error]}")
      puts "TIMEOUT (heavy, warn-only)  #{result[:error]}"
    else
      fail!("[#{result[:status]}] #{info[:corpus_key]}: #{result[:error]}")
      puts "#{result[:status]}  #{result[:error]}"
    end
    next
  end

  threshold = CorpusHarness.placement_threshold(result)
  if result[:placement_total].to_i > 0 && result[:placement_rate].to_f < threshold
    fail!(
      "Placement rate #{result[:placement_rate]} below #{threshold} for #{info[:corpus_key]}"
    )
  end

  baseline = CorpusHarness.load_baseline(info[:corpus_key])
  if UPDATE_BASELINES
    path = CorpusHarness.save_baseline(result)
    puts "OK  baseline updated -> #{File.basename(path)}"
  elsif baseline.nil?
    warn!("Missing baseline for #{info[:corpus_key]} — run tools/generate_corpus_baselines.rb --update")
    puts "OK  (no baseline yet)"
  else
    mismatches = CorpusHarness.compare_baseline(result, baseline)
    if mismatches.empty?
      puts "OK  matches baseline"
    else
      mismatches.each { |m| fail!("Baseline mismatch #{info[:corpus_key]}: #{m}") }
      puts "DRIFT  #{mismatches.length} field(s)"
    end
  end
  $stdout.flush
end

CorpusHarness.print_summary_table(results)

if !$warnings.empty?
  puts
  puts 'WARNINGS:'
  $warnings.each { |w| puts "  - #{w}" }
end

if $failures.empty?
  puts
  puts "PASS: corpus placement gate (#{results.length} PDFs)"
  exit 0
else
  puts
  puts "FAIL: #{$failures.length} issue(s)"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
