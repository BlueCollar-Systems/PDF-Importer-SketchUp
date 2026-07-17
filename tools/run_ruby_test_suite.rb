#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rbconfig'

repo_root = File.expand_path('..', File.dirname(__FILE__))
parse_gate = File.join(repo_root, 'tools', 'ruby22_real_parse_gate.rb')
source_gate = File.join(repo_root, 'tools', 'run_ruby22_exact_source.sh')

source_gate_opt_in = ENV['BCS_RUBY22_SOURCE_GATE'].to_s.strip.downcase
gate_passed = if source_gate_opt_in =~ /\A(?:1|true|yes)\z/
                system('bash', source_gate, '--parse')
              else
                system(RbConfig.ruby, '--disable-gems', parse_gate)
              end
unless gate_passed
  warn 'ERROR: test suite stopped because the exact Ruby 2.2.4-p230 parse gate failed'
  warn 'Use the verified official-source gate in Linux or a current Linux build container:'
  warn "  BCS_RUBY22_SOURCE_GATE=1 ruby #{File.join(repo_root, 'tools', 'run_ruby_test_suite.rb')}"
  warn 'Or set RUBY22_EXE (or BCS_RUBY22_EXE) to a separately installed exact interpreter.'
  exit 1
end

tests = if ARGV.empty?
          patterns = [
            File.join(repo_root, 'test', '**', '*_test.rb'),
            File.join(repo_root, 'test', '**', 'test_*.rb')
          ]
          patterns.flat_map { |pattern| Dir.glob(pattern) }.uniq.sort
        else
          ARGV.map { |path| File.expand_path(path, repo_root) }
        end

if tests.empty?
  warn 'ERROR: no Ruby tests found'
  exit 1
end

failures = []
tests.each do |test_file|
  puts "Ruby test: #{test_file}"
  # Minitest can be supplied as a default/installed gem on the developer
  # runtime. The exact 2.2.4 parser gate above remains gem-independent, but
  # disabling gems here would prevent an otherwise valid local suite run.
  passed = system(RbConfig.ruby, test_file)
  failures << test_file unless passed
end

unless failures.empty?
  warn "ERROR: #{failures.length} Ruby test file(s) failed:"
  failures.each { |path| warn "  #{path}" }
  exit 1
end

puts "PASS: #{tests.length} Ruby test file(s) passed after the exact parse gate"
