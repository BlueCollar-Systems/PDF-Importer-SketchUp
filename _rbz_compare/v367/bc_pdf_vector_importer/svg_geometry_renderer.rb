# bc_pdf_vector_importer/svg_geometry_renderer.rb
# Full geometry import via pdftocairo SVG output.
#
# Uses Cairo's rendering engine for all geometry AND text —
# exact same output as the PDF viewer. Handles Form XObjects,
# line weights, dash patterns, fills, and text positioning
# that the pure Ruby parser may miss or approximate.
#
# Falls back to the Ruby parser if pdftocairo is unavailable.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'tmpdir'
require File.join(File.dirname(__FILE__), 'command_runner')

module BlueCollarSystems
  module PDFVectorImporter
    module SvgGeometryRenderer

      PDF_PT_TO_INCH = 1.0 / 72.0

      # ---------------------------------------------------------------
      # Main entry. Returns stats hash or nil if pdftocairo unavailable.
      # ---------------------------------------------------------------
      def self.render(model, pdf_path, page_num, media_box, opts = {})
        exe = SvgTextRenderer.find_pdftocairo
        return nil unless exe

        scale = opts[:scale] || 1.0
        import_text = opts[:import_text] != false
        create_faces = opts[:create_faces] != false
        layer_name = opts[:layer_name] || 'PDF Import'
        @bezier_segments = opts[:bezier_segments] || 16
        @cleanup_geometry = opts[:cleanup_geometry] || false
        @merge_tolerance = opts[:merge_tolerance] || 0.001
        render_box = opts[:svg_page_box] || media_box
        media_min_x = media_box[0].to_f
        media_min_y = media_box[1].to_f
        render_min_x = render_box[0].to_f
        render_min_y = render_box[1].to_f
        box_offset_x_in = (render_min_x - media_min_x) * PDF_PT_TO_INCH * scale.to_f
        box_offset_y_in = (render_min_y - media_min_y) * PDF_PT_TO_INCH * scale.to_f
        vb_w = (render_box[2] - render_box[0]).abs.to_f
        vb_h = (render_box[3] - render_box[1]).abs.to_f
        vb_w = 2592.0 if vb_w < 1
        vb_h = 1728.0 if vb_h < 1

        # Generate SVG
        svg_path = File.join(Dir.tmpdir,
          "bc_geo_#{Process.pid}_#{Time.now.to_i}_#{rand(100000)}.svg")
        use_cropbox = false
        begin
          if media_box.is_a?(Array) && media_box.length >= 4 &&
             render_box.is_a?(Array) && render_box.length >= 4
            use_cropbox = render_box.zip(media_box).any? { |a, b| (a.to_f - b.to_f).abs > 0.01 }
          end
        rescue StandardError => e
          Logger.warn("SvgGeometryRenderer", "cropbox compare failed: #{e.message}")
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
            timeout_s: 120,
            context: 'SvgGeometryRenderer.pdftocairo'
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
          Logger.warn("SvgGeometryRenderer",
            "Page #{page_num}: pdftocairo -cropbox unavailable; used media box SVG fallback")
        end

        svg = File.read(svg_path, encoding: 'UTF-8')

        # Parse SVG dimensions
        svg_vb_w = (svg[/width="([^"]+)"/, 1] || vb_w).to_f
        svg_vb_h = (svg[/height="([^"]+)"/, 1] || vb_h).to_f

        # Split into defs and body
        defs_split = svg.split('</defs>')
        defs_section = defs_split[0] || ''
        body_section = defs_split[1] || svg

        # Parse body paths and compute scale factor
        body_paths = parse_body_paths(body_section)
        return nil if body_paths.empty?

        # Compute Cairo internal scale from max path coordinates
        max_x = 0.0; max_y = 0.0
        body_paths.each do |bp|
          bp[:points].each do |pt|
            max_x = pt[0] if pt[0] > max_x
            max_y = pt[1] if pt[1] > max_y
          end
        end

        # Dynamic scale: body coords → viewBox coords
        geo_scale_x = max_x > 0 ? svg_vb_w / max_x : 1.0
        geo_scale_y = max_y > 0 ? svg_vb_h / max_y : 1.0

        stats = { edges: 0, faces: 0, text: 0, glyphs: 0 }

        # Create page group
        page_group = model.active_entities.add_group
        page_group.name = "PDF_Page_#{page_num}"
        entities = page_group.entities

        # Create layers/tags
        base_layer = model.layers[layer_name] || model.layers.add(layer_name)
        dash_layer = model.layers["Dashed"] || model.layers.add("Dashed")
        dashdot_layer = model.layers["Dashdot"] || model.layers.add("Dashdot")

        Sketchup.status_text = "Drawing #{body_paths.length} geometry paths..."

        # Draw geometry paths
        body_paths.each_with_index do |bp, idx|
          if idx % 500 == 0
            Sketchup.status_text = "Drawing geometry: #{idx}/#{body_paths.length} [#{((idx.to_f/body_paths.length)*100).round}%]"
          end

          pts = bp[:points].map do |px, py|
            # Convert: body coords → viewBox coords → SketchUp inches
            pdf_x = (px * geo_scale_x) - render_min_x
            pdf_y = (svg_vb_h - py * geo_scale_y) - render_min_y
            Geom::Point3d.new(
              (pdf_x * PDF_PT_TO_INCH * scale) + box_offset_x_in,
              (pdf_y * PDF_PT_TO_INCH * scale) + box_offset_y_in,
              0.0
            )
          end

          # Remove duplicate consecutive points
          clean = [pts.first]
          pts[1..-1].each { |p| clean << p if p.distance(clean.last) >= 0.001 }
          next if clean.length < 2

          # Choose layer based on line type
          target_layer = base_layer
          if bp[:dash]
            if bp[:dash].include?(' ')
              parts = bp[:dash].split(' ').map(&:to_f)
              target_layer = parts.length > 2 ? dashdot_layer : dash_layer
            end
          end

          begin
            edges = entities.add_edges(clean)
            if edges
              stats[:edges] += edges.length
              edges.each do |edge|
                begin
                  edge.layer = target_layer if target_layer
                rescue StandardError => e
                  Logger.warn("SvgGeometryRenderer", "edge layer assignment failed: #{e.message}")
                end
              end
            end

            # Create face from closed filled paths
            if create_faces && bp[:filled] && clean.length >= 3 &&
               clean.first.distance(clean.last) < 0.01
              begin
                face = entities.add_face(clean)
                if face
                  stats[:faces] += 1
                  begin
                    face.layer = base_layer if base_layer
                  rescue StandardError => e
                    Logger.warn("SvgGeometryRenderer", "face layer assignment failed: #{e.message}")
                  end
                end
              rescue StandardError => e
                Logger.warn("SvgGeometryRenderer", "add_face failed: #{e.message}")
              end
            end
          rescue StandardError => e
            Logger.warn("SvgGeometryRenderer", "draw geometry path failed: #{e.message}")
          end
        end

        # Draw text via SvgTextRenderer (reuse existing glyph component approach)
        if import_text
          Sketchup.status_text = "Rendering text glyphs..."
          glyphs = SvgTextRenderer.send(:parse_glyph_defs, svg)
          placements = SvgTextRenderer.send(:parse_use_placements, svg)

          # Build glyph components
          glyph_defs = {}
          glyphs.each do |glyph_id, path_d|
            next if path_d.strip.empty?
            subpaths = SvgTextRenderer.send(:svg_path_to_points, path_d, scale)
            next if subpaths.empty?
            defn = model.definitions.add("_g_#{glyph_id}")
            subpaths.each do |sp|
              next if sp.length < 2
              begin
                r = defn.entities.add_edges(sp)
                stats[:edges] += r.length if r
              rescue StandardError => e
                Logger.warn("SvgGeometryRenderer", "add_edges for glyph failed: #{e.message}")
              end
            end
            glyph_defs[glyph_id] = defn if defn.entities.count > 0
          end

          # Place instances
          text_layer = model.layers["#{layer_name}:Text"] ||
                       model.layers.add("#{layer_name}:Text")
          placements.each_with_index do |p, idx|
            if idx % 500 == 0
              Sketchup.status_text = "Placing text: #{idx}/#{placements.length}"
            end
            defn = glyph_defs[p[:glyph_id]]
            next unless defn
            # Glyph positions are in viewBox coords (no scaling needed)
            pdf_x = p[:x] - render_min_x
            pdf_y = (svg_vb_h - p[:y]) - render_min_y
            x_inch = (pdf_x * PDF_PT_TO_INCH * scale) + box_offset_x_in
            y_inch = (pdf_y * PDF_PT_TO_INCH * scale) + box_offset_y_in
            begin
              inst = entities.add_instance(defn,
                Geom::Transformation.new(Geom::Point3d.new(x_inch, y_inch, 0.0)))
              begin
                inst.layer = text_layer if text_layer
              rescue StandardError => e
                Logger.warn("SvgGeometryRenderer", "glyph layer assignment failed: #{e.message}")
              end
              stats[:glyphs] += 1
            rescue StandardError => e
              Logger.warn("SvgGeometryRenderer", "add_instance for glyph failed: #{e.message}")
            end
          end
          stats[:text] = stats[:glyphs]
        end

        # ── Auto-clean geometry if enabled ──
        if @cleanup_geometry && page_group
          Sketchup.status_text = "Cleaning up SVG geometry..."
          cl = GeometryCleanup.cleanup(page_group.entities,
            merge_tolerance: @merge_tolerance,
            min_edge_length: @merge_tolerance)
          stats[:cleanup] = cl
        end

        begin
          page_group.layer = base_layer if page_group && base_layer
        rescue StandardError => e
          Logger.warn("SvgGeometryRenderer", "page group layer assignment failed: #{e.message}")
        end

        stats
      rescue StandardError => e
        begin
          Logger.warn("SvgGeometryRenderer", "Failed: #{e.message}")
        rescue StandardError
          # Logger may be unavailable in minimal runtime/test contexts.
        end
        nil
      ensure
        begin
          File.delete(svg_path) if svg_path && File.exist?(svg_path)
        rescue StandardError => e
          Logger.warn("SvgGeometryRenderer", "cleanup temp svg failed: #{e.message}")
        end
      end

      private

      # ---------------------------------------------------------------
      # Parse <path> elements from SVG body into point arrays.
      # Returns [{ points: [[x,y], ...], filled: bool, dash: str|nil }, ...]
      # ---------------------------------------------------------------
      def self.parse_body_paths(body)
        results = []

        body.scan(/<path\s+([^>]*)\/>/m) do |attrs_str,|
          attrs = attrs_str.to_s

          # Get path data
          d = attrs[/d="([^"]*)"/, 1]
          next unless d && !d.strip.empty?

          # Determine if this is filled or stroked
          is_filled = attrs.include?('fill=') && !attrs.include?('fill="none"')
          is_stroked = attrs.include?('stroke=') && !attrs.include?('stroke="none"')

          # Get dash pattern if any
          dash = attrs[/stroke-dasharray="([^"]*)"/, 1]

          # Parse path into points (use configured curve smoothness)
          points = path_to_points(d, bezier_segments: @bezier_segments)
          next if points.length < 2

          results << {
            points: points,
            filled: is_filled && !is_stroked,
            stroked: is_stroked,
            dash: dash
          }
        end

        results
      end

      # ---------------------------------------------------------------
      # Parse SVG path d="" into flat array of [x,y] points.
      # Handles M, L, H, V, C, S, Z (absolute only — Cairo uses absolute).
      # ---------------------------------------------------------------
      def self.path_to_points(d, bezier_segments: nil)
        seg_count = bezier_segments || @bezier_segments || 16
        tokens = d.scan(/[MLHVCSZmlhvcsz]|[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?/)
        points = []
        cx = 0.0; cy = 0.0
        start_x = 0.0; start_y = 0.0
        cmd = nil; nums = []

        flush = lambda do
          case cmd
          when 'M'
            while nums.length >= 2
              cx, cy = nums.shift(2)
              start_x, start_y = cx, cy
              points << [cx, cy]
            end
          when 'L'
            while nums.length >= 2
              cx, cy = nums.shift(2)
              points << [cx, cy]
            end
          when 'H'
            while nums.length >= 1
              cx = nums.shift
              points << [cx, cy]
            end
          when 'V'
            while nums.length >= 1
              cy = nums.shift
              points << [cx, cy]
            end
          when 'C'
            while nums.length >= 6
              x1, y1, x2, y2, x, y = nums.shift(6)
              # Subdivide cubic bezier using configurable segment count
              p0x, p0y = cx, cy
              chord = Math.sqrt((x-p0x)**2 + (y-p0y)**2)
              # Scale steps proportionally: short chords use fewer segments,
              # long chords use more, up to the configured bezier_segments cap.
              steps = if chord < 5
                        [2, seg_count / 4].max
                      elsif chord < 20
                        [3, seg_count / 3].max
                      else
                        [5, seg_count / 2].max
                      end
              steps = [steps, seg_count].min
              (1..steps).each do |i|
                t = i.to_f / steps; mt = 1.0 - t
                bx = mt**3*p0x + 3*mt**2*t*x1 + 3*mt*t**2*x2 + t**3*x
                by = mt**3*p0y + 3*mt**2*t*y1 + 3*mt*t**2*y2 + t**3*y
                points << [bx, by]
              end
              cx, cy = x, y
            end
          when 'S'
            while nums.length >= 4
              _, _, x, y = nums.shift(4)
              cx, cy = x, y
              points << [cx, cy]
            end
          when 'Z', 'z'
            if (cx - start_x).abs > 0.1 || (cy - start_y).abs > 0.1
              points << [start_x, start_y]
            end
            cx, cy = start_x, start_y
          end
        end

        tokens.each do |tok|
          if tok =~ /\A[A-Za-z]\z/
            flush.call if cmd
            cmd = tok.upcase
            nums = []
          else
            nums << tok.to_f
          end
        end
        flush.call if cmd

        points
      end

    end
  end
end
