#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/compatibility_report'

class CompatibilityReportIsolationTest < Minitest::Test
  REPORT = BlueCollarSystems::PDFVectorImporter::CompatibilityReport
  TEMP = BlueCollarSystems::PDFVectorImporter::SafeTemp

  def test_saved_report_remains_bound_to_its_original_host
    Dir.mktmpdir('bc_compatibility_isolation_') do |root|
      first = nil
      second = nil
      TEMP.stub(:root, root) do
        first = REPORT.send(:save_report, 'SketchUp host A; version A')
        second = REPORT.send(:save_report, 'SketchUp host B; version B')
      end
      refute_nil first
      refute_nil second
      refute_equal first, second
      assert_equal 'SketchUp host A; version A', File.read(first)
      assert_equal 'SketchUp host B; version B', File.read(second)
      assert_equal 'compatibility_report.txt', File.basename(first)
      assert first.ascii_only?
    end
  end
end
