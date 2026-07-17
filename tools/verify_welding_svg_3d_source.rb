#!/usr/bin/env ruby
# Read-only fixture diagnostic for the exact source-outline 3D text path.

require 'json'
require 'tmpdir'

repo_root = File.expand_path('..', __dir__)
src_root = File.join(repo_root, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(src_root) unless $LOAD_PATH.include?(src_root)

module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def distance(other)
      dx = x - other.x.to_f
      dy = y - other.y.to_f
      dz = z - other.z.to_f
      Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    end
  end unless const_defined?(:Point3d)
end

require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/external_text_extractor'
require 'bc_pdf_vector_importer/text_source_identity'
require 'bc_pdf_vector_importer/cairo_glyph_source'
require 'bc_pdf_vector_importer/svg_3d_text_renderer'
require 'bc_pdf_vector_importer/svg_item_representation_renderer'
require 'bc_pdf_vector_importer/main'

mod = BlueCollarSystems::PDFVectorImporter

def raster_source_probe(mod, pdf_path, page_num, use_cropbox)
  exe = mod::SvgTextRenderer.find_pdftocairo
  return { :ok => false, :reason => 'pdftocairo_unavailable' } unless exe

  base = File.join(
    Dir.tmpdir,
    "bc_welding_raster_probe_#{Process.pid}_#{Time.now.to_i}_#{page_num}"
  )
  png = base + '.png'
  args = [exe, '-png', '-singlefile', '-r', '150']
  args << '-cropbox' if use_cropbox
  args += ['-f', page_num.to_s, '-l', page_num.to_s, pdf_path, base]
  run = mod::CommandRunner.run(
    args, :timeout_s => 180, :context => 'WeldingFixture.raster_probe'
  )
  return {
    :ok => false, :reason => 'pdftocairo_failed',
    :stderr => run[:stderr].to_s[0, 500]
  } unless run[:ok] && File.file?(png)

  header = File.open(png, 'rb') { |file| file.read(24) }
  signature_ok = header && header.bytes[0, 8] == [137, 80, 78, 71, 13, 10, 26, 10]
  width, height = signature_ok ? header[16, 8].unpack('NN') : [0, 0]
  {
    :ok => signature_ok && width.to_i > 0 && height.to_i > 0,
    :renderer => exe,
    :png_signature_verified => signature_ok,
    :pixel_width => width.to_i,
    :pixel_height => height.to_i,
    :bytes => File.size(png)
  }
rescue StandardError => e
  { :ok => false, :reason => e.class.name, :detail => e.message }
ensure
  begin
    File.delete(png) if defined?(png) && png && File.file?(png)
  rescue StandardError
  end
end

# Exercise the production item-crop geometry and artifact verifier without
# pretending that a PNG is already a SketchUp::Image. Host entity creation,
# save/reopen, and source-file deletion remain separate live-SketchUp gates.
def item_raster_source_probe(mod, pdf_path, page_num, item, media_box,
                             page_rotation = 0, dpi = 400)
  exe = mod::SvgTextRenderer.find_pdftocairo
  return { :ok => false, :reason => 'pdftocairo_unavailable' } unless exe

  crop = mod.item_raster_crop_geometry(
    item, media_box, page_rotation, dpi
  )
  pixel_x, pixel_y, pixel_width, pixel_height = crop[:pixel_crop]
  source_id = mod::RepresentationFidelity.source_span_id(item)
  safe_id = source_id.gsub(/[^A-Za-z0-9_-]+/, '_')
  base = File.join(
    Dir.tmpdir,
    "bc_welding_item_probe_#{Process.pid}_#{Time.now.to_i}_#{safe_id}"
  )
  png = base + '.png'
  candidates = [
    png, png.sub(/\.png$/, "-#{page_num}.png"),
    png.sub(/\.png$/, '-01.png'), png.sub(/\.png$/, '-1.png')
  ]
  args = [
    exe, '-png', '-singlefile', '-r', dpi.to_s,
    '-x', pixel_x.to_s, '-y', pixel_y.to_s,
    '-W', pixel_width.to_s, '-H', pixel_height.to_s,
    '-f', page_num.to_s, '-l', page_num.to_s,
    pdf_path, base
  ]
  run = mod::CommandRunner.run(
    args, :timeout_s => 180,
    :context => 'WeldingFixture.item_raster_probe'
  )
  unless run[:ok] && !run[:timed_out]
    return {
      :ok => false, :reason => 'pdftocairo_failed',
      :stderr => run[:stderr].to_s[0, 500]
    }
  end
  actual_png = candidates.find { |candidate| File.file?(candidate) }
  return { :ok => false, :reason => 'item_png_missing' } unless actual_png

  artifact = mod.verify_item_raster_artifact!(
    actual_png, item, page_num, crop, args
  )
  {
    :ok => true,
    :source_span_id => source_id,
    :page_number => artifact[:page_number],
    :page_rotation => artifact[:page_rotation],
    :pixel_crop => artifact[:pixel_crop],
    :pixel_width => artifact[:pixel_width],
    :pixel_height => artifact[:pixel_height],
    :png_signature_verified => artifact[:png_signature_verified],
    :page_binding_verified => artifact[:page_binding_verified],
    :source_crop_binding_verified => artifact[:source_crop_binding_verified],
    :aspect_verified => artifact[:aspect_verified]
  }
rescue StandardError => e
  { :ok => false, :reason => e.class.name, :detail => e.message }
ensure
  Array(candidates).each do |candidate|
    begin
      File.delete(candidate) if candidate && File.file?(candidate)
    rescue StandardError
    end
  end
end

# A source-only diagnostic must never pretend it owns SketchUp entities. The
# real renderers can still prove an item-specific source absence before host
# creation. When source outlines do exist, this collection makes the attempt
# stop at the honest live-host boundary.
class WeldingSourceProbeEntities
  def to_a
    []
  end
end

def live_host_creation_boundary?(value)
  detail = if value.is_a?(Hash)
             value[:detail].to_s
           else
             value.to_s
           end
  detail =~ /parent entities cannot create an owned (?:item vector )?group/i
end

def compact_coverage_failure(failure)
  record = failure.is_a?(Hash) ? failure : {}
  indices = Array(record[:placement_indices])
  {
    :source_span_id => record[:source_span_id].to_s,
    :reason => record[:reason],
    :expected_glyph_count => record[:expected_glyph_count],
    :observed_glyph_count => record[:observed_glyph_count],
    :placement_index_count => indices.length,
    :first_placement_index => indices.empty? ? nil : indices.first,
    :last_placement_index => indices.empty? ? nil : indices.last
  }
end

def transition_proof_summary(proof)
  record = proof.is_a?(Hash) ? proof : {}
  evidence = record[:evidence].is_a?(Hash) ? record[:evidence] : {}
  coverage = Array(evidence[:glyph_coverage_failures]).map do |failure|
    compact_coverage_failure(failure)
  end
  ambiguous = Array(evidence[:peer_ambiguous_placement_indices])
  {
    :source_span_id => record[:source_span_id],
    :importer_id => record[:importer_id],
    :page_number => record[:page_number],
    :scope => record[:scope],
    :category => record[:category],
    :affirmative_impossibility => record[:affirmative_impossibility],
    :generic_failure => record[:generic_failure],
    :from_mode => record[:from_mode],
    :to_mode => record[:to_mode],
    :reason_code => record[:reason_code],
    :attempted_renderer => record[:attempted_renderer],
    :cleanup_outcome => record[:cleanup_outcome],
    :evidence_summary => {
      :source_observation => evidence[:source_observation],
      :source_renderer => evidence[:source_renderer],
      :font_inventory_status => evidence[:font_inventory_status],
      :source_placement_count => evidence[:source_placement_count],
      :matched_item_placement_count => evidence[:matched_item_placement_count],
      :bbox_geometry_candidate_count =>
        evidence[:bbox_geometry_candidate_count],
      :peer_ambiguous_placement_count => ambiguous.length,
      :representation_contract_checked =>
        evidence[:representation_contract_checked],
      :glyph_coverage_failure_count => coverage.length,
      :glyph_coverage_failures => coverage,
      :verification => evidence[:verification]
    }
  }
end

def item_representation_source_probe(mod, pdf_path, svg_page, item, all_items,
                                     media_box, svg_box, source_context)
  source_id = mod::RepresentationFidelity.source_span_id(item)
  controller = mod::RepresentationFidelity::FallbackController.new(
    :text3d, source_id
  )
  attempts = []
  hard_stop = nil
  live_host_mode = nil
  entities = WeldingSourceProbeEntities.new

  text3d = mod::Svg3DTextRenderer.render_svg(
    entities, svg_page[:svg], media_box, [item],
    :svg_page_box => svg_box,
    :preserve_unmatched_source_placements => false,
    :source_context => source_context
  )
  text3d_failures = Array(text3d[:failures])
  text3d_proofs = Array(text3d[:transition_proofs])
  if text3d_failures.empty? && text3d_proofs.length == 1
    proof = text3d_proofs.first
    controller.advance!(proof)
    attempts << {
      :mode => :text3d, :outcome => :affirmative_impossibility,
      :transition => [proof[:from_mode], proof[:to_mode]],
      :reason_code => proof[:reason_code]
    }
  elsif text3d_failures.length == 1 &&
        live_host_creation_boundary?(text3d_failures.first)
    live_host_mode = :text3d
    attempts << {
      :mode => :text3d, :outcome => :source_candidate_requires_live_host,
      :failure => text3d_failures.first
    }
  else
    hard_stop = {
      :mode => :text3d, :reason => :production_renderer_did_not_prove_transition,
      :failures => text3d_failures,
      :transition_proof_count => text3d_proofs.length
    }
  end

  while hard_stop.nil? && live_host_mode.nil? && !controller.terminal?
    mode = controller.current_mode
    begin
      peers = Array(all_items).reject do |peer|
        mod::RepresentationFidelity.source_span_id(peer) == source_id
      end
      result = mod::SvgItemRepresentationRenderer.render_svg(
        entities, svg_page[:svg], media_box, item, mode,
        :svg_page_box => svg_box,
        :peer_items => peers,
        :source_context => source_context
      )
      proof = result.is_a?(Hash) ? result[:transition_proof] : nil
      if result.is_a?(Hash) && result[:ok] == false &&
         Array(result[:failures]).empty? && proof.is_a?(Hash)
        controller.advance!(proof)
        attempts << {
          :mode => mode, :outcome => :affirmative_impossibility,
          :transition => [proof[:from_mode], proof[:to_mode]],
          :reason_code => proof[:reason_code]
        }
      else
        hard_stop = {
          :mode => mode,
          :reason => :production_renderer_did_not_prove_transition,
          :renderer_result => result
        }
      end
    rescue mod::RepresentationFidelity::ContractError => e
      if live_host_creation_boundary?(e)
        live_host_mode = mode
        attempts << {
          :mode => mode, :outcome => :source_candidate_requires_live_host,
          :detail => e.message.to_s
        }
      else
        hard_stop = {
          :mode => mode, :reason => :production_renderer_contract_stop,
          :detail => e.message.to_s
        }
      end
    end
  end

  raster_artifact = if hard_stop.nil? && controller.terminal?
                      item_raster_source_probe(
                        mod, pdf_path, 1, item, media_box, 0, 400
                      )
                    else
                      nil
                    end
  accepted = attempts.count do |attempt|
    attempt[:outcome] == :affirmative_impossibility
  end
  recorded_proofs_verified = accepted == controller.transitions.length
  terminal_source_verified = controller.terminal? &&
    raster_artifact.is_a?(Hash) && raster_artifact[:ok] == true
  status = if hard_stop
             :hard_stop
           elsif live_host_mode
             :live_host_vector_delivery_required
           elsif terminal_source_verified
             :terminal_raster_source_verified_pending_live_host
           else
             :terminal_raster_source_verification_failed
           end
  coverage = Array(text3d[:match] && text3d[:match][:coverage_failures]).find do |failure|
    failure[:source_span_id].to_s == source_id
  end

  {
    :source_span_id => source_id,
    :source_text => item.respond_to?(:text) ? item.text.to_s : '',
    :expected_glyph_count => coverage && coverage[:expected_glyph_count],
    :observed_glyph_count => coverage && coverage[:observed_glyph_count],
    :source_probe_status => status,
    :current_mode => controller.current_mode,
    :ladder_reached_terminal_raster => controller.terminal?,
    :recorded_transition_proofs_verified => recorded_proofs_verified,
    :adjacent_transition_proofs_verified =>
      recorded_proofs_verified && controller.terminal?,
    :transition_probe_results => controller.transitions.map do |proof|
      transition_proof_summary(proof)
    end,
    :attempt_history => attempts,
    :hard_stop => hard_stop,
    :live_host_delivery_required => hard_stop.nil?,
    :live_host_representation_mode =>
      live_host_mode || (controller.terminal? ? :raster : nil),
    :item_raster_artifact => raster_artifact,
    :live_host_delivery_verified => false
  }
rescue StandardError => e
  {
    :source_span_id => source_id,
    :source_probe_status => :hard_stop,
    :hard_stop => { :reason => e.class.name, :detail => e.message.to_s },
    :live_host_delivery_required => false,
    :live_host_delivery_verified => false
  }
end

paths = ARGV.empty? ? [
  'C:/Users/Rowdy Payton/Desktop/PDFTest Files/Welding-Symbol-Chart.pdf',
  'C:/Users/Rowdy Payton/Desktop/PDFTest Files/AWSWeldSymbolchart.pdf'
] : ARGV

reports = paths.map do |pdf_path|
  begin
  unless File.file?(pdf_path)
    next({ :pdf => pdf_path, :ok => false, :reason => 'file_missing' })
  end

  parser = mod::PDFParser.new(pdf_path)
  parser.parse
  raw = parser.page_data(1)
  media_box = raw[:media_box] || [0, 0, 612, 792]
  crop_box = raw[:crop_box]
  crop_box = nil unless crop_box.is_a?(Array) && crop_box.length >= 4
  streams = raw[:content_streams] || []
  font_maps = parser.page_font_maps(1)
  ocg_map = begin
    parser.page_ocg_map(1) || {}
  rescue StandardError
    {}
  end
  internal = mod::TextParser.new(
    streams, font_maps,
    { :strict_text_fidelity => true, :merge_text_runs => false }, ocg_map
  ).parse || []
  external = mod::ExternalTextExtractor.extract(pdf_path, 1) || []
  items = external.empty? ? internal : external
  mod::TextSourceIdentity.assign!(items, 1)

  paths_on_page = mod::ContentStreamParser.new(
    streams, parser, ocg_map
  ).parse
  failure = {}
  use_cropbox = crop_box && crop_box.zip(media_box).any? do |a, b|
    (a.to_f - b.to_f).abs > 0.01
  end
  svg_page = mod::CairoGlyphSource.render_page_svg(
    pdf_path, 1,
    :failure_info => failure,
    :use_cropbox => use_cropbox == true
  )
  unless svg_page
    parser.release
    next({
      :pdf => File.basename(pdf_path), :ok => false,
      :reason => failure[:reason].to_s,
      :semantic_text_items => items.length,
      :page_paths => paths_on_page.length
    })
  end

  svg_box = crop_box || media_box
  placed = mod::CairoGlyphSource.model_space_loops(
    svg_page[:svg], media_box, :svg_page_box => svg_box
  )
  pens = placed.map do |entry|
    {
      :x => entry[:pen_pdf][0], :y => entry[:pen_pdf][1],
      :placement_index => entry[:placement_index]
    }
  end
  match = mod::CairoGlyphSource.match_spans(pens, items, media_box)
  invalid_contours = placed.inject(0) do |sum, entry|
    sum + Array(entry[:loops]).count do |loop|
      loop.length < 3 || mod::Svg3DTextRenderer.normalized_contour(loop).nil?
    end
  end
  rotated = placed.count do |entry|
    matrix = Array(entry[:svg_matrix])
    matrix.length >= 4 &&
      ((matrix[1].to_f.abs > 1.0e-9) || (matrix[2].to_f.abs > 1.0e-9))
  end
  no_semantic_text = items.empty?
  svg_source_uses = svg_page[:svg].scan(
    /<use\b[^>]*(?:xlink:href|href)=["']#source-[^"']+["']/
  ).length
  svg_images = svg_page[:svg].scan(/<image\b/).length
  svg_visible_nontext = svg_source_uses > 0 || svg_images > 0
  raster_probe = if no_semantic_text && svg_visible_nontext
                   raster_source_probe(mod, pdf_path, 1, use_cropbox == true)
                 else
                   nil
                 end
  unmatched_indices = Array(match[:unmatched_placements]).map do |record|
    record.is_a?(Hash) && record.key?(:placement_index) ?
      record[:placement_index].to_i : nil
  end.compact.uniq.sort
  placed_indices = placed.map { |entry| entry[:placement_index].to_i }.uniq.sort
  unjoined_source_ready = unmatched_indices.all? do |index|
    placed_indices.include?(index)
  end
  source_ready = !placed.empty? && match[:runs_unmatched].to_i == 0 &&
    invalid_contours == 0 && unjoined_source_ready
  source_context = mod.svg_source_context(svg_page, 1, failure)
  transition_items = Array(match[:unmatched_source_runs])
  transition_probes = transition_items.map do |item|
    item_representation_source_probe(
      mod, pdf_path, svg_page, item, items, media_box, svg_box,
      source_context
    )
  end
  mixed_source_pipeline_ready = !transition_probes.empty? &&
    transition_probes.all? do |probe|
      probe[:adjacent_transition_proofs_verified] == true &&
        probe[:ladder_reached_terminal_raster] == true &&
        probe[:item_raster_artifact].is_a?(Hash) &&
        probe[:item_raster_artifact][:ok] == true
    end && invalid_contours == 0 && unjoined_source_ready
  mixed_source_pipeline_accounted = !transition_probes.empty? &&
    transition_probes.all? do |probe|
      [
        :live_host_vector_delivery_required,
        :terminal_raster_source_verified_pending_live_host
      ].include?(probe[:source_probe_status])
    end && invalid_contours == 0 && unjoined_source_ready
  unmatched_details = Array(match[:unmatched_placements]).first(10).map do |pen|
    record = pen.is_a?(Hash) ? pen : {}
    sample = record[:placement].is_a?(Hash) ? record[:placement] : record
    has_point = sample.key?(:x) && sample.key?(:y)
    nearest = if has_point
      items.map do |item|
        box = mod::CairoGlyphSource.item_bbox_media_relative(
          item, media_box[0].to_f, media_box[1].to_f
        )
        next unless box
        x0, x1 = [box[0].to_f, box[2].to_f].minmax
        y0, y1 = [box[1].to_f, box[3].to_f].minmax
        dx = if sample[:x].to_f < x0
               x0 - sample[:x].to_f
             elsif sample[:x].to_f > x1
               sample[:x].to_f - x1
             else
               0.0
             end
        dy = if sample[:y].to_f < y0
               y0 - sample[:y].to_f
             elsif sample[:y].to_f > y1
               sample[:y].to_f - y1
             else
               0.0
             end
        [Math.sqrt((dx * dx) + (dy * dy)), item, box]
      end.compact.min_by { |row| row[0] }
    end
    placement_evidence = if record.key?(:placement_indices)
                           compact_coverage_failure(record)
                         else
                           {
                             :x => sample[:x], :y => sample[:y],
                             :placement_index => sample[:placement_index]
                           }
                         end
    {
      :placement_evidence => placement_evidence,
      :nearest_distance => nearest ? nearest[0] : nil,
      :nearest_text => nearest ? nearest[1].text.to_s : nil,
      :nearest_source_span_id => nearest ? nearest[1].source_span_id.to_s : nil,
      :nearest_bbox => nearest ? nearest[2] : nil
    }
  end
  page_raster_source_candidate = no_semantic_text && svg_visible_nontext &&
    raster_probe && raster_probe[:ok]
  source_diagnostic_complete = source_ready ||
    mixed_source_pipeline_accounted || page_raster_source_candidate
  finite_delivery_contract = if source_ready
    {
      :requested_mode => :text3d,
      :delivered_mode => nil,
      :source_candidate_mode => :text3d,
      :semantic_source_span_count => match[:runs_matched].to_i,
      :unjoined_source_glyph_placement_count => unmatched_indices.length,
      :fallback_transitions => [],
      :terminal => false,
      :source_candidate => true,
      :positive_z_depth_required => true,
      :live_host_solid_verification_required => true
    }
  elsif mixed_source_pipeline_accounted
    {
      :requested_mode => :text3d,
      :delivered_mode => nil,
      :source_candidate_mode => mixed_source_pipeline_ready ?
        :mixed_text3d_and_item_raster : :mixed_item_vector_pending_live_host,
      :source_outline_3d_candidate_count => match[:runs_matched].to_i,
      :item_source_candidate_count => transition_probes.length,
      :item_raster_source_candidate_count => transition_probes.count do |probe|
        probe[:ladder_reached_terminal_raster] == true
      end,
      :item_vector_live_host_candidate_count => transition_probes.count do |probe|
        probe[:source_probe_status] == :live_host_vector_delivery_required
      end,
      :unjoined_source_glyph_placement_count => unmatched_indices.length,
      :fallback_ladder => [:text3d, :glyphs, :geometry, :raster],
      :adjacent_transition_proofs_verified => transition_probes.all? do |probe|
        probe[:adjacent_transition_proofs_verified] == true
      end,
      :item_raster_source_artifacts_verified => transition_probes.all? do |probe|
        probe[:item_raster_artifact].is_a?(Hash) &&
          probe[:item_raster_artifact][:ok] == true
      end,
      :terminal => false,
      :source_candidate => true,
      :live_host_entity_verification_required => true
    }
  elsif page_raster_source_candidate
    {
      :requested_mode => :text3d,
      :delivered_mode => nil,
      :source_candidate_mode => :raster,
      :scope => :page,
      :reason_code => :visible_nontext_source_only,
      :semantic_source_span_count => 0,
      :item_fallback_transitions => [],
      :terminal => false,
      :source_candidate => true,
      :raster_source_render_verified => true,
      :live_host_image_verification_required => true
    }
  else
    {
      :requested_mode => :text3d,
      :delivered_mode => nil,
      :source_candidate_mode => nil,
      :terminal => false,
      :source_candidate => false
    }
  end
  report_records = {
    :page_representation_fallbacks => [],
    :terminal_text_delivery_records => [],
    :source_glyph_physical_deliveries => [],
    :pending_live_host_source_candidates => []
  }
  if source_ready
    report_records[:pending_live_host_source_candidates] << {
      :page => 1,
      :scope => :page_source_inventory,
      :requested_mode => :text3d,
      :source_candidate_mode => :text3d,
      :semantic_source_span_count => match[:runs_matched].to_i,
      :unjoined_source_placement_indices => unmatched_indices,
      :positive_z_depth_required => true,
      :live_host_delivery_required => true
    }
  elsif mixed_source_pipeline_accounted
    transition_probes.each do |probe|
      report_records[:pending_live_host_source_candidates] << {
        :page => 1,
        :scope => :item,
        :source_span_id => probe[:source_span_id],
        :requested_mode => :text3d,
        :source_candidate_mode => probe[:live_host_representation_mode],
        :source_probe_status => probe[:source_probe_status],
        :validated_transitions => Array(probe[:transition_probe_results]).map do |proof|
          [proof[:from_mode], proof[:to_mode]]
        end,
        :raster_source_artifact_verified =>
          probe[:item_raster_artifact].is_a?(Hash) &&
          probe[:item_raster_artifact][:ok] == true,
        :live_host_delivery_required => true
      }
    end
  elsif page_raster_source_candidate
    report_records[:pending_live_host_source_candidates] << {
      :page => 1,
      :scope => :page,
      :requested_mode => :text3d,
      :source_candidate_mode => :raster,
      :reason_code => :visible_nontext_source_only,
      :raster_source_render_verified => true,
      :live_host_delivery_required => true
    }
  end
  report = {
    :pdf => File.basename(pdf_path),
    :ok => source_diagnostic_complete,
    :source_diagnostic_complete => source_diagnostic_complete,
    :renderer => svg_page[:renderer].to_s,
    :renderer_missing_fonts => Array(svg_page[:missing_fonts]),
    :renderer_missing_language_packs =>
      Array(svg_page[:missing_language_packs]),
    :source_page_inventory_clear =>
      Array(svg_page[:missing_fonts]).empty? &&
      Array(svg_page[:missing_language_packs]).empty?,
    :semantic_text_items => items.length,
    :internal_text_items => internal.length,
    :external_text_items => external.length,
    :source_glyph_placements => placed.length,
    :source_runs_matched => match[:runs_matched].to_i,
    :source_runs_unmatched => match[:runs_unmatched].to_i,
    :placements_unmatched => match[:placements_unmatched].to_i,
    :unjoined_source_placements_available_for_3d_source_attempt =>
      unmatched_indices.length,
    :unjoined_source_identity_verified => unjoined_source_ready,
    :unmatched_placement_evidence => unmatched_details,
    :invalid_closed_contours => invalid_contours,
    :rotated_source_placements => rotated,
    :page_paths => paths_on_page.length,
    :svg_source_uses => svg_source_uses,
    :svg_images => svg_images,
    :no_semantic_text => no_semantic_text,
    :source_outline_3d_source_candidate_ready => source_ready,
    :mixed_source_pipeline_ready => mixed_source_pipeline_ready,
    :mixed_source_pipeline_accounted => mixed_source_pipeline_accounted,
    :fallback_item_source_probes => transition_probes,
    :raster_source_probe => raster_probe,
    :finite_delivery_contract => finite_delivery_contract,
    :report_records => report_records,
    :positive_depth_inches => mod::Svg3DTextRenderer::DEFAULT_DEPTH_INCHES,
    :positive_depth_contract => mod::Svg3DTextRenderer::DEFAULT_DEPTH_INCHES > 0.0,
    :no_substitute_font_used => true,
    :live_host_delivery_required => source_diagnostic_complete,
    :live_host_delivery_verified => false
  }
  parser.release
  report
rescue StandardError => e
  begin
    parser.release if parser
  rescue StandardError
  end
  {
    :pdf => File.basename(pdf_path.to_s), :ok => false,
    :reason => e.class.name, :detail => e.message
  }
  end
end

puts JSON.pretty_generate(reports)
exit(reports.all? { |report| report[:ok] } ? 0 : 1)
