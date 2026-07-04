#!/usr/bin/env ruby
# tools/su_pdf_cli.rb
#
# SketchUp PDF Importer -- headless CLI (feature-parity slice with
# LibreCAD's pdf2dxf and Blender's batch_cli; Round 7 / Q-N13).
#
# Runs the extension's own Ruby extraction pipeline (PDFParser +
# ContentStreamParser + text extraction) without SketchUp, so shops and CI
# can batch-inspect PDFs, pre-flight them, and produce machine-readable
# reports before anyone opens the host app.
#
# Usage:
#   ruby tools/su_pdf_cli.rb INPUT.pdf [--json OUT.json] [--report OUT.json]
#   ruby tools/su_pdf_cli.rb INPUT.pdf --preflight
#   ruby tools/su_pdf_cli.rb --version
#
# Notes:
#   - Requires a dev Ruby (2.7+). The in-SketchUp extension remains
#     Ruby 2.2-compatible; this tool is not shipped inside the RBZ.
#   - The report deliberately does NOT emit actual_text_entity_types:
#     host entity proof requires the host. It emits extraction-level
#     counts instead (honesty rule -- no overclaiming).

require 'json'
require 'time'
require_relative '../test/support/corpus_harness'

CLI_REPO_ROOT = File.expand_path('..', __dir__)

def plugin_version
  loader = File.join(CLI_REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer.rb')
  match = File.read(loader, encoding: 'utf-8')[/PLUGIN_VERSION\s*=\s*'([^']+)'/, 1]
  match || 'unknown'
end

def poppler_bin_dir
  File.join(CLI_REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer', 'bin')
end

def preflight(pdf_path)
  checks = []
  add = lambda do |id, ok, message|
    checks << { 'id' => id, 'status' => ok ? 'pass' : 'fail', 'message' => message }
  end

  add.call('input_exists', pdf_path && File.file?(pdf_path),
           pdf_path ? "input: #{pdf_path}" : 'no input PDF given')
  if pdf_path && File.file?(pdf_path)
    header = File.binread(pdf_path, 8).to_s
    add.call('pdf_header', header.start_with?('%PDF-'),
             header.start_with?('%PDF-') ? 'valid %PDF- header' : 'not a PDF (bad header)')
  end
  %w[pdftotext.exe pdftocairo.exe pdffonts.exe].each do |exe|
    path = File.join(poppler_bin_dir, exe)
    present = File.file?(path)
    # Poppler helpers are fetched by tools/fetch_third_party_binaries.ps1
    # on dev machines and bundled in release RBZs; absence only degrades
    # text extraction (internal fallback), so warn instead of fail.
    checks << { 'id' => "poppler_#{exe.sub('.exe', '')}",
                'status' => present ? 'pass' : 'warn',
                'message' => present ? "bundled #{exe} present" : "#{exe} missing (text falls back to internal extractor)" }
  end

  status = if checks.any? { |c| c['status'] == 'fail' }
             'fail'
           elsif checks.any? { |c| c['status'] == 'warn' }
             'warn'
           else
             'pass'
           end
  {
    'schema' => 'bcs.ready_check/1.0',
    'status' => status,
    'product' => 'SketchUp PDF Importer CLI',
    'version' => plugin_version,
    'host' => { 'name' => 'sketchup' },
    'checks' => checks,
    'repair_hints' => []
  }
end

FRACTION_RE = /(?:\d+\s+\d+\/\d+|\d+\/\d+|\d+(?:\.\d+)?)/
PLATE_RE = /\bPL\s*(#{FRACTION_RE})\s*"?\s*[xX]\s*(#{FRACTION_RE})\s*"?(?:\s*[xX]\s*([0-9'\-\s\/\."]+))?/
MEMBER_RE = /\b(W|S|M|HP|WT|MT|ST|C|MC)\s?(\d{1,3})\s?[xX]\s?(\d{1,3}(?:\.\d+)?)\b|\b(L)\s?(\d{1,2})\s?[xX]\s?(\d{1,2})\s?[xX]\s?(#{FRACTION_RE})\b|\b(HSS)\s?(\d{1,2}(?:\.\d+)?)\s?[xX]\s?(\d{1,2}(?:\.\d+)?)\s?[xX]\s?(#{FRACTION_RE})\b|\b(PIPE)\s?(\d{1,2})\s?(STD|XS|XXS)\b/
FEET_INCH_RE = /(\d+)'\s*-?\s*(\d+(?:\s+\d+\/\d+|\/\d+)?(?:\.\d+)?)?\s*"?/
MARK_RE = /\b([a-z]{1,2}\d{3,5}(?:[A-Z]{1,3}\d{0,3})?)\b/

def parse_fraction_inches(token)
  s = token.to_s.strip.gsub('"', '')
  return nil if s.empty?
  if s =~ /\A(\d+)\s+(\d+)\/(\d+)\z/
    den = Regexp.last_match(3).to_i
    return nil if den == 0
    return Regexp.last_match(1).to_i + Regexp.last_match(2).to_f / den
  end
  if s =~ /\A(\d+)\/(\d+)\z/
    den = Regexp.last_match(2).to_i
    return nil if den == 0
    return Regexp.last_match(1).to_f / den
  end
  return s.to_f if s =~ /\A\d+(?:\.\d+)?\z/
  nil
end

def feet_inches_to_inches(text)
  m = FEET_INCH_RE.match(text.to_s)
  return nil unless m
  feet = m[1].to_i
  inches = parse_fraction_inches(m[2] || '0') || 0.0
  feet * 12.0 + inches
end

def member_candidate(match)
  g = match.captures
  if g[0]
    return { 'designation' => "#{g[0]}#{g[1]}X#{g[2]}", 'family' => g[0] }
  end
  if g[3]
    return { 'designation' => "L#{g[4]}X#{g[5]}X#{g[6]}", 'family' => 'L' }
  end
  if g[7]
    return { 'designation' => "HSS#{g[8]}X#{g[9]}X#{g[10]}", 'family' => 'HSS' }
  end
  return { 'designation' => "PIPE#{g[12]}#{g[13]}", 'family' => 'PIPE' } if g[11]
  nil
end

def analyze_model3d_intent(texts)
  plates = {}
  members = {}
  Array(texts).each do |text|
    s = text.to_s
    next if s.strip.empty?
    mark = (MARK_RE.match(s) || [])[1]
    length_in = feet_inches_to_inches(s)
    s.scan(PLATE_RE) do |thick_s, width_s, length_s|
      thickness = parse_fraction_inches(thick_s)
      next unless thickness && thickness >= 0.01 && thickness <= 12.0
      width = parse_fraction_inches(width_s)
      callout = Regexp.last_match(0).gsub(/\s+/, '').upcase
      if plates.key?(callout)
        plates[callout]['count'] += 1
      else
        plates[callout] = {
          'callout' => callout,
          'thickness_in' => thickness.round(6),
          'width_in' => width && width.round(6),
          'length_in' => length_s ? feet_inches_to_inches(length_s) : length_in,
          'count' => 1,
          'mark' => mark
        }
      end
    end
    s.to_enum(:scan, MEMBER_RE).each do
      match = Regexp.last_match
      cand = member_candidate(match)
      next unless cand
      key = cand['designation']
      if members.key?(key)
        members[key]['count'] += 1
      else
        cand['length_in'] = length_in
        cand['count'] = 1
        cand['mark'] = mark
        members[key] = cand
      end
    end
  end
  found = !plates.empty? || !members.empty?
  {
    'feasible' => found,
    'plates' => plates.values,
    'members' => members.values,
    'skipped_reason' => (found ? nil : 'No plate thickness callouts or rolled-shape designations found - the drawing does not carry enough third-dimension data for an honest 3D model.')
  }
end

def build_report(analysis, pdf_path, elapsed_s)
  model3d_intent = analyze_model3d_intent(analysis[:texts] || [])
  {
    'schema' => 'bcs.import_report/1.1',
    'report_meta' => {
      'host' => 'sketchup-cli',
      'semver' => plugin_version,
      'build_stamp' => "cli-#{plugin_version}",
      'imported_at' => Time.now.utc.iso8601
    },
    'app' => { 'name' => 'SketchUp PDF Importer CLI', 'version' => plugin_version },
    'source' => { 'file' => File.basename(pdf_path) },
    'result' => {
      'pages' => analysis[:pages],
      'geometry' => analysis[:paths],
      'text' => analysis[:text_items]
    },
    'performance' => { 'total_ms' => (elapsed_s * 1000.0).round },
    'fallback' => { 'used' => analysis[:text_source] != 'pdftotext',
                    'reason' => analysis[:text_source] == 'pdftotext' ? nil : "text source: #{analysis[:text_source]}" },
    'mode' => 'headless-extraction',
    'extra' => {
      'text_source' => analysis[:text_source],
      'bbox_items' => analysis[:bbox_items],
      'bbox_pct' => analysis[:bbox_pct],
      'placement_rate' => analysis[:placement_rate],
      'model_3d_intent' => model3d_intent,
      'model_3d' => {
        'supported' => false,
        'enabled' => false,
        'mode' => 'off',
        'solids_created' => 0,
        'skipped_reason' => 'Headless SketchUp CLI cannot create host geometry; import in SketchUp and enable 3D Model to generate solids.'
      },
      'human_summary' => "Headless CLI extraction of #{File.basename(pdf_path)}: " \
                         "#{analysis[:pages]} page(s), #{analysis[:paths]} vector path(s), " \
                         "#{analysis[:text_items]} text item(s). Host entity creation " \
                         'requires importing inside SketchUp.'
    }
  }
end

def main(argv)
  if argv.include?('--version')
    puts plugin_version
    return 0
  end

  json_out = nil
  report_out = nil
  run_preflight = argv.delete('--preflight')
  if (i = argv.index('--json'))
    json_out = argv.delete_at(i + 1)
    argv.delete_at(i)
  end
  if (i = argv.index('--report'))
    report_out = argv.delete_at(i + 1)
    argv.delete_at(i)
  end
  pdf_path = argv.find { |a| !a.start_with?('--') }

  if run_preflight
    doc = preflight(pdf_path)
    puts JSON.pretty_generate(doc)
    return doc['status'] == 'fail' ? 1 : 0
  end

  unless pdf_path && File.file?(pdf_path)
    warn 'Give me a PDF to inspect, e.g.:  ruby tools/su_pdf_cli.rb "C:\\drawings\\1017 - Rev 0.pdf" --json out.json'
    warn 'The file was not found.' if pdf_path
    return 2
  end

  started = Time.now
  analysis = CorpusHarness.analyze_pdf(path: pdf_path, corpus_key: File.basename(pdf_path))
  elapsed = Time.now - started

  if analysis[:status] != 'OK'
    warn "Could not analyze this PDF: #{analysis[:error]}"
    warn 'If it is encrypted or damaged, that is the expected refusal behavior.'
    return 1
  end

  summary = {
    'input' => pdf_path,
    'pages' => analysis[:pages],
    'vector_paths' => analysis[:paths],
    'text_items' => analysis[:text_items],
    'text_source' => analysis[:text_source],
    'placement_rate' => analysis[:placement_rate],
    'time_s' => elapsed.round(2)
  }
  report = build_report(analysis, pdf_path, elapsed)

  File.write(json_out, JSON.pretty_generate(summary) + "\n") if json_out
  if report_out
    File.write(report_out, JSON.pretty_generate(report) + "\n")
    summary['import_report_path'] = report_out
  end
  puts JSON.pretty_generate(summary)
  0
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
