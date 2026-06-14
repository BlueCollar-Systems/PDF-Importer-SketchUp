#!/usr/bin/env ruby
# tools/generate_corpus_baselines.rb
# Regenerate corpus placement baselines for headless SU CI.
#
# Usage:
#   ruby tools/generate_corpus_baselines.rb
#   ruby tools/generate_corpus_baselines.rb --update

require_relative '../test/support/corpus_harness'

update = ARGV.include?('--update') || ENV['CORPUS_UPDATE_BASELINES'] == '1'
unless update
  warn 'Refusing to write without --update (or CORPUS_UPDATE_BASELINES=1).'
  exit 2
end

pdfs = BlueCollarSystems::PDFVectorImporter::CorpusPaths.collect_corpus_pdfs
if pdfs.empty?
  warn 'No corpus PDFs found.'
  exit 1
end

puts "Generating baselines for #{pdfs.length} PDFs..."
written = 0
failed = 0

pdfs.each_with_index do |info, idx|
  print "#{idx + 1}/#{pdfs.length}  #{info[:corpus_key]} ... "
  $stdout.flush
  result = CorpusHarness.analyze_pdf(info)
  if result[:status] != 'OK'
    puts "SKIP  #{result[:error]}"
    failed += 1
    next
  end
  path = CorpusHarness.save_baseline(result)
  written += 1
  puts "OK  -> #{File.basename(path)}"
end

puts
puts "Wrote #{written} baseline(s) to #{CorpusHarness::BASELINE_DIR}"
puts "Skipped #{failed} PDF(s) due to parse/timeout errors" if failed > 0
exit failed.positive? ? 1 : 0
