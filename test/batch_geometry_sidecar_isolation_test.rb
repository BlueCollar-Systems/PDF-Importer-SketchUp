#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require_relative 'support/synthetic_pdf_builder'

class BatchGeometrySidecarIsolationTest < Minitest::Test
  CLI = File.expand_path('../tools/su_batch_cli.rb', __dir__)

  def test_different_page_selections_and_modes_retain_their_own_sidecars
    Dir.mktmpdir('bc_batch_isolation_') do |dir|
      source_dir = File.join(dir, 'source')
      Dir.mkdir(source_dir)
      pdf = File.join(source_dir, 'drawing.pdf')
      SyntheticPdfBuilder.write_pages(pdf, [
        "0 0 m 10 10 l S\n20 20 m 30 30 l S\n",
        "0 0 m 10 10 l S\n",
        "0 0 m 10 10 l S\n5 5 m 6 6 l S\n7 7 m 8 8 l S\n"
      ])

      first = run_cli(dir, pdf, '--pages', '1', '--mode', 'vector')
      first_sidecar = File.binread(first.fetch('geometry_sidecar'))
      first_report = File.binread(first.fetch('import_report'))
      second = run_cli(dir, pdf, '--pages', '2-3', '--mode', 'hybrid')

      refute_equal first.fetch('geometry_sidecar'), second.fetch('geometry_sidecar')
      refute_equal first.fetch('import_report'), second.fetch('import_report')
      [first, second].each do |result|
        assert_equal File.dirname(result.fetch('import_report')),
                     File.dirname(result.fetch('geometry_sidecar')),
                     'implicit sidecar must stay alongside its own report'
      end
      assert_equal first_sidecar, File.binread(first.fetch('geometry_sidecar'))
      assert_equal first_report, File.binread(first.fetch('import_report'))
      first_data = JSON.parse(first_sidecar)
      second_data = JSON.parse(File.read(second.fetch('geometry_sidecar')))
      assert_equal [1, 2, 'vector'],
                   first_data.values_at('pages', 'path_count', 'mode')
      assert_equal [2, 4, 'hybrid'],
                   second_data.values_at('pages', 'path_count', 'mode')
      assert_equal ['drawing.pdf'], (Dir.entries(source_dir) - ['.', '..']).sort
    end
  end

  def test_explicit_report_directory_preserves_public_filenames
    Dir.mktmpdir('bc_batch_explicit_') do |dir|
      pdf = File.join(dir, 'chosen.pdf')
      SyntheticPdfBuilder.write_pages(pdf, ["0 0 m 10 10 l S\n"])
      chosen = File.join(dir, 'operator-selected')
      result = run_cli(dir, pdf, '--report-dir', chosen)

      assert_equal File.join(chosen, 'chosen_import_report.json'),
                   result.fetch('import_report')
      assert_equal File.join(chosen, 'chosen_geometry_sidecar.json'),
                   result.fetch('geometry_sidecar')
      assert File.file?(result.fetch('import_report'))
      assert File.file?(result.fetch('geometry_sidecar'))
    end
  end

  private

  def run_cli(temp_root, pdf, *args)
    aggregate_path = File.join(Dir.mktmpdir('receipt-', temp_root), 'aggregate.json')
    stdout, stderr, status = Open3.capture3(
      { 'BC_PDF_TEMP_DIR' => temp_root }, RbConfig.ruby, CLI, pdf,
      '--geometry-sidecar', '--json', aggregate_path, *args
    )
    assert status.success?, "batch failed: #{stderr}\n#{stdout}"
    aggregate = JSON.parse(File.read(aggregate_path))
    assert_equal 1, aggregate.fetch('passed')
    result = aggregate.fetch('results').fetch(0)
    assert_equal 'OK', result.fetch('status')
    result
  end
end
