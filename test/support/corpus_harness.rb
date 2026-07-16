# test/support/corpus_harness.rb
# Shared headless corpus analysis + label placement simulation for SU CI.

require 'digest'
require 'fileutils'
require 'json'
require 'timeout'

require_relative '../../corpus_paths'

REPO_ROOT = File.expand_path('../..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/external_text_extractor'
require 'bc_pdf_vector_importer/pdf_salvage'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

unless defined?(Geom::Point3d)
  module Geom
    class Point3d
      attr_accessor :x, :y, :z
      def initialize(x = 0, y = 0, z = 0)
        @x = x.to_f
        @y = y.to_f
        @z = z.to_f
      end
    end

    class Vector3d
      attr_accessor :x, :y, :z
      def initialize(x = 0, y = 0, z = 0)
        @x = x.to_f
        @y = y.to_f
        @z = z.to_f
      end
    end
  end
end

class CorpusDummyTextEntity
  attr_accessor :layer
end

class CorpusDummyEntities
  attr_reader :texts
  def initialize
    @texts = []
  end
  def add_text(text, point, vector = nil)
    ent = CorpusDummyTextEntity.new
    @texts << [text, point, vector, ent]
    ent
  end
end

unless defined?(Sketchup::Model)
  module Sketchup
    class Model
      def layers
        @layers ||= {}
      end
      def layers_add(name)
        layers[name] = name
      end
    end
  end
end

module CorpusHarness
  TIMEOUT_SECONDS = (ENV['CORPUS_PDF_TIMEOUT'] || '90').to_i
  HEAVY_TIMEOUT_SECONDS = (ENV['CORPUS_HEAVY_PDF_TIMEOUT'] || '300').to_i
  PAGE_COUNT_TIMEOUT_SECONDS = (ENV['CORPUS_PAGE_COUNT_TIMEOUT'] || '10').to_i
  HEAVY_PDF_MB = (ENV['CORPUS_HEAVY_PDF_MB'] || '8').to_f
  HEAVY_PAGE_COUNT = (ENV['CORPUS_HEAVY_PAGE_COUNT'] || '30').to_i
  HEAVY_PATH_BUDGET = (ENV['CORPUS_HEAVY_PATH_BUDGET'] || '750000').to_i
  # CORPUS_STRESS_OPTOUT: pipe-separated PDF basenames skipped in CI (manual QA only).
  # Document additions in test/PRIVATE_VALIDATION_STRESS_OPTOUT.md and note in PR description.
  STRESS_PDF_SLUGS = (ENV['CORPUS_STRESS_OPTOUT'] || '')
                     .split('|').map(&:strip).reject(&:empty?).freeze
  # Soft cap — warn when the opt-out list grows (Round-2 action #6).
  STRESS_OPTOUT_SOFT_CAP = (ENV['CORPUS_STRESS_OPTOUT_CAP'] || '5').to_i
  PLACEMENT_THRESHOLD_DEFAULT = 0.95
  PLACEMENT_THRESHOLD_VECTOR = 1.0
  BASELINE_DIR = File.join(REPO_ROOT, 'test', 'fixtures', 'corpus_baselines')
  EXPECTED_REFUSALS = {
    'encryption_openpassword.pdf' => /encrypted|password-protected/i
  }.freeze

  @geometry_builder_loaded = false
  @stress_optout_warned = false

  def self.warn_stress_optout_cap!
    return if @stress_optout_warned
    return if STRESS_PDF_SLUGS.length <= STRESS_OPTOUT_SOFT_CAP
    @stress_optout_warned = true
    warn(
      "CORPUS_STRESS_OPTOUT has #{STRESS_PDF_SLUGS.length} entries " \
      "(soft cap #{STRESS_OPTOUT_SOFT_CAP}). Prefer manual QA for heavy PDFs; " \
      "document additions in test/PRIVATE_VALIDATION_STRESS_OPTOUT.md and note in PR."
    )
  end

  def self.install_headless_stubs!
    return if @geometry_builder_loaded
    load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')
    @geometry_builder_loaded = true
  end

  def self.pdftotext_available?
    BlueCollarSystems::PDFVectorImporter::ExternalTextExtractor
      .send(:pdftotext_executable) != nil
  rescue StandardError
    false
  end

  def self.geometry_builder
    install_headless_stubs!
    @geometry_builder ||= BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
      Sketchup::Model.new,
      [],
      [],
      [0, 0, 612, 792],
      scale_factor: 1.0,
      import_text: true,
      use_3d_text: false
    )
  end

  def self.page_geometry_builder(page_info, page_number, rotation = nil)
    install_headless_stubs!
    media_box = page_info[:crop_box]
    unless media_box.is_a?(Array) && media_box.length >= 4
      media_box = page_info[:media_box]
    end
    media_box = [0, 0, 612, 792] unless media_box.is_a?(Array) &&
                                            media_box.length >= 4
    rotation = page_info[:rotation] if rotation.nil?
    BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
      Sketchup::Model.new,
      [],
      [],
      media_box,
      scale_factor: 1.0,
      import_text: true,
      use_3d_text: false,
      page_number: page_number,
      page_rotation: rotation
    )
  end

  def self.page_height_for_info(page_info, rotation = nil)
    media_box = page_info[:crop_box]
    unless media_box.is_a?(Array) && media_box.length >= 4
      media_box = page_info[:media_box]
    end
    media_box = [0, 0, 612, 792] unless media_box.is_a?(Array) &&
                                            media_box.length >= 4
    rotation = page_info[:rotation] if rotation.nil?
    BlueCollarSystems::PDFVectorImporter::PageTransform.effective_height(
      media_box, rotation
    )
  rescue StandardError
    792.0
  end

  def self.timeout_exceeded?(start_time, timeout_s)
    (Time.now - start_time) >= timeout_s.to_f
  end

  def self.heavy_pdf?(pdf_path, page_count = nil)
    return true if File.size(pdf_path) > (HEAVY_PDF_MB * 1024.0 * 1024.0)
    return true if page_count.to_i >= HEAVY_PAGE_COUNT
    false
  rescue StandardError
    false
  end

  def self.timeout_for(pdf_path, page_count = nil)
    heavy_pdf?(pdf_path, page_count) ? HEAVY_TIMEOUT_SECONDS : TIMEOUT_SECONDS
  end

  def self.page_count_hint_for(pdf_path)
    return nil if heavy_pdf?(pdf_path, nil)
    estimate_page_count(pdf_path)
  rescue StandardError
    nil
  end

  def self.estimate_page_count(pdf_path)
    parser = nil
    count = nil
    Timeout.timeout(PAGE_COUNT_TIMEOUT_SECONDS) do
      parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(pdf_path)
      parser.parse
      count = parser.page_count
    end
    count
  rescue StandardError, Timeout::Error
    nil
  ensure
    begin
      parser.release if parser
    rescue StandardError
    end
  end

  def self.analyze_pdf(pdf_info)
    warn_stress_optout_cap!

    pdf_path = pdf_info[:path]
    result = {
      corpus_key: pdf_info[:corpus_key],
      pdf_name: File.basename(pdf_path),
      path: pdf_path,
      status: nil,
      pages: 0,
      paths: 0,
      text_items: 0,
      bbox_items: 0,
      bbox_pct: 0.0,
      placement_ok: 0,
      placement_total: 0,
      placement_rate: 0.0,
      rotated_pages: 0,
      rotated_placement_ok: 0,
      rotated_placement_total: 0,
      rotated_placement_rate: 1.0,
      text_hash: nil,
      text_source: nil,
      salvage_note: nil,
      error: nil,
      time_s: 0.0,
      heavy: false
    }

    start_time = Time.now
    builder = geometry_builder
    all_text_items = []
    page_placements = []
    rotated_pages = 0
    analysis_path = pdf_path
    parser = nil
    timeout_s = TIMEOUT_SECONDS

    if STRESS_PDF_SLUGS.include?(File.basename(pdf_path))
      result[:status] = 'TIMEOUT'
      result[:error] = 'Stress PDF opt-out (manual QA only; exceeds CI budget)'
      result[:time_s] = (Time.now - start_time).round(2)
      return result
    end

    begin
      analysis_path, salvage_note =
        BlueCollarSystems::PDFVectorImporter::PdfSalvage
          .prepare_if_needed(pdf_path)
      result[:salvage_note] = salvage_note
      page_count_hint = page_count_hint_for(analysis_path)
      result[:heavy] = heavy_pdf?(analysis_path, page_count_hint)
      timeout_s = timeout_for(analysis_path, page_count_hint)

      Timeout.timeout(timeout_s) do
        parser = BlueCollarSystems::PDFVectorImporter::PDFParser.new(analysis_path)
        parser.parse
        if parser.page_count == 0
          raise 'PDF parser returned zero pages after production salvage preflight'
        end
        result[:pages] = parser.page_count
        result[:heavy] = heavy_pdf?(analysis_path, parser.page_count)

        total_paths = 0
        text_source = nil

        (1..parser.page_count).each do |pg|
          if timeout_exceeded?(start_time, timeout_s)
            raise Timeout::Error, "Exceeded #{timeout_s}s"
          end

          page_info = parser.page_data(pg)
          next unless page_info

          streams = page_info[:content_streams] || []
          ocg_map = begin
            parser.page_ocg_map(pg) || {}
          rescue StandardError
            {}
          end

          csp = BlueCollarSystems::PDFVectorImporter::ContentStreamParser.new(
            streams, parser, ocg_map
          )
          page_paths = csp.parse.length
          total_paths += page_paths
          if result[:heavy] && total_paths > HEAVY_PATH_BUDGET
            raise Timeout::Error,
                  "Heavy PDF path budget exceeded (#{total_paths} > #{HEAVY_PATH_BUDGET})"
          end

          page_items, source = extract_page_text(
            parser, analysis_path, pg, streams, ocg_map
          )
          text_source ||= source
          all_text_items.concat(page_items) if page_items && !page_items.empty?

          rotation = BlueCollarSystems::PDFVectorImporter::PageTransform
                       .normalize_rotation(page_info[:rotation])
          page_builder = page_geometry_builder(page_info, pg, rotation)
          control_builder = rotation == 0 ? nil :
                              page_geometry_builder(page_info, pg, 0)
          rotated_pages += 1 unless rotation == 0
          page_placements << simulate_placement(
            page_builder,
            page_items || [],
            page_height_for_info(page_info, rotation),
            control_builder,
            page_height_for_info(page_info, 0)
          )
        end

        result[:paths] = total_paths
        result[:text_items] = all_text_items.length
        result[:text_source] = text_source
        result[:bbox_items] = all_text_items.count { |it| builder.send(:label_has_bbox?, it) }
        result[:bbox_pct] = if all_text_items.empty?
                              0.0
                            else
                              (100.0 * result[:bbox_items] / all_text_items.length).round(2)
                            end

        placement_ok = page_placements.inject(0) { |sum, item| sum + item[:ok].to_i }
        placement_total = page_placements.inject(0) do |sum, item|
          sum + item[:total].to_i
        end
        placed_texts = page_placements.inject([]) do |all, item|
          all.concat(Array(item[:placed_texts]))
        end
        rotated_ok = page_placements.inject(0) do |sum, item|
          sum + item[:rotated_ok].to_i
        end
        rotated_total = page_placements.inject(0) do |sum, item|
          sum + item[:rotated_total].to_i
        end
        result[:placement_ok] = placement_ok
        result[:placement_total] = placement_total
        result[:placement_rate] = placement_total == 0 ? 1.0 :
                                    (placement_ok.to_f / placement_total).round(4)
        result[:rotated_pages] = rotated_pages
        result[:rotated_placement_ok] = rotated_ok
        result[:rotated_placement_total] = rotated_total
        result[:rotated_placement_rate] = rotated_total == 0 ? 1.0 :
                                            (rotated_ok.to_f / rotated_total).round(4)
        result[:text_hash] = text_hash_for(placed_texts)
        result[:texts] = all_text_items.map { |it| it.respond_to?(:text) ? it.text.to_s : it.to_s }
        result[:status] = 'OK'
      end
    rescue Timeout::Error
      result[:status] = 'TIMEOUT'
      result[:error] = "Exceeded #{timeout_s}s"
    rescue StandardError => e
      result[:status] = 'FAIL'
      result[:error] = "#{e.class}: #{e.message}"
    ensure
      begin
        parser.release if parser
      rescue StandardError
      end
      BlueCollarSystems::PDFVectorImporter::PdfSalvage.cleanup(analysis_path)
    end

    result[:time_s] = (Time.now - start_time).round(2)
    result
  end

  def self.extract_page_text(parser, pdf_path, page_num, streams, ocg_map)
    ext = BlueCollarSystems::PDFVectorImporter::ExternalTextExtractor
    font_maps = parser.page_font_maps(page_num)
    parser_opts = { strict_text_fidelity: false }

    if pdftotext_available?
      items = ext.extract(pdf_path, page_num)
      return [items, :external] if items && !items.empty?
    end

    items = BlueCollarSystems::PDFVectorImporter::TextParser.new(
      streams, font_maps, parser_opts, ocg_map
    ).parse
    [items || [], :internal]
  end

  def self.page_height_for(parser)
    raw = parser.page_data(1)
    return 792.0 unless raw
    mb = raw[:media_box]
    cb = raw[:crop_box]
    box = (cb.is_a?(Array) && cb.length >= 4) ? cb : mb
    return 792.0 unless box.is_a?(Array) && box.length >= 4
    (box[3].to_f - box[1].to_f).abs
  rescue StandardError
    792.0
  end

  def self.expected_placements_for(builder, item)
    return 0 unless item.text && !item.text.to_s.strip.empty?
    if builder.send(:stacked_vertical_dimension_labels?, item)
      item.text.to_s.strip.split(/\s+/).length
    else
      1
    end
  end

  def self.simulate_placement(builder, items, page_height,
                              control_builder = nil,
                              control_page_height = nil)
    entities = CorpusDummyEntities.new
    control_entities = control_builder ? CorpusDummyEntities.new : nil
    placed_texts = []
    placement_ok = 0
    placement_total = 0
    rotated_ok = 0
    rotated_total = 0

    items.each do |item|
      next unless item.text && !item.text.to_s.strip.empty?
      expected = expected_placements_for(builder, item)
      placement_total += expected
      rotated_total += expected if control_builder
      before = entities.texts.length
      begin
        builder.send(:place_text, entities, item, 0.0, 0.0, page_height, 'TextLayer')
        added = entities.texts.length - before
        placement_ok += added if added > 0
        entities.texts[before...entities.texts.length].each { |t| placed_texts << t[0].to_s }

        if control_builder
          control_before = control_entities.texts.length
          control_builder.send(
            :place_text, control_entities, item, 0.0, 0.0,
            control_page_height || page_height, 'TextLayer'
          )
          actual_entries = entities.texts[before...entities.texts.length]
          control_entries = control_entities.texts[
            control_before...control_entities.texts.length
          ]
          expected.times do |index|
            if rotated_placement_evidence?(
              actual_entries[index], control_entries[index]
            )
              rotated_ok += 1
            end
          end
        end
      rescue StandardError
        # count as failed placement for this item
      end
    end

    rate = placement_total == 0 ? 1.0 : (placement_ok.to_f / placement_total)
    {
      ok: placement_ok,
      total: placement_total,
      rate: rate.round(4),
      text_hash: text_hash_for(placed_texts),
      placed_texts: placed_texts,
      rotated_ok: rotated_ok,
      rotated_total: rotated_total
    }
  end

  def self.rotated_placement_evidence?(actual, control)
    return false unless actual && control
    actual_point = actual[1]
    actual_vector = actual[2]
    control_point = control[1]
    control_vector = control[2]
    return false unless finite_xyz?(actual_point) && finite_xyz?(actual_vector)
    return false unless finite_xyz?(control_point) && finite_xyz?(control_vector)

    point_delta = xyz_delta(actual_point, control_point)
    vector_delta = xyz_delta(actual_vector, control_vector)
    point_delta > 1.0e-8 && vector_delta > 1.0e-8
  rescue StandardError
    false
  end

  def self.finite_xyz?(value)
    return false unless value
    [:x, :y, :z].all? do |axis|
      value.respond_to?(axis) && value.send(axis).to_f.finite?
    end
  end

  def self.xyz_delta(left, right)
    [:x, :y, :z].inject(0.0) do |sum, axis|
      sum + (left.send(axis).to_f - right.send(axis).to_f).abs
    end
  end

  def self.text_hash_for(texts)
    Digest::SHA256.hexdigest(texts.sort.join("\n"))
  end

  def self.placement_threshold(result)
    return PLACEMENT_THRESHOLD_DEFAULT if result[:text_items].to_i == 0
    vector_sheet = result[:bbox_pct].to_f >= 50.0 && result[:text_items].to_i >= 10
    vector_sheet ? PLACEMENT_THRESHOLD_VECTOR : PLACEMENT_THRESHOLD_DEFAULT
  end

  def self.expected_refusal?(pdf_info, result)
    return false unless result[:status] == 'FAIL'
    pattern = EXPECTED_REFUSALS[File.basename(pdf_info[:path])]
    pattern && !result[:error].to_s.match(pattern).nil?
  end

  def self.mark_expected_refusal!(result)
    result[:status] = 'REFUSED'
    result[:expected_refusal] = true
    result
  end

  def self.baseline_record(result)
    {
      'pdf_name' => result[:pdf_name],
      'corpus_key' => canonical_baseline_key(result[:corpus_key]),
      'pages' => result[:pages],
      'paths' => result[:paths],
      'text_items' => result[:text_items],
      'bbox_pct' => result[:bbox_pct],
      'placement_ok' => result[:placement_ok],
      'placement_total' => result[:placement_total],
      'text_hash' => result[:text_hash]
    }
  end

  def self.canonical_baseline_key(corpus_key)
    paths = BlueCollarSystems::PDFVectorImporter::CorpusPaths
    if paths.respond_to?(:canonical_baseline_key)
      paths.canonical_baseline_key(corpus_key)
    else
      corpus_key
    end
  end

  def self.baseline_path(corpus_key)
    slug = BlueCollarSystems::PDFVectorImporter::CorpusPaths.baseline_slug(corpus_key)
    File.join(BASELINE_DIR, slug)
  end

  def self.load_baseline(corpus_key)
    paths = if BlueCollarSystems::PDFVectorImporter::CorpusPaths.respond_to?(:baseline_slug_candidates)
              BlueCollarSystems::PDFVectorImporter::CorpusPaths
                .baseline_slug_candidates(corpus_key)
                .map { |slug| File.join(BASELINE_DIR, slug) }
            else
              [baseline_path(corpus_key)]
            end
    path = paths.find { |candidate| File.file?(candidate) }
    return nil unless path
    JSON.parse(File.read(path))
  rescue StandardError
    nil
  end

  def self.save_baseline(result)
    FileUtils.mkdir_p(BASELINE_DIR) unless File.directory?(BASELINE_DIR)
    path = baseline_path(result[:corpus_key])
    File.write(path, JSON.pretty_generate(baseline_record(result)) + "\n")
    path
  end

  def self.compare_baseline(result, baseline)
    mismatches = []
    record = baseline_record(result)
    record.each do |key, value|
      next if key == 'corpus_key'
      expected = baseline[key]
      next if expected == value
      mismatches << "#{key}: expected #{expected.inspect}, got #{value.inspect}"
    end
    mismatches
  end

  def self.print_summary_table(results)
    puts
    puts '=' * 120
    puts 'CORPUS PLACEMENT SUMMARY'
    puts '=' * 120
    header = format(
      '%-4s  %-42s  %6s  %5s  %6s  %5s  %6s  %6s  %7s  %s',
      '#', 'PDF', 'Status', 'Pages', 'Paths', 'Text', 'Bbox%', 'Place', 'Time(s)', 'Error'
    )
    puts header
    puts '-' * header.length

    results.each_with_index do |r, i|
      place = if r[:placement_total].to_i == 0
                'n/a'
              else
                format('%d/%d', r[:placement_ok], r[:placement_total])
              end
      name = r[:pdf_name].to_s
      name = name[0, 39] + '...' if name.length > 42
      puts format(
        '%-4d  %-42s  %6s  %5d  %6d  %5d  %5.1f  %6s  %7.2f  %s',
        i + 1, name, r[:status], r[:pages], r[:paths], r[:text_items],
        r[:bbox_pct], place, r[:time_s], r[:error] || ''
      )
    end

    ok = results.count { |r| r[:status] == 'OK' }
    refused_n = results.count { |r| r[:status] == 'REFUSED' }
    fail_n = results.count { |r| r[:status] == 'FAIL' }
    timeout_n = results.count { |r| r[:status] == 'TIMEOUT' }
    puts
    puts "TOTALS: #{ok} OK / #{refused_n} EXPECTED REFUSAL / #{fail_n} FAIL / #{timeout_n} TIMEOUT of #{results.length} PDFs"
    puts "pdftotext: #{pdftotext_available? ? 'available' : 'unavailable (internal TextParser fallback)'}"
    puts '=' * 120
  end
end
