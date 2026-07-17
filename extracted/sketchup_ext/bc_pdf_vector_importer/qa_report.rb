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
          text_width_crosscheck: text_width_crosscheck_block(stats),
          glyph_source: glyph_source_block(stats)
        }
      end

      # Round 23 (F-1): which glyph SOURCE produced the Glyphs-mode outlines
      # (TEXTMODE-1: the delivered mode stays Glyphs; the source is reported,
      # never silently swapped). Present only when a Glyphs-mode import ran.
      #   source                 cairo_svg (bundled pdftocairo), mupdf_svg
      #                          (installed mutool), or internal (StrokeFont
      #                          lettering fallback).
      #   fallback_reason        why the preferred cairo source was not used
      #                          (pdftocairo_missing/_failed/_timeout,
      #                          svg_zero_placements) or null.
      #   runs_matched/unmatched extractor text spans with / without rendered
      #                          glyph ink at their declared position (R17-3
      #                          span matching keeps span_ids attached).
      #   placements_unmatched   rendered glyph ink the extractor never
      #                          declared (disagreement, reported not hidden).
      #   missing_fonts /        poppler stderr diagnostics captured even when
      #   missing_language_packs the process exits 0 — dropped runs are loud.
      def glyph_source_block(stats)
        src = stats[:glyph_source] || stats['glyph_source']
        return nil unless src.respond_to?(:[])
        reason = src[:fallback_reason] || src['fallback_reason']
        out = {
          source: (src[:source] || src['source']).to_s,
          fallback_reason: reason.nil? ? nil : reason.to_s,
          pages: (src[:pages] || src['pages']).to_i,
          runs_matched: (src[:runs_matched] || src['runs_matched']).to_i,
          runs_unmatched: (src[:runs_unmatched] || src['runs_unmatched']).to_i,
          placements_unmatched: (src[:placements_unmatched] ||
                                 src['placements_unmatched']).to_i,
          note: 'Glyphs-mode outline source (R23). cairo_svg/mupdf_svg stamp ' \
                'the PDF fonts\' own glyph outlines; internal is StrokeFont ' \
                'lettering (degraded, reported). runs_* position-match ' \
                'extractor spans to rendered glyph ink (R17-3).'
        }
        fonts = Array(src[:missing_fonts] || src['missing_fonts']).map { |v| v.to_s }
        packs = Array(src[:missing_language_packs] ||
                      src['missing_language_packs']).map { |v| v.to_s }
        out[:missing_fonts] = fonts unless fonts.empty?
        out[:missing_language_packs] = packs unless packs.empty?
        out
      rescue StandardError
        nil
      end

      # Round 20 (R20-1b/R20-2): report faithful mesh-text target heights and
      # the height-fallback count so Import Health / Report Doctor can
      # distinguish SIZE issues from host runtime issues.
      def text_height_crosscheck_block(stats)
        samples = Array(stats[:text_height_samples] || stats['text_height_samples'])
          .map { |v| v.to_f }
          .select { |v| v > 0.0 }
          .sort
        fallbacks = (stats[:text_height_fallback_count] ||
                     stats['text_height_fallback_count']).to_i
        return nil if samples.empty? && fallbacks.zero?

        mid = samples.empty? ? 0.0 : samples[samples.length / 2]
        {
          sample_count: samples.length,
          min_in: (samples.first || 0.0).round(5),
          median_in: mid.round(5),
          max_in: (samples.last || 0.0).round(5),
          policy: 'nominal_pt_to_inch_x_scale',
          fallback_count: fallbacks,
          note: 'Heights are faithful nominal PDF targets (pt/72 x scale). ' \
                'fallback_count > 0 means the height safety floor engaged ' \
                '(R20-2) and text may render at the 0.01" minimum.'
        }
      rescue StandardError
        nil
      end

      # Round 22: report the width-fidelity factors applied to native 3D text
      # runs (condensed title-block parity) so Import Health / Report Doctor
      # can tell width compression from height problems. Mirrors
      # text_height_crosscheck. Factors are declared/rendered run-width
      # ratios; the height axis factor is always exactly 1.0.
      def text_width_crosscheck_block(stats)
        samples = Array(stats[:text_width_factor_samples] ||
                        stats['text_width_factor_samples'])
          .map { |v| v.to_f }
          .select { |v| v > 0.0 }
          .sort
        out_of_bounds = (stats[:text_width_out_of_bounds_count] ||
                         stats['text_width_out_of_bounds_count']).to_i
        skipped_near_1 = (stats[:text_width_skipped_near_1_count] ||
                          stats['text_width_skipped_near_1_count']).to_i
        errors = (stats[:text_width_error_count] ||
                  stats['text_width_error_count']).to_i
        if samples.empty? && out_of_bounds.zero? && skipped_near_1.zero? && errors.zero?
          return nil
        end

        mid = samples.empty? ? 0.0 : samples[samples.length / 2]
        {
          sample_count: samples.length,
          samples: samples.map { |v| v.round(5) },
          min_factor: (samples.first || 0.0).round(5),
          median_factor: mid.round(5),
          max_factor: (samples.last || 0.0).round(5),
          policy: 'declared_span_width_over_rendered_run_width',
          out_of_bounds_count: out_of_bounds,
          skipped_near_1_count: skipped_near_1,
          error_count: errors,
          note: 'Horizontal-only run-axis factors compressing/expanding 3D ' \
                'text to the PDF-declared span extent (R22). Height axis is ' \
                'always exactly 1.0. out_of_bounds_count > 0 means spans ' \
                'kept their natural width because the factor left 0.25..4.0.'
        }
      rescue StandardError
        nil
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
        ready = has_stamp && has_crosscheck && text_ok && open_failure.nil?
        {
          ready: ready,
          checks: {
            build_stamp: has_stamp,
            scale_crosscheck: has_crosscheck,
            actual_text_entity_types: text_ok,
            no_open_failure: open_failure.nil?
          },
          note: 'diagnostics stub — Report Doctor may recompute client-side'
        }
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

        stats_mode = extra[:text_mode] || extra['text_mode']
        mode = stats_mode.to_s.strip.downcase
        return nil if mode.empty? || mode == 'none'

        result = report[:result] || {}
        total = result[:text_entities].to_i
        return nil if total <= 0

        rendered = %w[labels label 3d_text text3d].include?(mode)
        info = {
          entity_type: mode,
          count: total,
          font_rendered: rendered,
          examples: []
        }
        case mode
        when 'labels', 'label'
          info[:native_label] = total
        when '3d_text', 'text3d'
          info[:native_3d_text] = total
        when 'glyphs', 'geometry', 'outlines'
          info[:outline_curve_or_mesh] = total
        else
          info[:fallback_geometry] = total
        end
        info
      end

      # Native builders append one source-provenance object for every text
      # entity they actually create.  Prefer those delivered types whenever
      # available: the requested text-mode string cannot describe a legitimate
      # TEXTMODE-1 fallback such as 3D Text -> Labels.
      def delivered_text_entity_counts(stats)
        counts = {}
        Array(stats[:source_provenance_objects] || stats['source_provenance_objects']).each do |entry|
          next unless entry.respond_to?(:[])
          kind = (entry[:created_entity_type] || entry['created_entity_type']).to_s.strip
          next if kind.empty?
          counts[kind] = counts.fetch(kind, 0).to_i + 1
        end
        counts
      rescue StandardError
        {}
      end

      def build_actual_text_entity_types_from_delivered_counts(raw_counts)
        return nil unless raw_counts.respond_to?(:each)

        supported = %w[
          native_label native_3d_text outline_curve_or_mesh raw_geometry_edges
          dxf_text fallback_geometry
        ]
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

        # Round 23 (F-1): Glyphs-mode source telemetry must fail VISIBLE —
        # an internal-source delivery, unmatched runs, or a dropped CID
        # language pack are signals, never silent passes.
        glyph_source = glyph_source_block(stats)
        if glyph_source
          if glyph_source[:source] == 'internal'
            signals << 'glyph_source_internal_fallback'
            actions << "Glyphs mode delivered internal stroke-outline lettering (#{glyph_source[:fallback_reason]}) — restore the bundled Poppler pdftocairo for embedded-font glyph outlines."
          end
          if glyph_source[:runs_unmatched].to_i > 0
            signals << 'glyph_runs_unmatched'
            actions << 'Some extracted text spans have no rendered glyph ink at their declared position — see extra.glyph_source (possible dropped runs: unresolved fonts or missing CID language packs).'
          end
          unless Array(glyph_source[:missing_language_packs]).empty?
            signals << 'glyph_missing_language_packs'
            actions << "Poppler reported missing CID language pack(s) #{Array(glyph_source[:missing_language_packs]).join(', ')} — affected text runs were dropped by the renderer; verify the page visually."
          end
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
