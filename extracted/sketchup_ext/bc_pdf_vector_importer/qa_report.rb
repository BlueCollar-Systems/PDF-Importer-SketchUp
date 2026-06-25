# bc_pdf_vector_importer/qa_report.rb
# Shared import_report.json builder (bcs.import_report/1.1)
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'json'
require 'digest'
require 'fileutils'

module BlueCollarSystems
  module PDFVectorImporter
    module QAReport

      SCHEMA = 'bcs.import_report/1.1'.freeze
      SCALE_TRUST_CONFIDENCE = 0.70
      SCALE_DIMENSION_TENSION_CONFIDENCE = 0.85
      SCALE_FACTOR_DISAGREE_RATIO = 0.15

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
          extra: extra_block(stats, warnings, degraded_renderers)
        }
        enrich_report_extras!(report)
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
        if stats[:raster_fallback_used]
          return { used: true, reason: 'raster_fallback' }
        end

        degraded = Array(degraded_renderers)
        if degraded.empty?
          return { used: false, reason: nil }
        end

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
        {
          used: true,
          reason: reason,
          notes: notes
        }
      end

      def extra_block(stats, warning_count = 0, degraded_renderers = [])
        renderers = Array(stats[:text_renderers]).map do |entry|
          normalize_json(entry)
        end
        {
          text_renderers: renderers,
          edges: stats[:edges].to_i,
          arcs: stats[:arcs].to_i,
          text_mode: stats[:text_mode].to_s,
          svg_renderer_missing: !!stats[:svg_renderer_missing],
          resolved_scale: stats[:resolved_scale] ? normalize_json(stats[:resolved_scale]) : nil,
          scale_hints: scale_hints_block(stats),
          diagnostics: diagnostics_block(stats, warning_count, degraded_renderers)
        }
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
        report[:extra][:human_summary] = build_human_summary(report)
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

      def diagnostics_block(stats, warning_count = 0, degraded_renderers = [])
        primitives = stats[:primitives].to_i
        text_entities = stats[:text].to_i
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
          else
            signals << 'no_vector_geometry_created'
            'empty'
          end

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
