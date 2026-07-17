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

# Disabled closed-shape extrusion must not be advertised as a usable headless option.
help_out, help_status = Open3.capture2(RbConfig.ruby, CLI, '--help')
check.call('--help exits 0', help_status.success?)
check.call('--help omits disabled closed-shape extrusion flags', help_out !~ /extrude-to-3d|extrude-depth-mm/)
_, extrude_err, extrude_status = Open3.capture3(RbConfig.ruby, CLI, '--extrude-to-3d')
check.call('--extrude-to-3d exits nonzero while disabled', !extrude_status.success?)
check.call('--extrude-to-3d explains independent disabled state',
           extrude_err.include?('disabled independently of 3D text'), extrude_err)

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
    extra = report['extra'] || {}
    check.call('unified CLI identifies extraction-only scope',
               extra['execution_scope'] == 'extraction_only', extra['execution_scope'])
    check.call('extraction-only CLI does not claim SketchUp text entities',
               (report['result'] || {})['text_entities'].to_i == 0)
    check.call('extraction-only CLI does not fabricate actual_text_entity_types',
               !extra.key?('actual_text_entity_types'))
    check.call('extraction-only CLI keeps extracted text count separately',
               extra['extracted_text_items'].to_i > 0)
    check.call('host import contract is explicitly not ready',
               (extra['import_contract_ready'] || {})['ready'] == false)
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

  # R23 (F-1): Glyphs-mode report parity — extra.glyph_source names the
  # source that produced the outlines and the R17-3 run-matching counts.
  glyphs_report = File.join(tmp, 'glyphs_report.json')
  _, g_err, g_status = Open3.capture3(
    RbConfig.ruby, CLI, TEST_PDF, '--text-mode', 'glyphs', '--report', glyphs_report
  )
  check.call('glyphs-mode run exits 0', g_status.success?, "stderr=#{g_err}")
  check.call('glyphs-mode report written', File.file?(glyphs_report))
  if File.file?(glyphs_report)
    greport = JSON.parse(File.read(glyphs_report))
    gs = (greport['extra'] || {})['glyph_source']
    check.call('glyphs report carries extra.glyph_source', gs.is_a?(Hash))
    if gs.is_a?(Hash)
      check.call('glyph_source names a source',
                 %w[cairo_svg mupdf_svg internal].include?(gs['source']), gs['source'])
      check.call('glyph_source counts pages', gs['pages'].to_i >= 1, gs['pages'])
      if gs['source'] == 'cairo_svg'
        check.call('cairo source matches extractor runs (R17-3)',
                   gs['runs_matched'].to_i > 0, gs.inspect)
        check.call('no unmatched extractor runs on the synthetic page',
                   gs['runs_unmatched'].to_i == 0, gs.inspect)
      else
        check.call('non-cairo source records a visible fallback_reason',
                   gs['fallback_reason'].to_s.length > 0, gs.inspect)
      end
    end
  end
end

if failures.empty?
  puts "PASS: #{pass_count} assertions"
  exit 0
else
  failures.each { |f| puts "FAIL: #{f}" }
  exit 1
end
