#!/usr/bin/env ruby
require_relative 'extracted/sketchup_ext/bc_pdf_vector_importer/logger'
require_relative 'extracted/sketchup_ext/bc_pdf_vector_importer/pdf_reader'
require_relative 'extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_decoder'
require_relative 'extracted/sketchup_ext/bc_pdf_vector_importer/text_parser'

PDF = 'C:/Users/Rowdy Payton/Desktop/PDFTest Files/1017 - Rev 0.pdf'
reader = BlueCollarSystems::PDFVectorImporter::PDFReader.new(PDF)
page = reader.page(1)
streams = page.content_streams
font_maps = page.font_maps
items = BlueCollarSystems::PDFVectorImporter::TextParser.new(streams, font_maps, {}, {}).parse
puts "TextParser count: #{items.length}"
items.select { |it| %w[a1005 a1006].include?(it.text.to_s.strip) }.each do |it|
  puts "#{it.text.ljust(8)} angle=#{it.angle.to_f.round(2)} x=#{it.x.round(2)} y=#{it.y.round(2)} fs=#{it.font_size.to_f.round(2)}"
end
