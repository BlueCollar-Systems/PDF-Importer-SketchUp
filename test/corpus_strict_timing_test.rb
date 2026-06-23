#!/usr/bin/env ruby
# test/corpus_strict_timing_test.rb
# Strict-mode timing budget on one named corpus PDF (Round-2 action #10).
#
# Usage (opt-in — not part of default corpus gate):
#   CORPUS_STRICT_TIMING=1 ruby test/corpus_strict_timing_test.rb
#   CORPUS_STRICT_TIMING=1 CORPUS_STRICT_TIMING_PDF=1017 ruby test/corpus_strict_timing_test.rb
#
# Uses normal (non-heavy) timeout from corpus_harness. Fails if wall-clock
# exceeds CORPUS_STRICT_TIMING_BUDGET_S (default 60s post-v3.7.55).

exit 0 unless ENV['CORPUS_STRICT_TIMING'] == '1'

require_relative 'support/corpus_harness'

slug = (ENV['CORPUS_STRICT_TIMING_PDF'] || '1017').strip
budget_s = (ENV['CORPUS_STRICT_TIMING_BUDGET_S'] || '60').to_f
budget_s = 60.0 if budget_s <= 0

pdf_path = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf(slug)
unless pdf_path && File.file?(pdf_path)
  warn "SKIP: corpus PDF #{slug.inspect} not found (set BCS_CORPUS_ROOT)"
  exit 0
end

info = {
  path: pdf_path,
  corpus_key: "strict_timing/#{File.basename(pdf_path)}",
  source_root: File.dirname(pdf_path),
  tag: 'strict_timing'
}

puts "Strict timing: #{File.basename(pdf_path)} (budget #{budget_s}s, normal timeout #{CorpusHarness::TIMEOUT_SECONDS}s)"
result = CorpusHarness.analyze_pdf(info)

if result[:status] != 'OK'
  warn "FAIL: #{result[:status]} — #{result[:error]}"
  exit 1
end

time_s = result[:time_s].to_f
puts "Elapsed: #{time_s.round(2)}s"
if time_s > budget_s
  warn "FAIL: #{File.basename(pdf_path)} took #{time_s.round(2)}s > #{budget_s}s budget"
  exit 1
end

puts "PASS: within #{budget_s}s budget"
exit 0
