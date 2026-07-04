#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'

REPO_ROOT = File.expand_path('..', __dir__)
CLI = File.join(REPO_ROOT, 'tools', 'su_batch_cli.rb')

class BatchCliTest < Minitest::Test
  def run_cli(*args)
    cmd = ['ruby', CLI] + args
    Open3.capture2e(*cmd)
  end

  def test_preflight_exits_zero
    out, status = run_cli('--preflight')
    assert status.success?, out
    assert_includes out, 'BCS-ARCH-001'
    assert_includes out, 'SketchUp.exe'
  end

  def test_missing_input_exits_nonzero
    _out, status = run_cli
    refute status.success?
  end

  def test_refuses_non_pdf
    Dir.mktmpdir('su_batch_') do |dir|
      bad = File.join(dir, 'not.pdf')
      File.write(bad, 'hello')
      out, status = run_cli(bad)
      refute status.success?, out
      assert_includes out, '"failed": 1'
    end
  end

  def test_analyzes_minimal_pdf_and_writes_report
    Dir.mktmpdir('su_batch_') do |dir|
      pdf = File.join(dir, 'minimal.pdf')
      File.binwrite(
        pdf,
        "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\nstartxref\n0\n%%EOF\n"
      )
      report_dir = File.join(dir, 'reports')
      out, status = run_cli(pdf, '--report-dir', report_dir, '--geometry-sidecar')
      assert status.success?, out
      report_path = File.join(report_dir, 'minimal_import_report.json')
      assert File.file?(report_path), 'expected import_report.json'
      report = JSON.parse(File.read(report_path))
      assert_equal 'bcs.import_report/1.1', report['schema']
      assert report['extra']['import_contract_ready']
      sidecar_path = File.join(report_dir, 'minimal_geometry_sidecar.json')
      assert File.file?(sidecar_path)
    end
  end
end
