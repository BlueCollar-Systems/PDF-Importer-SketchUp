#!/usr/bin/env ruby
# test/ruby22_compat_test.rb
# CI gate: extension Ruby must stay SketchUp 2017 (Ruby 2.2) compatible.
#
# Usage: ruby test/ruby22_compat_test.rb

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
EXT_DIR   = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
TEST_DIR  = File.join(REPO_ROOT, 'test')
LOADER    = File.join(EXT_DIR, 'bc_pdf_vector_importer.rb')

MODERN_METHOD_PATTERN =
  /&\.|(?<!\.)\.(?:match\?|positive\?|negative\?|dig|sum|then|yield_self|filter|filter_map|tally|transform_values|delete_prefix|delete_suffix|fetch_values|chunk_while)(?=[^A-Za-z0-9_]|$)/
ENDLESS_RANGE_PATTERN   = /(^|[^.])\.\.(?!\.)\s*(?:[\]\)\}]|$)/
BEGINLESS_RANGE_PATTERN = /(?:\[|\()\s*\.\.(?!\.)/

def strip_noise(line)
  stripped = line.strip
  return '' if stripped.start_with?('#')

  line.
    gsub(/'([^'\\]|\\.)*'/, "''").
    gsub(/"([^"\\]|\\.)*"/, '""').
    sub(/\s+#.*$/, '')
end

def collect_hits(root, label)
  hits = []
  Dir.glob(File.join(root, '**', '*.rb')).sort.each do |rb|
    next if File.basename(rb) == 'ruby22_compat_test.rb'
    rel = rb.sub("#{REPO_ROOT}/", '').sub("#{REPO_ROOT}\\", '')
    File.open(rb, 'rb') do |io|
      io.each_line.with_index do |raw_line, idx|
        line = raw_line.force_encoding('UTF-8')
        line = line.encode('UTF-8', 'binary', invalid: :replace, undef: :replace)
        scan_line = strip_noise(line)
        if scan_line =~ MODERN_METHOD_PATTERN
          hits << "#{label} #{rel}:#{idx + 1}: #{line.strip}"
        end
        if scan_line =~ ENDLESS_RANGE_PATTERN || scan_line =~ BEGINLESS_RANGE_PATTERN
          hits << "#{label} #{rel}:#{idx + 1}: #{line.strip}"
        end
      end
    end
  end
  hits
end

class Ruby22CompatTest < Minitest::Test
  def test_extension_has_no_ruby22_incompatible_syntax
    hits = collect_hits(EXT_DIR, '[ext]')
    assert_empty hits, "SketchUp 2017 incompatible syntax in extension:\n#{hits.join("\n")}"
  end

  def test_test_suite_has_no_ruby22_incompatible_syntax
    hits = collect_hits(TEST_DIR, '[test]')
    assert_empty hits, "SketchUp 2017 incompatible syntax in test suite:\n#{hits.join("\n")}"
  end

  def test_loader_parses_on_ruby22
    skip 'loader missing' unless File.exist?(LOADER)
    output = `ruby -c "#{LOADER}" 2>&1`
    assert $?.success?, "Loader syntax error: #{output.strip}"
  end
end
