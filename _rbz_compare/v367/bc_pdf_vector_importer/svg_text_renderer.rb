# bc_pdf_vector_importer/svg_text_renderer.rb
# Renders PDF text as precise vector geometry using pdftocairo.
#
# Performance: each unique glyph is drawn ONCE as a Component, then
# placed as lightweight instances. ~500 draws + ~3000 placements
# instead of ~3000 individual draws.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'tmpdir'
require File.join(File.dirname(__FILE__), 'command_runner')

module BlueCollarSystems
  module PDFVectorImporter
    module SvgTextRenderer

      PDF_PT_TO_INCH = 1.0 / 72.0

      def self.render(entities, pdf_path, page_num, media_box, opts = {})
        exe = find_pdftocairo
        return nil unless exe

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

        svg_path = File.join(Dir.tmpdir,
          "bc_svg_#{Process.pid}_#{Time.now.to_i}_#{rand(100000)}.svg")

        use_cropbox = false
        begin
          if media_box.is_a?(Array) && media_box.length >= 4 &&
             svg_page_box.is_a?(Array) && svg_page_box.length >= 4
            use_cropbox = svg_page_box.zip(media_box).any? { |a, b| (a.to_f - b.to_f).abs > 0.01 }
          end
        rescue StandardError => e
          Logger.warn("SvgTextRenderer", "cropbox compare failed: #{e.message}")
        end

        base_args = [
          exe.to_s,
          '-svg',
          '-f', page_num.to_i.to_s,
          '-l', page_num.to_i.to_s,
          '--',
          pdf_path.to_s,
          svg_path.to_s
        ]
        arg_variants = []
        arg_variants << [exe.to_s, '-svg', '-cropbox'] + base_args[2..-1] if use_cropbox
        arg_variants << base_args

        used_cropbox_fallback = false
        render_ok = false
        arg_variants.each_with_index do |args, idx|
          begin
            File.delete(svg_path) if File.exist?(svg_path)
          rescue StandardError
            # best-effort cleanup
          end

          run = CommandRunner.run(
            args,
            timeout_s: 90,
            context: 'SvgTextRenderer.pdftocairo'
          )
          if run[:ok] && File.exist?(svg_path)
            used_cropbox_fallback = (idx == 1 && use_cropbox)
            render_ok = true
            break
          end
          break if run[:timed_out]
        end
        return nil unless render_ok
        if used_cropbox_fallback
          Logger.warn("SvgTextRenderer",
            "Page #{page_num}: pdftocairo -cropbox unavailable; used media box SVG fallback")
        end

        svg = File.read(svg_path, encoding: 'UTF-8')
        glyphs = parse_glyph_defs(svg)
        placements = parse_use_placements(svg)
        return { edges: 0, glyphs: 0 } if placements.empty?

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

        model = entities.model || Sketchup.active_model
        edge_count = 0
        glyph_count = 0

        # Build each unique glyph as a Component (draw once)
        Sketchup.status_text = "Building #{glyphs.length} glyph shapes..."
        glyph_defs = {}
        glyphs.each do |glyph_id, path_d|
          next if path_d.strip.empty?
          subpaths = svg_path_to_points(path_d, x_unit_to_in, y_unit_to_in)
          next if subpaths.empty?

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

        # Place instances (fast)
        total = placements.length
        placements.each_with_index do |p, idx|
          if idx % 500 == 0
            Sketchup.status_text = "Placing text: #{idx}/#{total} [#{((idx.to_f/total)*100).round}%]"
          end

          defn = glyph_defs[p[:glyph_id]]
          next unless defn

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

            inst = entities.add_instance(defn, tr)
            begin
              inst.layer = text_layer if inst && text_layer
            rescue StandardError => e
              Logger.warn("SvgTextRenderer", "set_layer on glyph instance failed: #{e.message}")
            end
            glyph_count += 1
          rescue StandardError => e
            Logger.warn("SvgTextRenderer", "add_instance for glyph failed: #{e.message}")
          end
        end

        { edges: edge_count, glyphs: glyph_count }
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

      def self.find_pdftocairo
        env = ENV['BC_PDFTOCAIRO_PATH']
        return env if env && !env.empty? && File.exist?(env)

        begin
          # Common local/system installs
          candidates = []
          if ENV['LOCALAPPDATA'] && !ENV['LOCALAPPDATA'].empty?
            candidates << File.join(ENV['LOCALAPPDATA'],
              'Programs', 'MiKTeX', 'miktex', 'bin', 'x64', 'pdftocairo.exe')
          end
          candidates << 'C:\\Program Files\\MiKTeX\\miktex\\bin\\x64\\pdftocairo.exe'
          # FreeCAD bundles poppler utils in many installs.
          candidates << 'C:\\Program Files\\FreeCAD 1.1\\bin\\pdftocairo.exe'
          Dir.glob('C:/Program Files/FreeCAD*/bin/pdftocairo.exe').each { |p| candidates << p }
          candidates.each { |p| return p if File.exist?(p) }
        rescue StandardError => e
          Logger.warn("SvgTextRenderer", "find_pdftocairo path search failed: #{e.message}")
        end

        if (RUBY_PLATFORM =~ /mswin|mingw|cygwin/)
          ['C:/poppler*/bin/pdftocairo.exe',
           'C:/tools/poppler*/bin/pdftocairo.exe'
          ].each do |pat|
            Dir.glob(pat).each { |p| return p if File.exist?(p) }
          end
        end

        begin
          if (RUBY_PLATFORM =~ /mswin|mingw|cygwin/)
            r = `where pdftocairo.exe 2>NUL`.strip
          else
            r = `which pdftocairo 2>/dev/null`.strip
          end
          return r.split("\n").first.strip if !r.empty?
        rescue StandardError => e
          Logger.warn("SvgTextRenderer", "find_pdftocairo which/where failed: #{e.message}")
        end
        nil
      end

      def self.parse_glyph_defs(svg)
        h = {}
        svg.scan(/<g id="(glyph-\d+-\d+)">\s*<path d="([^"]*)"/m) do |id, d|
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
          next unless id.start_with?('glyph-')

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
