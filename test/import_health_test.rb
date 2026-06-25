#!/usr/bin/env ruby
# test/import_health_test.rb
# Unit tests for ImportHealth helpers without SketchUp runtime.

require 'minitest/autorun'

module UI
  def self.messagebox(_msg); nil; end
end

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_health'

class ImportHealthTest < Minitest::Test
  H = BlueCollarSystems::PDFVectorImporter::ImportHealth

  def test_short_path_empty
    assert_equal 'n/a', H.short_path('')
    assert_equal 'n/a', H.short_path(nil)
  end

  def test_short_path_unchanged_when_short
    path = 'C:/Projects/drawing.pdf'
    assert path.length <= 72
    assert_equal path, H.short_path(path)
  end

  def test_short_path_unchanged_at_boundary
    path = 'x' * 72
    assert_equal 72, path.length
    assert_equal path, H.short_path(path)
  end

  def test_short_path_truncates_long_paths_with_ruby22_slice
    path = 'C:/very/long/' + ('nested/' * 12) + 'import_report.json'
    assert path.length > 72, 'fixture path should exceed display limit'

    result = H.short_path(path)
    assert result.start_with?('...'), 'expected leading ellipsis'
    assert_equal 72, result.length, '3-char prefix + 69-char tail'
    assert_equal path[-69, 69], result[3..-1], 'tail must use two-arg String#[] (Ruby 2.2 safe)'
  end
end
