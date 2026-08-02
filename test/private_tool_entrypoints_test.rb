require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class PrivateToolEntrypointsTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  POWERSHELL = 'C:/Program Files/PowerShell/7/pwsh.exe'

  def test_probe_uses_environment_resource_board_and_fails_before_host_work
    Dir.mktmpdir('su-private-tool') do |root|
      missing_board = File.join(root, 'missing-resource-board.md')
      command = [
        '&', ps_quote(File.join(REPO_ROOT, 'tools', 'run_skp_probe.ps1')),
        '-Script', ps_quote(File.join(root, 'unused.rb')),
        '-OutFile', ps_quote(File.join(root, 'unused.json')),
        '-EnvVars', '@{}',
        '-Claimant', ps_quote('__privacy_entrypoint_test__')
      ].join(' ')
      output, status = Open3.capture2e(
        { 'BCS_RESOURCE_BOARD_PATH' => missing_board },
        POWERSHELL, '-NoProfile', '-NonInteractive', '-Command', command
      )

      refute status.success?
      assert_includes output, missing_board
      assert_match(/RESOURCE_BOARD\.md is missing/, output)
      refute File.exist?(File.join(root, 'unused.json'))
    end
  end

  def test_source_diagnostic_requires_exactly_two_explicit_pdf_paths
    Dir.mktmpdir('su-source-diagnostic') do |root|
      missing_pdf = File.join(root, 'one.pdf')
      output, status = Open3.capture2e(
        RbConfig.ruby,
        File.join(REPO_ROOT, 'tools', 'verify_welding_svg_3d_source.rb'),
        missing_pdf
      )

      refute status.success?
      assert_match(/expected exactly two PDF paths/, output)
      refute_match(/file_missing/, output)
    end
  end

  private

  def ps_quote(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end
end
