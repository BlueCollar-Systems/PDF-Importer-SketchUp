#!/usr/bin/env ruby
# frozen_string_literal: true

# Run golden_oracle_test.rb against BCS_PRIVATE_VALIDATION_ROOT (or PDF_PRIVATE_VALIDATION_ROOT).
# Usage:
#   ruby tools/run_golden_oracle_test.rb
#   BCS_PRIVATE_VALIDATION_ROOT=__private_validation_assets_not_configured__ ruby tools/run_golden_oracle_test.rb

require 'fileutils'

repo_root = File.expand_path('..', __dir__)
test_path = File.join(repo_root, 'test', 'golden_oracle_test.rb')

unless File.file?(test_path)
  warn "Missing #{test_path}"
  exit 1
end

corpus_root = ENV['BCS_PRIVATE_VALIDATION_ROOT'].to_s.strip
corpus_root = ENV['PDF_PRIVATE_VALIDATION_ROOT'].to_s.strip if corpus_root.empty?
corpus_root = '__private_validation_assets_not_configured__' if corpus_root.empty?

unless File.directory?(corpus_root)
  warn "BCS_PRIVATE_VALIDATION_ROOT not found: #{corpus_root}"
  exit 1
end

ENV['BCS_PRIVATE_VALIDATION_ROOT'] = File.expand_path(corpus_root)
puts "BCS_PRIVATE_VALIDATION_ROOT=#{ENV['BCS_PRIVATE_VALIDATION_ROOT']}"
exec(Gem.ruby, test_path, *ARGV)
