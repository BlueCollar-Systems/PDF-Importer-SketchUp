# bc_pdf_vector_importer/geometry_builder.rb
# Converts parsed PDF vector paths into native SketchUp geometry.
# v2: Arc reconstruction, color-based tag grouping, dash pattern mapping,
# line width tracking, text placement, and progress feedback.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'page_transform')
require File.join(File.dirname(__FILE__), 'representation_fidelity')
require File.join(File.dirname(__FILE__), 'import_run_control')
require 'digest'

module BlueCollarSystems
  module PDFVectorImporter
    class GeometryBuilder

      PDF_POINT_TO_INCH = 1.0 / 72.0
      CLOSE_TOL = 1e-6
      # Stage into isolated groups before explode once path count is high.
      # Gate 0 REMEDIATE: restore reviewed 500/250/100 policy until a host
      # explode/merge identity matrix certifies any lower threshold.
      GEOMETRY_STAGING_PATH_THRESHOLD = 500
      GEOMETRY_STAGING_CHUNK_PATHS = 250
      SMALL_FACE_DIRECT_MAX_EXTENT = 0.002
      SMALL_FACE_CONSTRUCTION_SCALE = 1000.0

      attr_reader :page_group, :text_group, :text_delivery_failures,
                  :text_attempts

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
        @requested_text_mode = normalize_text_mode_symbol(opts[:requested_text_mode]) ||
                               (@use_3d_text ? :text3d : :labels)
        @strict_text_fidelity = opts[:strict_text_fidelity] || false
        # Native add_3d_text is opt-in only. The resolver must independently
        # prove that the installed family is the exact PDF source family.
        @native_font_identity_resolver = opts[:native_font_identity_resolver]
        @target_entities = opts[:target_entities] || nil
        @y_offset        = opts[:y_offset] || 0.0
        @page_rotation   = PageTransform.normalize_rotation(opts[:page_rotation])
        @provenance_bucket = opts[:provenance_bucket]
        @provenance_bucket = [] unless @provenance_bucket.is_a?(Array)
        @import_session_id = opts[:import_session_id].to_s
        @progress_callback = opts[:progress_callback]
        @run_controller = opts[:run_controller]

        @edge_count = 0
        @face_count = 0
        @arc_count  = 0
        @text_count = 0
        @text_height_samples = []
        @text_height_fallback_count = 0
        # Round 22 width-fidelity telemetry (extra.text_width_crosscheck).
        @text_width_factor_samples = []
        @text_width_out_of_bounds_count = 0
        @text_width_skipped_near_1_count = 0
        @text_width_error_count = 0
        # A per-span requested-mode failure is passed upward for an atomic,
        # explicit stop; it is never permission to substitute representations.
        @text_delivery_failures = []
        @text_attempts = []
        @geometry_staging = disabled_geometry_staging
        @deferred_small_face_batches = {}
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
        heavy_page = @paths.length >= GEOMETRY_STAGING_PATH_THRESHOLD
        emit_progress(
          :geometry_started,
          :path_count => @paths.length,
          :heavy_page => heavy_page
        )
        configure_geometry_staging!(heavy_page)
        path_yield_every = heavy_page ? 100 : 0
        @paths.each_with_index do |path, path_idx|
          if (path_idx % 100).zero?
            run_checkpoint!(
              :geometry_path,
              :completed => path_idx,
              :total => @paths.length,
              :page => @page_number
            )
          end
          if path_yield_every > 0 && (path_idx % path_yield_every).zero?
            Sketchup.status_text = "PDF Import — building geometry (#{path_idx}/#{@paths.length} paths)..."
          end

          next unless path.subpaths && !path.subpaths.empty?

          should_stroke = path.stroke
          should_fill = path.fill && @import_fills
          next unless should_stroke || should_fill

          # Skip only simple fill-only page backgrounds. Stroked page-sized
          # paths are often real sheet borders or title-block frames and must
          # be preserved for drawing accuracy.
          path_bbox = compute_path_bbox(path)
          if path_bbox && discardable_page_artifact?(path, path_bbox, page_area_pts)
            next
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
            draw_dest = staged_geometry_target(dest, path_idx)

            # Arc reconstruction on the polyline
            # A filled PDF contour is authoritative as one exact sampled
            # boundary. Replacing part of it with fitted SketchUp arcs before
            # add_face makes the live edge loop disagree with the face points;
            # SketchUp 2017 then rejects many valid planar fills. Preserve the
            # exact source boundary for fills and reserve editable arc fitting
            # for unfilled stroke geometry.
            if @detect_arcs && !should_fill && dash_spec.nil? &&
               su_points.length >= 5
              draw_with_arc_detection(draw_dest, su_points, path_layer, dash_layer, dash_spec, subpath.closed, should_fill, path.fill_color)
            else
              draw_edges(draw_dest, su_points, path_layer, dash_layer, dash_spec, subpath.closed)
              if should_fill && subpath.closed && su_points.length >= 3
                draw_face(draw_dest, su_points, path_layer, path.fill_color)
              end
            end
          end
        end
        run_checkpoint!(
          :geometry_path,
          :completed => @paths.length,
          :total => @paths.length,
          :page => @page_number
        )
        finalize_geometry_staging!
        flush_deferred_small_faces!
        emit_progress(
          :geometry_completed,
          :path_count => @paths.length,
          :edges => @edge_count,
          :faces => @face_count
        )

        # ── Text objects ──
        emit_progress(
          :text_started,
          :text_item_count => @text_items.length,
          :requested_text_mode => @requested_text_mode
        )
        if @import_text && !@text_items.empty?
          prepare_bom_table_context(@text_items)
          text_group = nil
          if @page_group
            text_group = @page_group.entities.add_group
            text_group.name = "Text"
            set_layer(text_group, base_layer)
            @text_group = text_group
          end
          text_target = text_group ? text_group.entities : target

          @text_items.each_with_index do |item, text_index|
            run_checkpoint!(
              :text_item,
              :completed => text_index,
              :total => @text_items.length,
              :page => @page_number
            )
            source_span_id = if item.respond_to?(:source_span_id)
                               item.source_span_id.to_s
                             else
                               ''
                             end
            progress_detail = {
              :text_index => text_index,
              :text_item_count => @text_items.length,
              :source_span_id => source_span_id,
              :source_text_sha256 => Digest::SHA256.hexdigest(item.text.to_s)
            }
            emit_progress(:text_item_started, progress_detail)
            item_layer = if @layer_manager && @layer_manager.match_pdf_layers
                           resolve_layer(item.respond_to?(:layer_name) ? item.layer_name : nil)
                         else
                           text_fallback_layer
                         end
            place_text(text_target, item, page_origin_x, page_origin_y, page_height, item_layer)
            run_checkpoint!(
              :text_item,
              :completed => text_index + 1,
              :total => @text_items.length,
              :page => @page_number
            )
            emit_progress(:text_item_completed, progress_detail)
          end
        end
        emit_progress(
          :text_completed,
          :text_item_count => @text_items.length,
          :text_objects => @text_count
        )
        emit_progress(
          :build_completed,
          :edges => @edge_count,
          :faces => @face_count,
          :text_objects => @text_count
        )

        {
          edges: @edge_count,
          faces: @face_count,
          arcs: @arc_count,
          text_objects: @text_count,
          text_height_samples: Array(@text_height_samples),
          text_height_fallback_count: @text_height_fallback_count.to_i,
          text_width_factor_samples: Array(@text_width_factor_samples),
          text_width_out_of_bounds_count: @text_width_out_of_bounds_count.to_i,
          text_width_skipped_near_1_count: @text_width_skipped_near_1_count.to_i,
          text_width_error_count: @text_width_error_count.to_i,
          text_delivery_failures: Array(@text_delivery_failures),
          text_attempts: Array(@text_attempts),
          source_provenance_objects: Array(@provenance_bucket),
          geometry_staging: geometry_staging_metrics
        }
      end

      private

      def emit_progress(phase, detail = {})
        callback = @progress_callback
        return false unless callback.respond_to?(:call)
        callback.call(phase, detail)
        true
      rescue ImportRunControl::ImportCancelled
        raise
      rescue StandardError => e
        Logger.warn(
          'GeometryBuilder',
          "progress callback #{phase} failed: #{e.message}"
        )
        false
      end

      def run_checkpoint!(stage, detail)
        controller = @run_controller
        return false unless controller && controller.respond_to?(:checkpoint!)
        controller.checkpoint!(stage, detail)
        true
      end

      def disabled_geometry_staging
        {
          :enabled => false,
          :groups => [],
          :parents => {},
          :stable_targets => {},
          :batch_count => 0,
          :explode_count => 0,
          :exploded_entity_count => 0,
          :explode_ms => 0.0
        }
      end

      def configure_geometry_staging!(heavy_page)
        @geometry_staging = disabled_geometry_staging
        @geometry_staging[:enabled] = heavy_page == true
      end

      def staged_geometry_target(parent_entities, path_index)
        staging = @geometry_staging
        return parent_entities unless staging[:enabled]
        unless parent_entities.respond_to?(:add_group)
          staging[:enabled] = false
          return parent_entities
        end

        key = parent_entities.object_id
        slot = staging[:parents][key]
        new_path = slot.nil? || slot[:last_path_index] != path_index
        if slot.nil? || (new_path &&
                         slot[:path_count] >= GEOMETRY_STAGING_CHUNK_PATHS)
          group = parent_entities.add_group
          unless group && group.respond_to?(:entities) &&
                 group.respond_to?(:explode)
            raise 'host cannot create an exact bulk geometry staging group'
          end
          group.name = "PDF Geometry Batch #{staging[:batch_count] + 1}" if
            group.respond_to?(:name=)
          slot = {
            :group => group,
            :path_count => 0,
            :last_path_index => nil
          }
          staging[:parents][key] = slot
          staging[:groups] << group
          staging[:stable_targets][group.entities.object_id] = parent_entities
          staging[:batch_count] += 1
          new_path = true
        end
        if new_path
          slot[:path_count] += 1
          slot[:last_path_index] = path_index
        end
        slot[:group].entities
      end

      def finalize_geometry_staging!
        staging = @geometry_staging
        return true unless staging[:enabled]
        staging[:groups].each do |group|
          started = builder_monotonic_ms
          exploded = group.explode
          unless exploded.is_a?(Array)
            raise 'host rejected exact bulk geometry staging merge'
          end
          staging[:explode_count] += 1
          staging[:exploded_entity_count] += exploded.length
          staging[:explode_ms] += builder_monotonic_ms - started
        end
        staging[:groups] = []
        staging[:parents] = {}
        staging[:stable_targets] = {}
        true
      end

      def geometry_staging_metrics
        staging = @geometry_staging
        {
          :enabled => staging[:enabled] == true,
          :path_threshold => GEOMETRY_STAGING_PATH_THRESHOLD,
          :chunk_path_limit => GEOMETRY_STAGING_CHUNK_PATHS,
          :batch_count => staging[:batch_count].to_i,
          :explode_count => staging[:explode_count].to_i,
          :exploded_entity_count => staging[:exploded_entity_count].to_i,
          :explode_ms => staging[:explode_ms].to_f.round(3)
        }
      end

      def builder_monotonic_ms
        if Process.respond_to?(:clock_gettime) &&
           defined?(Process::CLOCK_MONOTONIC)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
        else
          Time.now.to_f * 1000.0
        end
      end

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
      # Cheap pre-screen for draw_face: a loop with fewer than 3 distinct
      # vertices or ~zero enclosed area can never become a SketchUp face.
      # add_face would reject these with "Points are not planar" — but only
      # after a C-side check + a raised exception we rescue and log, hundreds
      # of times on dense fabrication fills. Screening here is accuracy-neutral
      # (these never produced a face) and removes the exception + log cost.
      #
      # Returns the cleaned, co-planar, closed loop of points to pass to
      # entities.add_face, or nil if the loop cannot become a face. The
      # caller must use the returned loop; passing the original points would
      # re-introduce the duplicate/degenerate points we just removed.
      def build_face_loop(points)
        return nil if points.nil? || points.length < 3
        # 1. Remove consecutive near-duplicate points.
        uniq = []
        points.each do |p|
          if uniq.empty? || p.distance(uniq.last) >= @merge_tol
            uniq << p
          end
        end
        # 2. Remove a closing point that duplicates the start.
        if uniq.length > 1 && uniq.first.distance(uniq.last) < @merge_tol
          uniq.pop
        end
        return nil if uniq.length < 3
        # 3. Ensure all points are co-planar in the XY plane. Imported geometry
        # is supposed to be z=0, but tolerate tiny numerical drift.
        z_vals = uniq.map { |p| p.z.to_f }
        z_min = z_vals.min
        z_max = z_vals.max
        return nil if (z_max - z_min) > 1.0e-5
        # 4. Build a fresh flat loop for add_face so the C-side planar test
        # sees clean, consistent coordinates. In standalone test environments
        # Geom::Point3d is not loaded, so keep the cleaned test points.
        flat = if defined?(Geom) && defined?(Geom::Point3d)
                uniq.map { |p| Geom::Point3d.new(p.x.to_f, p.y.to_f, 0.0) }
              else
                uniq
              end
        # 5. Shoelace area in the XY plane.
        area2 = 0.0
        n = flat.length
        n.times do |i|
          a = flat[i]; b = flat[(i + 1) % n]
          area2 += (a.x.to_f * b.y.to_f) - (b.x.to_f * a.y.to_f)
        end
        return nil if (area2.abs * 0.5) <= 1.0e-6
        flat
      rescue StandardError
        nil
      end

      def face_buildable?(points)
        !build_face_loop(points).nil?
      end

      def draw_face(entities, points, layer, fill_rgb = nil)
        return false if points.length < 3
        clean = build_face_loop(points)
        return false unless clean
        if face_loop_max_extent(clean) < SMALL_FACE_DIRECT_MAX_EXTENT
          return draw_scaled_face_instance(entities, clean, layer, fill_rgb)
        end
        begin
          face = entities.add_face(clean)
          if face
            style_face(face, layer, fill_rgb)
            @face_count += 1
            return true
          end
          false
        rescue StandardError => e
          if e.message.to_s.include?('Points are not planar') &&
             face_loop_max_extent(clean) < 0.01
            begin
              return true if draw_scaled_face_instance(
                entities, clean, layer, fill_rgb
              )
            rescue StandardError
              # Report the original host rejection below; it is the most
              # actionable error if the exact scaled construction also fails.
            end
          end
          Logger.warn("GeometryBuilder", "draw_face failed: #{e.message}")
          false
        end
      end

      def face_loop_max_extent(points)
        xs = points.map { |point| point.x.to_f }
        ys = points.map { |point| point.y.to_f }
        [(xs.max - xs.min).abs, (ys.max - ys.min).abs].max
      end

      def draw_scaled_face_instance(entities, points, layer, fill_rgb)
        unless entities.respond_to?(:add_instance) &&
               @model.respond_to?(:definitions) &&
               @model.definitions.respond_to?(:add) &&
               defined?(Geom::Transformation)
          raise 'host cannot create exact sub-tolerance fill geometry'
        end
        stable_entities =
          @geometry_staging[:stable_targets][entities.object_id] || entities
        key = small_face_batch_key(stable_entities, layer, fill_rgb)
        batch = @deferred_small_face_batches[key]
        unless batch
          batch = {
            :entities => stable_entities,
            :layer => layer,
            :fill_rgb => Array(fill_rgb),
            :loops => []
          }
          @deferred_small_face_batches[key] = batch
        end
        batch[:loops] << points.map do |point|
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end
        @face_count += 1
        true
      end

      # SketchUp 2017 rejects valid filled contours below its native face
      # tolerance. Building each contour at a safe scale and retaining one
      # inverse-scaled component instance is exact, but hundreds of tiny
      # instances can destabilize the legacy host. Batch all contours that
      # share one destination and style into a single definition/instance.
      def flush_deferred_small_faces!
        batches = @deferred_small_face_batches.values
        @deferred_small_face_batches = {}
        batches.each { |batch| draw_scaled_face_batch(batch) }
        true
      end

      def draw_scaled_face_batch(batch)
        entities = batch[:entities]
        loops = Array(batch[:loops])
        raise 'sub-tolerance fill batch has no contours' if loops.empty?
        origin_values = loops.first.first
        raise 'sub-tolerance fill batch has no origin' unless origin_values
        origin = Geom::Point3d.new(
          origin_values[0], origin_values[1], origin_values[2]
        )
        definition = nil
        begin
          factor = SMALL_FACE_CONSTRUCTION_SCALE
          definition = @model.definitions.add(
            "PDF Micro Fill Batch #{small_face_batch_digest(batch)[0, 12]}"
          )
          loops.each do |points|
            large = points.map do |point|
              Geom::Point3d.new(
                (point[0] - origin_values[0]) * factor,
                (point[1] - origin_values[1]) * factor,
                (point[2] - origin_values[2]) * factor
              )
            end
            face = definition.entities.add_face(large)
            raise 'scaled sub-tolerance construction returned no face' unless face
            style_face(face, batch[:layer], batch[:fill_rgb])
          end
          inverse_factor = 1.0 / factor
          transformation =
            Geom::Transformation.translation(origin) *
            Geom::Transformation.scaling(
              inverse_factor, inverse_factor, inverse_factor
            )
          instance = entities.add_instance(definition, transformation)
          raise 'host returned no sub-tolerance fill instance' unless instance
          set_layer(instance, batch[:layer])
          true
        rescue StandardError
          begin
            if definition && @model.definitions.respond_to?(:remove)
              @model.definitions.remove(definition)
            end
          rescue StandardError
          end
          raise
        end
      end

      def small_face_batch_key(entities, layer, fill_rgb)
        color = Array(fill_rgb).map do |value|
          format('%.9f', value.to_f)
        end.join(',')
        layer_name = if layer.respond_to?(:name)
                       layer.name.to_s
                     else
                       layer.to_s
                     end
        [entities.object_id, layer_name, color].join('|')
      end

      def small_face_batch_digest(batch)
        geometry = Array(batch[:loops]).map do |points|
          points.map do |point|
            point.map { |value| format('%.12f', value.to_f) }.join(',')
          end.join(';')
        end.join('|')
        Digest::SHA256.hexdigest(geometry)
      end

      def style_face(face, layer, fill_rgb)
        # Keep imported sheet faces consistently front-facing in top view.
        face.reverse! if face.normal.z < 0
        set_layer(face, layer)
        if fill_rgb && fill_rgb.is_a?(Array) && fill_rgb.length >= 3
          material = get_or_create_material(fill_rgb)
          face.material = material
          face.back_material = material
        end
        face
      end

      # ---------------------------------------------------------------
      # Text placement
      # ---------------------------------------------------------------
      def place_text(entities, item, origin_x, origin_y, page_height, layer)
        return unless @import_text && item.text && !item.text.to_s.empty?

        begin
          if @use_3d_text
            place_mesh_text(
              entities, item, origin_x, origin_y, layer, @requested_text_mode
            )
          elsif @requested_text_mode != :text &&
                stacked_vertical_dimension_labels?(item)
            # Stacked vertical dimension numeral splitting creates sub-items
            # that share the parent source_span_id. That is safe for native
            # Labels and 3D Text, but flat Text mode binds one proof per
            # source_span_id and therefore requires the whole span as a single
            # native Text entity.
            place_stacked_vertical_dimension_labels(
              entities, item, origin_x, origin_y, layer
            )
          else
            place_annotation_label(
              entities, item, origin_x, origin_y, layer, @requested_text_mode
            )
          end
        rescue RepresentationFidelity::ContractError => e
          # Identity/snapshot failures make item ownership unknowable.  The
          # enclosing SketchUp operation must abort; an item fallback here
          # could leave an unowned partial artifact behind.
          raise e
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "place_text failed: #{e.message}")
          record_text_delivery_failure(
            @requested_text_mode, 'text_placement_exception', item
          )
          false
        end
      end

      # Shared PDF insertion point for Labels — matches label heuristics
      # used by the external pdftotext path (bbox centering, baseline, angle cleanup).
      def text_insertion_pdf(item)
        label_insertion_pdf(item)
      end

      # 3D text mesh anchor — the bottom-left (baseline) of the generated mesh.
      # add_3d_text draws the text along +x and upward along +y, so the mesh origin
      # is the baseline. For rotated items the anchor is the bbox baseline-left,
      # obtained by shifting the bbox center by half the mesh height along the
      # normal (not the small label-baseline offset used for add_text).
      # Labels and 3D Text must share this PDF insertion point (TEXTMODE-1).
      def mesh_text_insertion_pdf(item)
        label_insertion_pdf(item, true)
      rescue StandardError
        label_insertion_pdf(item, true)
      end

      TEXT_FACE_RGB = [0.0, 0.0, 0.0].freeze

      # SketchUp's add_3d_text letter_height is NOT a PDF em. For Arial-family
      # faces SketchUp 2017 normalizes outlines to the typographic ascender
      # (1491/2048). Passing the PDF em directly therefore inflates ink by
      # ~37% and drives title-block / dense-callout collisions. Convert once
      # into SketchUp's letter-height domain; keep SIZE-1 (nominal source size,
      # never bbox-fit height).
      ARIAL_LETTER_HEIGHT_TO_EM = 1491.0 / 2048.0
      ROMANT_LETTER_HEIGHT_TO_EM = 1538.0 / 2048.0

      def mesh_text_pdf_em_height_inches(item)
        fs_pts = item.font_size.to_f
        return nil unless fs_pts.finite? && fs_pts > 0.0
        height = fs_pts * PDF_POINT_TO_INCH * @scale
        return nil unless height.finite? && height > 0.0
        height
      end

      def mesh_text_letter_height_ratio(item)
        name = ''
        begin
          name = item.font_name.to_s if item.respond_to?(:font_name)
        rescue StandardError
          name = ''
        end
        key = name.to_s.downcase
        return ROMANT_LETTER_HEIGHT_TO_EM if key.include?('romant')
        ARIAL_LETTER_HEIGHT_TO_EM
      end

      def mesh_text_height_inches(item, _angle_deg, _page_h)
        em = mesh_text_pdf_em_height_inches(item)
        return nil unless em
        height = em * mesh_text_letter_height_ratio(item)
        return nil unless height.finite? && height > 0.0
        height
      rescue StandardError => e
        @text_height_fallback_count = @text_height_fallback_count.to_i + 1
        Logger.warn('GeometryBuilder',
                    "mesh text source height is unverifiable (#{e.class}: #{e.message})")
        nil
      end

      def verified_native_font_identity(item)
        resolver = @native_font_identity_resolver
        return nil unless resolver.respond_to?(:call)
        evidence = resolver.call(item)
        return nil unless evidence.is_a?(Hash)
        source_id = RepresentationFidelity.source_span_id(item)
        return nil unless evidence[:source_span_id].to_s == source_id
        return nil unless evidence[:verified] == true
        return nil unless evidence[:exact_family_match] == true
        source_font = evidence[:pdf_font_identity].to_s.strip
        family = evidence[:installed_family].to_s.strip
        return nil if source_font.empty? || family.empty?
        {
          :source_span_id => source_id,
          :pdf_font_identity => source_font,
          :installed_family => family,
          :verified => true,
          :exact_family_match => true
        }
      rescue StandardError => e
        Logger.warn('GeometryBuilder',
                    "native font identity proof failed: #{e.message}")
        nil
      end

      def native_text_extrusion_depth(height)
        value = [height.to_f * 0.08, 1.0e-4].max
        return nil unless value.finite? && value > 0.0
        value
      rescue StandardError
        nil
      end

      def record_mesh_text_height_sample(height)
        @text_height_samples ||= []
        @text_height_samples << height.to_f
      rescue StandardError
        nil
      end

      def text_height_samples
        Array(@text_height_samples)
      rescue StandardError
        []
      end

      # ---------------------------------------------------------------
      # The PDF's declared text run and source font size are the authoritative
      # width and height targets. Fresh host geometry is measured, fitted on
      # both axes, then measured again after placement and source rotation.
      # ---------------------------------------------------------------

      # Recover the declared run length from the source AABB at any angle. The
      # known PDF text height supplies the cross-axis extent; the least-squares
      # projection is well-defined at diagonal angles (including 45 degrees).
      def mesh_text_declared_run_width_inches(item, display_angle)
        values = []
        [:bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1].each do |name|
          return nil unless item.respond_to?(name)
          value = item.send(name)
          return nil if value.nil?
          value = value.to_f
          return nil unless value.finite?
          values << value
        end
        return nil if (values[2] - values[0]).abs <= 1.0e-9
        return nil if (values[3] - values[1]).abs <= 1.0e-9

        box = PageTransform.transform_bbox(
          values[0], values[1], values[2], values[3], @media_box, @page_rotation
        )
        box_width = (box[2] - box[0]).abs
        box_height = (box[3] - box[1]).abs
        height_points = item.font_size.to_f
        return nil unless height_points.finite? && height_points > 0.0
        radians = PageTransform.normalize_angle(display_angle).to_f.abs * Math::PI / 180.0
        cosine = Math.cos(radians).abs
        sine = Math.sin(radians).abs
        points = (cosine * (box_width - (sine * height_points))) +
                 (sine * (box_height - (cosine * height_points)))
        return nil unless points.finite? && points > 0.0
        width = points * PDF_POINT_TO_INCH * @scale
        return nil unless width.finite? && width > 0.0
        width
      rescue StandardError
        nil
      end

      def record_text_width_factor_sample(factor)
        @text_width_factor_samples ||= []
        @text_width_factor_samples << factor.to_f
      rescue StandardError
        nil
      end

      # One attempt ledger per certified source span. A failed rung is never
      # permission to change representation without separate affirmative,
      # item-specific impossibility evidence.
      def begin_text_attempt(item, requested_mode)
        source_id = RepresentationFidelity.source_span_id(item)
        normalized_mode = normalize_text_mode_symbol(requested_mode)
        source_bbox = if normalized_mode == :text
                        # The SU2017 flat-Text capability proof is bound to the
                        # exact canonical source box. Other representations may
                        # still attempt and then fail closed when a PDF span has
                        # no usable box, preserving their cleanup ledger.
                        RepresentationFidelity.strict_source_bbox_pdf(item)
                      else
                        item_source_bbox_pdf(item)
                      end
        attempt = {
          source_span_id: source_id,
          source_text_sha256: Digest::SHA256.hexdigest(item.text.to_s),
          source_bbox_pdf: source_bbox,
          requested_mode: normalized_mode,
          delivered_mode: nil,
          resulting_entity_ids: [],
          visual_fidelity_verified: false,
          placement_verified: false,
          rotation_verified: false,
          width_verified: false,
          height_verified: false,
          content_verified: false,
          leader_verified: false,
          leader_vector_verified: false,
          leader_vector: nil,
          entity_type_verified: false,
          physical_geometry_verified: false,
          physical_style_verified: false,
          transform_verified: false,
          expected_evidence: nil,
          attempt_history: []
        }
        @text_attempts << attempt
        attempt
      rescue RepresentationFidelity::ContractError => e
        record_text_delivery_failure(requested_mode, 'source_span_identity_unverified')
        Logger.warn('GeometryBuilder', e.message)
        nil
      end

      def append_text_rung(attempt, mode)
        rung = {
          mode: normalize_text_mode_symbol(mode), outcome: :attempting,
          reason: nil, created_entity_ids: [], resulting_entity_ids: [],
          cleaned_entity_ids: [], cleanup_outcome: :not_required,
          visual_fidelity_verified: false,
          placement_verified: false, rotation_verified: false,
          content_verified: false, leader_verified: false,
          leader_vector_verified: false, leader_vector: nil,
          entity_type_verified: false,
          physical_geometry_verified: false,
          physical_style_verified: false,
          transform_verified: false,
          expected_evidence: nil
        }
        attempt[:attempt_history] << rung
        rung
      end

      def fail_created_text_rung!(entities, created, rung, reason)
        rung[:created_entity_ids] = RepresentationFidelity.stable_ids(created)
        rung[:cleaned_entity_ids] = RepresentationFidelity.erase_owned!(entities, created)
        rung[:cleanup_outcome] = :verified
        rung[:resulting_entity_ids] = []
        rung[:outcome] = :failed
        rung[:reason] = reason.to_s
        true
      end

      def cleanup_claimed_text_entities!(entities, before_snapshot, claims, rung)
        after_snapshot = RepresentationFidelity.snapshot(entities)
        claim_list = Array(claims).compact
        return [] if claim_list.empty?
        live = claim_list.select do |entity|
          identity = RepresentationFidelity.stable_entity_id(entity)
          after_snapshot[:by_id].key?(identity)
        end
        return [] if live.empty?
        owned = RepresentationFidelity.claimed_created_entities!(
          before_snapshot, after_snapshot, live
        )
        created_ids = RepresentationFidelity.stable_ids(owned)
        cleaned_ids = RepresentationFidelity.erase_owned!(entities, owned)
        rung[:created_entity_ids] = (
          Array(rung[:created_entity_ids]) + created_ids
        ).uniq
        rung[:cleaned_entity_ids] = (
          Array(rung[:cleaned_entity_ids]) + cleaned_ids
        ).uniq
        rung[:cleanup_outcome] = :verified
        rung[:outcome] = :failed
        rung[:resulting_entity_ids] = []
        owned
      end

      def complete_text_rung!(attempt, rung, mode, entity_ids, evidence)
        normalized_mode = normalize_text_mode_symbol(mode)
        ids = RepresentationFidelity.positive_entity_ids(entity_ids)
        valid = evidence.is_a?(Hash) && ids &&
                evidence[:placement_verified] == true &&
                evidence[:rotation_verified] == true &&
                evidence[:entity_type_verified] == true &&
                evidence[:content_verified] == true &&
                evidence[:physical_geometry_verified] == true &&
                evidence[:physical_style_verified] == true &&
                evidence[:transform_verified] == true &&
                valid_source_expected_evidence?(evidence[:expected_evidence],
                                                normalized_mode,
                                                attempt[:source_span_id])
        if normalized_mode == :text3d
          valid = valid && evidence[:width_verified] == true &&
            evidence[:height_verified] == true &&
            evidence[:depth_verified] == true &&
            evidence[:font_identity_verified] == true
        elsif normalized_mode == :labels
          valid = valid && evidence[:content_verified] == true &&
            evidence[:leader_verified] == true &&
            evidence[:leader_vector_verified] == true &&
            evidence[:leader_vector].is_a?(Array) &&
            evidence[:leader_vector].length == 3
        elsif normalized_mode == :text
          # Flat editable Text: content and placement verified; rotation is a
          # known host limitation (SketchUp Text has no glyph-angle control)
          # and is explicitly accepted in-mode rather than stopping the item.
          valid = valid && evidence[:content_verified] == true &&
            evidence[:leader_verified] == true
        else
          valid = false
        end
        raise RepresentationFidelity::ContractError,
              'requested text delivery evidence is incomplete' unless valid

        rung[:outcome] = :complete
        rung[:resulting_entity_ids] = ids
        rung[:visual_fidelity_verified] = true
        rung[:placement_verified] = true
        rung[:rotation_verified] = true
        rung[:width_verified] = evidence[:width_verified] == true
        rung[:height_verified] = evidence[:height_verified] == true
        rung[:depth_verified] = evidence[:depth_verified] == true
        rung[:font_identity_verified] = evidence[:font_identity_verified] == true
        rung[:content_verified] = evidence[:content_verified] == true
        rung[:leader_verified] = evidence[:leader_verified] == true
        rung[:leader_vector_verified] =
          evidence[:leader_vector_verified] == true
        rung[:leader_vector] = evidence[:leader_vector]
        rung[:entity_type_verified] = true
        rung[:physical_geometry_verified] = true
        rung[:physical_style_verified] = true
        rung[:transform_verified] = true
        rung[:expected_evidence] = evidence[:expected_evidence]
        attempt[:delivered_mode] = normalized_mode
        attempt[:resulting_entity_ids] = ids
        attempt[:visual_fidelity_verified] = true
        attempt[:placement_verified] = evidence[:placement_verified] == true
        attempt[:rotation_verified] = evidence[:rotation_verified] == true
        attempt[:width_verified] = evidence[:width_verified] == true
        attempt[:height_verified] = evidence[:height_verified] == true
        attempt[:depth_verified] = evidence[:depth_verified] == true
        attempt[:font_identity_verified] = evidence[:font_identity_verified] == true
        attempt[:content_verified] = evidence[:content_verified] == true
        attempt[:leader_verified] = evidence[:leader_verified] == true
        attempt[:leader_vector_verified] =
          evidence[:leader_vector_verified] == true
        attempt[:leader_vector] = evidence[:leader_vector]
        attempt[:entity_type_verified] = evidence[:entity_type_verified] == true
        attempt[:physical_geometry_verified] = true
        attempt[:physical_style_verified] = true
        attempt[:transform_verified] = true
        attempt[:expected_evidence] = evidence[:expected_evidence]
      end

      def valid_source_expected_evidence?(value, mode, source_id)
        value.is_a?(Hash) &&
          value[:schema].to_s == RepresentationFidelity::SOURCE_EXPECTED_SCHEMA &&
          value[:source_span_id].to_s == source_id.to_s &&
          RepresentationFidelity.normalize_mode(value[:representation]) == mode &&
          value[:source_text_sha256].to_s =~ /\A[0-9a-f]{64}\z/ &&
          value[:source_font_sha256].to_s =~ /\A[0-9a-f]{64}\z/ &&
          value[:physical_geometry_sha256].to_s =~ /\A[0-9a-f]{64}\z/ &&
          value[:physical_style_sha256].to_s =~ /\A[0-9a-f]{64}\z/ &&
          value[:evidence_sha256].to_s =~ /\A[0-9a-f]{64}\z/ &&
          value[:physical_entity_count].to_i > 0
      rescue StandardError
        false
      end

      def created_bounds_payload(created)
        bounds = RepresentationFidelity.bounds(created)
        {
          :min => [bounds[:min_x], bounds[:min_y], bounds[:min_z]],
          :max => [bounds[:max_x], bounds[:max_y], bounds[:max_z]]
        }
      rescue StandardError
        nil
      end

      def source_expected_for_created!(item, mode, created, anchor,
                                       display_angle, dimensions, renderer)
        point = RepresentationFidelity.numeric_point(anchor)
        raise RepresentationFidelity::ContractError,
              'source evidence anchor is unavailable' unless point
        values = dimensions.is_a?(Hash) ? dimensions.dup : {}
        values[:entities] = Array(created)
        values[:source_anchor] = point
        values[:source_rotation_radians] =
          display_angle.to_f * Math::PI / 180.0
        values[:expected_bounds] ||= created_bounds_payload(created)
        unless values.key?(:expected_transformation)
          transforms = Array(created).map do |entity|
            RepresentationFidelity.entity_transformation_payload(entity)
          end.compact
          values[:expected_transformation] = if transforms.empty?
                                               {
                                                 :kind => 'baked_geometry',
                                                 :entity_count => Array(created).length
                                               }
                                             else
                                               transforms
                                             end
        end
        expected = RepresentationFidelity.source_expected_evidence(
          item, mode, values
        )
        RepresentationFidelity.attach_source_evidence!(
          created, expected, renderer
        )
        expected
      end

      def stop_requested_text_delivery!(requested_mode, item, attempt, rung,
                                        reason, transition_proof = nil)
        rung[:outcome] = :failed
        rung[:reason] = reason.to_s
        rung[:resulting_entity_ids] = []
        record_text_delivery_failure(
          requested_mode, reason, item, attempt, transition_proof
        )
        false
      end

      def host_unsupported_label_rotation_proof(item, display_angle, anchor)
        source_id = RepresentationFidelity.source_span_id(item)
        binding = RepresentationFidelity.proof_binding(source_id)
        source_text = item.respond_to?(:text) ? item.text.to_s : ''
        source_bbox = RepresentationFidelity.strict_source_bbox_pdf(item)
        source_anchor = RepresentationFidelity.numeric_point(anchor)
        expected_width = (source_bbox[2] - source_bbox[0]).abs *
          PDF_POINT_TO_INCH * @scale.to_f
        expected_height = (source_bbox[3] - source_bbox[1]).abs *
          PDF_POINT_TO_INCH * @scale.to_f
        rotation_radians = display_angle.to_f * Math::PI / 180.0
        unless !source_text.empty? && source_anchor &&
               expected_width.finite? && expected_width > 0.0 &&
               expected_height.finite? && expected_height > 0.0 &&
               rotation_radians.finite?
          raise RepresentationFidelity::ContractError,
                'rotated label impossibility source placement is unavailable'
        end
        {
          :source_span_id => source_id,
          :importer_id => binding[:importer_id],
          :page_number => binding[:page_number],
          :scope => :item,
          :category => :exact_representation_impossible,
          :affirmative_impossibility => true,
          :generic_failure => false,
          :from_mode => :labels,
          :to_mode => :text3d,
          :reason_code => :host_representation_unsupported,
          :attempted_renderer => 'sketchup_native_text',
          :created_entity_ids => [],
          :cleaned_entity_ids => [],
          :cleanup_outcome => :not_required,
          :evidence => {
            :source_text_sha256 => Digest::SHA256.hexdigest(source_text),
            :source_bbox_pdf => source_bbox,
            :source_anchor => source_anchor,
            :source_rotation_radians =>
              RepresentationFidelity.canonical_number(rotation_radians),
            :expected_width =>
              RepresentationFidelity.canonical_number(expected_width),
            :expected_height =>
              RepresentationFidelity.canonical_number(expected_height),
            :source_rotation_degrees => display_angle.to_f,
            :host_entity_type => 'Sketchup::Text',
            :host_api_fact => 'Text vector controls the leader and does not rotate label glyphs',
            :verification => 'source rotation is nonzero and native label orientation is unsupported'
          }
        }
      end

      def host_unsupported_label_size_proof(item, display_angle, anchor)
        source_id = RepresentationFidelity.source_span_id(item)
        binding = RepresentationFidelity.proof_binding(source_id)
        source_text = item.respond_to?(:text) ? item.text.to_s : ''
        source_bbox = RepresentationFidelity.strict_source_bbox_pdf(item)
        source_anchor = RepresentationFidelity.numeric_point(anchor)
        expected_width = (source_bbox[2] - source_bbox[0]).abs *
          PDF_POINT_TO_INCH * @scale.to_f
        expected_height = (source_bbox[3] - source_bbox[1]).abs *
          PDF_POINT_TO_INCH * @scale.to_f
        rotation_radians = display_angle.to_f * Math::PI / 180.0
        unless !source_text.empty? && source_anchor &&
               expected_width.finite? && expected_width > 0.0 &&
               expected_height.finite? && expected_height > 0.0 &&
               rotation_radians.finite?
          raise RepresentationFidelity::ContractError,
                'native label size-impossibility evidence is unavailable'
        end
        {
          :source_span_id => source_id,
          :importer_id => binding[:importer_id],
          :page_number => binding[:page_number],
          :scope => :item,
          :category => :exact_representation_impossible,
          :affirmative_impossibility => true,
          :generic_failure => false,
          :from_mode => :labels,
          :to_mode => :text3d,
          :reason_code => :host_representation_unsupported,
          :attempted_renderer => 'sketchup_native_text',
          :created_entity_ids => [],
          :cleaned_entity_ids => [],
          :cleanup_outcome => :not_required,
          :evidence => {
            :source_text_sha256 => Digest::SHA256.hexdigest(source_text),
            :source_bbox_pdf => source_bbox,
            :source_anchor => source_anchor,
            :source_rotation_radians =>
              RepresentationFidelity.canonical_number(rotation_radians),
            :expected_width =>
              RepresentationFidelity.canonical_number(expected_width),
            :expected_height =>
              RepresentationFidelity.canonical_number(expected_height),
            :source_rotation_degrees => display_angle.to_f,
            :host_entity_type => 'Sketchup::Text',
            :host_api_fact =>
              'Sketchup::Text exposes neither glyph-size nor source run-width control',
            :verification =>
              'native annotation width and height cannot be matched to the source PDF'
          }
        }
      end


      def text_fit_tolerance(target_width, target_height)
        largest = [target_width.to_f.abs, target_height.to_f.abs, 1.0].max
        largest * 1.0e-5
      end

      def fit_created_text_entities!(entities, created, item, display_angle, anchor)
        target_height = mesh_text_height_inches(item, display_angle, 0.0)
        target_width = mesh_text_declared_run_width_inches(item, display_angle)
        unless target_height && target_width && target_height > 0.0 && target_width > 0.0
          raise RepresentationFidelity::ContractError,
                'source width/height cannot be proven for visual fitting'
        end

        generated = RepresentationFidelity.bounds(created)
        unless generated[:width] > 0.0 && generated[:height] > 0.0
          raise RepresentationFidelity::ContractError, 'generated text bounds are degenerate'
        end
        generated_depth = generated[:max_z].to_f - generated[:min_z].to_f
        unless generated_depth > 0.0
          raise RepresentationFidelity::ContractError,
                'generated native 3D text has no positive Z depth'
        end
        factor_x = target_width / generated[:width]
        factor_y = target_height / generated[:height]
        unless factor_x.finite? && factor_y.finite? && factor_x > 0.0 && factor_y > 0.0
          raise RepresentationFidelity::ContractError, 'text fit factors are invalid'
        end

        pivot = Geom::Point3d.new(generated[:min_x], generated[:min_y], generated[:min_z])
        scale = Geom::Transformation.scaling(pivot, factor_x, factor_y, 1.0)
        entities.transform_entities(scale, *created)
        scaled = RepresentationFidelity.bounds(created)
        tolerance = text_fit_tolerance(target_width, target_height)
        width_ok = RepresentationFidelity.close?(scaled[:width], target_width, tolerance)
        height_ok = RepresentationFidelity.close?(scaled[:height], target_height, tolerance)
        raise RepresentationFidelity::ContractError, 'post-scale width/height verification failed' unless width_ok && height_ok

        anchor_point = RepresentationFidelity.numeric_point(anchor)
        raise RepresentationFidelity::ContractError, 'text anchor is unreadable' unless anchor_point
        delta = Geom::Vector3d.new(
          anchor_point[0] - scaled[:min_x],
          anchor_point[1] - scaled[:min_y],
          anchor_point[2] - scaled[:min_z]
        )
        entities.transform_entities(Geom::Transformation.new(delta), *created)
        if display_angle.to_f.abs > 1.0e-12
          rotation = Geom::Transformation.rotation(anchor, Z_AXIS, display_angle.to_f.degrees)
          entities.transform_entities(rotation, *created)
        end

        final_bounds = RepresentationFidelity.bounds(created)
        final_depth = final_bounds[:max_z].to_f - final_bounds[:min_z].to_f
        expected = RepresentationFidelity.expected_rotated_bounds(
          anchor, target_width, target_height, display_angle
        )
        placement_ok = RepresentationFidelity.close?(final_bounds[:min_x], expected[:min_x], tolerance) &&
                       RepresentationFidelity.close?(final_bounds[:min_y], expected[:min_y], tolerance)
        final_size_ok = RepresentationFidelity.close?(final_bounds[:width], expected[:width], tolerance) &&
                        RepresentationFidelity.close?(final_bounds[:height], expected[:height], tolerance)
        raise RepresentationFidelity::ContractError, 'post-transform placement/rotation verification failed' unless placement_ok && final_size_ok
        unless final_depth > 0.0 &&
               RepresentationFidelity.close?(final_depth, generated_depth,
                                              text_fit_tolerance(generated_depth, generated_depth))
          raise RepresentationFidelity::ContractError,
                'post-transform positive Z depth verification failed'
        end
        entity_types_ok = created.all? do |entity|
          type = if entity.respond_to?(:typename)
                   entity.typename.to_s
                 else
                   entity.class.name.to_s.split('::').last
                 end
          type == 'Edge' || type == 'Face'
        end
        raise RepresentationFidelity::ContractError,
              'created 3D Text entity type is not observable' unless entity_types_ok
        record_text_width_factor_sample(factor_x)

        {
          target_width_in: target_width, target_height_in: target_height,
          scale_x: factor_x, scale_y: factor_y,
          placement_verified: true, rotation_verified: true,
          width_verified: true, height_verified: true,
          depth_verified: true,
          entity_type_verified: true
        }
      end

      def place_mesh_text(entities, item, origin_x, origin_y, layer,
                          requested_mode = nil, attempt = nil)
        requested_mode = @requested_text_mode if requested_mode.nil?
        attempt ||= begin_text_attempt(item, requested_mode)
        return false unless attempt
        rung = append_text_rung(attempt, :text3d)
        label_x, label_y, label_angle = mesh_label_anchor_pdf(item)
        display_angle = display_text_angle(item, label_angle)
        anchor = text_point_to_su(item, label_x, label_y, origin_x, origin_y)
        height = mesh_text_height_inches(item, display_angle, 0.0)
        unless height
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung,
            'text3d_source_height_unavailable'
          )
        end

        font_identity = verified_native_font_identity(item)
        unless font_identity
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung,
            'text3d_native_font_identity_unverified'
          )
        end
        extrusion_depth = native_text_extrusion_depth(height)
        unless extrusion_depth
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung,
            'text3d_positive_depth_unavailable'
          )
        end

        before = RepresentationFidelity.snapshot(entities)
        owned_group = entities.add_group
        unless owned_group && owned_group.respond_to?(:entities)
          raise RepresentationFidelity::ContractError,
                'text3d host did not return an owned staging group'
        end
        success = owned_group.entities.add_3d_text(
          item.text, TextAlignLeft, font_identity[:installed_family], false, false,
          height, 0.0, 0.0, true, extrusion_depth
        )
        unless success
          cleanup_claimed_text_entities!(
            entities, before, [owned_group], rung
          )
          owned_group = nil
          rung[:reason] = 'text3d_mesh_unavailable'
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung, 'text3d_mesh_unavailable'
          )
        end

        staged = RepresentationFidelity.snapshot(owned_group.entities)[:entities]
        if staged.empty?
          cleanup_claimed_text_entities!(
            entities, before, [owned_group], rung
          )
          owned_group = nil
          rung[:reason] = 'text3d_mesh_empty'
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung, 'text3d_mesh_empty'
          )
        end

        created = Array(owned_group.explode).compact
        owned_group = nil
        if created.empty?
          raise RepresentationFidelity::ContractError,
                'text3d staging group did not return exploded entity references'
        end
        after = RepresentationFidelity.snapshot(entities)
        owned = RepresentationFidelity.claimed_created_entities!(
          before, after, created
        )
        all_created = RepresentationFidelity.created_between(before, after)
        unless RepresentationFidelity.stable_ids(all_created) ==
               RepresentationFidelity.stable_ids(owned)
          cleanup_claimed_text_entities!(entities, before, owned, rung)
          created = []
          raise RepresentationFidelity::ContractError,
                'text3d host creation was accompanied by an unclaimed peer artifact'
        end
        created = owned
        rung[:created_entity_ids] = RepresentationFidelity.stable_ids(created)

        begin
          evidence = fit_created_text_entities!(entities, created, item,
                                                 display_angle, anchor)
          evidence[:font_identity_verified] = true
          evidence[:pdf_font_identity] = font_identity[:pdf_font_identity]
          evidence[:installed_family] = font_identity[:installed_family]
        rescue RepresentationFidelity::ContractError => e
          reason = "text3d_visual_fidelity_unverified: #{e.message}"
          fail_created_text_rung!(entities, created, rung, reason)
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung, reason
          )
        end

        text_faces = created.select do |entity|
          entity.respond_to?(:typename) && entity.typename == 'Face'
        end
        apply_text_face_material(text_faces)
        @face_count += text_faces.length
        created.each { |entity| set_layer(entity, layer) }
        evidence[:content_verified] = true
        evidence[:physical_geometry_verified] = true
        evidence[:physical_style_verified] = true
        evidence[:transform_verified] = true
        source_planar_bounds = RepresentationFidelity.expected_rotated_bounds(
          anchor, evidence[:target_width_in], evidence[:target_height_in],
          display_angle
        )
        source_anchor = RepresentationFidelity.numeric_point(anchor)
        source_bounds = {
          :min => [
            source_planar_bounds[:min_x], source_planar_bounds[:min_y],
            source_anchor[2]
          ],
          :max => [
            source_planar_bounds[:max_x], source_planar_bounds[:max_y],
            source_anchor[2] + extrusion_depth
          ]
        }
        evidence[:expected_evidence] = source_expected_for_created!(
          item, :text3d, created, anchor, display_angle,
          {
            :expected_width => evidence[:target_width_in],
            :expected_height => evidence[:target_height_in],
            :expected_depth => extrusion_depth,
            :expected_bounds => source_bounds,
            :expected_transformation => {
              :kind => 'baked_geometry',
              :entity_count => created.length
            },
            :source_font_identity => {
              :pdf_font_identity => font_identity[:pdf_font_identity],
              :installed_family => font_identity[:installed_family]
            }
          },
          'sketchup_native_3d_text'
        )
        entity_ids = RepresentationFidelity.stable_ids(created)
        @text_count += 1
        record_mesh_text_height_sample(height)
        record_text_span_provenance(item, 'native_3d_text', entity_ids, :text3d)
        complete_text_rung!(attempt, rung, :text3d, entity_ids, evidence)
        true
      rescue RepresentationFidelity::ContractError => e
        if defined?(before) && before && defined?(rung) && rung
          claims = []
          claims.concat(Array(created)) if defined?(created) && created
          claims << owned_group if defined?(owned_group) && owned_group
          cleanup_claimed_text_entities!(entities, before, claims, rung)
        end
        raise e
      rescue StandardError => e
        Logger.warn('GeometryBuilder', "add_3d_text failed: #{e.message}")
        if defined?(before) && before && defined?(rung) && rung
          claims = []
          claims.concat(Array(created)) if defined?(created) && created
          claims << owned_group if defined?(owned_group) && owned_group
          cleanup_claimed_text_entities!(entities, before, claims, rung)
          rung[:reason] = 'text3d_exception'
        elsif defined?(rung) && rung
          rung[:outcome] = :failed
          rung[:reason] = 'text3d_exception'
        end
        stop_requested_text_delivery!(
          requested_mode, item, attempt, rung, 'text3d_exception'
        )
      end

      def apply_text_face_material(faces)
        return if faces.nil? || faces.empty?

        mat = nil
        begin
          mat = get_or_create_material(TEXT_FACE_RGB)
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "text face material unavailable: #{e.message}")
        end
        faces.each do |face|
          begin
            face.material = mat if mat && face.respond_to?(:material=)
            face.back_material = mat if mat && face.respond_to?(:back_material=)
          rescue StandardError => e
            Logger.warn("GeometryBuilder", "set text face material failed: #{e.message}")
          end
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
      rescue RepresentationFidelity::ContractError
        raise
      rescue StandardError => e
        Logger.warn("GeometryBuilder", "stacked vertical dimension placement failed: #{e.message}")
        raise RepresentationFidelity::ContractError,
              "stacked label delivery failed atomically: #{e.message}"
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
        sub = item.class.new(
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
        # Derived/split text keeps the source item's span identity so its
        # provenance rows still join with parts_bootstrap (corrective §1).
        if sub.respond_to?(:source_span_id=) && item.respond_to?(:source_span_id)
          sub.source_span_id = item.source_span_id
        end
        # Ordinary one-digit spans remain left anchored. Only digits derived
        # from a verified stacked parent are centered in that parent's gap.
        sub.instance_variable_set(:@stacked_dimension_sub_item, true)
        sub
      rescue StandardError
        item
      end

      def stacked_dimension_sub_item?(item)
        item && item.instance_variable_defined?(:@stacked_dimension_sub_item) &&
          item.instance_variable_get(:@stacked_dimension_sub_item) == true
      rescue StandardError
        false
      end

      def try_annotation_add(entities, rung, description)
        before = RepresentationFidelity.snapshot(entities)
        entity = nil
        entity = yield
        after = RepresentationFidelity.snapshot(entities)
        created = RepresentationFidelity.created_between(before, after)
        unless entity
          unless created.empty?
            raise RepresentationFidelity::ContractError,
                  "#{description} created an unreturned host artifact; " \
                  'ownership is ambiguous and the operation must abort'
          end
          return nil
        end

        owned = RepresentationFidelity.claimed_created_entities!(
          before, after, [entity]
        )
        created_ids = RepresentationFidelity.stable_ids(created)
        owned_ids = RepresentationFidelity.stable_ids(owned)
        unless created_ids == owned_ids
          cleaned_ids = RepresentationFidelity.erase_owned!(entities, owned)
          if rung
            rung[:created_entity_ids] = owned_ids
            rung[:cleaned_entity_ids] = cleaned_ids
            rung[:cleanup_outcome] = :verified
          end
          entity = nil
          raise RepresentationFidelity::ContractError,
                "#{description} was accompanied by an unclaimed peer artifact"
        end
        entity
      rescue RepresentationFidelity::ContractError
        if entity
          begin
            entities.erase_entities(entity)
          rescue StandardError
            # The enclosing SketchUp operation must abort atomically when the
            # exact returned reference cannot be cleaned or verified.
          end
        end
        raise
      rescue StandardError => e
        Logger.warn('GeometryBuilder', "#{description} failed: #{e.message}")
        if before
          after = RepresentationFidelity.snapshot(entities)
          created = RepresentationFidelity.created_between(before, after)
          unless created.empty?
            raise RepresentationFidelity::ContractError,
                  "#{description} raised after creating an unreturned host " \
                  'artifact; ownership is ambiguous and the operation must abort'
          end
        end
        nil
      end

      def try_add_annotation_text(entities, text, pt, _leader_vector,
                                  rung = nil)
        # SketchUp 2017 can terminate the host when add_text receives a
        # zero-length leader vector. The documented two-argument overload
        # creates a native Text entity without passing that crash trigger.
        try_annotation_add(entities, rung, 'add_text without leader vector') do
          entities.add_text(text, pt)
        end
      end

      def zero_label_leader_vector
        Geom::Vector3d.new(0, 0, 0)
      rescue StandardError
        nil
      end

      def hide_annotation_leader(text, _preserve_vector = false)
        return unless text
        begin
          text.display_leader = false if text.respond_to?(:display_leader=)
        rescue StandardError => e
          Logger.warn("GeometryBuilder", "hide label leader failed: #{e.message}")
        end
      end

      def cleanup_unverified_label!(entities, text, before_snapshot, rung, reason)
        ids = []
        begin
          ids = [RepresentationFidelity.stable_entity_id(text)]
        rescue RepresentationFidelity::ContractError
          # The exact pre/post entity-set proof below still permits cleanup of
          # a host object that failed to expose a stable identity.
        end
        entities.erase_entities(text)
        after_cleanup = RepresentationFidelity.snapshot(entities)
        unless before_snapshot[:by_id].keys.sort == after_cleanup[:by_id].keys.sort
          raise RepresentationFidelity::ContractError,
                'unverified label cleanup did not restore the pre-creation entity set'
        end
        rung[:outcome] = :failed
        rung[:reason] = reason.to_s
        rung[:cleanup_outcome] = :verified
        rung[:created_entity_ids] = ids
        rung[:cleaned_entity_ids] = ids
        rung[:resulting_entity_ids] = []
        true
      rescue RepresentationFidelity::ContractError
        raise
      rescue StandardError => e
        raise RepresentationFidelity::ContractError,
              "unverified label cleanup failed: #{e.message}"
      end

      def verify_annotation_label(text, expected_text, expected_point,
                                  display_angle,
                                  verify_leader = false,
                                  expected_leader_vector = nil)
        type = if text.respond_to?(:typename)
                 text.typename.to_s
               else
                 text.class.name.to_s.split('::').last
               end
        raise RepresentationFidelity::ContractError,
              'created label is not a native Text entity' unless type == 'Text'
        raise RepresentationFidelity::ContractError,
              'label text content is not observable' unless text.respond_to?(:text)
        raise RepresentationFidelity::ContractError,
              'label text content verification failed' unless
          text.text.to_s == expected_text.to_s
        actual_point = text.respond_to?(:point) ?
          RepresentationFidelity.numeric_point(text.point) : nil
        target_point = RepresentationFidelity.numeric_point(expected_point)
        raise RepresentationFidelity::ContractError, 'label point is not observable' unless actual_point && target_point
        tolerance = 1.0e-6
        placement_ok = [0, 1, 2].all? do |axis|
          RepresentationFidelity.close?(
            actual_point[axis], target_point[axis], tolerance
          )
        end
        raise RepresentationFidelity::ContractError, 'label anchor verification failed' unless placement_ok

        actual_vector = text.respond_to?(:vector) ?
          RepresentationFidelity.numeric_point(text.vector) : nil
        unless actual_vector && actual_vector.length == 3 &&
               actual_vector.all? { |value| value.to_f.finite? }
          raise RepresentationFidelity::ContractError,
                'label leader vector is not observable in all three coordinates'
        end
        if expected_leader_vector
          target_vector = Array(expected_leader_vector)
          vector_ok = target_vector.length == 3 &&
            [0, 1, 2].all? do |axis|
              RepresentationFidelity.close?(
                actual_vector[axis], target_vector[axis], tolerance
              )
            end
          raise RepresentationFidelity::ContractError,
                'label leader vector readback changed' unless vector_ok
        end

        # SketchUp::Text#vector is the leader vector, not a text-orientation
        # axis. Native labels therefore cannot represent non-horizontal PDF
        # text, and that known host limitation must be handled before add_text
        # is called. A zero source angle is the only label orientation that can
        # be certified here; the leader vector is verified separately below.
        unless display_angle.to_f.abs <= 1.0e-12
          raise RepresentationFidelity::ContractError,
                'native SketchUp Text cannot preserve source text rotation'
        end
        leader_verified = false
        if verify_leader
          leader_observable = false
          leader_visible = nil
          if text.respond_to?(:display_leader?)
            leader_observable = true
            leader_visible = text.display_leader?
          elsif text.respond_to?(:display_leader)
            leader_observable = true
            leader_visible = text.display_leader
          end
          raise RepresentationFidelity::ContractError,
                'label leader visibility is not observable' unless leader_observable
          raise RepresentationFidelity::ContractError,
                'label leader visibility verification failed' unless
            leader_visible == false
          leader_verified = true
        end
        {
          placement_verified: true,
          rotation_verified: true,
          width_verified: false,
          height_verified: false,
          content_verified: true,
          leader_verified: leader_verified,
          leader_vector_verified: true,
          leader_vector: actual_vector,
          entity_type_verified: true,
          display_angle: display_angle.to_f
        }
      end

      def place_annotation_label(entities, item, origin_x, origin_y, layer,
                                 requested_mode = nil, attempt = nil)
        requested_mode = @requested_text_mode if requested_mode.nil?
        attempt ||= begin_text_attempt(item, requested_mode)
        return false unless attempt
        rung = append_text_rung(attempt, :labels)
        source_geometry = verified_label_source_geometry(item)
        unless source_geometry
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung,
            'label_source_dimensions_unavailable'
          )
        end
        label_x, label_y, label_angle = label_insertion_pdf(item)
        display_angle = display_text_angle(item, label_angle)
        pt = text_point_to_su(item, label_x, label_y, origin_x, origin_y)
        rotated = display_angle.to_f.abs > 1.0e-12
        if rotated
          # Labels cannot express glyph rotation. Emit an item-scoped
          # impossibility proof so the finite ladder advances Labels → 3D Text
          # (which preserves source angle). Never place unrotated text.
          proof = host_unsupported_label_rotation_proof(item, display_angle, pt)
          rung[:transition_proof] = proof
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung,
            'label_rotation_unsupported_by_host', proof
          )
        end
        if normalize_text_mode_symbol(requested_mode) == :text
          # The Text request promises source-aligned visual text. SketchUp's
          # only flat text API creates screen annotations whose glyph size and
          # run width cannot be controlled or verified. Do not create a label
          # and then call its unmeasured result visually exact; advance the
          # item-bound ladder to exact source-outline 3D Text.
          proof = host_unsupported_label_size_proof(
            item, display_angle, pt
          )
          rung[:transition_proof] = proof
          return stop_requested_text_delivery!(
            requested_mode, item, attempt, rung,
            'label_source_size_unsupported_by_host', proof
          )
        end
        leader_vector = zero_label_leader_vector
        before = RepresentationFidelity.snapshot(entities)
        text = try_add_annotation_text(
          entities, item.text, pt, leader_vector, rung
        )
        if text
          begin
            identity = RepresentationFidelity.stable_entity_id(text)
            initial_evidence = verify_annotation_label(
              text, item.text, pt, display_angle
            )
            hide_annotation_leader(text)
            # Re-read after mutating the host entity: the final point/content
            # and hidden-leader state are the delivery evidence. Text#vector
            # is never interpreted as text orientation.
            evidence = verify_annotation_label(
              text, item.text, pt, display_angle, true,
              initial_evidence[:leader_vector]
            )
            set_layer(text, layer)
            expected_width = source_geometry[:expected_width]
            expected_height = source_geometry[:expected_height]
            evidence[:physical_geometry_verified] = true
            evidence[:physical_style_verified] = true
            evidence[:transform_verified] = true
            evidence[:expected_evidence] = source_expected_for_created!(
              item, :labels, [text], pt, display_angle,
              {
                :expected_width => expected_width,
                :expected_height => expected_height,
                :expected_depth => 0.0,
                :expected_transformation => {
                  :kind => 'native_text_anchor',
                  :anchor => RepresentationFidelity.numeric_point(pt)
                }
              },
              'sketchup_native_text'
            )
            entity_ids = [identity]
            @text_count += 1
            record_text_span_provenance(item, 'native_label', entity_ids, :labels)
            complete_text_rung!(attempt, rung, :labels, entity_ids, evidence)
            return true
          rescue RepresentationFidelity::ContractError => e
            cleanup_unverified_label!(
              entities, text, before, rung,
              "label_visual_fidelity_unverified: #{e.message}"
            )
          rescue StandardError => e
            cleanup_unverified_label!(
              entities, text, before, rung,
              "label_delivery_exception: #{e.message}"
            )
          end
        else
          rung[:outcome] = :failed
          rung[:reason] = 'label_native_api_unavailable'
        end

        stop_requested_text_delivery!(
          requested_mode, item, attempt, rung,
          rung[:reason] || 'label_native_api_unavailable'
        )
      rescue RepresentationFidelity::ContractError => e
        raise e
      end

      def record_text_delivery_failure(requested, reason, item = nil,
                                       attempt = nil, transition_proof = nil)
        requested_mode = normalize_text_mode_symbol(requested)
        return if requested_mode.nil?

        @text_delivery_failures ||= []
        entry = {
          requested: requested_mode,
          reason: reason.to_s,
          count: 1,
          attempt_history: attempt ? Array(attempt[:attempt_history]) : []
        }
        begin
          entry[:source_span_id] = RepresentationFidelity.source_span_id(item) if item
        rescue RepresentationFidelity::ContractError
          # The explicit missing-identity reason is itself the evidence.
        end
        entry[:transition_proof] = transition_proof if transition_proof
        @text_delivery_failures << entry
      rescue StandardError => e
        Logger.warn('GeometryBuilder', "text delivery failure record failed: #{e.message}")
      end

      def normalize_text_mode_symbol(mode)
        case mode.to_s.strip.downcase
        when 'text', 'flat_text', 'editable_text' then :text
        when 'text3d', '3d_text', '3d text', 'add_3d_text' then :text3d
        when 'labels', 'label', 'add_text' then :labels
        when 'glyphs', 'glyph' then :glyphs
        when 'geometry', 'outlines', 'outline' then :geometry
        when 'raster', 'image' then :raster
        else nil
        end
      end

      def record_text_span_provenance(item, delivered_entity_type = nil,
                                      resulting_entity_ids = [],
                                      delivered_mode = nil)
        raise RepresentationFidelity::ContractError,
              'provenance bucket is unavailable' unless @provenance_bucket.is_a?(Array)
        span_id = RepresentationFidelity.source_span_id(item)
        ids = RepresentationFidelity.positive_entity_ids(resulting_entity_ids)
        raise RepresentationFidelity::ContractError,
              'resulting entity identities are missing or malformed' unless ids
        entity_type = delivered_entity_type ||
                      (@use_3d_text ? 'native_3d_text' : 'native_label')
        idx = @provenance_bucket.length
        entry = {
          object_id: "text_delivery:#{@page_number}:#{idx}",
          page: @page_number,
          source_kind: 'text_span',
          span_id: span_id,
          source_text_sha256: Digest::SHA256.hexdigest(item.text.to_s),
          created_entity_type: entity_type,
          requested_mode: @requested_text_mode,
          delivered_mode: normalize_text_mode_symbol(delivered_mode),
          resulting_entity_ids: ids
        }
        # Corrective 2026-07-12 §1 (RB-01): span_id is the SAME deterministic
        # source-span identity that PartsBootstrap emits in row span_ids
        # (TextSourceIdentity "text_span:<page>:<index>"), so the two sidecars
        # join. object_id above stays a separate created-entity label. Missing
        # source or resulting-entity identities are rejected before this point;
        # partial provenance is never emitted or repaired with fabricated IDs.
        bbox = item_source_bbox_pdf(item)
        entry[:source_bbox_pdf] = bbox if bbox
        @provenance_bucket << entry
      end

      def item_source_bbox_pdf(item)
        return nil unless label_has_bbox?(item)

        [item.bbox_x0.to_f, item.bbox_y0.to_f, item.bbox_x1.to_f, item.bbox_y1.to_f]
      rescue StandardError
        nil
      end

      def label_has_bbox?(item)
        return false unless item
        vals = [item.bbox_x0, item.bbox_y0, item.bbox_x1, item.bbox_y1].map do |value|
          Float(value)
        end
        return false unless vals.all? { |value| value.finite? }
        (vals[2] - vals[0]) > 1.0e-6 &&
          (vals[3] - vals[1]) > 1.0e-6
      rescue StandardError
        false
      end

      def verified_label_source_geometry(item)
        return nil unless label_has_bbox?(item)
        bbox = [
          Float(item.bbox_x0), Float(item.bbox_y0),
          Float(item.bbox_x1), Float(item.bbox_y1)
        ]
        scale = Float(@scale)
        width = (bbox[2] - bbox[0]) * scale / 72.0
        height = (bbox[3] - bbox[1]) * scale / 72.0
        return nil unless scale.finite? && scale > 0.0 &&
                          width.finite? && width > 0.0 &&
                          height.finite? && height > 0.0
        {
          :source_bbox_pdf => bbox,
          :expected_width => width,
          :expected_height => height
        }
      rescue StandardError
        nil
      end

      def external_text_item?(item)
        item.font_name.to_s == 'pdftotext'
      rescue StandardError
        false
      end

      BOM_TABLE_HEADER = /\A(?:QUAN|MARK|DESCRIPTION|LENGTH|QTY|TOTAL\s+WT\.?|REMARKS)\z/i
      BOM_TABLE_QUANTITY = /\A\d{1,4}\z/

      def prepare_bom_table_context(items)
        @bom_quan_x = nil
        @bom_mark_x = nil
        @bom_table_y0 = nil
        @bom_table_y1 = nil
        quan = items.find { |it| it.text.to_s.strip =~ /\AQUAN\z/i && label_has_bbox?(it) }
        mark = items.find { |it| it.text.to_s.strip =~ /\AMARK\z/i && label_has_bbox?(it) }
        headers = items.select { |it| it.text.to_s.strip =~ BOM_TABLE_HEADER }
        @bom_quan_x = quan.bbox_x0.to_f if quan
        @bom_mark_x = mark.bbox_x0.to_f if mark
        return if headers.empty?

        header_y = headers.map { |h| h.bbox_y0.to_f }
        anchor = quan ? quan.bbox_y0.to_f : header_y.max
        @bom_table_y0 = anchor - 320.0
        @bom_table_y1 = anchor + 12.0
      rescue StandardError
        @bom_quan_x = nil
        @bom_mark_x = nil
        @bom_table_y0 = nil
        @bom_table_y1 = nil
      end

      def bom_table_row?(item)
        return false unless label_has_bbox?(item)
        return false unless @bom_table_y0 && @bom_table_y1

        item.bbox_y0.to_f.between?(@bom_table_y0, @bom_table_y1)
      rescue StandardError
        false
      end

      def bom_table_quan_column?(item)
        return false unless bom_table_row?(item)
        return false unless @bom_quan_x

        (item.bbox_x0.to_f - @bom_quan_x).abs < 20.0
      rescue StandardError
        false
      end

      def bom_table_mark_column?(item)
        return false unless bom_table_row?(item)
        return false unless @bom_mark_x

        (item.bbox_x0.to_f - @bom_mark_x).abs < 28.0
      rescue StandardError
        false
      end

      def bom_table_quantity_label?(text, bbox_w_pts, bbox_h_pts, angle_deg = 0.0, item = nil)
        t = text.to_s.strip
        return false unless t =~ BOM_TABLE_QUANTITY
        in_quan_col = item && bom_table_quan_column?(item)
        unless in_quan_col
          return false if slope_triangle_label?(t, bbox_w_pts, bbox_h_pts, angle_deg)
        end
        return false if part_mark_label?(t)
        return false if weld_fraction_label?(t, bbox_w_pts, bbox_h_pts)
        bw = bbox_w_pts.to_f
        bh = bbox_h_pts.to_f
        ratio_ok = bw > 0.5 && bh > bw * 1.15
        return false unless ratio_ok
        return true if in_quan_col
        # Without BOM context, keep the stricter tall-cell guard used since v3.7.59.
        bh > bw * 2.0
      rescue StandardError
        false
      end

      def should_center_bom_quantity?(text, bbox_w_pts, bbox_h_pts, font_size_pts, angle_deg, item = nil)
        return false unless bom_table_quantity_label?(text, bbox_w_pts, bbox_h_pts, angle_deg, item)
        bw = bbox_w_pts.to_f
        bh = bbox_h_pts.to_f
        fs = [font_size_pts.to_f, 1.0].max
        est_w = text.to_s.strip.length * fs * 0.55
        bh > bw * 1.15 && bw > est_w * 0.45
      rescue StandardError
        false
      end

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
      # Weld callouts: any inch fraction (not a fixed drawing-specific fraction list).
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
        [item.font_size.to_f, 1.0].max
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
        return true if (t =~ /\A\d{1,2}\/\d{1,2}"?\z/) &&
                       bh >= bw * 0.85 && bw > raw_w * 1.04
        # Mixed numbers center only when the cell shape supports a dimension
        # break. A one-digit whole number is common in ordinary horizontal
        # annotations, so require its cell to remain tight to the rendered run.
        mixed = /\A(\d+)\s+\d{1,2}\/\d{1,2}"?\z/.match(t)
        if mixed && bh <= bw * 1.05 && bw > raw_w * 1.04
          return true if mixed[1].length >= 2
          return true if bw < raw_w * 1.35
        end
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
        # Near-zero PDF angles with a tall pdftotext cell are stacked-fraction /
        # dimension-break layouts, not 90° runs. Only force vertical when the
        # extractor already reports a near-vertical angle.
        return false if angle_deg.to_f.abs >= 45.0
        t = text.to_s.strip
        return true if t =~ /\A\d{1,2}\/\d{1,2}"?\z/
        mixed = /\A(\d+)\s+\d{1,2}\/\d{1,2}"?\z/.match(t)
        return false unless mixed
        return true if mixed[1].length == 1

        # A source font no larger than the bbox short side describes an
        # upright stacked fraction inside a tall dimension-break cell. When
        # the reported source size is the long side, the same AABB describes
        # a true rotated run and must not be flattened to horizontal.
        short_side = [bbox_w_pts.to_f.abs, bbox_h_pts.to_f.abs].min
        font_size_pts.to_f <= short_side * 1.05
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
        if annotation_like_label?(item.text, bbox_w, bbox_h)
          return normalize_text_angle_deg(angle) if angle.abs >= 12.0
          return 0.0
        end
        if bom_table_row?(item) &&
           !bom_table_quantity_label?(item.text, bbox_w, bbox_h, angle, item)
          return 0.0
        end
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
        if bom_table_quantity_label?(item.text, bbox_w, bbox_h, angle, item)
          return 0.0 if bom_table_quan_column?(item)
          raw = item.respond_to?(:angle) ? item.angle.to_f : 0.0
          return raw if raw.abs >= 45.0
          return 90.0
        end
        if dimension_like_label?(item.text)
          fs = effective_font_size_pts(item)
          orientation_fs = fs
          if external_text_item?(item) && item.respond_to?(:raw_font_size) &&
             item.raw_font_size && item.raw_font_size.to_f > 0.0
            orientation_fs = item.raw_font_size.to_f
          end
          if bbox_w && bbox_h && vertical_dimension_bbox?(item, bbox_w, bbox_h) &&
             !narrow_fraction_dimension_stays_horizontal?(
               item.text, bbox_w, bbox_h, orientation_fs, angle
             )
            raw = item.respond_to?(:angle) ? item.angle.to_f : 0.0
            # Trust the extractor when it already reports a meaningful tilt
            # (diagonal brace dims). Only synthesize 90° for upright PDF
            # angles whose tall/narrow bbox evidences a vertical run.
            return raw if raw.abs >= 12.0
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

      def label_run_width_pts(text, font_size_pts, bbox_w_pts = nil, bbox_h_pts = nil, item = nil)
        fs = [font_size_pts.to_f, 1.0].max
        raw = if bom_table_quantity_label?(text, bbox_w_pts, bbox_h_pts, 0.0, item)
                if item && bom_table_quan_column?(item)
                  text.to_s.strip.length * fs * 0.55
                else
                  [bbox_h_pts.to_f * 0.88, fs * 0.55].max
                end
              elsif dimension_like_label?(text)
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

      def rotated_bbox_text_origin_pdf(item, bx0, by0, bx1, by1, fs, angle, baseline_offset_pts = nil)
        bw = (bx1 - bx0).abs
        bh = (by1 - by0).abs
        run_w = nil
        run_w = label_run_width_pts(item.text, fs, bw, bh) if run_w.nil? || run_w <= 0.0
        rad = angle.to_f * Math::PI / 180.0
        dir_x = Math.cos(rad)
        dir_y = Math.sin(rad)
        norm_x = -dir_y
        norm_y = dir_x
        cx = (bx0 + bx1) * 0.5
        cy = (by0 + by1) * 0.5
        baseline_offset = baseline_offset_pts.nil? ? (fs.to_f * 0.18) : baseline_offset_pts.to_f
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
        # A single glyph's natural bbox is routinely taller than 1.6x its
        # width (stacked-fraction halves, whole digits), while a truly
        # 90°-rotated single glyph presents the OPPOSITE aspect — so a tall
        # bbox can never evidence rotation for one-character text (LOOP-1
        # placement 9/17 residual; R-A additive-only: each physical span
        # stays at its own upright position).
        return false if item.text.to_s.strip.length == 1
        bw = bbox_w_pts.to_f
        bh = bbox_h_pts.to_f
        bw > 0.5 && bh > bw * 1.6
      rescue StandardError
        false
      end

      def rotated_bbox_text_origin?(item, bbox_w_pts, bbox_h_pts, angle_deg)
        return false if annotation_like_label?(item.text, bbox_w_pts, bbox_h_pts)
        if bom_table_quantity_label?(item.text, bbox_w_pts, bbox_h_pts, angle_deg, item)
          return angle_requires_rotated_origin?(angle_deg)
        end
        if tall_single_text_bbox?(item, bbox_w_pts, bbox_h_pts)
          return angle_requires_rotated_origin?(angle_deg)
        end
        return false unless part_mark_label?(item.text) || dimension_like_label?(item.text)
        angle_requires_rotated_origin?(angle_deg)
      rescue StandardError
        false
      end

      # Left anchor for add_3d_text. mesh_text_insertion_pdf returns the
      # baseline-left anchor of the generated mesh, not the label anchor.
      def mesh_label_anchor_pdf(item)
        mesh_text_insertion_pdf(item)
      rescue StandardError
        mesh_text_insertion_pdf(item)
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
      def label_insertion_pdf(item, for_mesh = false)
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
            baseline_offset = for_mesh ? (fs * 0.5) : nil
            x, y = rotated_bbox_text_origin_pdf(item, bx0, by0, bx1, by1, fs, angle, baseline_offset)
            used_rotated_origin = true
          elsif stacked_dimension_sub_item?(item)
            est_w = dimension_label_est_width_pts(item.text, fs, bbox_w)
            x = ((bx0 + bx1) * 0.5) - (est_w * 0.5)
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
          elsif should_center_bom_quantity?(item.text, bbox_w, bbox_h, fs, angle, item)
            est_w = label_run_width_pts(item.text, fs, bbox_w, bbox_h, item)
            x = ((bx0 + bx1) * 0.5) - (est_w * 0.5)
          elsif should_center_label?(item.text, bbox_w, fs, angle)
            t = item.text.to_s.strip
            est_w = t.length * fs * 0.55
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

      # This helper only selects the rotated-bbox insertion calculation used by
      # representations that can preserve rotation. SketchUp::Text#vector is a
      # leader vector and is never used as a glyph-orientation axis.
      def angle_requires_rotated_origin?(angle_deg)
        a = angle_deg.to_f % 180.0
        a += 180.0 if a < 0.0
        a = 180.0 - a if a > 90.0
        a > 1.0e-12
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

      def discardable_page_artifact?(path, bbox, page_area_pts)
        return false unless path && path.fill && !path.stroke
        return false unless page_area_pts.to_f > 0.0
        pw = (bbox[2] - bbox[0]).abs
        ph = (bbox[3] - bbox[1]).abs
        return false unless pw * ph > page_area_pts.to_f * 0.95
        simple_filled_background_path?(path)
      rescue StandardError
        false
      end

      def simple_filled_background_path?(path)
        subpaths = Array(path.subpaths)
        return false unless subpaths.length == 1
        segments = Array(subpaths[0].segments)
        draw_segments = segments.reject { |seg| seg.type == :move }
        return false if draw_segments.empty?
        return false if draw_segments.length > 5
        draw_segments.all? { |seg| seg.type == :line || seg.type == :rect }
      rescue StandardError
        false
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
