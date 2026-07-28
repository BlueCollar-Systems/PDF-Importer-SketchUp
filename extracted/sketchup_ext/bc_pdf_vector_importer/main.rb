# bc_pdf_vector_importer/main.rb
# Pipeline: PDF > Primitives > Cleanup > Profile > Generic Recognition
#           > Optional Domain Pack > Validation > Host Build > Report
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'zlib'
require 'digest'
require 'tmpdir'
require 'fileutils'

module BlueCollarSystems
  module PDFVectorImporter

    dir = File.dirname(__FILE__)
    # Core Engine
    require File.join(dir, 'import_config')
    require File.join(dir, 'import_bounds')
    require File.join(dir, 'page_transform')
    require File.join(dir, 'primitives')
    require File.join(dir, 'logger')
    require File.join(dir, 'command_runner')
    require File.join(dir, 'png_cropper')
    require File.join(dir, 'dependency_resolver')
    require File.join(dir, 'batch_host_policy')
    require File.join(dir, 'pdf_open_gate')
    require File.join(dir, 'pdf_salvage')
    require File.join(dir, 'pdf_parser')
    require File.join(dir, 'content_stream_parser')
    require File.join(dir, 'text_parser')
    require File.join(dir, 'text_source_identity')
    require File.join(dir, 'external_text_extractor')
    require File.join(dir, 'bezier')
    require File.join(dir, 'arc_fitter')
    require File.join(dir, 'ocg_parser')
    require File.join(dir, 'layer_manager')
    require File.join(dir, 'xobject_parser')
    require File.join(dir, 'embedded_image_extractor')
    require File.join(dir, 'source_provenance')
    require File.join(dir, 'batch_pipeline')
    require File.join(dir, 'primitive_extractor')
    require File.join(dir, 'unit_parser')
    require File.join(dir, 'dimension_parser')
    require File.join(dir, 'resolved_scale')
    require File.join(dir, 'generic_classifier')
    require File.join(dir, 'document_profiler')
    require File.join(dir, 'region_segmenter')
    require File.join(dir, 'generic_recognizer')
    # Pipeline
    require File.join(dir, 'recognizer')
    require File.join(dir, 'validator')
    # Host Builders
    require File.join(dir, 'embedded_image_extractor')
    require File.join(dir, 'extrude_3d')
    require File.join(dir, 'geometry_builder')
    require File.join(dir, 'model_3d_extruder')
    require File.join(dir, 'geometry_cleanup')
    require File.join(dir, 'hatch_detector')
    require File.join(dir, 'poppler_result_validator')
    require File.join(dir, 'poppler_semantic_proof')
    require File.join(dir, 'svg_text_renderer')
    require File.join(dir, 'cairo_glyph_source')
    require File.join(dir, 'svg_3d_text_renderer')
    require File.join(dir, 'svg_item_representation_renderer')
    require File.join(dir, 'metadata')
    # Tools & UI
    require File.join(dir, 'scale_tool')
    require File.join(dir, 'import_dialog')
    require File.join(dir, 'report_dialog')
    require File.join(dir, 'compatibility_report')
    require File.join(dir, 'version_notice')
    require File.join(dir, 'qa_report')
    require File.join(dir, 'import_health')

    # ================================================================
    # SHARED PIPELINE — single source of truth for all import paths
    # ================================================================
    @last_import_layer_names = []
    DEFAULT_AUTO_RECOGNITION_PRIMITIVE_LIMIT = 20_000
    DEFAULT_AUTO_RECOGNITION_PATH_LIMIT = 12_000
    DEFAULT_AUTO_RECOGNITION_STREAM_MB_LIMIT = 24.0
    # Closed-shape page extrusion is intentionally disabled. It is independent
    # from source-glyph 3D text, whose positive depth is always allowed.
    SHAPE_EXTRUSION_ENABLED = false

    def self.env_numeric(name, fallback)
      raw = ENV[name.to_s]
      return fallback if raw.nil? || raw.to_s.strip.empty?
      value = raw.to_f
      value > 0.0 ? value : fallback
    rescue StandardError
      fallback
    end

    def self.heavy_auto_recognition_skip?(page_data, paths, stream_bytes)
      return false if ENV['BC_SU_FORCE_AUTO_RECOGNITION'].to_s.strip.downcase =~ /\A(?:1|true|yes)\z/

      primitive_limit = env_numeric(
        'BC_SU_AUTO_RECOGNITION_MAX_PRIMITIVES',
        DEFAULT_AUTO_RECOGNITION_PRIMITIVE_LIMIT
      ).to_i
      path_limit = env_numeric(
        'BC_SU_AUTO_RECOGNITION_MAX_PATHS',
        DEFAULT_AUTO_RECOGNITION_PATH_LIMIT
      ).to_i
      stream_mb_limit = env_numeric(
        'BC_SU_AUTO_RECOGNITION_MAX_STREAM_MB',
        DEFAULT_AUTO_RECOGNITION_STREAM_MB_LIMIT
      )

      primitive_count = page_data && page_data.primitives ? page_data.primitives.length : 0
      path_count = Array(paths).length
      stream_mb = stream_bytes.to_f / 1_000_000.0
      primitive_count > primitive_limit ||
        path_count > path_limit ||
        stream_mb > stream_mb_limit
    rescue StandardError
      false
    end

    def self.register_import_layer_names(names)
      @last_import_layer_names = Array(names).map(&:to_s)
    end

    def self.last_import_layer_names
      @last_import_layer_names || []
    end

    def self.safe_abort_operation(model, source)
      return unless model
      model.abort_operation
    rescue StandardError => e
      Logger.warn(source, "abort_operation failed: #{e.message}")
    end

    def self.safe_find_pdftocairo
      SvgTextRenderer.find_pdftocairo
    rescue StandardError => e
      Logger.warn("Raster", "pdftocairo lookup failed: #{e.message}")
      nil
    end

    # A missing SVG helper may block only a page that actually needs it. The
    # old import-wide preflight stopped Geometry/Glyphs/3D Text even when every
    # selected page had no text and already had ordinary vector/image content.
    # That was a false roadblock: there is no requested text artifact to render
    # on such a page. Empty pages still require SVG source inspection so hidden
    # renderer-visible content is never silently omitted.
    def self.svg_renderer_required_for_page?(requested_mode, import_text,
                                             text_items,
                                             source_inspection_required = false)
      return false unless import_text == true
      mode = normalize_text_renderer_mode(requested_mode)
      return false unless [:geometry, :glyphs, :text3d].include?(mode)

      !Array(text_items).empty? || source_inspection_required == true
    end

    def self.enforce_svg_renderer_available!(model, stats, requested_text_mode)
      return true if SvgTextRenderer.svg_renderer_available?

      stats[:svg_renderer_missing] = true if stats.is_a?(Hash)
      requested_label = case normalize_text_renderer_mode(requested_text_mode)
                        when :glyphs then 'Glyphs'
                        when :text3d then '3D Text'
                        else 'Geometry'
                        end
      Logger.warn(
        'Pipeline',
        "#{requested_label} text was requested, but a free Poppler/MuPDF SVG " \
        'renderer is unavailable. The requested representation will not be substituted.'
      )
      if BatchHostPolicy.prompt_allowed? &&
         defined?(UI) && UI.respond_to?(:messagebox)
        UI.messagebox(
          "#{requested_label} text requires a free Poppler/MuPDF SVG " \
          "renderer, which is unavailable.\n\nThe import is stopping without " \
          "changing the requested representation. Install Poppler or MuPDF " \
          "and expose it on PATH, or configure BC_PDFTOCAIRO_PATH / " \
          "BC_MUTOOL_PATH. Then open Extensions > PDF Vector Importer > " \
          'Compatibility Report to verify detection.'
        )
      end
      safe_abort_operation(model, 'Pipeline')
      raise RepresentationFidelity::ContractError,
            "requested #{requested_label} renderer is unavailable; no " \
            'representation fallback is authorized'
    end

    def self.record_text_renderer(stats, page_num, attrs)
      stats[:text_renderers] ||= []
      stats[:page_text_sources] ||= {}
      entry = { page: page_num }
      attrs.each { |k, v| entry[k] = v } if attrs.respond_to?(:each)
      if stats[:page_text_sources][page_num] && !entry.key?(:text_source)
        entry[:text_source] = stats[:page_text_sources][page_num]
      end
      stats[:text_renderers] << entry
    end

    def self.merge_text_attempts!(stats, attempts)
      stats[:text_attempts] ||= []
      Array(attempts).each do |attempt|
        raise RepresentationFidelity::ContractError,
              'text attempt is not a Hash' unless attempt.is_a?(Hash)
        stats[:text_attempts] << attempt
      end
      true
    end

    def self.record_fallback_transitions!(stats, page_num, transitions)
      stats[:fallback_transitions] ||= []
      Array(transitions).each do |transition|
        raise RepresentationFidelity::ContractError,
              'fallback transition is not a Hash' unless transition.is_a?(Hash)
        entry = transition.dup
        entry[:page] = page_num.to_i
        stats[:fallback_transitions] << entry
        Logger.warn(
          'RepresentationFidelity',
          "Page #{page_num} #{entry[:source_span_id]}: " \
          "#{entry[:from_mode]} -> #{entry[:to_mode]} " \
          "(#{entry[:reason_code]}; affirmative item proof)"
        )
      end
      true
    end

    def self.svg_source_context(svg_document, page_num, failure_info = {})
      document = svg_document.is_a?(Hash) ? svg_document : {}
      failures = []
      reason = failure_info.is_a?(Hash) ? failure_info[:reason].to_s.strip : ''
      unless reason.empty?
        failures << {
          :scope => :page, :page_number => page_num.to_i,
          :reason_code => :renderer_runtime_error, :detail => reason
        }
      end
      missing_fonts = Array(document[:missing_fonts]).map { |value| value.to_s }
      missing_languages = Array(document[:missing_language_packs]).map do |value|
        value.to_s
      end
      unless missing_fonts.empty? && missing_languages.empty?
        failures << {
          :scope => :page, :page_number => page_num.to_i,
          :reason_code => :font_inventory_runtime_error,
          :missing_fonts => missing_fonts,
          :missing_language_packs => missing_languages
        }
      end
      {
        :importer_id => RepresentationFidelity::IMPORTER_ID,
        :page_number => page_num.to_i,
        :renderer => document[:renderer],
        :render_status => document[:svg].to_s.empty? ? :failed : :complete,
        :font_inventory_status => failures.empty? ? :complete : :failed,
        :page_failures => failures
      }
    end

    def self.failed_item_rung_from_transition(proof)
      raise RepresentationFidelity::ContractError,
            'item fallback transition proof is missing' unless proof.is_a?(Hash)
      {
        :mode => RepresentationFidelity.normalize_mode(proof[:from_mode]),
        :outcome => :failed,
        :reason => proof[:reason_code].to_s,
        :created_entity_ids => Array(proof[:created_entity_ids]),
        :cleaned_entity_ids => Array(proof[:cleaned_entity_ids]),
        :resulting_entity_ids => [],
        :cleanup_outcome => proof[:cleanup_outcome],
        :visual_fidelity_verified => false,
        :transition_proof => proof
      }
    end

    def self.append_failed_item_rung!(history, proof)
      rung = failed_item_rung_from_transition(proof)
      mode = rung[:mode]
      raise RepresentationFidelity::ContractError,
            'item fallback transition mode is invalid' unless mode
      existing = Array(history).find do |entry|
        RepresentationFidelity.normalize_mode(entry[:mode]) == mode
      end
      if existing
        unless existing[:outcome].to_s == 'failed'
          raise RepresentationFidelity::ContractError,
                "#{mode} item rung was already completed"
        end
        existing[:transition_proof] ||= proof
        existing[:reason] = rung[:reason] if existing[:reason].to_s.empty?
        existing[:created_entity_ids] ||= rung[:created_entity_ids]
        existing[:cleaned_entity_ids] ||= rung[:cleaned_entity_ids]
        existing[:resulting_entity_ids] = []
        existing[:cleanup_outcome] ||= rung[:cleanup_outcome]
        existing[:visual_fidelity_verified] = false
        return existing
      end
      history << rung
      rung
    end

    def self.prepare_flat_text_fallback_controllers!(text_items)
      prepared = {}
      Array(text_items).each do |item|
        source_id = RepresentationFidelity.source_span_id(item)
        if prepared.key?(source_id)
          raise RepresentationFidelity::ContractError,
                "duplicate flat Text source item #{source_id}"
        end
        proof = RepresentationFidelity.
          flat_editable_text_impossibility_proof(item)
        controller = RepresentationFidelity::FallbackController.new(
          :text, source_id
        )
        controller.advance!(proof)
        prepared[source_id] = {
          :item => item, :proof => proof, :controller => controller
        }
      end
      prepared
    end

    def self.bind_flat_text_capability_attempt!(attempt, proof)
      unless attempt.is_a?(Hash) && proof.is_a?(Hash)
        raise RepresentationFidelity::ContractError,
              'flat Text attempt/proof binding is unavailable'
      end
      source_id = RepresentationFidelity.source_span_id(
        attempt[:source_span_id]
      )
      controller = RepresentationFidelity::FallbackController.new(
        :text, source_id
      )
      controller.advance!(proof)
      evidence = proof[:evidence]
      unless RepresentationFidelity.normalize_mode(attempt[:requested_mode]) == :text &&
             attempt[:source_text_sha256].to_s.downcase ==
               evidence[:source_text_sha256].to_s.downcase &&
             RepresentationFidelity.canonical_json(attempt[:source_bbox_pdf]) ==
               RepresentationFidelity.canonical_json(
                 evidence[:source_bbox_pdf]
               )
        raise RepresentationFidelity::ContractError,
              "#{source_id}: flat Text proof conflicts with source attempt"
      end
      history = attempt[:attempt_history]
      unless history.is_a?(Array)
        raise RepresentationFidelity::ContractError,
              "#{source_id}: flat Text attempt history is unavailable"
      end
      if history.any? do |entry|
           RepresentationFidelity.normalize_mode(entry[:mode]) == :text
         end
        raise RepresentationFidelity::ContractError,
              "#{source_id}: flat Text capability rung is duplicated"
      end
      history.unshift(failed_item_rung_from_transition(proof))
      true
    end

    def self.bind_flat_text_capability_rows!(attempts, failures, prepared)
      by_id = {}
      Array(attempts).each do |attempt|
        source_id = RepresentationFidelity.source_span_id(
          attempt[:source_span_id]
        )
        row = prepared[source_id]
        raise RepresentationFidelity::ContractError,
              "#{source_id}: flat Text capability proof is missing" unless row
        bind_flat_text_capability_attempt!(attempt, row[:proof])
        by_id[source_id] = attempt
      end
      unless by_id.keys.sort == prepared.keys.sort
        raise RepresentationFidelity::ContractError,
              'flat Text capability attempt set does not equal source set'
      end
      Array(failures).each do |failure|
        source_id = RepresentationFidelity.source_span_id(
          failure[:source_span_id]
        )
        attempt = by_id[source_id]
        raise RepresentationFidelity::ContractError,
              "#{source_id}: flat Text failure has no attempt" unless attempt
        failure[:requested] = :text
        failure[:attempt_history] = attempt[:attempt_history]
      end
      true
    end

    def self.record_item_vector_delivery!(stats, page_num, item,
                                          requested_mode, result, history,
                                          transitions)
      source_id = RepresentationFidelity.source_span_id(item)
      delivered_mode = RepresentationFidelity.normalize_mode(result[:mode])
      unless [:glyphs, :geometry].include?(delivered_mode) &&
             result[:source_span_id].to_s == source_id &&
             result[:visual_fidelity_verified] == true &&
             result[:identity_verified] == true &&
             result[:placement_verified] == true &&
             result[:rotation_verified] == true &&
             result[:size_verified] == true &&
             result[:entity_type_verified] == true &&
             result[:visibility_verified] == true &&
             result[:content_verified] == true &&
             result[:physical_geometry_verified] == true &&
             result[:physical_style_verified] == true &&
             result[:transform_verified] == true &&
             result[:expected_evidence].is_a?(Hash)
        raise RepresentationFidelity::ContractError,
              "#{source_id}: item vector delivery evidence is incomplete"
      end
      entity_id = result[:group_entity_id].to_s
      unless RepresentationFidelity.positive_entity_ids([entity_id])
        raise RepresentationFidelity::ContractError,
              "#{source_id}: item vector group identity is invalid"
      end
      completed = {
        :mode => delivered_mode,
        :outcome => :complete,
        :resulting_entity_ids => [entity_id],
        :cleanup_outcome => :not_required,
        :visual_fidelity_verified => true,
        :identity_verified => true,
        :placement_verified => true,
        :rotation_verified => true,
        :width_verified => true,
        :height_verified => true,
        :entity_type_verified => true,
        :visibility_verified => true,
        :content_verified => true,
        :physical_geometry_verified => true,
        :physical_style_verified => true,
        :transform_verified => true,
        :expected_evidence => result[:expected_evidence],
        :physical_entity_ids => Array(result[:physical_entity_ids])
      }
      history << completed
      requested = RepresentationFidelity.normalize_mode(requested_mode)
      attempt = {
        :source_span_id => source_id,
        :requested_mode => requested,
        :delivered_mode => delivered_mode,
        :resulting_entity_ids => [entity_id],
        :visual_fidelity_verified => true,
        :identity_verified => true,
        :placement_verified => true,
        :rotation_verified => true,
        :width_verified => true,
        :height_verified => true,
        :entity_type_verified => true,
        :visibility_verified => true,
        :content_verified => true,
        :physical_geometry_verified => true,
        :physical_style_verified => true,
        :transform_verified => true,
        :source_text_sha256 => result[:expected_evidence][:source_text_sha256],
        :source_anchor => result[:expected_evidence][:source_anchor],
        :source_rotation_radians =>
          result[:expected_evidence][:source_rotation_radians],
        :expected_width => result[:expected_evidence][:expected_width],
        :expected_height => result[:expected_evidence][:expected_height],
        :expected_depth => result[:expected_evidence][:expected_depth],
        :source_style_sha256 =>
          result[:expected_evidence][:physical_style_sha256],
        :source_geometry_sha256 =>
          result[:expected_evidence][:physical_geometry_sha256],
        :expected_transform =>
          result[:expected_evidence][:expected_transformation],
        :expected_evidence => result[:expected_evidence],
        :attempt_history => history
      }
      created_type = delivered_mode == :glyphs ? 'glyph_outline' :
        'page_path_geometry'
      renderer = result[:renderer].to_s
      stats[:text_attempts] ||= []
      stats[:text_attempts] << attempt
      stats[:source_provenance_objects] ||= []
      stats[:source_provenance_objects] << {
        :object_id => source_id,
        :span_id => source_id,
        :page => page_num.to_i,
        :source_kind => 'text_span',
        :created_entity_type => created_type,
        :renderer => renderer,
        :resulting_entity_ids => [entity_id],
        :physical_entity_ids => Array(result[:physical_entity_ids]),
        :source_placement_indices => Array(result[:placement_indices]),
        :source_glyph_ids => Array(result[:glyph_ids]),
        :placement_verified => true,
        :rotation_verified => true,
        :width_verified => true,
        :height_verified => true,
        :entity_type_verified => true,
        :visibility_verified => true,
        :content_verified => true,
        :physical_geometry_verified => true,
        :physical_style_verified => true,
        :transform_verified => true,
        :expected_evidence => result[:expected_evidence],
        :visual_fidelity_verified => true
      }
      record_fallback_transitions!(stats, page_num, transitions)
      record_text_renderer(
        stats, page_num,
        :renderer => result[:renderer],
        :mode => delivered_mode,
        :requested_mode => requested,
        :delivered_mode => delivered_mode,
        :degraded => requested != delivered_mode,
        :reason => 'affirmative item-specific requested-representation impossibility',
        :count => 1,
        :resulting_entity_ids => [entity_id],
        :physical_entity_ids => Array(result[:physical_entity_ids]),
        :visual_fidelity_verified => true
      )
      stats[:text] = stats[:text].to_i + 1
      stats[:edges] = stats[:edges].to_i + result[:edge_count].to_i
      true
    end

    def self.record_item_raster_delivery!(stats, page_num, item,
                                          requested_mode, raster, history,
                                          transitions)
      source_id = RepresentationFidelity.source_span_id(item)
      entity_id = raster[:entity_id].to_s
      artifact = raster[:artifact_evidence]
      unless RepresentationFidelity.positive_entity_ids([entity_id]) &&
             raster[:real_raster_verified] == true &&
             raster[:visual_fidelity_verified] == true &&
             artifact.is_a?(Hash) &&
             artifact[:source_span_id].to_s == source_id &&
             artifact[:page_number].to_i == page_num.to_i &&
             artifact[:source_crop_binding_verified] == true &&
             artifact[:page_binding_verified] == true &&
             artifact[:source_pdf_binding_verified] == true &&
             artifact[:source_pdf_sha256].to_s.downcase =~ /\A[0-9a-f]{64}\z/ &&
             artifact[:content_sha256].to_s.downcase =~ /\A[0-9a-f]{64}\z/
        raise RepresentationFidelity::ContractError,
              "#{source_id}: terminal item raster evidence is incomplete"
      end
      completed = {
        :mode => :raster,
        :outcome => :complete,
        :resulting_entity_ids => [entity_id],
        :cleanup_outcome => :not_required,
        :visual_fidelity_verified => true,
        :real_raster_verified => true,
        :source_crop_binding_verified => true,
        :entity_type_verified => true,
        :artifact_evidence => artifact
      }
      history << completed
      requested = RepresentationFidelity.normalize_mode(requested_mode)
      explicit_request = requested == :raster
      attempt = {
        :source_span_id => source_id,
        :requested_mode => requested,
        :delivered_mode => :raster,
        :resulting_entity_ids => [entity_id],
        :visual_fidelity_verified => true,
        :real_raster_verified => true,
        :source_crop_binding_verified => true,
        :entity_type_verified => true,
        :explicit_request => explicit_request,
        :degraded => !explicit_request,
        :artifact_evidence => artifact,
        :attempt_history => history
      }
      record = {
        :page => page_num.to_i,
        :source_span_ids => [source_id],
        :requested_mode => requested,
        :delivered_mode => :raster,
        :created_entity_type => 'raster_image',
        :resulting_entity_ids => [entity_id],
        :real_raster_verified => true,
        :visual_fidelity_verified => true,
        :source_crop_binding_verified => true,
        :explicit_request => explicit_request,
        :degraded => !explicit_request,
        :artifact_evidence => artifact,
        :cleanup_outcome => :not_required,
        :delivery_scope => :item_raster
      }
      stats[:text_attempts] ||= []
      stats[:text_attempts] << attempt
      stats[:terminal_text_delivery_records] ||= []
      stats[:terminal_text_delivery_records] << record
      stats[:raster_delivery_records] ||= []
      stats[:raster_delivery_records] << record.dup
      stats[:raster_fallback_used] = true unless explicit_request
      stats[:text] = stats[:text].to_i + 1
      record_fallback_transitions!(stats, page_num, transitions)
      record_text_renderer(
        stats, page_num,
        :renderer => :pdftocairo_real_item_raster,
        :mode => :raster,
        :requested_mode => requested,
        :delivered_mode => :raster,
        :degraded => !explicit_request,
        :reason => explicit_request ?
          'explicit requested item Raster' :
          'affirmative item-specific vector representation impossibility',
        :count => 1,
        :resulting_entity_ids => [entity_id],
        :real_raster_verified => true,
        :source_crop_binding_verified => true,
        :artifact_evidence => artifact
      )
      true
    end

    def self.complete_item_representation_ladder!(
      stats, model, target_entities, pdf_path, page_num, item,
      requested_mode, controller, history, media_box, render_box,
      page_rotation, opts, import_start, y_offset, svg_document,
      text_layer = nil, peer_items = [],
      precomputed_match = nil, precomputed_peer_boxes = nil
    )
      source_id = RepresentationFidelity.source_span_id(item)
      context = svg_source_context(svg_document, page_num, {})
      while [:glyphs, :geometry].include?(controller.current_mode)
        mode = controller.current_mode
        result = SvgItemRepresentationRenderer.render_svg(
          target_entities, svg_document[:svg], media_box, item, mode,
          :scale => opts[:scale],
          :svg_page_box => render_box,
          :y_offset => 0.0,
          :layer => text_layer,
          :peer_items => peer_items,
          :source_context => context,
          :precomputed_match => precomputed_match,
          :precomputed_peer_boxes => precomputed_peer_boxes
        )
        unless result.is_a?(Hash) && Array(result[:failures]).empty?
          raise RepresentationFidelity::ContractError,
                "#{source_id}: #{mode} item renderer failed generically"
        end
        if result[:ok] == true
          begin
            transformed = apply_and_verify_page_representation_transform(
              result[:group], media_box, opts[:scale], page_rotation, y_offset,
              result
            )
            unless transformed &&
                   SvgItemRepresentationRenderer.verify_transformed_delivery!(
                     result
                   )
              raise RepresentationFidelity::ContractError,
                    "#{source_id}: #{mode} item page transform was not verified"
            end
            SvgItemRepresentationRenderer.finalize_source_evidence!(
              result, item, page_rotation
            )
            return record_item_vector_delivery!(
              stats, page_num, item, requested_mode, result, history,
              controller.transitions
            )
          rescue StandardError => error
            cleanup = RepresentationFidelity.erase_owned!(
              target_entities, [result[:group]]
            )
            raise RepresentationFidelity::ContractError,
                  "#{source_id}: #{mode} item delivery failed after creation: " \
                  "#{error.message}; cleaned #{cleanup.join(', ')}"
          end
        end
        proof = result[:transition_proof]
        controller.advance!(proof)
        append_failed_item_rung!(history, proof)
      end

      unless controller.current_mode == :raster && controller.terminal?
        raise RepresentationFidelity::ContractError,
              "#{source_id}: item representation ladder did not reach Raster"
      end
      raster = verified_item_raster_entity!(
        model, target_entities, pdf_path, page_num, item, media_box, opts,
        import_start, y_offset, page_rotation
      )
      begin
        record_item_raster_delivery!(
          stats, page_num, item, requested_mode, raster, history,
          controller.transitions
        )
      rescue StandardError => error
        cleanup = RepresentationFidelity.erase_owned!(
          target_entities, [raster[:entity]]
        )
        raise RepresentationFidelity::ContractError,
              "#{source_id}: terminal item Raster recording failed: " \
              "#{error.message}; cleaned #{cleanup.join(', ')}"
      end
    end

    def self.prepare_item_page_match_and_peer_boxes(
      svg, media_box, text_items, opts, render_box, y_offset = 0.0
    )
      base_opts = {
        :scale => opts[:scale],
        :svg_page_box => render_box,
        :y_offset => y_offset.to_f
      }
      placed = CairoGlyphSource.model_space_loops(svg, media_box, base_opts)
      pens = Array(placed).map do |entry|
        {
          :x => Array(entry[:pen_pdf])[0],
          :y => Array(entry[:pen_pdf])[1],
          :placement_index => entry[:placement_index]
        }
      end
      match = CairoGlyphSource.match_spans(pens, text_items, media_box)

      base_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
      base_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
      tolerance = if CairoGlyphSource.const_defined?(
        :SPAN_MATCH_TOLERANCE_PT
      )
                    CairoGlyphSource::SPAN_MATCH_TOLERANCE_PT.to_f
                  else
                    2.0
                  end
      peer_boxes = {}
      Array(text_items).each do |item|
        source_id = RepresentationFidelity.source_span_id(item)
        box = CairoGlyphSource.item_bbox_media_relative(item, base_x, base_y)
        next unless box
        x0, x1 = [box[0].to_f, box[2].to_f].minmax
        y0, y1 = [box[1].to_f, box[3].to_f].minmax
        peer_boxes[source_id] = [
          x0 - tolerance, y0 - tolerance,
          x1 + tolerance, y1 + tolerance
        ]
      end

      [match, peer_boxes]
    end

    def self.item_raster_crop_geometry(item, media_box, page_rotation, dpi,
                                       padding_points = 1.5)
      unless media_box.is_a?(Array) && media_box.length >= 4
        raise RepresentationFidelity::ContractError,
              'item raster MediaBox is unavailable'
      end
      base_x = media_box[0].to_f
      base_y = media_box[1].to_f
      relative = CairoGlyphSource.item_bbox_media_relative(item, base_x, base_y)
      unless relative && relative.length >= 4
        raise RepresentationFidelity::ContractError,
              'item raster source bbox is unavailable'
      end
      x0 = relative[0].to_f + base_x
      y0 = relative[1].to_f + base_y
      x1 = relative[2].to_f + base_x
      y1 = relative[3].to_f + base_y
      x0, x1 = [x0, x1].minmax
      y0, y1 = [y0, y1].minmax
      pad = [padding_points.to_f, 0.0].max
      min_x, max_x = [media_box[0].to_f, media_box[2].to_f].minmax
      min_y, max_y = [media_box[1].to_f, media_box[3].to_f].minmax
      source_box = [
        [x0 - pad, min_x].max, [y0 - pad, min_y].max,
        [x1 + pad, max_x].min, [y1 + pad, max_y].min
      ]
      display_box = PageTransform.transform_bbox(
        source_box[0], source_box[1], source_box[2], source_box[3],
        media_box, page_rotation
      )
      display_width = display_box[2] - display_box[0]
      display_height = display_box[3] - display_box[1]
      unless display_width > 0.0 && display_height > 0.0
        raise RepresentationFidelity::ContractError,
              'item raster source bbox is empty'
      end
      page_height = PageTransform.effective_height(media_box, page_rotation)
      pixels_per_point = dpi.to_f / 72.0
      raise RepresentationFidelity::ContractError,
            'item raster DPI must be positive' unless pixels_per_point > 0.0
      pixel_x0 = (display_box[0] * pixels_per_point).floor
      pixel_y0 = ((page_height - display_box[3]) * pixels_per_point).floor
      pixel_x1 = (display_box[2] * pixels_per_point).ceil
      pixel_y1 = ((page_height - display_box[1]) * pixels_per_point).ceil
      {
        :source_box => source_box,
        :display_box => display_box,
        :display_width => display_width,
        :display_height => display_height,
        :page_rotation => PageTransform.normalize_rotation(page_rotation),
        :dpi => dpi.to_i,
        :pixel_crop => [
          pixel_x0, pixel_y0,
          [pixel_x1 - pixel_x0, 1].max,
          [pixel_y1 - pixel_y0, 1].max
        ]
      }
    end

    def self.complete_text3d_item_fallbacks!(
      stats, model, target_entities, pdf_path, page_num, text_items,
      media_box, render_box, page_rotation, opts, import_start, y_offset,
      svg_document, initial_proofs
    )
      items_by_id = {}
      Array(text_items).each do |item|
        items_by_id[RepresentationFidelity.source_span_id(item)] = item
      end
      proofs_by_id = {}
      Array(initial_proofs).each do |proof|
        source_id = RepresentationFidelity.source_span_id(proof[:source_span_id])
        raise RepresentationFidelity::ContractError,
              "duplicate initial fallback proof for #{source_id}" if
          proofs_by_id.key?(source_id)
        proofs_by_id[source_id] = proof
      end

      precomputed_match, precomputed_peer_boxes =
        prepare_item_page_match_and_peer_boxes(
          svg_document[:svg], media_box, text_items, opts, render_box, 0.0
        )

      proofs_by_id.each do |source_id, initial_proof|
        item = items_by_id[source_id]
        raise RepresentationFidelity::ContractError,
              "fallback proof has no source item #{source_id}" unless item
        controller = RepresentationFidelity::FallbackController.new(
          :text3d, source_id
        )
        controller.advance!(initial_proof)
        history = []
        append_failed_item_rung!(history, initial_proof)
        complete_item_representation_ladder!(
          stats, model, target_entities, pdf_path, page_num, item, :text3d,
          controller, history, media_box, render_box, page_rotation, opts,
          import_start, y_offset, svg_document, nil,
          Array(text_items).reject do |peer|
            RepresentationFidelity.source_span_id(peer) == source_id
          end,
          precomputed_match, precomputed_peer_boxes
        )
      end
      true
    end

    def self.complete_label_item_fallbacks!(
      stats, model, target_entities, pdf_path, page_num, text_items,
      media_box, render_box, page_rotation, opts, import_start, y_offset,
      svg_document, failures, prior_attempts, text_layer,
      all_page_text_items = nil, requested_mode = :labels,
      prepared_controllers = nil
    )
      items_by_id = {}
      Array(text_items).each do |item|
        items_by_id[RepresentationFidelity.source_span_id(item)] = item
      end
      attempts_by_id = {}
      Array(prior_attempts).each do |attempt|
        attempts_by_id[attempt[:source_span_id].to_s] = attempt
      end
      controllers = {}
      failed_items = []
      Array(failures).each do |failure|
        source_id = RepresentationFidelity.source_span_id(
          failure[:source_span_id]
        )
        item = items_by_id[source_id]
        proof = failure[:transition_proof]
        unless item && proof.is_a?(Hash)
          raise RepresentationFidelity::ContractError,
                "#{source_id} Labels failure lacks an item-bound transition proof"
        end
        prepared = prepared_controllers.is_a?(Hash) ?
          prepared_controllers[source_id] : nil
        controller = prepared.is_a?(Hash) ? prepared[:controller] : nil
        controller ||= RepresentationFidelity::FallbackController.new(
          requested_mode, source_id
        )
        unless controller.current_mode == :labels
          raise RepresentationFidelity::ContractError,
                "#{source_id} controller is not at the Labels rung"
        end
        controller.advance!(proof)
        controllers[source_id] = controller
        failed_items << item
      end
      return true if failed_items.empty?

      depth = opts[:text_3d_depth]
      depth = Svg3DTextRenderer::DEFAULT_DEPTH_INCHES if depth.nil?
      result = Svg3DTextRenderer.render_svg(
        target_entities, svg_document[:svg], media_box, failed_items,
        :scale => opts[:scale], :svg_page_box => render_box,
        :y_offset => 0.0, :depth => depth, :layer => text_layer,
        :page_number => page_num,
        :preserve_unmatched_source_placements => false,
        :source_context => svg_source_context(svg_document, page_num, {})
      )
      unless Array(result[:failures]).empty?
        details = result[:failures].map do |failure|
          "#{failure[:source_span_id]}:#{failure[:reason_code]}"
        end
        raise RepresentationFidelity::ContractError,
              "Labels -> 3D Text fallback failed generically: #{details.join(', ')}"
      end

      rows = Array(result[:span_results])
      transforms_ok = rows.all? do |row|
        apply_and_verify_page_representation_transform(
          row[:group], media_box, opts[:scale], page_rotation, y_offset, row
        )
      end
      unless transforms_ok
        rows.each do |row|
          RepresentationFidelity.erase_owned!(
            target_entities, [row[:group]]
          ) if row[:group]
        end
        raise RepresentationFidelity::ContractError,
              'Labels -> 3D Text page transform was not verified'
      end

      delivered_ids = rows.map { |row| row[:source_span_id].to_s }
      delivered_items = failed_items.select do |item|
        delivered_ids.include?(RepresentationFidelity.source_span_id(item))
      end
      delivered_items.each do |item|
        source_id = RepresentationFidelity.source_span_id(item)
        record_fallback_transitions!(
          stats, page_num, controllers[source_id].transitions
        )
      end
      unless delivered_items.empty?
        record_svg_3d_text_delivery!(
          stats, page_num, delivered_items, result, requested_mode,
          attempts_by_id,
          page_rotation
        )
        stats[:text] = stats[:text].to_i + rows.length
        stats[:faces] = stats[:faces].to_i + rows.inject(0) do |sum, row|
          sum + row[:face_count].to_i
        end
      end

      transition_by_id = {}
      Array(result[:transition_proofs]).each do |proof|
        transition_by_id[proof[:source_span_id].to_s] = proof
      end

      label_peer_items = Array(all_page_text_items || text_items)
      precomputed_match, precomputed_peer_boxes =
        prepare_item_page_match_and_peer_boxes(
          svg_document[:svg], media_box, label_peer_items, opts, render_box, 0.0
        )

      undelivered = failed_items.reject do |item|
        delivered_ids.include?(RepresentationFidelity.source_span_id(item))
      end
      undelivered.each do |item|
        source_id = RepresentationFidelity.source_span_id(item)
        controller = controllers[source_id]
        text3d_proof = transition_by_id[source_id]
        unless text3d_proof
          raise RepresentationFidelity::ContractError,
                "#{source_id} has neither 3D Text delivery nor proof"
        end
        controller.advance!(text3d_proof)
        prior = attempts_by_id[source_id]
        history = prior.is_a?(Hash) ?
          Array(prior[:attempt_history]).map { |entry| entry.dup } : []
        append_failed_item_rung!(history, controller.transitions.first)
        append_failed_item_rung!(history, text3d_proof)
        complete_item_representation_ladder!(
          stats, model, target_entities, pdf_path, page_num, item,
          requested_mode,
          controller, history, media_box, render_box, page_rotation, opts,
          import_start, y_offset, svg_document, text_layer,
          Array(all_page_text_items || text_items).reject do |peer|
            RepresentationFidelity.source_span_id(peer) == source_id
          end,
          precomputed_match, precomputed_peer_boxes
        )
      end
      true
    end

    def self.verified_raster_entity!(model, pdf_path, page_num, media_box, opts,
                                     import_start, y_offset, render_box,
                                     page_rotation = 0)
      parent = nil
      before = nil
      delivery = nil
      parent = model.active_entities
      before = RepresentationFidelity.snapshot(parent)
      delivery = import_page_as_raster(
        model, pdf_path, page_num, media_box, opts, import_start, y_offset,
        render_box, page_rotation
      )
      unless delivery.is_a?(Hash) && delivery[:entity] &&
             delivery[:artifact_evidence].is_a?(Hash)
        raise RepresentationFidelity::ContractError,
              'terminal raster lacks verified PNG/page/box evidence'
      end
      image = delivery[:entity]
      artifact = delivery[:artifact_evidence]
      required_artifact_checks = [
        :png_signature_verified, :page_binding_verified,
        :box_binding_verified, :aspect_verified,
        :source_pdf_binding_verified
      ]
      unless required_artifact_checks.all? { |key| artifact[key] == true } &&
             artifact[:page_number].to_i == page_num.to_i &&
             artifact[:page_rotation].to_i ==
               PageTransform.normalize_rotation(page_rotation) &&
             artifact[:source_pdf_sha256].to_s.downcase ==
               Digest::SHA256.file(pdf_path).hexdigest &&
             File.expand_path(artifact[:source_pdf_path].to_s).downcase ==
               File.expand_path(pdf_path.to_s).downcase
        raise RepresentationFidelity::ContractError,
              'terminal raster artifact evidence is incomplete or misbound'
      end
      raise RepresentationFidelity::ContractError,
            'terminal raster renderer did not create an image' unless image
      after = RepresentationFidelity.snapshot(parent)
      created = RepresentationFidelity.created_between(before, after)
      image_id = RepresentationFidelity.stable_entity_id(image)
      created_ids = RepresentationFidelity.stable_ids(created)
      unless created_ids == [image_id]
        raise RepresentationFidelity::ContractError,
              'terminal raster must own exactly one top-level image'
      end
      type = representation_entity_type(image)
      unless type.to_s.downcase.include?('image')
        raise RepresentationFidelity::ContractError,
              "terminal raster entity type is #{type}, not Image"
      end
      bounds = RepresentationFidelity.bounds([image])
      unless bounds[:width].to_f > 0.0 && bounds[:height].to_f > 0.0
        raise RepresentationFidelity::ContractError,
              'terminal raster image has empty placement bounds'
      end
      {
        :entity => image,
        :entity_id => image_id,
        :created_entities => created,
        :created_entity_ids => created_ids,
        :bounds => bounds,
        :artifact_evidence => artifact,
        :visual_fidelity_verified => true,
        :real_raster_verified => true
      }
    rescue StandardError => e
      if parent && before
        begin
          current = RepresentationFidelity.snapshot(parent)
          owned = RepresentationFidelity.claimed_created_entities!(
            before, current, raster_delivery_owned_claims(delivery)
          )
          RepresentationFidelity.erase_owned!(parent, owned) unless owned.empty?
        rescue StandardError => cleanup_error
          raise RepresentationFidelity::ContractError,
                "terminal raster verification failed: #{e.message}; " \
                "owned cleanup failed: #{cleanup_error.message}"
        end
      end
      raise e if e.is_a?(RepresentationFidelity::ContractError)
      raise RepresentationFidelity::ContractError,
            "terminal raster verification failed: #{e.message}"
    end

    def self.verified_item_raster_entity!(model, target_entities, pdf_path,
                                          page_num, item, media_box, opts,
                                          import_start, y_offset,
                                          page_rotation = 0)
      parent = target_entities
      delivery = nil
      before = RepresentationFidelity.snapshot(parent)
      delivery = import_item_as_raster(
        model, parent, pdf_path, page_num, item, media_box, opts,
        import_start, y_offset, page_rotation
      )
      unless delivery.is_a?(Hash) && delivery[:entity] &&
             delivery[:artifact_evidence].is_a?(Hash)
        raise RepresentationFidelity::ContractError,
              'terminal item raster lacks verified source-crop evidence'
      end
      image = delivery[:entity]
      artifact = delivery[:artifact_evidence]
      source_id = RepresentationFidelity.source_span_id(item)
      required = [
        :png_signature_verified, :page_binding_verified,
        :source_crop_binding_verified, :source_pdf_binding_verified,
        :aspect_verified, :alpha_channel_verified,
        :transparent_background_verified, :visible_pixel_verified,
        :page_render_once_verified
      ]
      source_sha256 = cached_source_pdf_sha256!(opts, pdf_path)
      unless required.all? { |key| artifact[key] == true } &&
             artifact[:source_span_id].to_s == source_id &&
              artifact[:page_number].to_i == page_num.to_i &&
              artifact[:source_pdf_sha256].to_s.downcase ==
                source_sha256 &&
             File.expand_path(artifact[:source_pdf_path].to_s).downcase ==
               File.expand_path(pdf_path.to_s).downcase &&
             artifact[:page_rotation].to_i ==
               PageTransform.normalize_rotation(page_rotation)
        raise RepresentationFidelity::ContractError,
              'terminal item raster evidence is incomplete or misbound'
      end
      after = RepresentationFidelity.snapshot(parent)
      created = RepresentationFidelity.created_between(before, after)
      image_id = RepresentationFidelity.stable_entity_id(image)
      created_ids = RepresentationFidelity.stable_ids(created)
      unless created_ids == [image_id]
        raise RepresentationFidelity::ContractError,
              'terminal item raster must own exactly one top-level image'
      end
      type = representation_entity_type(image)
      unless type.to_s.downcase.include?('image')
        raise RepresentationFidelity::ContractError,
              "terminal item raster entity type is #{type}, not Image"
      end
      bounds = RepresentationFidelity.bounds([image])
      unless bounds[:width].to_f > 0.0 && bounds[:height].to_f > 0.0
        raise RepresentationFidelity::ContractError,
              'terminal item raster has empty placement bounds'
      end
      {
        :entity => image,
        :entity_id => image_id,
        :created_entities => created,
        :created_entity_ids => created_ids,
        :bounds => bounds,
        :artifact_evidence => artifact,
        :visual_fidelity_verified => true,
        :real_raster_verified => true
      }
    rescue StandardError => e
      if parent && before
        begin
          current = RepresentationFidelity.snapshot(parent)
          owned = RepresentationFidelity.claimed_created_entities!(
            before, current, raster_delivery_owned_claims(delivery)
          )
          RepresentationFidelity.erase_owned!(parent, owned) unless owned.empty?
        rescue StandardError => cleanup_error
          raise RepresentationFidelity::ContractError,
                "terminal item raster verification failed: #{e.message}; " \
                "owned cleanup failed: #{cleanup_error.message}"
        end
      end
      raise e if e.is_a?(RepresentationFidelity::ContractError)
      raise RepresentationFidelity::ContractError,
            "terminal item raster verification failed: #{e.message}"
    end

    def self.raster_delivery_owned_claims(delivery)
      return [] unless delivery.is_a?(Hash)
      Array(delivery[:owned_entities]) + Array(delivery[:entity])
    end

    # Classify renderer-visible source material on a page whose semantic/path
    # extractors returned nothing. Glyph placements remain eligible for their
    # exact requested renderer; image/non-text marks authorize a verified page
    # raster only when no requested-representation artifact exists.
    def self.svg_page_source_summary(svg, media_box, opts = {})
      source = svg.to_s
      placed = CairoGlyphSource.model_space_loops(source, media_box, opts)
      definitions = source.scan(/<defs\b.*?<\/defs>/im).join
      visible_body = source.gsub(/<defs\b.*?<\/defs>/im, '')
      image_ids = definitions.scan(
        /<image\b[^>]*\bid=["']([^"']+)["']/i
      ).flatten.map { |value| value.to_s }
      image_definitions = image_ids.length
      use_refs = visible_body.scan(
        /<use\b[^>]*(?:xlink:href|href)=["']#([^"']+)["']/i
      ).flatten.map { |value| value.to_s }
      referenced_image_placements = use_refs.count do |reference|
        image_ids.include?(reference)
      end
      direct_image_placements = visible_body.scan(/<image\b/i).length
      image_placements = direct_image_placements + referenced_image_placements
      source_uses = use_refs.count do |reference|
        reference !~ /\Aglyph-/i
      end
      direct_nontext_marks = visible_body.scan(
        /<(?:path|rect|circle|ellipse|polygon|polyline|line)\b/i
      ).length
      {
        :source_glyph_placements => placed.length,
        :source_uses => source_uses,
        :image_definitions => image_definitions,
        :direct_image_placements => direct_image_placements,
        :referenced_image_placements => referenced_image_placements,
        :image_placements => image_placements,
        :direct_nontext_marks => direct_nontext_marks,
        :visible_nontext_source => image_placements > 0 || source_uses > 0 ||
          direct_nontext_marks > 0,
        :visible_source => !placed.empty? || image_placements > 0 ||
          source_uses > 0 ||
          direct_nontext_marks > 0
      }
    rescue StandardError => e
      {
        :source_glyph_placements => 0,
        :source_uses => 0,
        :image_definitions => 0,
        :direct_image_placements => 0,
        :referenced_image_placements => 0,
        :image_placements => 0,
        :direct_nontext_marks => 0,
        :visible_nontext_source => false,
        :visible_source => false,
        :inspection_error => e.message.to_s
      }
    end

    # Extraction is not delivery. In particular, CCITT/JBIG2 image streams may
    # be preserved for diagnostics while remaining unplaceable by SketchUp.
    # Therefore an extracted embedded asset can never suppress inspection of a
    # page for which neither path nor semantic-text artifacts were produced.
    def self.empty_requested_page_artifacts?(paths, text_items,
                                             _embedded_assets = nil)
      Array(paths).empty? && Array(text_items).empty?
    end

    def self.requested_zero_canonical_page_raster?(requested_mode,
                                                   import_text, text_items)
      normalize_text_renderer_mode(requested_mode) == :raster &&
        import_text == true && Array(text_items).empty?
    end

    def self.record_empty_page_source_inspection!(stats, page_num, details = {})
      unless stats.is_a?(Hash)
        raise RepresentationFidelity::ContractError,
              'empty-page source inspection stats are unavailable'
      end
      page = page_num.to_i
      if page <= 0
        raise RepresentationFidelity::ContractError,
              'empty-page source inspection page is invalid'
      end
      immutable_sha = stats[:source_input_sha256].to_s.downcase
      rendered_sha = stats[:normalized_input_sha256].to_s.downcase
      unless immutable_sha =~ /\A[0-9a-f]{64}\z/ &&
             rendered_sha =~ /\A[0-9a-f]{64}\z/
        raise RepresentationFidelity::ContractError,
              'empty-page source inspection is not bound to exact PDF bytes'
      end

      rows = stats[:empty_page_source_inspections]
      rows = [] unless rows.is_a?(Array)
      stats[:empty_page_source_inspections] = rows
      matches = rows.select do |row|
        row.is_a?(Hash) && row[:page].to_i == page
      end
      if matches.length > 1
        raise RepresentationFidelity::ContractError,
              "Page #{page}: duplicate empty-page source inspections"
      end
      row = matches.first
      unless row
        row = {}
        rows << row
      end
      if details.is_a?(Hash)
        details.each { |key, value| row[key] = value }
      end
      # These bindings are authoritative and cannot be overwritten by a caller.
      row[:page] = page
      row[:source_page_number] = page
      row[:canonical_text_item_count] = 0
      row[:immutable_pdf_sha256] = immutable_sha
      row[:rendered_pdf_sha256] = rendered_sha
      row
    end

    def self.canonical_terminal_text_bbox(value, label)
      return nil if value.nil?
      unless value.is_a?(Array) && value.length == 4
        raise RepresentationFidelity::ContractError,
              "#{label} source bbox is missing or malformed"
      end
      value.map do |raw|
        number = Float(raw)
        unless number.finite?
          raise RepresentationFidelity::ContractError,
                "#{label} source bbox is non-finite"
        end
        RepresentationFidelity.canonical_number(number)
      end
    rescue RepresentationFidelity::ContractError
      raise
    rescue StandardError => e
      raise RepresentationFidelity::ContractError,
            "#{label} source bbox is unreadable: #{e.message}"
    end

    def self.terminal_text_attempt_source_bbox!(item, prior_attempt,
                                                requested_mode,
                                                expected_evidence)
      requested = RepresentationFidelity.normalize_mode(requested_mode)
      source_bbox = begin
        RepresentationFidelity.strict_source_bbox_pdf(item)
      rescue RepresentationFidelity::ContractError
        raise if requested == :text
        nil
      end
      prior_bbox = if prior_attempt.is_a?(Hash)
                     RepresentationFidelity.contract_hash_value(
                       prior_attempt, :source_bbox_pdf
                     )
                   end
      evidence_bbox = if expected_evidence.is_a?(Hash)
                        RepresentationFidelity.contract_hash_value(
                          expected_evidence, :source_bbox_pdf
                        )
                      end
      prior_bbox = canonical_terminal_text_bbox(prior_bbox, 'prior attempt')
      evidence_bbox = canonical_terminal_text_bbox(
        evidence_bbox, 'terminal 3D Text evidence'
      )

      if requested == :text && (!prior_attempt.is_a?(Hash) ||
                                prior_bbox.nil? || evidence_bbox.nil?)
        raise RepresentationFidelity::ContractError,
              'Text fallback terminal record is missing its exact source bbox'
      end

      candidates = [source_bbox, prior_bbox, evidence_bbox].compact
      unless candidates.empty? || candidates.all? { |bbox| bbox == candidates[0] }
        raise RepresentationFidelity::ContractError,
              'terminal 3D Text source bbox conflicts with its prior attempt'
      end
      candidates.first
    end

    def self.record_svg_3d_text_delivery!(stats, page_num, text_items,
                                          render_result,
                                          requested_mode = :text3d,
                                          prior_attempts = {},
                                          page_rotation = 0.0)
      requested_mode = RepresentationFidelity.normalize_mode(requested_mode)
      requested_mode = :text3d unless requested_mode
      rows = Array(render_result[:span_results])
      physical_rows = Array(render_result[:unmatched_source_results])
      expected = Array(text_items).map do |item|
        RepresentationFidelity.source_span_id(item)
      end
      items_by_id = {}
      Array(text_items).each do |item|
        items_by_id[RepresentationFidelity.source_span_id(item)] = item
      end
      delivered = rows.map { |row| row[:source_span_id].to_s }
      unless delivered.sort == expected.sort
        raise RepresentationFidelity::ContractError,
              '3D text delivered source set does not equal the requested source set'
      end
      rows.each do |row|
        item = items_by_id[row[:source_span_id].to_s]
        unless item
          raise RepresentationFidelity::ContractError,
                "#{row[:source_span_id]} 3D Text source item is unavailable"
        end
        Svg3DTextRenderer.finalize_source_evidence!(
          row, item, page_rotation
        )
        required = [
          :identity_verified, :placement_verified, :rotation_verified,
          :size_verified, :depth_verified, :content_verified,
          :physical_geometry_verified, :physical_style_verified,
          :transform_verified
        ]
        unless required.all? { |key| row[key] == true }
          raise RepresentationFidelity::ContractError,
                "#{row[:source_span_id]} 3D text evidence is incomplete"
        end
        unless row[:depth].to_f > 0.0 && row[:extruded_face_count].to_i > 0
          raise RepresentationFidelity::ContractError,
                "#{row[:source_span_id]} is flat, not 3D text"
        end
        prior = prior_attempts[row[:source_span_id].to_s]
        source_bbox = terminal_text_attempt_source_bbox!(
          item, prior, requested_mode, row[:expected_evidence]
        )
        history = prior.is_a?(Hash) ?
          Array(prior[:attempt_history]).map { |entry| entry.dup } : []
        history << {
          :mode => :text3d, :outcome => :complete,
          :resulting_entity_ids => [row[:group_entity_id]],
          :cleanup_outcome => :not_required,
          :placement_verified => true,
          :rotation_verified => true,
          :width_verified => true,
          :height_verified => true,
          :depth_verified => true,
          :content_verified => true,
          :entity_type_verified => true,
          :source_glyph_identity_verified => true,
          :positive_z_depth_verified => true,
          :physical_geometry_verified => true,
          :physical_style_verified => true,
          :transform_verified => true,
          :expected_evidence => row[:expected_evidence],
          :visual_fidelity_verified => true
        }
        stats[:text_attempts] ||= []
        stats[:text_attempts] << {
          :source_span_id => row[:source_span_id],
          :requested_mode => requested_mode,
          :delivered_mode => :text3d,
          :renderer => :svg_source_3d_text,
          :resulting_entity_ids => [row[:group_entity_id]],
          :visual_fidelity_verified => true,
          :placement_verified => true,
          :rotation_verified => true,
          :width_verified => true,
          :height_verified => true,
          :depth_verified => true,
          :content_verified => true,
          :entity_type_verified => true,
          :source_glyph_identity_verified => true,
          :positive_z_depth_verified => true,
          :physical_geometry_verified => true,
          :physical_style_verified => true,
          :transform_verified => true,
          :source_text_sha256 => row[:expected_evidence][:source_text_sha256],
          :source_bbox_pdf => source_bbox,
          :source_anchor => row[:expected_evidence][:source_anchor],
          :source_rotation_radians =>
            row[:expected_evidence][:source_rotation_radians],
          :expected_width => row[:expected_evidence][:expected_width],
          :expected_height => row[:expected_evidence][:expected_height],
          :expected_depth => row[:expected_evidence][:expected_depth],
          :source_style_sha256 =>
            row[:expected_evidence][:physical_style_sha256],
          :source_geometry_sha256 =>
            row[:expected_evidence][:physical_geometry_sha256],
          :expected_transform =>
            row[:expected_evidence][:expected_transformation],
          :expected_evidence => row[:expected_evidence],
          :width => row[:width], :height => row[:height], :depth => row[:depth],
          :attempt_history => history
        }
        stats[:source_provenance_objects] ||= []
        stats[:source_provenance_objects] << {
          :object_id => row[:source_span_id],
          :span_id => row[:source_span_id],
          :page => page_num.to_i,
          :source_kind => 'text_span',
          :created_entity_type => 'source_glyph_3d_text',
          :renderer => 'svg_source_3d_text',
          :resulting_entity_ids => [row[:group_entity_id]],
          :placement_verified => true,
          :rotation_verified => true,
          :width_verified => true,
          :height_verified => true,
          :depth_verified => true,
          :content_verified => true,
          :entity_type_verified => true,
          :source_glyph_identity_verified => true,
          :positive_z_depth_verified => true,
          :physical_geometry_verified => true,
          :physical_style_verified => true,
          :transform_verified => true,
          :expected_evidence => row[:expected_evidence],
          :width => row[:width], :height => row[:height], :depth => row[:depth]
        }
      end
      physical_rows.each do |row|
        required = [
          :identity_verified, :placement_verified, :rotation_verified,
          :size_verified, :depth_verified,
          :physical_source_identity_verified
        ]
        unless row[:source_kind] == :svg_glyph_placement &&
               !row[:source_unit_id].to_s.empty? &&
               required.all? { |key| row[key] == true } &&
               row[:source_span_id].nil? &&
               row[:depth].to_f > 0.0 &&
               row[:extruded_face_count].to_i > 0 &&
               !Array(row[:placement_indices]).empty?
          raise RepresentationFidelity::ContractError,
                'unjoined SVG source-glyph 3D evidence is incomplete'
        end
        stats[:source_provenance_objects] ||= []
        stats[:source_provenance_objects] << {
          :object_id => row[:source_unit_id],
          :span_id => nil,
          :page => page_num.to_i,
          :source_kind => 'svg_glyph_placement',
          :semantic_identity_available => false,
          :created_entity_type => 'source_glyph_3d_text',
          :renderer => 'svg_source_3d_text',
          :resulting_entity_ids => [row[:group_entity_id]],
          :source_placement_indices => row[:placement_indices],
          :source_glyph_identity_verified => true,
          :positive_z_depth_verified => true,
          :width => row[:width], :height => row[:height], :depth => row[:depth]
        }
        stats[:source_glyph_physical_deliveries] ||= []
        stats[:source_glyph_physical_deliveries] << {
          :page => page_num.to_i,
          :source_unit_id => row[:source_unit_id],
          :placement_indices => row[:placement_indices],
          :resulting_entity_ids => [row[:group_entity_id]],
          :delivered_mode => :text3d,
          :visual_fidelity_verified => true,
          :source_glyph_identity_verified => true,
          :positive_z_depth_verified => true
        }
      end
      physical_count = physical_rows.inject(0) do |sum, row|
        sum + row[:source_placement_count].to_i
      end
      record_text_renderer(
        stats, page_num,
        :renderer => :svg_source_3d_text,
        :mode => :text3d,
        :requested_mode => requested_mode,
        :delivered_mode => :text3d,
        :degraded => requested_mode != :text3d,
        :reason => requested_mode == :text3d ? nil :
          'affirmative item-specific requested-representation impossibility',
        :count => rows.length + physical_count,
        :semantic_span_count => rows.length,
        :unjoined_source_glyph_placement_count => physical_count,
        :source_glyph_identity_verified => true,
        :positive_z_depth_verified => true,
        :depths => (rows + physical_rows).map { |row| row[:depth] }
      )
      true
    end

    def self.record_page_representation_delivery!(stats, page_num, text_items,
                                                  page_group, mode,
                                                  created_entity_type,
                                                  renderer, svg_result,
                                                  media_box,
                                                  record_renderer = true)
      normalized_mode = RepresentationFidelity.normalize_mode(mode)
      allowed_types = {
        geometry: 'page_path_geometry',
        glyphs: 'glyph_outline'
      }
      unless allowed_types[normalized_mode] == created_entity_type.to_s
        raise RepresentationFidelity::ContractError,
              'Page representation mode and entity type are inconsistent'
      end
      raise RepresentationFidelity::ContractError,
            'Page representation delivery must be a distinct group' unless
        page_group && page_group.respond_to?(:entities)
      unless svg_page_visual_fidelity_verified?(
               svg_result, text_items, media_box, normalized_mode, page_group
             )
        raise RepresentationFidelity::ContractError,
              'Page representation type/visual/source evidence is incomplete'
      end
      source_ids = Array(text_items).map do |item|
        RepresentationFidelity.source_span_id(item)
      end
      raise RepresentationFidelity::ContractError,
            'Page representation delivery source set is empty' if source_ids.empty?
      raise RepresentationFidelity::ContractError,
            'Page representation delivery source IDs are duplicated' unless
        source_ids.uniq.length == source_ids.length
      entity_ids = [RepresentationFidelity.stable_entity_id(page_group)]
      record = {
        page: page_num.to_i,
        source_span_ids: source_ids,
        requested_mode: normalized_mode,
        delivered_mode: normalized_mode,
        created_entity_type: created_entity_type.to_s,
        resulting_entity_ids: entity_ids,
        visual_fidelity_verified: true
      }
      stats[:page_text_delivery_records] ||= []
      stats[:page_text_delivery_records] << record
      stats[:text_attempts] ||= []
      stats[:text_attempts] << {
        source_span_ids: source_ids,
        requested_mode: normalized_mode,
        delivered_mode: normalized_mode,
        resulting_entity_ids: entity_ids,
        visual_fidelity_verified: true,
        attempt_history: [{
          mode: normalized_mode, outcome: :complete,
          resulting_entity_ids: entity_ids,
          cleanup_outcome: :not_required,
          visual_fidelity_verified: true
        }]
      }
      if record_renderer
        record_text_renderer(
          stats, page_num,
          renderer: renderer, mode: normalized_mode,
          requested_mode: normalized_mode, delivered_mode: normalized_mode,
          degraded: false, count: source_ids.length,
          resulting_entity_ids: entity_ids
        )
      end
      true
    end

    def self.record_page_geometry_delivery!(stats, page_num, text_items,
                                            page_group, svg_result, media_box)
      record_page_representation_delivery!(
        stats, page_num, text_items, page_group, :geometry,
        'page_path_geometry', :svg_raw_path_geometry, svg_result, media_box,
        false
      )
    end

    def self.record_page_glyph_delivery!(stats, page_num, text_items,
                                         page_group, svg_result, media_box)
      record_page_representation_delivery!(
        stats, page_num, text_items, page_group, :glyphs,
        'glyph_outline', :svg_glyph_components, svg_result, media_box, false
      )
    end

    def self.representation_entity_type(entity)
      return '' unless entity
      if entity.respond_to?(:typename)
        value = entity.typename.to_s
        return value unless value.empty?
      end
      entity.class.name.to_s.split('::').last
    rescue StandardError
      ''
    end

    def self.representation_entity_members(value)
      collection = value.respond_to?(:entities) ? value.entities : value
      return nil unless collection && collection.respond_to?(:to_a)
      Array(collection.to_a)
    rescue StandardError
      nil
    end

    def self.svg_page_representation_type_verified?(svg_result, requested_mode,
                                                    page_group)
      return false unless svg_result.is_a?(Hash)
      members = representation_entity_members(page_group)
      return false unless members && !members.empty?
      mode = normalize_text_renderer_mode(requested_mode)

      if mode == :geometry
        return false unless svg_result[:raw_edge_glyphs] == true
        return false unless svg_result[:component_container] == false
        return false unless svg_result[:glyph_instances].to_i == 0
        return false unless svg_result[:flattened_glyph_instances].to_i == 0
        return false unless svg_result[:edges].to_i > 0
        return false unless members.length == svg_result[:edges].to_i
        return members.all? do |entity|
          representation_entity_type(entity) == 'Edge'
        end
      end

      if mode == :glyphs
        return false unless svg_result[:raw_edge_glyphs] == false
        return false unless svg_result[:component_container] == true
        return false unless svg_result[:flattened_glyph_instances].to_i == 0
        return false unless svg_result[:glyph_instances].to_i > 0
        return false unless svg_result[:glyph_instances].to_i ==
                            svg_result[:glyphs].to_i
        return false unless members.length == 1
        container = members.first
        return false unless representation_entity_type(container) == 'Group'
        instances = representation_entity_members(container)
        return false unless instances &&
                            instances.length == svg_result[:glyph_instances].to_i
        return instances.all? do |entity|
          representation_entity_type(entity) == 'ComponentInstance'
        end
      end

      false
    rescue StandardError
      false
    end

    def self.svg_page_visual_fidelity_verified?(svg_result, text_items,
                                                media_box, requested_mode,
                                                page_group)
      return false unless svg_result.is_a?(Hash)
      return false unless svg_result[:glyphs].to_i > 0
      return false unless svg_result[:skipped_glyphs].to_i == 0
      return false unless svg_result[:missing_glyphs].to_i == 0
      return false unless svg_result[:placement_failures].to_i == 0
      unoutlined = svg_result[:unoutlined_placement_evidence]
      return false if !unoutlined.nil? && !unoutlined.is_a?(Array)
      unoutlined_ids = Array(unoutlined).map do |entry|
        entry.is_a?(Hash) ? entry[:glyph_id].to_s : ''
      end.uniq.sort
      certified_unoutlined = Array(
        svg_result[:certified_unoutlined_glyph_ids]
      ).map { |glyph_id| glyph_id.to_s }.uniq.sort
      return false unless (unoutlined_ids - certified_unoutlined).empty?
      return false unless svg_page_representation_type_verified?(
        svg_result, requested_mode, page_group
      )

      source_ids = Array(text_items).map do |item|
        RepresentationFidelity.source_span_id(item)
      end
      return false if source_ids.empty? || source_ids.uniq.length != source_ids.length
      match = CairoGlyphSource.match_spans(
        svg_result[:placements_pdf], text_items, media_box
      )
      matched_ids = Array(match[:matched_items]).map do |item|
        RepresentationFidelity.source_span_id(item)
      end
      matched_ids.sort == source_ids.sort &&
        match[:runs_unmatched].to_i == 0 &&
        match[:placements_unmatched].to_i == 0
    rescue RepresentationFidelity::ContractError
      raise
    rescue StandardError
      false
    end

    # A known return-code-zero Poppler diagnostic may remain deferred only
    # until the current page's created glyphs have been matched to every real
    # extractor source span and host placement failures are known. Production
    # owns the exact fixture certificate; callers cannot supply a blanket true.
    def self.finalize_svg_poppler_semantics(svg_result, pdf_path, page_num,
                                            text_items, media_box)
      return false unless svg_result.is_a?(Hash)
      transport = svg_result[:poppler_transport_validation]
      if svg_result[:renderer] == :pdftocairo && !transport.is_a?(Hash)
        return false
      end
      deferred = transport.is_a?(Hash) &&
        transport[:semantic_completion_deferred] == true
      unoutlined_present = !svg_result.key?(:unoutlined_placement_evidence) ||
        !svg_result[:unoutlined_placement_evidence].is_a?(Array) ||
        !svg_result[:unoutlined_placement_evidence].empty?
      return true unless deferred || unoutlined_present

      proof = PopplerSemanticProof.for_svg_page(pdf_path, page_num)
      allowed_unoutlined = proof.respond_to?(:call) ?
        PopplerSemanticProof::ADOBE_GB1_PAGE_CERTIFICATE[
          :allowed_unoutlined_glyph_ids
        ] : []
      evidence = CairoGlyphSource.semantic_completion_evidence(
        svg_result, text_items, media_box, allowed_unoutlined
      )
      semantic_ok = if deferred
                      SvgTextRenderer.finalize_deferred_semantic_validation(
                        svg_result, proof, evidence
                      )
                    else
                      proof.respond_to?(:call) &&
                        PopplerSemanticProof.complete_failure_evidence?(
                          evidence
                        ) && proof.call(evidence) == true
                    end
      if semantic_ok
        svg_result[:certified_unoutlined_glyph_ids] =
          Array(allowed_unoutlined).map { |glyph_id| glyph_id.to_s }.uniq.sort
      end
      semantic_ok
    rescue StandardError => e
      Logger.warn('PopplerSemanticProof',
        "Page #{page_num}: final semantic proof failed: #{e.message}")
      false
    end

    def self.create_owned_page_representation_group!(parent_entities, name)
      before = RepresentationFidelity.snapshot(parent_entities)
      group = nil
      begin
        group = parent_entities.add_group
        raise RepresentationFidelity::ContractError,
              'Page representation group was not created' unless group
        group.name = name.to_s if group.respond_to?(:name=)
        after = RepresentationFidelity.snapshot(parent_entities)
        created = RepresentationFidelity.created_between(before, after)
        unless created.length == 1 && created.first.equal?(group)
          raise RepresentationFidelity::ContractError,
                'Page representation group ownership is ambiguous'
        end
        group
      rescue RepresentationFidelity::ContractError => e
        restore_page_representation_snapshot!(parent_entities, before, group) if group
        raise e
      rescue StandardError => e
        restore_page_representation_snapshot!(parent_entities, before, group) if group
        raise RepresentationFidelity::ContractError,
              "Page representation group creation failed: #{e.message}"
      end
    end

    def self.restore_page_representation_snapshot!(parent_entities,
                                                   before_snapshot, group)
      created_id = nil
      begin
        created_id = RepresentationFidelity.stable_entity_id(group)
      rescue RepresentationFidelity::ContractError
        # A stable ID is not required to erase the exact object reference.  The
        # before/after snapshot equality below is the fail-closed proof.
      end
      raise RepresentationFidelity::ContractError,
            'Page representation target cannot erase its owned group' unless
        parent_entities.respond_to?(:erase_entities)
      parent_entities.erase_entities(group)
      after = RepresentationFidelity.snapshot(parent_entities)
      unless after[:by_id].keys.sort == before_snapshot[:by_id].keys.sort
        raise RepresentationFidelity::ContractError,
              'Page representation group cleanup did not restore the exact snapshot'
      end
      created_id ? [created_id] : []
    rescue RepresentationFidelity::ContractError
      raise
    rescue StandardError => e
      raise RepresentationFidelity::ContractError,
            "Page representation group cleanup failed: #{e.message}"
    end

    def self.page_representation_transform(media_box, scale, rotation, y_offset)
      width = PageTransform.box_width(media_box) * (1.0 / 72.0) * scale.to_f
      height = PageTransform.box_height(media_box) * (1.0 / 72.0) * scale.to_f
      y = y_offset.to_f
      zaxis = Geom::Vector3d.new(0.0, 0.0, 1.0)
      case PageTransform.normalize_rotation(rotation)
      when 90
        origin = Geom::Point3d.new(0.0, width + y, 0.0)
        xaxis = Geom::Vector3d.new(0.0, -1.0, 0.0)
        yaxis = Geom::Vector3d.new(1.0, 0.0, 0.0)
      when 180
        origin = Geom::Point3d.new(width, height + y, 0.0)
        xaxis = Geom::Vector3d.new(-1.0, 0.0, 0.0)
        yaxis = Geom::Vector3d.new(0.0, -1.0, 0.0)
      when 270
        origin = Geom::Point3d.new(height, y, 0.0)
        xaxis = Geom::Vector3d.new(0.0, 1.0, 0.0)
        yaxis = Geom::Vector3d.new(-1.0, 0.0, 0.0)
      else
        origin = Geom::Point3d.new(0.0, y, 0.0)
        xaxis = Geom::Vector3d.new(1.0, 0.0, 0.0)
        yaxis = Geom::Vector3d.new(0.0, 1.0, 0.0)
      end
      Geom::Transformation.axes(origin, xaxis, yaxis, zaxis)
    end

    def self.apply_and_verify_page_representation_transform(group, media_box,
                                                            scale, rotation,
                                                            y_offset,
                                                            evidence_record = nil)
      expected = page_representation_transform(
        media_box, scale, rotation, y_offset
      )
      return false unless group.respond_to?(:transform!)
      group.transform!(expected)
      return false unless group.respond_to?(:transformation)
      actual = group.transformation
      return false unless actual.respond_to?(:to_a) && expected.respond_to?(:to_a)
      expected_values = expected.to_a
      actual_values = actual.to_a
      return false unless expected_values.length == actual_values.length
      verified = expected_values.each_with_index.all? do |value, index|
        (value.to_f - actual_values[index].to_f).abs <= 1.0e-8
      end
      if verified && evidence_record.is_a?(Hash)
        evidence_record[:source_page_transformation] =
          expected_values.map { |value| value.to_f }
        evidence_record[:page_transform_verified] = true
      end
      verified
    rescue StandardError
      false
    end

    def self.erase_owned_glyph_definitions!(model, definitions)
      doomed = Array(definitions).compact
      return true if doomed.empty?
      collection = model && model.respond_to?(:definitions) ? model.definitions : nil
      raise RepresentationFidelity::ContractError,
            'Glyph definition collection is unavailable for cleanup' unless
        collection && collection.respond_to?(:remove) && collection.respond_to?(:to_a)
      doomed.each do |definition|
        collection.remove(definition) if collection.to_a.include?(definition)
      end
      remaining = collection.to_a
      live = doomed.select { |definition| remaining.include?(definition) }
      raise RepresentationFidelity::ContractError,
            'Owned glyph definition cleanup is unverifiable' unless live.empty?
      true
    rescue RepresentationFidelity::ContractError
      raise
    rescue StandardError => e
      raise RepresentationFidelity::ContractError,
            "Owned glyph definition cleanup failed: #{e.message}"
    end

    def self.normalize_text_renderer_mode(mode)
      case mode.to_s.strip.downcase
      when 'text', 'flat_text', 'editable_text' then :text
      when 'text3d', '3d_text', '3d text', 'add_3d_text' then :text3d
      when 'labels', 'label', 'add_text' then :labels
      when 'glyphs', 'glyph' then :glyphs
      when 'geometry', 'outlines', 'outline' then :geometry
      when 'raster', 'image' then :raster
      else nil
      end
    end

    # Representation changes are fail-closed.  A missing helper, host/API
    # failure, exception, empty artifact, or failed visual check is evidence
    # that this attempt failed; it is not affirmative proof that this source
    # span can never be delivered in the requested representation.
    def self.enforce_requested_text_delivery!(page_num, requested_mode, failures)
      rows = Array(failures)
      return true if rows.empty?

      mode = normalize_text_renderer_mode(requested_mode)
      label = case mode
              when :labels then 'Labels'
              when :text3d then '3D Text'
              when :glyphs then 'Glyphs'
              when :geometry then 'Geometry'
              when :raster then 'Raster'
              else requested_mode.to_s
              end
      details = rows.map do |failure|
        next 'unidentified source span: unreported failure' unless failure.respond_to?(:[])
        source_id = (failure[:source_span_id] || failure['source_span_id']).to_s
        source_id = 'unidentified source span' if source_id.empty?
        reason = (failure[:reason] || failure['reason']).to_s
        reason = 'unreported failure' if reason.empty?
        "#{source_id}: #{reason}"
      end
      raise RepresentationFidelity::ContractError,
            "Page #{page_num}: requested #{label} representation was not " \
            "certified (#{details.join('; ')}); no representation fallback " \
             'is authorized without affirmative, item-specific impossibility evidence.'
    end

    # If the SVG renderer found real glyph placements but neither source
    # extractor produced spans, cleaning the unverifiable page group and then
    # continuing would silently omit detected text. Pages with no detected SVG
    # glyphs remain valid no-text pages; detected-but-unmatched text stops.
    def self.enforce_detected_svg_text_delivery!(page_num, requested_mode,
                                                 failure_info, text_items)
      return true unless Array(text_items).empty?
      info = failure_info.is_a?(Hash) ? failure_info : {}
      detected = info[:detected_svg_placements]
      detected = info['detected_svg_placements'] if detected.nil?
      return true unless detected.to_i > 0

      mode = normalize_text_renderer_mode(requested_mode)
      label = case mode
              when :glyphs then 'Glyphs'
              when :geometry then 'Geometry'
              else requested_mode.to_s
              end
      raise RepresentationFidelity::ContractError,
            "Page #{page_num}: requested #{label} renderer detected " \
            "#{detected.to_i} glyph placement(s), but no certified source " \
             'spans were available; the detected text was not silently omitted.'
    end

    # A zero-span extractor result is only a valid no-text page when the page
    # and its referenced Form XObjects also contain no nonempty PDF text-show
    # operands. This detector does not deliver a substitute representation; it
    # prevents undecodable text from being silently omitted in any text mode.
    def self.enforce_extracted_text_presence!(page_num, requested_mode,
                                              text_items, page_streams,
                                              form_streams)
      return true unless Array(text_items).empty?

      detector_streams = Array(page_streams) + Array(form_streams)
      detected = TextParser.new(
        detector_streams, {}, { strict_text_fidelity: true,
                                merge_text_runs: false }
      ).nonempty_text_show_operation_count
      return true unless detected.to_i > 0

      mode = normalize_text_renderer_mode(requested_mode)
      label = case mode
              when :labels then 'Labels'
              when :text3d then '3D Text'
              when :glyphs then 'Glyphs'
              when :geometry then 'Geometry'
              when :raster then 'Raster'
              else requested_mode.to_s
              end
      raise RepresentationFidelity::ContractError,
            "Page #{page_num}: #{detected.to_i} nonempty PDF text-show " \
            "operation(s) were detected, but requested #{label} had no " \
            'certified source spans; the detected text was not silently omitted.'
    rescue RepresentationFidelity::ContractError
      raise
    rescue StandardError => e
      raise RepresentationFidelity::ContractError,
            "Page #{page_num}: no-text proof failed for requested " \
            "#{requested_mode} (#{e.message}); import stopped instead of " \
            'silently omitting possible text.'
    end

    # Round 20: accumulate faithful mesh-text target heights (inches) for
    # import_report extra.text_height_crosscheck.
    def self.merge_text_height_samples!(stats, samples)
      return unless samples.respond_to?(:each)
      stats[:text_height_samples] ||= []
      samples.each do |h|
        begin
          v = h.to_f
          stats[:text_height_samples] << v if v > 0.0
        rescue StandardError
          next
        end
      end
    rescue StandardError
      nil
    end

    # Round 22: accumulate native 3D text width-fidelity telemetry for
    # import_report extra.text_width_crosscheck (mirrors the height merge).
    def self.merge_text_width_crosscheck!(stats, result)
      return unless result.is_a?(Hash)
      samples = result[:text_width_factor_samples]
      if samples.respond_to?(:each)
        stats[:text_width_factor_samples] ||= []
        samples.each do |f|
          begin
            v = f.to_f
            stats[:text_width_factor_samples] << v if v > 0.0
          rescue StandardError
            next
          end
        end
      end
      stats[:text_width_out_of_bounds_count] =
        stats[:text_width_out_of_bounds_count].to_i +
        result[:text_width_out_of_bounds_count].to_i
      stats[:text_width_skipped_near_1_count] =
        stats[:text_width_skipped_near_1_count].to_i +
        result[:text_width_skipped_near_1_count].to_i
      stats[:text_width_error_count] =
        stats[:text_width_error_count].to_i +
        result[:text_width_error_count].to_i
    rescue StandardError
      nil
    end

    def self.new_import_session_id
      require 'securerandom'
      SecureRandom.uuid
    rescue StandardError
      "su-import-#{Process.pid}-#{Time.now.to_i}"
    end

    def self.embedded_image_output_dir(pdf_path, opts, session_id)
      configured = opts[:embedded_image_dir].to_s.strip
      return configured unless configured.empty?

      base = File.basename(pdf_path.to_s, '.pdf')
      base = 'pdf' if base.empty?
      File.join(Dir.tmpdir, "bc_pdf_embedded_images_#{base}_#{session_id}")
    rescue StandardError
      File.join(Dir.tmpdir, "bc_pdf_embedded_images_#{Process.pid}")
    end

    def self.apply_internal_text_angle_hints(text_items, angle_items)
      return text_items unless text_items && angle_items && !angle_items.empty?

      hints = angle_items.select do |it|
        it && it.text && !it.text.to_s.empty?
      end
      return text_items if hints.empty?

      merged = text_items.map do |item|
        next item unless item && item.text

        hint = nearest_text_angle_hint(item, hints)
        hint ? clone_text_item_with_hints(item, hint) : item
      end
      # pdftotext bbox output has no word element for a whitespace-only source
      # span. Keep those internal semantic spans so downstream delivery either
      # creates the requested representation or records an explicit failure.
      semantic_whitespace = hints.select do |hint|
        normalize_text_key(hint.text).empty?
      end.select do |hint|
        hint.respond_to?(:source_decode_complete) &&
          hint.source_decode_complete == true
      end
      merged + semantic_whitespace
    rescue StandardError => e
      Logger.warn("Pipeline", "apply internal text angle hints failed: #{e.message}")
      text_items
    end

    def self.nearest_text_angle_hint(item, hints)
      text = normalize_text_key(item.text)
      return nil if text.empty?
      ix, iy = text_item_anchor_for_angle(item)
      fs = [item.font_size.to_f, 1.0].max
      threshold = [fs * 2.5, 24.0].max
      best = nil

      hints.each do |hint|
        next unless normalize_text_key(hint.text) == text
        hx, hy = text_item_anchor_for_angle(hint)
        dist = Math.sqrt(((hx - ix) ** 2) + ((hy - iy) ** 2))
        next if dist > threshold
        best = [dist, hint] if best.nil? || dist < best[0]
      end

      best ? best[1] : nil
    rescue StandardError
      nil
    end

    def self.normalize_text_key(text)
      text.to_s.gsub(/\s+/, ' ').strip
    rescue StandardError
      ''
    end

    def self.text_item_anchor_for_angle(item)
      if item.respond_to?(:bbox_x0) && item.bbox_x0 && item.bbox_x1 &&
         item.bbox_y0 && item.bbox_y1
        [
          (item.bbox_x0.to_f + item.bbox_x1.to_f) * 0.5,
          (item.bbox_y0.to_f + item.bbox_y1.to_f) * 0.5
        ]
      else
        [item.x.to_f, item.y.to_f]
      end
    rescue StandardError
      [0.0, 0.0]
    end

    def self.clone_text_item_with_angle(item, angle)
      clone_text_item_with_hints(
        item,
        TextParser::TextItem.new(
          item.text, item.x, item.y, item.font_size, angle,
          item.font_name,
          item.respond_to?(:raw_font_size) ? item.raw_font_size : nil
        )
      )
    rescue StandardError
      item
    end

    # Merge exact internal semantic content, PDF text-matrix origin, nominal
    # size, and angle onto external bbox items. Poppler gives excellent
    # coverage and bboxes; the internal parser keeps the source operand.
    def self.clone_text_item_with_hints(item, hint)
      nominal_size = begin
        v = hint.font_size.to_f
        v > 0.05 ? v : item.font_size
      rescue StandardError
        item.font_size
      end
      clone = TextParser::TextItem.new(
        hint.text,
        hint.x,
        hint.y,
        nominal_size,
        hint.angle.to_f,
        item.font_name,
        hint.respond_to?(:raw_font_size) ? hint.raw_font_size : item.raw_font_size,
        item.respond_to?(:bbox_x0) ? item.bbox_x0 : nil,
        item.respond_to?(:bbox_y0) ? item.bbox_y0 : nil,
        item.respond_to?(:bbox_x1) ? item.bbox_x1 : nil,
        item.respond_to?(:bbox_y1) ? item.bbox_y1 : nil,
        item.respond_to?(:layer_name) ? item.layer_name : nil,
        # Clones keep the source item's span identity (corrective §1).
        item.respond_to?(:source_span_id) ? item.source_span_id : nil
      )
      if clone.respond_to?(:source_decode_complete=)
        complete = hint.respond_to?(:source_decode_complete) ?
          hint.source_decode_complete : nil
        clone.source_decode_complete = complete == true
      end
      clone
    rescue StandardError
      item
    end

    # Auto-mode flood heuristics (mirrors the FreeCAD importer behavior).
    # Catches decorative/map pages that are technically vector paths but are not
    # useful CAD geometry in SketchUp.
    AUTO_FILL_DRAWING_THRESHOLD = 400
    AUTO_FILL_HEAVY_RATIO = 0.60
    AUTO_FILL_STROKE_MAX = 0.22
    AUTO_FILL_PURE_RATIO = 0.95
    AUTO_FILL_PURE_STROKE_MAX = 0.02
    AUTO_FILL_PURE_MIN_GROUPS = 12
    AUTO_FILL_PURE_MIN_ITEMS = 24
    AUTO_FILL_PURE_LARGE_RECT_RATIO = 0.03

    def self.path_bbox(path)
      return nil unless path && path.respond_to?(:subpaths) && path.subpaths
      min_x = nil
      min_y = nil
      max_x = nil
      max_y = nil

      path.subpaths.each do |sp|
        next unless sp && sp.respond_to?(:segments) && sp.segments
        sp.segments.each do |seg|
          next unless seg && seg.respond_to?(:points) && seg.points
          seg.points.each do |pt|
            next unless pt && pt.length >= 2
            x = pt[0].to_f
            y = pt[1].to_f
            min_x = x if min_x.nil? || x < min_x
            min_y = y if min_y.nil? || y < min_y
            max_x = x if max_x.nil? || x > max_x
            max_y = y if max_y.nil? || y > max_y
          end
        end
      end
      return nil if min_x.nil? || min_y.nil? || max_x.nil? || max_y.nil?
      [min_x, min_y, max_x, max_y]
    end

    def self.vector_path_stats(paths, media_box)
      total = paths ? paths.length : 0
      empty = {
        total: 0,
        fill_only_ratio: 0.0,
        stroke_ratio: 0.0,
        fill_only_count: 0,
        stroke_count: 0,
        total_item_count: 0,
        max_rect_ratio: 0.0
      }
      return empty if total <= 0

      page_w = ((media_box[2] || 0).to_f - (media_box[0] || 0).to_f).abs
      page_h = ((media_box[3] || 0).to_f - (media_box[1] || 0).to_f).abs
      page_area = page_w * page_h
      page_area = 0.0 if page_area.nan? || page_area.infinite?

      fill_only = 0
      stroke_count = 0
      total_items = 0
      max_rect_ratio = 0.0

      paths.each do |path|
        has_fill = !!(path && path.fill)
        has_stroke = !!(path && path.stroke)
        fill_only += 1 if has_fill && !has_stroke
        stroke_count += 1 if has_stroke

        if path && path.respond_to?(:subpaths) && path.subpaths
          path.subpaths.each do |sp|
            total_items += sp.segments.length if sp && sp.respond_to?(:segments) && sp.segments
          end
        end

        if page_area > 0.0
          bbox = path_bbox(path)
          if bbox
            w = (bbox[2] - bbox[0]).abs
            h = (bbox[3] - bbox[1]).abs
            ratio = (w * h) / page_area
            max_rect_ratio = ratio if ratio > max_rect_ratio
          end
        end
      end

      {
        total: total,
        fill_only_ratio: fill_only.to_f / total.to_f,
        stroke_ratio: stroke_count.to_f / total.to_f,
        fill_only_count: fill_only,
        stroke_count: stroke_count,
        total_item_count: total_items,
        max_rect_ratio: max_rect_ratio
      }
    end

    def self.looks_like_fill_art_flood?(paths, media_box)
      stats = vector_path_stats(paths, media_box)
      n = stats[:total]
      fill_ratio = stats[:fill_only_ratio]
      stroke_ratio = stats[:stroke_ratio]
      total_items = stats[:total_item_count]
      max_rect_ratio = stats[:max_rect_ratio]

      # Average items per drawing — glyph/fill-art floods have 1-3 items,
      # real drawings (garden plans, floor plans) have many more
      avg_items = n > 0 ? total_items.to_f / n : 0.0

      pure_fill = fill_ratio >= AUTO_FILL_PURE_RATIO &&
                  stroke_ratio <= AUTO_FILL_PURE_STROKE_MAX &&
                  avg_items <= 5.0
      if pure_fill && n >= AUTO_FILL_PURE_MIN_GROUPS
        if total_items >= AUTO_FILL_PURE_MIN_ITEMS ||
           max_rect_ratio >= AUTO_FILL_PURE_LARGE_RECT_RATIO
          return [true, stats]
        end
      end

      if n >= AUTO_FILL_DRAWING_THRESHOLD &&
         fill_ratio >= AUTO_FILL_HEAVY_RATIO &&
         stroke_ratio <= AUTO_FILL_STROKE_MAX &&
         avg_items <= 5.0
        return [true, stats]
      end

      [false, stats]
    end

    def self.fit_ignored_entity?(entity)
      return true unless entity
      return true if defined?(Sketchup::Text) && entity.is_a?(Sketchup::Text)
      return true if defined?(Sketchup::Dimension) && entity.is_a?(Sketchup::Dimension)
      false
    end

    def self.fit_usable_bounds?(bb)
      return false unless bb && bb.valid?
      begin
        dx = (bb.max.x.to_f - bb.min.x.to_f).abs
        dy = (bb.max.y.to_f - bb.min.y.to_f).abs
        dz = (bb.max.z.to_f - bb.min.z.to_f).abs
        (dx + dy + dz) > 1.0e-9
      rescue StandardError
        false
      end
    end

    def self.normalize_page_arrangement(raw)
      key = raw.to_s.strip.downcase
      return :overlay if key.include?("overlay")
      return :touch if key.include?("touch")
      return :compact if key.include?("compact")
      :spread
    end

    def self.normalized_requested_pages(requested, page_count)
      total = page_count.to_i
      return [] if total <= 0
      values = requested == :all ? (1..total).to_a : Array(requested)
      seen = {}
      values.each_with_object([]) do |value, pages|
        page = value.to_i
        next if page < 1 || page > total || seen[page]
        seen[page] = true
        pages << page
      end
    end

    def self.normalize_page_gap_ratio(raw)
      val = begin
        Float(raw)
      rescue StandardError
        0.20
      end
      val = 0.20 unless val.finite?
      [[val, 0.0].max, 1.0].min
    end

    def self.page_stack_step(page_height_in, arrangement, gap_ratio)
      h = page_height_in.to_f
      h = 11.0 if h <= 0.0
      case arrangement
      when :overlay
        0.0
      when :touch
        h
      when :compact
        h * (1.0 + gap_ratio.to_f)
      else
        h * 1.2
      end
    end

    # Add a deterministic page-sized fit box in SketchUp model space.
    # This makes "fit all" resilient even when imported entities contain
    # sparse labels, nested groups, or occasional outlier bounds.
    def self.add_page_fit_bounds(target_bb, media_box, render_box, scale, y_offset, page_rotation = 0)
      return unless target_bb
      return unless media_box.is_a?(Array) && media_box.length >= 4
      return unless render_box.is_a?(Array) && render_box.length >= 4

      s = scale.to_f
      s = 1.0 if s <= 0.0
      oy = y_offset.to_f

      rx0 = render_box[0].to_f
      ry0 = render_box[1].to_f
      rx1 = render_box[2].to_f
      ry1 = render_box[3].to_f

      rb = PageTransform.transform_bbox(rx0, ry0, rx1, ry1, media_box, page_rotation)
      x0 = rb[0] * (1.0 / 72.0) * s
      y0 = rb[1] * (1.0 / 72.0) * s + oy
      x1 = rb[2] * (1.0 / 72.0) * s
      y1 = rb[3] * (1.0 / 72.0) * s + oy

      px0, py0, px1, py1 = ImportBounds.padded_fit_corners(x0, y0, x1, y1, s)
      bb = Geom::BoundingBox.new
      bb.add(Geom::Point3d.new(px0, py0, 0.0))
      bb.add(Geom::Point3d.new(px1, py1, 0.0))
      return unless fit_usable_bounds?(bb)

      target_bb.add(bb)
    rescue StandardError => e
      Logger.warn("Pipeline", "add_page_fit_bounds failed: #{e.message}")
    end

    def self.bb_corners(bb)
      mn = bb.min
      mx = bb.max
      [
        Geom::Point3d.new(mn.x, mn.y, mn.z),
        Geom::Point3d.new(mx.x, mn.y, mn.z),
        Geom::Point3d.new(mn.x, mx.y, mn.z),
        Geom::Point3d.new(mx.x, mx.y, mn.z),
        Geom::Point3d.new(mn.x, mn.y, mx.z),
        Geom::Point3d.new(mx.x, mn.y, mx.z),
        Geom::Point3d.new(mn.x, mx.y, mx.z),
        Geom::Point3d.new(mx.x, mx.y, mx.z)
      ]
    end

    def self.add_bounds_with_transform(target_bb, source_bb, transform = nil)
      return unless fit_usable_bounds?(source_bb)
      if transform
        bb_corners(source_bb).each { |pt| target_bb.add(pt.transform(transform)) }
      else
        target_bb.add(source_bb)
      end
    rescue StandardError
      nil
    end

    # Collect bounds recursively while ignoring text/dimension annotations.
    # This prevents a single outlier label from blowing up fit extents.
    def self.collect_fit_bounds(entity, out_bb, parent_transform = nil, depth = 0)
      return if entity.nil? || !entity.valid?
      return if fit_ignored_entity?(entity)
      return if depth > 12

      if defined?(Sketchup::Group) && entity.is_a?(Sketchup::Group)
        world_t = parent_transform ? (parent_transform * entity.transformation) : entity.transformation
        nested = Geom::BoundingBox.new
        entity.entities.each { |child| collect_fit_bounds(child, nested, world_t, depth + 1) }
        if fit_usable_bounds?(nested)
          out_bb.add(nested)
        end
        return
      end

      if defined?(Sketchup::ComponentInstance) && entity.is_a?(Sketchup::ComponentInstance)
        world_t = parent_transform ? (parent_transform * entity.transformation) : entity.transformation
        nested = Geom::BoundingBox.new
        entity.definition.entities.each { |child| collect_fit_bounds(child, nested, world_t, depth + 1) }
        if fit_usable_bounds?(nested)
          out_bb.add(nested)
        end
        return
      end

      add_bounds_with_transform(out_bb, entity.bounds, parent_transform)
    rescue StandardError
      nil
    end

    def self.apply_camera_top_ortho(view, bb)
      return unless view && fit_usable_bounds?(bb)
      center = bb.center
      dx = (bb.max.x.to_f - bb.min.x.to_f).abs
      dy = (bb.max.y.to_f - bb.min.y.to_f).abs
      height = [dy, 1.0e-6].max
      begin
        if view.respond_to?(:vpwidth) && view.respond_to?(:vpheight)
          vw = view.vpwidth.to_f
          vh = view.vpheight.to_f
          if vw > 0.0 && vh > 0.0
            aspect = vw / vh
            height = [height, dx / aspect].max if aspect > 0.0
          end
        end
      rescue StandardError
        # keep bbox-height fit
      end
      eye_z = [1000.0, height * 10.0].max
      eye = Geom::Point3d.new(center.x, center.y, center.z + eye_z)
      target = center
      up = Geom::Vector3d.new(0, 1, 0)
      camera = Sketchup::Camera.new(eye, target, up)
      camera.perspective = false
      framed = false
      begin
        if camera.respond_to?(:height=)
          camera.height = height
          framed = true
        end
      rescue StandardError
        framed = false
      end
      view.camera = camera
      begin
        view.refresh if view.respond_to?(:refresh)
      rescue StandardError
      end
      framed
    rescue StandardError
      false
    end

    # Zoom to imported geometry only — avoids reframing the whole model.
    def self.zoom_extents_imported_only(model, view, imported_roots)
      roots = Array(imported_roots).select { |e| e && e.valid? }
      return false if roots.empty?

      hidden = []
      begin
        model.active_entities.each do |e|
          next unless e.valid? && e.respond_to?(:visible?)
          next if roots.include?(e)
          next unless e.visible?
          e.visible = false
          hidden << e
        end
        view.zoom_extents
        true
      rescue StandardError
        false
      ensure
        hidden.each do |e|
          begin
            e.visible = true if e.valid?
          rescue StandardError
            next
          end
        end
      end
    end

    def self.apply_top_view_fit(model, preferred_bb = nil, imported_entities = nil)
      return unless model
      view = model.active_view
      return unless view

      preferred_valid = fit_usable_bounds?(preferred_bb)
      bb = Geom::BoundingBox.new
      bb.add(preferred_bb) if preferred_valid

      fit_targets = []
      unless fit_usable_bounds?(bb)
        targets = Array(imported_entities)
        if targets.empty?
          begin
            targets = model.active_entities.to_a
          rescue StandardError
            targets = []
          end
        end

        fit_targets = targets.select do |e|
          next false unless e && e.valid? && e.respond_to?(:bounds)
          next false if fit_ignored_entity?(e)
          fit_usable_bounds?(e.bounds)
        end

        # If a page only produced label entities, still fit to what was imported.
        if fit_targets.empty?
          fit_targets = targets.select do |e|
            e && e.valid? && e.respond_to?(:bounds) && fit_usable_bounds?(e.bounds)
          end
        end
        fit_targets.each { |e| collect_fit_bounds(e, bb) }
      end

      fit_entities = Array(imported_entities).select { |e| e && e.valid? }
      if fit_entities.empty?
        fit_entities = fit_targets
      end

      framed = false
      if fit_usable_bounds?(bb)
        framed = apply_camera_top_ortho(view, bb)
        unless framed
          begin
            view.zoom(bb)
            framed = true
          rescue StandardError
            framed = false
          end
        end
      end

      # Entity zoom is a fallback when page/geometry bounds zoom failed.
      # Do not run after a successful bounds zoom — entity bounds ignore
      # annotation text and can reframe to a corner clump of edges only.
      unless framed
        unless preferred_valid || fit_entities.empty?
          begin
            view.zoom(fit_entities)
            framed = true
          rescue StandardError
          end
        end
      end

      unless framed
        framed = zoom_extents_imported_only(model, view, fit_entities)
      end

      # Last resort: model-wide extents when we have no import bounds at all.
      view.zoom_extents unless framed
    rescue StandardError => e
      Logger.warn("Pipeline", "Auto-fit view failed: #{e.message}")
      begin
        if view && zoom_extents_imported_only(model, view, Array(imported_entities))
          return
        end
        view.zoom_extents if view
      rescue StandardError
      end
    end

    def self.import_contract_ready?(stats)
      contract = stats[:import_contract_ready]
      return contract if contract == true || contract == false
      return false unless contract.is_a?(Hash)
      contract[:ready] == true || contract['ready'] == true
    end

    def self.record_source_lineage!(stats, source_path, normalized_path,
                                    salvage_note, opts = {})
      raise RepresentationFidelity::ContractError,
            'source-lineage stats are unavailable' unless stats.is_a?(Hash)
      provided = opts.is_a?(Hash) ? opts[:source_lineage] : nil
      provided = {} unless provided.is_a?(Hash)
      lineage = {}
      provided.each do |key, value|
        normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
        lineage[normalized_key] = value
      end

      immutable_path = File.expand_path(source_path.to_s)
      normalized = File.expand_path(normalized_path.to_s)
      immutable_sha256 = Digest::SHA256.file(immutable_path).hexdigest
      normalized_sha256 = Digest::SHA256.file(normalized).hexdigest
      declared_immutable_sha256 = lineage[:immutable_pdf_sha256].to_s
      unless declared_immutable_sha256.empty? ||
             declared_immutable_sha256 == immutable_sha256
        raise RepresentationFidelity::ContractError,
              'immutable source lineage SHA256 differs from imported bytes'
      end

      lineage[:original_pdf_path] ||= immutable_path
      lineage[:original_pdf_sha256] ||= immutable_sha256
      lineage[:immutable_pdf_path] = immutable_path
      lineage[:immutable_pdf_sha256] = immutable_sha256
      lineage[:normalized_pdf_path] = normalized
      lineage[:normalized_pdf_sha256] = normalized_sha256
      lineage[:salvage_note] = salvage_note
      stats[:source_lineage] = lineage
      stats[:source_input_path] = immutable_path
      stats[:source_input_sha256] = immutable_sha256
      stats[:normalized_input_path] = normalized
      stats[:normalized_input_sha256] = normalized_sha256
      stats[:salvage_note] = salvage_note
      lineage
    end

    def self.finalize_import_diagnostics!(path, opts, stats)
      report = QAReport.build_from_stats(path, opts, stats)
      parts_payload = report[:extra] && report[:extra][:parts_bootstrap]
      if parts_payload && parts_payload[:row_count].to_i > 0
        report_target = QAReport.default_output_path(path)
        sidecar_base = File.join(
          File.dirname(report_target),
          File.basename(path.to_s, File.extname(path.to_s))
        )
        parts_path = PartsBootstrap.write_sidecar(parts_payload, sidecar_base)
        if parts_path
          parts_payload[:sidecar_path] = parts_path
          report[:extra][:parts_bootstrap] = parts_payload
          stats[:parts_bootstrap_sidecar_path] = parts_path
        end
      end
      extra = report[:extra] || {}
      stats[:human_summary] = extra[:human_summary]
      stats[:scale_crosscheck] = extra[:scale_crosscheck]
      stats[:performance_hint] = extra[:performance_hint]
      stats[:actual_text_entity_types] = extra[:actual_text_entity_types]
      stats[:model_3d_intent] = extra[:model_3d_intent]
      stats[:representation_fidelity] = extra[:representation_fidelity] ||
        extra['representation_fidelity'] || { :ready => false }
      stats[:import_contract_ready] = extra[:import_contract_ready] ||
        extra['import_contract_ready'] || { :ready => false }
      report_path = QAReport.write_json(report, QAReport.default_output_path(path))
      stats[:import_report_path] = report_path if report_path
      sidecar_path = write_source_provenance_sidecar(path, opts, stats)
      stats[:source_provenance_sidecar_path] = sidecar_path if sidecar_path
      ImportHealth.record!(stats, path)
      stats[:import_contract_ready]
    rescue StandardError => e
      stats[:import_contract_ready] = {
        :ready => false,
        :checks => { :diagnostics_generated => false },
        :errors => ["diagnostics_error:#{e.class}:#{e.message}"]
      }
      Logger.error('Pipeline', "import diagnostics failed: #{e.message}", e)
      stats[:import_contract_ready]
    end

    def self.run_forced_raster_pipeline(model, path, opts)
      dpi = opts[:raster_dpi] || 300
      Logger.info('Pipeline', "Explicit Raster mode at #{dpi} DPI")
      parser = PDFParser.new(path)
      parser.parse
      if parser.page_count.to_i <= 0
        raise RepresentationFidelity::ContractError,
              'PDF parser returned zero pages; Raster delivery is impossible.'
      end

      pages = normalized_requested_pages(opts[:pages], parser.page_count)
      if pages.empty?
        raise RepresentationFidelity::ContractError,
              'No valid selected PDF pages remain for Raster delivery.'
      end

      pre_import_entities = model.active_entities.to_a
      import_start = Time.now
      page_fit_bounds = Geom::BoundingBox.new
      arrangement = normalize_page_arrangement(opts[:page_arrangement])
      gap_ratio = normalize_page_gap_ratio(opts[:page_gap_ratio])
      running_y_offset = 0.0
      operation_open = false
      stats = {
        :pages => 0, :primitives => 0, :edges => 0, :faces => 0,
        :arcs => 0, :text => 0, :components => 0, :layers => [],
        :cleanup => {}, :generic => nil, :mode_used => :raster,
        :xobjects => 0, :embedded_images => 0,
        :embedded_images_placed => 0, :embedded_image_paths => [],
        :embedded_image_dir => nil, :extruded_faces => 0,
        :text_mode => :raster, :requested_text_mode => :raster,
        :selected_pages => pages.dup,
        :match_pdf_layers => false,
        :text_renderers => [], :page_text_sources => {}, :peak_mb => 0.0,
        :model_3d_texts => [], :page_text_map => {},
        :recognition_skipped_pages => [],
        :import_session_id => new_import_session_id,
        :source_provenance_objects => [], :text_source_span_ids => [],
        :text_attempts => [], :page_text_delivery_records => [],
        :terminal_text_delivery_records => [],
        :terminal_cleanup_events => [], :fallback_transitions => [],
        :page_representation_fallbacks => [],
        :empty_page_source_inspections => [],
        :representation_ownership_group_forced_pages => [],
        :source_glyph_physical_deliveries => [],
        :raster_delivery_records => [], :raster_fallback_used => false
      }
      record_source_lineage!(stats, path, path, nil, opts)

      model.start_operation('Import PDF Raster', true)
      operation_open = true
      pages.each_with_index do |page_num, index|
        raw = parser.page_data(page_num)
        unless raw.is_a?(Hash)
          raise RepresentationFidelity::ContractError,
                "Page #{page_num}: parser returned no page data for Raster delivery."
        end
        media_box = raw[:media_box]
        media_box = [0, 0, 612, 792] unless
          media_box.is_a?(Array) && media_box.length >= 4
        crop_box = raw[:crop_box]
        crop_box = nil unless crop_box.is_a?(Array) && crop_box.length >= 4
        render_box = crop_box || media_box
        page_rotation = PageTransform.normalize_rotation(raw[:rotation])
        pct = pages.length > 1 ?
          " (#{((index.to_f / pages.length) * 100).round}%)" : ''
        Sketchup.status_text =
          "PDF Raster Import#{pct} — Page #{page_num}/#{parser.page_count}"

        raster = verified_raster_entity!(
          model, path, page_num, media_box, opts, import_start,
          running_y_offset, render_box, page_rotation
        )
        artifact_evidence = raster[:artifact_evidence]
        record = {
          :page => page_num,
          :source_span_ids => [],
          :requested_mode => :raster,
          :delivered_mode => :raster,
          :resulting_entity_ids => [raster[:entity_id]],
          :created_entity_type => 'raster_image',
          :real_raster_verified => true,
          :visual_fidelity_verified => true,
          :artifact_evidence => artifact_evidence,
          :cleanup_outcome => :not_required,
          :delivery_scope => :page_raster,
          :delivery_basis => :explicit_full_page_raster,
          :full_page_raster_request => true,
          :semantic_text_evaluated => false,
          :explicit_request => true,
          :degraded => false
        }
        stats[:terminal_text_delivery_records] << record
        stats[:raster_delivery_records] << record.dup
        record_text_renderer(
          stats, page_num,
          :renderer => :pdftocairo_real_raster,
          :mode => :raster,
          :requested_mode => :raster,
          :delivered_mode => :raster,
          :degraded => false,
          :count => 1,
          :resulting_entity_ids => [raster[:entity_id]],
          :real_raster_verified => true,
          :artifact_evidence => artifact_evidence
        )
        add_page_fit_bounds(
          page_fit_bounds, media_box, render_box, opts[:scale],
          running_y_offset, page_rotation
        )
        _display_width, display_height = raster_display_dimensions(
          render_box, page_rotation
        )
        scale = opts[:scale].to_f
        scale = 1.0 if scale <= 0.0
        height_in = display_height.to_f * (1.0 / 72.0) * scale
        running_y_offset += page_stack_step(height_in, arrangement, gap_ratio)
        stats[:pages] += 1
      end

      # Raster page caches are importer-owned evidence artifacts.  They must be
      # gone before the model transaction becomes durable; an ensure-only
      # cleanup would report a failure after commit, when rollback is too late.
      cleanup_item_raster_page_cache!(opts)
      verify_cached_source_pdf_bindings!(opts)
      model.commit_operation
      operation_open = false
      stats[:elapsed_seconds] = (Time.now - import_start).round(1)
      stats[:log_path] = Logger.log_path
      imported_entities = model.active_entities.to_a - pre_import_entities
      apply_top_view_fit(model, page_fit_bounds, imported_entities)
      finalize_import_diagnostics!(path, opts, stats)
      ready = import_contract_ready?(stats)
      Sketchup.status_text = if ready
        "PDF Raster Import complete — #{stats[:pages]} page(s) — " \
          "#{stats[:elapsed_seconds]}s"
      else
        "PDF Raster Import finished, but QA contract is NOT READY — " \
          "#{stats[:pages]} page(s)"
      end
      stats
    rescue StandardError => e
      safe_abort_operation(model, 'Raster Pipeline') if operation_open
      raise e
    ensure
      begin
        parser.release if parser
      rescue StandardError => e
        Logger.warn('Raster Pipeline', "parser.release failed: #{e.message}")
      end
    end

    def self.run_pipeline(model, path, opts)
      Logger.reset
      config = RecognitionConfig.default
      source_input_path = path

      # ── Explicit Raster request: deliver verified images for every selected
      # page. This is a requested representation, not a fallback. ──
      if opts[:force_raster]
        return run_forced_raster_pipeline(model, path, opts)
      end

      # ── File size warning for very large PDFs ──
      begin
        file_size_bytes = File.size(path)
        if file_size_bytes > BatchHostPolicy::LARGE_PDF_BYTES
          size_mb = (file_size_bytes / (1024.0 * 1024.0)).round(1)
          choice = BatchHostPolicy.confirm_large_pdf!(file_size_bytes) do
            UI.messagebox(
              "This PDF is very large (#{size_mb} MB). Import may take a significant " \
              "amount of time and use considerable memory. Continue?",
              MB_OKCANCEL)
          end
          return nil unless choice == IDOK
        end
      rescue BatchHostPolicy::NoninteractiveError
        raise
      rescue StandardError => e
        Logger.warn("Pipeline", "File size check failed: #{e.message}")
      end

      # Round 18: encrypted (empty-password) and damaged-xref files are
      # normalized through poppler before the strict internal parser sees
      # them, so "any PDF type" imports instead of failing or degrading.
      salvage_note = nil
      begin
        path, salvage_note = PdfSalvage.prepare_if_needed(path)
      rescue PdfSalvage::SalvageError => e
        BatchHostPolicy.handle_salvage_error!(e) do |failure|
          UI.messagebox(failure.message)
        end
        return nil
      rescue StandardError => e
        Logger.warn("Pipeline", "salvage preflight failed: #{e.message}")
      end
      Logger.info("Pipeline", salvage_note) if salvage_note

      parser = PDFParser.new(path)
      parser.parse
      if parser.page_count == 0
        Logger.warn(
          'Pipeline',
          'PDF parser returned zero pages; stopping without raster substitution.'
        )
        raise RepresentationFidelity::ContractError,
              'PDF parser returned zero pages; requested representation was not changed.'
      end

      ocg = OCGParser.new(parser)
      ocg.parse

      pages = opts[:pages]
      pages = (1..parser.page_count).to_a if pages == :all
      pages = pages.select { |p| p >= 1 && p <= parser.page_count }
      return nil if pages.empty?

      # Track new entities in the currently active editing context.
      # Using model.entities misses imports done while editing groups/components.
      pre_import_entities = model.active_entities.to_a
      model.start_operation("Import PDF Vectors", true)

      # Reset ID counter once at the start of a multi-page import
      IDGen.reset

      match_pdf_layers = opts[:match_pdf_layers] != false
      layer_mgr = LayerManager.new(model,
        base_layer_name: opts[:layer_name] || 'PDF Import',
        match_pdf_layers: match_pdf_layers)
      layer_mgr.precreate_pdf_layers(ocg.layer_list)
      layer_mgr.register_imported_names!

      requested_text_mode = opts[:text_mode]
      requested_text_mode ||= (opts[:use_3d_text] ? :text3d : (opts[:import_text] ? :geometry : :none))
      requested_text_mode = :none unless opts[:import_text]
      initialize_item_raster_import_cache!(opts, opts[:import_text])

      stats = { pages: 0, primitives: 0, edges: 0, faces: 0, arcs: 0,
                text: 0, components: 0, layers: [], cleanup: {},
                generic: nil, mode_used: nil, xobjects: 0, embedded_images: 0,
                embedded_images_placed: 0, embedded_image_paths: [],
                embedded_image_dir: nil, extruded_faces: 0,
                text_mode: requested_text_mode,
                requested_text_mode: requested_text_mode,
                selected_pages: pages.dup,
                match_pdf_layers: match_pdf_layers,
                text_renderers: [], page_text_sources: {}, peak_mb: 0.0,
                model_3d_texts: [], page_text_map: {},
                recognition_skipped_pages: [],
                import_session_id: new_import_session_id,
                 source_provenance_objects: [], text_source_span_ids: [],
                 text_attempts: [], page_text_delivery_records: [],
                 terminal_text_delivery_records: [],
                 terminal_cleanup_events: [], fallback_transitions: [],
                 page_representation_fallbacks: [],
                 empty_page_source_inspections: [],
                 representation_ownership_group_forced_pages: [],
                 source_glyph_physical_deliveries: [],
                 raster_delivery_records: [],
                 raster_fallback_used: false }
      record_source_lineage!(
        stats, source_input_path, path, salvage_note, opts
      )

      image_extractor = nil
      if opts[:extract_embedded_images] != false && opts[:import_mode].to_s != 'vector'
        stats[:embedded_image_dir] = embedded_image_output_dir(path, opts, stats[:import_session_id])
        image_extractor = EmbeddedImageExtractor.new(parser, stats[:embedded_image_dir])
      end

      page_fit_bounds = Geom::BoundingBox.new

      import_start = Time.now
      page_arrangement = normalize_page_arrangement(opts[:page_arrangement])
      page_gap_ratio = normalize_page_gap_ratio(opts[:page_gap_ratio])
      running_y_offset = 0.0

      pages.each_with_index do |page_num, idx|
       begin
        pct = pages.length > 1 ? " (#{((idx.to_f / pages.length) * 100).round}%)" : ""
        elapsed = (Time.now - import_start).round(1)

        Sketchup.status_text = "PDF Import#{pct} — Page #{page_num}/#{parser.page_count} — Parsing... [#{elapsed}s]"

        raw = parser.page_data(page_num)
        unless raw
          raise RepresentationFidelity::ContractError,
                "Page #{page_num}: parser returned no page data; requested " \
                'representation was not changed.'
        end
        media_box = raw[:media_box] || [0, 0, 612, 792]
        page_rotation = PageTransform.normalize_rotation(raw[:rotation])
        crop_box = raw[:crop_box]
        crop_box = nil unless crop_box.is_a?(Array) && crop_box.length >= 4
        svg_page_box = crop_box || media_box
        text_offset_x = svg_page_box[0].to_f - media_box[0].to_f
        text_offset_y = svg_page_box[1].to_f - media_box[1].to_f
        Logger.info("Pipeline",
          "Page #{page_num}: text_mode=#{requested_text_mode}, media_box=#{media_box.inspect}, " \
          "crop_box=#{crop_box ? crop_box.inspect : 'nil'}, rotation=#{page_rotation}, " \
          "text_offset_pts=(#{text_offset_x.round(3)},#{text_offset_y.round(3)})")
        stack_box = svg_page_box
        source_svg_document = nil
        flat_text_fallbacks = {}
        curr_page_height_in = PageTransform.effective_height(stack_box, page_rotation) * (1.0 / 72.0) * opts[:scale].to_f
        curr_page_height_in = 11.0 * opts[:scale].to_f if curr_page_height_in <= 0.0
        page_y_offset = running_y_offset
        streams = raw[:content_streams]
        if streams.nil? || streams.empty?
          raise RepresentationFidelity::ContractError,
                "Page #{page_num}: parser returned no content streams; " \
                'requested representation was not changed.'
        end

        Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Reading paths... [#{elapsed}s]"
        ocg_map = parser.page_ocg_map(page_num)
        cs = ContentStreamParser.new(streams, parser, ocg_map)
        paths = cs.parse
        force_import_fills_for_page = false

        # Diagnostic only. Content-density heuristics may never substitute a
        # requested representation before its item/page renderer is attempted.
        flood_hit, flood_stats = looks_like_fill_art_flood?(paths, media_box)
        if flood_hit
          fill_pct = (flood_stats[:fill_only_ratio] * 100.0).round
          stroke_pct = (flood_stats[:stroke_ratio] * 100.0).round
          Logger.warn(
            "Pipeline",
            "Page #{page_num}: fill-art density warning — " \
            "#{flood_stats[:total]} groups, fill-only=#{fill_pct}%, " \
            "strokes=#{stroke_pct}% (map/decorative PDF — vectors would be unusable geometry)"
          )
          Logger.warn('Pipeline',
                      "Page #{page_num}: preserving the requested vector/text representation; no heuristic raster substitution was made.")
        end

        xobj = XObjectParser.new(parser)
        xobj.scan_page(page_num)
        xobj.count_references(streams)
        xobj_paths = xobj.expanded_paths(streams)
        if xobj_paths && !xobj_paths.empty?
          paths += xobj_paths
          Logger.info("Pipeline",
            "Page #{page_num}: merged #{xobj_paths.length} transformed XObject path group(s).")
        end

        embedded_assets = []
        if image_extractor
          embedded_assets = image_extractor.extract_page(page_num)
          unless embedded_assets.empty?
            stats[:embedded_images] += embedded_assets.length
            stats[:embedded_image_paths].concat(embedded_assets.map { |asset| asset.file_path }.compact)
            Logger.info(
              "EmbeddedImages",
              "Page #{page_num}: extracted #{embedded_assets.length} embedded image placement(s)."
            )
          end
        end

        stream_bytes = streams.inject(0) { |sum, s| sum + s.length }
        text_items = []
        if opts[:import_text]
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Extracting text... [#{(Time.now - import_start).round(1)}s]"
          strict_text_fidelity = !!opts[:strict_text_fidelity]
          text3d_mode = (requested_text_mode == :text3d)
          strict_text_processing = strict_text_fidelity
          # Geometry/Labels/3D Text favor external bbox extraction for maximum visible
          # text coverage and shared placement heuristics. Internal parsing remains
          # for strict modes or when external extraction returns nothing.
          prefer_internal_text = strict_text_processing
          # Guard: skip internal parsing for very large streams (>5MB total).
          # The internal Ruby parser is too slow for monster PDFs like GIS maps.
          # Fall through to external pdftotext which handles them efficiently.
          stream_limit_mb = text3d_mode ? 24.0 : 5.0
          env_limit = ENV['BC_SU_INTERNAL_TEXT_MAX_MB']
          if env_limit && !env_limit.to_s.strip.empty?
            begin
              parsed_limit = env_limit.to_f
              stream_limit_mb = parsed_limit if parsed_limit > 0.0
            rescue StandardError
              # keep default threshold
            end
          end
          stream_limit_bytes = (stream_limit_mb * 1_000_000.0).to_i
          if stream_bytes > stream_limit_bytes
            Logger.warn("Pipeline",
              "Page #{page_num}: #{(stream_bytes / 1_000_000.0).round(1)}MB streams " \
              "(limit #{stream_limit_mb.round(1)}MB) — using external text extractor")
            prefer_internal_text = false
          end
          if prefer_internal_text
            font_maps = parser.page_font_maps(page_num)
            parser_opts = { strict_text_fidelity: strict_text_processing }
            # For 3D text, preserving native spans avoids accidental
            # concatenation/offset caused by run-merge heuristics.
            parser_opts[:merge_text_runs] = false if requested_text_mode == :text3d
            text_items = TextParser.new(streams, font_maps, parser_opts, ocg_map).parse
            text_source = :internal
            if text_items.nil? || text_items.empty?
              text_items = ExternalTextExtractor.extract(path, page_num,
                offset_x_pts: text_offset_x, offset_y_pts: text_offset_y,
                strict_text_fidelity: strict_text_processing)
              text_source = :external
            end
          else
            text_items = ExternalTextExtractor.extract(path, page_num,
              offset_x_pts: text_offset_x, offset_y_pts: text_offset_y,
              strict_text_fidelity: strict_text_processing)
            text_source = :external
            if text_items.nil? || text_items.empty?
              font_maps = parser.page_font_maps(page_num)
              parser_opts = { strict_text_fidelity: strict_text_processing }
              parser_opts[:merge_text_runs] = false if requested_text_mode == :text3d
              text_items = TextParser.new(streams, font_maps, parser_opts, ocg_map).parse
              text_source = :internal
            end
          end
          if text_source == :external && text_items && !text_items.empty? &&
             stream_bytes <= stream_limit_bytes
            begin
              angle_font_maps = defined?(font_maps) && font_maps ? font_maps : parser.page_font_maps(page_num)
              angle_items = TextParser.new(
                streams,
                angle_font_maps,
                { strict_text_fidelity: true, merge_text_runs: false },
                ocg_map
              ).parse
              text_items = apply_internal_text_angle_hints(text_items, angle_items)
            rescue StandardError => e
              Logger.warn("Pipeline", "Page #{page_num}: internal text angle hints unavailable: #{e.message}")
            end
          end
          # Corrective 2026-07-12 §1 (RB-01): assign deterministic source-span
          # identity ONCE per page — after final extractor selection, merging,
          # and angle-hint replacement above, and BEFORE stats[:page_text_map]
          # (PartsBootstrap input) and GeometryBuilder consume the SAME item
          # objects below. This is what makes parts_bootstrap row span_ids and
          # source_provenance span_id join.
          TextSourceIdentity.assign!(text_items, page_num)
          TextSourceIdentity.validate!(text_items, page_num)
          stats[:text_source_span_ids].concat(
            Array(text_items).map { |item| item.source_span_id.to_s }
          )
          Logger.info("Pipeline", "Page #{page_num}: text extractor=#{text_source}, items=#{text_items ? text_items.length : 0}")
          stats[:page_text_sources][page_num] = text_source if text_source
          stats[:page_text_map][page_num] = text_items if text_items && !text_items.empty?
          Array(text_items).each do |item|
            raw_text = if item.respond_to?(:text)
                         item.text
                       elsif item.is_a?(Hash)
                         item[:text] || item['text']
                       else
                         item
                       end
            raw_text = raw_text.to_s.strip
            stats[:model_3d_texts] << raw_text unless raw_text.empty?
          end
        end

        if requested_text_mode == :text && !Array(text_items).empty?
          flat_text_fallbacks =
            prepare_flat_text_fallback_controllers!(text_items)
        end

        if opts[:import_text] && Array(text_items).empty?
          referenced_form_streams = xobj.form_xobjects.values.select do |form|
            form.respond_to?(:usage_count) && form.usage_count.to_i > 0
          end.map do |form|
            form.respond_to?(:stream_data) ? form.stream_data : nil
          end.compact
          enforce_extracted_text_presence!(
            page_num, requested_text_mode, text_items, streams,
            referenced_form_streams
          )
          record_empty_page_source_inspection!(stats, page_num, {
            :semantic_text_extraction_complete => true,
            :decoded_stream_text_operators => false,
            :decoded_form_stream_text_operators => false,
            :embedded_image_asset_count => Array(embedded_assets).length,
            :embedded_image_placed_count => 0
          })
        end

        if svg_renderer_required_for_page?(
          requested_text_mode, opts[:import_text], text_items, false
        )
          enforce_svg_renderer_available!(model, stats, requested_text_mode)
        end

        explicit_zero_canonical_page_raster =
          requested_zero_canonical_page_raster?(
            requested_text_mode, opts[:import_text], text_items
          )
        if empty_requested_page_artifacts?(paths, text_items, embedded_assets) ||
           explicit_zero_canonical_page_raster
          if svg_renderer_required_for_page?(
            requested_text_mode, opts[:import_text], text_items, true
          )
            enforce_svg_renderer_available!(model, stats, requested_text_mode)
          end
          svg_failure = {}
          use_cropbox = crop_box && crop_box.zip(media_box).any? do |a, b|
            (a.to_f - b.to_f).abs > 0.01
          end
          source_svg_document = CairoGlyphSource.render_page_svg(
            path, page_num,
            :failure_info => svg_failure,
            :use_cropbox => use_cropbox == true
          )
          if source_svg_document &&
             source_svg_document[:svg].to_s.length > 0
            source_summary = svg_page_source_summary(
              source_svg_document[:svg], media_box,
              :svg_page_box => svg_page_box
            )
          elsif explicit_zero_canonical_page_raster
            reason = svg_failure[:reason].to_s
            reason = 'source_svg_inspection_failed' if reason.empty?
            source_summary = {
              :source_glyph_placements => 0,
              :visible_nontext_source =>
                (!Array(paths).empty? || !Array(embedded_assets).empty?),
              :inspection_error => reason
            }
          else
            reason = svg_failure[:reason].to_s
            reason = 'source_svg_inspection_failed' if reason.empty?
            raise RepresentationFidelity::ContractError,
                  "Page #{page_num}: no requested-representation artifacts " \
                  "were certified and source inspection failed: #{reason}"
          end
          record_empty_page_source_inspection!(stats, page_num,
            source_summary.merge(
            :semantic_text_extraction_complete => true,
            :decoded_stream_text_operators => false,
            :decoded_form_stream_text_operators => false,
            :embedded_image_asset_count => Array(embedded_assets).length,
            :embedded_image_placed_count => 0
          ))

          if requested_text_mode == :text3d &&
             source_summary[:source_glyph_placements].to_i > 0
            Logger.info(
              'Pipeline',
              "Page #{page_num}: semantic extraction found no text, but " \
              "#{source_summary[:source_glyph_placements]} exact SVG source " \
              'glyph placement(s) remain eligible for 3D Text.'
            )
          elsif explicit_zero_canonical_page_raster ||
                source_summary[:visible_nontext_source] == true
            raster = verified_raster_entity!(
              model, path, page_num, media_box, opts, import_start,
              page_y_offset, svg_page_box, page_rotation
            )
            stats[:pages] += 1
            stats[:xobjects] += xobj.form_xobjects.length
            stats[:mode_used] = :raster
            explicit_page_raster = requested_text_mode == :raster
            stats[:raster_fallback_used] = true unless explicit_page_raster
            stats[:text_mode] = :raster unless requested_text_mode == :none
            unless explicit_page_raster
              stats[:page_representation_fallbacks] << {
                :page => page_num,
                :scope => :page,
                :reason_code => :visible_nontext_source_only,
                :affirmative_impossibility => true,
                :requested_text_mode => requested_text_mode,
                :source_text_items => 0,
                :canonical_text_item_count => 0,
                :source_page_number => page_num,
                :immutable_pdf_sha256 => stats[:source_input_sha256],
                :rendered_pdf_sha256 => stats[:normalized_input_sha256],
                :embedded_image_asset_count => Array(embedded_assets).length,
                :embedded_image_placed_count => 0,
                :source_summary => source_summary,
                :delivered_mode => :raster,
                :resulting_entity_ids => [raster[:entity_id]],
                :real_raster_verified => true,
                :visual_fidelity_verified => true
              }
            end
            unless requested_text_mode == :none
              stats[:terminal_text_delivery_records] << {
                :page => page_num,
                :source_span_ids => [],
                :requested_mode => requested_text_mode,
                :delivered_mode => :raster,
                :no_semantic_text => true,
                :delivery_basis => :verified_zero_canonical_text,
                :semantic_text_evaluated => true,
                :canonical_text_item_count => 0,
                :source_page_number => page_num,
                :immutable_pdf_sha256 => stats[:source_input_sha256],
                :rendered_pdf_sha256 => stats[:normalized_input_sha256],
                :resulting_entity_ids => [raster[:entity_id]],
                :created_entity_type => 'raster_image',
                :real_raster_verified => true,
                :visual_fidelity_verified => true,
                :artifact_evidence => raster[:artifact_evidence],
                :cleanup_outcome => :not_required,
                :delivery_scope => :page_raster,
                :explicit_request => explicit_page_raster,
                :degraded => !explicit_page_raster
              }
              stats[:raster_delivery_records] <<
                stats[:terminal_text_delivery_records].last.dup
              record_text_renderer(
                stats, page_num,
                :renderer => :pdftocairo_real_raster,
                :mode => :raster,
                :requested_mode => requested_text_mode,
                :delivered_mode => :raster,
                :degraded => !explicit_page_raster,
                :reason => explicit_page_raster ?
                  'explicit requested page Raster for a zero-canonical-text page' :
                  'visible page source has no semantic or exact source-glyph text representation',
                :count => 0,
                :resulting_entity_ids => [raster[:entity_id]],
                :real_raster_verified => true
              )
            end
            add_page_fit_bounds(
              page_fit_bounds, media_box, stack_box, opts[:scale],
              page_y_offset, page_rotation
            )
            running_y_offset += page_stack_step(
              curr_page_height_in, page_arrangement, page_gap_ratio
            )
            next
          else
            detail = source_summary[:inspection_error].to_s
            detail = 'renderer SVG contains no visible source material' if detail.empty?
            raise RepresentationFidelity::ContractError,
                  "Page #{page_num}: no requested-representation artifacts " \
                  "were certified (#{detail})."
          end
        end

        Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — #{paths.length} paths, #{text_items.length} text items... [#{(Time.now - import_start).round(1)}s]"

        page_data = PrimitiveExtractor.extract(paths, text_items, media_box, page_num,
          scale: opts[:scale], bezier_segments: opts[:bezier_segments],
          page_rotation: page_rotation)
        page_data.layers = ocg.layer_list
        page_data.xobject_names = xobj.form_xobjects.keys
        stats[:primitives] += page_data.primitives.length
        stats[:resolved_scale] = ResolvedScaleDetect.merge_best(
          stats[:resolved_scale],
          ResolvedScaleDetect.resolve(page_data)
        )
        stats[:pages] += 1
        stats[:xobjects] += xobj.form_xobjects.length

        recog_mode = opts[:recognition_mode] || :auto
        recognition = nil
        if recog_mode == :auto && heavy_auto_recognition_skip?(page_data, paths, stream_bytes)
          stats[:mode_used] = :none
          skip = {
            page: page_num,
            reason: 'heavy_page',
            primitives: page_data.primitives.length,
            paths: paths.length,
            stream_mb: (stream_bytes.to_f / 1_000_000.0).round(1)
          }
          stats[:recognition_skipped_pages] << skip
          Logger.warn("Pipeline",
            "Page #{page_num}: skipped auto recognition for heavy page " \
            "(#{skip[:primitives]} primitives, #{skip[:paths]} paths, #{skip[:stream_mb]}MB streams); " \
            "vector/text import continues.")
        elsif recog_mode != :none
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Analyzing document... [#{(Time.now - import_start).round(1)}s]"
          recognition = Recognizer.run(page_data, mode: recog_mode, config: config)
          stats[:mode_used] = recognition[:mode_used]
          if recognition[:generic]
            g = recognition[:generic]
            stats[:generic] = {
              circles: g.circles.length, boundaries: g.closed_boundaries.length,
              patterns: g.repeated_patterns.length, tables: g.tables.length,
              title_block: g.title_block_bbox ? true : false,
              dimensions: g.dimension_assocs.length,
              profile: g.page_profile.primary_type }
          end
        end

        # ── Complexity warning for very large pages ──
        total_subpaths = paths.inject(0) { |sum, p| sum + p.subpaths.length }
        if paths.length > 5000 || total_subpaths > 10000
          Logger.warn("Pipeline",
            "Page #{page_num}: heavy page (#{paths.length} paths, " \
            "#{total_subpaths} subpaths). Import may take several minutes.")
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Heavy page: #{paths.length} paths (this may take a while)... [#{(Time.now - import_start).round(1)}s]"
        else
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Building #{paths.length} paths... [#{(Time.now - import_start).round(1)}s]"
        end

        # ── Hatch detection ──
        hatch_mode = opts[:hatch_mode] || :import
        hatch_paths = []
        if hatch_mode != :import && paths.length > 20
          hatch_indices = HatchDetector.detect(page_data.primitives)
          if hatch_indices && !hatch_indices.empty?
            hatch_set = hatch_indices.to_a
            if hatch_mode == :skip
              paths = paths.each_with_index.reject { |_, i| hatch_set.include?(i) }.map(&:first)
            elsif hatch_mode == :group
              hatch_paths = paths.each_with_index.select { |_, i| hatch_set.include?(i) }.map(&:first)
              paths = paths.each_with_index.reject { |_, i| hatch_set.include?(i) }.map(&:first)
            end
          end
        end

        # Geometry text uses raw transformed path edges in one owned group;
        # Glyphs uses reusable component instances in a different owned group.
        # The ordinary PDF vectors remain on GeometryBuilder's established
        # parser path.  The unsafe dormant full-page SVG renderer is not loaded.
        # Labels with layer matching use internal parsing so each span lands on its OCG tag.
        use_svg_text = [:geometry, :glyphs].include?(requested_text_mode) &&
                       opts[:import_text]
        use_svg_3d_text = requested_text_mode == :text3d && opts[:import_text]
        use_item_raster = requested_text_mode == :raster && opts[:import_text]
        if match_pdf_layers && !ocg.layer_list.empty? &&
           [:text, :labels].include?(requested_text_mode)
          use_svg_text = false
        end
        # Native add_3d_text cannot certify embedded PDF font identity. Exact
        # 3D text therefore uses the renderer's own glyph outlines; native 3D
        # text remains available only behind GeometryBuilder's explicit font
        # identity proof gate.
        builder_use_3d_text = false
        builder_text_items =
          (use_svg_text || use_svg_3d_text || use_item_raster) ? [] : text_items
        representation_renderer = if use_svg_3d_text
                                    :svg_3d_text
                                  elsif use_svg_text
                                    :svg_text
                                  end
        group_policy = RepresentationFidelity.owned_page_group_policy(
          opts[:group_per_page], representation_renderer
        )
        if group_policy[:forced]
          stats[:representation_ownership_group_forced_pages] << {
            :page => page_num,
            :requested_text_mode => requested_text_mode,
            :requested_group_per_page => false,
            :effective_group_per_page => true,
            :reason_code => group_policy[:reason_code]
          }
        end
        provenance_opts = {
          provenance_bucket: stats[:source_provenance_objects],
          import_session_id: stats[:import_session_id]
        }
        builder = GeometryBuilder.new(model, paths, builder_text_items, media_box,
          scale_factor: opts[:scale], bezier_segments: opts[:bezier_segments],
          import_as: opts[:import_as], layer_name: opts[:layer_name],
          group_per_page: group_policy[:effective_group_per_page], page_number: page_num,
          flatten_to_2d: true, merge_tolerance: opts[:merge_tolerance],
          import_fills: (opts[:import_fills] || force_import_fills_for_page), group_by_color: opts[:group_by_color],
          detect_arcs: opts[:detect_arcs], map_dashes: opts[:map_dashes],
          import_text: (use_svg_text || use_svg_3d_text || use_item_raster) ?
            false : opts[:import_text],
          use_3d_text: builder_use_3d_text,
          strict_text_fidelity: opts[:strict_text_fidelity],
          requested_text_mode: requested_text_mode,
          layer_manager: layer_mgr,
          y_offset: page_y_offset,
          page_rotation: page_rotation,
          provenance_bucket: provenance_opts[:provenance_bucket],
          import_session_id: provenance_opts[:import_session_id])
        result = builder.build
        stats[:edges] += result[:edges]; stats[:faces] += result[:faces]
        stats[:arcs] += result[:arcs]; stats[:text] += result[:text_objects]
        merge_text_height_samples!(stats, result[:text_height_samples])
        stats[:text_height_fallback_count] =
          stats[:text_height_fallback_count].to_i + result[:text_height_fallback_count].to_i
        merge_text_width_crosscheck!(stats, result)

        builder_failures = Array(result[:text_delivery_failures])
        if requested_text_mode == :text
          bind_flat_text_capability_rows!(
            result[:text_attempts], builder_failures, flat_text_fallbacks
          )
        end
        label_fallback_failures = []
        if [:text, :labels].include?(requested_text_mode)
          label_fallback_failures = builder_failures.select do |failure|
            failure[:transition_proof].is_a?(Hash)
          end
        end
        hard_builder_failures = builder_failures - label_fallback_failures
        unless hard_builder_failures.empty?
          enforce_requested_text_delivery!(
            page_num, requested_text_mode, hard_builder_failures
          )
        end

        fallback_source_ids = label_fallback_failures.map do |failure|
          failure[:source_span_id].to_s
        end
        completed_builder_attempts = Array(result[:text_attempts]).reject do |attempt|
          fallback_source_ids.include?(attempt[:source_span_id].to_s)
        end
        merge_text_attempts!(stats, completed_builder_attempts)
        if requested_text_mode == :text
          completed_builder_attempts.each do |attempt|
            source_id = RepresentationFidelity.source_span_id(
              attempt[:source_span_id]
            )
            record_fallback_transitions!(
              stats, page_num,
              flat_text_fallbacks.fetch(source_id)[:controller].transitions
            )
          end
        end

        if opts[:import_text] && !use_svg_text && !use_svg_3d_text &&
           result[:text_objects].to_i > 0
          renderer = builder_use_3d_text ? :add_3d_text : :labels
          delivered_mode = builder_use_3d_text ? :text3d : :labels
          record_text_renderer(stats, page_num,
            renderer: renderer, mode: delivered_mode,
            requested_mode: requested_text_mode,
            delivered_mode: delivered_mode,
            degraded: delivered_mode != requested_text_mode,
            reason: (requested_text_mode == :text ?
              'SketchUp has no distinct flat editable model Text entity; ' \
              'item-bound capability proof advanced to Labels' : nil),
            count: result[:text_objects].to_i)
        end

        unless label_fallback_failures.empty?
          label_svg_failure = {}
          use_cropbox = crop_box && crop_box.zip(media_box).any? do |a, b|
            (a.to_f - b.to_f).abs > 0.01
          end
          label_svg_document = CairoGlyphSource.render_page_svg(
            path, page_num, :failure_info => label_svg_failure,
            :use_cropbox => use_cropbox == true
          )
          unless label_svg_document &&
                 !label_svg_document[:svg].to_s.empty?
            raise RepresentationFidelity::ContractError,
                  "Page #{page_num}: Labels fallback source inspection failed: " \
                  "#{label_svg_failure[:reason]}"
          end
          fallback_items = text_items.select do |item|
            fallback_source_ids.include?(
              RepresentationFidelity.source_span_id(item)
            )
          end
          fallback_parent = builder.page_group ?
            builder.page_group.entities : model.active_entities
          complete_label_item_fallbacks!(
            stats, model, fallback_parent, path, page_num, fallback_items,
            media_box, svg_page_box, page_rotation, opts, import_start,
            page_y_offset, label_svg_document, label_fallback_failures,
            result[:text_attempts], layer_mgr.text_fallback_layer, text_items,
            requested_text_mode, flat_text_fallbacks
          )
        end


        # Explicit text-mode Raster is item-scoped whenever canonical source
        # spans exist. It is requested delivery, not a fallback, and therefore
        # begins at the terminal Raster rung with no transition ledger.
        if use_item_raster && !Array(text_items).empty?
          raster_parent = builder.page_group ?
            builder.page_group.entities : model.active_entities
          Array(text_items).each do |source_item|
            source_id = RepresentationFidelity.source_span_id(source_item)
            controller = RepresentationFidelity::FallbackController.new(
              :raster, source_id
            )
            complete_item_representation_ladder!(
              stats, model, raster_parent, path, page_num, source_item,
              :raster, controller, [], media_box, svg_page_box,
              page_rotation, opts, import_start, page_y_offset, {},
              layer_mgr.text_fallback_layer, text_items
            )
          end
          stats[:text_mode] = :raster
        end

        # Exact 3D Text: build filled solids from the PDF renderer's own glyph
        # outlines. Arial/native-font substitution is never used as a visual
        # correction. Each source span owns one independently verified group.
        if use_svg_3d_text && builder.page_group
          svg_failure = {}
          use_cropbox = crop_box && crop_box.zip(media_box).any? do |a, b|
            (a.to_f - b.to_f).abs > 0.01
          end
          svg_document = source_svg_document ||
            CairoGlyphSource.render_page_svg(
              path, page_num,
              :failure_info => svg_failure,
              :use_cropbox => use_cropbox == true
            )
          unless svg_document && svg_document[:svg].to_s.length > 0
            reason = svg_failure[:reason].to_s
            reason = 'svg_3d_text_renderer_failed' if reason.empty?
            if text_items.empty?
              raise RepresentationFidelity::ContractError,
                    "Page #{page_num}: exact 3D text source inspection failed: #{reason}"
            end
            failures = text_items.map do |item|
              {
                :source_span_id => RepresentationFidelity.source_span_id(item),
                :reason => reason
              }
            end
            enforce_requested_text_delivery!(page_num, :text3d, failures)
          end

          representation_parent = builder.page_group.entities
          depth = opts[:text_3d_depth]
          depth = Svg3DTextRenderer::DEFAULT_DEPTH_INCHES if depth.nil?
          # When semantic spans exist, do not also emit anonymous unmatched
          # glyph groups — partial matcher leftovers beside delivered spans
          # read as ghosted duplicates on shop drawings. Truly source-only
          # symbol ink without a span identity still advances via the item
          # fallback ladder / transition proofs, not a second anonymous paint.
          text3d_result = Svg3DTextRenderer.render_svg(
            representation_parent, svg_document[:svg], media_box, text_items,
            :scale => opts[:scale],
            :svg_page_box => svg_page_box,
            :y_offset => 0.0,
            :depth => depth,
            :layer => layer_mgr.text_fallback_layer,
            :page_number => page_num,
            :preserve_unmatched_source_placements => Array(text_items).empty?,
            :source_context => svg_source_context(
              svg_document, page_num, svg_failure
            )
          )

          unless Array(text3d_result[:failures]).empty?
            failures = text3d_result[:failures].map do |failure|
              {
                :source_span_id => failure[:source_span_id],
                :reason => failure[:reason_code].to_s
              }
            end
            enforce_requested_text_delivery!(page_num, :text3d, failures)
          end

          transition_proofs = Array(text3d_result[:transition_proofs])
          if text3d_result[:no_semantic_text] == true
            record_text_renderer(
              stats, page_num,
              :renderer => :no_semantic_text,
              :mode => :text3d,
              :requested_mode => :text3d,
              :delivered_mode => :text3d,
              :degraded => false,
              :count => 0,
              :no_semantic_text => true,
              :source_svg_inspected => true
            )
          else
            all_source_rows = Array(text3d_result[:span_results]) +
              Array(text3d_result[:unmatched_source_results])
            transforms_ok = all_source_rows.all? do |row|
              apply_and_verify_page_representation_transform(
                row[:group], media_box, opts[:scale], page_rotation,
                page_y_offset, row
              )
            end
            unless transforms_ok
              all_source_rows.each do |row|
                group = row[:group]
                RepresentationFidelity.erase_owned!(
                  representation_parent, [group]
                ) if group
              end
              raise RepresentationFidelity::ContractError,
                    "Page #{page_num}: exact 3D text page transform was not verified"
            end
            delivered_ids = Array(text3d_result[:span_results]).map do |row|
              row[:source_span_id].to_s
            end
            delivered_items = Array(text_items).select do |item|
              delivered_ids.include?(
                RepresentationFidelity.source_span_id(item)
              )
            end
            unless all_source_rows.empty?
              record_svg_3d_text_delivery!(
                stats, page_num, delivered_items, text3d_result, :text3d, {},
                page_rotation
              )
            end
            # QA text_entities counts created host text-representation groups;
            # the placement count remains explicit in renderer/provenance data.
            stats[:text] += text3d_result[:span_results].length +
              Array(text3d_result[:unmatched_source_results]).length
            stats[:faces] += all_source_rows.inject(0) do |sum, row|
              sum + row[:face_count].to_i
            end
            unless transition_proofs.empty?
              complete_text3d_item_fallbacks!(
                stats, model, representation_parent, path, page_num,
                text_items, media_box, svg_page_box, page_rotation, opts,
                import_start, page_y_offset, svg_document,
                transition_proofs
              )
            end
          end
        end

        # Build hatching on separate layer if group mode
        if hatch_mode == :group && !hatch_paths.empty? && builder.page_group
          hatch_layer_name = "#{opts[:layer_name] || 'PDF Import'}:Hatching"
          hatch_builder = GeometryBuilder.new(model, hatch_paths, [], media_box,
            scale_factor: opts[:scale], bezier_segments: opts[:bezier_segments],
            import_as: :edges, layer_name: hatch_layer_name,
            group_per_page: false, page_number: page_num,
            flatten_to_2d: true, merge_tolerance: opts[:merge_tolerance],
            import_fills: false, group_by_color: false,
            detect_arcs: false, map_dashes: false,
            import_text: false, use_3d_text: false,
            layer_manager: layer_mgr,
            y_offset: page_y_offset,
            page_rotation: page_rotation,
            target_entities: builder.page_group.entities)
          hatch_result = hatch_builder.build
          stats[:edges] += hatch_result[:edges]
          # Default hatching layer to hidden
          begin
            hl = model.layers[hatch_layer_name]
            hl.visible = false if hl
          rescue StandardError => e
            Logger.warn("Main", "hide hatch layer failed: #{e.message}")
          end
        end

        # Render text as precise vector geometry via Poppler/MuPDF SVG.
        if use_svg_text && builder.page_group
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Rendering text geometry... [#{(Time.now - import_start).round(1)}s]"
          text_layer = layer_mgr.text_fallback_layer

          # A page container cannot prove which physical descendants belong to
          # which source span. Render and certify every source item independently.
          # This also keeps same-text spans distinct by their deterministic span
          # identity and exact source placement set.
          svg_failure = {}
          use_cropbox = crop_box && crop_box.zip(media_box).any? do |a, b|
            (a.to_f - b.to_f).abs > 0.01
          end
          svg_document = source_svg_document ||
            CairoGlyphSource.render_page_svg(
              path, page_num,
              :failure_info => svg_failure,
              :use_cropbox => use_cropbox == true
            )
          unless svg_document && !svg_document[:svg].to_s.empty?
            reason = svg_failure[:reason].to_s
            reason = 'requested_svg_representation_unavailable' if reason.empty?
            raise RepresentationFidelity::ContractError,
                  "Page #{page_num}: item source inspection failed: #{reason}"
          end
          representation_parent = builder.page_group ?
            builder.page_group.entities : model.active_entities
          Array(text_items).each do |source_item|
            source_id = RepresentationFidelity.source_span_id(source_item)
            controller = RepresentationFidelity::FallbackController.new(
              requested_text_mode, source_id
            )
            complete_item_representation_ladder!(
              stats, model, representation_parent, path, page_num,
              source_item, requested_text_mode, controller, [], media_box,
              svg_page_box, page_rotation, opts, import_start, page_y_offset,
              svg_document, text_layer, text_items
            )
          end
          stats[:text_mode] = requested_text_mode
        end

        if opts[:cleanup_geometry] && builder.page_group
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Cleaning up geometry... [#{(Time.now - import_start).round(1)}s]"
          cl = GeometryCleanup.cleanup(builder.page_group.entities,
            merge_tolerance:    opts[:merge_tolerance],
            min_edge_length:    opts[:merge_tolerance],
            cleanup_level:      opts[:cleanup_level])
          cl.each { |k, v| stats[:cleanup][k] = (stats[:cleanup][k] || 0) + v }
        end

        if !embedded_assets.empty? && builder.page_group
          placed = place_embedded_images(
            model,
            embedded_assets,
            media_box,
            opts,
            page_y_offset,
            page_rotation,
            builder.page_group.entities
          )
          stats[:embedded_images_placed] += placed
          Logger.info(
            "EmbeddedImages",
            "Page #{page_num}: placed #{placed}/#{embedded_assets.length} supported embedded image(s)."
          )
        end

        # ── Closed-shape extrusion (disabled; independent of 3D text) ───
        if SHAPE_EXTRUSION_ENABLED && opts[:extrude_depth].to_f > 0.0 && builder.page_group &&
           opts[:import_mode].to_s != 'raster'
          begin
            Sketchup.status_text = "PDF Import#{pct} \u2014 Page #{page_num} \u2014 Extruding 3D faces... [#{(Time.now - import_start).round(1)}s]"
            ex = Extrude3D.apply(builder.page_group.entities, opts[:extrude_depth].to_f)
            stats[:extruded_faces] = (stats[:extruded_faces] || 0) + ex[:faces_extruded]
            Logger.info('Extrude3D',
              "Page #{page_num}: #{ex[:faces_extruded]}/#{ex[:faces_found]} face(s) extruded " \
              "#{opts[:extrude_depth].to_f.round(4)}in")
          rescue StandardError => e
            Logger.warn('Extrude3D', "Page #{page_num}: extrude failed: #{e.message}")
          end
        end

        add_page_fit_bounds(page_fit_bounds, media_box, stack_box, opts[:scale], page_y_offset, page_rotation)

        # Advance the running page stack only after a successful import.
        running_y_offset += page_stack_step(curr_page_height_in, page_arrangement, page_gap_ratio)

      rescue RepresentationFidelity::ContractError => e
        Logger.error(
          'Pipeline',
          "Page #{page_num} ownership/identity proof failed: #{e.message}", e
        )
        safe_abort_operation(model, 'Pipeline')
        raise e
      rescue StandardError => e
        Logger.error("Pipeline", "Page #{page_num} failed: #{e.message}", e)
        safe_abort_operation(model, 'Pipeline')
        raise e
      end
      end

      if SHAPE_EXTRUSION_ENABLED && opts[:extrude_to_3d]
        stats[:model_3d] = Model3DExtruder.extrude_imported(model, pre_import_entities, opts)
      end

      cleanup_item_raster_page_cache!(opts)
      verify_cached_source_pdf_bindings!(opts)
      model.commit_operation

      layer_mgr.register_imported_names!
      stats[:layers] = layer_mgr.imported_names
      stats[:layer_warning] = layer_mgr.warning

      # Release the raw PDF buffer and object cache to free memory.
      begin
        parser.release
      rescue StandardError => e
        Logger.warn("Pipeline", "parser.release failed: #{e.message}")
      end

      elapsed = (Time.now - import_start).round(1)
      stats[:elapsed_seconds] = elapsed

      # ── Auto fit view to newly imported geometry (not model-wide extents) ──
      imported_entities = []
      begin
        imported_entities = model.active_entities.to_a - pre_import_entities
      rescue StandardError
        imported_entities = []
      end
      apply_top_view_fit(model, page_fit_bounds, imported_entities)

      stats[:log_path] = Logger.log_path
      finalize_import_diagnostics!(source_input_path, opts, stats)
      Sketchup.status_text = if import_contract_ready?(stats)
        "PDF Import complete — #{stats[:edges]} edges, #{stats[:text]} text " \
          "items — #{elapsed}s"
      else
        "PDF Import finished, but QA contract is NOT READY — " \
          "#{stats[:edges]} edges, #{stats[:text]} text items"
      end
      stats
    ensure
      cleanup_item_raster_page_cache!(opts) if
        defined?(opts) && opts.is_a?(Hash)
      Logger.flush_log
      PdfSalvage.cleanup(path) if defined?(PdfSalvage)
    end

    def self.place_embedded_images(model, assets, media_box, opts, y_offset, page_rotation, target_entities = nil)
      return 0 unless model && assets && !assets.empty?
      entities = target_entities || model.active_entities
      return 0 unless entities && entities.respond_to?(:add_image)

      layer = begin
        model.layers['PDF Import: Images'] || model.layers.add('PDF Import: Images')
      rescue StandardError
        nil
      end

      placed = 0
      assets.each do |asset|
        next unless asset && asset.file_path && File.file?(asset.file_path)
        unless EmbeddedImageExtractor.placeable_sketchup_image?(asset)
          if asset.placement_error
            Logger.warn(
              'EmbeddedImages',
              "Skipping unsafe PDF image #{asset.name}: " \
              "#{asset.placement_error}."
            )
          elsif asset.fully_transparent
            Logger.info(
              'EmbeddedImages',
              "Skipping fully transparent PDF image #{asset.name}."
            )
          else
            Logger.warn(
              'EmbeddedImages',
              "Skipping SketchUp placement for #{asset.name}: exported #{File.extname(asset.file_path)} is not a SketchUp image format."
            )
          end
          next
        end

        bbox = embedded_image_su_bbox(asset, media_box, opts[:scale], y_offset, page_rotation)
        next unless bbox
        x0, y0, x1, y1 = bbox
        width = (x1 - x0).abs
        height = (y1 - y0).abs
        next if width <= 0.0 || height <= 0.0

        begin
          image = entities.add_image(asset.file_path, Geom::Point3d.new(x0, y0, 0.0), width, height)
          if image
            begin
              image.layer = layer if layer
            rescue StandardError => e
              Logger.warn('EmbeddedImages', "Image layer assignment failed: #{e.message}")
            end
            placed += 1
          end
        rescue StandardError => e
          Logger.warn('EmbeddedImages', "add_image failed for #{asset.name}: #{e.message}")
        end
      end
      placed
    end

    def self.embedded_image_su_bbox(asset, media_box, scale, y_offset, page_rotation)
      corners = asset.respond_to?(:corners_pts) ? asset.corners_pts : nil
      return nil unless corners && corners.length >= 2

      s = scale.to_f
      s = 1.0 if s <= 0.0
      ox = media_box[0].to_f
      oy = media_box[1].to_f
      rot = PageTransform.normalize_rotation(page_rotation)
      pts = corners.map do |corner|
        if rot != 0
          x_pts, y_pts = PageTransform.transform_point(corner[0], corner[1], media_box, rot)
        else
          x_pts = corner[0].to_f - ox
          y_pts = corner[1].to_f - oy
        end
        [
          x_pts * (1.0 / 72.0) * s,
          y_pts * (1.0 / 72.0) * s + y_offset.to_f
        ]
      end
      xs = pts.map { |pt| pt[0] }
      ys = pts.map { |pt| pt[1] }
      [xs.min, ys.min, xs.max, ys.max]
    rescue StandardError => e
      Logger.warn('EmbeddedImages', "placement bbox failed: #{e.message}")
      nil
    end

    # ================================================================
    # RASTER FALLBACK — render scanned page as positioned image
    # ================================================================
    def self.raster_command_value(arguments, option)
      args = Array(arguments).map { |value| value.to_s }
      index = args.index(option.to_s)
      return nil unless index && index + 1 < args.length
      args[index + 1]
    end

    def self.distinct_page_box?(left, right)
      return false unless left.is_a?(Array) && right.is_a?(Array)
      return false unless left.length >= 4 && right.length >= 4
      4.times.any? do |index|
        (left[index].to_f - right[index].to_f).abs > 0.01
      end
    rescue StandardError
      false
    end

    def self.raster_display_dimensions(render_box, page_rotation)
      width = PageTransform.box_width(render_box).to_f
      height = PageTransform.box_height(render_box).to_f
      raise RepresentationFidelity::ContractError,
            'raster render box is empty' unless width > 0.0 && height > 0.0
      if [90, 270].include?(PageTransform.normalize_rotation(page_rotation))
        [height, width]
      else
        [width, height]
      end
    end

    def self.raster_placement_geometry(media_box, render_box, page_rotation,
                                       scale, y_offset)
      transformed = PageTransform.transform_bbox(
        render_box[0], render_box[1], render_box[2], render_box[3],
        media_box, page_rotation
      )
      factor = (1.0 / 72.0) * scale.to_f
      {
        :x => transformed[0].to_f * factor,
        :y => y_offset.to_f + (transformed[1].to_f * factor),
        :width => (transformed[2].to_f - transformed[0].to_f).abs * factor,
        :height => (transformed[3].to_f - transformed[1].to_f).abs * factor
      }
    rescue RepresentationFidelity::ContractError
      raise
    rescue StandardError => e
      raise RepresentationFidelity::ContractError,
            "raster placement geometry failed: #{e.message}"
    end

    def self.verify_raster_artifact!(png_path, page_num, media_box, render_box,
                                     page_rotation, arguments,
                                     source_pdf_path = nil,
                                     source_pdf_binding = nil)
      raise RepresentationFidelity::ContractError,
            'raster artifact file is missing' unless
        png_path && File.file?(png_path)
      header = File.open(png_path, 'rb') { |file| file.read(24) }
      signature = "\x89PNG\r\n\x1a\n".dup
      signature.force_encoding(Encoding::BINARY) if signature.respond_to?(:force_encoding)
      unless header && header.bytesize >= 24 && header[0, 8] == signature &&
             header[12, 4] == 'IHDR'
        raise RepresentationFidelity::ContractError,
              'raster artifact is not a PNG with an IHDR header'
      end
      pixel_width, pixel_height = header[16, 8].unpack('N2')
      unless pixel_width.to_i > 0 && pixel_height.to_i > 0
        raise RepresentationFidelity::ContractError,
              'raster PNG dimensions are empty'
      end

      requested_page = page_num.to_i
      first_page = raster_command_value(arguments, '-f').to_i
      last_page = raster_command_value(arguments, '-l').to_i
      unless requested_page > 0 && first_page == requested_page &&
             last_page == requested_page &&
             Array(arguments).map { |value| value.to_s }.include?('-singlefile')
        raise RepresentationFidelity::ContractError,
              'raster command is not bound to exactly the requested page'
      end

      source_binding = {}
      pixel_binding = {}
      if source_pdf_path
        source_path = File.expand_path(source_pdf_path.to_s)
        unless File.file?(source_path)
          raise RepresentationFidelity::ContractError,
                'raster source PDF is missing'
        end
        argv = Array(arguments).map { |value| value.to_s }
        command_source = argv.length >= 2 ? argv[-2] : nil
        unless command_source &&
               File.expand_path(command_source).downcase == source_path.downcase
          raise RepresentationFidelity::ContractError,
                'raster command source does not match the selected PDF'
        end
        binding_sha = nil
        if source_pdf_binding.is_a?(Hash)
          unless source_pdf_binding[:pre_render_verified] == true &&
                 source_pdf_binding[:post_render_verified] == true &&
                 File.expand_path(source_pdf_binding[:source_pdf_path].to_s).downcase ==
                   source_path.downcase
            raise RepresentationFidelity::ContractError,
                  'raster source lacks a complete pre/post render binding'
          end
          binding_sha = source_pdf_binding[:source_pdf_sha256].to_s.downcase
        else
          # Kept for isolated verifier callers; production render paths always
          # supply the pre/post command-window binding.
          binding_sha = Digest::SHA256.file(source_path).hexdigest
        end
        source_binding = {
          :source_pdf_path => source_path,
          :source_pdf_sha256 => binding_sha,
          :source_pdf_binding_verified => true
        }

        # Production render paths supply a command-window source binding.  At
        # that boundary, decode the exact PNG as pixels as well; a valid header
        # and self-authored attributes are not proof of visible raster content.
        if source_pdf_binding.is_a?(Hash)
          pixel_temp_dir = Dir.mktmpdir('bc_raster_pixel_proof_')
          pixel_raw_path = File.join(pixel_temp_dir, 'pixels.rgba')
          begin
            prepared_pixels = PngCropper.prepare_rgba!(
              png_path, pixel_raw_path, false
            )
            pixel_binding = {
              :visual_pixel_sha256 =>
                prepared_pixels[:visual_pixel_sha256].to_s.downcase,
              :visual_pixel_binding_verified => true
            }
          ensure
            cleanup_owned_temp_artifacts!(
              [pixel_raw_path], [pixel_temp_dir]
            ) if pixel_temp_dir
          end
        end
      end

      crop_expected = distinct_page_box?(render_box, media_box)
      crop_used = Array(arguments).map { |value| value.to_s.downcase }.include?('-cropbox')
      unless crop_expected == crop_used
        raise RepresentationFidelity::ContractError,
              'raster command box does not match the placement box'
      end

      display_width, display_height = raster_display_dimensions(
        render_box, page_rotation
      )
      expected_aspect = display_width / display_height
      pixel_aspect = pixel_width.to_f / pixel_height.to_f
      aspect_tolerance = [0.01, 2.0 / [pixel_width, pixel_height].min.to_f].max
      unless (pixel_aspect - expected_aspect).abs <= aspect_tolerance
        raise RepresentationFidelity::ContractError,
              "raster PNG aspect #{pixel_aspect} does not match page aspect #{expected_aspect}"
      end

      {
        :png_path => png_path.to_s,
        :content_sha256 => Digest::SHA256.file(png_path).hexdigest,
        :content_byte_size => File.size(png_path).to_i,
        :pixel_width => pixel_width.to_i,
        :pixel_height => pixel_height.to_i,
        :page_number => requested_page,
        :page_rotation => PageTransform.normalize_rotation(page_rotation),
        :render_box_used => crop_used ? :crop_box : :media_box,
        :render_box => render_box.map { |value| value.to_f },
        :png_signature_verified => true,
        :page_binding_verified => true,
        :box_binding_verified => true,
        :aspect_verified => true
      }.merge(source_binding).merge(pixel_binding)
    rescue RepresentationFidelity::ContractError
      raise
    rescue StandardError => e
      raise RepresentationFidelity::ContractError,
            "raster artifact verification failed: #{e.message}"
    end

    def self.verify_item_raster_artifact!(png_path, item, page_num,
                                          crop_geometry, arguments,
                                          source_pdf_path, crop_proof = nil,
                                          source_pdf_sha256 = nil)
      source_id = RepresentationFidelity.source_span_id(item)
      binding = RepresentationFidelity.proof_binding(source_id)
      unless binding[:page_number] == page_num.to_i
        raise RepresentationFidelity::ContractError,
              'item raster source identity belongs to a different page'
      end
      raise RepresentationFidelity::ContractError,
            'item raster artifact file is missing' unless
        png_path && File.file?(png_path)
      source_path = File.expand_path(source_pdf_path.to_s)
      unless File.file?(source_path)
        raise RepresentationFidelity::ContractError,
              'item raster source PDF is missing'
      end
      argv = Array(arguments).map { |value| value.to_s }
      command_source = argv.length >= 2 ? argv[-2] : nil
      unless command_source &&
             File.expand_path(command_source).downcase == source_path.downcase
        raise RepresentationFidelity::ContractError,
              'item raster command source does not match the selected PDF'
      end
      header = File.open(png_path, 'rb') { |file| file.read(24) }
      signature = "\x89PNG\r\n\x1a\n".dup
      signature.force_encoding(Encoding::BINARY) if
        signature.respond_to?(:force_encoding)
      unless header && header.bytesize >= 24 && header[0, 8] == signature &&
             header[12, 4] == 'IHDR'
        raise RepresentationFidelity::ContractError,
              'item raster artifact is not a PNG with an IHDR header'
      end
      pixel_width, pixel_height = header[16, 8].unpack('N2')
      expected_crop = Array(crop_geometry[:pixel_crop]).map { |value| value.to_i }
      unless expected_crop.length == 4 && expected_crop[2] > 0 &&
             expected_crop[3] > 0
        raise RepresentationFidelity::ContractError,
              'item raster expected crop is invalid'
      end
      crop_options = ['-x', '-y', '-W', '-H']
      unless crop_options.none? { |option| argv.include?(option) }
        raise RepresentationFidelity::ContractError,
              'item raster page renderer must not launch once per crop'
      end
      requested_page = page_num.to_i
      args = Array(arguments).map { |value| value.to_s }
      unless raster_command_value(args, '-f').to_i == requested_page &&
             raster_command_value(args, '-l').to_i == requested_page &&
             args.include?('-singlefile') && args.include?('-transp') &&
             !args.include?('-cropbox')
        raise RepresentationFidelity::ContractError,
              'item raster command is not bound to exactly one MediaBox page'
      end
      unless raster_command_value(args, '-r').to_i == crop_geometry[:dpi].to_i
        raise RepresentationFidelity::ContractError,
              'item raster command DPI is not bound to crop geometry'
      end
      unless pixel_width.to_i == expected_crop[2] &&
             pixel_height.to_i == expected_crop[3]
        raise RepresentationFidelity::ContractError,
              'item raster PNG dimensions do not equal its source crop'
      end
      proof = crop_proof.is_a?(Hash) ? crop_proof : {}
      page_render_sha = proof[:page_render_content_sha256].to_s.downcase
      visual_pixel_sha = proof[:visual_pixel_sha256].to_s.downcase
      unless proof[:alpha_channel_verified] == true &&
             proof[:transparent_background_verified] == true &&
             proof[:visible_pixel_verified] == true &&
             proof[:page_render_once_verified] == true &&
             page_render_sha =~ /\A[0-9a-f]{64}\z/ &&
             visual_pixel_sha =~ /\A[0-9a-f]{64}\z/
        raise RepresentationFidelity::ContractError,
              'item raster crop lacks transparent one-page-render pixel proof'
      end
      exact_source_sha = source_pdf_sha256.to_s.downcase
      unless exact_source_sha =~ /\A[0-9a-f]{64}\z/
        raise RepresentationFidelity::ContractError,
              'item raster cached source PDF digest is missing'
      end
      {
        :png_path => png_path.to_s,
        :content_sha256 => Digest::SHA256.file(png_path).hexdigest,
        :content_byte_size => File.size(png_path).to_i,
        :source_span_id => source_id,
        :page_number => requested_page,
        :source_pdf_path => source_path,
        :source_pdf_sha256 => exact_source_sha,
        :source_pdf_binding_verified => true,
        :page_rotation => crop_geometry[:page_rotation].to_i,
        :source_box => Array(crop_geometry[:source_box]).map { |value| value.to_f },
        :display_box => Array(crop_geometry[:display_box]).map { |value| value.to_f },
        :pixel_crop => expected_crop,
        :pixel_width => pixel_width.to_i,
        :pixel_height => pixel_height.to_i,
        :png_signature_verified => true,
        :page_binding_verified => true,
        :source_crop_binding_verified => true,
        :aspect_verified => true,
        :alpha_channel_verified => true,
        :transparent_background_verified => true,
        :page_render_once_verified => true,
        :page_render_content_sha256 => page_render_sha,
        :visual_pixel_sha256 => visual_pixel_sha,
        :visual_pixel_binding_verified => true,
        :visible_pixel_verified => proof[:visible_pixel_verified] == true
      }
    rescue RepresentationFidelity::ContractError
      raise
    rescue StandardError => e
      raise RepresentationFidelity::ContractError,
            "item raster artifact verification failed: #{e.message}"
    end

    def self.fetch_item_raster_page_cache!(opts, cache_key)
      raise ArgumentError, 'item raster options must be a Hash' unless
        opts.is_a?(Hash)
      cache = opts[:item_raster_page_cache]
      cache = {} unless cache.is_a?(Hash)
      opts[:item_raster_page_cache] = cache
      return cache[cache_key] if cache.key?(cache_key)
      value = yield
      unless value.is_a?(Hash)
        raise RepresentationFidelity::ContractError,
              'item raster page cache producer returned no artifact'
      end
      cache[cache_key] = value
    end

    def self.initialize_item_raster_import_cache!(opts, import_text)
      raise ArgumentError, 'item raster options must be a Hash' unless
        opts.is_a?(Hash)
      unless import_text == true
        opts.delete(:item_raster_page_cache)
        opts.delete(:source_pdf_digest_cache)
        opts.delete(:item_raster_cache_persistent)
        return opts
      end
      # Every finite text-representation ladder can legitimately terminate at
      # Raster. Own one cache for the entire import regardless of the requested
      # starting rung so a terminal fallback cannot render the same page twice.
      opts[:item_raster_page_cache] = {}
      opts[:source_pdf_digest_cache] = {}
      opts[:item_raster_cache_persistent] = true
      opts
    end

    def self.cached_source_pdf_sha256!(opts, pdf_path)
      source_path = File.expand_path(pdf_path.to_s)
      raise RepresentationFidelity::ContractError,
            'item raster source PDF is missing' unless File.file?(source_path)
      identity = source_pdf_file_identity!(source_path)
      cache = opts[:source_pdf_digest_cache]
      cache = {} unless cache.is_a?(Hash)
      opts[:source_pdf_digest_cache] = cache
      key = source_path.downcase
      entry = cache[key]
      if entry.is_a?(Hash) && entry[:sha256].to_s =~ /\A[0-9a-f]{64}\z/
        unless entry[:file_identity] == identity
          raise RepresentationFidelity::ContractError,
                'source PDF identity changed after the import digest was frozen'
        end
        return entry[:sha256]
      end
      sha256 = Digest::SHA256.file(source_path).hexdigest
      cache[key] = {
        :source_pdf_path => source_path,
        :file_identity => identity,
        :sha256 => sha256
      }
      sha256
    end

    def self.source_pdf_file_identity!(pdf_path)
      source_path = File.expand_path(pdf_path.to_s)
      stat = File.stat(source_path)
      {
        :path => source_path.downcase,
        :size => stat.size.to_i,
        :mtime => stat.mtime.to_f,
        :ctime => stat.ctime.to_f,
        :device => (stat.dev.to_i rescue 0),
        :inode => (stat.ino.to_i rescue 0)
      }
    rescue StandardError => e
      raise RepresentationFidelity::ContractError,
            "source PDF identity is unavailable: #{e.message}"
    end

    def self.begin_source_pdf_render_binding!(opts, pdf_path)
      source_path = File.expand_path(pdf_path.to_s)
      frozen_sha = cached_source_pdf_sha256!(opts, source_path)
      identity = source_pdf_file_identity!(source_path)
      actual_sha = Digest::SHA256.file(source_path).hexdigest
      unless actual_sha == frozen_sha
        raise RepresentationFidelity::ContractError,
              'source PDF content changed before page rendering began'
      end
      {
        :source_pdf_path => source_path,
        :source_pdf_sha256 => frozen_sha,
        :file_identity => identity,
        :pre_render_verified => true
      }
    end

    def self.verify_source_pdf_render_binding!(binding)
      unless binding.is_a?(Hash) && binding[:pre_render_verified] == true
        raise RepresentationFidelity::ContractError,
              'source PDF pre-render binding is missing'
      end
      source_path = File.expand_path(binding[:source_pdf_path].to_s)
      identity = source_pdf_file_identity!(source_path)
      sha256 = Digest::SHA256.file(source_path).hexdigest
      unless identity == binding[:file_identity] &&
             sha256 == binding[:source_pdf_sha256].to_s
        raise RepresentationFidelity::ContractError,
              'source PDF changed while the page renderer was running'
      end
      binding[:post_render_verified] = true
      true
    end

    def self.verify_cached_source_pdf_bindings!(opts)
      cache = opts.is_a?(Hash) ? opts[:source_pdf_digest_cache] : nil
      Array(cache && cache.values).each do |entry|
        unless entry.is_a?(Hash)
          raise RepresentationFidelity::ContractError,
                'source PDF digest cache contains an invalid entry'
        end
        path = File.expand_path(entry[:source_pdf_path].to_s)
        identity = source_pdf_file_identity!(path)
        sha256 = Digest::SHA256.file(path).hexdigest
        unless identity == entry[:file_identity] && sha256 == entry[:sha256].to_s
          raise RepresentationFidelity::ContractError,
                'source PDF changed before the SketchUp operation committed'
        end
      end
      true
    end

    def self.cleanup_item_raster_page_cache!(opts)
      return true unless opts.is_a?(Hash)
      cache = opts[:item_raster_page_cache]
      paths = []
      directories = []
      Array(cache && cache.values).each do |entry|
        next unless entry.is_a?(Hash)
        paths.concat(Array(entry[:owned_temp_paths]))
        directories.concat(Array(entry[:owned_temp_directories]))
      end
      cleanup_owned_temp_artifacts!(paths, directories)
      cache.clear if cache.respond_to?(:clear)
      true
    end

    def self.cleanup_owned_temp_artifacts!(paths, directories = [])
      failures = []
      Array(paths).compact.uniq.each do |path|
        begin
          File.delete(path) if File.file?(path)
        rescue StandardError => e
          failures << "#{path}: #{e.message}"
        end
      end
      Array(directories).compact.uniq.sort_by { |path| -path.to_s.length }.each do |path|
        begin
          FileUtils.remove_entry(path) if File.directory?(path)
        rescue StandardError => e
          failures << "#{path}: #{e.message}"
        end
      end
      remaining = (Array(paths) + Array(directories)).compact.uniq.select do |path|
        File.exist?(path)
      end
      failures << "still present: #{remaining.join(', ')}" unless remaining.empty?
      unless failures.empty?
        raise RepresentationFidelity::ContractError,
              "owned temporary artifact cleanup failed: #{failures.join('; ')}"
      end
      true
    end

    def self.prepare_item_raster_page!(pdf_path, page_num, media_box,
                                       page_rotation, opts)
      exe = safe_find_pdftocairo
      raise RepresentationFidelity::ContractError,
            'pdftocairo is unavailable for item Raster' unless exe
      page_width = PageTransform.effective_width(media_box, page_rotation)
      page_height = PageTransform.effective_height(media_box, page_rotation)
      dpi_plan = compute_effective_raster_dpi(opts, page_width, page_height)
      dpi = dpi_plan[:effective].to_i
      source_path = File.expand_path(pdf_path.to_s)
      source_sha = cached_source_pdf_sha256!(opts, source_path)
      key = [source_path.downcase, source_sha, page_num.to_i, dpi,
             PageTransform.normalize_rotation(page_rotation)].join('|')
      candidates = []
      raw_path = nil
      owned_temp_dir = nil
      fetch_item_raster_page_cache!(opts, key) do
        owned_temp_dir = Dir.mktmpdir("bc_item_page_p#{page_num}_")
        png_path = File.join(owned_temp_dir, 'page.png')
        raw_path = File.join(owned_temp_dir, 'page.rgba')
        base_path = png_path.sub(/\.png\z/, '')
        candidates = [
          png_path, "#{base_path}-#{page_num}.png",
          "#{base_path}-01.png", "#{base_path}-1.png"
        ]
        args = [
          exe, '-png', '-transp', '-singlefile', '-r', dpi.to_s,
          '-f', page_num.to_i.to_s, '-l', page_num.to_i.to_s,
          source_path, base_path
        ]
        source_binding = begin_source_pdf_render_binding!(opts, source_path)
        run = CommandRunner.run(
          args, :timeout_s => 180, :context => 'Raster.item_page.pdftocairo'
        )
        verify_source_pdf_render_binding!(source_binding)
        validation = PopplerResultValidator.validate(
          run,
          :executable => exe, :argv => args,
          :context => 'Raster.item_page.pdftocairo',
          :page => page_num, :attempt => 1,
          :representation => :item_raster_page,
          :artifacts => candidates, :artifact_policy => :any_nonempty
        )
        PopplerResultValidator.log_rejection(validation, 'Raster') unless
          validation[:ok]
        unless validation[:ok] && !run[:timed_out]
          raise RepresentationFidelity::ContractError,
                'transparent item Raster page render was rejected'
        end
        actual_png = candidates.find { |candidate| File.file?(candidate) }
        raise RepresentationFidelity::ContractError,
              'transparent item Raster page PNG is missing' unless actual_png
        prepared = PngCropper.prepare_rgba!(actual_png, raw_path)
        expected_width = page_width.to_f * dpi.to_f / 72.0
        expected_height = page_height.to_f * dpi.to_f / 72.0
        unless (prepared[:pixel_width].to_f - expected_width).abs <= 2.0 &&
               (prepared[:pixel_height].to_f - expected_height).abs <= 2.0
          raise RepresentationFidelity::ContractError,
                'transparent item Raster page dimensions are misbound'
        end
        prepared.merge(
          :page_number => page_num.to_i,
          :page_rotation => PageTransform.normalize_rotation(page_rotation),
          :dpi => dpi,
          :arguments => args,
          :source_pdf_path => source_path,
          :source_pdf_sha256 => source_sha,
          :source_pdf_render_binding => source_binding,
          :source_pdf_binding_verified => true,
          :page_render_once_verified => true,
          :render_count => 1,
          :owned_temp_paths => (candidates + [raw_path]).uniq,
          :owned_temp_directories => [owned_temp_dir]
        )
      end
    rescue StandardError => original_error
      cleanup_paths = Array(defined?(candidates) && candidates)
      cleanup_paths << raw_path if defined?(raw_path) && raw_path
      begin
        cleanup_owned_temp_artifacts!(
          cleanup_paths, [defined?(owned_temp_dir) && owned_temp_dir].compact
        )
      rescue StandardError => cleanup_error
        raise RepresentationFidelity::ContractError,
              "#{original_error.message}; #{cleanup_error.message}"
      end
      raise original_error
    end

    def self.compute_effective_raster_dpi(opts, page_w_pts, page_h_pts)
      requested = (opts[:raster_dpi] || 300).to_i
      requested = 300 if requested <= 0
      requested = [[requested, 150].max, 1200].min

      # Safe sharpening default:
      # if user kept the legacy 300 DPI default, raise target modestly.
      desired = requested
      desired = 400 if requested <= 300

      page_w_in = page_w_pts.to_f / 72.0
      page_h_in = page_h_pts.to_f / 72.0
      page_area_in2 = page_w_in * page_h_in
      page_area_in2 = 1.0 if page_area_in2 <= 0.0 || !page_area_in2.finite?

      # Guardrail against giant raster allocations.
      pixel_budget = (opts[:raster_pixel_budget] || 120_000_000).to_i
      pixel_budget = [[pixel_budget, 25_000_000].max, 240_000_000].min
      cap_from_budget = Math.sqrt(pixel_budget.to_f / page_area_in2).floor
      cap_from_budget = [[cap_from_budget, 150].max, 1200].min

      effective = [desired, cap_from_budget].min
      effective = [[effective, 150].max, 1200].min

      {
        requested: requested,
        desired: desired,
        effective: effective,
        cap: cap_from_budget,
        pixel_budget: pixel_budget
      }
    rescue StandardError => e
      Logger.warn("Raster", "DPI planner failed: #{e.message}")
      { requested: 300, desired: 300, effective: 300, cap: 300, pixel_budget: 120_000_000 }
    end

    def self.import_item_as_raster(model, target_entities, pdf_path, page_num,
                                   item, media_box, opts, import_start,
                                   y_offset = 0.0, page_rotation = 0)
      image = nil
      owned_crop_dir = nil
      standalone_cache = opts[:item_raster_cache_persistent] != true
      source_id = RepresentationFidelity.source_span_id(item)
      page_render = prepare_item_raster_page!(
        pdf_path, page_num, media_box, page_rotation, opts
      )
      crop = item_raster_crop_geometry(
        item, media_box, page_rotation, page_render[:dpi]
      )
      owned_crop_dir = Dir.mktmpdir("bc_item_crop_p#{page_num}_")
      png_path = File.join(owned_crop_dir, 'crop.png')
      crop_proof = PngCropper.crop_rgba!(
        page_render, crop[:pixel_crop], png_path
      )
      artifact = verify_item_raster_artifact!(
        png_path, item, page_num, crop, page_render[:arguments], pdf_path,
        crop_proof, page_render[:source_pdf_sha256]
      )
      scale = opts[:scale].to_f
      scale = 1.0 if scale <= 0.0
      factor = (1.0 / 72.0) * scale
      display_box = crop[:display_box]
      placement = {
        :x => display_box[0].to_f * factor,
        :y => y_offset.to_f + (display_box[1].to_f * factor),
        :width => crop[:display_width].to_f * factor,
        :height => crop[:display_height].to_f * factor
      }
      point = Geom::Point3d.new(placement[:x], placement[:y], 0.0)
      image = target_entities.add_image(
        png_path, point, placement[:width], placement[:height]
      )
      return false unless image
      begin
        layer = model.layers['PDF Import: Text Fallback'] ||
          model.layers.add('PDF Import: Text Fallback')
        image.layer = layer if layer
      rescue StandardError => e
        Logger.warn('Raster', "item image layer assignment failed: #{e.message}")
      end
      begin
        if image.respond_to?(:set_attribute)
          dictionary = 'BC_PDF_Importer'
          image.set_attribute(dictionary, 'source_claim_root', true)
          image.set_attribute(dictionary, 'source_span_id', source_id)
          image.set_attribute(dictionary, 'source_kind', 'text_span')
          image.set_attribute(dictionary, 'representation', 'raster')
          image.set_attribute(
            dictionary, 'renderer', 'pdftocairo_transparent_page_crop'
          )
          image.set_attribute(dictionary, 'raster_page_number', page_num.to_i)
          image.set_attribute(
            dictionary, 'raster_page_rotation',
            PageTransform.normalize_rotation(page_rotation)
          )
          image.set_attribute(dictionary, 'raster_source_box', artifact[:source_box])
          image.set_attribute(dictionary, 'raster_pixel_crop', artifact[:pixel_crop])
          image.set_attribute(dictionary, 'raster_pixel_width', artifact[:pixel_width])
          image.set_attribute(dictionary, 'raster_pixel_height', artifact[:pixel_height])
          image.set_attribute(
            dictionary, 'raster_content_sha256', artifact[:content_sha256]
          )
          image.set_attribute(
            dictionary, 'raster_visual_pixel_sha256',
            artifact[:visual_pixel_sha256]
          )
          image.set_attribute(
            dictionary, 'raster_source_pdf_sha256',
            artifact[:source_pdf_sha256]
          )
          image.set_attribute(
            dictionary, 'raster_content_bytes', artifact[:content_byte_size]
          )
          image.set_attribute(
            dictionary, 'raster_alpha_verified',
            artifact[:alpha_channel_verified]
          )
          image.set_attribute(
            dictionary, 'raster_transparent_background_verified',
            artifact[:transparent_background_verified]
          )
          image.set_attribute(
            dictionary, 'raster_visible_pixel_verified',
            artifact[:visible_pixel_verified]
          )
          image.set_attribute(
            dictionary, 'raster_page_render_once_verified',
            artifact[:page_render_once_verified]
          )
          image.set_attribute(
            dictionary, 'raster_page_render_sha256',
            artifact[:page_render_content_sha256]
          )
        end
      rescue StandardError => e
        Logger.warn('Raster', "item image evidence attributes unavailable: #{e.message}")
      end
      Logger.info(
        'Raster',
        "Page #{page_num} #{source_id}: placed verified item raster " \
          "#{artifact[:pixel_width]}x#{artifact[:pixel_height]} px at " \
          "#{crop[:dpi]} DPI [#{(Time.now - import_start).round(1)}s]"
      )
      delivery = {
        :entity => image,
        :artifact_evidence => artifact,
        :placement => placement,
        :command => page_render[:arguments]
      }
      cleanup_owned_temp_artifacts!([png_path], [owned_crop_dir])
      owned_crop_dir = nil
      png_path = nil
      delivery
    rescue StandardError => e
      Logger.warn('Raster', "Item raster failed: #{e.message}")
      image ? {
        :failure => true,
        :error => e.message.to_s,
        :owned_entities => [image]
      } : false
    ensure
      cleanup_owned_temp_artifacts!(
        [defined?(png_path) && png_path].compact,
        [defined?(owned_crop_dir) && owned_crop_dir].compact
      )
      cleanup_item_raster_page_cache!(opts) if standalone_cache
    end

    def self.import_page_as_raster(model, pdf_path, page_num, media_box, opts,
                                   import_start, y_offset = 0.0,
                                   render_box = nil, page_rotation = 0)
      img = nil
      exe = safe_find_pdftocairo
      return false unless exe

      # Render/placement box (usually CropBox when available, else MediaBox).
      render_box = media_box unless render_box.is_a?(Array) && render_box.length >= 4
      page_w_pts = (render_box[2] - render_box[0]).abs
      page_h_pts = (render_box[3] - render_box[1]).abs
      page_w_pts = 612.0 if page_w_pts < 1
      page_h_pts = 792.0 if page_h_pts < 1
      dpi_plan = compute_effective_raster_dpi(opts, page_w_pts, page_h_pts)
      dpi = dpi_plan[:effective]

      use_cropbox = distinct_page_box?(render_box, media_box)

      # Render page to PNG
      owned_page_dir = Dir.mktmpdir("bc_page_raster_p#{page_num}_")
      png_path = File.join(owned_page_dir, 'page.png')
      candidates = [png_path,
       png_path.sub(/\.png$/, "-#{page_num}.png"),
       png_path.sub(/\.png$/, "-01.png"),
       png_path.sub(/\.png$/, "-1.png")
      ]
      variants = []
      variants << { :cropbox => true, :render_box => render_box } if use_cropbox
      variants << { :cropbox => false, :render_box => media_box }
      actual_png = nil
      actual_box = nil
      artifact_evidence = nil
      successful_args = nil

      variants.each_with_index do |variant, variant_index|
        candidates.each do |candidate|
          begin
            File.delete(candidate) if File.exist?(candidate)
          rescue StandardError
            # verification below rejects a stale/missing artifact
          end
        end
        args = [exe, '-png', '-singlefile', '-r', dpi.to_s]
        args << '-cropbox' if variant[:cropbox]
        args += [
          '-f', page_num.to_s, '-l', page_num.to_s,
          pdf_path, png_path.sub(/\.png$/, '')
        ]
        source_binding = begin_source_pdf_render_binding!(opts, pdf_path)
        run = CommandRunner.run(
          args,
          timeout_s: 180,
          context: "Raster.pdftocairo"
        )
        verify_source_pdf_render_binding!(source_binding)
        validation = PopplerResultValidator.validate(
          run,
          :executable => exe,
          :argv => args,
          :context => 'Raster.pdftocairo',
          :page => page_num,
          :attempt => variant_index + 1,
          :representation => :page_raster,
          :artifacts => candidates,
          :artifact_policy => :any_nonempty
        )
        PopplerResultValidator.log_rejection(
          validation, 'Raster'
        ) unless validation[:ok]
        attempt_ok = validation[:ok] && !run[:timed_out]
        unless attempt_ok
          candidates.each do |path|
            begin
              File.delete(path) if File.exist?(path)
            rescue StandardError => e
              Logger.warn('Raster', "cleanup rejected PNG failed: #{e.message}")
            end
          end
        end
        break if run[:timed_out]
        next unless attempt_ok
        candidate = candidates.find { |path| File.file?(path) }
        next unless candidate
        begin
          proof = verify_raster_artifact!(
            candidate, page_num, media_box, variant[:render_box],
            page_rotation, args, pdf_path, source_binding
          )
          actual_png = candidate
          actual_box = variant[:render_box]
          artifact_evidence = proof
          successful_args = args
          break
        rescue RepresentationFidelity::ContractError => e
          Logger.warn('Raster', "artifact rejected: #{e.message}")
          candidates.each do |path|
            begin
              File.delete(path) if File.exist?(path)
            rescue StandardError => cleanup_error
              Logger.warn(
                'Raster',
                "cleanup invalid PNG failed: #{cleanup_error.message}"
              )
            end
          end
        end
      end
      return false unless actual_png && artifact_evidence && actual_box

      scale = opts[:scale] || 1.0
      placement = raster_placement_geometry(
        media_box, actual_box, page_rotation, scale, y_offset
      )
      pt = Geom::Point3d.new(placement[:x], placement[:y], 0)
      begin
        img = model.active_entities.add_image(
          actual_png, pt, placement[:width], placement[:height]
        )
        return false unless img
        layer = model.layers['PDF Import'] || model.layers.add('PDF Import')
        begin
          img.layer = layer if layer
        rescue StandardError => e
          Logger.warn("Raster", "Image layer assignment failed: #{e.message}")
        end
        begin
          if img.respond_to?(:set_attribute)
            dictionary = 'BC_PDF_Importer'
            img.set_attribute(dictionary, 'raster_page_number', page_num.to_i)
            img.set_attribute(dictionary, 'raster_page_rotation',
                              PageTransform.normalize_rotation(page_rotation))
            img.set_attribute(dictionary, 'raster_render_box',
                              artifact_evidence[:render_box])
            img.set_attribute(dictionary, 'raster_pixel_width',
                              artifact_evidence[:pixel_width])
            img.set_attribute(dictionary, 'raster_pixel_height',
                              artifact_evidence[:pixel_height])
            img.set_attribute(dictionary, 'raster_content_sha256',
                              artifact_evidence[:content_sha256])
            img.set_attribute(dictionary, 'raster_visual_pixel_sha256',
                              artifact_evidence[:visual_pixel_sha256])
            img.set_attribute(dictionary, 'raster_content_bytes',
                              artifact_evidence[:content_byte_size])
            img.set_attribute(dictionary, 'raster_source_pdf_sha256',
                              artifact_evidence[:source_pdf_sha256])
          end
        rescue StandardError => e
          Logger.warn('Raster', "image evidence attributes unavailable: #{e.message}")
        end
        box_msg = artifact_evidence[:render_box_used] == :crop_box ?
          'cropbox' : 'mediabox'
        req = dpi_plan[:requested]
        cap = dpi_plan[:cap]
        sharpened = dpi > req
        status_suffix = sharpened ? " (enhanced)" : ""
        Sketchup.status_text = "PDF Import — Page #{page_num} — Raster image placed at #{dpi} DPI#{status_suffix} [#{(Time.now - import_start).round(1)}s]"
        Logger.info(
          "Raster",
          "Page #{page_num}: placed verified #{box_msg} raster " \
          "#{placement[:width].round(3)}x#{placement[:height].round(3)} in at " \
          "(#{pt.x.round(3)},#{pt.y.round(3)}), rotation=#{artifact_evidence[:page_rotation]}, " \
          "pixels=#{artifact_evidence[:pixel_width]}x#{artifact_evidence[:pixel_height]}, " \
          "dpi req=#{req}, eff=#{dpi}, cap=#{cap}, budget=#{dpi_plan[:pixel_budget]}"
        )
        delivery = {
          :entity => img,
          :artifact_evidence => artifact_evidence,
          :placement => placement,
          :command => successful_args
        }
        cleanup_owned_temp_artifacts!(candidates, [owned_page_dir])
        owned_page_dir = nil
        candidates = []
        delivery
      rescue StandardError => e
        Logger.warn("Raster", "add_image failed: #{e.message}")
        img ? {
          :failure => true,
          :error => e.message.to_s,
          :owned_entities => [img]
        } : false
      end
    rescue StandardError => e
      Logger.warn("Raster", "Failed: #{e.message}")
      img ? {
        :failure => true,
        :error => e.message.to_s,
        :owned_entities => [img]
      } : false
    ensure
      if defined?(candidates) && candidates
        cleanup_owned_temp_artifacts!(
          candidates,
          [defined?(owned_page_dir) && owned_page_dir].compact
        )
      end
    end

    # ================================================================
    # OPEN-TIME GATE — refuse malformed/unsupported PDFs cleanly
    # ================================================================
    # Mirrors the Python hosts' shared safe_open contract. Runs before
    # the import dialog / pipeline so a bad file shows one actionable
    # message (no Ruby traceback), logs a warning, and records the
    # structured reason in import_report.json.
    #
    # Returns the failure result Hash when the import should be aborted,
    # or nil when the file passed the gate. Pass show_ui: false for batch
    # imports so the per-file refusal is logged/recorded without stacking
    # message boxes (the batch summary reports the totals instead).
    def self.handle_open_gate(path, opts = {}, show_ui: true)
      result = PdfOpenGate.inspect_path(path)
      return nil if result[:ok]

      reason = result[:reason]
      message = result[:message]

      # Round 18: gate runs first at entry points; salvage may OVERRIDE a
      # refusal when poppler can normalize the file (empty-password encryption,
      # damaged xref — files every viewer opens). Salvage is memoized, so
      # run_pipeline's later prepare_if_needed reuses this result.
      # R21-18 / QQ-3: denylist skips salvage for not_a_pdf + file_missing
      # (file_missing cannot be memo-keyed; every retry would spawn doomed
      # pdftocairo). Prefer extending this denylist over flipping to an
      # allowlist — an allowlist would silently exclude future salvageable
      # reasons. Escape hatch: add/remove a reason here intentionally when a
      # new gate code should/shouldn't attempt salvage; keep file_missing and
      # not_a_pdf skipped (safety, not a product freeze).
      if reason.to_s != 'not_a_pdf' && reason.to_s != 'file_missing'
        begin
          _sp, note = PdfSalvage.prepare_if_needed(path)
          if note
            Logger.info("OpenGate", "gate '#{reason}' overridden: #{note}")
            return nil
          end
        rescue PdfSalvage::SalvageError => e
          message = e.message
        rescue StandardError => e
          Logger.warn("OpenGate", "salvage attempt failed: #{e.message}")
        end
      end

      Logger.reset if Logger.log_path.nil?
      Logger.warn("OpenGate",
        "Refusing #{path ? File.basename(path.to_s) : 'file'}: #{reason} — #{message}")
      record_open_failure_report(path, opts, reason, message)
      Logger.flush_log
      if show_ui && defined?(UI) && UI.respond_to?(:messagebox)
        UI.messagebox(message)
      end
      result
    rescue StandardError => e
      # Fail closed (Python-host parity): never admit the file because the
      # gate wrapper crashed. Record a visible refusal instead.
      Logger.warn("OpenGate", "gate check failed: #{e.message}")
      reason = 'unreadable'
      message = PdfOpenGate.message_for(reason)
      begin
        record_open_failure_report(path, opts, reason, message)
        Logger.flush_log
      rescue StandardError
        # best-effort diagnostics only
      end
      if show_ui && defined?(UI) && UI.respond_to?(:messagebox)
        UI.messagebox(message)
      end
      { ok: false, reason: reason, message: message }
    end

    def self.write_source_provenance_sidecar(pdf_path, opts, stats)
      objects = Array(stats[:source_provenance_objects])
      return nil if objects.empty?

      session_id = (stats[:import_session_id] || SourceProvenance.new_import_session_id).to_s
      sidecar_path = SourceProvenance.default_sidecar_path(pdf_path)
      SourceProvenance.write_sidecar(
        output_path: sidecar_path,
        import_session_id: session_id,
        pdf_path: pdf_path,
        objects: objects,
        version: BlueCollarSystems::PDFVectorImporter::VERSION,
        page_count: stats[:pages]
      )
    rescue StandardError => e
      Logger.warn('Pipeline', "source_provenance sidecar failed: #{e.message}")
      nil
    end

    def self.record_open_failure_report(path, opts, reason, message)
      report = QAReport.build_open_failure(path, opts, reason, message)
      QAReport.write_json(report, QAReport.default_output_path(path))
    rescue StandardError => e
      Logger.warn("OpenGate", "open-failure report write failed: #{e.message}")
      nil
    end

    # ================================================================
    # PUBLIC ENTRY POINTS
    # ================================================================
    def self.import_pdf
      model = Sketchup.active_model
      return UI.messagebox("No active model.") unless model
      path = UI.openpanel("Select PDF File", "", "PDF Files|*.pdf||")
      return unless path && File.exist?(path)
      return if handle_open_gate(path)
      begin
        opts = ImportDialog.show(path)
        return unless opts
        stats = run_pipeline(model, path, opts)
        if stats
          # No blocking every-import modal (owner rule). Concise result on
          # the status bar; full summary in import_report.json + Import Health.
          ReportDialog.announce(stats)
        else
          UI.messagebox("No vector content found in PDF.")
        end
      rescue StandardError => e
        safe_abort_operation(model, "Import")
        Logger.error("Import", "Import failed", e)
        log_hint = Logger.log_path ? "\n\nDetails saved to:\n#{Logger.log_path}" : ""
        UI.messagebox("PDF import failed:\n#{e.message}#{log_hint}")
      end
    end

    def self.import_pdf_safe
      model = Sketchup.active_model
      return UI.messagebox("No active model.") unless model
      path = UI.openpanel("Select PDF File (Safe Mode)", "", "PDF Files|*.pdf||")
      return unless path && File.exist?(path)
      return if handle_open_gate(path)

      begin
        # BCS-ARCH-001: safe mode uses explicit Vector extraction
        # (no raster fallback) — the most predictable pure-vector path.
        mode = ImportDialog::MODES['Vector'] || {}
        sym_attrs = {}
        mode.each { |k, v| sym_attrs[k.to_sym] = v }
        opts = ImportDialog.send(:build_opts, sym_attrs.merge(pages: 'All'))
        stats = run_pipeline(model, path, opts)
        unless stats
          UI.messagebox("No vector content found in PDF.")
        end
      rescue StandardError => e
        safe_abort_operation(model, "ImportSafe")
        Logger.error("ImportSafe", "Safe mode import failed", e)
        log_hint = Logger.log_path ? "\n\nDetails saved to:\n#{Logger.log_path}" : ""
        UI.messagebox("PDF import failed:\n#{e.message}#{log_hint}")
      end
    end

    def self.batch_import
      model = Sketchup.active_model
      return UI.messagebox("No active model.") unless model
      # UI.select_directory is not available in SketchUp Make (free) editions.
      # Fall back to an inputbox for the folder path.
      folder = if UI.respond_to?(:select_directory)
                 UI.select_directory(title: "Select Folder of PDFs")
               else
                 result = UI.inputbox(["Folder path:"], [""], "Select Folder of PDFs")
                 result ? result[0] : nil
               end
      return unless folder && File.directory?(folder)
      pdfs = (Dir.glob(File.join(folder, "*.pdf")) + Dir.glob(File.join(folder, "*.PDF"))).uniq
      return UI.messagebox("No PDF files found.") if pdfs.empty?
      return unless UI.messagebox("Import #{pdfs.length} PDF(s) with Auto mode?", MB_YESNO) == IDYES
      ok = 0; fail_c = 0
      # BCS-ARCH-001: batch import uses Auto mode — per-page strategy selection.
      mode_raw = ImportDialog::MODES['Auto']
      sym_attrs = {}
      mode_raw.each { |k, v| sym_attrs[k.to_sym] = v }
      pdfs.sort.each_with_index do |pdf, idx|
        Sketchup.status_text = "Batch: #{idx+1}/#{pdfs.length} #{File.basename(pdf)}"
        begin
          opts = ImportDialog.send(:build_opts, sym_attrs.merge(pages: 'All'))
          # Refuse bad PDFs quietly here; the summary box reports the count.
          if handle_open_gate(pdf, opts, show_ui: false)
            fail_c += 1
            next
          end
          ok += 1 if run_pipeline(model, pdf, opts)
        rescue StandardError => e
          fail_c += 1; Logger.error("Batch", File.basename(pdf), e)
        end
      end
      UI.messagebox("Batch: #{ok} imported, #{fail_c} failed, #{pdfs.length} total.")
    end

    def self.scale_by_reference; ScaleTool.activate; end
    def self.quick_scale; ScaleTool.quick_scale; end

    def self.cleanup_selected
      model = Sketchup.active_model; return unless model
      groups = model.selection.grep(Sketchup::Group)
      return UI.messagebox("Select groups to clean.") if groups.empty?
      model.start_operation("Cleanup", true)
      total = {}
      groups.each { |g| GeometryCleanup.cleanup(g.entities).each { |k,v| total[k]=(total[k]||0)+v } }
      model.commit_operation
      UI.messagebox("Cleanup:\n"+total.select{|_,v|v>0}.map{|k,v|"  #{v} #{k}"}.join("\n"))
    end

    def self.feature_inventory
      model = Sketchup.active_model; return unless model
      t = model.selection.grep(Sketchup::Group).first
      UI.messagebox(Metadata.report(t ? t.entities : model.active_entities))
    end

    def self.visibility_toggles; ReportDialog.show_visibility_menu; end

    # ================================================================
    # MENU & TOOLBAR
    # ================================================================
    if !@loaded && defined?(UI) && UI.respond_to?(:menu)
      UI.menu('File').add_item('Import PDF Vectors...') { self.import_pdf }

      sub = UI.menu('Extensions').add_submenu('PDF Vector Importer')
      sub.add_item('Import PDF...') { self.import_pdf }
      sub.add_item('Import PDF (Safe Mode)...') { self.import_pdf_safe }
      sub.add_item('Batch Import Folder...') { self.batch_import }
      sub.add_separator
      sub.add_item('Scale to Real Dimensions...') { self.scale_by_reference }
      sub.add_item('Quick Scale...') { self.quick_scale }
      sub.add_separator
      sub.add_item('Compatibility Report...') { CompatibilityReport.show }
      sub.add_item('Import Health...') { ImportHealth.show }
      sub.add_separator
      sub.add_item('About PDF Importer') {
        version = begin
          BlueCollarSystems::PDFVectorImporter::VERSION
        rescue NameError
          PLUGIN_VERSION
        end
        UI.messagebox(
          "PDF Vector Importer v#{version}\n" \
          "by BlueCollar Systems\n\n" \
          "Import PDF drawings as editable SketchUp geometry.\n\n" \
          "BUILT. NOT BOUGHT.")
      }

      @loaded = true
      DependencyResolver.maybe_show_first_run_notice
    end

    # ================================================================
    # File Importer — drag-drop + File > Import
    # Guarded: Sketchup::Importer only exists in SU 2017+ Pro/Make
    # (some early 2017 builds may lack it). If missing, the plugin
    # still works via the Extensions menu — just no File > Import.
    # ================================================================
    if defined?(Sketchup::Importer)
    class PDFFileImporter < Sketchup::Importer
      def description; "PDF Vector Drawings (*.pdf)"; end
      def file_extension; "pdf"; end
      def id; "com.bluecollar.pdfvectorimporter"; end
      def supports_options?; true; end

      def load_file(file_path, status)
        # Open-time gate: a clear message was already shown for bad files,
        # so report Canceled to suppress SketchUp's generic failure dialog.
        if BlueCollarSystems::PDFVectorImporter.handle_open_gate(file_path)
          return Sketchup::Importer::ImportCanceled
        end
        opts = ImportDialog.show(file_path)
        return Sketchup::Importer::ImportCanceled unless opts
        model = Sketchup.active_model
        return Sketchup::Importer::ImportFail unless model
        stats = BlueCollarSystems::PDFVectorImporter.run_pipeline(model, file_path, opts)
        stats ? Sketchup::Importer::ImportSuccess : Sketchup::Importer::ImportFail
      rescue StandardError => e
        BlueCollarSystems::PDFVectorImporter.safe_abort_operation(model, "PDFFileImporter")
        Logger.error("PDFFileImporter", "load_file failed", e)
        Sketchup::Importer::ImportFail
      end
    end
    end # if defined?(Sketchup::Importer)

    if defined?(Sketchup) && Sketchup.respond_to?(:add_observer)
      unless defined?(@@bc_pdf_version_observer) && @@bc_pdf_version_observer
        class BCPDFVersionObserver < Sketchup::AppObserver
          def expectsStartupModelNotifications
            false
          end

          def onExtensionsLoaded
            BlueCollarSystems::PDFVectorImporter::VersionNotice.check
          end
        end
        Sketchup.add_observer(BCPDFVersionObserver.new)
        @@bc_pdf_version_observer = true
      end
    end

  end
end
