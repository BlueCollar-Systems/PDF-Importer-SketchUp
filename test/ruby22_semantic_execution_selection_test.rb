#!/usr/bin/env ruby
runner = File.read(File.expand_path('../tools/run_ruby22_exact_source.sh', File.dirname(__FILE__)))
required = %w[
  test/content_stream_tokenizer_test.rb
  test/geometry_builder_staging_test.rb
  test/ownership_bookkeeping_test.rb
]
missing = required.reject { |path| runner.lines.any? { |line| line.strip == path } }
unless missing.empty?
  warn "missing exact Ruby 2.2 semantic tests: #{missing.join(', ')}"
  exit 1
end
puts 'RUBY22_SEMANTIC_SELECTION_OK count=3'
