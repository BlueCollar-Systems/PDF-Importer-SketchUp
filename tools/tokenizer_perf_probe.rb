#!/usr/bin/env ruby
# tools/tokenizer_perf_probe.rb
# RED/GREEN tokenizer performance and parity probe for the SketchUp PDF importer.
# Loads a PDF with the bundled PDFParser, extracts every page content stream,
# times tokenization, and writes a JSON report with token stream checksums.

require 'json'
require 'fileutils'
require 'digest'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/content_stream_parser'

pdf_path = ARGV[0] || ENV['TOKENIZER_PDF']
unless pdf_path && File.exist?(pdf_path)
  warn 'Usage: ruby tools/tokenizer_perf_probe.rb <pdf-path>'
  warn '   or set TOKENIZER_PDF'
  exit 0
end

repetitions = (ENV['TOKENIZER_REPS'] || '5').to_i
repetitions = 1 if repetitions < 1

parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf_path)
parser.parse

report = {
  pdf: File.basename(pdf_path),
  pages: parser.page_count,
  ruby_version: RUBY_VERSION,
  reps: repetitions,
  page_tokens: [],
  total_token_ms: 0.0
}

(1..parser.page_count).each do |page_num|
  raw = parser.page_data(page_num)
  streams = raw[:content_streams] || []
  ocg = begin
    parser.page_ocg_map(page_num)
  rescue StandardError
    {}
  end

  page_tokens = []
  total_page_ms = 0.0
  stream_samples = []

  streams.each do |stream|
    # Warm up once, then average the requested repetitions.
    csp = BlueCollarSystems::PDFVectorImporter::ContentStreamParser.new([stream], parser, ocg)
    _warmup = csp.send(:tokenize_content_stream, stream)

    tokens = nil
    samples = []
    repetitions.times do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      tokens = csp.send(:tokenize_content_stream, stream)
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      samples << ((t1 - t0) * 1000.0)
      page_tokens = tokens
    end

    avg_ms = samples.sum / samples.length.to_f
    total_page_ms += avg_ms

    token_serialized = tokens.to_json
    stream_samples << {
      bytes: stream.bytesize,
      token_count: tokens.length,
      token_sha256: Digest::SHA256.hexdigest(token_serialized),
      avg_ms: avg_ms,
      samples_ms: samples
    }
  end

  report[:page_tokens] << {
    page: page_num,
    streams: stream_samples.length,
    total_avg_ms: total_page_ms,
    stream_samples: stream_samples
  }
  report[:total_token_ms] += total_page_ms
end

parser.release

out_path = ENV['TOKENIZER_OUT'] || File.join(Dir.tmpdir, "tokenizer_probe_#{Process.pid}.json")
File.write(out_path, JSON.pretty_generate(report))
puts "Tokenizer probe: #{out_path}"
puts "  pages=#{report[:pages]} total_token_ms=#{report[:total_token_ms].round(4)}"
