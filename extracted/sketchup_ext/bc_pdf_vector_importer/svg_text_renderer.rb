# bc_pdf_vector_importer/svg_text_renderer.rb
# Renders PDF text as precise vector geometry using Poppler or MuPDF SVG.
#
# Normal PDFs draw glyphs as raw transformed edges so selecting text does not
# show one bounding box per glyph. Very large glyph runs fall back to component
# instances for performance.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'tmpdir'
require File.join(File.dirname(__FILE__), 'command_runner')
require File.join(File.dirname(__FILE__), 'logger')
require File.join(File.dirname(__FILE__), 'dependency_resolver')

module BlueCollarSystems
  module PDFVectorImporter
    module SvgTextRenderer

      PDF_PT_TO_INCH = 1.0 / 72.0
      DEFAULT_EDGE_GLYPH_THRESHOLD = 5_000

      def self.render(entities, pdf_path, page_num, media_box, opts = {})
        renderer = find_svg_renderer
        return nil unless renderer

        # If the PDF references non-embedded fonts (e.g. the base-14 "Symbol"
        # font) that pdftocairo can't resolve on this platform, embed them once
        # via Ghostscript so text renders instead of collapsing to a blob.
        render_pdf = renderer[:kind] == :pdftocairo ?
          ensure_renderable_pdf(pdf_path, renderer[:exe]) : pdf_path

        scale = opts[:scale] || 1.0
        y_offset = opts[:y_offset] || 0.0
        text_layer = opts[:layer]
        svg_page_box = opts[:svg_page_box] || media_box
        media_min_x = media_box[0].to_f
        media_min_y = media_box[1].to_f
        svg_min_x = svg_page_box[0].to_f
        svg_min_y = svg_page_box[1].to_f
        page_w   = (svg_page_box[2] - svg_page_box[0]).abs.to_f
        page_h   = (svg_page_box[3] - svg_page_box[1]).abs.to_f
        box_offset_x_in = (svg_min_x - media_min_x) * PDF_PT_TO_INCH * scale.to_f
        box_offset_y_in = (svg_min_y - media_min_y) * PDF_PT_TO_INCH * scale.to_f

        # pdftocairo's SVG backend writes later pages reliably when the output
        # target is a bare filename, not a .svg-suffixed path. MuPDF also accepts
        # the extensionless path because the format is supplied explicitly.
        svg_path = temp_svg_path

        use_cropbox = false
        begin
          if media_box.is_a?(Array) && media_box.length >= 4 &&
             svg_page_box.is_a?(Array) && svg_page_box.length >= 4
            use_cropbox = svg_page_box.zip(media_box).any? { |a, b| (a.to_f - b.to_f).abs > 0.01 }
          end
        rescue StandardError => e
          Logger.warn("SvgTextRenderer", "cropbox compare failed: #{e.message}")
        end

        arg_variants = svg_render_arg_variants(
          renderer, render_pdf, svg_path, page_num, use_cropbox
        )

        used_cropbox_fallback = false
        render_ok = false
        render_stderr = ""
        arg_variants.each_with_index do |args, idx|
          begin
            File.delete(svg_path) if File.exist?(svg_path)
          rescue StandardError
            # best-effort cleanup
          end

          run = CommandRunner.run(
            args,
            timeout_s: 90,
            context: "SvgTextRenderer.#{renderer[:kind]}"
          )
          if run[:ok] && File.exist?(svg_path)
            used_cropbox_fallback = (idx == 1 && use_cropbox)
            render_stderr = run[:stderr].to_s
            render_ok = true
            break
          end
          break if run[:timed_out]
        end
        return nil unless render_ok
        if used_cropbox_fallback
          Logger.warn("SvgTextRenderer",
            "Page #{page_num}: #{renderer[:kind]} crop box render unavailable; used media box SVG fallback")
        end

        svg = File.read(svg_path, encoding: 'UTF-8')
        glyphs = parse_glyph_defs(svg)
        placements = parse_use_placements(svg)
        return { edges: 0, glyphs: 0, renderer: renderer[:kind] } if placements.empty?

        # OCR-backed PDFs can contain many "#source-*" uses for embedded images.
        # Do not disable glyph rendering solely because of source image uses:
        # that fallback causes text drift on symbol charts and OCR overlays.
        source_use_count = svg.scan(/<use\b[^>]*(?:xlink:href|href)="#source-[^"]+"/).length
        if source_use_count > 0
          Logger.info("SvgTextRenderer",
            "Page #{page_num}: source_uses=#{source_use_count}, glyph_uses=#{placements.length} (rendering glyph geometry)")
        end

        vb_min_x, vb_min_y, vb_w, vb_h = parse_viewbox(svg)
        vb_w = page_w if vb_w <= 0.0
        vb_h = page_h if vb_h <= 0.0
        # pdftocairo SVG coordinates are already in PDF points for the rendered
        # page box (often CropBox). Use direct pt->inch conversion to avoid
        # MediaBox-vs-CropBox rescaling drift on OCR/chart PDFs.
        x_unit_to_in = PDF_PT_TO_INCH * scale.to_f
        y_unit_to_in = PDF_PT_TO_INCH * scale.to_f

        model = nil
        begin
          model = entities.model if entities.respond_to?(:model)
        rescue StandardError => e
          Logger.warn("SvgTextRenderer", "entities.model lookup failed: #{e.message}")
        end
        model ||= Sketchup.active_model if defined?(Sketchup) && Sketchup.respond_to?(:active_model)
        raise "SketchUp model unavailable for glyph definitions" unless model
        edge_count = 0
        glyph_count = 0
        placement_count = placements.length
        raw_edge_glyphs = raw_edge_glyphs?(opts, placement_count)

        # Build each unique glyph once. Normal-size text imports keep point
        # paths and stamp raw edges; huge imports use component definitions.
        Sketchup.status_text = "Building #{glyphs.length} glyph shapes..."
        glyph_defs = {}
        glyph_paths = {}
        glyphs.each do |glyph_id, path_d|
          next if path_d.strip.empty?
          subpaths = svg_path_to_points(path_d, x_unit_to_in, y_unit_to_in)
          next if subpaths.empty?

          if raw_edge_glyphs
            glyph_paths[glyph_id] = subpaths
          else
            defn = model.definitions.add("_g_#{glyph_id}")
            subpaths.each do |pts|
              next if pts.length < 2
              begin
                r = defn.entities.add_edges(pts)
                edge_count += r.length if r
              rescue StandardError => e
                Logger.warn("SvgTextRenderer", "add_edges for glyph failed: #{e.message}")
              end
            end
            glyph_defs[glyph_id] = defn if defn.entities.count > 0
          end
        end

        # Guard against font-substitution failures (see collapsed_signature_keys):
        # skip glyphs pdftocairo stamped at one identical transform so they do
        # not pile into a blob.
        collapsed_set = {}
        collapsed_signature_keys(placements).each { |k| collapsed_set[k] = true }
        skipped_collapsed = 0

        # Place instances (fast)
        total = placements.length
        placements.each_with_index do |p, idx|
          if idx % 500 == 0
            Sketchup.status_text = "Placing text: #{idx}/#{total} [#{((idx.to_f/total)*100).round}%]"
          end

          glyph_data = raw_edge_glyphs ? glyph_paths[p[:glyph_id]] : glyph_defs[p[:glyph_id]]
          next unless glyph_data

          if collapsed_set[placement_signature(p)]
            skipped_collapsed += 1
            next
          end

          begin
            tr = nil
            if p[:matrix].is_a?(Array) && p[:matrix].length >= 6
              a, b, c, d, e, f = p[:matrix].map(&:to_f)
              # SVG <use> x/y are additive placement offsets.
              e += p[:x].to_f
              f += p[:y].to_f

              tx = (e - vb_min_x) * x_unit_to_in + box_offset_x_in
              ty = (vb_h + vb_min_y - f) * y_unit_to_in + y_offset.to_f + box_offset_y_in

              # Local glyph coordinates are scaled to inches and Y-flipped.
              ratio_xy = y_unit_to_in.zero? ? 1.0 : (x_unit_to_in / y_unit_to_in)
              ratio_yx = x_unit_to_in.zero? ? 1.0 : (y_unit_to_in / x_unit_to_in)
              xaxis = Geom::Vector3d.new(a, -b * ratio_yx, 0.0)
              yaxis = Geom::Vector3d.new(-c * ratio_xy, d, 0.0)
              zaxis = Geom::Vector3d.new(0.0, 0.0, 1.0)
              tr = Geom::Transformation.axes(Geom::Point3d.new(tx, ty, 0.0), xaxis, yaxis, zaxis)
            else
              tx = (p[:x].to_f - vb_min_x) * x_unit_to_in + box_offset_x_in
              ty = (vb_h + vb_min_y - p[:y].to_f) * y_unit_to_in + y_offset.to_f + box_offset_y_in
              tr = Geom::Transformation.new(Geom::Point3d.new(tx, ty, 0.0))
            end

            if raw_edge_glyphs
              added = add_transformed_glyph_edges(entities, glyph_data, tr, text_layer)
              edge_count += added
              next if added <= 0
            else
              inst = entities.add_instance(glyph_data, tr)
              begin
                inst.layer = text_layer if inst && text_layer
              rescue StandardError => e
                Logger.warn("SvgTextRenderer", "set_layer on glyph instance failed: #{e.message}")
              end
            end
            glyph_count += 1
          rescue StandardError => e
            Logger.warn("SvgTextRenderer", "place glyph failed: #{e.message}")
          end
        end

        missing_fonts = missing_display_fonts(render_stderr)
        if skipped_collapsed > 0
          note = missing_fonts.empty? ? "" : " (unresolved font#{missing_fonts.length > 1 ? 's' : ''}: #{missing_fonts.join(', ')})"
          begin
            Logger.warn("SvgTextRenderer",
              "Page #{page_num}: skipped #{skipped_collapsed} glyph(s) collapsed onto one point#{note}; " \
              "those characters were not rendered. Install/enable the font for full fidelity.")
          rescue StandardError
          end
          begin
            Sketchup.status_text = "PDF text: skipped #{skipped_collapsed} unresolved glyph(s)#{note}" if defined?(Sketchup)
          rescue StandardError
          end
        end

        { edges: edge_count, glyphs: glyph_count, renderer: renderer[:kind],
          cropbox_fallback: used_cropbox_fallback,
          glyph_instances: raw_edge_glyphs ? 0 : glyph_count,
          raw_edge_glyphs: raw_edge_glyphs,
          skipped_glyphs: skipped_collapsed, missing_fonts: missing_fonts }
      rescue StandardError => e
        begin
          Logger.warn("SvgTextRenderer", "Failed: #{e.message}")
        rescue StandardError
          # Logger may be unavailable in minimal runtime/test contexts.
        end
        nil
      ensure
        begin
          File.delete(svg_path) if svg_path && File.exist?(svg_path)
        rescue StandardError => e
          Logger.warn("SvgTextRenderer", "cleanup temp svg failed: #{e.message}")
        end
      end

      private

      def self.raw_edge_glyphs?(opts, placement_count)
        return false if opts[:raw_edge_glyphs] == false
        placement_count.to_i <= raw_edge_glyph_threshold
      end

      def self.raw_edge_glyph_threshold
        raw = ENV['BC_SU_GLYPH_EDGE_THRESHOLD'].to_s.strip
        value = raw.empty? ? DEFAULT_EDGE_GLYPH_THRESHOLD : raw.to_i
        value.positive? ? value : DEFAULT_EDGE_GLYPH_THRESHOLD
      rescue StandardError
        DEFAULT_EDGE_GLYPH_THRESHOLD
      end

      def self.add_transformed_glyph_edges(entities, subpaths, tr, text_layer)
        added = 0
        Array(subpaths).each do |pts|
          next unless pts && pts.length >= 2
          pts.each_cons(2) do |a, b|
            begin
              pa = a.respond_to?(:transform) ? a.transform(tr) : tr * a
              pb = b.respond_to?(:transform) ? b.transform(tr) : tr * b
              edge = entities.add_line(pa, pb)
              begin
                edge.layer = text_layer if edge && text_layer
              rescue StandardError => e
                Logger.warn("SvgTextRenderer", "set_layer on glyph edge failed: #{e.message}")
              end
              added += 1 if edge
            rescue StandardError => e
              Logger.warn("SvgTextRenderer", "add_line for glyph edge failed: #{e.message}")
            end
          end
        end
        added
      end

      def self.warn_safe(message)
        Logger.warn("SvgTextRenderer", message)
      rescue StandardError
        # Logger may be unavailable in minimal runtime/test contexts.
      end

      def self.temp_svg_path
        File.join(Dir.tmpdir,
          "bc_svg_#{Process.pid}_#{Time.now.to_i}_#{rand(100000)}")
      end

      def self.find_svg_renderer
        poppler = find_pdftocairo
        return { kind: :pdftocairo, exe: poppler } if poppler

        mupdf = find_mutool
        return { kind: :mutool, exe: mupdf } if mupdf

        nil
      end

      def self.find_pdftocairo
        DependencyResolver.find_pdftocairo
      rescue StandardError => e
        Logger.warn("SvgTextRenderer", "find_pdftocairo failed: #{e.message}")
        nil
      end

      def self.find_mutool
        DependencyResolver.find_mutool
      rescue StandardError => e
        Logger.warn("SvgTextRenderer", "find_mutool failed: #{e.message}")
        nil
      end

      def self.svg_render_arg_variants(renderer, pdf_path, svg_path, page_num, use_cropbox)
        exe = renderer[:exe].to_s
        page = page_num.to_i.to_s
        if renderer[:kind] == :mutool
          base = [exe, 'draw', '-q', '-F', 'svg', '-o', svg_path.to_s, pdf_path.to_s, page]
          variants = []
          variants << [exe, 'draw', '-q', '-F', 'svg', '-b', 'CropBox', '-o', svg_path.to_s, pdf_path.to_s, page] if use_cropbox
          variants << base
          return variants
        end

        base = [
          exe,
          '-svg',
          '-f', page,
          '-l', page,
          '--',
          pdf_path.to_s,
          svg_path.to_s
        ]
        variants = []
        variants << [exe, '-svg', '-cropbox'] + base[2..-1] if use_cropbox
        variants << base
        variants
      end

      def self.parse_glyph_defs(svg)
        h = {}
        svg.scan(/<g id="(glyph-\d+-\d+)">\s*<path d="([^"]*)"/m) do |id, d|
          h[id] = d unless d.strip.empty?
        end
        svg.scan(/<path\b[^>]*\bid="([^"]+)"[^>]*\bd="([^"]*)"/m) do |id, d|
          next unless glyph_reference_id?(id)
          h[id] = d unless d.strip.empty?
        end
        h
      end

      def self.parse_use_placements(svg)
        a = []
        svg.scan(/<use\b[^>]*>/m) do |m|
          tag = m.is_a?(Array) ? m.first.to_s : m.to_s
          href = tag[/\bxlink:href="([^"]+)"/, 1] || tag[/\bhref="([^"]+)"/, 1]
          next unless href && href.start_with?('#')
          id = href[1..-1]
          next unless glyph_reference_id?(id)

          x = (tag[/\bx="([^"]+)"/, 1] || '0').to_f
          y = (tag[/\by="([^"]+)"/, 1] || '0').to_f

          matrix = nil
          tr = tag[/\btransform="([^"]+)"/, 1]
          if tr && tr =~ /matrix\(([^)]+)\)/i
            vals = $1.split(/[,\s]+/).reject(&:empty?).map(&:to_f)
            matrix = vals[0, 6] if vals.length >= 6
          end

          a << { glyph_id: id, x: x, y: y, matrix: matrix }
        end
        a
      end

      def self.glyph_reference_id?(id)
        s = id.to_s
        s.start_with?('glyph-') || s =~ /\Afont[_-]/
      end

      # ------------------------------------------------------------------
      # Missing-font / collapsed-glyph guard.
      # When pdftocairo cannot resolve a font (e.g. the non-embedded base-14
      # "Symbol" font), it stamps many glyph <use> placements at one identical
      # transform (typically the page-box corner). Rendering those piles
      # hundreds of glyphs on a single point -> an illegible blob. Detect any
      # transform shared by >= MIN_COLLAPSE_REPEAT placements and skip them.
      # ------------------------------------------------------------------
      MIN_COLLAPSE_REPEAT = 12

      def self.placement_signature(p)
        m = p[:matrix]
        if m.is_a?(Array) && m.length >= 6
          a = m[0].to_f; b = m[1].to_f; c = m[2].to_f; d = m[3].to_f
          e = m[4].to_f + p[:x].to_f
          f = m[5].to_f + p[:y].to_f
          "m:#{a.round(3)},#{b.round(3)},#{c.round(3)},#{d.round(3)},#{e.round(2)},#{f.round(2)}"
        else
          "p:#{p[:x].to_f.round(2)},#{p[:y].to_f.round(2)}"
        end
      end

      def self.collapsed_signature_keys(placements, min_repeat = MIN_COLLAPSE_REPEAT)
        counts = Hash.new(0)
        placements.each { |pl| counts[placement_signature(pl)] += 1 }
        keys = []
        counts.each { |k, n| keys << k if n >= min_repeat }
        keys
      end

      def self.missing_display_fonts(stderr)
        return [] unless stderr.is_a?(String) && !stderr.empty?
        stderr.scan(/No display font for '([^']+)'/).map { |mm| mm[0] }.uniq
      end

      # ------------------------------------------------------------------
      # Ghostscript font-embedding fallback.
      # poppler on some platforms cannot substitute non-embedded base-14
      # fonts (notably "Symbol"). When the PDF has non-embedded fonts and
      # Ghostscript is available, embed them once into a temp copy so
      # pdftocairo renders them. Cached per source path+mtime+size.
      # ------------------------------------------------------------------
      def self.ghostscript_embed_args(gs, in_pdf, out_pdf)
        [
          gs.to_s,
          '-dNOSAFER', '-dBATCH', '-dNOPAUSE', '-dQUIET',
          '-sDEVICE=pdfwrite',
          '-dEmbedAllFonts=true',
          '-dSubsetFonts=true',
          '-dCompatibilityLevel=1.7',
          '-o', out_pdf.to_s,
          in_pdf.to_s
        ]
      end

      def self.pdffonts_reports_unembedded?(output)
        return false unless output.is_a?(String)
        output.each_line do |line|
          m = line.match(/\b(yes|no)\s+(yes|no)\s+(yes|no)\s+\d+\s+\d+\s*$/)
          return true if m && m[1] == 'no'
        end
        false
      end

      def self.cache_key(pdf_path)
        st = File.stat(pdf_path)
        "#{pdf_path}|#{st.mtime.to_i}|#{st.size}"
      rescue StandardError
        pdf_path.to_s
      end

      def self.find_pdffonts(pdftocairo_exe)
        DependencyResolver.find_pdffonts(pdftocairo_exe)
      rescue StandardError => e
        warn_safe("find_pdffonts failed: #{e.message}")
        nil
      end

      def self.find_ghostscript
        DependencyResolver.find_ghostscript
      rescue StandardError => e
        warn_safe("find_ghostscript failed: #{e.message}")
        nil
      end

      def self.pdf_needs_embedding?(pdf_path, pdftocairo_exe)
        @font_check_cache ||= {}
        key = cache_key(pdf_path)
        return @font_check_cache[key] if @font_check_cache.key?(key)
        result = false
        begin
          pf = find_pdffonts(pdftocairo_exe)
          if pf
            run = CommandRunner.run([pf.to_s, '--', pdf_path.to_s],
              timeout_s: 30, context: 'SvgTextRenderer.pdffonts')
            result = run[:ok] && pdffonts_reports_unembedded?(run[:stdout].to_s)
          end
        rescue StandardError => e
          warn_safe("pdf_needs_embedding? failed: #{e.message}")
          result = false
        end
        @font_check_cache[key] = result
        result
      end

      def self.embed_fonts_cached(pdf_path, gs)
        @embed_cache ||= {}
        key = cache_key(pdf_path)
        cached = @embed_cache[key]
        return cached if cached && File.exist?(cached)
        out = File.join(Dir.tmpdir,
          "bc_embed_#{Process.pid}_#{Time.now.to_i}_#{rand(100000)}.pdf")
        begin
          run = CommandRunner.run(ghostscript_embed_args(gs, pdf_path, out),
            timeout_s: 180, context: 'SvgTextRenderer.ghostscript')
          if run[:ok] && File.exist?(out) && File.size(out) > 0
            @embed_cache[key] = out
            return out
          end
          File.delete(out) if File.exist?(out)
        rescue StandardError => e
          warn_safe("embed_fonts_cached failed: #{e.message}")
        end
        nil
      end

      def self.ensure_renderable_pdf(pdf_path, pdftocairo_exe)
        return pdf_path unless pdf_needs_embedding?(pdf_path, pdftocairo_exe)
        gs = find_ghostscript
        unless gs
          warn_safe(
            "PDF has non-embedded fonts and Ghostscript was not found; symbols from " \
            "unresolved fonts may be skipped. Install Ghostscript for full fidelity.")
          return pdf_path
        end
        embedded = embed_fonts_cached(pdf_path, gs)
        embedded || pdf_path
      rescue StandardError => e
        warn_safe("ensure_renderable_pdf failed: #{e.message}")
        pdf_path
      end

      def self.parse_viewbox(svg)
        if (m = svg.match(/viewBox="([^"]+)"/i))
          vals = m[1].split(/[\s,]+/).reject(&:empty?).map(&:to_f)
          return vals[0], vals[1], vals[2], vals[3] if vals.length >= 4
        end
        [0.0, 0.0, 0.0, 0.0]
      rescue StandardError => e
        Logger.warn("SvgTextRenderer", "parse_viewbox failed: #{e.message}")
        [0.0, 0.0, 0.0, 0.0]
      end

      # Convert SVG path to arrays of SketchUp Point3d.
      # Glyph coords are in SVG viewBox units, Y-down.
      # Convert to model inches with potentially non-uniform scaling.
      def self.svg_path_to_points(d, scale_or_x_unit_to_in, y_unit_to_in = nil)
        if y_unit_to_in.nil?
          # Backward compatibility: 2-arg call treated as isotropic scale factor.
          x_unit_to_in = PDF_PT_TO_INCH * scale_or_x_unit_to_in.to_f
          y_unit_to_in = x_unit_to_in
        else
          x_unit_to_in = scale_or_x_unit_to_in.to_f
          y_unit_to_in = y_unit_to_in.to_f
        end

        tokens = d.scan(/[MLHVCSZmlhvcsz]|[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?/)
        subpaths = []
        current = []
        start_pt = nil
        cx = 0.0; cy = 0.0
        cmd = nil; nums = []

        mk = lambda { |gx, gy|
          Geom::Point3d.new(gx * x_unit_to_in, -gy * y_unit_to_in, 0.0)
        }

        run = lambda {
          case cmd
          when 'M'
            while nums.length >= 2
              subpaths << current if current.length >= 2
              cx, cy = nums.shift(2)
              start_pt = mk.call(cx, cy)
              current = [start_pt]
            end
          when 'L'
            while nums.length >= 2
              cx, cy = nums.shift(2)
              current << mk.call(cx, cy)
            end
          when 'H'
            while nums.length >= 1
              cx = nums.shift
              current << mk.call(cx, cy)
            end
          when 'V'
            while nums.length >= 1
              cy = nums.shift
              current << mk.call(cx, cy)
            end
          when 'C'
            while nums.length >= 6
              x1, y1, x2, y2, x, y = nums.shift(6)
              p0 = current.last || mk.call(cx, cy)
              p1 = mk.call(x1, y1); p2 = mk.call(x2, y2); p3 = mk.call(x, y)
              ch = p0.distance(p3)
              n = ch < 0.02 ? 2 : (ch < 0.08 ? 3 : 4)
              (1..n).each do |i|
                t = i.to_f / n; mt = 1.0 - t
                bx = mt**3*p0.x + 3*mt**2*t*p1.x + 3*mt*t**2*p2.x + t**3*p3.x
                by = mt**3*p0.y + 3*mt**2*t*p1.y + 3*mt*t**2*p2.y + t**3*p3.y
                current << Geom::Point3d.new(bx, by, 0.0)
              end
              cx, cy = x, y
            end
          when 'S'
            while nums.length >= 4
              _, _, x, y = nums.shift(4)
              cx, cy = x, y
              current << mk.call(cx, cy)
            end
          when '_RM'  # relative moveto
            while nums.length >= 2
              subpaths << current if current.length >= 2
              cx += nums.shift; cy += nums.shift
              start_pt = mk.call(cx, cy)
              current = [start_pt]
            end
          when '_RL'  # relative lineto
            while nums.length >= 2
              cx += nums.shift; cy += nums.shift
              current << mk.call(cx, cy)
            end
          when '_RH'  # relative horizontal lineto
            while nums.length >= 1
              cx += nums.shift
              current << mk.call(cx, cy)
            end
          when '_RV'  # relative vertical lineto
            while nums.length >= 1
              cy += nums.shift
              current << mk.call(cx, cy)
            end
          when '_RC'  # relative curveto
            while nums.length >= 6
              dx1, dy1, dx2, dy2, dx, dy = nums.shift(6)
              x1 = cx + dx1; y1 = cy + dy1
              x2 = cx + dx2; y2 = cy + dy2
              x = cx + dx;   y = cy + dy
              p0 = current.last || mk.call(cx, cy)
              p1 = mk.call(x1, y1); p2 = mk.call(x2, y2); p3 = mk.call(x, y)
              ch = p0.distance(p3)
              n = ch < 0.02 ? 2 : (ch < 0.08 ? 3 : 4)
              (1..n).each do |i|
                t = i.to_f / n; mt = 1.0 - t
                bx = mt**3*p0.x + 3*mt**2*t*p1.x + 3*mt*t**2*p2.x + t**3*p3.x
                by = mt**3*p0.y + 3*mt**2*t*p1.y + 3*mt*t**2*p2.y + t**3*p3.y
                current << Geom::Point3d.new(bx, by, 0.0)
              end
              cx, cy = x, y
            end
          when '_RS'  # relative smooth curveto
            while nums.length >= 4
              _, _, dx, dy = nums.shift(4)
              cx += dx; cy += dy
              current << mk.call(cx, cy)
            end
          when 'Z'
            if current.last && start_pt && current.last.distance(start_pt) >= 0.0003
              current << start_pt
            end
            subpaths << current if current.length >= 2
            current = start_pt ? [start_pt] : []
          end
        }

        tokens.each do |tok|
          if tok =~ /\A[A-Za-z]\z/
            run.call if cmd
            is_relative = (tok =~ /[a-z]/) ? true : false
            cmd = tok.upcase
            # For relative commands, convert coordinates to absolute before processing
            if is_relative && cmd == 'M'
              cmd = '_RM'  # relative move marker
            elsif is_relative && cmd == 'L'
              cmd = '_RL'
            elsif is_relative && cmd == 'H'
              cmd = '_RH'
            elsif is_relative && cmd == 'V'
              cmd = '_RV'
            elsif is_relative && cmd == 'C'
              cmd = '_RC'
            elsif is_relative && cmd == 'S'
              cmd = '_RS'
            end
            # Z/z behave identically
            nums = []
          else
            nums << tok.to_f
          end
        end
        run.call if cmd
        subpaths << current if current.length >= 2

        subpaths.map { |pts|
          cl = [pts.first]
          pts[1..-1].each { |p| cl << p if p.distance(cl.last) >= 0.0003 }
          cl.length >= 2 ? cl : nil
        }.compact
      end

    end
  end
end
