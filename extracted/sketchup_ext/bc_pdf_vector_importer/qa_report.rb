# bc_pdf_vector_importer/qa_report.rb
# Shared import_report.json builder (bcs.import_report/1.1)
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'json'
require 'digest'
require 'fileutils'
require 'time'
require File.join(File.dirname(__FILE__), 'metadata')
require File.join(File.dirname(__FILE__), 'model_3d_extruder')
require File.join(File.dirname(__FILE__), 'model_3d_intent')
require File.join(File.dirname(__FILE__), 'parts_bootstrap')

module BlueCollarSystems
  module PDFVectorImporter
    module QAReport

      SCHEMA = 'bcs.import_report/1.1'.freeze
      SCALE_TRUST_CONFIDENCE = 0.70
      SCALE_DIMENSION_TENSION_CONFIDENCE = 0.85
      SCALE_FACTOR_DISAGREE_RATIO = 0.15
      PERFORMANCE_HINT_ENTITY_THRESHOLD = 50_000
      PERFORMANCE_HINT_PEAK_MB = 1024.0
      DELIVERED_TEXT_ENTITY_TYPES = %w[
        native_label native_3d_text outline_curve_or_mesh raw_geometry_edges
        dxf_text fallback_geometry
      ].freeze

      module_function

      def sample_process_mb
        if RUBY_PLATFORM =~ /mswin|mingw|cygwin/i
          size = `powershell -NoProfile -Command "(Get-Process -Id #{Process.pid}).WorkingSet64"`.strip.to_i
          return (size / 1024.0 / 1024.0).round(2) if size > 0
        elsif File.readable?('/proc/self/status')
          rss = File.read('/proc/self/status').each_line.find { |line| line.start_with?('VmRSS:') }
          if rss && rss =~ /(\d+)\s*kB/i
            return ($1.to_f / 1024.0).round(2)
          end
        end
        0.0
      rescue StandardError
        0.0
      end

      def build_from_stats(pdf_path, opts, stats)
        elapsed_ms = ((stats[:elapsed_seconds] || 0).to_f * 1000.0).round(1)
        layers = Array(stats[:layers]).compact
        warnings = Array(stats[:failed_pages]).length
        warnings += 1 if stats[:layer_warning]
        degraded_renderers = Array(stats[:text_renderers]).select do |entry|
          entry[:degraded] || entry['degraded']
        end
        warnings += degraded_renderers.length
        version = importer_version

        report = {
          schema: SCHEMA,
          host: {
            app: 'sketchup',
            version: sketchup_version
          },
          runtime: {
            lang: 'ruby',
            version: RUBY_VERSION
          },
          importer: {
            version: version
          },
          pdf_engine: {
            name: 'internal_ruby',
            version: version,
            wheel_tag: ''
          },
          input: input_block(pdf_path, stats),
          result: {
            primitives: stats[:primitives].to_i,
            text_entities: stats[:text].to_i,
            layers: layers.length,
            bbox: nil,
            warnings: warnings
          },
          performance: begin
            perf = {
              elapsed_ms: elapsed_ms,
              peak_mb: stats[:peak_mb].to_f > 0.0 ? stats[:peak_mb].to_f.round(2) : sample_process_mb
            }
            perf[:phases] = { total_ms: elapsed_ms } if elapsed_ms > 0
            perf
          end,
          fallback: fallback_block(stats, degraded_renderers),
          mode: import_mode_label(opts),
          report_meta: build_report_meta(version),
          extra: extra_block(stats, warnings, degraded_renderers, opts)
        }
        flags = pdf_interactive_flags(pdf_path)
        unless flags.empty?
          report[:extra][:pdf_interactive_flags] = flags
          report[:extra][:pdf_interactive_note] =
            'PDF contains document scripting/actions (' + flags.join(', ') +
            '). The importer never executes these; flagged for awareness ' \
            'to match the Python hosts (R2-6).'
        end
        enrich_report_extras!(report)
        attach_source_provenance!(report, stats)
        report
      end

      # Build a schema-consistent report for an open-time gate refusal
      # (malformed/encrypted/truncated PDF). The structured reason code is
      # carried on fallback.reason to match the Python hosts' enum.
      def build_open_failure(pdf_path, opts, reason, message)
        stats = {
          pages: 0, primitives: 0, edges: 0, text: 0, arcs: 0,
          layers: [], text_renderers: [], elapsed_seconds: 0.0
        }
        report = build_from_stats(pdf_path, opts || {}, stats)
        report[:result][:warnings] = 1
        report[:fallback] = {
          used: true,
          reason: reason.to_s,
          notes: message.to_s.empty? ? [] : [message.to_s]
        }
        report[:extra][:open_failure] = {
          reason: reason.to_s,
          message: message.to_s
        }
        enrich_report_extras!(report)
        report
      end

      # R2-6 parity with the Python hosts: detect document scripting /
      # auto-run actions so reports can flag them. Warn-only; the importer
      # never executes PDF actions. Raw-byte scan is deliberate — it works
      # on files the strict parser refuses. Ruby 2.2 compatible.
      def pdf_interactive_flags(pdf_path)
        return [] unless pdf_path && File.file?(pdf_path)
        raw = File.binread(pdf_path)
        flags = []
        flags << 'JavaScript' if raw =~ %r{/(?:JavaScript|JS)[\s/<\[(]}n
        flags << 'OpenAction' if raw =~ %r{/OpenAction[\s/<\[(]}n
        flags << 'AdditionalActions' if raw =~ %r{/AA[\s/<]}n
        flags
      rescue StandardError
        []
      end

      def write_json(report, output_path)
        path = output_path.to_s
        FileUtils.mkdir_p(File.dirname(path)) unless File.dirname(path).empty?
        File.write(path, JSON.pretty_generate(report) + "\n", encoding: 'UTF-8')
        path
      rescue StandardError => e
        Logger.warn('QAReport', "write_json failed: #{e.message}")
        nil
      end

      def default_output_path(pdf_path)
        base = File.basename(pdf_path.to_s, '.pdf')
        File.join(Dir.tmpdir, "#{base}_import_report.json")
      end

      def input_block(pdf_path, stats)
        block = {
          file: pdf_path.to_s,
          pages: stats[:pages].to_i
        }
        if pdf_path && File.file?(pdf_path)
          begin
            block[:sha256] = Digest::SHA256.file(pdf_path).hexdigest
          rescue StandardError
            # non-fatal
          end
        end
        block
      end

      def fallback_block(stats, degraded_renderers = [])
        degraded = Array(degraded_renderers)
        if stats[:raster_fallback_used]
          block = { used: true, reason: 'raster_fallback' }
        elsif degraded.empty?
          block = { used: false, reason: nil }
        else
          notes = degraded.map do |entry|
            entry[:note] || entry['note']
          end.compact.map(&:to_s).reject(&:empty?).uniq
          reason = if stats[:svg_renderer_missing]
                     'text_degraded_missing_svg_renderer'
                   elsif notes.include?('Poppler/MuPDF not found')
                     'text_degraded_missing_svg_renderer'
                   else
                     'text_degraded_svg_unavailable'
                   end
          block = {
            used: true,
            reason: reason,
            notes: notes
          }
        end

        text = text_mode_fallback_block(degraded)
        if text
          block[:used] = true
          block[:text] = text
          if block[:reason].nil? || block[:reason].to_s.empty?
            block[:reason] = "text_mode_fallback: #{text[:requested]} -> #{text[:delivered]} (#{text[:reason]})"
          end
        end
        block
      end

      # Ruby mirror of pdfcadcore.build_text_mode_fallback.  The surrounding
      # renderer list remains detailed per page/span; the compact fallback.text
      # field is the portable contract consumed by Import Health and support.
      def text_mode_fallback_block(degraded_renderers)
        selected = nil
        Array(degraded_renderers).each do |entry|
          requested = normalize_report_text_mode(
            entry[:requested_mode] || entry['requested_mode']
          )
          delivered = normalize_report_text_mode(
            entry[:delivered_mode] || entry['delivered_mode'] ||
            entry[:mode] || entry['mode'] || entry[:renderer] || entry['renderer']
          )
          next if requested.nil? || delivered.nil? || requested == delivered

          reason = (entry[:reason] || entry['reason']).to_s.strip
          reason = 'text_mode_substitution' if reason.empty?
          count = (entry[:count] || entry['count']).to_i
          count = 1 if count < 1
          if selected && selected[:requested] == requested &&
             selected[:delivered] == delivered && selected[:reason] == reason
            selected[:count] = selected[:count].to_i + count
          elsif delivered == 'raster'
            # A terminal page raster supersedes any prior per-span rescue for
            # the page; the visible result is raster, not the earlier label.
            selected = {
              requested: requested,
              delivered: delivered,
              reason: reason,
              count: count
            }
          elsif selected.nil?
            selected = {
              requested: requested,
              delivered: delivered,
              reason: reason,
              count: count
            }
          end
        end
        selected
      rescue StandardError
        nil
      end

      def normalize_report_text_mode(mode)
        case mode.to_s.strip.downcase
        when 'text3d', '3d_text', '3d text', 'add_3d_text' then '3d_text'
        when 'labels', 'label', 'add_text' then 'labels'
        when 'glyphs', 'glyph' then 'glyphs'
        when 'geometry', 'outlines', 'outline' then 'geometry'
        when 'raster', 'image' then 'raster'
        else nil
        end
      end

      def extra_block(stats, warning_count = 0, degraded_renderers = [], opts = {})
        renderers = Array(stats[:text_renderers]).map do |entry|
          normalize_json(entry)
        end
        {
          text_renderers: renderers,
          delivered_text_entity_counts: delivered_text_entity_counts(stats),
          edges: stats[:edges].to_i,
          arcs: stats[:arcs].to_i,
          text_mode: stats[:text_mode].to_s,
          source_text_count: explicit_stat_value(stats, :source_text_count),
          source_text_span_ids: normalize_json(
            Array(stats[:source_text_span_ids] || stats['source_text_span_ids'])
          ),
          svg_renderer_missing: !!stats[:svg_renderer_missing],
          font_substitution_note: stats[:font_substitution_note],
          resolved_scale: stats[:resolved_scale] ? normalize_json(stats[:resolved_scale]) : nil,
          recognition_skipped_pages: Array(stats[:recognition_skipped_pages]).map { |entry| normalize_json(entry) },
          embedded_images: stats[:embedded_images].to_i,
          embedded_images_placed: stats[:embedded_images_placed].to_i,
          embedded_image_dir: stats[:embedded_image_dir],
          embedded_image_paths: Array(stats[:embedded_image_paths] || stats[:embedded_image_files]).map(&:to_s),
          scale_hints: scale_hints_block(stats),
          diagnostics: diagnostics_block(stats, warning_count, degraded_renderers),
          model_3d_intent: model_3d_intent_block(stats),
          model_3d: model_3d_block(stats, opts),
          parts_bootstrap: parts_bootstrap_block(stats),
          text_height_crosscheck: text_height_crosscheck_block(stats),
          delivery_integrity: delivery_integrity_block(stats)
        }
      end

      def delivery_integrity_block(stats)
        provenance = text_provenance_evidence(stats)
        failures = Array(
          stats[:import_report_failures] || stats['import_report_failures']
        ).dup
        singular = stats[:import_report_failure] || stats['import_report_failure']
        failures << singular if singular && !failures.any? do |entry|
          entry.equal?(singular) || entry == singular
        end
        {
          failed_pages: normalize_json(
            Array(stats[:failed_pages] || stats['failed_pages'])
          ),
          telemetry_failure_counts: {
            initialization: (
              stats[:mesh_text_telemetry_initialization_failure_count] ||
              stats['mesh_text_telemetry_initialization_failure_count']
            ).to_i,
            record: (
              stats[:mesh_text_telemetry_record_failure_count] ||
              stats['mesh_text_telemetry_record_failure_count']
            ).to_i,
            invalid_sample: (
              stats[:mesh_text_telemetry_invalid_sample_count] ||
              stats['mesh_text_telemetry_invalid_sample_count']
            ).to_i,
            merge: (
              stats[:mesh_text_telemetry_merge_failure_count] ||
              stats['mesh_text_telemetry_merge_failure_count']
            ).to_i,
            outer_merge: (
              stats[:mesh_text_telemetry_outer_merge_failure_count] ||
              stats['mesh_text_telemetry_outer_merge_failure_count']
            ).to_i,
            font_substitution_merge: (
              stats[:text_font_substitution_merge_failure_count] ||
              stats['text_font_substitution_merge_failure_count']
            ).to_i
          },
          provenance_record_failure_count: (
            stats[:provenance_record_failure_count] ||
            stats['provenance_record_failure_count']
          ).to_i,
          text_provenance_invalid_entry_count:
            provenance[:invalid_entry_count].to_i,
          text_provenance_invalid_reasons:
            normalize_json(provenance[:invalid_reasons]),
          text_provenance_span_ids: provenance[:span_ids],
          text_provenance_span_entity_types:
            normalize_json(provenance[:span_entity_types]),
          text_provenance_span_resulting_entity_ids:
            normalize_json(provenance[:span_resulting_entity_ids]),
          source_text_span_ids: normalize_json(
            Array(
              stats[:source_text_span_ids] || stats['source_text_span_ids']
            )
          ),
          terminal_cleanup_failures: normalize_json(
            Array(
              stats[:terminal_cleanup_failures] ||
              stats['terminal_cleanup_failures']
            )
          ),
          terminal_cleanup_events: normalize_json(
            Array(
              stats[:terminal_cleanup_events] ||
              stats['terminal_cleanup_events']
            )
          ),
          terminal_text_delivery_records: normalize_json(
            Array(
              stats[:terminal_text_delivery_records] ||
              stats['terminal_text_delivery_records']
            )
          ),
          source_text_identity_failure_count: (
            stats[:source_text_identity_failure_count] ||
            stats['source_text_identity_failure_count']
          ).to_i,
          source_text_identity_failures: normalize_json(
            Array(
              stats[:source_text_identity_failures] ||
              stats['source_text_identity_failures']
            )
          ),
          import_report_failures: normalize_json(failures),
          report_publication_status: (
            stats[:import_report_publication_status] ||
            stats['import_report_publication_status']
          ).to_s,
          report_path: (
            stats[:import_report_path] || stats['import_report_path']
          ).to_s
        }
      rescue StandardError => e
        {
          failed_pages: [],
          telemetry_failure_counts: { integrity_block: 1 },
          provenance_record_failure_count: 1,
          text_provenance_invalid_entry_count: 1,
          text_provenance_invalid_reasons: ['integrity_block_exception'],
          text_provenance_span_ids: [],
          text_provenance_span_entity_types: {},
          text_provenance_span_resulting_entity_ids: {},
          source_text_span_ids: [],
          terminal_cleanup_failures: [],
          terminal_cleanup_events: [],
          terminal_text_delivery_records: [],
          source_text_identity_failure_count: 1,
          source_text_identity_failures: [],
          import_report_failures: [
            { stage: 'generation', reason: e.message.to_s }
          ],
          report_publication_status: 'failed',
          report_path: ''
        }
      end

      def telemetry_numeric_value(value)
        return nil if value.nil?
        return nil if value.respond_to?(:empty?) && value.empty?
        number = value.is_a?(Numeric) ? value.to_f : Float(value.to_s)
        return nil unless number.finite? && number > 0.0
        number
      rescue StandardError
        nil
      end

      def numeric_summary(values)
        valid = []
        missing = 0
        invalid = 0
        Array(values).each do |value|
          if value.nil? || (value.respond_to?(:empty?) && value.empty?)
            missing += 1
            next
          end
          number = telemetry_numeric_value(value)
          if number
            valid << number
          else
            invalid += 1
          end
        end
        valid.sort!
        if valid.empty?
          return {
            count: 0, min: 0.0, median: 0.0, max: 0.0,
            missing_count: missing, invalid_count: invalid
          }
        end
        {
          count: valid.length,
          min: valid.first.round(8),
          median: begin
            middle = valid.length / 2
            value = if valid.length.even?
                      (valid[middle - 1] + valid[middle]) / 2.0
                    else
                      valid[middle]
                    end
            value.round(8)
          end,
          max: valid.last.round(8),
          missing_count: missing,
          invalid_count: invalid
        }
      end

      def telemetry_field(sample, field)
        return nil unless sample.respond_to?(:[])
        sample[field] || sample[field.to_s]
      rescue StandardError
        nil
      end

      def value_counts(samples, field)
        counts = {}
        Array(samples).each do |sample|
          value = telemetry_field(sample, field)
          next if value.nil? || value.to_s.empty?
          key = value.to_s
          counts[key] = counts.fetch(key, 0) + 1
        end
        counts
      end

      # Round 20: preserve one normalized attempt for every native-mesh call.
      # PDF em and SketchUp letter height remain distinct; only local X is fit.
      def text_height_crosscheck_block(stats)
        raw_samples = Array(
          stats[:mesh_text_telemetry] || stats['mesh_text_telemetry']
        )
        samples = raw_samples.select { |sample| sample.is_a?(Hash) }
        fallbacks = (
          stats[:text_height_fallback_count] ||
          stats['text_height_fallback_count']
        ).to_i

        if samples.empty? && raw_samples.empty?
          legacy = Array(
            stats[:text_height_samples] || stats['text_height_samples']
          )
          letter = numeric_summary(legacy)
          return nil if legacy.empty? && fallbacks.zero?
          return {
            sample_count: letter[:count],
            min_in: letter[:min],
            median_in: letter[:median],
            max_in: letter[:max],
            policy: 'legacy_letter_height_samples',
            fallback_count: fallbacks,
            height_fallback_count: fallbacks,
            note: 'Legacy delivered SketchUp letter-height samples.'
          }
        end

        outcomes = value_counts(samples, :outcome)
        phases = value_counts(samples, :failure_phase)
        fits = value_counts(samples, :fit_status)
        letter = numeric_summary(
          samples.map do |sample|
            telemetry_field(sample, :sketchup_letter_height_in)
          end
        )
        normalized_attempts = samples.map { |sample| normalize_json(sample) }
        superseded = samples.inject(0) do |count, sample|
          value = telemetry_field(sample, :superseded_by_raster)
          count + (value == true || value.to_s == 'true' ? 1 : 0)
        end
        representation_fallbacks = samples.inject(0) do |count, sample|
          requested = telemetry_field(sample, :requested_mode).to_s
          delivered = telemetry_field(sample, :delivered_mode).to_s
          changed = !requested.empty? && !delivered.empty? &&
                    delivered != 'none' && requested != delivered
          count + (changed ? 1 : 0)
        end
        height_fallback_reasons = value_counts(samples, :height_fallback_reason)
        visual_height_correction_reasons =
          value_counts(samples, :visual_height_correction_reason)
        visual_height_correction_count =
          visual_height_correction_reasons.values.inject(0) do |sum, value|
            sum + value.to_i
          end
        {
          sample_count: samples.length,
          invalid_sample_count: raw_samples.length - samples.length,
          attempts: normalized_attempts,
          min_in: letter[:min],
          median_in: letter[:median],
          max_in: letter[:max],
          policy: 'pdf_em_x_font_metric_then_local_x',
          pdf_em_height_in: numeric_summary(
            samples.map { |sample| telemetry_field(sample, :pdf_em_height_in) }
          ),
          nominal_sketchup_letter_height_in: numeric_summary(
            samples.map do |sample|
              telemetry_field(sample, :nominal_sketchup_letter_height_in)
            end
          ),
          sketchup_letter_height_in: letter,
          letter_height_ratio: numeric_summary(
            samples.map { |sample| telemetry_field(sample, :letter_height_ratio) }
          ),
          metric_sources: value_counts(samples, :metric_source),
          matrix_x: numeric_summary(
            samples.map { |sample| telemetry_field(sample, :matrix_x) }
          ),
          residual_x: numeric_summary(
            samples.map { |sample| telemetry_field(sample, :residual_x) }
          ),
          total_x: numeric_summary(
            samples.map { |sample| telemetry_field(sample, :total_x) }
          ),
          outcome_counts: outcomes,
          failure_phase_counts: phases,
          failure_reason_counts: value_counts(samples, :failure_reason),
          cleanup_outcome_counts: value_counts(samples, :cleanup_outcome),
          fit_status_counts: fits,
          fit_reason_counts: value_counts(samples, :fit_reason),
          requested_mode_counts: value_counts(samples, :requested_mode),
          delivered_mode_counts: value_counts(samples, :delivered_mode),
          fitted_count: fits.fetch('fitted', 0),
          skipped_count: fits.fetch('skipped', 0),
          rejected_outlier_count: fits.fetch('rejected_outlier', 0),
          failed_transform_count:
            phases.fetch('scale', 0) +
            phases.fetch('translation', 0) +
            phases.fetch('rotation', 0),
          superseded_by_raster_count: superseded,
          fallback_count: fallbacks,
          height_fallback_count: fallbacks,
          metric_fallback_count: fallbacks,
          representation_fallback_count: representation_fallbacks,
          height_fallback_reasons: height_fallback_reasons,
          visual_height_correction_count: visual_height_correction_count,
          visual_height_correction_reasons: visual_height_correction_reasons,
          font_substitutions:
            value_counts(samples, :font_substitution_reason),
          telemetry_record_failure_count: (
            stats[:mesh_text_telemetry_record_failure_count] ||
            stats['mesh_text_telemetry_record_failure_count']
          ).to_i,
          telemetry_initialization_failure_count: (
            stats[:mesh_text_telemetry_initialization_failure_count] ||
            stats['mesh_text_telemetry_initialization_failure_count']
          ).to_i,
          telemetry_invalid_sample_count: (
            stats[:mesh_text_telemetry_invalid_sample_count] ||
            stats['mesh_text_telemetry_invalid_sample_count']
          ).to_i,
          telemetry_merge_failure_count: (
            stats[:mesh_text_telemetry_merge_failure_count] ||
            stats['mesh_text_telemetry_merge_failure_count']
          ).to_i,
          telemetry_outer_merge_failure_count: (
            stats[:mesh_text_telemetry_outer_merge_failure_count] ||
            stats['mesh_text_telemetry_outer_merge_failure_count']
          ).to_i,
          font_substitution_merge_failure_count: (
            stats[:text_font_substitution_merge_failure_count] ||
            stats['text_font_substitution_merge_failure_count']
          ).to_i,
          note: 'PDF em height is converted by a trusted font-level ratio; ' \
                'only local X may be reconciled.'
        }
      rescue StandardError => e
        Logger.warn('QAReport', "text height crosscheck failed: #{e.message}")
        {
          sample_count: 0,
          policy: 'telemetry_summary_error',
          error: e.message.to_s
        }
      end

      def model_3d_intent_block(stats)
        payload = stats[:model_3d_intent] || stats['model_3d_intent']
        return normalize_json(payload) if payload.is_a?(Hash)

        texts = stats[:model_3d_texts] || stats['model_3d_texts'] ||
                stats[:text_items] || stats['text_items'] || []
        normalize_json(Model3DIntent.analyze(texts, host_supports_3d: true))
      rescue StandardError => e
        {
          feasible: false,
          plates: [],
          members: [],
          skipped_reason: "3D intent analysis failed: #{e.message}"
        }
      end

      def model_3d_block(_stats, _opts = {})
        # 3D shape extrusion is shelved pending 3D-text scaling resolution.
        # The UI and CLI both hardcode extrude_to_3d=false; always report disabled
        # regardless of any legacy stats payload that may have been populated.
        normalize_json(
          enabled: false, supported: false, faces_extruded: 0, skipped_reason: 'shelved_by_owner'
        )
      rescue StandardError
        { 'enabled' => false, 'supported' => false, 'skipped_reason' => 'report_error' }
      end

      def parts_bootstrap_block(stats)
        payload = stats[:parts_bootstrap] || stats['parts_bootstrap']
        return normalize_json(payload) if payload.is_a?(Hash)

        pages_map = stats[:page_text_map] || stats['page_text_map'] || {}
        return { schema: PartsBootstrap::SCHEMA, table_count: 0, row_count: 0, tables: [] } if pages_map.empty?

        normalize_json(PartsBootstrap.build(pages_map, session_id: stats[:import_session_id]))
      rescue StandardError
        { schema: PartsBootstrap::SCHEMA, table_count: 0, row_count: 0, tables: [], error: 'extraction_error' }
      end

      def scale_hints_block(stats)
        generic = stats[:generic] || {}
        hints = {
          title_block_detected: !!generic[:title_block],
          dimension_count: generic[:dimensions].to_i
        }
        alternate = stats[:alternate_scale_factors]
        hints[:alternate_scale_factors] = Array(alternate).map(&:to_f) if alternate
        hints
      end

      def enrich_report_extras!(report)
        crosscheck = build_scale_crosscheck(report[:extra] || {})
        report[:extra][:scale_crosscheck] = normalize_json(crosscheck) if crosscheck
        hint = build_performance_hint(report)
        report[:extra][:performance_hint] = hint if hint
        entity_info = build_actual_text_entity_types(report)
        report[:extra][:actual_text_entity_types] = normalize_json(entity_info) if entity_info
        report[:extra][:human_summary] = build_human_summary(report)
        contract = build_import_contract_ready(report)
        report[:extra][:import_contract_ready] = contract if contract
      end

      def build_import_contract_ready(report)
        extra = report[:extra] || {}
        meta = report[:report_meta] || {}
        open_failure = extra[:open_failure] || extra['open_failure']
        has_stamp = !meta[:build_stamp].to_s.strip.empty?
        has_crosscheck = extra.key?(:scale_crosscheck) || extra.key?('scale_crosscheck')
        text_count = (report[:result] || {})[:text_entities].to_i
        has_entity_types = extra.key?(:actual_text_entity_types) || extra.key?('actual_text_entity_types')
        text_ok = text_count <= 0 || has_entity_types
        integrity = extra[:delivery_integrity] || extra['delivery_integrity'] || {}
        terminal_delivery_evidence = terminal_text_delivery_evidence(integrity)
        failed_pages = Array(
          integrity[:failed_pages] || integrity['failed_pages']
        )
        telemetry_counts = integrity[:telemetry_failure_counts] ||
                           integrity['telemetry_failure_counts'] || {}
        telemetry_failures = telemetry_counts.values.inject(0) do |sum, value|
          sum + value.to_i
        end
        crosscheck = extra[:text_height_crosscheck] ||
                     extra['text_height_crosscheck']
        policy = crosscheck.is_a?(Hash) ?
                   (crosscheck[:policy] || crosscheck['policy']).to_s : ''
        crosscheck_invalid = crosscheck.is_a?(Hash) ?
          (crosscheck[:invalid_sample_count] ||
           crosscheck['invalid_sample_count']).to_i : 0
        attempts = crosscheck.is_a?(Hash) ?
          Array(crosscheck[:attempts] || crosscheck['attempts']) : []
        attempt_records_present = crosscheck.is_a?(Hash) && (
          !attempts.empty? ||
          (crosscheck[:sample_count] || crosscheck['sample_count']).to_i > 0 ||
          crosscheck_invalid > 0
        )
        text_mode = (extra[:text_mode] || extra['text_mode']).to_s
        source_count_present = extra.key?(:source_text_count) ||
                               extra.key?('source_text_count')
        source_count = strict_nonnegative_integer(
          extra[:source_text_count] || extra['source_text_count']
        )
        active_text_mode = !normalize_report_text_mode(text_mode).nil?
        source_count_valid = source_count_present && !source_count.nil?
        source_count_valid = true unless active_text_mode || source_count_present
        identity_failure_count = (
          integrity[:source_text_identity_failure_count] ||
          integrity['source_text_identity_failure_count']
        ).to_i
        identity_failures = Array(
          integrity[:source_text_identity_failures] ||
          integrity['source_text_identity_failures']
        )
        expected_source_span_ids = Array(
          integrity[:source_text_span_ids] ||
          integrity['source_text_span_ids']
        ).map { |identity| identity.to_s.strip }
        source_span_ledger_required = active_text_mode || source_count_present
        source_span_ledger_valid = if source_span_ledger_required
                                     canonical_source_span_id_ledger?(
                                       expected_source_span_ids, source_count
                                     )
                                   else
                                     true
                                   end
        source_text_identity_integrity = identity_failure_count.zero? &&
                                         identity_failures.empty? &&
                                         source_span_ledger_valid
        entity_types = extra[:actual_text_entity_types] ||
                       extra['actual_text_entity_types'] || {}
        native_entity_count = (
          entity_types[:native_3d_text] || entity_types['native_3d_text']
        ).to_i
        native_attempt_present = native_entity_count > 0 || attempts.any? do |sample|
          telemetry_field(sample, :requested_mode).to_s == 'text3d' ||
            telemetry_field(sample, :delivered_mode).to_s == 'text3d'
        end
        native_required = native_attempt_present ||
                          (normalize_report_text_mode(text_mode) == '3d_text' &&
                           source_count_valid && source_count.to_i > 0)
        valid_attempts = !attempts.empty? && crosscheck_invalid.zero? &&
                         attempts.all? { |sample| valid_mesh_attempt_evidence?(sample) }
        attempt_evidence = attempt_records_present ? valid_attempts : !native_required
        source_identity = (!attempt_records_present && !native_required) ||
                          (!attempts.empty? && attempts.all? do |sample|
          !telemetry_field(sample, :source_span_id).to_s.strip.empty?
        end)
        terminal_delivery = attempts.all? do |sample|
          delivered = telemetry_field(sample, :delivered_mode).to_s
          !delivered.empty? && delivered != 'none'
        end && terminal_delivery_evidence[:invalid_entry_count].to_i.zero?
        cleanup_failures = Array(
          integrity[:terminal_cleanup_failures] ||
          integrity['terminal_cleanup_failures']
        )
        cleanup_verified = cleanup_failures.empty? &&
                           terminal_delivery_evidence[:invalid_entry_count].to_i.zero? &&
                           attempts.all? do |sample|
          cleanup = telemetry_field(sample, :cleanup_outcome).to_s
          terminal_cleanup = telemetry_field(
            sample, :terminal_cleanup_outcome
          ).to_s
          delivered = telemetry_field(sample, :delivered_mode).to_s
          base_cleanup_ok = %w[complete not_required].include?(cleanup)
          terminal_cleanup_ok = if delivered == 'raster'
                                  terminal_cleanup == 'verified'
                                else
                                  terminal_cleanup.empty? ||
                                    terminal_cleanup == 'verified'
                                end
          base_cleanup_ok && terminal_cleanup_ok
        end
        metric_fallbacks = crosscheck.is_a?(Hash) ?
          (crosscheck[:metric_fallback_count] ||
           crosscheck['metric_fallback_count']).to_i : 0
        reason_counts = crosscheck.is_a?(Hash) ?
          (crosscheck[:height_fallback_reasons] ||
           crosscheck['height_fallback_reasons'] || {}) : {}
        reason_total = reason_counts.values.inject(0) do |sum, value|
          sum + value.to_i
        end
        height_fallback_reasons = metric_fallbacks == reason_total
        report_failures = Array(
          integrity[:import_report_failures] ||
          integrity['import_report_failures']
        )
        generation_ok = report_failures.none? do |failure|
          %w[generation report_generation build].include?(
            telemetry_field(failure, :stage).to_s
          )
        end
        publication_ok = report_failures.none? do |failure|
          stage = telemetry_field(failure, :stage).to_s
          %w[
            publication report_publication parts_bootstrap_sidecar
            source_provenance_sidecar sidecar
          ].include?(stage)
        end
        publication_status = (
          integrity[:report_publication_status] ||
          integrity['report_publication_status']
        ).to_s
        publication_path = (
          integrity[:report_path] || integrity['report_path']
        ).to_s.strip
        publication_ok = false unless publication_status == 'published' &&
                                      !publication_path.empty?
        telemetry_ok = telemetry_failures.zero? && crosscheck_invalid.zero? &&
                       policy != 'telemetry_summary_error'
        provenance_failure_count = (
          integrity[:provenance_record_failure_count] ||
          integrity['provenance_record_failure_count']
        ).to_i
        provenance_invalid_count = (
          integrity[:text_provenance_invalid_entry_count] ||
          integrity['text_provenance_invalid_entry_count']
        ).to_i
        provenance_span_ids = Array(
          integrity[:text_provenance_span_ids] ||
          integrity['text_provenance_span_ids']
        ).map(&:to_s).reject(&:empty?).uniq
        provenance_span_types =
          integrity[:text_provenance_span_entity_types] ||
          integrity['text_provenance_span_entity_types'] || {}
        provenance_span_resulting_ids =
          integrity[:text_provenance_span_resulting_entity_ids] ||
          integrity['text_provenance_span_resulting_entity_ids'] || {}
        terminal_raster_span_ids = terminal_delivery_evidence[:span_ids]
        delivered_span_ids = (provenance_span_ids + terminal_raster_span_ids).uniq
        source_delivery_accounted = if !source_count_valid
                                      false
                                    elsif source_count.to_i == 0
                                      text_count <= 0 && provenance_span_ids.empty? &&
                                        terminal_raster_span_ids.empty? &&
                                        attempts.empty? && source_span_ledger_valid
                                    else
                                      source_span_ledger_valid &&
                                        (provenance_span_ids &
                                         terminal_raster_span_ids).empty? &&
                                        delivered_span_ids.sort ==
                                          expected_source_span_ids.sort
                                    end
        attempt_provenance_consistent = attempts.all? do |sample|
          delivered = telemetry_field(sample, :delivered_mode).to_s
          span_id = telemetry_field(sample, :source_span_id).to_s
          if delivered == 'raster'
            record = terminal_delivery_evidence[:records].find do |entry|
              telemetry_field(entry, :source_span_id).to_s == span_id
            end
            attempt_ids = stable_resulting_entity_ids(
              telemetry_field(sample, :resulting_entity_ids)
            )
            record_ids = record && stable_resulting_entity_ids(
              telemetry_field(record, :resulting_entity_ids)
            )
            next terminal_raster_span_ids.include?(span_id) && attempt_ids &&
                 record_ids && attempt_ids.sort == record_ids.sort
          end
          types = provenance_span_types[span_id] || []
          expected = case delivered
                     when 'text3d' then 'native_3d_text'
                     when 'labels' then 'native_label'
                     else nil
                     end
          attempt_ids = stable_resulting_entity_ids(
            telemetry_field(sample, :resulting_entity_ids)
          )
          provenance_ids = stable_resulting_entity_ids(
            Array(provenance_span_resulting_ids[span_id])
          )
          !expected.nil? && Array(types).map(&:to_s).include?(expected) &&
            attempt_ids && provenance_ids &&
            attempt_ids.sort == provenance_ids.sort
        end
        provenance_ok = provenance_failure_count.zero? &&
                         provenance_invalid_count.zero? &&
                         attempt_provenance_consistent
        renderer_provenance_consistency = renderer_provenance_consistent?(
          extra, {
            counts: (extra[:delivered_text_entity_counts] ||
                     extra['delivered_text_entity_counts'] || {})
          }, terminal_delivery_evidence, source_count
        )
        actual_type_evidence = text_count <= 0 || has_entity_types
        checks = {
          build_stamp: has_stamp,
          scale_crosscheck: has_crosscheck,
          actual_text_entity_types: text_ok,
          actual_text_type_evidence: actual_type_evidence,
          source_text_count_valid: source_count_valid,
          source_text_identity_integrity: source_text_identity_integrity,
          source_text_delivery_accounted: source_delivery_accounted,
          provenance_integrity: provenance_ok,
          renderer_provenance_consistency: renderer_provenance_consistency,
          terminal_delivery_record_integrity:
            terminal_delivery_evidence[:invalid_entry_count].to_i.zero?,
          no_open_failure: open_failure.nil?,
          no_failed_pages: failed_pages.empty?,
          telemetry_integrity: telemetry_ok,
          native_3d_attempt_evidence: attempt_evidence,
          native_3d_source_identity: source_identity,
          cleanup_verified: cleanup_verified,
          terminal_delivery: terminal_delivery,
          height_fallback_reasons: height_fallback_reasons,
          report_failure_ledger: report_failures.empty?,
          report_generation: generation_ok,
          report_publication: publication_ok
        }
        ready = checks.values.all?
        {
          ready: ready,
          checks: checks,
          failed_checks: checks.keys.reject { |key| checks[key] },
          note: 'Fail-closed import delivery and evidence integrity checks.'
        }
      end

      def valid_mesh_attempt_evidence?(sample)
        return false unless sample.is_a?(Hash)
        page = telemetry_field(sample, :page).to_i
        identity = telemetry_field(sample, :source_span_id).to_s.strip
        requested = telemetry_field(sample, :requested_mode).to_s
        delivered = telemetry_field(sample, :delivered_mode).to_s
        outcome = telemetry_field(sample, :outcome).to_s
        cleanup = telemetry_field(sample, :cleanup_outcome).to_s
        history = telemetry_field(sample, :attempt_history)
        return false if page <= 0 || identity.empty? || requested.empty?
        return false if delivered.empty? || delivered == 'none' || outcome.empty?
        return false if cleanup.empty? || cleanup == 'not_attempted'
        return false unless history.is_a?(Array) && !history.empty?
        return false unless history.all? do |entry|
          next false unless entry.is_a?(Hash)
          mode = telemetry_field(entry, :mode).to_s
          rung_outcome = telemetry_field(entry, :outcome).to_s
          next false if mode.empty? || rung_outcome.empty?
          failed = rung_outcome == 'failed' || rung_outcome.start_with?('failed_')
          !failed || !telemetry_field(entry, :reason).to_s.strip.empty?
        end
        first_mode = telemetry_field(history.first, :mode).to_s
        return false unless first_mode == requested
        terminal_mode = telemetry_field(history.last, :delivered_mode).to_s
        return false unless terminal_mode == delivered
        return false if telemetry_field(sample, :representation_fallback_allowed) == false
        if delivered == 'raster'
          return false unless telemetry_field(sample, :terminal_cleanup_outcome).to_s == 'verified'
          return true
        end
        if delivered == 'labels'
          return false unless terminal_mode == 'labels'
          ids = stable_resulting_entity_ids(
            telemetry_field(sample, :resulting_entity_ids)
          )
          history_ids = stable_resulting_entity_ids(
            telemetry_field(history.last, :resulting_entity_ids)
          )
          return false unless ids && history_ids && ids.sort == history_ids.sort
          return true
        end
        return false unless delivered == 'text3d'
        ids = stable_resulting_entity_ids(
          telemetry_field(sample, :resulting_entity_ids)
        )
        history_ids = stable_resulting_entity_ids(
          telemetry_field(history.last, :resulting_entity_ids)
        )
        return false unless ids && history_ids && ids.sort == history_ids.sort
        return false unless %w[complete fallback_text3d].include?(outcome)
        return false unless telemetry_field(sample, :visual_fidelity_verified) == true
        return false unless telemetry_field(sample, :source_height_verified) == true
        return false unless telemetry_field(sample, :height_fallback_reason).to_s.strip.empty?
        return false unless telemetry_field(sample, :fit_status).to_s == 'fitted'
        return false unless telemetry_field(sample, :fit_measurement_verified) == true

        numeric_fields = [
          :pdf_em_height_in, :sketchup_letter_height_in,
          :letter_height_ratio, :matrix_x, :residual_x, :total_x
        ]
        numeric_fields.all? do |field|
          !telemetry_numeric_value(telemetry_field(sample, field)).nil?
        end && !telemetry_field(sample, :delivered_font).to_s.strip.empty?
      rescue StandardError
        false
      end

      def attach_source_provenance!(report, stats)
        objects = Array(stats[:source_provenance_objects] || stats['source_provenance_objects'])
        return if objects.empty?

        session_id = (stats[:import_session_id] || stats['import_session_id']).to_s.strip
        if session_id.empty?
          begin
            require 'securerandom'
            session_id = SecureRandom.uuid
          rescue StandardError
            session_id = ''
          end
        end

        report[:extra][:source_provenance] = {
          schema: 'bcs.source_provenance/1.0',
          import_session_id: session_id,
          object_count: objects.length
        }
        sidecar = stats[:source_provenance_sidecar_path] || stats['source_provenance_sidecar_path']
        report[:extra][:source_provenance][:sidecar_path] = sidecar.to_s unless sidecar.to_s.empty?
      end

      def build_report_meta(version)
        semver = version.to_s.strip
        {
          build_stamp: ['sketchup', semver].reject(&:empty?).join(' '),
          host: 'sketchup',
          semver: semver,
          report_sha256: '',
          imported_at: Time.now.utc.iso8601
        }
      end

      def build_actual_text_entity_types(report)
        extra = report[:extra] || {}
        delivered_counts = extra[:delivered_text_entity_counts] ||
                           extra['delivered_text_entity_counts']
        delivered_info = build_actual_text_entity_types_from_delivered_counts(delivered_counts)
        return delivered_info if delivered_info
        nil
      end

      # Native builders append one source-provenance object for every text
      # entity they actually create.  Prefer those delivered types whenever
      # available: the requested text-mode string cannot describe a legitimate
      # TEXTMODE-1 fallback such as 3D Text -> Labels.
      def delivered_text_entity_counts(stats)
        text_provenance_evidence(stats)[:counts]
      rescue StandardError
        {}
      end

      def explicit_stat_value(stats, key)
        return nil unless stats.respond_to?(:key?)
        return stats[key] if stats.key?(key)
        string_key = key.to_s
        return stats[string_key] if stats.key?(string_key)
        nil
      rescue StandardError
        nil
      end

      def strict_nonnegative_integer(value)
        return nil if value.nil? || value == true || value == false
        if value.is_a?(Integer)
          return value >= 0 ? value : nil
        end
        if value.is_a?(Numeric)
          number = value.to_f
          return nil unless number.finite? && number >= 0.0 && number == number.to_i.to_f
          return number.to_i
        end
        text = value.to_s.strip
        return nil unless text =~ /\A\d+\z/
        text.to_i
      rescue StandardError
        nil
      end

      def stable_resulting_entity_ids(value)
        return nil unless value.is_a?(Array)
        ids = value.map { |identity| identity.to_s.strip }
        return nil if ids.empty? || ids.uniq.length != ids.length
        pattern = /\A(?:persistent_id|entity_id):.+\z/
        return nil unless ids.all? { |identity| identity =~ pattern }
        ids
      rescue StandardError
        nil
      end

      def canonical_source_span_id_ledger?(value, source_count)
        return false unless value.is_a?(Array)
        return false if source_count.nil? || source_count.to_i < 0
        ids = value.map { |identity| identity.to_s.strip }
        return false unless ids.length == source_count.to_i
        return false unless ids.uniq.length == ids.length

        page_indexes = {}
        ids.each do |identity|
          match = /\Atext_span:(\d+):(\d+)\z/.match(identity)
          return false unless match && match[1].to_i > 0
          page = match[1].to_i
          page_indexes[page] ||= []
          page_indexes[page] << match[2].to_i
        end
        page_indexes.each_value do |indexes|
          sorted = indexes.sort
          expected = (0...sorted.length).to_a
          return false unless sorted == expected
        end
        true
      rescue StandardError
        false
      end

      def terminal_text_delivery_evidence(integrity)
        records = Array(
          integrity[:terminal_text_delivery_records] ||
          integrity['terminal_text_delivery_records']
        )
        events = Array(
          integrity[:terminal_cleanup_events] ||
          integrity['terminal_cleanup_events']
        )
        seen_span_ids = {}
        valid_records = []
        invalid = 0

        records.each do |record|
          unless record.is_a?(Hash)
            invalid += 1
            next
          end
          page = telemetry_field(record, :page).to_i
          span_id = telemetry_field(record, :source_span_id).to_s.strip
          requested = normalize_report_text_mode(
            telemetry_field(record, :requested_mode)
          )
          delivered = normalize_report_text_mode(
            telemetry_field(record, :delivered_mode)
          )
          scope = telemetry_field(record, :delivery_scope).to_s
          cleanup = telemetry_field(record, :cleanup_outcome).to_s
          reason = telemetry_field(record, :reason).to_s.strip
          entity_ids = Array(
            telemetry_field(record, :resulting_entity_ids)
          ).map { |value| value.to_s.strip }.reject(&:empty?)
          identity_pattern = /\A(?:persistent_id|entity_id):.+\z/
          fields_ok = page > 0 &&
                      span_id =~ /\Atext_span:#{page}:\d+\z/ &&
                      !requested.nil? && delivered == 'raster' &&
                      scope == 'page_raster' && cleanup == 'verified' &&
                      !reason.empty? && !entity_ids.empty? &&
                      entity_ids.uniq.length == entity_ids.length &&
                      entity_ids.all? { |identity| identity =~ identity_pattern }
          event_ok = events.any? do |event|
            next false unless event.is_a?(Hash)
            event_page = telemetry_field(event, :page).to_i
            event_cleanup = telemetry_field(event, :cleanup_outcome).to_s
            event_mode = normalize_report_text_mode(
              telemetry_field(event, :delivered_mode)
            )
            event_spans = Array(
              telemetry_field(event, :source_span_ids)
            ).map { |value| value.to_s.strip }.reject(&:empty?)
            event_ids = Array(
              telemetry_field(event, :resulting_entity_ids)
            ).map { |value| value.to_s.strip }.reject(&:empty?)
            event_page == page && event_cleanup == 'verified' &&
              event_mode == 'raster' && event_spans.include?(span_id) &&
              entity_ids.all? { |identity| event_ids.include?(identity) }
          end
          if !fields_ok || !event_ok || seen_span_ids.key?(span_id)
            invalid += 1
            next
          end
          seen_span_ids[span_id] = true
          valid_records << record
        end

        {
          records: valid_records,
          span_ids: seen_span_ids.keys,
          invalid_entry_count: invalid
        }
      rescue StandardError
        { records: [], span_ids: [], invalid_entry_count: 1 }
      end

      def renderer_provenance_consistent?(extra, provenance,
                                          terminal_delivery,
                                          source_count)
        renderers = Array(extra[:text_renderers] || extra['text_renderers'])
        declared = {
          'native_3d_text' => 0,
          'native_label' => 0,
          'raster' => 0
        }
        relevant = 0
        renderers.each do |entry|
          next unless entry.is_a?(Hash)
          has_requested = entry.key?(:requested_mode) ||
                          entry.key?('requested_mode')
          has_delivered = entry.key?(:delivered_mode) ||
                          entry.key?('delivered_mode')
          has_count = entry.key?(:count) || entry.key?('count')
          next unless has_requested || has_delivered || has_count
          return false unless has_requested && has_delivered && has_count

          count = strict_nonnegative_integer(telemetry_field(entry, :count))
          requested = normalize_report_text_mode(
            telemetry_field(entry, :requested_mode)
          )
          delivered = normalize_report_text_mode(
            telemetry_field(entry, :delivered_mode)
          )
          return false if count.nil? || count <= 0 || requested.nil? ||
                          delivered.nil?
          case delivered
          when '3d_text'
            declared['native_3d_text'] += count
          when 'labels'
            declared['native_label'] += count
          when 'raster'
            declared['raster'] += count
          else
            # Geometry/Glyphs final-delivery evidence is intentionally not
            # synthesized from requested mode or dormant renderer paths.
            return false
          end
          relevant += 1
        end

        return false if source_count.to_i > 0 && relevant.zero?
        counts = provenance[:counts] || {}
        return false unless declared['native_3d_text'] ==
                            counts.fetch('native_3d_text', 0).to_i
        return false unless declared['native_label'] ==
                            counts.fetch('native_label', 0).to_i
        other_provenance = counts.inject(0) do |sum, pair|
          kind, value = pair
          if %w[native_3d_text native_label].include?(kind.to_s)
            sum
          else
            sum + value.to_i
          end
        end
        return false unless other_provenance.zero?
        declared['raster'] == terminal_delivery[:records].length
      rescue StandardError
        false
      end

      def text_provenance_evidence(stats)
        counts = {}
        span_ids = []
        span_entity_types = {}
        span_resulting_entity_ids = {}
        span_records = {}
        seen_object_ids = {}
        seen_resulting_entity_ids = {}
        invalid_reasons = []
        invalid = 0
        objects = Array(
          stats[:source_provenance_objects] || stats['source_provenance_objects']
        )
        objects.each do |entry|
          unless entry.is_a?(Hash)
            invalid += 1
            invalid_reasons << 'entry_not_hash'
            next
          end
          source_kind = (entry[:source_kind] || entry['source_kind']).to_s.strip
          entity_type = (
            entry[:created_entity_type] || entry['created_entity_type']
          ).to_s.strip
          relevant = source_kind == 'text_span' ||
                     DELIVERED_TEXT_ENTITY_TYPES.include?(entity_type)
          next unless relevant

          span_id = (entry[:span_id] || entry['span_id']).to_s.strip
          unless source_kind == 'text_span' && !span_id.empty? &&
                 DELIVERED_TEXT_ENTITY_TYPES.include?(entity_type)
            invalid += 1
            invalid_reasons << 'invalid_text_provenance_fields'
            next
          end

          resulting_entity_ids = stable_resulting_entity_ids(
            entry[:resulting_entity_ids] || entry['resulting_entity_ids']
          )
          unless resulting_entity_ids
            invalid += 1
            invalid_reasons << "invalid_resulting_entity_ids:#{span_id}"
            next
          end
          duplicate_identity = resulting_entity_ids.find do |identity|
            seen_resulting_entity_ids.key?(identity)
          end
          if duplicate_identity
            invalid += 1
            invalid_reasons << "duplicate_resulting_entity_id:#{duplicate_identity}"
            next
          end

          object_id = (entry[:object_id] || entry['object_id']).to_s.strip
          existing = span_records[span_id] || []
          if existing.any? { |record| record[:entity_type].to_s != entity_type }
            invalid += 1
            invalid_reasons << "conflicting_entity_type:#{span_id}"
            next
          end
          if !object_id.empty? && seen_object_ids.key?(object_id)
            invalid += 1
            invalid_reasons << "duplicate_object_id:#{object_id}"
            next
          end
          if !existing.empty? && (
               object_id.empty? ||
               existing.any? { |record| record[:object_id].to_s.empty? }
             )
            invalid += 1
            invalid_reasons << "duplicate_span_without_fragment_identity:#{span_id}"
            next
          end

          seen_object_ids[object_id] = true unless object_id.empty?
          resulting_entity_ids.each do |identity|
            seen_resulting_entity_ids[identity] = true
          end
          span_records[span_id] ||= []
          span_records[span_id] << {
            entity_type: entity_type,
            object_id: object_id,
            resulting_entity_ids: resulting_entity_ids
          }
          counts[entity_type] = counts.fetch(entity_type, 0).to_i + 1
          span_ids << span_id unless span_ids.include?(span_id)
          span_entity_types[span_id] ||= []
          unless span_entity_types[span_id].include?(entity_type)
            span_entity_types[span_id] << entity_type
          end
          span_resulting_entity_ids[span_id] ||= []
          span_resulting_entity_ids[span_id].concat(resulting_entity_ids)
        end
        {
          counts: counts,
          span_ids: span_ids,
          span_entity_types: span_entity_types,
          span_resulting_entity_ids: span_resulting_entity_ids,
          invalid_entry_count: invalid,
          invalid_reasons: invalid_reasons
        }
      rescue StandardError
        {
          counts: {}, span_ids: [], span_entity_types: {},
          span_resulting_entity_ids: {},
          invalid_entry_count: 1,
          invalid_reasons: ['provenance_evidence_exception']
        }
      end

      def build_actual_text_entity_types_from_delivered_counts(raw_counts)
        return nil unless raw_counts.respond_to?(:each)

        supported = DELIVERED_TEXT_ENTITY_TYPES
        counts = {}
        raw_counts.each do |kind, value|
          key = kind.to_s.strip
          next unless supported.include?(key)
          number = value.to_i
          counts[key] = number if number > 0
        end
        total = counts.values.inject(0) { |sum, value| sum + value.to_i }
        return nil if total <= 0

        entity_kinds = counts.keys
        entity_type = if entity_kinds.length > 1
                        'mixed'
                      elsif counts['native_label']
                        'labels'
                      elsif counts['native_3d_text']
                        '3d_text'
                      elsif counts['outline_curve_or_mesh'] || counts['raw_geometry_edges']
                        'geometry'
                      elsif counts['dxf_text']
                        'dxf_text'
                      else
                        'fallback_geometry'
                      end
        info = {
          entity_type: entity_type,
          count: total,
          font_rendered: !!(counts['native_label'] || counts['native_3d_text']),
          examples: []
        }
        counts.each { |kind, value| info[kind.to_sym] = value }
        info
      rescue StandardError
        nil
      end

      def build_scale_crosscheck(extra)
        scale = extra[:resolved_scale] || extra['resolved_scale'] || {}
        scale = {} unless scale.is_a?(Hash)

        hints = extra[:scale_hints] || extra['scale_hints'] || {}
        hints = {} unless hints.is_a?(Hash)

        title_block = !!(hints[:title_block_detected] || hints['title_block_detected'])
        dimension_count = (hints[:dimension_count] || hints['dimension_count']).to_i
        alternate_factors = hints[:alternate_scale_factors] || hints['alternate_scale_factors'] || []

        warnings = []
        reasons = []

        conf = scale[:confidence] || scale['confidence']
        conf = conf.to_f if conf
        factor = scale[:factor] || scale['factor']
        fallback = (scale[:fallback_reason] || scale['fallback_reason']).to_s.strip
        source = (scale[:source] || scale['source']).to_s.strip

        if fallback == 'no_scale_detected' || factor.nil?
          warnings << 'No drawing scale was detected in the title block or page text — verify manually before takeoff.'
          reasons << 'no_scale_detected'
        elsif conf && conf < SCALE_TRUST_CONFIDENCE
          warnings << "Scale detection confidence is low (#{(conf * 100).round}%) — verify with manual scale tools before takeoff."
          reasons << 'low_confidence'
        end

        if title_block && !source.empty? && source != 'titleblock' && factor
          warnings << 'A title block was detected but scale came from other page text — compare the title-block notation.'
          reasons << 'titleblock_source_mismatch'
        end

        if title_block && dimension_count >= 3 && conf && conf < SCALE_DIMENSION_TENSION_CONFIDENCE && factor
          warnings << "Title-block scale may disagree with #{dimension_count} detected dimension strings — spot-check one known dimension."
          reasons << 'titleblock_dimension_tension'
        end

        primary = factor.to_f if factor
        if primary && primary > 0 && alternate_factors.is_a?(Array)
          alternate_factors.each do |alt|
            alt_factor = alt.to_f
            next unless alt_factor > 0
            if (alt_factor - primary).abs / [primary, alt_factor].max > SCALE_FACTOR_DISAGREE_RATIO
              warnings << 'Multiple scale notations on the sheet disagree — confirm which scale applies to this view.'
              reasons << 'conflicting_scale_notations'
              break
            end
          end
        end

        return nil if warnings.empty?

        {
          level: 'warn',
          reasons: unique_strings(reasons),
          messages: unique_strings(warnings),
          banner: warnings.first
        }
      end

      def build_performance_hint(report)
        data = normalize_json(report)
        result = data['result'] || {}
        perf = data['performance'] || {}
        entities = result['primitives'].to_i + result['text_entities'].to_i
        peak = perf['peak_mb'].to_f
        if entities >= PERFORMANCE_HINT_ENTITY_THRESHOLD || peak >= PERFORMANCE_HINT_PEAK_MB
          return 'Large PDF - on PCs with less than 8 GB RAM, import one page at a time using the Pages field.'
        end
        nil
      end

      def diagnostics_block(stats, warning_count = 0, degraded_renderers = [])
        primitives = stats[:primitives].to_i
        text_entities = stats[:text].to_i
        embedded_images = stats[:embedded_images].to_i
        layer_count = Array(stats[:layers]).compact.length
        text_mode = stats[:text_mode].to_s
        source_spans = stats[:text_source_spans].to_i
        glyph_estimate = stats[:text_glyph_estimate].to_i
        signals = []
        actions = []

        quality_level =
          if primitives >= 50
            signals << 'good_vector_content'
            'high'
          elsif primitives >= 10
            signals << 'limited_vector_content'
            'moderate'
          elsif primitives > 0
            signals << 'very_limited_vector_content'
            'low'
          elsif embedded_images > 0
            signals << 'embedded_images_extracted'
            'image_only'
          else
            signals << 'no_vector_geometry_created'
            'empty'
          end
        signals << 'embedded_images_extracted' if embedded_images > 0

        fallback = fallback_block(stats, degraded_renderers)
        if fallback[:used] || fallback['used']
          reason = (fallback[:reason] || fallback['reason']).to_s
          signals << 'fallback_used'
          if reason.downcase.include?('raster')
            actions << 'If editable geometry is required, retry Vector or Hybrid mode and confirm the PDF contains vector data.'
          else
            actions << 'Review the fallback reason and attach the import report when requesting support.'
          end
        end

        text_fallback = fallback[:text] || fallback['text'] || {}
        requested_mode = (text_fallback[:requested] || text_fallback['requested']).to_s
        delivered_mode = (text_fallback[:delivered] || text_fallback['delivered']).to_s
        unless requested_mode.empty? || delivered_mode.empty?
          signals << 'text_mode_fallback'
          actions << "Requested text mode '#{requested_mode}' was delivered as '#{delivered_mode}' — see fallback.text in this report for the reason."
        end

        if warning_count.to_i > 0
          signals << 'warnings_present'
          actions << 'Review the warning count and last import log before trusting the drawing for production use.'
        end

        signals << (layer_count.zero? ? 'no_pdf_layers_detected' : 'pdf_layers_preserved')

        unless text_mode.empty?
          signals << "text_mode_#{text_mode}"
          if %w[glyphs geometry].include?(text_mode)
            actions << 'Use Labels or 3D Text mode when editable text is more important than exact glyph outlines.'
          elsif %w[labels text3d 3d_text].include?(text_mode)
            actions << 'Use Geometry or Glyphs mode when exact visual text outlines are more important than editability.'
          end
        end

        if source_spans > 0 && text_entities.zero?
          signals << 'source_text_seen_but_no_text_entities_created'
          actions << 'Retest with another text mode and compare the text_source_spans count against visible text.'
        end

        if glyph_estimate >= 1000
          signals << 'dense_text_glyph_workload'
          actions << 'For heavy PDFs on older PCs, import one page first and compare Labels versus Glyphs/Geometry performance.'
        end

        if !Array(stats[:recognition_skipped_pages]).empty?
          signals << 'semantic_recognition_skipped_for_speed'
          actions << 'Geometry was imported, but heavy-page semantic recognition was skipped; use a smaller page range if you need semantic report details.'
        end

        {
          quality_level: quality_level,
          signals: unique_strings(signals),
          recommended_actions: unique_strings(actions)
        }
      end

      def unique_strings(values)
        seen = {}
        Array(values).map(&:to_s).map(&:strip).reject(&:empty?).each_with_object([]) do |value, out|
          next if seen[value]
          seen[value] = true
          out << value
        end
      end

      def normalize_json(value)
        case value
        when Hash
          value.each_with_object({}) do |(k, v), out|
            out[k.to_s] = normalize_json(v)
          end
        when Array
          value.map { |item| normalize_json(item) }
        when Symbol
          value.to_s
        when Float
          value.finite? ? value : nil
        else
          value
        end
      end

      def import_mode_label(opts)
        return 'raster' if opts[:force_raster]
        mode = (opts[:import_mode] || opts[:mode] || 'auto').to_s
        mode.empty? ? 'auto' : mode
      end

      def build_human_summary(report)
        data = normalize_json(report)
        host = 'SketchUp'
        input = data['input'] || {}
        result = data['result'] || {}
        perf = data['performance'] || {}
        fallback = data['fallback'] || {}
        extra = data['extra'] || {}
        diagnostics = extra['diagnostics'] || {}

        pages = input['pages'].to_i
        primitives = result['primitives'].to_i
        text_count = result['text_entities'].to_i
        layers = result['layers'].to_i
        warnings = result['warnings'].to_i
        elapsed_ms = perf['elapsed_ms'].to_f
        elapsed_s = elapsed_ms > 0 ? (elapsed_ms / 1000.0) : 0.0
        mode = data['mode'].to_s
        text_mode = format_text_mode(extra['text_mode'])
        pdf_name = File.basename(input['file'].to_s)
        pdf_name = 'the PDF' if pdf_name.empty?

        parts = []
        page_phrase = pages > 0 ? "#{pages} page#{'s' if pages != 1}" : 'the PDF'
        lead = "Imported #{page_phrase} from #{pdf_name} into #{host} using #{mode} mode"
        lead += " with #{text_mode}" unless text_mode.empty?
        parts << lead

        outcome = []
        outcome << "#{primitives} vector primitive#{'s' if primitives != 1}" if primitives > 0
        outcome << "#{text_count} text item#{'s' if text_count != 1}" if text_count > 0
        outcome << "#{layers} PDF layer#{'s' if layers != 1}" if layers > 0
        parts << if outcome.empty?
                   'No editable geometry was created'
                 else
                   "Created #{outcome.join(', ')}"
                 end
        parts << "in #{format('%.1f', elapsed_s)}s" if elapsed_s > 0

        scale = extra['resolved_scale']
        if scale.is_a?(Hash) && scale['factor']
          scale_bit = "Scale resolved from #{scale['source'].to_s.tr('_', ' ')}"
          notation = scale['notation'].to_s.strip
          scale_bit += " (#{notation})" unless notation.empty?
          if scale['confidence']
            scale_bit += ", confidence #{(scale['confidence'].to_f * 100).round}%"
          end
          parts << scale_bit
        end

        if fallback['used']
          reason = fallback['reason'].to_s.tr('_', ' ')
          parts << "Raster or degraded fallback was used (#{reason})"
        elsif primitives > 0
          parts << 'Vector extraction completed without raster fallback'
        end

        quality = diagnostics['quality_level'].to_s
        parts << "Overall fidelity: #{quality}" unless quality.empty?

        if warnings > 0
          parts << "#{warnings} warning#{'s' if warnings != 1} recorded — review the import log before production use"
        end

        crosscheck = extra['scale_crosscheck']
        if crosscheck.is_a?(Hash)
          banner = crosscheck['banner'].to_s.strip
          parts << "Scale note: #{banner.sub(/\.\z/, '')}" unless banner.empty?
        end

        paragraph = parts.map { |part| part.to_s.sub(/\.\z/, '') }.reject(&:empty?).join('. ')
        paragraph += '.' unless paragraph.empty? || paragraph.end_with?('.')
        paragraph
      end

      def format_text_mode(mode)
        labels = {
          'geometry' => 'geometry text',
          'glyphs' => 'glyph geometry',
          'text3d' => '3D text',
          '3d_text' => '3D text',
          'labels' => 'labels'
        }
        key = mode.to_s.strip
        labels[key] || key.tr('_', ' ')
      end

      def importer_version
        BlueCollarSystems::PDFVectorImporter.const_get(:VERSION)
      rescue NameError
        'unknown'
      end

      def sketchup_version
        if defined?(Sketchup) && Sketchup.respond_to?(:version)
          Sketchup.version.to_s
        else
          'headless'
        end
      rescue StandardError
        'unknown'
      end

    end
  end
end
