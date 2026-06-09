#!/usr/bin/env ruby
# One-off profiler for Alvord garden map PDF (headless).

require_relative '../corpus_paths'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_dialog'

module BlueCollarSystems
  module PDFVectorImporter
    def self.looks_like_fill_art_flood?(paths, media_box)
      return [false, {}] if paths.nil? || paths.empty?
      fill_only = paths.count { |p| p.fill && !p.stroke }
      ratio = fill_only.to_f / paths.length
      stats = { fill_only: fill_only, fill_ratio: ratio.round(4) }
      hit = paths.length >= 400 && ratio >= 0.60
      [hit, stats]
    end
  end
end

default_pdf = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf(
  'Alvord TX — Garden Map · Final.pdf'
)
pdf = ARGV[0] || default_pdf || 'C:/Users/Rowdy Payton/Desktop/PDFTest Files/Alvord TX — Garden Map · Final.pdf'
unless File.exist?(pdf)
  warn "PDF not found: #{pdf}"
  exit 1
end

opts = BlueCollarSystems::PDFVectorImporter::ImportDialog.build_opts(
  import_mode: 'auto',
  pages: 'All',
  scale: '1.0',
  text_mode: '3D Text',
  import_text: 'Yes'
)

parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf)
parser.parse

puts "PDF: #{File.basename(pdf)}"
puts "build_opts: import_fills=#{opts[:import_fills]} raster_fallback=#{opts[:raster_fallback]} import_mode=#{opts[:import_mode]}"
puts "pages=#{parser.page_count}"

(1..parser.page_count).each do |pg|
  raw = parser.page_data(pg)
  mb = raw[:media_box]
  cb = raw[:crop_box]
  page_box = (cb.is_a?(Array) && cb.length >= 4) ? cb : mb
  streams = raw[:content_streams] || []
  ocg = begin
    parser.page_ocg_map(pg)
  rescue StandardError
    {}
  end
  paths = BlueCollarSystems::PDFVectorImporter::ContentStreamParser.new(streams, parser, ocg).parse
  fills = paths.count { |p| p.fill }
  strokes = paths.count { |p| p.stroke }
  fill_only = paths.count { |p| p.fill && !p.stroke }
  colors = paths.map { |p| p.fill_color || p.stroke_color }.compact.uniq.length
  flood, stats = BlueCollarSystems::PDFVectorImporter.looks_like_fill_art_flood?(paths, mb)
  puts "Page #{pg}: paths=#{paths.length} fill=#{fills} stroke=#{strokes} fill_only=#{fill_only} unique_colors=#{colors}"
  puts "  media=#{mb.inspect}"
  puts "  crop=#{cb.inspect}" if cb
  if cb && mb
    dx = (cb[0].to_f - mb[0].to_f).round(3)
    dy = (cb[1].to_f - mb[1].to_f).round(3)
    puts "  crop-media origin delta pts: (#{dx}, #{dy})"
  end
  puts "  fill_art_flood=#{flood} stats=#{stats.inspect}"
end

parser.release
