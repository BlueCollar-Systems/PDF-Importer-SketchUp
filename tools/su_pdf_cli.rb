#!/usr/bin/env ruby
# tools/su_pdf_cli.rb
#
# Compatibility wrapper for the unified SketchUp headless CLI.
# The extraction/report contract lives in:
#   extracted/sketchup_ext/bc_pdf_vector_importer/cli.rb
#
# Legacy flags kept here:
#   ruby tools/su_pdf_cli.rb INPUT.pdf [--json OUT.json] [--report OUT.json]
#   ruby tools/su_pdf_cli.rb INPUT.pdf --preflight
#   ruby tools/su_pdf_cli.rb --version

require 'json'
require 'optparse'
require 'time'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/cli'

REPO_ROOT = File.expand_path('..', __dir__)

def plugin_version
  loader = File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer.rb')
  match = File.read(loader, encoding: 'utf-8')[/PLUGIN_VERSION\s*=\s*'([^']+)'/, 1]
  match || 'unknown'
end

def poppler_bin_dir
  File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer', 'bin')
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
    checks << {
      'id' => "poppler_#{exe.sub('.exe', '')}",
      'status' => present ? 'pass' : 'warn',
      'message' => present ? "bundled #{exe} present" : "#{exe} missing (text falls back to internal extractor)"
    }
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

def help_text
  <<~HELP
    Usage:
      ruby tools/su_pdf_cli.rb INPUT.pdf [--json OUT.json] [--report OUT.json]
      ruby tools/su_pdf_cli.rb INPUT.pdf --preflight
      ruby tools/su_pdf_cli.rb --version

    Unified CLI flags forwarded to the extension CLI:
      --output-dir DIR
      --mode auto|vector|raster|hybrid
      --pages All|1|1-3|1,3,5
      --scale VALUE
      --text-mode MODE
      --no-text
      --extract-images / --no-extract-images
      --no-primitives-json
      --extrude-to-3d
      --extrude-depth-mm MM
  HELP
end

def parse_legacy_args(argv)
  options = {
    input: nil,
    json_out: nil,
    report: nil,
    preflight: false,
    version: false,
    quiet: false,
    cli_args: []
  }

  value_flags = %w[
    --output-dir --mode --pages --scale --text-mode --extrude-depth-mm
  ]
  bool_flags = %w[
    --no-text --extract-images --no-extract-images --no-primitives-json
    --extrude-to-3d --quiet
  ]

  i = 0
  while i < argv.length
    arg = argv[i]
    case arg
    when '--version'
      options[:version] = true
    when '--preflight'
      options[:preflight] = true
    when '--json'
      i += 1
      options[:json_out] = argv[i]
    when /\A--json=(.+)\z/
      options[:json_out] = Regexp.last_match(1)
    when '--report'
      i += 1
      options[:report] = argv[i]
      options[:cli_args].concat(['--report', options[:report]]) if options[:report]
    when /\A--report=(.+)\z/
      options[:report] = Regexp.last_match(1)
      options[:cli_args].concat(['--report', options[:report]])
    when '--extrude-depth'
      i += 1
      options[:cli_args].concat(['--extrude-depth-mm', argv[i]]) if argv[i]
    when /\A--extrude-depth=(.+)\z/
      options[:cli_args].concat(['--extrude-depth-mm', Regexp.last_match(1)])
    when *value_flags
      i += 1
      options[:cli_args].concat([arg, argv[i]]) if argv[i]
    when *bool_flags
      options[:quiet] = true if arg == '--quiet'
      options[:cli_args] << arg
    when '-h', '--help'
      puts help_text
      exit 0
    else
      if arg.start_with?('--')
        raise OptionParser::InvalidOption, arg
      elsif options[:input].nil?
        options[:input] = arg
      else
        raise OptionParser::InvalidArgument, arg
      end
    end
    i += 1
  end
  options
end

def legacy_summary(summary)
  {
    'status' => summary[:status],
    'input' => summary[:input],
    'pages' => summary[:pages],
    'vector_paths' => summary[:paths],
    'text_items' => summary[:text],
    'primitives' => summary[:primitives],
    'embedded_images' => summary[:embedded_images],
    'output_dir' => summary[:output_dir],
    'import_report_path' => summary[:report],
    'primitives_json' => summary[:primitives_json],
    'time_s' => summary[:elapsed_seconds]
  }
end

def main(argv)
  opts = parse_legacy_args(argv)
  if opts[:version]
    puts plugin_version
    return 0
  end

  if opts[:preflight]
    doc = preflight(opts[:input])
    puts JSON.pretty_generate(doc)
    return doc['status'] == 'fail' ? 1 : 0
  end

  unless opts[:input] && File.file?(opts[:input])
    warn 'Give me a PDF to inspect, e.g.: ruby tools/su_pdf_cli.rb "C:\\drawings\\my-shop-drawing.pdf" --json out.json'
    warn 'The file was not found.' if opts[:input]
    return 2
  end

  cli_argv = ['--input', opts[:input], '--quiet'] + opts[:cli_args]
  cli_opts = BlueCollarSystems::PDFVectorImporter::CLI.parse_args(cli_argv)
  result = BlueCollarSystems::PDFVectorImporter::CLI.run(cli_opts)
  summary = legacy_summary(result[:summary])
  File.write(opts[:json_out], JSON.pretty_generate(summary) + "\n", encoding: 'UTF-8') if opts[:json_out]
  puts JSON.pretty_generate(summary) unless opts[:quiet]
  result[:ok] ? 0 : 1
rescue OptionParser::ParseError => e
  warn e.message
  return 2
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
