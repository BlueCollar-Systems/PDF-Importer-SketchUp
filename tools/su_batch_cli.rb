#!/usr/bin/env ruby
# tools/su_batch_cli.rb
# Offline batch CLI for SketchUp PDF importer — preflight, parse, import_report.
#
# Usage:
#   ruby tools/su_batch_cli.rb --preflight
#   ruby tools/su_batch_cli.rb drawing.pdf [--report-dir DIR] [--geometry-sidecar] [--json OUT]
#   ruby tools/su_batch_cli.rb ./pdfs --recursive [--summary-dir DIR]
#
# Full geometry import requires SketchUp; see tools/sketchup_batch_import.rb

require 'optparse'
require 'json'
require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/pdf_open_gate'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/source_provenance'
require 'bc_pdf_vector_importer/embedded_image_extractor'
require 'bc_pdf_vector_importer/qa_report'
require 'bc_pdf_vector_importer/batch_pipeline'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

options = {
  import_mode: 'auto',
  text_mode: 'none',
  pages: 'all',
  recursive: false,
  report_dir: nil,
  summary_dir: nil,
  geometry_sidecar: false,
  json_out: nil,
  preflight: false,
  verbose: false
}

parser = OptionParser.new do |opts|
  opts.banner = <<-BANNER
su_batch_cli — SketchUp PDF importer offline batch CLI (BlueCollar Systems)

Analyzes PDFs without SketchUp: open gate, vector parse, import_report.json.
Optional geometry sidecar summarizes path/text/image counts.

Full SketchUp geometry batch:
  SketchUp.exe -RubyStartup tools/sketchup_batch_import.rb -RubyStartupArg file.pdf
  BANNER

  opts.on('--preflight', 'Print preflight guidance and exit') { options[:preflight] = true }
  opts.on('--mode MODE', 'Import mode: auto|vector|raster|hybrid (default: auto)') { |v| options[:import_mode] = v }
  opts.on('--text-mode MODE', 'Text mode label for report metadata') { |v| options[:text_mode] = v }
  opts.on('--pages SPEC', 'Page list: all, 1,3,5 or 1-4 (default: all)') { |v| options[:pages] = v }
  opts.on('--report-dir DIR', 'Directory for per-PDF import_report.json files') { |v| options[:report_dir] = v }
  opts.on('--summary-dir DIR', 'Directory for per-PDF summary JSON (batch dir mode)') { |v| options[:summary_dir] = v }
  opts.on('--geometry-sidecar', 'Write geometry sidecar JSON alongside import_report') { options[:geometry_sidecar] = true }
  opts.on('--json PATH', 'Write aggregate batch JSON report') { |v| options[:json_out] = v }
  opts.on('--recursive', 'Include subfolders when input is a directory') { options[:recursive] = true }
  opts.on('--verbose', 'Print progress to stderr') { options[:verbose] = true }
  opts.on('-h', '--help', 'Show help') do
    puts opts
    exit 0
  end
end

parser.parse!(ARGV)

if options[:preflight]
  puts BlueCollarSystems::PDFVectorImporter::BatchPipeline.preflight_paragraph
  exit 0
end

if ARGV.empty?
  warn 'ERROR: missing input PDF or directory (use --preflight for guidance)'
  exit 1
end

input = File.expand_path(ARGV[0])
unless File.exist?(input)
  warn "ERROR: input not found: #{input}"
  exit 1
end

if options[:report_dir]
  FileUtils.mkdir_p(options[:report_dir])
end
if options[:summary_dir]
  FileUtils.mkdir_p(options[:summary_dir])
end

def collect_pdfs(path, recursive)
  if File.file?(path)
    return path.downcase.end_with?('.pdf') ? [path] : []
  end
  pattern = recursive ? '**/*.pdf' : '*.pdf'
  Dir.glob(File.join(path, pattern)).select { |f| File.file?(f) }.sort
end

pdfs = collect_pdfs(input, options[:recursive])
if pdfs.empty?
  warn "ERROR: no PDF files found under: #{input}"
  exit 1
end

BP = BlueCollarSystems::PDFVectorImporter::BatchPipeline
run_opts = {
  import_mode: options[:import_mode],
  text_mode: options[:text_mode],
  pages: options[:pages],
  report_dir: options[:report_dir],
  geometry_sidecar: options[:geometry_sidecar]
}

aggregate = {
  root: input,
  total: pdfs.length,
  passed: 0,
  failed: 0,
  results: []
}

pdfs.each do |pdf|
  warn "Analyzing #{pdf}..." if options[:verbose]
  result = BP.run_file(pdf, run_opts)
  entry = {
    pdf: pdf,
    status: result[:status],
    import_report: result[:import_report_path],
    geometry_sidecar: result[:geometry_sidecar_path],
    error: result[:error]
  }

  if options[:summary_dir]
    summary_path = File.join(options[:summary_dir], "#{File.basename(pdf, '.pdf')}.summary.json")
    File.write(summary_path, JSON.pretty_generate(entry) + "\n", encoding: 'UTF-8')
    entry[:summary_json] = summary_path
  end

  if result[:status] == 'OK'
    aggregate[:passed] += 1
  else
    aggregate[:failed] += 1
  end
  aggregate[:results] << entry
end

summary = {
  root: aggregate[:root],
  total: aggregate[:total],
  passed: aggregate[:passed],
  failed: aggregate[:failed]
}
puts JSON.pretty_generate(summary)

if options[:json_out]
  out_path = File.expand_path(options[:json_out])
  FileUtils.mkdir_p(File.dirname(out_path))
  File.write(out_path, JSON.pretty_generate(aggregate) + "\n", encoding: 'UTF-8')
  warn "Wrote aggregate report: #{out_path}" if options[:verbose]
end

exit aggregate[:failed] == 0 ? 0 : 1
