#!/usr/bin/env ruby
# frozen_string_literal: true

# Run golden_oracle_test.rb against BCS_CORPUS_ROOT (or PDF_TEST_CORPUS).
# Usage:
#   ruby tools/run_golden_oracle_test.rb
#   BCS_CORPUS_ROOT=C:/1pdf-test-corpus ruby tools/run_golden_oracle_test.rb

require 'fileutils'

repo_root = File.expand_path('..', __dir__)
test_path = File.join(repo_root, 'test', 'golden_oracle_test.rb')

unless File.file?(test_path)
  warn "Missing #{test_path}"
  exit 1
end

corpus_root = ENV['BCS_CORPUS_ROOT'].to_s.strip
corpus_root = ENV['PDF_TEST_CORPUS'].to_s.strip if corpus_root.empty?
corpus_root = 'C:/1pdf-test-corpus' if corpus_root.empty?

unless File.directory?(corpus_root)
  warn "BCS_CORPUS_ROOT not found: #{corpus_root}"
  exit 1
end

ENV['BCS_CORPUS_ROOT'] = File.expand_path(corpus_root)
puts "BCS_CORPUS_ROOT=#{ENV['BCS_CORPUS_ROOT']}"
exec(Gem.ruby, test_path, *ARGV)
