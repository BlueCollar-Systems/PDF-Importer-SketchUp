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

      module_function

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

        {
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
          performance: {
            elapsed_ms: elapsed_ms,
            peak_mb: 0.0
          },
          fallback: fallback_block(stats, degraded_renderers),
          mode: import_mode_label(opts),
          extra: extra_block(stats)
        }
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

      def extra_block(stats)
        renderers = Array(stats[:text_renderers]).map do |entry|
          normalize_json(entry)
        end
        {
          text_renderers: renderers,
          edges: stats[:edges].to_i,
          arcs: stats[:arcs].to_i,
          text_mode: stats[:text_mode].to_s,
          svg_renderer_missing: !!stats[:svg_renderer_missing],
          resolved_scale: stats[:resolved_scale] ? normalize_json(stats[:resolved_scale]) : nil
        }
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
