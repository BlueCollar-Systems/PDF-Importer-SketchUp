#!/usr/bin/env ruby
# tools/su_pdf_cli.rb
#
# Compatibility shim — R7-9 CLI contract merge.
#
# The canonical implementation lives in:
#   extracted/sketchup_ext/bc_pdf_vector_importer/cli.rb  (BlueCollarSystems::PDFVectorImporter::CLI)
#
# This shim translates the legacy positional-arg interface:
#   ruby tools/su_pdf_cli.rb INPUT.pdf [--json OUT] [--report OUT] [--preflight] [--version]
# into the canonical OptionParser flags used by cli.rb, so existing scripts
# and CI jobs that reference su_pdf_cli.rb continue to work unchanged.
#
# New callers should use cli.rb directly via --input for the full flag set.

require 'json'

SHIM_REPO_ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(SHIM_REPO_ROOT, 'extracted', 'sketchup_ext'))

require 'bc_pdf_vector_importer/cli'

CLI_MOD = BlueCollarSystems::PDFVectorImporter::CLI

def shim_main(argv)
  args = argv.dup

  # --version
  if args.include?('--version')
    puts CLI_MOD.version_string
    return 0
  end

  # --preflight [PDF]
  if args.delete('--preflight')
    pdf = args.find { |a| !a.start_with?('--') }
    doc = CLI_MOD.run_preflight(pdf)
    puts JSON.pretty_generate(doc)
    return doc['status'] == 'fail' ? 1 : 0
  end

  # Parse legacy flags
  json_out  = nil
  report_out = nil
  if (i = args.index('--json'))
    json_out = args.delete_at(i + 1)
    args.delete_at(i)
  end
  if (i = args.index('--report'))
    report_out = args.delete_at(i + 1)
    args.delete_at(i)
  end
  pdf_path = args.find { |a| !a.start_with?('--') }

  unless pdf_path && File.file?(pdf_path)
    warn 'Give me a PDF to inspect, e.g.:  ruby tools/su_pdf_cli.rb drawing.pdf --json out.json'
    warn 'The file was not found.' if pdf_path
    return 2
  end

  # Build canonical opts and run
  cli_opts = {
    input:          pdf_path,
    output_dir:     json_out ? File.dirname(File.expand_path(json_out)) : nil,
    report:         report_out,
    mode:           'auto',
    pages:          'All',
    scale:          '1.0',
    text_mode:      'Labels',
    import_text:    'Yes',
    match_pdf_layers: 'Yes',
    grouping_mode:  'Group per page',
    page_arrangement: 'Spread (20% gap)',
    extract_images: true,
    write_primitives: false,
    quiet:          true
  }
  result = CLI_MOD.run(cli_opts)
  s = result[:summary] || {}

  # Emit legacy summary shape
  legacy = {
    'input'          => pdf_path,
    'pages'          => s[:pages],
    'vector_paths'   => s[:paths],
    'text_items'     => s[:text],
    'text_source'    => nil,
    'placement_rate' => nil,
    'time_s'         => s[:elapsed_seconds]
  }
  legacy['import_report_path'] = report_out if report_out

  File.write(json_out, JSON.pretty_generate(legacy) + "\n") if json_out
  puts JSON.pretty_generate(legacy)
  result[:ok] ? 0 : 1
end

if $PROGRAM_NAME == __FILE__
  exit shim_main(ARGV)
end
