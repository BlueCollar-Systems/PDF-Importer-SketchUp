#!/usr/bin/env ruby
# test/pdf_type_matrix_test.rb -- Round 18 "any PDF type" contract.
#
# Owner directive 2026-07-10: the importers must import/recreate any PDF
# file/PDF type. This locks the three SketchUp defects the corpus
# pdf-type-matrix exposed (and their fixes):
#   1. Form XObjects: vector geometry inside `/Name Do` forms imports
#      (pdf_parser inline expansion).
#   2. Empty-password encryption: imports via the poppler salvage path
#      instead of a gate refusal (viewers open these silently).
#   3. Damaged xref / real password: clean refusal or repair -- NEVER a
#      Ruby backtrace.
#
# Skips VISIBLY when the private corpus matrix is absent (R4-2 rule).
# Ruby 2.2 compatible.

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

REPO_ROOT = File.expand_path('..', __dir__)
CLI = File.join(REPO_ROOT, 'tools', 'su_pdf_cli.rb')
CORPUS_ROOT = ENV['BCS_PRIVATE_VALIDATION_ROOT'] ||
              '__private_validation_assets_not_configured__'
MATRIX = File.join(CORPUS_ROOT, 'tier2', 'pdf-type-matrix')

unless File.directory?(MATRIX)
  puts "SKIP (visible): pdf-type-matrix not found at #{MATRIX} -- " \
       'set BCS_PRIVATE_VALIDATION_ROOT or regenerate via corpus ' \
       'tools/generate_pdf_type_matrix.py.'
  puts 'PASS: 0 assertions (matrix absent)'
  exit 0
end

failures = []
pass_count = 0
check = lambda do |label, ok, detail = nil|
  if ok
    pass_count += 1
  else
    failures << "#{label}#{detail ? " -- #{detail}" : ''}"
  end
end

def run_cli(pdf, workdir)
  json_out = File.join(workdir, File.basename(pdf, '.pdf') + '.json')
  out, err, status = Open3.capture3(
    RbConfig.ruby, CLI, pdf, '--json', json_out, '--output-dir', workdir)
  summary = nil
  if File.file?(json_out)
    summary = JSON.parse(File.read(json_out)) rescue nil
  end
  [status, out, err, summary]
end

Dir.mktmpdir('pdf_type_matrix_') do |tmp|
  # 1. Form XObject vectors must import
  status, _out, err, summary = run_cli(
    File.join(MATRIX, 'form_xobject_cm.pdf'), tmp)
  check.call('form xobject: exit 0', status.success?, err.to_s[0, 120])
  prims = summary ? summary['vector_paths'].to_i : -1
  check.call('form xobject: vector geometry extracted (>=4 paths)',
             prims >= 4, "vector_paths=#{prims}")

  # 2. Empty-password encrypted file imports via salvage
  status, _out, err, summary = run_cli(
    File.join(MATRIX, 'encrypted_empty_pw.pdf'), tmp)
  check.call('encrypted empty-pw: exit 0 (salvaged, not refused)',
             status.success?, err.to_s[0, 120])
  prims = summary ? summary['vector_paths'].to_i : -1
  check.call('encrypted empty-pw: vectors present', prims >= 4,
             "vector_paths=#{prims}")

  # 3. Broken startxref: repaired import or clean refusal, no backtrace
  status, out, err, _summary = run_cli(
    File.join(MATRIX, 'broken_startxref.pdf'), tmp)
  blob = out.to_s + err.to_s
  check.call('broken startxref: no ruby backtrace',
             !(blob =~ /\.rb:\d+:in/ && !status.success?), blob[0, 160])

  # 4. Real password: clean refusal (nonzero exit, message, no backtrace)
  status, out, err, _summary = run_cli(
    File.join(MATRIX, 'encrypted_user_pw.pdf'), tmp)
  blob = out.to_s + err.to_s
  check.call('password-protected: refused (nonzero exit)', !status.success?)
  check.call('password-protected: no ruby backtrace',
             !(blob =~ /\.rb:\d+:in .{0,40}\n\s+from /), blob[0, 160])
end

if failures.empty?
  puts "PASS: #{pass_count} assertions"
  exit 0
else
  failures.each { |f| puts "FAIL: #{f}" }
  exit 1
end
