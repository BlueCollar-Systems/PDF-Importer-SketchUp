#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'

class LoggerBufferTest < Minitest::Test
  L = BlueCollarSystems::PDFVectorImporter::Logger

  def teardown
    L.send(:close_log)
  end

  def test_import_log_uses_buffered_writes
    L.reset
    file = L.instance_variable_get(:@log_file)

    refute_nil file
    refute file.sync, 'import log should not fsync every line on slow disks'
  end

  def test_write_line_flushes_in_batches
    L.reset
    62.times { |idx| L.info('Test', "line #{idx}") }

    assert_equal 0, L.instance_variable_get(:@writes_since_flush)
  end
end
