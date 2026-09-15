#!/usr/bin/env ruby
# test/cli_page_selection_test.rb
#
# Headless CLI page selection must honour --pages. ImportDialog.build_opts
# converts the --pages text into an Array of page numbers (or :all) before
# CLI.extract_pdf sees it; CLI.normalize_pages used to stringify that Array
# ("[1]"), find no valid page, and silently fall back to EVERY page, so
# `--pages 1` on a 27-page submittal parsed and reported all 27 pages.
#
# Fixture PDFs are generated here from fictional content (PRIV-1).
# Ruby 2.2 compatible syntax throughout (RB22).

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'

REPO_ROOT = File.expand_path('..', __dir__)
require File.join(REPO_ROOT, 'test', 'support', 'synthetic_pdf_builder')
require File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer', 'cli')

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

class CliPageSelectionTest < Minitest::Test
  CLI = BlueCollarSystems::PDFVectorImporter::CLI
  DIALOG = BlueCollarSystems::PDFVectorImporter::ImportDialog

  def normalize(spec, count)
    CLI.send(:normalize_pages, spec, count)
  end

  def test_array_spec_from_build_opts_selects_only_those_pages
    assert_equal [1], normalize([1], 27)
    assert_equal [2, 5], normalize([5, 2, 2], 27)
    assert_equal [1, 2, 3], normalize([1, 2, 3], 3)
  end

  def test_array_spec_drops_out_of_range_pages_and_falls_back_like_text
    assert_equal [3], normalize([3, 40], 27)
    # Consistent with the text-spec contract: nothing valid => every page.
    assert_equal [1, 2, 3], normalize([99], 3)
    assert_equal [1, 2, 3], normalize([], 3)
  end

  def test_symbol_and_text_specs_are_unchanged
    assert_equal [1, 2, 3], normalize(:all, 3)
    assert_equal [1, 2, 3], normalize('All', 3)
    assert_equal [1], normalize('1', 27)
    assert_equal [1, 2, 3], normalize('1-3', 27)
    assert_equal [1, 3, 5], normalize('1,3,5', 27)
    assert_equal [], normalize([1], 0)
  end

  def test_cli_args_through_build_opts_reach_extract_as_one_page
    cli_opts = CLI.parse_args(['--input', 'fictional.pdf', '--pages', '1'])
    built = DIALOG.send(:build_opts, { pages: cli_opts[:pages], import_mode: 'auto' })
    assert_equal [1], built[:pages], 'build_opts yields an Array page list'
    assert_equal [1], normalize(built[:pages], 27)
  end

  def test_headless_cli_reports_only_the_requested_page
    Dir.mktmpdir('cli_pages_') do |tmp|
      pdf = File.join(tmp, 'three_pages.pdf')
      SyntheticPdfBuilder.write_pages(pdf, [
        "0 0 m 10 10 l S\n20 20 m 30 30 l S\n",
        "0 0 m 10 10 l S\n",
        "0 0 m 10 10 l S\n5 5 m 6 6 l S\n7 7 m 8 8 l S\n"
      ])
      cli_tool = File.join(REPO_ROOT, 'tools', 'su_pdf_cli.rb')
      summary_path = File.join(tmp, 'summary.json')
      report_path = File.join(tmp, 'report.json')
      out, err, status = Open3.capture3(
        RbConfig.ruby, cli_tool, pdf,
        '--pages', '2', '--no-text', '--no-primitives-json',
        '--output-dir', File.join(tmp, 'out'),
        '--report', report_path, '--json', summary_path
      )
      assert status.success?, "CLI failed: #{err}\n#{out}"
      summary = JSON.parse(File.read(summary_path))
      assert_equal 1, summary['pages'], summary.inspect
      assert_equal 1, summary['vector_paths'], summary.inspect
      report = JSON.parse(File.read(report_path))
      assert_equal 1, report['input']['pages'], report['input'].inspect
    end
  end
end
