#!/usr/bin/env ruby
# tools/sketchup_batch_import.rb
# SketchUp -RubyStartup entry for full geometry PDF import (host required).
#
# Example:
#   "C:\Program Files\SketchUp\SketchUp 2024\SketchUp.exe" ^
#     -RubyStartup "C:\1PDF-Importer-SketchUp\tools\sketchup_batch_import.rb" ^
#     -RubyStartupArg "C:\drawings\sample.pdf"
#
# Optional second RubyStartupArg: output directory for import_report.json

unless defined?(Sketchup)
  warn 'sketchup_batch_import.rb must run inside SketchUp (-RubyStartup).'
  exit 1
end

require 'fileutils'

plugin_root = File.expand_path('../extracted/sketchup_ext', __dir__)
load File.join(plugin_root, 'bc_pdf_vector_importer', 'main.rb')

PDF = BlueCollarSystems::PDFVectorImporter

pdf_path = ARGV[0]
report_dir = ARGV[1]

unless pdf_path && File.file?(pdf_path)
  UI.messagebox("Batch import: PDF not found:\n#{pdf_path}")
  exit 1
end

gate = PDF.handle_open_gate(pdf_path, {}, show_ui: false)
if gate
  warn "Refused: #{gate[:reason]} — #{gate[:message]}"
  exit 1
end

model = Sketchup.active_model
config = PDF::ImportConfig.from_mode('Auto')
opts = config.to_opts
opts[:import_text] = true
opts[:text_mode] = :text3d
opts[:use_3d_text] = true
opts[:raster_fallback] = true

stats = PDF.run_pipeline(model, pdf_path, opts)
unless PDF.pipeline_result_success?(stats)
  UI.messagebox("Batch import failed for:\n#{pdf_path}")
  exit 1
end

if report_dir && stats[:import_report_path]
  FileUtils.mkdir_p(report_dir)
  dest = File.join(report_dir, File.basename(stats[:import_report_path]))
  FileUtils.cp(stats[:import_report_path], dest)
  stats[:import_report_path] = dest
end

msg = "Imported #{stats[:edges]} edges, #{stats[:text]} text items.\nReport: #{stats[:import_report_path]}"
UI.messagebox(msg)
puts msg
