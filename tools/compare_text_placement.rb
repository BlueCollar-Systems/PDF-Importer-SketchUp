#!/usr/bin/env ruby
# tools/compare_text_placement.rb
# Compare label insertion vs internal TextParser CTM after angle/position hints.

require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/external_text_extractor'
require 'bc_pdf_vector_importer/main'

CorpusHarnessPath = File.join(REPO_ROOT, 'test', 'support', 'corpus_harness.rb')
require CorpusHarnessPath if File.file?(CorpusHarnessPath)

CorpusHarness.install_headless_stubs! if defined?(CorpusHarness)
builder = defined?(CorpusHarness) ? CorpusHarness.geometry_builder :
  BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(nil, [], [], [0, 0, 612, 792], import_text: true)

def normalize_key(text)
  BlueCollarSystems::PDFVectorImporter.normalize_text_key(text)
end

def match_internal(external, internals)
  key = normalize_key(external.text)
  return nil if key.empty?
  ex, ey = BlueCollarSystems::PDFVectorImporter.text_item_anchor_for_angle(external)
  fs = [external.font_size.to_f, 1.0].max
  threshold = [fs * 2.5, 24.0].max
  best = nil
  internals.each do |hint|
    next unless normalize_key(hint.text) == key
    hx, hy = BlueCollarSystems::PDFVectorImporter.text_item_anchor_for_angle(hint)
    dist = Math.sqrt(((hx - ex)**2) + ((hy - ey)**2))
    next if dist > threshold
    best = [dist, hint] if best.nil? || dist < best[0]
  end
  best ? best[1] : nil
end

pdf_path = ARGV[0]
unless pdf_path && File.file?(pdf_path)
  warn 'Usage: ruby tools/compare_text_placement.rb <pdf>'
  exit 1
end

parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf_path)
parser.parse
page = 1
page_info = parser.page_data(page)
streams = page_info[:content_streams] || []
ocg_map = begin
  parser.page_ocg_map(page) || {}
rescue StandardError
  {}
end
font_maps = parser.page_font_maps(page)

external = BlueCollarSystems::PDFVectorImporter::ExternalTextExtractor.extract(pdf_path, page) || []
internal = BlueCollarSystems::PDFVectorImporter::TextParser.new(
  streams, font_maps, { strict_text_fidelity: true, merge_text_runs: false }, ocg_map
).parse || []
merged = BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(external, internal)

drifts = []
matched = 0
merged.each do |ext|
  hint = match_internal(ext, internal)
  next unless hint
  matched += 1
  lx, ly, = builder.send(:label_insertion_pdf, ext)
  drifts << Math.sqrt(((lx - ext.x.to_f)**2) + ((ly - ext.y.to_f)**2))
end

drifts.sort!
n = drifts.length
puts "PDF: #{File.basename(pdf_path)}"
puts "External=#{external.length} internal=#{internal.length} matched=#{matched}"
if n > 0
  over5 = drifts.count { |d| d > 5.0 }
  puts format('Label vs matrix-origin drift: p50=%.2f p90=%.2f p95=%.2f max=%.2f',
              drifts[n / 2], drifts[(n * 0.9).to_i], drifts[(n * 0.95).to_i], drifts.last)
  puts ">5pt: #{over5}/#{n} (#{(100.0 * over5 / n).round(1)}%)"
end
parser.release
