#!/usr/bin/env ruby
require 'json'
require 'digest'

module SketchupHostJob
  TEXT_MODES = [:text, :labels, :text3d, :glyphs, :geometry, :raster].freeze unless const_defined?(:TEXT_MODES, false)
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
    source_tree_sha256 = raw['source_tree_sha256']
    unless source_tree_sha256.nil?
      source_tree_sha256 = source_tree_sha256.to_s.downcase
      unless source_tree_sha256 =~ /\A[0-9a-f]{64}\z/
        raise ArgumentError, 'source tree SHA256 is invalid'
      end
    end
    release_identity = normalize_release_identity(
      raw, File.extname(input).downcase == '.json' ? File.dirname(input) : nil,
      source_tree_sha256
    )
    if release_identity[:release_acceptance] && pages == :all
      raise ArgumentError,
            'release acceptance requires exact requested page numbers'
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
      :source_tree_sha256 => source_tree_sha256,
      :release_acceptance => release_identity[:release_acceptance],
      :repository_root => release_identity[:repository_root],
      :git_commit => release_identity[:git_commit],
      :git_tag => release_identity[:git_tag],
      :package_path => release_identity[:package_path],
      :package_sha256 => release_identity[:package_sha256],
      :expected_importer_version =>
        release_identity[:expected_importer_version],
      :lease_evidence => release_identity[:lease_evidence],
      :output_dir => output_dir,
      :text_mode => text_mode,
      :import_mode => import_mode,
      :pages => pages,
      :skp_export_only => raw['skp_export_only'] == true,
      :model_path => File.join(output_dir, "#{base}-#{text_mode}.skp"),
      :result_path => File.join(output_dir, 'host_acceptance.json'),
      :progress_path => File.join(output_dir, 'host_progress.json')
    }
  end

  def self.normalize_release_identity(raw, base_dir, source_tree_sha256)
    return { :release_acceptance => false } unless
      raw['release_acceptance'] == true
    required = %w[
      repository_root git_commit git_tag package_path package_sha256
      expected_importer_version lease_evidence
    ]
    missing = required.select do |key|
      !raw.key?(key) || raw[key].nil? || raw[key].to_s.strip.empty?
    end
    unless missing.empty?
      raise ArgumentError,
            "release acceptance requires #{missing.join(', ')}"
    end
    unless source_tree_sha256.to_s =~ /\A[0-9a-f]{64}\z/
      raise ArgumentError,
            'release acceptance requires exact source_tree_sha256'
    end
    repository_root = File.expand_path(raw['repository_root'].to_s, base_dir)
    package_path = File.expand_path(raw['package_path'].to_s, base_dir)
    raise ArgumentError, 'repository_root is not a directory' unless
      File.directory?(repository_root)
    raise ArgumentError, 'package_path is not a file' unless File.file?(package_path)
    git_commit = raw['git_commit'].to_s.downcase
    unless git_commit =~ /\A[0-9a-f]{40}\z/
      raise ArgumentError, 'git_commit must be an exact 40-hex SHA'
    end
    git_tag = raw['git_tag'].to_s
    unless git_tag =~ /\Av[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z/
      raise ArgumentError, 'git_tag is invalid'
    end
    version = raw['expected_importer_version'].to_s
    unless version =~ /\A[0-9]+\.[0-9]+\.[0-9]+\z/
      raise ArgumentError, 'expected_importer_version is invalid'
    end
    package_sha256 = raw['package_sha256'].to_s.downcase
    unless package_sha256 =~ /\A[0-9a-f]{64}\z/ &&
           Digest::SHA256.file(package_path).hexdigest == package_sha256
      raise ArgumentError, 'package SHA256 does not match exact package bytes'
    end
    lease = normalize_lease_evidence(raw['lease_evidence'], base_dir)
    {
      :release_acceptance => true,
      :repository_root => repository_root,
      :git_commit => git_commit,
      :git_tag => git_tag,
      :package_path => package_path,
      :package_sha256 => package_sha256,
      :expected_importer_version => version,
      :lease_evidence => lease
    }
  end

  def self.normalize_lease_evidence(raw, base_dir)
    unless raw.is_a?(Hash) && !raw['claimant'].to_s.strip.empty?
      raise ArgumentError, 'lease_evidence claimant is missing'
    end
    result = { 'claimant' => raw['claimant'].to_s }
    %w[resource_board_path global_lock_path host_lock_path].each do |key|
      path = File.expand_path(raw[key].to_s, base_dir)
      unless File.file?(path)
        raise ArgumentError, "lease_evidence #{key} is missing"
      end
      result[key] = path
      result[key.sub(/_path\z/, '_sha256')] =
        Digest::SHA256.file(path).hexdigest
    end
    result
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
