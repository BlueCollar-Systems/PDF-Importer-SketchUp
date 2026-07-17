#!/usr/bin/env ruby
require 'json'

module SketchupHostJob
  TEXT_MODES = [:labels, :text3d, :glyphs, :geometry, :raster].freeze unless const_defined?(:TEXT_MODES, false)
  IMPORT_MODES = ['auto', 'vector', 'raster', 'hybrid'].freeze unless const_defined?(:IMPORT_MODES, false)

  def self.load(argument)
    raise ArgumentError, 'one job JSON or PDF path is required' if argument.to_s.strip.empty?
    input = File.expand_path(argument.to_s)
    if File.extname(input).downcase == '.json'
      raw = JSON.parse(File.read(input, :encoding => 'UTF-8'))
      pdf_path = File.expand_path(raw.fetch('pdf_path'), File.dirname(input))
      output_dir = File.expand_path(raw.fetch('output_dir'), File.dirname(input))
      text_mode = raw.fetch('text_mode').to_s.downcase.to_sym
      import_mode = raw.fetch('import_mode', 'auto').to_s.downcase
      pages = normalize_pages(raw.fetch('pages', 'all'))
    else
      pdf_path = input
      output_dir = File.dirname(input)
      text_mode = :labels
      import_mode = 'auto'
      pages = :all
    end
    raise ArgumentError, "PDF not found: #{pdf_path}" unless File.file?(pdf_path)
    raise ArgumentError, "unsupported text_mode: #{text_mode}" unless TEXT_MODES.include?(text_mode)
    raise ArgumentError, "unsupported import_mode: #{import_mode}" unless IMPORT_MODES.include?(import_mode)
    base = File.basename(pdf_path, File.extname(pdf_path))
    {
      :pdf_path => pdf_path,
      :output_dir => output_dir,
      :text_mode => text_mode,
      :import_mode => import_mode,
      :pages => pages,
      :model_path => File.join(output_dir, "#{base}-#{text_mode}.skp"),
      :result_path => File.join(output_dir, 'host_acceptance.json')
    }
  end

  def self.normalize_pages(value)
    return :all if value.to_s.downcase == 'all'
    pages = Array(value).map { |page| Integer(page) }
    raise ArgumentError, 'pages must contain positive integers' if pages.empty? || pages.any? { |page| page < 1 }
    pages.uniq.sort
  rescue StandardError
    raise ArgumentError, 'pages must be all or positive integers'
  end
end
