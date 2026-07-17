#!/usr/bin/env ruby
# test/import_health_test.rb
# Unit tests for ImportHealth helpers without SketchUp runtime.

require 'minitest/autorun'

module UI
  class << self
    attr_reader :last_message
  end

  def self.messagebox(msg)
    @last_message = msg
    nil
  end
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

  def test_failed_representation_contract_is_preserved_and_shown_loudly
    H.record!({
      pages: 1, edges: 2, text: 0, layers: [],
      import_contract_ready: {
        ready: false,
        errors: ['source_delivery_set_mismatch']
      },
      representation_fidelity: {
        ready: false,
        errors: ['source_delivery_set_mismatch']
      }
    }, 'fixture.pdf')

    assert_equal false, H.snapshot[:import_contract_ready][:ready]
    H.show
    assert_includes UI.last_message, 'QA contract: NOT READY'
    assert_includes UI.last_message, 'source_delivery_set_mismatch'
  end
end
