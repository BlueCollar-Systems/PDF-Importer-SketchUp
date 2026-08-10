# bc_pdf_vector_importer/qa_report.rb
# Shared import_report.json builder (bcs.import_report/1.1)
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'json'
require 'digest'
require 'fileutils'
require 'time'
require File.join(File.dirname(__FILE__), 'safe_temp')
require File.join(File.dirname(__FILE__), 'metadata')
require File.join(File.dirname(__FILE__), 'model_3d_extruder')
require File.join(File.dirname(__FILE__), 'model_3d_intent')
require File.join(File.dirname(__FILE__), 'parts_bootstrap')
require File.join(File.dirname(__FILE__), 'representation_fidelity')

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

      # Split the pipeline's accumulated measurements into durations and everything else.
      #
      # stats[:pipeline_performance] is a single flat bag holding both timings
      # (commit_ms, item_delivery_ms, text3d_render_ms, the raster_*_ms family, ...) and
      # non-durations (glyph_component_definition_count, raster_png_temp_bytes,
      # commit_includes_source_binding_verification). Reporting a byte count as a phase
      # would silently corrupt every later optimisation decision, so membership is decided
      # by the `_ms` suffix rather than by a hand-maintained allow-list that would drift as
      # new stages are instrumented.
      #
      # Keys are sorted so the same input yields the same key order on every run
      # (determinism), and non-numeric timing values are dropped rather than coerced.
      def split_pipeline_performance(stats)
        collected = stats[:pipeline_performance]
        return [{}, {}, []] unless collected.is_a?(Hash)

        phases = {}
        counters = {}
        aggregates = []
        collected.keys.sort_by(&:to_s).each do |key|
          value = collected[key]
          name = key.to_s
          if name.end_with?('_ms')
            next unless value.is_a?(Numeric)
            phases[key] = value.to_f.round(3)
            # `*_total_ms` keys (page_total_ms, raster_total_ms) are PARENTS that enclose
            # the stages beside them. They are reported, but must not be summed as leaves:
            # the first real canary summed page_total_ms with its own children, overshot
            # total_ms, and the clamp reported unaccounted_ms as 0.0 -- claiming the
            # breakdown explained 100% of a run where ~32% was unexplained. A suffix rule
            # is used rather than a hand-listed set for the same reason `_ms` is: a list
            # drifts as stages are added, a naming convention does not.
            aggregates << key if name.end_with?('_total_ms')
          else
            counters[key] = value
          end
        end
        [phases, counters, aggregates]
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
            phases, counters, aggregates = split_pipeline_performance(stats)
            if elapsed_ms > 0 || !phases.empty?
              measured = phases.reject { |key, _| aggregates.include?(key) }
                               .values.inject(0.0) { |sum, ms| sum + ms }
              perf[:phases] = phases.merge(
                total_ms: elapsed_ms,
                # How much of the elapsed time the breakdown does NOT explain. Without
                # this a partial breakdown reads exactly like a complete one, which is
                # the same false-completeness trap as a returncode-only PASS. Clamped at
                # zero because stages can nest (a parent encloses a child), so the sum
                # can legitimately exceed the wall clock.
                unaccounted_ms: [(elapsed_ms - measured).round(3), 0.0].max
              )
            end
            perf[:counters] = counters unless counters.empty?
            # Declare which keys were treated as parents. Reinterpreting a key's meaning
            # must be auditable rather than silent magic.
            perf[:phase_aggregates] = aggregates unless aggregates.empty?
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
        report[:extra][:representation_fidelity] =
          validate_representation_fidelity(stats, opts)
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
        SafeTemp.join("#{base}_import_report.json")
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
        geometry_staging = Array(
          stats[:geometry_staging] || stats['geometry_staging']
        ).map do |entry|
          normalize_json(entry)
        end
        {
          text_renderers: renderers,
          geometry_staging: geometry_staging,
          pipeline_performance: normalize_json(
            stats[:pipeline_performance] || stats['pipeline_performance'] || {}
          ),
          delivered_text_entity_counts: delivered_text_entity_counts(stats),
          text_delivery_accounting: text_delivery_accounting(stats),
          execution_scope: (stats[:execution_scope] ||
                            stats['execution_scope'] || :host_import).to_s,
          extracted_text_items: (stats[:extracted_text_items] ||
                                 stats['extracted_text_items']).to_i,
          edges: stats[:edges].to_i,
          arcs: stats[:arcs].to_i,
          text_mode: stats[:text_mode].to_s,
          requested_text_mode: (stats[:requested_text_mode] ||
                                stats['requested_text_mode']).to_s,
          selected_pages: Array(
            stats[:selected_pages] || stats['selected_pages']
          ).map { |value| value.to_i },
          import_session_id: (stats[:import_session_id] ||
                              stats['import_session_id']).to_s,
          source_tree_sha256_before_load:
            (stats[:source_tree_sha256_before_load] ||
             stats['source_tree_sha256_before_load']),
          source_tree_sha256_after_import:
            (stats[:source_tree_sha256_after_import] ||
             stats['source_tree_sha256_after_import']),
          source_lineage: begin
            lineage = stats[:source_lineage] || stats['source_lineage']
            lineage.is_a?(Hash) ? normalize_json(lineage) : nil
          end,
          svg_renderer_missing: !!stats[:svg_renderer_missing],
          font_substitution_note: stats[:font_substitution_note],
          resolved_scale: stats[:resolved_scale] ? normalize_json(stats[:resolved_scale]) : nil,
          recognition_skipped_pages: Array(stats[:recognition_skipped_pages]).map { |entry| normalize_json(entry) },
          embedded_images: stats[:embedded_images].to_i,
          embedded_images_placed: stats[:embedded_images_placed].to_i,
          embedded_image_dir: stats[:embedded_image_dir],
          embedded_image_paths: Array(stats[:embedded_image_paths] || stats[:embedded_image_files]).map(&:to_s),
          fallback_transitions: Array(stats[:fallback_transitions]).map { |entry| normalize_json(entry) },
          terminal_text_delivery_records: Array(stats[:terminal_text_delivery_records]).map { |entry| normalize_json(entry) },
          raster_delivery_records: Array(stats[:raster_delivery_records]).map { |entry| normalize_json(entry) },
          inline_image_page_raster_fallbacks:
            Array(stats[:inline_image_page_raster_fallbacks]).map do |entry|
              normalize_json(entry)
            end,
          terminal_cleanup_events: Array(stats[:terminal_cleanup_events]).map { |entry| normalize_json(entry) },
          page_representation_fallbacks: Array(stats[:page_representation_fallbacks]).map { |entry| normalize_json(entry) },
          empty_page_source_inspections: Array(stats[:empty_page_source_inspections]).map { |entry| normalize_json(entry) },
          representation_ownership_group_forced_pages: Array(stats[:representation_ownership_group_forced_pages]).map { |entry| normalize_json(entry) },
          source_glyph_physical_deliveries: Array(stats[:source_glyph_physical_deliveries]).map { |entry| normalize_json(entry) },
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

      def text_delivery_accounting(stats)
        source_ids = Array(
          stats[:text_source_span_ids] || stats['text_source_span_ids']
        ).map { |value| value.to_s.strip }.reject(&:empty?).uniq
        delivered_ids = []
        failed_ids = []
        Array(stats[:text_attempts] || stats['text_attempts']).each do |entry|
          next unless entry.is_a?(Hash)
          source_id = (entry[:source_span_id] ||
                       entry['source_span_id']).to_s.strip
          next if source_id.empty?
          delivered_mode = entry[:delivered_mode] || entry['delivered_mode']
          if normalize_report_text_mode(delivered_mode)
            delivered_ids << source_id
          else
            failed_ids << source_id
          end
        end
        Array(
          stats[:text_delivery_failures] || stats['text_delivery_failures']
        ).each do |entry|
          next unless entry.is_a?(Hash)
          source_id = (entry[:source_span_id] ||
                       entry['source_span_id']).to_s.strip
          failed_ids << source_id unless source_id.empty?
        end
        delivered_ids = delivered_ids.uniq & source_ids
        failed_ids = (failed_ids.uniq & source_ids) - delivered_ids
        unaccounted_ids = source_ids - delivered_ids - failed_ids
        requested = stats[:requested_text_mode] ||
                    stats['requested_text_mode'] || stats[:text_mode] ||
                    stats['text_mode']
        effective = stats[:text_mode] || stats['text_mode'] || requested
        source_count = source_ids.length
        delivered_count = delivered_ids.length
        failed_count = failed_ids.length
        unaccounted_count = unaccounted_ids.length
        {
          requested_mode: normalize_report_text_mode(requested) ||
                          requested.to_s,
          effective_mode: normalize_report_text_mode(effective) ||
                          effective.to_s,
          source_count: source_count,
          delivered_count: delivered_count,
          failed_count: failed_count,
          unaccounted_count: unaccounted_count,
          counts_reconciled: source_count ==
            delivered_count + failed_count + unaccounted_count
        }
      rescue StandardError
        {
          requested_mode: '', effective_mode: '', source_count: 0,
          delivered_count: 0, failed_count: 0, unaccounted_count: 0,
          counts_reconciled: false
        }
      end

      # Round 23 (F-1): which glyph SOURCE produced the Glyphs-mode outlines
      # (TEXTMODE-1: the delivered mode stays Glyphs; the source is reported,
      # never silently swapped). Present only when a Glyphs-mode import ran.
      #   source                 cairo_svg (bundled pdftocairo), mupdf_svg
      #                          (installed mutool), or unavailable (requested
      #                          glyph delivery stopped without substitution).
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
          attempted_source: (src[:attempted_source] ||
                             src['attempted_source']).to_s,
          fallback_reason: reason.nil? ? nil : reason.to_s,
          pages: (src[:pages] || src['pages']).to_i,
          runs_matched: (src[:runs_matched] || src['runs_matched']).to_i,
          runs_unmatched: (src[:runs_unmatched] || src['runs_unmatched']).to_i,
          placements_unmatched: (src[:placements_unmatched] ||
                                 src['placements_unmatched']).to_i,
          note: 'Glyphs-mode outline source (R23). cairo_svg/mupdf_svg stamp ' \
                'the PDF fonts\' own glyph outlines; unavailable means the ' \
                'requested delivery stopped without substitution. runs_* position-match ' \
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
        # Closed-shape page extrusion is an unrelated disabled feature. It must
        # never gate source-glyph 3D text or imply that text depth is disabled.
        normalize_json(
          enabled: false, supported: false, faces_extruded: 0,
          skipped_reason: 'closed_shape_extrusion_disabled'
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
        execution_scope = (extra[:execution_scope] ||
                           extra['execution_scope']).to_s
        host_delivery_ok = execution_scope != 'extraction_only'
        fidelity = extra[:representation_fidelity] ||
                   extra['representation_fidelity'] || {}
        # Requested-representation fidelity is an independent contract. An
        # empty host text count can mean "no source text", but it can also mean
        # every requested item was dropped; it must never bypass the ledger.
        fidelity_ok = fidelity[:ready] == true || fidelity['ready'] == true
        ready = has_stamp && has_crosscheck && text_ok && fidelity_ok &&
                host_delivery_ok &&
                open_failure.nil?
        {
          ready: ready,
          checks: {
            build_stamp: has_stamp,
            scale_crosscheck: has_crosscheck,
            actual_text_entity_types: text_ok,
            host_entity_delivery: host_delivery_ok,
            requested_representation_fidelity: fidelity_ok,
            no_open_failure: open_failure.nil?
          },
          note: 'diagnostics stub — Report Doctor may recompute client-side'
        }
      end

      def telemetry_value(hash, key)
        return nil unless hash.respond_to?(:[])
        if hash.respond_to?(:key?)
          return hash[key] if hash.key?(key)
          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)
          return nil
        end
        value = hash[key]
        value.nil? ? hash[key.to_s] : value
      end

      def telemetry_key?(hash, key)
        hash.respond_to?(:key?) &&
          (hash.key?(key) || hash.key?(key.to_s))
      end

      def symbolized_transition_proof(entry)
        return nil unless entry.is_a?(Hash)
        proof = {}
        [
          :source_span_id, :importer_id, :page_number,
          :requested_mode,
          :affirmative_impossibility, :generic_failure,
          :attempted_renderer, :created_entity_ids, :cleaned_entity_ids,
          :evidence
        ].each { |key| proof[key] = telemetry_value(entry, key) }
        proof[:scope] = telemetry_value(entry, :scope).to_s.to_sym
        proof[:category] = telemetry_value(entry, :category).to_s.to_sym
        proof[:from_mode] = telemetry_value(entry, :from_mode)
        proof[:to_mode] = telemetry_value(entry, :to_mode)
        proof[:reason_code] = telemetry_value(entry, :reason_code).to_s.to_sym
        proof[:cleanup_outcome] =
          telemetry_value(entry, :cleanup_outcome).to_s.to_sym
        proof
      rescue StandardError
        nil
      end

      def transition_signature(entry)
        proof = symbolized_transition_proof(entry)
        return nil unless proof
        evidence_digest = nil
        if RepresentationFidelity.normalize_mode(proof[:from_mode]) == :text
          evidence = proof[:evidence]
          evidence_digest = telemetry_value(
            evidence, :evidence_sha256
          ).to_s.downcase
        end
        [
          proof[:source_span_id].to_s,
          RepresentationFidelity.normalize_mode(proof[:from_mode]),
          RepresentationFidelity.normalize_mode(proof[:to_mode]),
          proof[:reason_code], proof[:importer_id].to_s,
          proof[:page_number].to_i,
          Array(proof[:created_entity_ids]).map { |value| value.to_s }.sort,
          Array(proof[:cleaned_entity_ids]).map { |value| value.to_s }.sort,
          proof[:cleanup_outcome], evidence_digest
        ]
      end

      def text_mode_delivery_evidence_complete?(entry, mode)
        return false unless entry.is_a?(Hash)

        common = telemetry_value(entry, :placement_verified) == true &&
                 telemetry_value(entry, :rotation_verified) == true &&
                 telemetry_value(entry, :entity_type_verified) == true
        return false unless common

        case RepresentationFidelity.normalize_mode(mode)
        when :text3d
          telemetry_value(entry, :width_verified) == true &&
            telemetry_value(entry, :height_verified) == true
        when :labels
          leader_vector = telemetry_value(entry, :leader_vector)
          telemetry_value(entry, :content_verified) == true &&
            telemetry_value(entry, :leader_verified) == true &&
            telemetry_value(entry, :leader_vector_verified) == true &&
            leader_vector.is_a?(Array) && leader_vector.length == 3 &&
            leader_vector.all? do |value|
              value.is_a?(Numeric) && value.to_f.finite?
            end
        else
          false
        end
      end

      def fidelity_requested_mode(stats, opts)
        raw = stats[:requested_text_mode] || stats['requested_text_mode'] ||
              stats[:text_mode] || stats['text_mode'] || opts[:text_mode] ||
              opts['text_mode']
        raw = :raster if opts[:force_raster] || opts['force_raster']
        RepresentationFidelity.normalize_mode(raw)
      end

      def fidelity_expected_mode(opts)
        return :raster if opts[:force_raster] || opts['force_raster']
        RepresentationFidelity.normalize_mode(opts[:text_mode] || opts['text_mode'])
      end

      def fidelity_page_list(raw, page_count)
        if raw == :all || raw.to_s.strip.downcase == 'all'
          count = page_count.to_i
          return count > 0 ? (1..count).to_a : []
        end
        Array(raw).map { |value| value.to_i }.select do |value|
          value > 0
        end.uniq.sort
      end

      def fidelity_selected_pages(stats, opts, errors)
        stats_has_pages = stats.key?(:selected_pages) ||
                          stats.key?('selected_pages')
        stats_pages = fidelity_page_list(
          stats[:selected_pages] || stats['selected_pages'], stats[:pages]
        )
        opts_has_pages = opts.key?(:pages) || opts.key?('pages')
        opts_pages = fidelity_page_list(
          opts[:pages] || opts['pages'], stats[:pages]
        )
        if stats_has_pages && opts_has_pages && stats_pages != opts_pages
          errors << 'selected_pages_do_not_match_import_request'
        end
        stats_has_pages ? stats_pages : opts_pages
      end

      def fidelity_source_page(source_id)
        match = RepresentationFidelity::SOURCE_ID.match(source_id.to_s.strip)
        match ? match[1].to_i : nil
      end

      def fidelity_record_mode_binding!(errors, collection_name, records,
                                        requested_mode, field, required)
        Array(records).each_with_index do |entry, index|
          next unless entry.is_a?(Hash)
          has_field = entry.key?(field) || entry.key?(field.to_s)
          next unless required || has_field
          actual = RepresentationFidelity.normalize_mode(
            telemetry_value(entry, field)
          )
          unless requested_mode && actual == requested_mode
            errors << "#{collection_name}_requested_mode_mismatch:#{index}"
          end
        end
      end

      def fidelity_span_pages_valid?(entry, span_ids, selected_pages)
        pages = Array(span_ids).map do |source_id|
          fidelity_source_page(source_id)
        end
        return false if pages.empty? || pages.any? { |page| page.nil? }
        return false unless selected_pages.empty? ||
                            pages.all? { |page| selected_pages.include?(page) }
        return false unless pages.uniq.length == 1
        raw_page = telemetry_value(entry, :page)
        return true if raw_page.nil? || raw_page.to_s.strip.empty?
        raw_page.to_i == pages[0]
      end

      def fidelity_raster_artifact_valid?(artifact, page_number)
        return false unless artifact.is_a?(Hash)
        sha256 = telemetry_value(artifact, :content_sha256).to_s.downcase
        telemetry_value(artifact, :page_number).to_i == page_number.to_i &&
          telemetry_value(artifact, :pixel_width).to_i > 0 &&
          telemetry_value(artifact, :pixel_height).to_i > 0 &&
          telemetry_value(artifact, :png_signature_verified) == true &&
          telemetry_value(artifact, :page_binding_verified) == true &&
          telemetry_value(artifact, :box_binding_verified) == true &&
          sha256 =~ /\A[0-9a-f]{64}\z/ &&
          telemetry_value(artifact, :content_byte_size).to_i > 0
      end

      def fidelity_source_pdf_sha256(stats)
        value = telemetry_value(stats, :normalized_input_sha256)
        value = telemetry_value(stats, :normalized_pdf_sha256) if
          value.to_s.strip.empty?
        value.to_s.downcase
      end

      def fidelity_explicit_page_raster_artifact_valid?(artifact, page_number,
                                                         source_pdf_sha256)
        fidelity_raster_artifact_valid?(artifact, page_number) &&
          source_pdf_sha256 =~ /\A[0-9a-f]{64}\z/ &&
          telemetry_value(artifact, :source_pdf_sha256).to_s.downcase ==
            source_pdf_sha256 &&
          telemetry_value(artifact, :source_pdf_binding_verified) == true
      end

      def fidelity_item_raster_artifact_valid?(artifact, source_id,
                                                page_number,
                                                source_pdf_sha256)
        return false unless artifact.is_a?(Hash)
        source_box = telemetry_value(artifact, :source_box)
        pixel_crop = telemetry_value(artifact, :pixel_crop)
        content_sha = telemetry_value(artifact, :content_sha256).to_s.downcase
        valid_box = source_box.is_a?(Array) && source_box.length == 4 &&
          source_box.all? { |value| value.is_a?(Numeric) && value.to_f.finite? } &&
          source_box[2].to_f > source_box[0].to_f &&
          source_box[3].to_f > source_box[1].to_f
        valid_crop = pixel_crop.is_a?(Array) && pixel_crop.length == 4 &&
          pixel_crop.all? { |value| value.is_a?(Integer) } &&
          pixel_crop[2].to_i > 0 && pixel_crop[3].to_i > 0
        telemetry_value(artifact, :source_span_id).to_s == source_id.to_s &&
          telemetry_value(artifact, :page_number).to_i == page_number.to_i &&
          valid_box && valid_crop &&
          telemetry_value(artifact, :pixel_width).to_i == pixel_crop[2].to_i &&
          telemetry_value(artifact, :pixel_height).to_i == pixel_crop[3].to_i &&
          telemetry_value(artifact, :png_signature_verified) == true &&
          telemetry_value(artifact, :page_binding_verified) == true &&
           telemetry_value(artifact, :source_crop_binding_verified) == true &&
           telemetry_value(artifact, :aspect_verified) == true &&
           telemetry_value(artifact, :alpha_channel_verified) == true &&
           telemetry_value(
             artifact, :transparent_background_verified
           ) == true &&
           telemetry_value(artifact, :visible_pixel_verified) == true &&
           telemetry_value(
             artifact, :page_render_once_verified
           ) == true &&
           telemetry_value(
             artifact, :page_render_content_sha256
           ).to_s.downcase =~ /\A[0-9a-f]{64}\z/ &&
           content_sha =~ /\A[0-9a-f]{64}\z/ &&
          telemetry_value(artifact, :content_byte_size).to_i > 0 &&
          source_pdf_sha256 =~ /\A[0-9a-f]{64}\z/ &&
          telemetry_value(artifact, :source_pdf_sha256).to_s.downcase ==
            source_pdf_sha256 &&
           telemetry_value(artifact, :source_pdf_binding_verified) == true
      end

      def fidelity_zero_canonical_inspection_valid?(stats, page_number)
        immutable_sha = telemetry_value(stats, :source_input_sha256)
        immutable_sha = telemetry_value(stats, :immutable_pdf_sha256) if
          immutable_sha.to_s.strip.empty?
        rendered_sha = telemetry_value(stats, :normalized_input_sha256)
        rendered_sha = telemetry_value(stats, :normalized_pdf_sha256) if
          rendered_sha.to_s.strip.empty?
        immutable_sha = immutable_sha.to_s.downcase
        rendered_sha = rendered_sha.to_s.downcase
        return false unless immutable_sha =~ /\A[0-9a-f]{64}\z/ &&
                            rendered_sha =~ /\A[0-9a-f]{64}\z/

        inspections = Array(
          telemetry_value(stats, :empty_page_source_inspections)
        ).select do |entry|
          entry.is_a?(Hash) && telemetry_value(entry, :page).is_a?(Integer) &&
            telemetry_value(entry, :page) == page_number
        end
        return false unless inspections.length == 1

        inspection = inspections[0]
        source_page = telemetry_value(inspection, :source_page_number)
        canonical_count = telemetry_value(
          inspection, :canonical_text_item_count
        )
        source_page.is_a?(Integer) && source_page == page_number &&
          canonical_count.is_a?(Integer) && canonical_count == 0 &&
          telemetry_value(
            inspection, :immutable_pdf_sha256
          ).to_s.downcase == immutable_sha &&
          telemetry_value(
            inspection, :rendered_pdf_sha256
          ).to_s.downcase == rendered_sha &&
          telemetry_value(
            inspection, :semantic_text_extraction_complete
          ) == true &&
          telemetry_value(
            inspection, :decoded_stream_text_operators
          ) == false &&
          telemetry_value(
            inspection, :decoded_form_stream_text_operators
          ) == false
      end

      def fidelity_page_raster_delivery_basis_valid?(stats, entry,
                                                      requested_mode,
                                                      page_number)
        case telemetry_value(entry, :delivery_basis).to_s
        when 'explicit_full_page_raster'
          requested_mode == :raster &&
            RepresentationFidelity.normalize_mode(
              telemetry_value(entry, :requested_mode)
            ) == :raster &&
            telemetry_value(entry, :full_page_raster_request) == true &&
            telemetry_value(entry, :semantic_text_evaluated) == false &&
            telemetry_value(entry, :no_semantic_text) != true &&
            !telemetry_key?(entry, :canonical_text_item_count)
        when 'verified_zero_canonical_text'
          canonical_count = telemetry_value(
            entry, :canonical_text_item_count
          )
          telemetry_value(entry, :full_page_raster_request) != true &&
            telemetry_value(entry, :semantic_text_evaluated) == true &&
            telemetry_value(entry, :no_semantic_text) == true &&
            canonical_count.is_a?(Integer) && canonical_count == 0 &&
            fidelity_zero_canonical_inspection_valid?(stats, page_number)
        when 'inline_image_paint_order_requires_terminal_page_raster'
          fidelity_inline_page_raster_valid?(
            stats, entry, requested_mode, page_number
          )
        else
          false
        end
      end

      def fidelity_inline_page_raster_valid?(stats, entry, requested_mode,
                                              page_number)
        return false if requested_mode == :raster
        requested_strategy = telemetry_value(entry, :requested_strategy).
          to_s.downcase
        inline_count = telemetry_value(entry, :inline_image_instance_count)
        ids = RepresentationFidelity.positive_entity_ids(
          telemetry_value(entry, :resulting_entity_ids)
        )
        artifact_path = telemetry_value(entry, :artifact_path).to_s
        artifact_sha = telemetry_value(entry, :artifact_sha256).to_s.downcase
        artifact = telemetry_value(entry, :artifact_evidence)
        valid = ['auto', 'hybrid'].include?(requested_strategy) &&
          telemetry_value(entry, :effective_strategy).to_s == 'raster' &&
          telemetry_value(entry, :semantic_text_evaluated) == false &&
          inline_count.is_a?(Integer) && inline_count > 0 &&
          RepresentationFidelity.normalize_mode(
            telemetry_value(entry, :requested_mode)
          ) == requested_mode &&
          RepresentationFidelity.normalize_mode(
            telemetry_value(entry, :delivered_mode)
          ) == :raster &&
          telemetry_value(entry, :source_page_number).to_i == page_number &&
          telemetry_value(entry, :source_span_ids) == [] &&
          telemetry_value(entry, :created_entity_type).to_s == 'raster_image' &&
          telemetry_value(entry, :delivery_scope).to_s == 'page_raster' &&
          telemetry_value(entry, :cleanup_outcome).to_s == 'not_required' &&
          telemetry_value(entry, :explicit_request) == false &&
          telemetry_value(entry, :degraded) == true &&
          ids && ids.length == 1 &&
          artifact_path.length > 0 && artifact_sha =~ /\A[0-9a-f]{64}\z/ &&
          artifact.is_a?(Hash) &&
          telemetry_value(artifact, :png_path).to_s == artifact_path &&
          telemetry_value(artifact, :content_sha256).to_s.downcase == artifact_sha
        return false unless valid

        matches = Array(
          telemetry_value(stats, :inline_image_page_raster_fallbacks)
        ).select do |record|
          record.is_a?(Hash) &&
            telemetry_value(record, :page).to_i == page_number &&
            RepresentationFidelity.positive_entity_ids(
              telemetry_value(record, :resulting_entity_ids)
            ) == ids &&
            telemetry_value(record, :artifact_path).to_s == artifact_path &&
            telemetry_value(record, :artifact_sha256).to_s.downcase == artifact_sha &&
            telemetry_value(record, :inline_image_instance_count) ==
              inline_count &&
            telemetry_value(record, :semantic_text_evaluated) == false &&
            telemetry_value(record, :requested_strategy).to_s.downcase ==
              requested_strategy &&
            telemetry_value(record, :delivery_basis).to_s ==
              'inline_image_paint_order_requires_terminal_page_raster' &&
            telemetry_value(record, :source_lineage) ==
              telemetry_value(entry, :source_lineage)
        end
        matches.length == 1 &&
          telemetry_value(entry, :source_lineage) ==
            telemetry_value(stats, :source_lineage)
      end

      def fidelity_inline_image_ledger_valid?(stats)
        records = Array(
          telemetry_value(stats, :inline_image_page_raster_fallbacks)
        )
        return true unless telemetry_key?(stats, :inline_images_detected) ||
                           !records.empty?
        detected = telemetry_value(stats, :inline_images_detected)
        return false unless detected.is_a?(Integer) && detected >= 0
        counts = records.map do |record|
          return false unless record.is_a?(Hash)
          count = telemetry_value(record, :inline_image_instance_count)
          return false unless count.is_a?(Integer) && count > 0
          count
        end
        pages = records.map { |record| telemetry_value(record, :page).to_i }
        pages.all? { |page| page > 0 } && pages.uniq.length == pages.length &&
          counts.inject(0) { |sum, count| sum + count } == detected
      end

      def validate_representation_fidelity(stats, opts = {})
        execution_scope = (stats[:execution_scope] ||
                           stats['execution_scope']).to_s
        if execution_scope == 'extraction_only'
          return {
            ready: false,
            not_applicable: true,
            checks: { host_entity_delivery: false },
            errors: ['host_representation_delivery_not_performed']
          }
        end
        source_ids = Array(
          stats[:text_source_span_ids] || stats['text_source_span_ids']
        ).map { |value| value.to_s.strip }
        attempts = Array(stats[:text_attempts] || stats['text_attempts'])
        provenance = Array(
          stats[:source_provenance_objects] || stats['source_provenance_objects']
        )
        terminal = Array(
          stats[:terminal_text_delivery_records] ||
          stats['terminal_text_delivery_records']
        )
        page_deliveries = Array(
          stats[:page_text_delivery_records] ||
          stats['page_text_delivery_records']
        )
        fallback_transitions = Array(
          stats[:fallback_transitions] || stats['fallback_transitions']
        )
        physical_deliveries = Array(
          stats[:source_glyph_physical_deliveries] ||
          stats['source_glyph_physical_deliveries']
        )
        errors = []
        errors << 'inline_image_page_raster_ledger_invalid' unless
          fidelity_inline_image_ledger_valid?(stats)
        requested_mode = fidelity_requested_mode(stats, opts)
        expected_mode = fidelity_expected_mode(opts)
        selected_pages = fidelity_selected_pages(stats, opts, errors)
        errors << 'requested_text_mode_invalid' unless requested_mode
        if expected_mode && requested_mode != expected_mode
          errors << 'requested_text_mode_does_not_match_import_request'
        end

        fidelity_record_mode_binding!(
          errors, 'text_attempt', attempts, requested_mode,
          :requested_mode, true
        )
        fidelity_record_mode_binding!(
          errors, 'page_delivery', page_deliveries, requested_mode,
          :requested_mode, true
        )
        fidelity_record_mode_binding!(
          errors, 'terminal_delivery', terminal, requested_mode,
          :requested_mode, true
        )
        raster_deliveries = Array(
          stats[:raster_delivery_records] || stats['raster_delivery_records']
        )
        fidelity_record_mode_binding!(
          errors, 'raster_delivery', raster_deliveries, requested_mode,
          :requested_mode, true
        )
        fidelity_record_mode_binding!(
          errors, 'text_renderer',
          stats[:text_renderers] || stats['text_renderers'], requested_mode,
          :requested_mode, false
        )
        fidelity_record_mode_binding!(
          errors, 'page_fallback',
          stats[:page_representation_fallbacks] ||
            stats['page_representation_fallbacks'], requested_mode,
          :requested_text_mode, false
        )

        if source_ids.uniq.length != source_ids.length ||
           !source_ids.all? { |identity| identity =~ RepresentationFidelity::SOURCE_ID }
          errors << 'source_span_ledger_invalid'
        end
        unless selected_pages.empty?
          source_ids.each do |source_id|
            page = fidelity_source_page(source_id)
            unless page && selected_pages.include?(page)
              errors << "source_span_outside_selected_pages:#{source_id}"
            end
          end
        end

        provenance_by_span = {}
        provenance_types_by_span = {}
        physical_provenance = {}
        live_id_owner = {}
        provenance.each do |entry|
          next unless entry.is_a?(Hash)
          source_kind = telemetry_value(entry, :source_kind).to_s
          entity_type = telemetry_value(entry, :created_entity_type).to_s
          if source_kind == 'svg_glyph_placement'
            unit_id = telemetry_value(entry, :object_id).to_s.strip
            page = telemetry_value(entry, :page).to_i
            ids = RepresentationFidelity.positive_entity_ids(
              telemetry_value(entry, :resulting_entity_ids)
            )
            placements = telemetry_value(entry, :source_placement_indices)
            placements = placements.is_a?(Array) ?
              placements.map { |value| value.to_i } : []
            valid_physical = !unit_id.empty? && page > 0 && ids &&
              entity_type == 'source_glyph_3d_text' &&
              telemetry_value(entry, :span_id).to_s.strip.empty? &&
              telemetry_value(entry, :semantic_identity_available) == false &&
              telemetry_value(entry, :source_glyph_identity_verified) == true &&
              telemetry_value(entry, :positive_z_depth_verified) == true &&
              !placements.empty? && placements.uniq.length == placements.length &&
              !physical_provenance.key?(unit_id)
            unless valid_physical
              errors << 'physical_glyph_provenance_invalid'
              next
            end
            ids.each do |identity|
              if live_id_owner.key?(identity)
                errors << "duplicate_live_entity_id:#{identity}"
              else
                live_id_owner[identity] = unit_id
              end
            end
            physical_provenance[unit_id] = {
              :page => page, :ids => ids.sort,
              :placements => placements.sort
            }
            next
          end
          next unless source_kind == 'text_span' ||
                      %w[native_label native_3d_text source_glyph_3d_text glyph_outline page_path_geometry raster_image].include?(entity_type)
          span_id = telemetry_value(entry, :span_id).to_s.strip
          ids = RepresentationFidelity.positive_entity_ids(
            telemetry_value(entry, :resulting_entity_ids)
          )
          page_valid = requested_mode == :raster || selected_pages.empty? ||
            fidelity_span_pages_valid?(entry, [span_id], selected_pages)
          unless source_ids.include?(span_id) && ids && page_valid
            errors << "provenance_invalid:#{span_id}"
            next
          end
          ids.each do |identity|
            if live_id_owner.key?(identity)
              errors << "duplicate_live_entity_id:#{identity}"
            else
              live_id_owner[identity] = span_id
            end
          end
          provenance_by_span[span_id] ||= []
          provenance_by_span[span_id].concat(ids)
          provenance_types_by_span[span_id] ||= []
          provenance_types_by_span[span_id] << entity_type
        end

        seen_physical_units = {}
        physical_deliveries.each do |entry|
          unless entry.is_a?(Hash)
            errors << 'physical_glyph_delivery_invalid'
            next
          end
          unit_id = telemetry_value(entry, :source_unit_id).to_s.strip
          ids = RepresentationFidelity.positive_entity_ids(
            telemetry_value(entry, :resulting_entity_ids)
          )
          placements = telemetry_value(entry, :placement_indices)
          placements = placements.is_a?(Array) ?
            placements.map { |value| value.to_i }.sort : []
          expected = physical_provenance[unit_id]
          valid = expected && !seen_physical_units.key?(unit_id) && ids &&
            expected[:page] == telemetry_value(entry, :page).to_i &&
            expected[:ids] == ids.sort && expected[:placements] == placements &&
            RepresentationFidelity.normalize_mode(
              telemetry_value(entry, :delivered_mode)
            ) == :text3d &&
            telemetry_value(entry, :visual_fidelity_verified) == true &&
            telemetry_value(entry, :positive_z_depth_verified) == true &&
            telemetry_value(entry, :source_glyph_identity_verified) == true
          unless valid
            errors << 'physical_glyph_delivery_crosslink_invalid'
            next
          end
          seen_physical_units[unit_id] = true
        end
        unless seen_physical_units.keys.sort == physical_provenance.keys.sort
          errors << 'physical_glyph_delivery_set_mismatch'
        end

        terminal_by_span = {}
        terminal_no_semantic_pages = {}
        source_pdf_sha256 = fidelity_source_pdf_sha256(stats)
        terminal.each do |entry|
          unless entry.is_a?(Hash)
            errors << 'terminal_record_not_hash'
            next
          end
          span_ids = telemetry_value(entry, :source_span_ids)
          span_ids = span_ids.is_a?(Array) ?
            span_ids.map { |value| value.to_s.strip } : []
          ids = RepresentationFidelity.positive_entity_ids(
            telemetry_value(entry, :resulting_entity_ids)
          )
          cleanup = telemetry_value(entry, :cleanup_outcome).to_s
          delivered = RepresentationFidelity.normalize_mode(
            telemetry_value(entry, :delivered_mode)
          )
          if span_ids.empty?
            page_number = telemetry_value(entry, :page).to_i
            valid_page_raster = page_number > 0 &&
              (selected_pages.empty? || selected_pages.include?(page_number)) &&
              !terminal_no_semantic_pages.key?(page_number) && ids &&
              cleanup == 'not_required' && delivered == :raster &&
               telemetry_value(entry, :delivery_scope).to_s == 'page_raster' &&
               telemetry_value(entry, :real_raster_verified) == true &&
               telemetry_value(entry, :visual_fidelity_verified) == true &&
               fidelity_page_raster_delivery_basis_valid?(
                 stats, entry, requested_mode, page_number
               )
            unless valid_page_raster
              errors << 'terminal_no_semantic_page_record_invalid'
              next
            end
            ids.each do |identity|
              if live_id_owner.key?(identity)
                errors << "duplicate_live_entity_id:#{identity}"
              else
                live_id_owner[identity] = "no_semantic_page_raster:#{page_number}"
              end
            end
            terminal_no_semantic_pages[page_number] = ids
            next
          end
          scope = telemetry_value(entry, :delivery_scope).to_s
          artifact = telemetry_value(entry, :artifact_evidence)
          page_number = telemetry_value(entry, :page).to_i
          page_raster_valid = scope == 'page_raster' && cleanup == 'verified'
          item_raster_valid = scope == 'item_raster' &&
            cleanup == 'not_required' && span_ids.length == 1 &&
            telemetry_value(entry, :source_crop_binding_verified) == true &&
            fidelity_item_raster_artifact_valid?(
              artifact, span_ids[0], page_number, source_pdf_sha256
            )
          valid = !span_ids.empty? && span_ids.uniq.length == span_ids.length &&
                  span_ids.all? { |span_id| source_ids.include?(span_id) } &&
                  fidelity_span_pages_valid?(entry, span_ids, selected_pages) &&
                  span_ids.none? { |span_id| terminal_by_span.key?(span_id) } &&
                  ids && delivered == :raster && page_number > 0 &&
                  (page_raster_valid || item_raster_valid) &&
                  telemetry_value(entry, :real_raster_verified) == true &&
                  telemetry_value(entry, :visual_fidelity_verified) == true
          unless valid
            errors << 'terminal_page_record_invalid'
            next
          end
          ids.each do |identity|
            if live_id_owner.key?(identity)
              errors << "duplicate_live_entity_id:#{identity}"
            else
              live_id_owner[identity] = span_ids.join(',')
            end
          end
          span_ids.each { |span_id| terminal_by_span[span_id] = ids }
        end

        raster_delivery_signatures = raster_deliveries.each_with_index.map do |entry, index|
          unless entry.is_a?(Hash)
            errors << "raster_delivery_invalid:#{index}"
            next nil
          end
          page_number = telemetry_value(entry, :page).to_i
          ids = RepresentationFidelity.positive_entity_ids(
            telemetry_value(entry, :resulting_entity_ids)
          )
          artifact = telemetry_value(entry, :artifact_evidence)
          valid = RepresentationFidelity.normalize_mode(
            telemetry_value(entry, :requested_mode)
          ) == requested_mode &&
            RepresentationFidelity.normalize_mode(
              telemetry_value(entry, :delivered_mode)
            ) == :raster && ids && ids.length == 1 && page_number > 0 &&
            (selected_pages.empty? || selected_pages.include?(page_number)) &&
            telemetry_value(entry, :created_entity_type).to_s == 'raster_image' &&
            telemetry_value(entry, :real_raster_verified) == true &&
            telemetry_value(entry, :visual_fidelity_verified) == true &&
            artifact.is_a?(Hash) &&
            telemetry_value(artifact, :page_number).to_i == page_number
          unless valid
            errors << "raster_delivery_invalid:#{index}"
            next nil
          end
          [page_number, ids[0]]
        end
        terminal_raster_signatures = terminal.map do |entry|
          next nil unless entry.is_a?(Hash) &&
            RepresentationFidelity.normalize_mode(
              telemetry_value(entry, :delivered_mode)
            ) == :raster
          ids = RepresentationFidelity.positive_entity_ids(
            telemetry_value(entry, :resulting_entity_ids)
          )
          ids && ids.length == 1 ?
            [telemetry_value(entry, :page).to_i, ids[0]] : :invalid
        end.compact
        if raster_delivery_signatures.any? { |signature| signature.nil? } ||
           terminal_raster_signatures.include?(:invalid) ||
           raster_delivery_signatures.compact.sort !=
             terminal_raster_signatures.reject { |value| value == :invalid }.sort
          errors << 'raster_delivery_terminal_crosslink_invalid'
        end

        if requested_mode == :raster
          raster_signatures = []
          item_span_ids = []
          page_raster_pages = []
          raster_deliveries.each_with_index do |entry, index|
            unless entry.is_a?(Hash)
              errors << "raster_delivery_invalid:#{index}"
              next
            end
            page_number = telemetry_value(entry, :page).to_i
            ids = RepresentationFidelity.positive_entity_ids(
              telemetry_value(entry, :resulting_entity_ids)
            )
            spans = telemetry_value(entry, :source_span_ids)
            spans = spans.is_a?(Array) ? spans : nil
            requested = RepresentationFidelity.normalize_mode(
              telemetry_value(entry, :requested_mode)
            )
            delivered = RepresentationFidelity.normalize_mode(
              telemetry_value(entry, :delivered_mode)
            )
            scope = telemetry_value(entry, :delivery_scope).to_s
            artifact = telemetry_value(entry, :artifact_evidence)
            common_valid = requested == :raster && delivered == :raster &&
              ids && ids.length == 1 && page_number > 0 &&
              (selected_pages.empty? || selected_pages.include?(page_number)) &&
              telemetry_value(entry, :created_entity_type).to_s == 'raster_image' &&
              telemetry_value(entry, :real_raster_verified) == true &&
              telemetry_value(entry, :visual_fidelity_verified) == true &&
              telemetry_value(entry, :cleanup_outcome).to_s == 'not_required'
            valid = if scope == 'item_raster'
                      source_id = spans.is_a?(Array) && spans.length == 1 ?
                        spans[0].to_s : ''
                      item_valid = common_valid && source_ids.include?(source_id) &&
                        fidelity_source_page(source_id) == page_number &&
                        telemetry_value(entry, :source_crop_binding_verified) == true &&
                        telemetry_value(entry, :explicit_request) == true &&
                        fidelity_item_raster_artifact_valid?(
                          artifact, source_id, page_number, source_pdf_sha256
                        )
                      item_span_ids << source_id if item_valid
                      item_valid
                    elsif scope == 'page_raster'
                      page_valid = common_valid && spans == [] &&
                        fidelity_page_raster_delivery_basis_valid?(
                          stats, entry, requested_mode, page_number
                        ) &&
                        fidelity_explicit_page_raster_artifact_valid?(
                          artifact, page_number, source_pdf_sha256
                        )
                      page_raster_pages << page_number if page_valid
                      page_valid
                    else
                      false
                    end
            unless valid
              errors << "raster_delivery_invalid:#{index}"
              next
            end
            raster_signatures << [page_number, ids[0]]
          end
          source_pages = source_ids.map do |source_id|
            fidelity_source_page(source_id)
          end.compact.uniq.sort
          expected_page_rasters = selected_pages.empty? ? page_raster_pages.sort :
            (selected_pages - source_pages).sort
          unless item_span_ids.uniq.length == item_span_ids.length &&
                 item_span_ids.sort == source_ids.sort
            errors << 'raster_delivery_item_set_mismatch'
          end
          if page_raster_pages.uniq.length != page_raster_pages.length ||
             page_raster_pages.sort != expected_page_rasters
            errors << 'raster_delivery_page_set_mismatch'
          end
          if raster_signatures.empty?
            errors << 'raster_delivery_set_empty'
          end
          terminal_signatures = terminal.map do |entry|
            next nil unless entry.is_a?(Hash)
            ids = RepresentationFidelity.positive_entity_ids(
              telemetry_value(entry, :resulting_entity_ids)
            )
            ids && ids.length == 1 ?
              [telemetry_value(entry, :page).to_i, ids[0]] : nil
          end
          if terminal_signatures.any? { |signature| signature.nil? } ||
             terminal_signatures.sort != raster_signatures.sort
            errors << 'raster_delivery_terminal_crosslink_invalid'
          end
          unless page_deliveries.empty? && provenance.empty?
            errors << 'raster_delivery_contains_non_raster_delivery_evidence'
          end
          if telemetry_value(stats, :raster_fallback_used) == true ||
             !fallback_transitions.empty? ||
             !Array(
               telemetry_value(stats, :page_representation_fallbacks)
             ).empty?
            errors << 'requested_raster_mislabeled_as_fallback'
          end
          renderers = Array(telemetry_value(stats, :text_renderers))
          unless renderers.all? do |renderer|
                   RepresentationFidelity.normalize_mode(
                     telemetry_value(renderer, :requested_mode)
                   ) == :raster &&
                     RepresentationFidelity.normalize_mode(
                       telemetry_value(renderer, :delivered_mode)
                     ) == :raster &&
                     telemetry_value(renderer, :degraded) == false
                 end
            errors << 'requested_raster_renderer_degraded'
          end
        end

        page_delivery_by_span = {}
        page_deliveries.each do |entry|
          unless entry.is_a?(Hash)
            errors << 'page_delivery_not_hash'
            next
          end
          span_ids = telemetry_value(entry, :source_span_ids)
          span_ids = span_ids.is_a?(Array) ?
            span_ids.map { |value| value.to_s.strip } : []
          ids = RepresentationFidelity.positive_entity_ids(
            telemetry_value(entry, :resulting_entity_ids)
          )
          requested = RepresentationFidelity.normalize_mode(
            telemetry_value(entry, :requested_mode)
          )
          delivered = RepresentationFidelity.normalize_mode(
            telemetry_value(entry, :delivered_mode)
          )
          entity_type = telemetry_value(entry, :created_entity_type).to_s
          page_entity_types = {
            geometry: 'page_path_geometry',
            glyphs: 'glyph_outline'
          }
          valid = !span_ids.empty? && span_ids.uniq.length == span_ids.length &&
                  span_ids.all? { |span_id| source_ids.include?(span_id) } &&
                  fidelity_span_pages_valid?(entry, span_ids, selected_pages) &&
                  ids && requested == delivered &&
                  page_entity_types[delivered] == entity_type &&
                  telemetry_value(entry, :visual_fidelity_verified) == true
          unless valid
            errors << 'page_representation_delivery_invalid'
            next
          end
          ids.each do |identity|
            if live_id_owner.key?(identity)
              errors << "duplicate_live_entity_id:#{identity}"
            else
              live_id_owner[identity] = span_ids.join(',')
            end
          end
          span_ids.each { |span_id| page_delivery_by_span[span_id] = ids }
        end

        attempt_by_span = {}
        cleaned_ids = {}
        attempt_transition_signatures = []
        attempts.each do |attempt|
          unless attempt.is_a?(Hash)
            errors << 'attempt_not_hash'
            next
          end
          page_span_ids = telemetry_value(attempt, :source_span_ids)
          if page_span_ids.is_a?(Array)
            page_span_ids = page_span_ids.map { |value| value.to_s.strip }
            requested = RepresentationFidelity.normalize_mode(
              telemetry_value(attempt, :requested_mode)
            )
            delivered = RepresentationFidelity.normalize_mode(
              telemetry_value(attempt, :delivered_mode)
            )
            ids = RepresentationFidelity.positive_entity_ids(
              telemetry_value(attempt, :resulting_entity_ids)
            )
            history = telemetry_value(attempt, :attempt_history)
            terminal_rung = history.is_a?(Array) ? history.last : nil
            rung_ids = terminal_rung && RepresentationFidelity.positive_entity_ids(
              telemetry_value(terminal_rung, :resulting_entity_ids)
            )
            page_modes = [:geometry, :glyphs]
            valid_page_attempt = !page_span_ids.empty? &&
              page_span_ids.uniq.length == page_span_ids.length &&
              page_span_ids.all? { |identity| source_ids.include?(identity) } &&
              fidelity_span_pages_valid?(
                attempt, page_span_ids, selected_pages
              ) &&
              requested == delivered && page_modes.include?(delivered) && ids &&
              telemetry_value(attempt, :visual_fidelity_verified) == true &&
              history.is_a?(Array) && history.length == 1 &&
              terminal_rung.is_a?(Hash) &&
              RepresentationFidelity.normalize_mode(
                telemetry_value(terminal_rung, :mode)
              ) == delivered &&
              telemetry_value(terminal_rung, :outcome).to_s == 'complete' &&
              telemetry_value(
                terminal_rung, :visual_fidelity_verified
              ) == true &&
              telemetry_value(
                terminal_rung, :cleanup_outcome
              ).to_s == 'not_required' &&
              rung_ids && rung_ids.sort == ids.sort
            unless valid_page_attempt
              errors << 'page_representation_attempt_invalid'
              next
            end
            page_span_ids.each do |identity|
              attempt_by_span[identity] ||= []
              attempt_by_span[identity].concat(ids)
            end
            next
          end

          span_id = telemetry_value(attempt, :source_span_id).to_s.strip
          requested = RepresentationFidelity.normalize_mode(
            telemetry_value(attempt, :requested_mode)
          )
          delivered = RepresentationFidelity.normalize_mode(
            telemetry_value(attempt, :delivered_mode)
          )
          ids = RepresentationFidelity.positive_entity_ids(
            telemetry_value(attempt, :resulting_entity_ids)
          )
          history = telemetry_value(attempt, :attempt_history)
          scalar_modes = RepresentationFidelity::MODES
          unless source_ids.include?(span_id) && requested && delivered &&
                 fidelity_span_pages_valid?(
                   attempt, [span_id], selected_pages
                 ) &&
                 scalar_modes.include?(delivered) && ids &&
                 history.is_a?(Array) && !history.empty?
            errors << "attempt_fields_invalid:#{span_id}"
            next
          end
          ladder = RepresentationFidelity.ladder_for(requested)
          delivered_index = ladder.index(delivered)
          expected_history_modes = delivered_index ?
            ladder[0..delivered_index] : []
          if expected_history_modes.empty?
            errors << "attempt_delivery_outside_ladder:#{span_id}"
          end
          unless telemetry_value(attempt, :visual_fidelity_verified) == true
            errors << "visual_fidelity_unverified:#{span_id}"
          end
          if delivered == :raster &&
             (telemetry_value(attempt, :real_raster_verified) != true ||
              telemetry_value(attempt, :source_crop_binding_verified) != true)
            errors << "attempt_item_raster_evidence_invalid:#{span_id}"
          end
          if [:text3d, :labels].include?(delivered) &&
             !text_mode_delivery_evidence_complete?(attempt, delivered)
            errors << "attempt_mode_evidence_invalid:#{span_id}"
          end
          if delivered == :labels
            types = provenance_types_by_span[span_id]
            unless types && types.uniq == ['native_label']
              errors << "attempt_provenance_type_mismatch:#{span_id}"
            end
          elsif delivered == :text3d
            types = provenance_types_by_span[span_id]
            allowed = ['native_3d_text', 'source_glyph_3d_text']
            unless types && types.uniq.length == 1 &&
                   allowed.include?(types.uniq[0])
              errors << "attempt_provenance_type_mismatch:#{span_id}"
            end
          end
          seen_modes = {}
          completed = []
          observed_history_modes = []
          controller = RepresentationFidelity::FallbackController.new(
            requested, span_id
          )
          history.each_with_index do |rung, rung_index|
            unless rung.is_a?(Hash)
              errors << "rung_not_hash:#{span_id}"
              next
            end
            mode = RepresentationFidelity.normalize_mode(
              telemetry_value(rung, :mode)
            )
            outcome = telemetry_value(rung, :outcome).to_s
            rung_ids_raw = telemetry_value(rung, :resulting_entity_ids)
            rung_ids = rung_ids_raw.is_a?(Array) ?
              rung_ids_raw.map { |value| value.to_s.strip } : nil
            if mode.nil? || seen_modes.key?(mode)
              errors << "rung_mode_invalid_or_duplicate:#{span_id}"
            else
              seen_modes[mode] = true
              observed_history_modes << mode
            end
            if outcome == 'complete'
              valid_ids = RepresentationFidelity.positive_entity_ids(rung_ids_raw)
              if valid_ids
                completed << [mode, valid_ids]
              else
                errors << "completed_rung_ids_invalid:#{span_id}"
              end
              if [:text3d, :labels].include?(mode) &&
                 !text_mode_delivery_evidence_complete?(rung, mode)
                errors << "completed_rung_mode_evidence_invalid:#{span_id}"
              end
              if [:text3d, :labels].include?(mode) &&
                 telemetry_value(rung, :visual_fidelity_verified) != true
                errors << "completed_rung_visual_fidelity_unverified:#{span_id}"
              end
              if [:text3d, :labels].include?(mode) &&
                 telemetry_value(rung, :cleanup_outcome).to_s != 'not_required'
                errors << "completed_rung_cleanup_invalid:#{span_id}"
              end
            elsif outcome == 'failed'
              errors << "failed_rung_has_live_ids:#{span_id}" unless rung_ids == []
              created = telemetry_value(rung, :created_entity_ids)
              created = [] unless created.is_a?(Array)
              cleaned = telemetry_value(rung, :cleaned_entity_ids)
              cleaned = [] unless cleaned.is_a?(Array)
              unless created.empty?
                created_ids = RepresentationFidelity.positive_entity_ids(created)
                cleaned_valid = RepresentationFidelity.positive_entity_ids(cleaned)
                cleanup = telemetry_value(rung, :cleanup_outcome).to_s
                unless created_ids && cleaned_valid &&
                       created_ids.sort == cleaned_valid.sort && cleanup == 'verified'
                  errors << "failed_rung_cleanup_invalid:#{span_id}"
                end
                Array(cleaned_valid).each { |identity| cleaned_ids[identity] = true }
              end
              transition = telemetry_value(rung, :transition_proof)
              proof = symbolized_transition_proof(transition)
              begin
                raise RepresentationFidelity::ContractError,
                      'failed rung transition proof is missing' unless proof
                advanced = controller.advance!(proof)
                unless advanced == expected_history_modes[rung_index + 1]
                  raise RepresentationFidelity::ContractError,
                        'failed rung transition does not match the ladder'
                end
                if mode == :text
                  evidence = proof[:evidence]
                  attempt_bbox = telemetry_value(attempt, :source_bbox_pdf)
                  attempt_sha = telemetry_value(
                    attempt, :source_text_sha256
                  ).to_s.downcase
                  proof_sha = telemetry_value(
                    evidence, :source_text_sha256
                  ).to_s.downcase
                  proof_bbox = telemetry_value(evidence, :source_bbox_pdf)
                  attempt_bbox_values = attempt_bbox.is_a?(Array) ? attempt_bbox : []
                  proof_bbox_values = proof_bbox.is_a?(Array) ? proof_bbox : []
                  bbox_matches = attempt_bbox_values.length == 4 &&
                    proof_bbox_values.length == 4 &&
                    (0...4).all? do |index|
                      attempt_bbox_values[index].is_a?(Numeric) &&
                        proof_bbox_values[index].is_a?(Numeric) &&
                        RepresentationFidelity.close?(
                          attempt_bbox_values[index], proof_bbox_values[index],
                          1.0e-6
                        )
                    end
                  unless attempt_sha =~ /\A[0-9a-f]{64}\z/ &&
                         attempt_sha == proof_sha &&
                         bbox_matches
                    raise RepresentationFidelity::ContractError,
                          'flat Text proof conflicts with source attempt: ' \
                          "sha_match=#{attempt_sha == proof_sha}; " \
                          "attempt_bbox=#{attempt_bbox.inspect}; " \
                          "proof_bbox=#{proof_bbox.inspect}"
                  end
                end
                attempt_transition_signatures << transition_signature(proof)
              rescue StandardError => e
                errors << "failed_rung_transition_invalid:#{span_id}:#{e.message}"
              end
            else
              errors << "rung_outcome_invalid:#{span_id}"
            end
          end
          unless observed_history_modes == expected_history_modes
            errors << "attempt_history_ladder_mismatch:#{span_id}"
          end
          if completed.length != 1 || completed[0][0] != delivered ||
             completed[0][1].sort != ids.sort
            errors << "attempt_terminal_crosslink_invalid:#{span_id}"
          end
          attempt_by_span[span_id] ||= []
          attempt_by_span[span_id].concat(ids)
        end

        global_transition_signatures = fallback_transitions.map do |entry|
          transition_signature(entry)
        end
        if global_transition_signatures.any? { |signature| signature.nil? } ||
           global_transition_signatures.map { |signature| signature.inspect }.sort !=
             attempt_transition_signatures.map { |signature| signature.inspect }.sort
          errors << 'fallback_transition_ledger_mismatch'
        end

        expected_set = source_ids.sort
        delivered_set = (provenance_by_span.keys + terminal_by_span.keys +
                         page_delivery_by_span.keys).uniq.sort
        attempt_set = attempt_by_span.keys.sort
        errors << 'source_delivery_set_mismatch' unless delivered_set == expected_set
        errors << 'source_attempt_set_mismatch' unless attempt_set == expected_set
        source_ids.each do |span_id|
          evidence_ids = provenance_by_span[span_id] ||
                         terminal_by_span[span_id] ||
                         page_delivery_by_span[span_id]
          attempt_ids = attempt_by_span[span_id]
          unless evidence_ids && attempt_ids && evidence_ids.sort == attempt_ids.sort
            errors << "attempt_provenance_crosslink_invalid:#{span_id}"
          end
        end
        cleaned_ids.each_key do |identity|
          errors << "cleaned_entity_is_live:#{identity}" if live_id_owner.key?(identity)
        end

        {
          ready: errors.empty?,
          checks: {
            source_span_set_equality: !errors.include?('source_delivery_set_mismatch') &&
                                      !errors.include?('source_attempt_set_mismatch'),
            positive_stable_entity_ids: errors.none? { |error| error.include?('ids_invalid') || error.include?('duplicate_live') },
            attempt_provenance_crosslinks: errors.none? { |error| error.include?('crosslink') },
            cleanup_integrity: errors.none? { |error| error.include?('cleanup') || error.include?('cleaned_entity_is_live') }
          },
          errors: errors.uniq
        }
      rescue StandardError => e
        { ready: false, checks: {}, errors: ["validator_exception:#{e.class}:#{e.message}"] }
      end

      def attach_source_provenance!(report, stats)
        objects = Array(stats[:source_provenance_objects] || stats['source_provenance_objects'])
        has_provenance_ledger = stats.key?(:source_provenance_objects) ||
                                stats.key?('source_provenance_objects')
        has_session = stats.key?(:import_session_id) ||
                      stats.key?('import_session_id')
        return unless has_provenance_ledger || has_session

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
          object_count: objects.length,
          objects: normalize_json(objects)
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
      # finite item fallback such as Labels -> source-glyph 3D Text.
      def delivered_text_entity_counts(stats)
        counts = {}
        Array(stats[:source_provenance_objects] || stats['source_provenance_objects']).each do |entry|
          next unless entry.respond_to?(:[])
          kind = (entry[:created_entity_type] || entry['created_entity_type']).to_s.strip
          next if kind.empty?
          counts[kind] = counts.fetch(kind, 0).to_i + 1
        end
        # An item-level raster is terminal delivery for one source text span,
        # but it deliberately has no source-provenance object: the resulting
        # entity is an image, not a fabricated text entity. Count it only from
        # the same self-contained evidence the fidelity validator accepts.
        Array(stats[:terminal_text_delivery_records] ||
              stats['terminal_text_delivery_records']).each do |entry|
          next unless verified_item_raster_delivery_record?(entry)
          counts['raster_image'] = counts.fetch('raster_image', 0).to_i + 1
        end
        counts
      rescue StandardError
        {}
      end

      def verified_item_raster_delivery_record?(entry)
        return false unless entry.is_a?(Hash)
        return false unless telemetry_value(entry, :created_entity_type).to_s ==
                            'raster_image'
        return false unless telemetry_value(entry, :delivery_scope).to_s ==
                            'item_raster'
        return false unless RepresentationFidelity.normalize_mode(
          telemetry_value(entry, :delivered_mode)
        ) == :raster
        return false unless telemetry_value(entry, :cleanup_outcome).to_s ==
                            'not_required'
        return false unless telemetry_value(entry, :real_raster_verified) == true
        return false unless telemetry_value(
          entry, :source_crop_binding_verified
        ) == true
        return false unless telemetry_value(entry, :visual_fidelity_verified) == true

        spans = telemetry_value(entry, :source_span_ids)
        return false unless spans.is_a?(Array) && spans.length == 1
        source_id = spans[0].to_s.strip
        return false unless source_id =~ RepresentationFidelity::SOURCE_ID
        ids = RepresentationFidelity.positive_entity_ids(
          telemetry_value(entry, :resulting_entity_ids)
        )
        return false unless ids && ids.length == 1
        page = telemetry_value(entry, :page).to_i
        return false unless page > 0
        artifact = telemetry_value(entry, :artifact_evidence)
        artifact.is_a?(Hash) &&
          telemetry_value(artifact, :source_span_id).to_s == source_id &&
          telemetry_value(artifact, :page_number).to_i == page &&
          telemetry_value(artifact, :source_crop_binding_verified) == true
      rescue StandardError
        false
      end

      def build_actual_text_entity_types_from_delivered_counts(raw_counts)
        return nil unless raw_counts.respond_to?(:each)

        supported = %w[
          native_label native_3d_text source_glyph_3d_text glyph_outline page_path_geometry
          outline_curve_or_mesh raw_geometry_edges dxf_text fallback_geometry raster_image
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
                      elsif counts['native_3d_text'] || counts['source_glyph_3d_text']
                        '3d_text'
                      elsif counts['glyph_outline']
                        'glyphs'
                      elsif counts['page_path_geometry']
                        'geometry'
                      elsif counts['outline_curve_or_mesh'] || counts['raw_geometry_edges']
                        'geometry'
                      elsif counts['dxf_text']
                        'dxf_text'
                      elsif counts['raster_image']
                        'raster'
                      else
                        'fallback_geometry'
                      end
        info = {
          entity_type: entity_type,
          count: total,
          font_rendered: !!(counts['native_label'] || counts['native_3d_text'] ||
                            counts['source_glyph_3d_text']),
          source_glyph_identity_verified: !!counts['source_glyph_3d_text'],
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
        # an unavailable source, unmatched runs, or a dropped CID
        # language pack are signals, never silent passes.
        glyph_source = glyph_source_block(stats)
        if glyph_source
          if glyph_source[:source] == 'unavailable'
            signals << 'glyph_source_unavailable'
            actions << "Glyphs mode stopped without substituting another representation (#{glyph_source[:fallback_reason]}) — install or configure the free Poppler/MuPDF renderer and retry."
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

        # P1-3 fleet parity: every human summary attributes the importer
        # version so owner-shared reports stay attributable evidence.
        importer_info = data['importer'] || {}
        importer_ver = importer_info['version'].to_s.strip
        parts << "Importer v#{importer_ver}" unless importer_ver.empty?

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
