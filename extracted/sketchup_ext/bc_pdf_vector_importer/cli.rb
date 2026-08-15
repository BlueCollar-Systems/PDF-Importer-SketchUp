# bc_pdf_vector_importer/cli.rb
# Headless CLI for parser QA, batch extraction, and embedded image export.
#
# This does not create a .skp file outside SketchUp. It runs the same parser,
# text, XObject, primitive, image, and report code used by the extension so
# large-file QA and asset extraction can be automated from a shell.
#
# Copyright 2024-2026 BlueCollar Systems -- BUILT. NOT BOUGHT.

require 'fileutils'
require 'json'
require 'optparse'
require 'time'

dir = File.expand_path(File.dirname(__FILE__))
require File.join(dir, 'logger')
require File.join(dir, 'command_runner')
require File.join(dir, 'dependency_resolver')
require File.join(dir, 'pdf_open_gate')
require File.join(dir, 'pdf_salvage')
require File.join(dir, 'pdf_parser')
require File.join(dir, 'content_stream_parser')
require File.join(dir, 'text_parser')
require File.join(dir, 'representation_fidelity')
require File.join(dir, 'text_source_identity')
require File.join(dir, 'external_text_extractor')
require File.join(dir, 'bezier')
require File.join(dir, 'arc_fitter')
require File.join(dir, 'ocg_parser')
require File.join(dir, 'xobject_parser')
require File.join(dir, 'page_transform')
require File.join(dir, 'primitives')
require File.join(dir, 'primitive_extractor')
require File.join(dir, 'embedded_image_extractor')
require File.join(dir, 'import_dialog')
require File.join(dir, 'cairo_glyph_source')
require File.join(dir, 'qa_report')

module BlueCollarSystems
  module PDFVectorImporter
    module CLI
      DEFAULTS = {
        mode: 'auto',
        pages: 'All',
        scale: '1.0',
        text_mode: '3D Text',
        import_text: 'Yes',
        match_pdf_layers: 'Yes',
        grouping_mode: 'Group per page',
        page_arrangement: 'Spread (20% gap)',
        extract_images: true,
        write_primitives: true,
        quiet: false
      }.freeze

      module_function

      def main(argv = ARGV)
        opts = parse_args(argv)

        if opts[:version]
          puts version_string
          return 0
        end

        if opts[:preflight]
          doc = run_preflight(opts[:input])
          puts JSON.pretty_generate(doc) unless opts[:quiet]
          return doc['status'] == 'fail' ? 1 : 0
        end

        unless opts[:input] && File.file?(opts[:input])
          warn 'Missing --input PDF path.'
          return 2
        end

        result = run(opts)
        puts JSON.pretty_generate(result[:summary]) unless opts[:quiet]
        result[:ok] ? 0 : 1
      rescue OptionParser::ParseError => e
        warn e.message
        return 2
      rescue StandardError => e
        warn "#{e.class}: #{e.message}"
        return 1
      ensure
        begin
          Logger.flush_log
        rescue StandardError
        end
      end

      def parse_args(argv)
        opts = DEFAULTS.dup
        parser = OptionParser.new do |o|
          o.banner = 'Usage: ruby cli.rb --input drawing.pdf [options]'
          o.on('--input PATH', 'PDF to inspect/import headlessly') { |v| opts[:input] = v }
          o.on('--output-dir DIR', 'Directory for reports/assets') { |v| opts[:output_dir] = v }
          o.on('--report PATH', 'import_report.json output path') { |v| opts[:report] = v }
          o.on('--mode MODE', 'auto, vector, raster, or hybrid') { |v| opts[:mode] = v }
          o.on('--pages SPEC', 'All, 1, 1-3, or 1,3,5') { |v| opts[:pages] = v }
          o.on('--scale VALUE', 'Scale factor') { |v| opts[:scale] = v }
        o.on('--text-mode MODE', 'text, labels, 3d_text, glyphs, geometry, raster, or no_text') { |v| opts[:text_mode] = v }
          o.on('--no-text', 'Disable text extraction') { opts[:import_text] = 'No'; opts[:text_mode] = 'No text' }
          o.on('--extract-images', 'Extract embedded Image XObjects') { opts[:extract_images] = true }
          o.on('--no-extract-images', 'Do not extract embedded images') { opts[:extract_images] = false }
          o.on('--no-primitives-json', 'Skip primitives.json output') { opts[:write_primitives] = false }
          # Unrelated closed-shape extrusion is disabled; do not expose its CLI flags.
          o.on('--preflight', 'Run preflight checks and emit ready_check JSON') { opts[:preflight] = true }
          o.on('--version', 'Print plugin version and exit') { opts[:version] = true }
          o.on('--quiet', 'Only use exit code and files') { opts[:quiet] = true }
          o.on('-h', '--help', 'Show help') do
            puts o
            exit 0
          end
        end
        parser.parse!(argv)
        opts
      end

      def run(cli_opts)
        Logger.reset
        pdf_path = File.expand_path(cli_opts[:input].to_s)
        output_dir = default_output_dir(pdf_path, cli_opts[:output_dir])

        raw_opts = {
          import_mode: normalized_mode(cli_opts[:mode]),
          pages: cli_opts[:pages],
          scale: cli_opts[:scale],
          text_mode: cli_opts[:text_mode],
          import_text: cli_opts[:import_text],
          match_pdf_layers: cli_opts[:match_pdf_layers],
          grouping_mode: cli_opts[:grouping_mode],
          page_arrangement: cli_opts[:page_arrangement],
          layer_name: 'PDF Import',
          group_per_page: 'Yes',
          group_by_color: 'Yes',
          extrude_to_3d: cli_opts[:extrude_to_3d],
          extrude_depth_mm: cli_opts[:extrude_depth_mm]
        }
        import_opts = ImportDialog.send(:build_opts, raw_opts)
        import_opts[:extract_embedded_images] = cli_opts[:extract_images]
        import_opts[:embedded_image_dir] = File.join(output_dir, 'embedded_images')

        # Round 18: normalize hostile PDFs (empty-password encryption,
        # damaged xref) through poppler BEFORE the open gate judges them —
        # viewers open these files, so the importer must too.
        begin
          pdf_path, salvage_note = PdfSalvage.prepare_if_needed(pdf_path)
          Logger.info('CLI', salvage_note) if salvage_note
        rescue PdfSalvage::SalvageError => e
          report = QAReport.build_open_failure(pdf_path, import_opts, 'encrypted', e.message)
          report_path = write_report(report, pdf_path, output_dir, cli_opts[:report])
          return {
            ok: false,
            summary: {
              status: 'refused',
              reason: 'encrypted',
              message: e.message,
              report: report_path
            }
          }
        rescue StandardError => e
          Logger.warn('CLI', "salvage preflight failed: #{e.message}")
        end

        gate = PdfOpenGate.inspect_path(pdf_path)
        unless gate[:ok]
          report = QAReport.build_open_failure(pdf_path, import_opts, gate[:reason], gate[:message])
          report_path = write_report(report, pdf_path, output_dir, cli_opts[:report])
          return {
            ok: false,
            summary: {
              status: 'refused',
              reason: gate[:reason],
              message: gate[:message],
              report: report_path
            }
          }
        end

        stats, payload = extract_pdf(pdf_path, import_opts, cli_opts)
        # Do not materialize an output tree until extraction (including the
        # all-pages source-identity gate) has completed successfully.
        FileUtils.mkdir_p(output_dir)
        report = QAReport.build_from_stats(pdf_path, import_opts, stats)
        attach_parts_sidecar(report, pdf_path, output_dir)
        report_path = write_report(report, pdf_path, output_dir, cli_opts[:report])
        primitive_path = nil
        if cli_opts[:write_primitives]
          primitive_path = File.join(output_dir, 'primitives.json')
          File.open(primitive_path, 'w') do |f|
            f.write(JSON.pretty_generate(payload) + "\n")
          end
        end

        {
          ok: true,
          summary: {
            status: 'ok',
            input: pdf_path,
            output_dir: output_dir,
            report: report_path,
            primitives_json: primitive_path,
            pages: stats[:pages],
            primitives: stats[:primitives],
            text: stats[:extracted_text_items],
            paths: stats[:paths],
            xobjects: stats[:xobjects],
            embedded_images: stats[:embedded_images],
            embedded_image_dir: import_opts[:embedded_image_dir],
            elapsed_seconds: stats[:elapsed_seconds]
          }
        }
      ensure
        Logger.flush_log
        PdfSalvage.cleanup(pdf_path) if defined?(PdfSalvage)
      end

      def extract_pdf(pdf_path, opts, cli_opts)
        parser = PDFParser.new(pdf_path)
        parser.parse
        ocg = OCGParser.new(parser)
        ocg.parse

        pages = normalize_pages(opts[:pages], parser.page_count)
        certified_pages = certify_page_text_sources(
          parser, pdf_path, pages, opts
        )
        IDGen.reset
        image_extractor = EmbeddedImageExtractor.new(parser, opts[:embedded_image_dir])

        stats = {
          pages: 0,
          primitives: 0,
          edges: 0,
          faces: 0,
          arcs: 0,
          text: 0,
          components: 0,
          layers: ocg.layer_list,
          cleanup: {},
          generic: nil,
          mode_used: nil,
          xobjects: 0,
          paths: 0,
          embedded_images: 0,
          embedded_image_files: [],
          execution_scope: :extraction_only,
          extracted_text_items: 0,
          text_source_span_ids: [],
          text_renderers: [],
          page_text_sources: {},
          page_text_map: {},
          model_3d_texts: [],
          text_mode: opts[:text_mode],
          elapsed_seconds: 0.0
        }
        payload = {
          schema: 'bcs.sketchup_cli_extract/1.0',
          generated_at: Time.now.utc.iso8601,
          input: pdf_path,
          pages: []
        }

        start = Time.now
        pages.each do |page_num|
          certified = certified_pages[page_num]
          next unless certified
          raw = certified[:raw]
          media_box = raw[:media_box] || [0, 0, 612, 792]
          streams = certified[:streams]
          ocg_map = certified[:ocg_map]
          cs = ContentStreamParser.new(streams, parser, ocg_map)
          paths = cs.parse

          xobj = XObjectParser.new(parser)
          xobj.scan_page(page_num)
          xobj.count_references(streams)
          xobj_paths = xobj.expanded_paths(streams)
          paths += xobj_paths if xobj_paths && !xobj_paths.empty?

          text_items = certified[:text_items]
          text_source = certified[:text_source]
          images = opts[:extract_embedded_images] == false ? [] : image_extractor.extract_page(page_num)
          page_data = PrimitiveExtractor.extract(
            paths,
            text_items,
            media_box,
            page_num,
            scale: opts[:scale],
            bezier_segments: opts[:bezier_segments],
            page_rotation: PageTransform.normalize_rotation(raw[:rotation])
          )
          page_data.layers = ocg.layer_list
          page_data.xobject_names = xobj.form_xobjects.keys

          stats[:pages] += 1
          stats[:paths] += paths.length
          stats[:primitives] += page_data.primitives.length
          stats[:extracted_text_items] += page_data.text_items.length
          stats[:xobjects] += xobj.form_xobjects.length
          stats[:embedded_images] += images.length
          stats[:embedded_image_files].concat(images.map { |img| img.file_path }.compact)
          stats[:page_text_sources][page_num] = text_source if text_source
          stats[:page_text_map][page_num] = text_items if text_items && !text_items.empty?
          Array(text_items).each do |item|
            source_id = RepresentationFidelity.source_span_id(item)
            stats[:text_source_span_ids] << source_id
          end
          if text_source
            stats[:text_renderers] << {
              page: page_num,
              renderer: :headless_extract,
              text_source: text_source,
              degraded: false
            }
          end

          # R23 (F-1): Glyphs-mode headless parity — the CLI report carries
          # the SAME extra.glyph_source telemetry the live import records,
          # exercising the real bundled pdftocairo + span matching (R17-3).
          if glyphs_text_mode?(opts)
            record_headless_glyph_source(stats, pdf_path, page_num, raw,
                                         media_box, text_items)
          end

          payload[:pages] << {
            page: page_num,
            media_box: media_box,
            crop_box: raw[:crop_box],
            rotation: raw[:rotation],
            paths: paths.length,
            primitives: page_data.primitives.map { |p| primitive_to_h(p) },
            text: page_data.text_items.map { |t| text_to_h(t) },
            embedded_images: images.map { |img| image_to_h(img) }
          }
        end
        stats[:elapsed_seconds] = (Time.now - start).round(3)
        [stats, payload]
      ensure
        begin
          parser.release if parser
        rescue StandardError
        end
      end

      # Certify the complete selected-page text ledger before creating any
      # embedded-image writer or downstream output. A malformed identity on a
      # later page therefore fails closed without partial CLI artifacts.
      def certify_page_text_sources(parser, pdf_path, pages, opts)
        certified = {}
        Array(pages).each do |page_num|
          raw = parser.page_data(page_num)
          unless raw
            raise "Page #{page_num}: parser returned no page data during " \
                  'selected-page source certification'
          end
          streams = raw[:content_streams] || []
          ocg_map = parser.page_ocg_map(page_num)
          text_items, text_source = extract_text(
            parser, pdf_path, page_num, streams, ocg_map, opts
          )
          enforce_extracted_text_presence!(
            page_num, opts[:text_mode], text_items, streams
          ) if opts[:import_text]
          TextSourceIdentity.assign!(text_items, page_num)
          TextSourceIdentity.validate!(text_items, page_num)
          certified[page_num] = {
            raw: raw,
            streams: streams,
            ocg_map: ocg_map,
            text_items: text_items,
            text_source: text_source
          }
        end
        certified
      end

      # Headless extraction must not certify an empty text ledger when the
      # decoded page stream contains real painting text. PDFParser expands
      # referenced (including nested) Form XObjects into these page streams.
      def enforce_extracted_text_presence!(page_num, requested_mode,
                                           text_items, streams)
        return true unless Array(text_items).empty?

        detected = TextParser.new(
          Array(streams), {}, { strict_text_fidelity: true,
                                merge_text_runs: false }
        ).nonempty_text_show_operation_count
        return true unless detected.to_i > 0

        label = requested_mode.to_s.strip
        label = 'requested text representation' if label.empty?
        raise RepresentationFidelity::ContractError,
              "Page #{page_num}: #{detected.to_i} nonempty PDF text-show " \
              "operation(s) were detected, but requested #{label} had no " \
              'certified source spans; headless extraction stopped instead ' \
              'of silently omitting the detected text.'
      rescue RepresentationFidelity::ContractError
        raise
      rescue StandardError => e
        raise RepresentationFidelity::ContractError,
              "Page #{page_num}: no-text proof failed for requested " \
              "#{requested_mode} (#{e.message}); headless extraction stopped " \
              'instead of silently omitting possible text.'
      end

      def extract_text(parser, pdf_path, page_num, streams, ocg_map, opts)
        return [[], nil] unless opts[:import_text]

        items = ExternalTextExtractor.extract(
          pdf_path, page_num, :content_streams => streams
        )
        return [items, :external] if items && !items.empty?

        font_maps = parser.page_font_maps(page_num)
        parsed = TextParser.new(streams, font_maps, { strict_text_fidelity: false }, ocg_map).parse
        [parsed || [], :internal]
      end

      def glyphs_text_mode?(opts)
        return false unless opts[:import_text]
        opts[:text_mode].to_s.strip.downcase.start_with?('glyph')
      end

      # R23 (F-1): headless mirror of the live Glyphs-mode source decision —
      # renders the page with the bundled pdftocairo, matches glyph pens to
      # extractor spans, and accumulates stats[:glyph_source]. A failed source
      # is reported unavailable; the CLI never invents a simplified glyph
      # delivery from extractor text.
      def record_headless_glyph_source(stats, pdf_path, page_num, raw,
                                       media_box, text_items)
        decision = CairoGlyphSource.import_decision(stats)
        return unless decision

        if CairoGlyphSource.svg_source?(decision)
          failure = {}
          page = CairoGlyphSource.render_page_svg(pdf_path, page_num,
                                                  failure_info: failure)
          pens = []
          if page
            crop = raw[:crop_box]
            crop = nil unless crop.is_a?(Array) && crop.length >= 4
            pens = CairoGlyphSource.pen_placements_pdf(
              page[:svg], media_box, svg_page_box: crop || media_box
            )
            if pens.empty? &&
               CairoGlyphSource.zero_placement_false_green?({ glyphs: 0 }, text_items)
              failure[:reason] = 'svg_zero_placements'
              page = nil
            end
          end
          if page
            CairoGlyphSource.record_svg_page!(
              decision, page_num,
              { glyphs: pens.length, placements_pdf: pens,
                missing_fonts: page[:missing_fonts],
                missing_language_packs: page[:missing_language_packs] },
              text_items, media_box, nil
            )
            return
          end
          CairoGlyphSource.mark_unavailable!(
            decision, CairoGlyphSource.failure_reason(failure)
          )
        end
      rescue StandardError => e
        Logger.warn('CLI', "glyph_source telemetry failed: #{e.message}")
      end

      def normalize_pages(spec, page_count)
        return [] if page_count.to_i <= 0
        return (1..page_count).to_a if spec == :all

        text = spec.to_s.strip
        return (1..page_count).to_a if text.empty? || text.downcase == 'all'

        pages = []
        text.split(/[,;\s]+/).each do |part|
          if part =~ /\A(\d+)\s*-\s*(\d+)\z/
            first = $1.to_i
            last = $2.to_i
            first, last = last, first if last < first
            (first..last).each { |p| pages << p }
          else
            n = part.to_i
            pages << n if n > 0
          end
        end
        pages = pages.uniq.sort.select { |p| p >= 1 && p <= page_count }
        pages.empty? ? (1..page_count).to_a : pages
      end

      def version_string
        loader = File.join(File.expand_path('..', File.dirname(__FILE__)), 'bc_pdf_vector_importer.rb')
        if File.file?(loader)
          m = File.read(loader, encoding: 'utf-8')[/PLUGIN_VERSION\s*=\s*'([^']+)'/, 1]
          return m if m
        end
        'unknown'
      end

      def run_preflight(pdf_path)
        checks = []
        add = ->(id, ok, msg) { checks << { 'id' => id, 'status' => ok ? 'pass' : 'fail', 'message' => msg } }
        add.call('input_exists', pdf_path && File.file?(pdf_path),
                 pdf_path ? "input: #{pdf_path}" : 'no input PDF given')
        if pdf_path && File.file?(pdf_path)
          header = File.binread(pdf_path, 8).to_s
          add.call('pdf_header', header.start_with?('%PDF-'),
                   header.start_with?('%PDF-') ? 'valid %PDF- header' : 'not a PDF (bad header)')
        end
        if pdf_path && File.file?(pdf_path)
          begin
            flags = QAReport.send(:pdf_interactive_flags, pdf_path)
            checks << { 'id' => 'active_content',
                        'status' => flags.empty? ? 'pass' : 'warn',
                        'message' => flags.empty? ? 'no document scripting/actions detected' : "PDF declares #{flags.join(', ')} (never executed; awareness only)" }
          rescue StandardError
            # scan is best-effort; absence of the check is acceptable
          end
        end
        pdftocairo = DependencyResolver.find_pdftocairo
        helper_paths = {
          'pdftotext' => DependencyResolver.find_pdftotext,
          'pdftocairo' => pdftocairo,
          'pdffonts' => DependencyResolver.find_pdffonts(pdftocairo)
        }
        helper_paths.each do |name, path|
          resolved = path.to_s.strip
          present = !resolved.empty?
          message = if present
                      "resolved #{name}: #{resolved}"
                    else
                      "#{name} unavailable; modes that require it stop explicitly"
                    end
          checks << { 'id' => "poppler_#{name}",
                      'status' => present ? 'pass' : 'warn',
                      'message' => message }
        end
        status = checks.any? { |c| c['status'] == 'fail' } ? 'fail' :
                 checks.any? { |c| c['status'] == 'warn' } ? 'warn' : 'pass'
        { 'schema' => 'bcs.ready_check/1.0', 'status' => status,
          'product' => 'SketchUp PDF Importer CLI', 'version' => version_string,
          'host' => { 'name' => 'sketchup' }, 'checks' => checks, 'repair_hints' => [] }
      end

      def normalized_mode(mode)
        m = mode.to_s.strip.downcase
        %w[auto vector raster hybrid].include?(m) ? m : 'auto'
      end

      def default_output_dir(pdf_path, requested)
        return File.expand_path(requested.to_s) if requested && !requested.to_s.strip.empty?
        base = File.basename(pdf_path.to_s, '.pdf')
        File.join(Dir.pwd, "#{base}_sketchup_cli")
      end

      def write_report(report, pdf_path, output_dir, requested)
        path = requested
        path = File.join(output_dir, "#{File.basename(pdf_path, '.pdf')}_import_report.json") if path.to_s.strip.empty?
        QAReport.write_json(report, path)
      end

      def attach_parts_sidecar(report, pdf_path, output_dir)
        payload = report[:extra] && report[:extra][:parts_bootstrap]
        return unless payload && payload[:row_count].to_i > 0

        base = File.join(output_dir, File.basename(pdf_path.to_s, File.extname(pdf_path.to_s)))
        sidecar_path = PartsBootstrap.write_sidecar(payload, base)
        return unless sidecar_path

        payload[:sidecar_path] = sidecar_path
        report[:extra][:parts_bootstrap] = payload
      rescue StandardError => e
        Logger.warn('CLI', "parts_bootstrap sidecar failed: #{e.message}")
      end

      def primitive_to_h(prim)
        {
          id: prim.id,
          type: prim.type,
          points: prim.points,
          center: prim.center,
          radius: prim.radius,
          start_angle: prim.start_angle,
          end_angle: prim.end_angle,
          bbox: prim.bbox,
          stroke_color: prim.stroke_color,
          fill_color: prim.fill_color,
          dash_pattern: prim.dash_pattern,
          line_width: prim.line_width,
          layer_name: prim.layer_name,
          closed: prim.closed,
          area: prim.area,
          page_number: prim.page_number
        }
      end

      def text_to_h(text)
        {
          id: text.id,
          text: text.text,
          normalized: text.normalized,
          insertion: text.insertion,
          bbox: text.bbox,
          font_size: text.font_size,
          rotation: text.rotation,
          font_name: text.font_name,
          page_number: text.page_number,
          classifications: text.classifications
        }
      end

      def image_to_h(image)
        {
          page: image.page_number,
          name: image.name,
          object: image.obj_num,
          placement_index: image.placement_index,
          width: image.width,
          height: image.height,
          bits_per_component: image.bits_per_component,
          color_space: image.color_space,
          filters: image.filters,
          ctm: image.ctm,
          bbox_pts: image.bbox_pts,
          file: image.file_path,
          metadata: image.metadata_path,
          bytes_written: image.bytes_written,
          encoded: image.encoded
        }
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit BlueCollarSystems::PDFVectorImporter::CLI.main(ARGV)
end
