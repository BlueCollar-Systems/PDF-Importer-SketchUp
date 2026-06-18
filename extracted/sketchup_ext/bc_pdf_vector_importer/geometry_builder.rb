# bc_pdf_vector_importer/geometry_builder.rb
# Converts parsed PDF vector paths into native SketchUp geometry.
# v2: Arc reconstruction, color-based tag grouping, dash pattern mapping,
# line width tracking, text placement, and progress feedback.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'page_transform')

module BlueCollarSystems
  module PDFVectorImporter
    class GeometryBuilder

      PDF_POINT_TO_INCH = 1.0 / 72.0
      CLOSE_TOL = 1e-6

      attr_reader :page_group, :text_group

      def initialize(model, paths, text_items, media_box, opts = {})
        @model = model
        @paths = paths
        @text_items = text_items || []
        @media_box = media_box

        # BCS-ARCH-001 consolidated defaults (tightest correct value):
        # bezier_segments=32 (SU curve quality ceiling),
        # merge_tolerance=0.0005 inches.
        @scale           = opts[:scale_factor] || 1.0
        @bezier_segments = opts[:bezier_segments] || 32
        @import_as       = opts[:import_as] || :edges
        @layer_name      = opts[:layer_name] || 'PDF Import'
        @layer_manager   = opts[:layer_manager]
        @group_per_page  = opts[:group_per_page] != false
        @page_number     = opts[:page_number] || 1
        @flatten         = opts[:flatten_to_2d] != false
        @merge_tol       = opts[:merge_tolerance] || 0.0005
        @import_fills    = opts[:import_fills] != false
        @group_by_color  = opts[:group_by_color] || false
        @detect_arcs     = opts[:detect_arcs] != false
        @map_dashes      = opts[:map_dashes] || false
        @import_text     = opts[:import_text] || false
        @use_3d_text     = opts[:use_3d_text] || false
        @strict_text_fidelity = opts[:strict_text_fidelity] || false
        @target_entities = opts[:target_entities] || nil
        @y_offset        = opts[:y_offset] || 0.0
        @page_rotation   = PageTransform.normalize_rotation(opts[:page_rotation])

        @edge_count = 0
        @face_count = 0
        @arc_count  = 0
        @text_count = 0
      end

      def build
        base_layer = resolve_layer(nil)
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

        page_height = PageTransform.effective_height(@media_box, @page_rotation)
        page_origin_x = @media_box[0]
        page_origin_y = @media_box[1]

        # Color group cache
        @color_groups = {}

        page_width  = PageTransform.effective_width(@media_box, @page_rotation)
        page_height_pts = PageTransform.effective_height(@media_box, @page_rotation)
        page_area_pts = page_width * page_height_pts

        # ── Vector geometry ──
        heavy_page = @paths.length >= 500
        path_yield_every = heavy_page ? 100 : 0
        @paths.each_with_index do |path, path_idx|
          if path_yield_every > 0 && (path_idx % path_yield_every).zero?
            Sketchup.status_text = "PDF Import — building geometry (#{path_idx}/#{@paths.length} paths)..."
            begin
              GC.start if path_idx > 0 && (path_idx % (path_yield_every * 5)).zero?
            rescue StandardError
            end
          end

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
          color_rgb = if should_fill && !should_stroke && path.fill_color.is_a?(Array)
                        path.fill_color
                      else
                        path.stroke_color || path.fill_color || [0, 0, 0]
                      end
          dest = get_color_group(target, color_rgb)

          # Determine the layer for this path — OCG layer takes priority when enabled
          path_layer = resolve_layer(path.layer_name)

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
          text_group = nil
          if @page_group
            text_group = @page_group.entities.add_group
            text_group.name = "Text"
            set_layer(text_group, base_layer)
            @text_group = text_group
          end
          text_target = text_group ? text_group.entities : target

          @text_items.each do |item|
            item_layer = if @layer_manager && @layer_manager.match_pdf_layers
                           resolve_layer(item.respond_to?(:layer_name) ? item.layer_name : nil)
                         else
                           text_fallback_layer
                         end
            place_text(text_target, item, page_origin_x, page_origin_y, page_height, item_layer)
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
      def pdf_to_su(pdf_x, pdf_y, origin_x, origin_y, displayed_space = false)
        if @page_rotation != 0 && displayed_space
          x_pts = pdf_x.to_f
          y_pts = pdf_y.to_f
        elsif @page_rotation != 0
          x_pts, y_pts = PageTransform.transform_point(pdf_x, pdf_y, @media_box, @page_rotation)
        else
          x_pts = pdf_x.to_f - origin_x.to_f
          y_pts = pdf_y.to_f - origin_y.to_f
        end

        x_inch = x_pts * PDF_POINT_TO_INCH * @scale
        y_inch = y_pts * PDF_POINT_TO_INCH * @scale + @y_offset
        z_inch = 0.0
        Geom::Point3d.new(x_inch, y_inch, z_inch)
      end

      def text_point_to_su(item, pdf_x, pdf_y, origin_x, origin_y)
        # pdftotext -bbox-layout reports positions in MediaBox space; rotate them
        # into displayed sheet space like internal TextParser coordinates.
        pdf_to_su(pdf_x, pdf_y, origin_x, origin_y, false)
      end

      def display_text_angle(item, angle_deg)
        return angle_deg.to_f if @page_rotation == 0
        PageTransform.transform_angle(angle_deg, @page_rotation)
      rescue StandardError
        angle_deg.to_f
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

        # Arc fit tolerance in inches (consistent with arc_fitter.rb which
        # expects inches).  0.003" ≈ 0.08mm matches the Python importers'
        # default arc_fit_tol_mm.  Scaled by import scale factor.
        segments = ArcFitter.detect_arcs_in_polyline(pts_2d,
          arc_fit_tol: 0.003 * @scale,
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
            # Keep imported sheet faces consistently front-facing in top view.
            face.reverse! if face.normal.z < 0
            set_layer(face, layer)
            if fill_rgb && fill_rgb.is_a?(Array) && fill_rgb.length >= 3
              mat = get_or_create_material(fill_rgb)
              face.material = mat
              face.back_material = mat
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
          if @use_3d_text
            place_mesh_text(entities, item, origin_x, origin_y, layer)
          elsif stacked_vertical_dimension_labels?(item)
            place_stacked_vertical_dimension_labels(
              entities, item, origin_x, origin_y, layer
            )
          else
            place_annotation_label(entities, item, origin_x, origin_y, layer)
          end
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "place_text failed: #{e.message}")
        end
      end

      # Shared PDF insertion point for Labels and 3D Text — matches label heuristics
      # used by the external pdftotext path (bbox centering, baseline, angle cleanup).
      def text_insertion_pdf(item)
        label_insertion_pdf(item)
      end

      def mesh_text_height_inches(item, angle_deg, page_h)
        fs = effective_font_size_pts(item)
        raw = (item.respond_to?(:raw_font_size) && item.raw_font_size) ?
              item.raw_font_size.to_f : nil

        if raw && raw > 0
          fs = fs > (page_h * 0.04) ? raw : fs
        else
          fs *= 0.55
        end

        fs = [fs, page_h * 0.03].min if fs > page_h * 0.03
        fs = [fs, 1.0].max
        height = fs * PDF_POINT_TO_INCH * @scale
        [[height, 0.015].max, 1.5].min
      rescue StandardError
        0.015
      end

      def place_mesh_text(entities, item, origin_x, origin_y, layer)
        label_x, label_y, label_angle = mesh_label_anchor_pdf(item)
        display_angle = display_text_angle(item, label_angle)
        pt = text_point_to_su(item, label_x, label_y, origin_x, origin_y)

        page_h = PageTransform.effective_height(@media_box, @page_rotation)
        page_h = 792.0 if page_h < 1
        height = mesh_text_height_inches(item, display_angle, page_h)
        return if height <= 0

        count_before = entities.to_a.length
        success = entities.add_3d_text(
          item.text,
          TextAlignLeft,
          "Arial",
          false,
          false,
          height,
          0.6,
          0.0,
          true,
          0.0
        )

        return unless success

        new_ents = entities.to_a[count_before..-1] || []
        return if new_ents.empty?

        move = Geom::Transformation.new(pt)
        entities.transform_entities(move, *new_ents)
        if display_angle.abs > 0.1
          rot = Geom::Transformation.rotation(pt, Z_AXIS, display_angle.degrees)
          entities.transform_entities(rot, *new_ents)
        end
        new_ents.each do |entity|
          begin
            set_layer(entity, layer)
          rescue StandardError => e
            Logger.warn("GeometryBuilder", "set_layer on text geometry failed: #{e.message}")
          end
        end
        @text_count += 1
      rescue StandardError => e
        Logger.warn("GeometryBuilder", "add_3d_text failed: #{e.message}")
        begin
          text = entities.add_text(item.text, pt)
          if text
            set_layer(text, layer)
            @text_count += 1
          end
        rescue StandardError => e2
          Logger.warn("GeometryBuilder", "add_text fallback failed: #{e2.message}")
        end
      end

      def stacked_vertical_dimension_labels?(item)
        return false unless label_has_bbox?(item)
        tokens = item.text.to_s.strip.split(/\s+/)
        return false if tokens.length < 2
        return false unless tokens.all? { |tok| tok =~ /\A\d{1,2}\z/ }
        bbox_w = (item.bbox_x1.to_f - item.bbox_x0.to_f).abs
        bbox_h = (item.bbox_y1.to_f - item.bbox_y0.to_f).abs
        narrow_vertical_dimension_bbox?(bbox_w, bbox_h)
      rescue StandardError
        false
      end

      def place_stacked_vertical_dimension_labels(entities, item, origin_x, origin_y, layer)
        tokens = item.text.to_s.strip.split(/\s+/)
        bx0 = item.bbox_x0.to_f
        bx1 = item.bbox_x1.to_f
        by0 = item.bbox_y0.to_f
        by1 = item.bbox_y1.to_f

        tokens.each_with_index do |token, idx|
          sub_by0, sub_by1 = stacked_dimension_row_bounds(by0, by1, idx, tokens.length)
          sub_item = sub_dimension_text_item(item, token, bx0, bx1, sub_by0, sub_by1)
          place_annotation_label(entities, sub_item, origin_x, origin_y, layer)
        end
      rescue StandardError => e
        Logger.warn("GeometryBuilder", "stacked vertical dimension placement failed: #{e.message}")
        place_annotation_label(entities, item, origin_x, origin_y, layer)
      end

      # CAD drawings leave a visible gap between stacked dimension numerals inside
      # one pdftotext line bbox (e.g. SECTION F-F "2" over "2").
      def stacked_dimension_row_bounds(by0, by1, index, count)
        bh = (by1 - by0).abs
        count = [count.to_i, 1].max
        return [by0, by1] if count == 1

        gap_ratio = 1.74
        glyph_h = bh / (count + ((count - 1) * gap_ratio))
        gap = bh - (glyph_h * count)
        cursor = by0.to_f
        index.times do
          cursor += glyph_h + gap
        end
        [cursor, cursor + glyph_h]
      rescue StandardError
        [by0.to_f, by1.to_f]
      end

      def sub_dimension_text_item(item, token, bx0, bx1, by0, by1)
        row_h = (by1 - by0).abs
        fs = [row_h, 1.0].max
        item.class.new(
          token,
          bx0,
          by0,
          fs,
          0.0,
          item.font_name,
          item.respond_to?(:raw_font_size) ? item.raw_font_size : nil,
          bx0,
          by0,
          bx1,
          by1
        )
      rescue StandardError
        item
      end

      def try_add_annotation_text(entities, text, pt, dir_vec)
        begin
          ent = entities.add_text(text, pt, dir_vec)
          return ent if ent
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "add_text with vector failed: #{e.message}")
        end

        begin
          ent = entities.add_text(text, pt, Geom::Vector3d.new(0, 0, 0))
          return ent if ent
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "add_text with zero vector failed: #{e.message}")
        end

        begin
          entities.add_text(text, pt)
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "add_text failed: #{e.message}")
          nil
        end
      end

      def place_annotation_label(entities, item, origin_x, origin_y, layer)
        label_x, label_y, label_angle = label_insertion_pdf(item)
        display_angle = display_text_angle(item, label_angle)
        pt = text_point_to_su(item, label_x, label_y, origin_x, origin_y)
        dir_vec = label_direction_vector(display_angle, item)
        text = try_add_annotation_text(entities, item.text, pt, dir_vec)
        if text
          set_layer(text, layer)
          @text_count += 1
          return
        end

        Logger.warn("GeometryBuilder",
          "add_text unavailable for #{item.text.inspect} — falling back to mesh text")
        place_mesh_text(entities, item, origin_x, origin_y, layer)
      end

      def label_has_bbox?(item)
        return false unless item
        vals = [item.bbox_x0, item.bbox_y0, item.bbox_x1, item.bbox_y1]
        return false unless vals.all? { |v| !v.nil? }
        (item.bbox_x1.to_f - item.bbox_x0.to_f).abs > 1.0e-6 &&
          (item.bbox_y1.to_f - item.bbox_y0.to_f).abs > 1.0e-6
      rescue StandardError
        false
      end

      def external_text_item?(item)
        item.font_name.to_s == 'pdftotext'
      rescue StandardError
        false
      end

      BOM_TABLE_HEADER = /\A(?:QUAN|MARK|DESCRIPTION|LENGTH|QTY)\z/i

      def label_baseline_ratio(angle_deg)
        ratio = (angle_deg.to_f.abs > 10.0) ? 0.05 : 0.20
        env_ratio = ENV['BC_SU_TEXT_BASELINE_RATIO']
        if env_ratio && !env_ratio.to_s.strip.empty?
          begin
            parsed_ratio = env_ratio.to_f
            ratio = parsed_ratio if parsed_ratio >= 0.0 && parsed_ratio <= 0.50
          rescue StandardError
            # keep computed baseline ratio
          end
        end
        ratio
      end

      ANNOTATION_LABEL = /\A(?:TYP\.?|U\.N\.O\.)\z/i
      # Weld callouts: any inch fraction (not a fixed 1017 fraction list).
      WELD_FRACTION_LABEL = /\A\d+\/\d+"?\z/i
      # Steel part marks: w/p/a prefix + digits (shop-drawing convention).
      PART_MARK_LABEL = /\A[wap]\d+\z/i
      SECTION_TITLE_LABEL = /\ASECTION\s+-/i

      # Common shop weld fractions stay callouts even in near-square bboxes.
      COMMON_WELD_FRACTION = /\A(?:1\/2|1\/4|3\/16|5\/16)"?\z/i

      def weld_fraction_label?(text, bbox_w_pts = nil, bbox_h_pts = nil)
        t = text.to_s.strip
        return false unless t =~ WELD_FRACTION_LABEL
        return true unless bbox_w_pts && bbox_h_pts
        bw = bbox_w_pts.to_f
        bh = bbox_h_pts.to_f
        return false if narrow_vertical_dimension_bbox?(bw, bh)
        return true if t =~ COMMON_WELD_FRACTION
        # Other inch fractions (e.g. 3/4", 7/8") in square/tall bboxes are dimensions.
        return false if bh >= bw * 0.85
        true
      rescue StandardError
        false
      end

      def annotation_like_label?(text, bbox_w_pts = nil, bbox_h_pts = nil)
        t = text.to_s.strip
        return false if t.empty?
        !!(t =~ ANNOTATION_LABEL) || weld_fraction_label?(t, bbox_w_pts, bbox_h_pts)
      rescue StandardError
        false
      end

      def dimension_like_label?(text)
        t = text.to_s.strip
        return false if t.empty?
        return false if t =~ ANNOTATION_LABEL
        !!((t =~ /\A\d+(?:[\s'\-]\d+)*(?:\s+\d+\/\d+)?"?\z/) ||
           (t =~ /\A\d+'-\d+(?:\s+\d+\/\d+)?"?\z/) ||
           (t =~ /\A\d+-\d+(?:\s+\d+\/\d+)?"?\z/) ||
           (t =~ /\A\d{1,2}\/\d{1,2}"?\z/) ||
           (t =~ /\A\d+\s+\d{1,2}\/\d{1,2}"?\z/))
      rescue StandardError
        false
      end

      def feet_inch_dimension_label?(text)
        t = text.to_s.strip
        !!((t =~ /\A\d+'-\d+/) ||
           (t =~ /\A\d+-\d+(?:\s+\d{1,2}\/\d{1,2})?"?\z/))
      rescue StandardError
        false
      end

      def dimension_glyph_width_pts(char, font_size_pts)
        fs = font_size_pts.to_f
        case char
        when "'", '"', '-', ' ' then fs * 0.28
        when '/' then fs * 0.32
        when '0'..'9' then fs * 0.52
        else fs * 0.45
        end
      rescue StandardError
        font_size_pts.to_f * 0.45
      end

      def feet_inch_label_width_pts(text, font_size_pts)
        text.to_s.chars.inject(0.0) { |sum, ch| sum + dimension_glyph_width_pts(ch, font_size_pts) }
      rescue StandardError
        text.to_s.length * font_size_pts.to_f * 0.55
      end

      def should_center_label?(text, bbox_w_pts, font_size_pts, angle_deg)
        return false if angle_deg.to_f.abs > 3.0
        t = text.to_s.strip
        return false if t.empty?
        return false unless t =~ BOM_TABLE_HEADER
        fs = [font_size_pts.to_f, 1.0].max
        bw = [bbox_w_pts.to_f, 0.0].max
        est_w = t.length * fs * 0.55
        bw > est_w * 1.15
      rescue StandardError
        false
      end

      def narrow_vertical_dimension_bbox?(bbox_w_pts, bbox_h_pts)
        bw = bbox_w_pts.to_f
        bh = bbox_h_pts.to_f
        bw > 0.5 && bh > bw * 1.15
      rescue StandardError
        false
      end

      def chord_spec_label?(text)
        !!(text.to_s.strip =~ /\A\d+'-\d+\s*\(/)
      rescue StandardError
        false
      end

      def spec_label_width_pts(text, font_size_pts, bbox_w_pts)
        fs = [font_size_pts.to_f, 1.0].max
        bw = [bbox_w_pts.to_f, 0.0].max
        raw = feet_inch_label_width_pts(text, fs)
        [raw, bw * 0.92].min
      rescue StandardError
        dimension_label_est_width_pts(text, font_size_pts, bbox_w_pts)
      end

      def should_center_spec_label?(text, bbox_w_pts, bbox_h_pts, font_size_pts, angle_deg)
        return false if angle_deg.to_f.abs > 3.0
        return false unless chord_spec_label?(text)
        bw = bbox_w_pts.to_f
        bh = bbox_h_pts.to_f
        fs = [font_size_pts.to_f, 1.0].max
        est_w = spec_label_width_pts(text, fs, bw)
        bh <= bw * 1.08 && bw > est_w * 1.02
      rescue StandardError
        false
      end
      def part_mark_label?(text)
        !!(text.to_s.strip =~ PART_MARK_LABEL)
      rescue StandardError
        false
      end

      def angle_member_mark_label?(text)
        !!(text.to_s.strip =~ /\Aa\d+\z/i)
      rescue StandardError
        false
      end

      # Part marks rotated ~90° in the PDF (not merely a tall/narrow pdftotext bbox).
      def rotated_part_mark_label?(item)
        return false unless part_mark_label?(item.text)
        angle = item.respond_to?(:angle) ? item.angle.to_f : 0.0
        angle.abs > 75.0 && angle.abs < 105.0
      rescue StandardError
        false
      end

      # Part marks aligned to diagonal members (~8°–75° PDF baseline).
      def diagonal_part_mark_label?(item)
        return false unless part_mark_label?(item.text)
        angle = item.respond_to?(:angle) ? item.angle.to_f : 0.0
        angle.abs >= 8.0 && angle.abs < 75.0
      rescue StandardError
        false
      end

      def narrow_part_mark_bbox?(bbox_w_pts, bbox_h_pts)
        bbox_h_pts.to_f > bbox_w_pts.to_f * 1.08
      rescue StandardError
        false
      end

      # Tall/narrow bbox with horizontal PDF angle — glyph height is the short side.
      def horizontal_part_mark_in_tall_bbox?(item)
        return false unless part_mark_label?(item.text) && label_has_bbox?(item)
        angle = item.respond_to?(:angle) ? item.angle.to_f : 0.0
        return false if angle.abs >= 12.0
        bw = (item.bbox_x1.to_f - item.bbox_x0.to_f).abs
        bh = (item.bbox_y1.to_f - item.bbox_y0.to_f).abs
        bh > bw * 1.5
      rescue StandardError
        false
      end

      # pdftotext reports many CAD labels as a horizontal angle with a tall/narrow
      # bbox. Use bbox short side for font size without assuming every narrow
      # dimension should rotate.
      def tall_single_text_bbox?(item, bbox_w_pts = nil, bbox_h_pts = nil)
        return false unless label_has_bbox?(item)
        bw = bbox_w_pts || (item.bbox_x1.to_f - item.bbox_x0.to_f).abs
        bh = bbox_h_pts || (item.bbox_y1.to_f - item.bbox_y0.to_f).abs
        return false unless narrow_vertical_dimension_bbox?(bw, bh)
        return false if stacked_vertical_dimension_labels?(item)
        t = item.text.to_s.strip
        return false if t.empty?
        return false if part_mark_label?(t)
        dimension_like_label?(t) || chord_spec_label?(t)
      rescue StandardError
        false
      end

      def single_vertical_part_mark_bbox?(item, bbox_w_pts = nil, bbox_h_pts = nil)
        return false unless tall_single_text_bbox?(item, bbox_w_pts, bbox_h_pts)
        part_mark_label?(item.text)
      rescue StandardError
        false
      end

      def effective_font_size_pts(item)
        fs = [item.font_size.to_f, 1.0].max
        return fs unless label_has_bbox?(item)
        bw = (item.bbox_x1.to_f - item.bbox_x0.to_f).abs
        bh = (item.bbox_y1.to_f - item.bbox_y0.to_f).abs
        angle = item.respond_to?(:angle) ? item.angle.to_f : 0.0
        if slope_triangle_label?(item.text, bw, bh, angle)
          [bw, bh].min
        elsif tall_single_text_bbox?(item, bw, bh)
          [bw, bh].min
        elsif horizontal_part_mark_in_tall_bbox?(item)
          [bw, bh].min
        elsif rotated_part_mark_label?(item)
          [bw, bh].min
        else
          fs
        end
      rescue StandardError
        [item.font_size.to_f, 1.0].max
      end

      def slope_triangle_label?(text, bbox_w_pts, bbox_h_pts, angle_deg)
        return false if angle_deg.to_f.abs > 3.0
        t = text.to_s.strip
        return false unless t =~ /\A\d{1,2}(?:\s+\d{1,2}\/\d{1,2})?"?\z/
        bbox_h_pts.to_f > bbox_w_pts.to_f * 1.15
      rescue StandardError
        false
      end

      def dimension_label_raw_width_pts(text, font_size_pts)
        fs = [font_size_pts.to_f, 1.0].max
        t = text.to_s.strip
        if t =~ /\A\d{1,2}\/\d{1,2}"?\z/
          fs * 0.58
        elsif t =~ /\A\d+\s+\d{1,2}\/\d{1,2}"?\z/
          fs * 1.05
        elsif t =~ /\A\d{1,2}\z/
          fs * 0.55
        elsif feet_inch_dimension_label?(t)
          feet_inch_label_width_pts(t, fs)
        else
          t.length * fs * 0.55
        end
      rescue StandardError
        [font_size_pts.to_f * 0.55, 1.0].max
      end

      def dimension_label_est_width_pts(text, font_size_pts, bbox_w_pts)
        bw = [bbox_w_pts.to_f, 0.0].max
        raw = dimension_label_raw_width_pts(text, font_size_pts)
        [raw, bw * 0.95].min
      rescue StandardError
        [font_size_pts.to_f * 0.55, 1.0].max
      end

      def should_center_dimension_label?(text, bbox_w_pts, bbox_h_pts, font_size_pts, angle_deg)
        return false if angle_deg.to_f.abs > 3.0
        return false unless dimension_like_label?(text)
        bw = bbox_w_pts.to_f
        bh = bbox_h_pts.to_f
        return false if weld_fraction_label?(text, bw, bh)
        fs = [font_size_pts.to_f, 1.0].max
        t = text.to_s.strip
        raw_w = dimension_label_raw_width_pts(text, fs)
        return true if narrow_vertical_dimension_bbox?(bw, bh)
        return true if (t =~ /\A\d{1,2}\z/) && bw < fs * 1.8
        return true if (t =~ /\A\d{1,2}\/\d{1,2}"?\z/) &&
                       bh >= bw * 0.85 && bw > raw_w * 1.04
        return true if (t =~ /\A\d{2}\s+\d{1,2}\/\d{1,2}"?\z/) &&
                       bh <= bw * 1.05 && bw > raw_w * 1.04
        # Feet-inch horizontal dims: center when pdftotext bbox is wider than glyphs.
        if feet_inch_dimension_label?(t) && bh <= bw * 1.05
          est_w = [raw_w, bw * 0.95].min
          return true if bw > est_w * 1.04
        end
        false
      rescue StandardError
        false
      end

      def narrow_fraction_dimension_stays_horizontal?(text, bbox_w_pts, bbox_h_pts, font_size_pts, angle_deg)
        return false unless should_center_dimension_label?(text, bbox_w_pts, bbox_h_pts, font_size_pts, angle_deg)
        t = text.to_s.strip
        # Single-digit stacked fractions (e.g. "1 1/2") stay horizontal in narrow bbox.
        !!(t =~ /\A\d{1}\s+\d{1,2}\/\d{1,2}"?\z/)
      rescue StandardError
        false
      end

      def label_baseline_pdf_y(item, by0, by1, bbox_h, angle_deg)
        fs = effective_font_size_pts(item)
        raw_angle = item.respond_to?(:angle) ? item.angle.to_f : 0.0
        ratio = label_baseline_ratio(angle_deg)
        bbox_w = label_has_bbox?(item) ?
                 (item.bbox_x1.to_f - item.bbox_x0.to_f).abs : fs
        ann = annotation_like_label?(item.text, bbox_w, bbox_h)
        if slope_triangle_label?(item.text, bbox_w, bbox_h, angle_deg)
          ((by0 + by1) * 0.5) - (fs * 0.35)
        elsif dimension_like_label?(item.text) && bbox_h > fs * 1.25 &&
              !feet_inch_dimension_label?(item.text)
          # Stacked-fraction dimensions: alphabetic baseline hugs bbox bottom.
          by0 + fs * 0.12
        elsif rotated_part_mark_label?(item) || diagonal_part_mark_label?(item)
          by0 + fs * 0.15
        elsif ann ||
              (dimension_like_label?(item.text) && raw_angle.abs >= 12.0 && raw_angle.abs < 85.0)
          # Weld/fraction callouts: anchor near bbox bottom regardless of PDF tilt.
          by0 + [bbox_h * 0.18, fs * 0.18].min
        else
          by0 + [bbox_h * ratio, fs * 0.18].min
        end
      rescue StandardError
        by0.to_f
      end

      def label_angle_pdf(item)
        angle = item.respond_to?(:angle) ? item.angle.to_f : 0.0
        bbox_w = label_has_bbox?(item) ? (item.bbox_x1.to_f - item.bbox_x0.to_f).abs : nil
        bbox_h = label_has_bbox?(item) ? (item.bbox_y1.to_f - item.bbox_y0.to_f).abs : nil
        return 0.0 if annotation_like_label?(item.text, bbox_w, bbox_h)
        if part_mark_label?(item.text)
          inferred = inferred_part_mark_angle_pdf(item)
          return inferred if inferred
          if rotated_part_mark_label?(item)
            return 90.0 if angle > 0.0
            return -90.0
          end
          return angle if diagonal_part_mark_label?(item)
          return 0.0
        end
        if dimension_like_label?(item.text)
          fs = effective_font_size_pts(item)
          if bbox_w && bbox_h && vertical_dimension_bbox?(item, bbox_w, bbox_h) &&
             !narrow_fraction_dimension_stays_horizontal?(item.text, bbox_w, bbox_h, fs, angle)
            return 90.0
          end
          return 0.0 if angle.abs < 12.0
          return angle
        end
        angle.abs < 12.0 ? 0.0 : angle
      rescue StandardError
        0.0
      end

      def inferred_part_mark_angle_pdf(item)
        return nil unless part_mark_label?(item.text)
        return nil unless label_has_bbox?(item)
        angle = item.respond_to?(:angle) ? item.angle.to_f : 0.0
        return normalize_text_angle_deg(angle) if angle.abs >= 12.0
        return nil unless angle_member_mark_label?(item.text)
        nearest_diagonal_text_angle(item)
      rescue StandardError
        nil
      end

      def nearest_diagonal_text_angle(item)
        segments = text_angle_segments
        return nil if segments.empty?

        bx0 = item.bbox_x0.to_f
        bx1 = item.bbox_x1.to_f
        by0 = item.bbox_y0.to_f
        by1 = item.bbox_y1.to_f
        cx = (bx0 + bx1) * 0.5
        cy = (by0 + by1) * 0.5
        bw = (bx1 - bx0).abs
        bh = (by1 - by0).abs
        radius = [[bw, bh].max * 1.25, effective_font_size_pts(item) * 2.0, 18.0].max

        best = nil
        segments.each do |seg|
          next if cx < seg[:min_x] - radius || cx > seg[:max_x] + radius
          next if cy < seg[:min_y] - radius || cy > seg[:max_y] + radius
          dist = point_segment_distance(cx, cy, seg[:x0], seg[:y0], seg[:x1], seg[:y1])
          next if dist > radius

          # Prefer close, longer member lines over tiny arrow ticks or hatch marks.
          score = dist - [[seg[:length], 90.0].min * 0.015]
          best = [score, seg] if best.nil? || score < best[0]
        end

        best ? best[1][:angle] : nil
      rescue StandardError
        nil
      end

      def text_angle_segments
        return @text_angle_segments if @text_angle_segments

        @text_angle_segments = []
        Array(@paths).each do |path|
          next if path.respond_to?(:stroke) && !path.stroke
          Array(path.subpaths).each do |subpath|
            pts = subpath_to_points(subpath)
            pts.each_cons(2) do |p0, p1|
              x0, y0 = point_xy(p0)
              x1, y1 = point_xy(p1)
              next unless x0 && y0 && x1 && y1
              dx = x1 - x0
              dy = y1 - y0
              length = Math.sqrt((dx * dx) + (dy * dy))
              next if length < 8.0
              angle = normalize_text_angle_deg(Math.atan2(dy, dx) * 180.0 / Math::PI)
              abs_angle = angle.abs
              next if abs_angle < 15.0 || abs_angle > 75.0
              @text_angle_segments << {
                x0: x0, y0: y0, x1: x1, y1: y1, length: length,
                angle: angle, min_x: [x0, x1].min, max_x: [x0, x1].max,
                min_y: [y0, y1].min, max_y: [y0, y1].max
              }
            end
          end
        end
        @text_angle_segments
      rescue StandardError
        @text_angle_segments = []
      end

      def point_xy(point)
        if point.respond_to?(:x) && point.respond_to?(:y)
          [point.x.to_f, point.y.to_f]
        elsif point.respond_to?(:[])
          [point[0].to_f, point[1].to_f]
        else
          [nil, nil]
        end
      rescue StandardError
        [nil, nil]
      end

      def normalize_text_angle_deg(angle)
        a = angle.to_f
        a += 180.0 while a <= -90.0
        a -= 180.0 while a > 90.0
        a
      rescue StandardError
        0.0
      end

      def point_segment_distance(px, py, x0, y0, x1, y1)
        dx = x1 - x0
        dy = y1 - y0
        len2 = (dx * dx) + (dy * dy)
        return Math.sqrt(((px - x0) ** 2) + ((py - y0) ** 2)) if len2 <= 1.0e-9
        t = (((px - x0) * dx) + ((py - y0) * dy)) / len2
        t = [[t, 0.0].max, 1.0].min
        qx = x0 + (t * dx)
        qy = y0 + (t * dy)
        Math.sqrt(((px - qx) ** 2) + ((py - qy) ** 2))
      rescue StandardError
        Float::INFINITY
      end

      def label_run_width_pts(text, font_size_pts, bbox_w_pts = nil, bbox_h_pts = nil)
        fs = [font_size_pts.to_f, 1.0].max
        raw = if dimension_like_label?(text)
                dimension_label_raw_width_pts(text, fs)
              elsif chord_spec_label?(text)
                feet_inch_label_width_pts(text, fs)
              else
                text.to_s.strip.length * fs * 0.55
              end
        limit = [bbox_w_pts.to_f, bbox_h_pts.to_f].max
        limit > 0.0 ? [raw, limit * 0.96].min : raw
      rescue StandardError
        [font_size_pts.to_f * 0.55, 1.0].max
      end

      def rotated_bbox_text_origin_pdf(item, bx0, by0, bx1, by1, fs, angle)
        bw = (bx1 - bx0).abs
        bh = (by1 - by0).abs
        run_w = label_run_width_pts(item.text, fs, bw, bh)
        rad = angle.to_f * Math::PI / 180.0
        dir_x = Math.cos(rad)
        dir_y = Math.sin(rad)
        norm_x = -dir_y
        norm_y = dir_x
        cx = (bx0 + bx1) * 0.5
        cy = (by0 + by1) * 0.5
        baseline_offset = fs.to_f * 0.18
        [
          cx - (dir_x * run_w * 0.5) - (norm_x * baseline_offset),
          cy - (dir_y * run_w * 0.5) - (norm_y * baseline_offset)
        ]
      rescue StandardError
        [bx0.to_f, by0.to_f]
      end

      def vertical_dimension_bbox?(item, bbox_w_pts, bbox_h_pts)
        return false if annotation_like_label?(item.text, bbox_w_pts, bbox_h_pts)
        return false if stacked_vertical_dimension_labels?(item)
        return false unless dimension_like_label?(item.text)
        bw = bbox_w_pts.to_f
        bh = bbox_h_pts.to_f
        bw > 0.5 && bh > bw * 1.6
      rescue StandardError
        false
      end

      def rotated_bbox_text_origin?(item, bbox_w_pts, bbox_h_pts, angle_deg)
        return false if annotation_like_label?(item.text, bbox_w_pts, bbox_h_pts)
        if tall_single_text_bbox?(item, bbox_w_pts, bbox_h_pts)
          return angle_needs_geometry_text?(angle_deg, 3.0)
        end
        return false unless part_mark_label?(item.text) || dimension_like_label?(item.text)
        angle_needs_geometry_text?(angle_deg, 3.0)
      rescue StandardError
        false
      end

      # Left anchor for add_3d_text when label_insertion_pdf returns a centered X.
      def mesh_label_anchor_pdf(item)
        label_x, label_y, label_angle = text_insertion_pdf(item)
        return [label_x, label_y, label_angle] unless label_has_bbox?(item)

        bx0 = item.bbox_x0.to_f
        return [label_x, label_y, label_angle] if (label_x - bx0).abs <= 0.25

        fs = effective_font_size_pts(item)
        bbox_w = (item.bbox_x1.to_f - bx0).abs
        bbox_h = (item.bbox_y1.to_f - item.bbox_y0.to_f).abs
        run_w = label_run_width_pts(item.text, fs, bbox_w, bbox_h)
        [label_x - (run_w * 0.5), label_y, label_angle]
      rescue StandardError
        text_insertion_pdf(item)
      end

      def matrix_origin_insertion?(item, angle_deg)
        return false unless external_text_item?(item)
        return false unless label_has_bbox?(item)
        return false if angle_deg.to_f.abs < 8.0
        bx0 = item.bbox_x0.to_f
        by0 = item.bbox_y0.to_f
        (item.x.to_f - bx0).abs > 0.5 || (item.y.to_f - by0).abs > 0.5
      rescue StandardError
        false
      end

      # Returns [x_pdf, y_pdf, angle_deg] for label insertion.
      def label_insertion_pdf(item)
        angle = label_angle_pdf(item)
        x = item.x.to_f
        y = item.y.to_f
        fs = effective_font_size_pts(item)

        if label_has_bbox?(item)
          bx0 = item.bbox_x0.to_f
          by0 = item.bbox_y0.to_f
          bx1 = item.bbox_x1.to_f
          by1 = item.bbox_y1.to_f
          bbox_h = (by1 - by0).abs
          bbox_w = (bx1 - bx0).abs
          if matrix_origin_insertion?(item, angle)
            return [item.x.to_f, item.y.to_f, angle]
          end
          used_rotated_origin = false
          if rotated_bbox_text_origin?(item, bbox_w, bbox_h, angle)
            x, y = rotated_bbox_text_origin_pdf(item, bx0, by0, bx1, by1, fs, angle)
            used_rotated_origin = true
          elsif slope_triangle_label?(item.text, bbox_w, bbox_h, angle)
            est_w = dimension_label_est_width_pts(item.text, fs, bbox_w)
            x = ((bx0 + bx1) * 0.5) - (est_w * 0.5)
          elsif should_center_dimension_label?(item.text, bbox_w, bbox_h, fs, angle)
            est_w = dimension_label_est_width_pts(item.text, fs, bbox_w)
            x = ((bx0 + bx1) * 0.5) - (est_w * 0.5)
          elsif should_center_spec_label?(item.text, bbox_w, bbox_h, fs, angle)
            est_w = spec_label_width_pts(item.text, fs, bbox_w)
            x = ((bx0 + bx1) * 0.5) - (est_w * 0.5)
          elsif rotated_part_mark_label?(item) ||
                (diagonal_part_mark_label?(item) && narrow_part_mark_bbox?(bbox_w, bbox_h))
            est_w = dimension_label_est_width_pts(item.text, fs, bbox_w)
            x = ((bx0 + bx1) * 0.5) - (est_w * 0.5)
          elsif should_center_label?(item.text, bbox_w, fs, angle)
            est_w = item.text.to_s.strip.length * fs * 0.55
            x = ((bx0 + bx1) * 0.5) - (est_w * 0.5)
          else
            x = bx0
          end
          y = label_baseline_pdf_y(item, by0, by1, bbox_h, angle) unless used_rotated_origin
        elsif external_text_item?(item)
          bbox_h = [fs, 1.0].max
          y = y + bbox_h * label_baseline_ratio(angle)
        end

        [x, y, angle]
      rescue StandardError
        [item.x.to_f, item.y.to_f, label_angle_pdf(item)]
      end

      # SketchUp 2017 label text expects a zero direction vector for horizontal
      # annotation text. Non-zero unit vectors are reserved for rotated labels.
      def label_direction_vector(angle_deg, item = nil)
        text = item ? item.text : nil
        tol = part_mark_label?(text) ? 8.0 : 12.0
        return Geom::Vector3d.new(0, 0, 0) unless angle_needs_geometry_text?(angle_deg, tol)
        label_text_vector(angle_deg)
      rescue StandardError
        Geom::Vector3d.new(0, 0, 0)
      end

      def label_text_vector(angle_deg)
        rad = angle_deg.to_f * Math::PI / 180.0
        Geom::Vector3d.new(Math.cos(rad), Math.sin(rad), 0.0)
      rescue StandardError
        Geom::Vector3d.new(0, 0, 0)
      end

      # Non-horizontal labels use a direction vector for add_text when |angle| exceeds
      # this threshold. Tunable via BC_SU_ROTATED_LABEL_DEG for troubleshooting.
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

      def resolve_layer(pdf_layer_name)
        if @layer_manager
          layer = @layer_manager.resolve(pdf_layer_name)
          return layer if layer
        end
        get_or_create_layer(@layer_name)
      end

      def text_fallback_layer
        if @layer_manager
          layer = @layer_manager.text_fallback_layer
          return layer if layer
        end
        get_or_create_layer("#{@layer_name}:Text")
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
