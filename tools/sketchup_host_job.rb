#!/usr/bin/env ruby
require 'json'
require 'digest'

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
      original_pdf_path = File.expand_path(
        raw.fetch('original_pdf_path', pdf_path), File.dirname(input)
      )
      immutable_pdf_path = File.expand_path(
        raw.fetch('immutable_pdf_path', pdf_path), File.dirname(input)
      )
    else
      pdf_path = input
      output_dir = File.dirname(input)
      text_mode = :labels
      import_mode = 'auto'
      pages = :all
      raw = {}
      original_pdf_path = pdf_path
      immutable_pdf_path = pdf_path
    end
    raise ArgumentError, "PDF not found: #{pdf_path}" unless File.file?(pdf_path)
    unless immutable_pdf_path == pdf_path
      raise ArgumentError, 'pdf_path must identify the immutable PDF snapshot'
    end
    immutable_sha256 = Digest::SHA256.file(immutable_pdf_path).hexdigest
    expected_immutable_sha256 = raw.fetch(
      'immutable_pdf_sha256', immutable_sha256
    ).to_s.downcase
    unless expected_immutable_sha256 == immutable_sha256
      raise ArgumentError, 'immutable PDF SHA256 does not match snapshot bytes'
    end
    original_sha256 = if raw.key?('original_pdf_sha256')
                        raw['original_pdf_sha256'].to_s.downcase
                      elsif File.file?(original_pdf_path)
                        Digest::SHA256.file(original_pdf_path).hexdigest
                      else
                        immutable_sha256
                      end
    unless original_sha256 =~ /\A[0-9a-f]{64}\z/
      raise ArgumentError, 'original PDF SHA256 is invalid'
    end
    raise ArgumentError, "unsupported text_mode: #{text_mode}" unless TEXT_MODES.include?(text_mode)
    raise ArgumentError, "unsupported import_mode: #{import_mode}" unless IMPORT_MODES.include?(import_mode)
    base = File.basename(pdf_path, File.extname(pdf_path))
    {
      :job_path => input,
      :job_sha256 => Digest::SHA256.file(input).hexdigest,
      :pdf_path => pdf_path,
      :original_pdf_path => original_pdf_path,
      :original_pdf_sha256 => original_sha256,
      :immutable_pdf_path => immutable_pdf_path,
      :immutable_pdf_sha256 => immutable_sha256,
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
    pages = Array(value).map do |page|
      if page.is_a?(Integer)
        page
      elsif page.is_a?(String) && page =~ /\A[1-9][0-9]*\z/
        page.to_i
      else
        raise ArgumentError, 'pages must contain positive integers'
      end
    end
    raise ArgumentError, 'pages must contain positive integers' if pages.empty? || pages.any? { |page| page < 1 }
    pages.uniq.sort
  rescue StandardError
    raise ArgumentError, 'pages must be all or positive integers'
  end
end
