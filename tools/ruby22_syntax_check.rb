#!/usr/bin/env ruby
# tools/ruby22_syntax_check.rb
# SketchUp 2017 (Ruby 2.2) forbidden-syntax scanner.
#
# Usage:
#   ruby tools/ruby22_syntax_check.rb
#   ruby tools/ruby22_syntax_check.rb --include-tests
#
# Exit 0 = clean, 1 = incompatible syntax found.

require 'optparse'

REPO_ROOT = File.expand_path('..', __dir__)
EXT_DIR   = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
TEST_DIR  = File.join(REPO_ROOT, 'test')

INCLUDE_TESTS = ARGV.include?('--include-tests')

MODERN_METHOD_PATTERN =
  /&\.|(?<!\.)\.(?:match\?|positive\?|negative\?|dig|sum|then|yield_self|filter|filter_map|tally|transform_values|delete_prefix|delete_suffix|fetch_values|chunk_while)(?=[^A-Za-z0-9_]|$)/
ENDLESS_RANGE_PATTERN   = /(^|[^.])\.\.(?!\.)\s*(?:[\]\)\}]|$)/
BEGINLESS_RANGE_PATTERN = /(?:\[|\()\s*\.\.(?!\.)/

def scan_dirs
  dirs = [EXT_DIR]
  dirs << TEST_DIR if INCLUDE_TESTS
  dirs
end

def strip_noise(line)
  stripped = line.strip
  return '' if stripped.start_with?('#')

  line.
    gsub(/'([^'\\]|\\.)*'/, "''").
    gsub(/"([^"\\]|\\.)*"/, '""').
    sub(/\s+#.*$/, '')
end

def scan_file(path)
  rel = path.sub("#{REPO_ROOT}/", '').sub("#{REPO_ROOT}\\", '')
  hits = []
  File.open(path, 'rb') do |io|
    io.each_line.with_index do |raw_line, idx|
      line = raw_line.force_encoding('UTF-8')
      line = line.encode('UTF-8', 'binary', invalid: :replace, undef: :replace)
      scan_line = strip_noise(line)

      if scan_line =~ MODERN_METHOD_PATTERN
        hits << "#{rel}:#{idx + 1}: #{line.strip} (Ruby 2.3+ method)"
      end
      if scan_line =~ ENDLESS_RANGE_PATTERN || scan_line =~ BEGINLESS_RANGE_PATTERN
        hits << "#{rel}:#{idx + 1}: #{line.strip} (Ruby 2.6+ range)"
      end
    end
  end
  hits
end

all_hits = []
scan_dirs.each do |dir|
  next unless File.directory?(dir)

  Dir.glob(File.join(dir, '**', '*.rb')).sort.each do |rb|
    next if rb.end_with?('ruby22_syntax_check.rb')
    next if rb.end_with?('ruby22_compat_test.rb')
    all_hits.concat(scan_file(rb))
  end
end

if all_hits.empty?
  scope = INCLUDE_TESTS ? 'extension + test' : 'extension'
  puts "Ruby 2.2 syntax check passed (#{scope})"
  exit 0
end

puts "Ruby 2.2 incompatible syntax (#{all_hits.length} hit(s)):"
all_hits.each { |hit| puts "  #{hit}" }
exit 1
