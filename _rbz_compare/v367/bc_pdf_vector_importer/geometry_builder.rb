# bc_pdf_vector_importer/geometry_builder.rb
# Converts parsed PDF vector paths into native SketchUp geometry.
# v2: Arc reconstruction, color-based tag grouping, dash pattern mapping,
# line width tracking, text placement, and progress feedback.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    class GeometryBuilder

      PDF_POINT_TO_INCH = 1.0 / 72.0
      CLOSE_TOL = 1e-6

      attr_reader :page_group

      def initialize(model, paths, text_items, media_box, opts = {})
        @model = model
        @paths = paths
        @text_items = text_items || []
        @media_box = media_box

        @scale           = opts[:scale_factor] || 1.0
        @bezier_segments = opts[:bezier_segments] || 16
        @import_as       = opts[:import_as] || :edges
        @layer_name      = opts[:layer_name] || 'PDF Import'
        @group_per_page  = opts[:group_per_page] != false
        @page_number     = opts[:page_number] || 1
        @flatten         = opts[:flatten_to_2d] != false
        @merge_tol       = opts[:merge_tolerance] || 0.001
        @import_fills    = opts[:import_fills] != false
        @group_by_color  = opts[:group_by_color] || false
        @detect_arcs     = opts[:detect_arcs] != false
        @map_dashes      = opts[:map_dashes] || false
        @import_text     = opts[:import_text] || false
        @use_3d_text     = opts[:use_3d_text] || false
        @strict_text_fidelity = opts[:strict_text_fidelity] || false
        @target_entities = opts[:target_entities] || nil
        @y_offset        = opts[:y_offset] || 0.0

        @edge_count = 0
        @face_count = 0
        @arc_count  = 0
        @text_count = 0
      end

      def build
        base_layer = get_or_create_layer(@layer_name)
        entities = @target_entities || @model.active_entities

        # Create page group
        if @group_per_page
          @page_group = entities.add_group
          @page_group.name = "PDF Page #{@page_number}"
          set_layer(@page_group, base_layer)
          target = @page_group.entities
        else
          @page_group = nil
          target = entities
        end

        page_height = @media_box[3] - @media_box[1]
        page_origin_x = @media_box[0]
        page_origin_y = @media_box[1]

        # Color group cache
        @color_groups = {}

        page_width  = (@media_box[2] - @media_box[0]).abs
        page_height_pts = (@media_box[3] - @media_box[1]).abs
        page_area_pts = page_width * page_height_pts

        # ── Vector geometry ──
        @paths.each do |path|
          next unless path.subpaths && !path.subpaths.empty?

          should_stroke = path.stroke
          should_fill = path.fill && @import_fills
          next unless should_stroke || should_fill

          # ── Skip paths whose bounding box exceeds the page ──
          # These are typically decorative backgrounds, clip-fill regions, or
          # graphic elements that extend far beyond the visible page area.
          # They produce huge arcs/circles that clutter the import.
          path_bbox = compute_path_bbox(path)
          if path_bbox
            pw = (path_bbox[2] - path_bbox[0]).abs
            ph = (path_bbox[3] - path_bbox[1]).abs
            if pw * ph > page_area_pts * 0.95
              next
            end
          end

          # Determine target group based on color
          color_rgb = path.stroke_color || [0, 0, 0]
          dest = get_color_group(target, color_rgb)

          # Determine the layer for this path — OCG layer takes priority
          path_layer = base_layer
          if path.layer_name && !path.layer_name.empty?
            ocg_layer_name = "PDF::Layer::#{path.layer_name}"
            path_layer = get_or_create_layer(ocg_layer_name)
          end

          # Determine dash rendering info
          dash_spec = nil
          dash_layer = nil
          if @map_dashes && path.dash_pattern
            dash_spec = normalize_dash_pattern(path.dash_pattern, path.ctm)
            dash_layer = classify_dash(path.dash_pattern)
          end

          path.subpaths.each do |subpath|
            points_list = subpath_to_points(subpath)
            next if points_list.empty?

            # Convert PDF → SketchUp coordinates
            su_points = points_list.map do |pt|
              pdf_to_su(pt[0], pt[1], page_origin_x, page_origin_y)
            end

            su_points = remove_consecutive_duplicates(su_points)
            next if su_points.length < 2

            # Arc reconstruction on the polyline
            if @detect_arcs && dash_spec.nil? && su_points.length >= 5
              draw_with_arc_detection(dest, su_points, path_layer, dash_layer, dash_spec, subpath.closed, should_fill, path.fill_color)
            else
              draw_edges(dest, su_points, path_layer, dash_layer, dash_spec, subpath.closed)
              if should_fill && subpath.closed && su_points.length >= 3
                draw_face(dest, su_points, path_layer, path.fill_color)
              end
            end
          end
        end

        # ── Text objects ──
        if @import_text && !@text_items.empty?
          text_layer = get_or_create_layer("#{@layer_name}:Text")
          text_group = nil
          if @page_group
            text_group = @page_group.entities.add_group
            text_group.name = "Text"
            set_layer(text_group, text_layer)
          end
          text_target = text_group ? text_group.entities : target

          @text_items.each do |item|
            place_text(text_target, item, page_origin_x, page_origin_y, page_height, text_layer)
          end
        end

        {
          edges: @edge_count,
          faces: @face_count,
          arcs: @arc_count,
          text_objects: @text_count
        }
      end

      private

      # ---------------------------------------------------------------
      # Coordinate conversion
      # ---------------------------------------------------------------
      def pdf_to_su(pdf_x, pdf_y, origin_x, origin_y)
        x_inch = (pdf_x - origin_x) * PDF_POINT_TO_INCH * @scale
        y_inch = (pdf_y - origin_y) * PDF_POINT_TO_INCH * @scale + @y_offset
        z_inch = 0.0
        Geom::Point3d.new(x_inch, y_inch, z_inch)
      end

      # ---------------------------------------------------------------
      # Subpath to flat point list
      # ---------------------------------------------------------------
      def subpath_to_points(subpath)
        points = []
        subpath.segments.each do |seg|
          case seg.type
          when :move
            points << seg.points[0]
          when :line
            points << seg.points[1]
          when :curve
            p0, p1, p2, p3 = seg.points
            # Try arc detection on individual Bézier curves
            if @detect_arcs
              arc = ArcFitter.bezier_to_arc(p0, p1, p2, p3, arc_fit_tol: 0.08)
              if arc
                # For arc, just add start and end — the arc fitter will handle it
                # at the polyline level. Add intermediate samples for fallback.
              end
            end
            # Linearize the Bézier
            curve_pts = Bezier.cubic_to_points(
              p0, p1, p2, p3,
              max_segments: @bezier_segments,
              tolerance: 0.25
            )
            curve_pts[1..-1].each { |pt| points << pt }
          when :rect
            seg.points.each { |pt| points << pt }
          end
        end
        points
      end

      # ---------------------------------------------------------------
      # Draw edges with arc detection
      # ---------------------------------------------------------------
      def draw_with_arc_detection(entities, points, layer, dash_layer, dash_spec, closed, should_fill, fill_rgb = nil)
        # Convert Point3d to [x,y] for the arc fitter
        pts_2d = points.map { |p| [p.x, p.y] }

        segments = ArcFitter.detect_arcs_in_polyline(pts_2d,
          arc_fit_tol: 0.002 * @scale,  # Scale tolerance with import scale
          # Require at least 4 line segments (5 points) before promoting to arc.
          # 3-segment runs are commonly orthogonal corners that circle-fit badly.
          min_arc_segments: 4,
          max_arc_segments: 64
        )

        if segments.empty?
          draw_edges(entities, points, layer, dash_layer, dash_spec, closed)
          if should_fill && closed && points.length >= 3
            draw_face(entities, points, layer, fill_rgb)
          end
          return
        end

        all_edges = []
        segments.each do |seg|
          if seg[:type] == :arc
            # Draw a true SketchUp arc using 3-point arc
            sp = Geom::Point3d.new(seg[:start_pt][0], seg[:start_pt][1], 0)
            mp = Geom::Point3d.new(seg[:mid_pt][0], seg[:mid_pt][1], 0)
            ep = Geom::Point3d.new(seg[:end_pt][0], seg[:end_pt][1], 0)

            begin
              # Use add_arc with center, normal, xaxis, radius, start_angle, end_angle
              cx, cy = seg[:center][0], seg[:center][1]
              center = Geom::Point3d.new(cx, cy, 0)
              radius = seg[:radius]
              normal = Geom::Vector3d.new(0, 0, 1)

              # Calculate angles
              start_angle = Math.atan2(sp.y - cy, sp.x - cx)
              end_angle = Math.atan2(ep.y - cy, ep.x - cx)
              mid_angle = Math.atan2(mp.y - cy, mp.x - cx)

              # Always use the minor arc between endpoints. If the midpoint
              # does not align with that sweep, this is not a valid arc run.
              sweep = normalize_angle(end_angle - start_angle)
              if sweep.abs < 1e-4
                # Degenerate sweep — render as original polyline
                seg[:points].each_cons(2) do |pa, pb|
                  p1 = Geom::Point3d.new(pa[0], pa[1], 0)
                  p2 = Geom::Point3d.new(pb[0], pb[1], 0)
                  e = safe_add_line(entities, p1, p2, layer, dash_layer, dash_spec)
                  all_edges << e if e
                end
                next
              end

              # Midpoint consistency check:
              # if midpoint is far from the expected minor sweep centerline,
              # do NOT flip to a major arc (which creates huge circles).
              test_mid = normalize_angle(start_angle + sweep / 2.0)
              mid_diff = normalize_angle(mid_angle - test_mid).abs
              if mid_diff > Math::PI / 2
                seg[:points].each_cons(2) do |pa, pb|
                  p1 = Geom::Point3d.new(pa[0], pa[1], 0)
                  p2 = Geom::Point3d.new(pb[0], pb[1], 0)
                  e = safe_add_line(entities, p1, p2, layer, dash_layer, dash_spec)
                  all_edges << e if e
                end
                next
              end

              xaxis = Geom::Vector3d.new(Math.cos(start_angle), Math.sin(start_angle), 0)
              num_segs = [12, (sweep.abs * 180 / Math::PI / 10).ceil].max
              num_segs = [num_segs, 72].min

              edges = entities.add_arc(center, xaxis, normal, radius, 0, sweep, num_segs)
              if edges && !edges.empty?
                edges.each do |e|
                  set_layer(e, layer)
                  set_layer(e, get_or_create_layer(dash_layer)) if dash_layer
                  all_edges << e
                end
                @arc_count += 1
                @edge_count += edges.length
              else
                # Fallback to line
                e = safe_add_line(entities, sp, ep, layer, dash_layer, dash_spec)
                all_edges << e if e
              end
            rescue StandardError => ex
              Logger.warn("GeometryBuilder", "arc creation failed: #{ex.message}")
              # Arc creation failed — fall back to lines through the points
              seg[:points].each_cons(2) do |pa, pb|
                p1 = Geom::Point3d.new(pa[0], pa[1], 0)
                p2 = Geom::Point3d.new(pb[0], pb[1], 0)
                e = safe_add_line(entities, p1, p2, layer, dash_layer, dash_spec)
                all_edges << e if e
              end
            end

          elsif seg[:type] == :line
            p1 = Geom::Point3d.new(seg[:from][0], seg[:from][1], 0)
            p2 = Geom::Point3d.new(seg[:to][0], seg[:to][1], 0)
            e = safe_add_line(entities, p1, p2, layer, dash_layer, dash_spec)
            all_edges << e if e
          end
        end

        # Close path if needed
        if closed && all_edges.length >= 2
          first_pt = points.first
          last_pt = points.last
          if first_pt.distance(last_pt) > @merge_tol
            e = safe_add_line(entities, last_pt, first_pt, layer, dash_layer, dash_spec)
            all_edges << e if e
          end
        end

        # Create face from closed paths
        if should_fill && closed && all_edges.length >= 3
          draw_face(entities, points, layer, fill_rgb)
        end
      end

      # ---------------------------------------------------------------
      # Draw simple edges (no arc detection)
      # ---------------------------------------------------------------
      def draw_edges(entities, points, layer, dash_layer, dash_spec, closed)
        # Filter out zero-length segments, then batch-add for performance.
        valid_pts = [points.first]
        (1...points.length).each do |i|
          valid_pts << points[i] if points[i].distance(valid_pts.last) >= @merge_tol
        end
        if closed && valid_pts.length >= 3 && valid_pts.first.distance(valid_pts.last) >= @merge_tol
          valid_pts << valid_pts.first
        end

        return if valid_pts.length < 2

        # When a dash pattern is present and the SketchUp version lacks the
        # line_styles API (SU 2017/2018), we must draw each segment through
        # safe_add_line → add_dashed_line to physically create the gaps.
        # The batch add_edges path would ignore dash_spec entirely.
        needs_physical_dashes = dash_spec &&
          dash_spec[:pattern].is_a?(Array) && !dash_spec[:pattern].empty? &&
          !(@model.respond_to?(:line_styles) && @model.line_styles)

        if needs_physical_dashes
          (0...valid_pts.length - 1).each do |i|
            safe_add_line(entities, valid_pts[i], valid_pts[i + 1], layer, dash_layer, dash_spec)
          end
          return
        end

        target = dash_layer ? get_or_create_layer(dash_layer) : layer

        begin
          edges = entities.add_edges(valid_pts)
          if edges && !edges.empty?
            edges.each { |e| set_layer(e, target) }
            @edge_count += edges.length
          end
        rescue StandardError => e
          # Fallback to individual lines if batch fails
          Logger.warn("GeometryBuilder", "add_edges batch failed, falling back: #{e.message}")
          (0...valid_pts.length - 1).each do |i|
            safe_add_line(entities, valid_pts[i], valid_pts[i + 1], layer, dash_layer, dash_spec)
          end
        end
      end

      def safe_add_line(entities, p1, p2, layer, dash_layer, dash_spec = nil)
        return nil if p1.distance(p2) < @merge_tol
        begin
          target = dash_layer ? get_or_create_layer(dash_layer) : layer

          if dash_spec && dash_spec[:pattern].is_a?(Array) && !dash_spec[:pattern].empty?
            edges = add_dashed_line(entities, p1, p2, dash_spec, target)
            return edges.first if edges && !edges.empty?
            return nil
          end

          edge = entities.add_line(p1, p2)
          if edge
            set_layer(edge, target)
            @edge_count += 1
          end
          edge
        rescue StandardError => e
          Logger.error("GeometryBuilder", "add_line failed", e)
          nil
        end
      end

      # ---------------------------------------------------------------
      # Face creation
      # ---------------------------------------------------------------
      def draw_face(entities, points, layer, fill_rgb = nil)
        return if points.length < 3
        begin
          face = entities.add_face(points)
          if face
            set_layer(face, layer)
            if fill_rgb && fill_rgb.is_a?(Array) && fill_rgb.length >= 3
              face.material = get_or_create_material(fill_rgb)
            end
            @face_count += 1
          end
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "draw_face failed: #{e.message}")
        end
      end

      # ---------------------------------------------------------------
      # Text placement
      # ---------------------------------------------------------------
      def place_text(entities, item, origin_x, origin_y, page_height, layer)
        return unless @import_text && item.text && !item.text.strip.empty?

        begin
          # Convert PDF coordinate to SketchUp point
          pt = pdf_to_su(item.x, item.y, origin_x, origin_y)
          item_angle = item.respond_to?(:angle) ? item.angle.to_f : 0.0
          rotated_label_geometry = (
            !@use_3d_text &&
            @strict_text_fidelity &&
            angle_needs_geometry_text?(item_angle)
          )

          if @use_3d_text || rotated_label_geometry
            # ── Geometry mode: add_3d_text (proper filled letterforms) ──
            page_h = (@media_box[3] - @media_box[1]).abs
            page_h = 792.0 if page_h < 1

            fs = item.font_size.to_f
            raw = (item.respond_to?(:raw_font_size) && item.raw_font_size) ?
                  item.raw_font_size.to_f : nil

            if raw && raw > 0
              # Internal parser: use raw if effective is blown up
              fs = fs > (page_h * 0.04) ? raw : fs
            else
              # ExternalTextExtractor: bbox height → add_3d_text letter height.
              # add_3d_text height = cap height directly.
              # bbox includes ascenders, descenders, leading.
              # Cap height ≈ 30% of pdftotext bbox for this font/page combo.
              bbox_h = fs
              fs = fs * 0.30
              # Shift origin up: bbox bottom includes descender space
              # Keep this conservative to avoid drift on rotated/angled blueprint text.
              baseline_ratio = (item_angle.abs > 10.0) ? 0.0 : 0.05
              baseline_shift = bbox_h * baseline_ratio * PDF_POINT_TO_INCH * @scale
              pt = Geom::Point3d.new(pt.x, pt.y + baseline_shift, pt.z)
            end

            fs = [fs, page_h * 0.03].min if fs > page_h * 0.03
            fs = [fs, 1.0].max
            height = fs * PDF_POINT_TO_INCH * @scale
            height = [[height, 0.015].max, 1.5].min

            begin
              # add_3d_text creates geometry at the origin, then we transform it
              count_before = entities.to_a.length
              success = entities.add_3d_text(
                item.text,
                TextAlignLeft,
                "Arial",
                false,             # bold
                false,             # italic
                height,            # letter height in inches
                0.6,               # tolerance (lower = smoother)
                0.0,               # z extrusion (0 = flat faces)
                true,              # filled
                0.0                # z position
              )

              if success
                new_ents = entities.to_a[count_before..-1] || []
                if new_ents.any?
                  # Build transform: move to position, optionally rotate
                  xform = Geom::Transformation.new(pt)
                  if item_angle.abs > 0.1
                    rot = Geom::Transformation.rotation(ORIGIN, Z_AXIS, item_angle.degrees)
                    xform = xform * rot
                  end
                  entities.transform_entities(xform, *new_ents)
                  new_ents.each do |entity|
                    begin
                      set_layer(entity, layer)
                    rescue StandardError => e
                      Logger.warn("GeometryBuilder", "set_layer on text geometry failed: #{e.message}")
                    end
                  end
                  @text_count += 1
                end
              end
            rescue StandardError => e
              Logger.warn("GeometryBuilder", "add_3d_text failed: #{e.message}")
              # Fallback to annotation text
              begin
                text = entities.add_text(item.text, pt)
                if text
                  set_layer(text, layer)
                  @text_count += 1
                end
              rescue StandardError => e
                Logger.warn("GeometryBuilder", "add_text fallback failed: #{e.message}")
              end
            end
          else
            # ── Label mode: annotation text ──
            text = nil
            begin
              text = entities.add_text(item.text, pt, Geom::Vector3d.new(0, 0, 0))
            rescue StandardError => e
              Logger.warn("GeometryBuilder", "add_text with vector failed: #{e.message}")
              text = entities.add_text(item.text, pt)
            end
            if text
              set_layer(text, layer)
              @text_count += 1
            end
          end
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "place_text failed: #{e.message}")
        end
      end

      # Use geometry text only for non-horizontal labels when strict fidelity is enabled.
      # This avoids needlessly converting horizontal labels that annotation text handles well.
      # Threshold is tunable via BC_SU_ROTATED_LABEL_DEG for troubleshooting.
      def angle_needs_geometry_text?(angle_deg, tol_deg = 12.0)
        env = ENV['BC_SU_ROTATED_LABEL_DEG']
        if env && !env.to_s.strip.empty?
          begin
            parsed = env.to_f
            tol_deg = parsed if parsed >= 0.0 && parsed <= 89.0
          rescue StandardError
            # keep default tolerance
          end
        end
        a = angle_deg.to_f % 180.0
        a += 180.0 if a < 0.0
        a = 180.0 - a if a > 90.0
        a > tol_deg.to_f
      rescue StandardError
        false
      end

      # ---------------------------------------------------------------
      # Color-based grouping
      # ---------------------------------------------------------------
      def get_color_group(parent_entities, rgb)
        return parent_entities unless @group_by_color

        r = [[rgb[0] * 255, 0].max, 255].min.to_i
        g = [[rgb[1] * 255, 0].max, 255].min.to_i
        b = [[rgb[2] * 255, 0].max, 255].min.to_i
        key = "#{r}_#{g}_#{b}"

        unless @color_groups[key]
          grp = parent_entities.add_group
          grp.name = "Color_%02X%02X%02X" % [r, g, b]
          @color_groups[key] = grp
        end

        @color_groups[key].entities
      end

      # ---------------------------------------------------------------
      # Dash pattern → layer/tag classification
      # ---------------------------------------------------------------
      # Get or create a SketchUp material from an [r, g, b] 0.0–1.0 array.
      # Caches materials to avoid duplicates.
      def get_or_create_material(rgb)
        @material_cache ||= {}
        r = (rgb[0].to_f * 255).round
        g = (rgb[1].to_f * 255).round
        b = (rgb[2].to_f * 255).round
        key = "PDF_#{r}_#{g}_#{b}"
        return @material_cache[key] if @material_cache[key]
        mat = @model.materials[key]
        unless mat
          mat = @model.materials.add(key)
          mat.color = Sketchup::Color.new(r, g, b)
        end
        @material_cache[key] = mat
        mat
      end

      # Compute bounding box of a VectorPath in PDF user-space points.
      # Returns [min_x, min_y, max_x, max_y] or nil.
      def compute_path_bbox(path)
        xs = []
        ys = []
        path.subpaths.each do |sp|
          sp.segments.each do |seg|
            seg.points.each do |pt|
              xs << pt[0] if pt[0]
              ys << pt[1] if pt[1]
            end
          end
        end
        return nil if xs.empty?
        [xs.min, ys.min, xs.max, ys.max]
      end

      def classify_dash(dash_pattern)
        return nil unless @map_dashes && dash_pattern
        arr = dash_pattern
        arr = arr[0] if arr.is_a?(Array) && arr[0].is_a?(Array)
        return nil unless arr.is_a?(Array) && arr.length >= 2

        # All positive values?
        return nil unless arr.all? { |d| d.is_a?(Numeric) && d > 0 }

        if arr.length == 2
          "Dashed"
        elsif arr.length >= 4
          "Dashdot"
        elsif arr.length == 3
          "Dashdot"
        else
          nil
        end
      end

      # Normalize PDF dash pattern to model-space inches.
      def normalize_dash_pattern(dash_pattern, ctm = nil)
        return nil unless dash_pattern

        arr = dash_pattern
        phase = 0.0
        if arr.is_a?(Array) && arr[0].is_a?(Array)
          phase = (arr[1] || 0.0).to_f
          arr = arr[0]
        end
        return nil unless arr.is_a?(Array) && !arr.empty?

        nums = arr.map { |d| d.to_f.abs }.select { |d| d > 0.0 }
        return nil if nums.empty?

        # Dash lengths are in PDF user units; convert with page scale and CTM magnitude.
        sx = 1.0
        sy = 1.0
        if ctm.is_a?(Array) && ctm.length >= 4
          sx = Math.sqrt(ctm[0].to_f**2 + ctm[1].to_f**2)
          sy = Math.sqrt(ctm[2].to_f**2 + ctm[3].to_f**2)
          sx = 1.0 if sx <= 1e-9
          sy = 1.0 if sy <= 1e-9
        end
        ctm_scale = (sx + sy) / 2.0

        to_in = PDF_POINT_TO_INCH * @scale * ctm_scale
        pattern = nums.map { |d| [d * to_in, @merge_tol * 2.0].max }

        # SketchUp 2017 can visually collapse very short dash segments to solid.
        # Enforce a minimum visible segment length while preserving ratios.
        min_visible = 0.03 # inches
        min_seg = pattern.min
        if min_seg && min_seg < min_visible
          vis_scale = min_visible / min_seg
          pattern = pattern.map { |d| d * vis_scale }
        end

        # PDF allows odd-length arrays; they repeat to make an even cycle.
        pattern = pattern + pattern if pattern.length.odd?

        cycle = pattern.inject(0.0, :+)
        return nil if cycle <= @merge_tol * 2.0

        {
          pattern: pattern,
          phase: (phase.to_f * to_in) % cycle
        }
      end

      # Draw line as explicit dash segments to preserve hidden-line semantics.
      def add_dashed_line(entities, p1, p2, dash_spec, layer)
        pattern = dash_spec[:pattern]
        phase = dash_spec[:phase].to_f
        return [] unless pattern.is_a?(Array) && !pattern.empty?

        total_len = p1.distance(p2)
        return [] if total_len <= @merge_tol

        cycle_len = pattern.inject(0.0, :+)
        return [] if cycle_len <= @merge_tol

        dir = Geom::Vector3d.new(p2.x - p1.x, p2.y - p1.y, p2.z - p1.z)
        return [] if dir.length <= 1e-9
        dir.length = 1.0

        # Resolve initial pattern index from phase.
        idx = 0
        remain = pattern[0]
        offset = phase % cycle_len
        while offset > remain && pattern.length > 1
          offset -= remain
          idx = (idx + 1) % pattern.length
          remain = pattern[idx]
        end
        remain -= offset
        remain = pattern[idx] if remain <= @merge_tol

        draw_on = idx.even?
        pos = 0.0
        edges = []

        while pos < total_len - @merge_tol
          seg_len = [remain, total_len - pos].min
          if draw_on && seg_len > @merge_tol
            a = Geom::Point3d.new(
              p1.x + dir.x * pos,
              p1.y + dir.y * pos,
              p1.z + dir.z * pos
            )
            b = Geom::Point3d.new(
              p1.x + dir.x * (pos + seg_len),
              p1.y + dir.y * (pos + seg_len),
              p1.z + dir.z * (pos + seg_len)
            )
            begin
              e = entities.add_line(a, b)
              if e
                set_layer(e, layer)
                edges << e
                @edge_count += 1
              end
            rescue StandardError => e
              Logger.warn("GeometryBuilder", "add_dashed_line segment failed: #{e.message}")
            end
          end

          pos += seg_len
          idx = (idx + 1) % pattern.length
          remain = pattern[idx]
          draw_on = idx.even?
        end

        edges
      end

      # ---------------------------------------------------------------
      # Utilities
      # ---------------------------------------------------------------
      def remove_consecutive_duplicates(points)
        return points if points.length <= 1
        result = [points[0]]
        (1...points.length).each do |i|
          unless points[i].distance(result.last) < @merge_tol
            result << points[i]
          end
        end
        result
      end

      def normalize_angle(angle)
        while angle <= -Math::PI
          angle += 2 * Math::PI
        end
        while angle > Math::PI
          angle -= 2 * Math::PI
        end
        angle
      end

      def get_or_create_layer(name)
        return nil unless name
        layers = @model.layers
        layer = layers[name]
        unless layer
          layer = layers.add(name)
          apply_layer_line_style(layer, name)
        end
        layer
      end

      def set_layer(entity, layer)
        return unless layer
        begin
          entity.layer = layer
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "set_layer failed: #{e.message}")
        end
      end

      def apply_layer_line_style(layer, name)
        return unless layer && name
        return unless @model.respond_to?(:line_styles) && @model.line_styles
        return unless layer.respond_to?(:line_style=)

        style_name = case name.to_s.downcase
                     when 'dashed' then 'Dashed'
                     when 'dashdot' then 'Dash Dot'
                     else nil
                     end
        return unless style_name

        begin
          styles = @model.line_styles
          style = nil
          begin
            style = styles[style_name]
          rescue StandardError => e
            Logger.warn("GeometryBuilder", "line style lookup by key failed: #{e.message}")
          end
          if style.nil?
            begin
              style = styles.to_a.find { |s| s.display_name.to_s.downcase == style_name.downcase }
            rescue StandardError => e
              Logger.warn("GeometryBuilder", "line style lookup by name failed: #{e.message}")
            end
          end
          layer.line_style = style if style
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "apply_layer_line_style failed: #{e.message}")
        end
      end

    end
  end
end
