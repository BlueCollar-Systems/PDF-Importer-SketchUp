# bc_pdf_vector_importer/batch_pipeline.rb
# Headless offline PDF analysis for batch CLI and CI (no SketchUp GUI).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'json'
require 'fileutils'
require 'time'

module BlueCollarSystems
  module PDFVectorImporter
    module BatchPipeline

      PREFLIGHT_TEXT = <<'TEXT'.freeze
BlueCollar PDF Vector Importer — SketchUp preflight (offline batch CLI)

Modes (BCS-ARCH-001): auto, vector, raster, hybrid — all target maximum fidelity.
Text modes (orthogonal): geometry, glyphs, labels, 3d_text.

Offline batch CLI (this tool):
  ruby tools/su_batch_cli.rb --preflight
  ruby tools/su_batch_cli.rb drawing.pdf --report-dir ./reports

Outputs import_report.json plus optional geometry sidecar without SketchUp.
Full geometry import still requires SketchUp with the extension loaded.

Full geometry batch (SketchUp host required):
  "C:\Program Files\SketchUp\SketchUp 2024\SketchUp.exe" ^
    -RubyStartup "path\to\tools\sketchup_batch_import.rb" ^
    -RubyStartupArg "C:\drawings\input.pdf"

Use Compatibility Report inside SketchUp to verify bundled Poppler helpers.
TEXT

      module_function

      def preflight_paragraph
        PREFLIGHT_TEXT.strip
      end

      def parse_pages(raw)
        return nil if raw.nil? || raw.to_s.strip.empty?
        return (1..999_999).to_a if raw.to_s.strip.downcase == 'all'

        pages = []
        raw.to_s.split(',').each do |part|
          part = part.strip
          next if part.empty?
          if part.include?('-')
            lo, hi = part.split('-', 2)
            pages.concat((lo.to_i..hi.to_i).to_a)
          else
            pages << part.to_i
          end
        end
        pages.uniq.sort
      end

      def analyze_pdf(pdf_path, opts = {})
        start_time = Time.now
        result = {
          pdf: pdf_path.to_s,
          status: 'FAIL',
          error: nil,
          pages: 0,
          paths: 0,
          text_items: 0,
          embedded_images: 0,
          elapsed_ms: 0.0
        }

        gate = PdfOpenGate.inspect_path(pdf_path)
        unless gate[:ok]
          result[:status] = 'REFUSED'
          result[:error] = "#{gate[:reason]}: #{gate[:message]}"
          result[:elapsed_ms] = ((Time.now - start_time) * 1000.0).round(1)
          return result
        end

        parser = PDFParser.new(pdf_path)
        parser.parse
        page_numbers = resolve_page_numbers(parser, opts[:pages])
        result[:pages] = page_numbers.length

        total_paths = 0
        total_text = 0
        total_images = 0

        page_numbers.each do |page_num|
          raw = parser.page_data(page_num)
          next unless raw

          streams = raw[:content_streams] || []
          ocg_map = begin
            parser.page_ocg_map(page_num) || {}
          rescue StandardError
            {}
          end

          csp = ContentStreamParser.new(streams, parser, ocg_map)
          total_paths += csp.parse.length

          font_maps = parser.page_font_maps(page_num)
          text_items = TextParser.new(streams, font_maps, {}, ocg_map).parse
          total_text += Array(text_items).length

          images = EmbeddedImageExtractor.new(parser, nil).extract_page(page_num, nil, false)
          total_images += images.length
        end

        result[:paths] = total_paths
        result[:text_items] = total_text
        result[:embedded_images] = total_images
        result[:status] = 'OK'
        result[:elapsed_ms] = ((Time.now - start_time) * 1000.0).round(1)
        result
      rescue StandardError => e
        result[:status] = 'FAIL'
        result[:error] = "#{e.class}: #{e.message}"
        result[:elapsed_ms] = ((Time.now - start_time) * 1000.0).round(1)
        result
      ensure
        begin
          parser.release if parser
        rescue StandardError
          # ignore
        end
      end

      def build_stats_from_analysis(analysis, opts = {})
        elapsed_s = analysis[:elapsed_ms].to_f / 1000.0
        {
          pages: analysis[:pages].to_i,
          primitives: analysis[:paths].to_i,
          edges: 0,
          text: analysis[:text_items].to_i,
          arcs: 0,
          layers: [],
          elapsed_seconds: elapsed_s,
          text_renderers: [],
          text_mode: (opts[:text_mode] || :none),
          embedded_images: analysis[:embedded_images].to_i,
          embedded_image_paths: [],
          import_session_id: SourceProvenance.new_import_session_id,
          source_provenance_objects: [],
          batch_offline: true
        }
      end

      def build_geometry_sidecar(analysis, opts = {})
        {
          schema: 'bcs.sketchup_geometry_sidecar/1.0',
          host: 'sketchup',
          mode: (opts[:import_mode] || 'auto').to_s,
          offline: true,
          pdf: analysis[:pdf],
          pages: analysis[:pages].to_i,
          path_count: analysis[:paths].to_i,
          text_item_count: analysis[:text_items].to_i,
          embedded_image_count: analysis[:embedded_images].to_i,
          note: 'Geometry counts from offline parse — SketchUp host import required for edges/faces.'
        }
      end

      def run_file(pdf_path, opts = {})
        analysis = analyze_pdf(pdf_path, opts)
        out = {
          pdf: pdf_path.to_s,
          status: analysis[:status],
          error: analysis[:error],
          import_report_path: nil,
          geometry_sidecar_path: nil,
          source_provenance_sidecar_path: nil
        }

        if analysis[:status] == 'REFUSED'
          gate = PdfOpenGate.inspect_path(pdf_path)
          report = QAReport.build_open_failure(
            pdf_path,
            opts,
            gate[:reason],
            gate[:message]
          )
          report_path = write_report(report, pdf_path, opts)
          out[:import_report_path] = report_path
          return out
        end

        return out unless analysis[:status] == 'OK'

        stats = build_stats_from_analysis(analysis, opts)
        report = QAReport.build_from_stats(pdf_path, opts, stats)
        report_path = write_report(report, pdf_path, opts)
        out[:import_report_path] = report_path

        if opts[:geometry_sidecar]
          sidecar_path = geometry_sidecar_path_for(pdf_path, opts)
          FileUtils.mkdir_p(File.dirname(sidecar_path))
          File.write(
            sidecar_path,
            JSON.pretty_generate(build_geometry_sidecar(analysis, opts)) + "\n",
            encoding: 'UTF-8'
          )
          out[:geometry_sidecar_path] = sidecar_path
        end

        out
      end

      def write_report(report, pdf_path, opts)
        if opts[:report_dir]
          base = File.basename(pdf_path.to_s, '.pdf')
          path = File.join(opts[:report_dir].to_s, "#{base}_import_report.json")
        else
          path = QAReport.default_output_path(pdf_path)
        end
        QAReport.write_json(report, path)
      end

      def geometry_sidecar_path_for(pdf_path, opts)
        base = File.basename(pdf_path.to_s, '.pdf')
        if opts[:report_dir]
          File.join(opts[:report_dir].to_s, "#{base}_geometry_sidecar.json")
        else
          File.join(File.dirname(pdf_path.to_s), "#{base}_geometry_sidecar.json")
        end
      end

      def resolve_page_numbers(parser, pages_opt)
        if pages_opt.nil? || pages_opt == 'all'
          return (1..parser.page_count).to_a
        end
        nums = pages_opt.is_a?(Array) ? pages_opt : parse_pages(pages_opt)
        nums = (1..parser.page_count).to_a if nums.nil? || nums.empty?
        nums.select { |n| n >= 1 && n <= parser.page_count }
      end

    end
  end
end
