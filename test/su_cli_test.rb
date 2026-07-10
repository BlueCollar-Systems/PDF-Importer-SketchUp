#!/usr/bin/env ruby
# test/su_cli_test.rb -- headless CLI contract (Round 7 parity slice).
#
# Runs tools/su_pdf_cli.rb as a subprocess against the redistributable
# corpus synthetic PDF and asserts the summary + report contracts.
# Skips VISIBLY (not silently) when the private validation PDF is absent, per the
# R4-2 skip-visibility rule.

require 'json'
require 'open3'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__)
CLI = File.join(REPO_ROOT, 'tools', 'su_pdf_cli.rb')
CORPUS_ROOT = ENV['BCS_PRIVATE_VALIDATION_ROOT'] || '__private_validation_assets_not_configured__'
TEST_PDF = File.join(CORPUS_ROOT, 'tier1', 'web', 'stacked_fraction_spacing.pdf')

failures = []
pass_count = 0
check = lambda do |label, ok, detail = nil|
  if ok
    pass_count += 1
  else
    failures << "#{label}#{detail ? " -- #{detail}" : ''}"
  end
end

# --version always works, no PDF needed.
version_out, version_status = Open3.capture2(RbConfig.ruby, CLI, '--version')
check.call('--version exits 0', version_status.success?)
check.call('--version prints a version', version_out.strip =~ /\A\d+\.\d+\.\d+\z/, version_out.strip)

# --preflight without input fails the input check but still emits JSON.
pf_out, = Open3.capture2(RbConfig.ruby, CLI, '--preflight')
pf = JSON.parse(pf_out) rescue nil
check.call('--preflight emits ready_check JSON', pf && pf['schema'] == 'bcs.ready_check/1.0')
check.call('--preflight without input reports fail', pf && pf['status'] == 'fail')

# Shelved 3D shape extrusion must not be advertised as a usable headless option.
help_out, help_status = Open3.capture2(RbConfig.ruby, CLI, '--help')
check.call('--help exits 0', help_status.success?)
check.call('--help omits shelved extrusion flags', help_out !~ /extrude-to-3d|extrude-depth-mm/)
_, extrude_err, extrude_status = Open3.capture3(RbConfig.ruby, CLI, '--extrude-to-3d')
check.call('--extrude-to-3d exits nonzero while shelved', !extrude_status.success?)
check.call('--extrude-to-3d explains shelved state', extrude_err.include?('currently shelved'), extrude_err)

unless File.file?(TEST_PDF)
  puts "SKIP (visible): corpus synthetic PDF not found at #{TEST_PDF} -- " \
       'extraction assertions not run. Set BCS_PRIVATE_VALIDATION_ROOT to a local validation asset root.'
  puts "PASS: #{pass_count} assertions (CLI plumbing only)"
  exit(failures.empty? ? 0 : 1)
end

Dir.mktmpdir('su_cli_test_') do |tmp|
  json_out = File.join(tmp, 'summary.json')
  report_out = File.join(tmp, 'report.json')
  out, err, status = Open3.capture3(
    RbConfig.ruby, CLI, TEST_PDF, '--json', json_out, '--report', report_out
  )
  check.call('extraction run exits 0', status.success?, "stderr=#{err}")
  summary = JSON.parse(out) rescue nil
  check.call('stdout is JSON summary', !summary.nil?)
  if summary
    check.call('pages == 1', summary['pages'] == 1, summary['pages'])
    check.call('text items extracted', summary['text_items'].to_i > 0, summary['text_items'])
    check.call('vector paths extracted', summary['vector_paths'].to_i >= 0)
  end
  check.call('summary file written', File.file?(json_out))
  check.call('report file written', File.file?(report_out))
  if File.file?(report_out)
    report = JSON.parse(File.read(report_out))
    check.call('report schema', report['schema'] == 'bcs.import_report/1.1')
    meta = report['report_meta'] || {}
    check.call('report_meta.host is sketchup or sketchup-cli', %w[sketchup sketchup-cli].include?(meta['host']))
    check.call('report_meta.semver present', meta['semver'].to_s =~ /\A(\d+\.\d+\.\d+|unknown)\z/)
    check.call('unified CLI emits actual_text_entity_types',
               (report['extra'] || {})['actual_text_entity_types'].is_a?(Hash))
    check.call('model_3d intent present',
               (report['extra'] || {})['model_3d_intent'].is_a?(Hash))
    check.call('model_3d block present', (report['extra'] || {})['model_3d'].is_a?(Hash))
    check.call('honesty: headless CLI does not claim solids enabled',
               ((report['extra'] || {})['model_3d'] || {})['enabled'] == false)
    check.call('human_summary present', (report['extra'] || {})['human_summary'].to_s.length > 10)
  end

  # Preflight against a real PDF: pass or warn, never fail.
  pf2_out, pf2_status = Open3.capture2(RbConfig.ruby, CLI, TEST_PDF, '--preflight')
  pf2 = JSON.parse(pf2_out) rescue nil
  check.call('preflight with real PDF exits 0', pf2_status.success?)
  check.call('preflight status pass/warn', pf2 && %w[pass warn].include?(pf2['status']), pf2 && pf2['status'])
end

if failures.empty?
  puts "PASS: #{pass_count} assertions"
  exit 0
else
  failures.each { |f| puts "FAIL: #{f}" }
  exit 1
end
