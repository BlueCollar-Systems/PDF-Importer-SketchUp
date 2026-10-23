#!/usr/bin/env ruby
# The import report's process memory is read in process on Windows.
#
# QAReport.sample_process_mb used to start PowerShell for one number at the
# end of every import (1-2 s on the measured PC). It now reads the working
# set through K32GetProcessMemoryInfo (Fiddle) and keeps PowerShell only as
# the fallback.

require 'minitest/autorun'
require 'minitest/mock'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

class ProcessMemoryReaderTest < Minitest::Test
  QA = BlueCollarSystems::PDFVectorImporter::QAReport

  def test_the_in_process_read_is_used_and_powershell_is_not_started
    started = 0
    QA.stub(:windows_working_set_bytes, 512 * 1024 * 1024) do
      QA.stub(:powershell_working_set_bytes, lambda { started += 1; 1 }) do
        assert_equal 512.0, QA.windows_process_mb
      end
    end
    assert_equal 0, started
  end

  def test_powershell_is_the_fallback_when_the_in_process_read_is_unavailable
    QA.stub(:windows_working_set_bytes, nil) do
      QA.stub(:powershell_working_set_bytes, 3 * 1024 * 1024) do
        assert_equal 3.0, QA.windows_process_mb
      end
    end
    QA.stub(:windows_working_set_bytes, nil) do
      QA.stub(:powershell_working_set_bytes, 0) do
        assert_equal 0.0, QA.windows_process_mb
      end
    end
  end

  def test_the_real_windows_read_is_positive_and_needs_no_child_process
    skip 'Windows only' unless RUBY_PLATFORM =~ /mswin|mingw|cygwin/i
    first = QA.windows_working_set_bytes
    refute_nil first, 'K32GetProcessMemoryInfo must be readable through Fiddle'
    assert_operator first, :>, 1024 * 1024
    assert_operator first, :<, 1024 * 1024 * 1024 * 1024
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    10.times { assert_operator QA.windows_working_set_bytes, :>, 0 }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.5, 'ten reads must not start any process'
    QA.stub(:powershell_working_set_bytes, lambda { raise 'PowerShell must not start' }) do
      assert_operator QA.sample_process_mb, :>, 1.0
    end
  end

  def test_the_counters_layout_matches_the_platform
    skip 'Windows only' unless RUBY_PLATFORM =~ /mswin|mingw|cygwin/i
    reader = QA.windows_memory_reader
    refute_nil reader
    size_t = reader[:size_t]
    assert_includes [4, 8], size_t
    assert_equal 8 + (8 * size_t), reader[:counters_size]
  end
end
