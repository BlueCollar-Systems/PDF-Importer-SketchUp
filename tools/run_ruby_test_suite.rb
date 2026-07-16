#!/usr/bin/env ruby
# Stable, Ruby-2.2-compatible suite gate. In strict mode every skip is a
# required-fixture failure, so a green summary cannot conceal missing evidence.

require 'open3'
require 'optparse'
require 'rbconfig'

options = {
  test_dir: File.expand_path('../test', __dir__),
  strict_fixtures: ENV['PRIVATE_VALIDATION_CI_STRICT'].to_s.strip == '1'
}

OptionParser.new do |parser|
  parser.on('--test-dir DIR') { |value| options[:test_dir] = value }
  parser.on('--strict-fixtures') { options[:strict_fixtures] = true }
end.parse!(ARGV)

test_dir = File.expand_path(options[:test_dir])
test_files = Dir.glob(File.join(test_dir, '*_test.rb')).sort
ruby_exe = File.join(
  RbConfig::CONFIG['bindir'],
  RbConfig::CONFIG['ruby_install_name'].to_s +
    RbConfig::CONFIG['EXEEXT'].to_s
)

if test_files.empty?
  warn "FULL RUBY SUITE: FAIL (0 files found in #{test_dir})"
  exit 1
end

failed_files = []
required_skips = []

test_files.each do |test_file|
  stdout, stderr, status = Open3.capture3(ruby_exe, test_file)
  combined = stdout.to_s + stderr.to_s
  skip_matches = combined.scan(/(\d+)\s+skips?\b/i)
  summary_skip_count = skip_matches.empty? ? 0 : skip_matches.last[0].to_i
  explicit_skip_count = combined.each_line.inject(0) do |count, line|
    missing_fixture = line =~ /^\s*SKIP(?:\s|\(|:)/i ||
                      line =~ /^\s*WARN:.*(?:fixture|PDF|validation).*(?:missing|not found|not configured)/i
    count + (missing_fixture ? 1 : 0)
  end
  skip_count = [summary_skip_count, explicit_skip_count].max

  unless status.success?
    failed_files << test_file
    puts "TEST FAILURE: #{File.basename(test_file)}"
    puts combined
    next
  end

  if options[:strict_fixtures] && skip_count > 0
    required_skips << [test_file, skip_count]
    puts "REQUIRED SKIP: #{File.basename(test_file)} (#{skip_count})"
    puts combined
  end
end

if failed_files.empty? && required_skips.empty?
  puts "FULL RUBY SUITE: PASS (#{test_files.length} files, 0 required skips)"
  exit 0
end

puts "FULL RUBY SUITE: FAIL (#{test_files.length} files, " \
     "#{failed_files.length} failed, #{required_skips.length} required skips)"
exit 1
