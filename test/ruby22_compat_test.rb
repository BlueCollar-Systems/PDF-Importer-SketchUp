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
  /&\.|(?<!\.)\.(?:match\?|casecmp\?|positive\?|negative\?|append|dig|sum|then|yield_self|filter|filter_map|tally|transform_values|transform_keys|delete_prefix|delete_suffix|fetch_values|chunk_while|clamp|unpack1|digits|grep_v|bsearch_index)(?=[^A-Za-z0-9_]|$)/
ENDLESS_RANGE_PATTERN   = /(^|[^.])\.\.(?!\.)\s*(?:[\]\)\}]|$)/
BEGINLESS_RANGE_PATTERN = /(?:\[|\()\s*\.\.(?!\.)/

TASK5_REPORTING_RANGES = [
  [
    File.join(EXT_DIR, 'bc_pdf_vector_importer', 'geometry_builder.rb'),
    'def mesh_text_attempt_sample',
    'def mesh_text_matrix_x_scale'
  ],
  [
    File.join(EXT_DIR, 'bc_pdf_vector_importer', 'main.rb'),
    'def self.merge_text_height_samples!',
    'def self.new_import_session_id'
  ],
  [
    File.join(EXT_DIR, 'bc_pdf_vector_importer', 'qa_report.rb'),
    'def telemetry_numeric_value',
    'def model_3d_intent_block'
  ]
].freeze

RUBY22_REPORTING_FORBIDDEN_METHOD_PATTERN =
  /\.(?:append|dig|slice|compact)\s*(?:\(|\b)/

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

  def test_task5_reporting_path_avoids_post_ruby22_collection_apis
    hits = []
    TASK5_REPORTING_RANGES.each do |path, start_marker, end_marker|
      source = File.binread(path)
      start_index = source.index(start_marker)
      end_index = source.index(end_marker, start_index.to_i + start_marker.length)
      refute_nil start_index, "missing compatibility range start: #{start_marker}"
      refute_nil end_index, "missing compatibility range end: #{end_marker}"
      next if start_index.nil? || end_index.nil?

      source[start_index...end_index].each_line.with_index do |line, offset|
        next unless strip_noise(line) =~ RUBY22_REPORTING_FORBIDDEN_METHOD_PATTERN
        hits << "#{File.basename(path)} reporting line +#{offset + 1}: #{line.strip}"
      end
    end
    assert_empty hits,
                 "Task 5 reporting uses APIs unavailable in SketchUp 2017 Ruby 2.2:\n#{hits.join("\n")}"
  end

  def test_mesh_width_metric_avoids_ruby22_void_value_expression
    path = File.join(EXT_DIR, 'bc_pdf_vector_importer', 'geometry_builder.rb')
    source = File.binread(path)
    start_index = source.index('def mesh_text_bbox_run_width_inches')
    end_index = source.index('def mesh_text_residual_x_scale', start_index.to_i)
    refute_nil start_index, 'missing mesh bbox-run width metric method'
    refute_nil end_index, 'missing mesh residual metric method'
    return if start_index.nil? || end_index.nil?

    method_source = source[start_index...end_index]
    refute_match(
      /=\s*if\b.*?\breturn\b/m,
      method_source,
      'Ruby 2.2 rejects return inside an if-expression assigned to a value'
    )
  end

  def test_text_parser_append_buffers_are_explicitly_mutable
    path = File.join(EXT_DIR, 'bc_pdf_vector_importer', 'text_parser.rb')
    source = File.binread(path)
    forbidden = [
      /^\s*out = ""\s*$/,
      /^\s*out = ""\.b\s*$/,
      /^\s*text = ""\s*$/,
      /^\s*oct = esc\s*$/
    ]
    hits = []
    source.each_line.with_index do |line, index|
      forbidden.each do |pattern|
        hits << "#{index + 1}: #{line.strip}" if line =~ pattern
      end
    end

    assert_empty hits,
                 "append targets must remain mutable under future frozen-string defaults:\n#{hits.join("\n")}"
    assert_operator source.scan('String.new').length, :>=, 4,
                    'known append buffers must use Ruby-2.2-compatible String.new'
  end
end
