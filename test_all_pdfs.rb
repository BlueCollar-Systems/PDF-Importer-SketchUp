#!/usr/bin/env ruby
# Test script: parse all corpus PDFs through the PDF-Importer-SketchUp pipeline
# Tests PDF structure parsing + content stream extraction (no SketchUp needed)

require 'timeout'
require 'zlib'

# Set up load path for the importer modules
SRC_ROOT = File.join(__dir__, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

# Require only the parsing-related modules (no SketchUp dependencies)
require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/content_stream_parser'
require_relative 'corpus_paths'

# Enable debug output from Logger
BlueCollarSystems::PDFVectorImporter::Logger.debug = false

PDF_DIR = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_root.to_s
TIMEOUT_SECONDS = (ENV['PDF_IMPORTER_TEST_TIMEOUT'] || '60').to_i
HEAVY_TIMEOUT_SECONDS = (ENV['PDF_IMPORTER_HEAVY_TIMEOUT'] || '240').to_i
HEAVY_MB = (ENV['PDF_IMPORTER_HEAVY_MB'] || '8').to_f
ALLOW_TIMEOUTS = ENV['PDF_IMPORTER_ALLOW_TIMEOUTS'] == '1'

def timeout_for(size_kb)
  size_mb = size_kb.to_f / 1024.0
  size_mb > HEAVY_MB ? HEAVY_TIMEOUT_SECONDS : TIMEOUT_SECONDS
end

# Collect all PDFs recursively
pdf_files = Dir.glob(File.join(PDF_DIR, '**', '*.{pdf,Pdf,PDF}')).sort

puts "=" * 100
puts "PDF-Importer-SketchUp Parser Test — #{pdf_files.length} PDF files"
puts "=" * 100
puts

results = []

pdf_files.each_with_index do |pdf_path, idx|
  short_name = pdf_path.sub(PDF_DIR + '/', '')
  file_size_kb = (File.size(pdf_path) / 1024.0).round(1)
  timeout_s = timeout_for(file_size_kb)

  print "#{idx + 1}/#{pdf_files.length}  #{short_name} (#{file_size_kb} KB) ... "
  $stdout.flush

  result = {
    file: short_name,
    size_kb: file_size_kb,
    status: nil,
    pages: 0,
    streams_per_page: [],
    total_paths: 0,
    error: nil,
    time_s: 0
  }

  start_time = Time.now

  begin
    Timeout.timeout(timeout_s) do
      # Phase 1: Parse PDF structure (xref, page tree)
      parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf_path)
      parser.parse

      result[:pages] = parser.page_count

      # Phase 2: For each page, extract content streams and parse vector paths
      total_paths = 0
      (1..parser.page_count).each do |pg|
        page_info = parser.page_data(pg)
        next unless page_info

        streams = page_info[:content_streams] || []
        result[:streams_per_page] << streams.length

        # Parse content streams for vector paths
        ocg_map = {}
        begin
          ocg_map = parser.page_ocg_map(pg) || {}
        rescue => e
          # OCG map is optional, don't fail on it
        end

        csp = BlueCollarSystems::PDFVectorImporter::ContentStreamParser.new(
          streams, parser, ocg_map
        )
        paths = csp.parse
        total_paths += paths.length
      end

      result[:total_paths] = total_paths
      result[:status] = 'OK'

      parser.release
    end
  rescue Timeout::Error
    result[:status] = 'TIMEOUT'
    result[:error] = "Exceeded #{timeout_s}s"
  rescue => e
    result[:status] = 'FAIL'
    result[:error] = "#{e.class}: #{e.message}"
  end

  result[:time_s] = (Time.now - start_time).round(2)
  results << result

  if result[:status] == 'OK'
    puts "OK  #{result[:pages]} pages, #{result[:total_paths]} paths (#{result[:time_s]}s)"
  else
    puts "#{result[:status]}  #{result[:error]} (#{result[:time_s]}s)"
  end
  $stdout.flush
end

# ---- Summary Table ----
puts
puts "=" * 100
puts "SUMMARY TABLE"
puts "=" * 100
puts

header = "%-4s  %-50s  %8s  %6s  %5s  %7s  %7s  %s" %
         ['#', 'File', 'Size(KB)', 'Status', 'Pages', 'Paths', 'Time(s)', 'Error']
puts header
puts "-" * header.length

results.each_with_index do |r, i|
  name = r[:file].length > 50 ? r[:file][0..47] + '...' : r[:file]
  line = "%-4d  %-50s  %8.1f  %6s  %5d  %7d  %7.2f  %s" %
         [i + 1, name, r[:size_kb], r[:status], r[:pages], r[:total_paths], r[:time_s],
          r[:error] || '']
  puts line
end

# Stats
ok_count = results.count { |r| r[:status] == 'OK' }
fail_count = results.count { |r| r[:status] == 'FAIL' }
timeout_count = results.count { |r| r[:status] == 'TIMEOUT' }
total_pages = results.sum { |r| r[:pages] }
total_paths = results.sum { |r| r[:total_paths] }
total_time = results.sum { |r| r[:time_s] }

puts
puts "=" * 100
puts "TOTALS: #{ok_count} OK / #{fail_count} FAIL / #{timeout_count} TIMEOUT  out of #{results.length} files"
puts "  Total pages parsed: #{total_pages}"
puts "  Total vector paths extracted: #{total_paths}"
puts "  Total time: #{total_time.round(2)}s"
puts "=" * 100

if fail_count > 0 || timeout_count > 0
  puts
  puts "FAILURES/TIMEOUTS:"
  results.select { |r| r[:status] != 'OK' }.each do |r|
    puts "  [#{r[:status]}] #{r[:file]}: #{r[:error]}"
  end
end

exit 1 if fail_count > 0 || (timeout_count > 0 && !ALLOW_TIMEOUTS)
