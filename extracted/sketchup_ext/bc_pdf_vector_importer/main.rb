# bc_pdf_vector_importer/main.rb
# Pipeline: PDF > Primitives > Cleanup > Profile > Generic Recognition
#           > Optional Domain Pack > Validation > Host Build > Report
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'zlib'

module BlueCollarSystems
  module PDFVectorImporter

    dir = File.dirname(__FILE__)
    # Core Engine
    require File.join(dir, 'import_config')
    require File.join(dir, 'primitives')
    require File.join(dir, 'logger')
    require File.join(dir, 'command_runner')
    require File.join(dir, 'pdf_parser')
    require File.join(dir, 'content_stream_parser')
    require File.join(dir, 'text_parser')
    require File.join(dir, 'external_text_extractor')
    require File.join(dir, 'bezier')
    require File.join(dir, 'arc_fitter')
    require File.join(dir, 'ocg_parser')
    require File.join(dir, 'xobject_parser')
    require File.join(dir, 'primitive_extractor')
    require File.join(dir, 'unit_parser')
    require File.join(dir, 'dimension_parser')
    require File.join(dir, 'generic_classifier')
    require File.join(dir, 'document_profiler')
    require File.join(dir, 'region_segmenter')
    require File.join(dir, 'generic_recognizer')
    # Pipeline
    require File.join(dir, 'recognizer')
    require File.join(dir, 'validator')
    # Host Builders
    require File.join(dir, 'geometry_builder')
    require File.join(dir, 'geometry_cleanup')
    require File.join(dir, 'hatch_detector')
    require File.join(dir, 'stroke_font')
    require File.join(dir, 'svg_text_renderer')
    require File.join(dir, 'svg_geometry_renderer')
    require File.join(dir, 'metadata')
    # Tools & UI
    require File.join(dir, 'scale_tool')
    require File.join(dir, 'import_dialog')
    require File.join(dir, 'report_dialog')

    # ================================================================
    # SHARED PIPELINE — single source of truth for all import paths
    # ================================================================
    def self.safe_abort_operation(model, source)
      return unless model
      model.abort_operation
    rescue StandardError => e
      Logger.warn(source, "abort_operation failed: #{e.message}")
    end

    def self.safe_find_pdftocairo
      SvgTextRenderer.find_pdftocairo
    rescue StandardError => e
      Logger.warn("Raster", "pdftocairo lookup failed: #{e.message}")
      nil
    end

    # Auto-mode flood heuristics (mirrors the FreeCAD importer behavior).
    # Catches decorative/map pages that are technically vector paths but are not
    # useful CAD geometry in SketchUp.
    AUTO_FILL_DRAWING_THRESHOLD = 400
    AUTO_FILL_HEAVY_RATIO = 0.60
    AUTO_FILL_STROKE_MAX = 0.22
    AUTO_FILL_PURE_RATIO = 0.95
    AUTO_FILL_PURE_STROKE_MAX = 0.02
    AUTO_FILL_PURE_MIN_GROUPS = 12
    AUTO_FILL_PURE_MIN_ITEMS = 24
    AUTO_FILL_PURE_LARGE_RECT_RATIO = 0.03

    def self.path_bbox(path)
      return nil unless path && path.respond_to?(:subpaths) && path.subpaths
      min_x = nil
      min_y = nil
      max_x = nil
      max_y = nil

      path.subpaths.each do |sp|
        next unless sp && sp.respond_to?(:segments) && sp.segments
        sp.segments.each do |seg|
          next unless seg && seg.respond_to?(:points) && seg.points
          seg.points.each do |pt|
            next unless pt && pt.length >= 2
            x = pt[0].to_f
            y = pt[1].to_f
            min_x = x if min_x.nil? || x < min_x
            min_y = y if min_y.nil? || y < min_y
            max_x = x if max_x.nil? || x > max_x
            max_y = y if max_y.nil? || y > max_y
          end
        end
      end
      return nil if min_x.nil? || min_y.nil? || max_x.nil? || max_y.nil?
      [min_x, min_y, max_x, max_y]
    end

    def self.vector_path_stats(paths, media_box)
      total = paths ? paths.length : 0
      empty = {
        total: 0,
        fill_only_ratio: 0.0,
        stroke_ratio: 0.0,
        fill_only_count: 0,
        stroke_count: 0,
        total_item_count: 0,
        max_rect_ratio: 0.0
      }
      return empty if total <= 0

      page_w = ((media_box[2] || 0).to_f - (media_box[0] || 0).to_f).abs
      page_h = ((media_box[3] || 0).to_f - (media_box[1] || 0).to_f).abs
      page_area = page_w * page_h
      page_area = 0.0 if page_area.nan? || page_area.infinite?

      fill_only = 0
      stroke_count = 0
      total_items = 0
      max_rect_ratio = 0.0

      paths.each do |path|
        has_fill = !!(path && path.fill)
        has_stroke = !!(path && path.stroke)
        fill_only += 1 if has_fill && !has_stroke
        stroke_count += 1 if has_stroke

        if path && path.respond_to?(:subpaths) && path.subpaths
          path.subpaths.each do |sp|
            total_items += sp.segments.length if sp && sp.respond_to?(:segments) && sp.segments
          end
        end

        if page_area > 0.0
          bbox = path_bbox(path)
          if bbox
            w = (bbox[2] - bbox[0]).abs
            h = (bbox[3] - bbox[1]).abs
            ratio = (w * h) / page_area
            max_rect_ratio = ratio if ratio > max_rect_ratio
          end
        end
      end

      {
        total: total,
        fill_only_ratio: fill_only.to_f / total.to_f,
        stroke_ratio: stroke_count.to_f / total.to_f,
        fill_only_count: fill_only,
        stroke_count: stroke_count,
        total_item_count: total_items,
        max_rect_ratio: max_rect_ratio
      }
    end

    def self.looks_like_fill_art_flood?(paths, media_box)
      stats = vector_path_stats(paths, media_box)
      n = stats[:total]
      fill_ratio = stats[:fill_only_ratio]
      stroke_ratio = stats[:stroke_ratio]
      total_items = stats[:total_item_count]
      max_rect_ratio = stats[:max_rect_ratio]

      # Average items per drawing — glyph/fill-art floods have 1-3 items,
      # real drawings (garden plans, floor plans) have many more
      avg_items = n > 0 ? total_items.to_f / n : 0.0

      pure_fill = fill_ratio >= AUTO_FILL_PURE_RATIO &&
                  stroke_ratio <= AUTO_FILL_PURE_STROKE_MAX &&
                  avg_items <= 5.0
      if pure_fill && n >= AUTO_FILL_PURE_MIN_GROUPS
        if total_items >= AUTO_FILL_PURE_MIN_ITEMS ||
           max_rect_ratio >= AUTO_FILL_PURE_LARGE_RECT_RATIO
          return [true, stats]
        end
      end

      if n >= AUTO_FILL_DRAWING_THRESHOLD &&
         fill_ratio >= AUTO_FILL_HEAVY_RATIO &&
         stroke_ratio <= AUTO_FILL_STROKE_MAX &&
         avg_items <= 5.0
        return [true, stats]
      end

      [false, stats]
    end

    def self.fit_ignored_entity?(entity)
      return true unless entity
      return true if defined?(Sketchup::Text) && entity.is_a?(Sketchup::Text)
      return true if defined?(Sketchup::Dimension) && entity.is_a?(Sketchup::Dimension)
      false
    end

    def self.fit_usable_bounds?(bb)
      return false unless bb && bb.valid?
      begin
        dx = (bb.max.x.to_f - bb.min.x.to_f).abs
        dy = (bb.max.y.to_f - bb.min.y.to_f).abs
        dz = (bb.max.z.to_f - bb.min.z.to_f).abs
        (dx + dy + dz) > 1.0e-9
      rescue StandardError
        false
      end
    end

    def self.normalize_page_arrangement(raw)
      key = raw.to_s.strip.downcase
      return :overlay if key.include?("overlay")
      return :touch if key.include?("touch")
      return :compact if key.include?("compact")
      :spread
    end

    def self.normalize_page_gap_ratio(raw)
      val = begin
        Float(raw)
      rescue StandardError
        0.20
      end
      val = 0.20 unless val.finite?
      [[val, 0.0].max, 1.0].min
    end

    def self.page_stack_step(page_height_in, arrangement, gap_ratio)
      h = page_height_in.to_f
      h = 11.0 if h <= 0.0
      case arrangement
      when :overlay
        0.0
      when :touch
        h
      when :compact
        h * (1.0 + gap_ratio.to_f)
      else
        h * 1.2
      end
    end

    # Add a deterministic page-sized fit box in SketchUp model space.
    # This makes "fit all" resilient even when imported entities contain
    # sparse labels, nested groups, or occasional outlier bounds.
    def self.add_page_fit_bounds(target_bb, media_box, render_box, scale, y_offset)
      return unless target_bb
      return unless media_box.is_a?(Array) && media_box.length >= 4
      return unless render_box.is_a?(Array) && render_box.length >= 4

      s = scale.to_f
      s = 1.0 if s <= 0.0
      oy = y_offset.to_f

      mx0 = media_box[0].to_f
      my0 = media_box[1].to_f

      rx0 = render_box[0].to_f
      ry0 = render_box[1].to_f
      rx1 = render_box[2].to_f
      ry1 = render_box[3].to_f

      x0 = (rx0 - mx0) * (1.0 / 72.0) * s
      y0 = (ry0 - my0) * (1.0 / 72.0) * s + oy
      x1 = (rx1 - mx0) * (1.0 / 72.0) * s
      y1 = (ry1 - my0) * (1.0 / 72.0) * s + oy

      bb = Geom::BoundingBox.new
      bb.add(Geom::Point3d.new(x0, y0, 0.0))
      bb.add(Geom::Point3d.new(x1, y1, 0.0))
      return unless fit_usable_bounds?(bb)

      target_bb.add(bb)
    rescue StandardError => e
      Logger.warn("Pipeline", "add_page_fit_bounds failed: #{e.message}")
    end

    def self.bb_corners(bb)
      mn = bb.min
      mx = bb.max
      [
        Geom::Point3d.new(mn.x, mn.y, mn.z),
        Geom::Point3d.new(mx.x, mn.y, mn.z),
        Geom::Point3d.new(mn.x, mx.y, mn.z),
        Geom::Point3d.new(mx.x, mx.y, mn.z),
        Geom::Point3d.new(mn.x, mn.y, mx.z),
        Geom::Point3d.new(mx.x, mn.y, mx.z),
        Geom::Point3d.new(mn.x, mx.y, mx.z),
        Geom::Point3d.new(mx.x, mx.y, mx.z)
      ]
    end

    def self.add_bounds_with_transform(target_bb, source_bb, transform = nil)
      return unless fit_usable_bounds?(source_bb)
      if transform
        bb_corners(source_bb).each { |pt| target_bb.add(pt.transform(transform)) }
      else
        target_bb.add(source_bb)
      end
    rescue StandardError
      nil
    end

    # Collect bounds recursively while ignoring text/dimension annotations.
    # This prevents a single outlier label from blowing up fit extents.
    def self.collect_fit_bounds(entity, out_bb, parent_transform = nil, depth = 0)
      return if entity.nil? || !entity.valid?
      return if fit_ignored_entity?(entity)
      return if depth > 12

      if defined?(Sketchup::Group) && entity.is_a?(Sketchup::Group)
        world_t = parent_transform ? (parent_transform * entity.transformation) : entity.transformation
        nested = Geom::BoundingBox.new
        entity.entities.each { |child| collect_fit_bounds(child, nested, world_t, depth + 1) }
        if fit_usable_bounds?(nested)
          out_bb.add(nested)
        end
        return
      end

      if defined?(Sketchup::ComponentInstance) && entity.is_a?(Sketchup::ComponentInstance)
        world_t = parent_transform ? (parent_transform * entity.transformation) : entity.transformation
        nested = Geom::BoundingBox.new
        entity.definition.entities.each { |child| collect_fit_bounds(child, nested, world_t, depth + 1) }
        if fit_usable_bounds?(nested)
          out_bb.add(nested)
        end
        return
      end

      add_bounds_with_transform(out_bb, entity.bounds, parent_transform)
    rescue StandardError
      nil
    end

    def self.apply_camera_top_ortho(view, bb)
      return unless view && fit_usable_bounds?(bb)
      center = bb.center
      eye = Geom::Point3d.new(center.x, center.y, center.z + 1000)
      target = center
      up = Geom::Vector3d.new(0, 1, 0)
      view.camera = Sketchup::Camera.new(eye, target, up)
      view.camera.perspective = false
    rescue StandardError
      nil
    end

    # Zoom to imported geometry only — avoids reframing the whole model.
    def self.zoom_extents_imported_only(model, view, imported_roots)
      roots = Array(imported_roots).select { |e| e && e.valid? }
      return false if roots.empty?

      hidden = []
      begin
        model.active_entities.each do |e|
          next unless e.valid? && e.respond_to?(:visible?)
          next if roots.include?(e)
          next unless e.visible?
          e.visible = false
          hidden << e
        end
        view.zoom_extents
        true
      rescue StandardError
        false
      ensure
        hidden.each do |e|
          begin
            e.visible = true if e.valid?
          rescue StandardError
            next
          end
        end
      end
    end

    def self.apply_top_view_fit(model, preferred_bb = nil, imported_entities = nil)
      return unless model
      view = model.active_view
      return unless view

      bb = Geom::BoundingBox.new
      bb.add(preferred_bb) if fit_usable_bounds?(preferred_bb)

      fit_targets = []
      unless fit_usable_bounds?(bb)
        targets = Array(imported_entities)
        if targets.empty?
          begin
            targets = model.active_entities.to_a
          rescue StandardError
            targets = []
          end
        end

        fit_targets = targets.select do |e|
          next false unless e && e.valid? && e.respond_to?(:bounds)
          next false if fit_ignored_entity?(e)
          fit_usable_bounds?(e.bounds)
        end

        # If a page only produced label entities, still fit to what was imported.
        if fit_targets.empty?
          fit_targets = targets.select do |e|
            e && e.valid? && e.respond_to?(:bounds) && fit_usable_bounds?(e.bounds)
          end
        end
        fit_targets.each { |e| collect_fit_bounds(e, bb) }
      end

      fit_entities = Array(imported_entities).select { |e| e && e.valid? }
      if fit_entities.empty?
        fit_entities = fit_targets
      end

      framed = false
      if fit_usable_bounds?(bb)
        apply_camera_top_ortho(view, bb)
        begin
          view.zoom(bb)
          framed = true
        rescue StandardError
          framed = false
        end

        # SketchUp 2017 often no-ops on zoom(bb) without error; entity zoom is reliable.
        unless fit_entities.empty?
          begin
            view.zoom(fit_entities)
            framed = true
          rescue StandardError
          end
        end
      end

      unless framed
        framed = zoom_extents_imported_only(model, view, fit_entities)
      end

      # Last resort: model-wide extents when we have no import bounds at all.
      view.zoom_extents unless framed
    rescue StandardError => e
      Logger.warn("Pipeline", "Auto-fit view failed: #{e.message}")
      begin
        if view && zoom_extents_imported_only(model, view, Array(imported_entities))
          return
        end
        view.zoom_extents if view
      rescue StandardError
      end
    end

    def self.run_pipeline(model, path, opts)
      Logger.reset
      config = RecognitionConfig.default

      # ── Force raster: skip all vector parsing, render as image ──
      if opts[:force_raster]
        dpi = opts[:raster_dpi] || 300
        Logger.warn("Pipeline", "Force-raster mode at #{dpi} DPI")
        model.start_operation("Import PDF Raster", true)
        media_box = [0, 0, 612, 792]  # default; overridden per-page below
        crop_box = nil
        import_start = Time.now
        # Try to get actual page size from parser
        begin
          p = PDFParser.new(path)
          p.parse
          if p.page_count > 0
            pg = p.pages.first
            media_box = pg[:media_box] if pg && pg[:media_box]
            if pg && pg[:crop_box].is_a?(Array) && pg[:crop_box].length >= 4
              crop_box = pg[:crop_box]
            end
          end
        rescue StandardError => e
          Logger.warn("Pipeline", "Could not read page size: #{e.message}")
        end
        raster_box = crop_box || media_box
        raster_ok = import_page_as_raster(
          model, path, 1, media_box, opts, import_start, 0.0, raster_box
        )
        if raster_ok
          model.commit_operation
          fit_bb = Geom::BoundingBox.new
          add_page_fit_bounds(fit_bb, media_box, raster_box, opts[:scale], 0.0)
          apply_top_view_fit(model, fit_bb)
          return { pages: 1, primitives: 0, edges: 0, faces: 0, arcs: 0,
                   text: 0, components: 0, layers: [], cleanup: {},
                   generic: nil, mode_used: nil, xobjects: 0,
                   raster_fallback_used: true,
                   log_path: Logger.log_path }
        else
          model.abort_operation
          UI.messagebox("Force-raster import failed.\n\nMake sure pdftocairo (from Poppler) is installed.")
          return nil
        end
      end

      # ── File size warning for very large PDFs ──
      begin
        file_size_bytes = File.size(path)
        if file_size_bytes > 100 * 1024 * 1024
          size_mb = (file_size_bytes / (1024.0 * 1024.0)).round(1)
          choice = UI.messagebox(
            "This PDF is very large (#{size_mb} MB). Import may take a significant " \
            "amount of time and use considerable memory. Continue?",
            MB_OKCANCEL)
          return nil unless choice == IDOK
        end
      rescue StandardError => e
        Logger.warn("Pipeline", "File size check failed: #{e.message}")
      end

      parser = PDFParser.new(path)
      parser.parse
      if parser.page_count == 0
        # Parser failed (compressed xref, unsupported features, etc.)
        # Try raster fallback before giving up
        if opts[:raster_fallback]
          Logger.warn("Pipeline", "PDF parser found 0 pages — attempting raster fallback")
          model.start_operation("Import PDF Raster", true)
          media_box = [0, 0, 612, 792]  # default letter size
          import_start = Time.now
          raster_ok = import_page_as_raster(model, path, 1, media_box, opts, import_start)
          if raster_ok
            model.commit_operation
            fit_bb = Geom::BoundingBox.new
            add_page_fit_bounds(fit_bb, media_box, media_box, opts[:scale], 0.0)
            apply_top_view_fit(model, fit_bb)
            return { pages: 1, primitives: 0, edges: 0, faces: 0, arcs: 0,
                     text: 0, components: 0, layers: [], cleanup: {},
                     generic: nil, mode_used: nil, xobjects: 0,
                     text_mode: :none,
                     elapsed_seconds: (Time.now - import_start).round(1),
                     raster_fallback_used: true,
                     log_path: Logger.log_path }
          else
            safe_abort_operation(model, "Pipeline")
          end
        end
        return nil
      end

      ocg = OCGParser.new(parser)
      ocg.parse

      pages = opts[:pages]
      pages = (1..parser.page_count).to_a if pages == :all
      pages = pages.select { |p| p >= 1 && p <= parser.page_count }
      return nil if pages.empty?

      # Track new entities in the currently active editing context.
      # Using model.entities misses imports done while editing groups/components.
      pre_import_entities = model.active_entities.to_a
      model.start_operation("Import PDF Vectors", true)

      # Reset ID counter once at the start of a multi-page import
      IDGen.reset

      ocg.layer_list.each do |n|
        t = "PDF::Layer::#{n}"
        model.layers.add(t) unless model.layers[t]
      end

      requested_text_mode = opts[:text_mode]
      requested_text_mode ||= (opts[:use_3d_text] ? :geometry : (opts[:import_text] ? :labels : :none))
      requested_text_mode = :none unless opts[:import_text]

      stats = { pages: 0, primitives: 0, edges: 0, faces: 0, arcs: 0,
                text: 0, components: 0, layers: ocg.layer_list, cleanup: {},
                generic: nil, mode_used: nil, xobjects: 0,
                text_mode: requested_text_mode }
      page_fit_bounds = Geom::BoundingBox.new

      import_start = Time.now
      page_arrangement = normalize_page_arrangement(opts[:page_arrangement])
      page_gap_ratio = normalize_page_gap_ratio(opts[:page_gap_ratio])
      running_y_offset = 0.0

      pages.each_with_index do |page_num, idx|
       begin
        pct = pages.length > 1 ? " (#{((idx.to_f / pages.length) * 100).round}%)" : ""
        elapsed = (Time.now - import_start).round(1)

        Sketchup.status_text = "PDF Import#{pct} — Page #{page_num}/#{parser.page_count} — Parsing... [#{elapsed}s]"

        raw = parser.page_data(page_num)
        next unless raw
        media_box = raw[:media_box] || [0, 0, 612, 792]
        crop_box = raw[:crop_box]
        crop_box = nil unless crop_box.is_a?(Array) && crop_box.length >= 4
        svg_page_box = crop_box || media_box
        text_offset_x = svg_page_box[0].to_f - media_box[0].to_f
        text_offset_y = svg_page_box[1].to_f - media_box[1].to_f
        Logger.info("Pipeline",
          "Page #{page_num}: text_mode=#{requested_text_mode}, media_box=#{media_box.inspect}, " \
          "crop_box=#{crop_box ? crop_box.inspect : 'nil'}, text_offset_pts=(#{text_offset_x.round(3)},#{text_offset_y.round(3)})")
        stack_box = svg_page_box
        curr_page_height_in = (stack_box[3].to_f - stack_box[1].to_f).abs * (1.0 / 72.0) * opts[:scale].to_f
        curr_page_height_in = 11.0 * opts[:scale].to_f if curr_page_height_in <= 0.0
        page_y_offset = running_y_offset
        streams = raw[:content_streams]
        if streams.nil? || streams.empty?
          # No content streams — try raster fallback instead of skipping
          if opts[:raster_fallback]
            Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — No streams, trying raster... [#{elapsed}s]"
            raster_ok = import_page_as_raster(
              model, path, page_num, media_box, opts, import_start, page_y_offset, svg_page_box
            )
            if raster_ok
              stats[:pages] += 1
              stats[:raster_fallback_used] = true
              add_page_fit_bounds(page_fit_bounds, media_box, stack_box, opts[:scale], page_y_offset)
              running_y_offset += page_stack_step(curr_page_height_in, page_arrangement, page_gap_ratio)
            end
          end
          next
        end

        Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Reading paths... [#{elapsed}s]"
        ocg_map = parser.page_ocg_map(page_num)
        cs = ContentStreamParser.new(streams, parser, ocg_map)
        paths = cs.parse
        force_import_fills_for_page = false

        # Smart auto-raster override for fill-art flood pages.
        flood_hit, flood_stats = looks_like_fill_art_flood?(paths, media_box)
        if flood_hit
          fill_pct = (flood_stats[:fill_only_ratio] * 100.0).round
          stroke_pct = (flood_stats[:stroke_ratio] * 100.0).round
          Logger.warn(
            "Pipeline",
            "Page #{page_num}: smart mode override — fill-art flood — " \
            "#{flood_stats[:total]} groups, fill-only=#{fill_pct}%, " \
            "strokes=#{stroke_pct}% (map/decorative PDF — vectors would be unusable geometry)"
          )

          if opts[:raster_fallback]
            Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Fill-art flood, rendering raster... [#{(Time.now - import_start).round(1)}s]"
            raster_ok = import_page_as_raster(
              model, path, page_num, media_box, opts, import_start, page_y_offset, svg_page_box
            )
            if raster_ok
              stats[:pages] += 1
              stats[:raster_fallback_used] = true
              add_page_fit_bounds(page_fit_bounds, media_box, stack_box, opts[:scale], page_y_offset)
              running_y_offset += page_stack_step(curr_page_height_in, page_arrangement, page_gap_ratio)
              next
            end
            Logger.warn("Pipeline", "Page #{page_num}: fill-art raster fallback failed; continuing with vectors.")
            if !opts[:import_fills]
              force_import_fills_for_page = true
              Logger.warn(
                "Pipeline",
                "Page #{page_num}: enabling fill import for this page because raster fallback failed."
              )
            end
          else
            Logger.warn("Pipeline", "Page #{page_num}: fill-art flood detected but raster fallback is disabled.")
          end
        end

        xobj = XObjectParser.new(parser)
        xobj.scan_page(page_num)
        xobj.count_references(streams)
        xobj_paths = xobj.expanded_paths(streams)
        if xobj_paths && !xobj_paths.empty?
          paths += xobj_paths
          Logger.info("Pipeline",
            "Page #{page_num}: merged #{xobj_paths.length} transformed XObject path group(s).")
        end

        text_items = []
        if opts[:import_text]
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Extracting text... [#{(Time.now - import_start).round(1)}s]"
          strict_text_fidelity = !!opts[:strict_text_fidelity]
          text3d_mode = (requested_text_mode == :text3d)
          # Strict mode is opt-in only. For text3d we still prefer internal
          # placement, but do not force strict token mode (it can regress
          # reconstructed dimensions like 15/16 and 3'-10 1/2).
          strict_text_processing = strict_text_fidelity
          # For text3d, baseline/matrix placement from stream parsing is usually
          # the most stable for rotated/angled dimensions and callouts.
          prefer_internal_text = text3d_mode || strict_text_processing
          # Guard: skip internal parsing for very large streams (>5MB total).
          # The internal Ruby parser is too slow for monster PDFs like GIS maps.
          # Fall through to external pdftotext which handles them efficiently.
          stream_bytes = streams.inject(0) { |sum, s| sum + s.length }
          stream_limit_mb = text3d_mode ? 24.0 : 5.0
          env_limit = ENV['BC_SU_INTERNAL_TEXT_MAX_MB']
          if env_limit && !env_limit.to_s.strip.empty?
            begin
              parsed_limit = env_limit.to_f
              stream_limit_mb = parsed_limit if parsed_limit > 0.0
            rescue StandardError
              # keep default threshold
            end
          end
          stream_limit_bytes = (stream_limit_mb * 1_000_000.0).to_i
          if stream_bytes > stream_limit_bytes
            Logger.warn("Pipeline",
              "Page #{page_num}: #{(stream_bytes / 1_000_000.0).round(1)}MB streams " \
              "(limit #{stream_limit_mb.round(1)}MB) — using external text extractor")
            prefer_internal_text = false
          end
          if prefer_internal_text
            font_maps = parser.page_font_maps(page_num)
            parser_opts = { strict_text_fidelity: strict_text_processing }
            # For 3D text, preserving native spans avoids accidental
            # concatenation/offset caused by run-merge heuristics.
            parser_opts[:merge_text_runs] = false if requested_text_mode == :text3d
            text_items = TextParser.new(streams, font_maps, parser_opts).parse
            text_source = :internal
            if text_items.nil? || text_items.empty?
              text_items = ExternalTextExtractor.extract(path, page_num,
                offset_x_pts: text_offset_x, offset_y_pts: text_offset_y,
                strict_text_fidelity: strict_text_processing)
              text_source = :external
            end
          else
            text_items = ExternalTextExtractor.extract(path, page_num,
              offset_x_pts: text_offset_x, offset_y_pts: text_offset_y,
              strict_text_fidelity: strict_text_processing)
            text_source = :external
            if text_items.nil? || text_items.empty?
              font_maps = parser.page_font_maps(page_num)
              parser_opts = { strict_text_fidelity: strict_text_processing }
              parser_opts[:merge_text_runs] = false if requested_text_mode == :text3d
              text_items = TextParser.new(streams, font_maps, parser_opts).parse
              text_source = :internal
            end
          end
          Logger.info("Pipeline", "Page #{page_num}: text extractor=#{text_source}, items=#{text_items ? text_items.length : 0}")
        end

        # If the page is text-dominant with little/no vector geometry, importing
        # only text produces misaligned/low-trust results on OCR/geospatial PDFs.
        # Prefer a faithful raster import in this case.
        if opts[:raster_fallback] && paths.length <= 10 && text_items.length >= 200
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Text-heavy page, using raster fallback... [#{(Time.now - import_start).round(1)}s]"
          Logger.warn("Pipeline",
            "Page #{page_num}: text-dominant content (paths=#{paths.length}, text=#{text_items.length}) — raster fallback")
          raster_ok = import_page_as_raster(
            model, path, page_num, media_box, opts, import_start, page_y_offset, svg_page_box
          )
          if raster_ok
            stats[:pages] += 1
            stats[:raster_fallback_used] = true
            add_page_fit_bounds(page_fit_bounds, media_box, stack_box, opts[:scale], page_y_offset)
            running_y_offset += page_stack_step(curr_page_height_in, page_arrangement, page_gap_ratio)
            next
          end
          Logger.warn("Pipeline", "Page #{page_num}: text-dominant raster fallback failed; continuing with vectors/text.")
        end

        if paths.empty? && text_items.empty?
          if opts[:raster_fallback]
            Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Rendering raster image... [#{(Time.now - import_start).round(1)}s]"
            raster_ok = import_page_as_raster(
              model, path, page_num, media_box, opts, import_start, page_y_offset, svg_page_box
            )
            if raster_ok
              stats[:pages] += 1
              stats[:edges] += 0
              add_page_fit_bounds(page_fit_bounds, media_box, stack_box, opts[:scale], page_y_offset)
              running_y_offset += page_stack_step(curr_page_height_in, page_arrangement, page_gap_ratio)
            else
              Logger.warn("Pipeline",
                "Page #{page_num}: no vector content and raster render failed; page skipped.")
            end
          end
          next
        end

        Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — #{paths.length} paths, #{text_items.length} text items... [#{(Time.now - import_start).round(1)}s]"

        page_data = PrimitiveExtractor.extract(paths, text_items, media_box, page_num,
          scale: opts[:scale], bezier_segments: opts[:bezier_segments])
        page_data.layers = ocg.layer_list
        page_data.xobject_names = xobj.form_xobjects.keys
        stats[:primitives] += page_data.primitives.length
        stats[:pages] += 1
        stats[:xobjects] += xobj.form_xobjects.length

        recog_mode = opts[:recognition_mode] || :auto
        recognition = nil
        if recog_mode != :none
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Analyzing document... [#{(Time.now - import_start).round(1)}s]"
          recognition = Recognizer.run(page_data, mode: recog_mode, config: config)
          stats[:mode_used] = recognition[:mode_used]
          if recognition[:generic]
            g = recognition[:generic]
            stats[:generic] = {
              circles: g.circles.length, boundaries: g.closed_boundaries.length,
              patterns: g.repeated_patterns.length, tables: g.tables.length,
              title_block: g.title_block_bbox ? true : false,
              dimensions: g.dimension_assocs.length,
              profile: g.page_profile.primary_type }
          end
        end

        # ── Complexity warning for very large pages ──
        total_subpaths = paths.inject(0) { |sum, p| sum + p.subpaths.length }
        if paths.length > 5000 || total_subpaths > 10000
          Logger.warn("Pipeline",
            "Page #{page_num}: heavy page (#{paths.length} paths, " \
            "#{total_subpaths} subpaths). Import may take several minutes.")
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Heavy page: #{paths.length} paths (this may take a while)... [#{(Time.now - import_start).round(1)}s]"
        else
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Building #{paths.length} paths... [#{(Time.now - import_start).round(1)}s]"
        end

        # ── Hatch detection ──
        hatch_mode = opts[:hatch_mode] || :import
        hatch_paths = []
        if hatch_mode != :import && paths.length > 20
          hatch_indices = HatchDetector.detect(page_data.primitives)
          if hatch_indices && !hatch_indices.empty?
            hatch_set = hatch_indices.to_a
            if hatch_mode == :skip
              paths = paths.each_with_index.reject { |_, i| hatch_set.include?(i) }.map(&:first)
            elsif hatch_mode == :group
              hatch_paths = paths.each_with_index.select { |_, i| hatch_set.include?(i) }.map(&:first)
              paths = paths.each_with_index.reject { |_, i| hatch_set.include?(i) }.map(&:first)
            end
          end
        end

        # When geometry text mode: try pdftocairo first, skip text in builder
        use_svg_text = (requested_text_mode == :geometry) && opts[:import_text]
        builder_use_3d_text = (requested_text_mode == :text3d)
        builder_text_items = use_svg_text ? [] : text_items

        builder = GeometryBuilder.new(model, paths, builder_text_items, media_box,
          scale_factor: opts[:scale], bezier_segments: opts[:bezier_segments],
          import_as: opts[:import_as], layer_name: opts[:layer_name],
          group_per_page: opts[:group_per_page], page_number: page_num,
          flatten_to_2d: true, merge_tolerance: opts[:merge_tolerance],
          import_fills: (opts[:import_fills] || force_import_fills_for_page), group_by_color: opts[:group_by_color],
          detect_arcs: opts[:detect_arcs], map_dashes: opts[:map_dashes],
          import_text: use_svg_text ? false : opts[:import_text],
          use_3d_text: builder_use_3d_text,
          strict_text_fidelity: opts[:strict_text_fidelity],
          y_offset: page_y_offset)
        result = builder.build
        stats[:edges] += result[:edges]; stats[:faces] += result[:faces]
        stats[:arcs] += result[:arcs]; stats[:text] += result[:text_objects]

        # Build hatching on separate layer if group mode
        if hatch_mode == :group && !hatch_paths.empty? && builder.page_group
          hatch_layer_name = "#{opts[:layer_name] || 'PDF Import'}:Hatching"
          hatch_builder = GeometryBuilder.new(model, hatch_paths, [], media_box,
            scale_factor: opts[:scale], bezier_segments: opts[:bezier_segments],
            import_as: :edges, layer_name: hatch_layer_name,
            group_per_page: false, page_number: page_num,
            flatten_to_2d: true, merge_tolerance: opts[:merge_tolerance],
            import_fills: false, group_by_color: false,
            detect_arcs: false, map_dashes: false,
            import_text: false, use_3d_text: false,
            target_entities: builder.page_group.entities)
          hatch_result = hatch_builder.build
          stats[:edges] += hatch_result[:edges]
          # Default hatching layer to hidden
          begin
            hl = model.layers[hatch_layer_name]
            hl.visible = false if hl
          rescue StandardError => e
            Logger.warn("Main", "hide hatch layer failed: #{e.message}")
          end
        end

        # Render text as precise vector geometry via pdftocairo
        if use_svg_text && builder.page_group
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Rendering text geometry... [#{(Time.now - import_start).round(1)}s]"
          text_layer_name = "#{opts[:layer_name] || 'PDF Import'}:Text"
          text_layer = model.layers[text_layer_name] ||
                       model.layers.add(text_layer_name)
          svg_result = SvgTextRenderer.render(
            builder.page_group.entities, path, page_num, media_box,
            scale: opts[:scale], layer: text_layer, y_offset: page_y_offset,
            svg_page_box: svg_page_box)

          if svg_result
            stats[:text] += svg_result[:glyphs]
            stats[:edges] += svg_result[:edges]
            stats[:text_mode] = :geometry
          else
            # SVG glyph text unavailable/disabled — preserve the user's selected
            # fallback intent (geometry/text3d => add_3d_text, labels => add_text).
            Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Fallback text rendering... [#{(Time.now - import_start).round(1)}s]"
            fallback_use_3d = (requested_text_mode == :geometry || requested_text_mode == :text3d)
            fallback_mode = fallback_use_3d ? "3D text" : "labels"
            Logger.warn("Pipeline", "SVG text unavailable — falling back to #{fallback_mode} text")
            fallback_builder = GeometryBuilder.new(model, [], text_items, media_box,
              scale_factor: opts[:scale], layer_name: opts[:layer_name],
              group_per_page: false, page_number: page_num,
              flatten_to_2d: true, import_text: true, use_3d_text: fallback_use_3d,
              strict_text_fidelity: opts[:strict_text_fidelity],
              y_offset: page_y_offset,
              target_entities: builder.page_group.entities)
            fb_result = fallback_builder.build
            stats[:text] += fb_result[:text_objects]
            stats[:text_mode] = fallback_use_3d ? :text3d : :labels
          end
        end

        if opts[:cleanup_geometry] && builder.page_group
          Sketchup.status_text = "PDF Import#{pct} — Page #{page_num} — Cleaning up geometry... [#{(Time.now - import_start).round(1)}s]"
          cl = GeometryCleanup.cleanup(builder.page_group.entities,
            merge_tolerance:    opts[:merge_tolerance],
            min_edge_length:    opts[:merge_tolerance],
            cleanup_level:      opts[:cleanup_level])
          cl.each { |k, v| stats[:cleanup][k] = (stats[:cleanup][k] || 0) + v }
        end

        add_page_fit_bounds(page_fit_bounds, media_box, stack_box, opts[:scale], page_y_offset)

        # Advance the running page stack only after a successful import.
        running_y_offset += page_stack_step(curr_page_height_in, page_arrangement, page_gap_ratio)

      rescue StandardError => e
        Logger.error("Pipeline", "Page #{page_num} failed: #{e.message}", e)
        stats[:failed_pages] ||= []
        stats[:failed_pages] << { page: page_num, error: e.message }
        # Continue to next page instead of aborting the entire operation.
        # Previously this called safe_abort_operation + raise, which
        # destroyed all geometry from successfully imported pages.
      end
      end

      model.commit_operation

      # Release the raw PDF buffer and object cache to free memory.
      begin
        parser.release
      rescue StandardError => e
        Logger.warn("Pipeline", "parser.release failed: #{e.message}")
      end

      elapsed = (Time.now - import_start).round(1)
      Sketchup.status_text = "PDF Import complete — #{stats[:edges]} edges, #{stats[:text]} text items — #{elapsed}s"

      stats[:elapsed_seconds] = elapsed

      # ── Auto fit view to newly imported geometry (not model-wide extents) ──
      imported_entities = []
      begin
        imported_entities = model.active_entities.to_a - pre_import_entities
      rescue StandardError
        imported_entities = []
      end
      apply_top_view_fit(model, page_fit_bounds, imported_entities)

      stats[:log_path] = Logger.log_path
      stats
    ensure
      Logger.flush_log
    end

    # ================================================================
    # RASTER FALLBACK — render scanned page as positioned image
    # ================================================================
    def self.compute_effective_raster_dpi(opts, page_w_pts, page_h_pts)
      requested = (opts[:raster_dpi] || 300).to_i
      requested = 300 if requested <= 0
      requested = [[requested, 150].max, 1200].min

      # Safe sharpening default:
      # if user kept the legacy 300 DPI default, raise target modestly.
      desired = requested
      desired = 400 if requested <= 300

      page_w_in = page_w_pts.to_f / 72.0
      page_h_in = page_h_pts.to_f / 72.0
      page_area_in2 = page_w_in * page_h_in
      page_area_in2 = 1.0 if page_area_in2 <= 0.0 || !page_area_in2.finite?

      # Guardrail against giant raster allocations.
      pixel_budget = (opts[:raster_pixel_budget] || 120_000_000).to_i
      pixel_budget = [[pixel_budget, 25_000_000].max, 240_000_000].min
      cap_from_budget = Math.sqrt(pixel_budget.to_f / page_area_in2).floor
      cap_from_budget = [[cap_from_budget, 150].max, 1200].min

      effective = [desired, cap_from_budget].min
      effective = [[effective, 150].max, 1200].min

      {
        requested: requested,
        desired: desired,
        effective: effective,
        cap: cap_from_budget,
        pixel_budget: pixel_budget
      }
    rescue StandardError => e
      Logger.warn("Raster", "DPI planner failed: #{e.message}")
      { requested: 300, desired: 300, effective: 300, cap: 300, pixel_budget: 120_000_000 }
    end

    def self.import_page_as_raster(model, pdf_path, page_num, media_box, opts, import_start, y_offset = 0.0, render_box = nil)
      exe = safe_find_pdftocairo
      return false unless exe

      # Render/placement box (usually CropBox when available, else MediaBox).
      render_box = media_box unless render_box.is_a?(Array) && render_box.length >= 4
      media_min_x = media_box[0].to_f
      media_min_y = media_box[1].to_f
      render_min_x = render_box[0].to_f
      render_min_y = render_box[1].to_f
      page_w_pts = (render_box[2] - render_box[0]).abs
      page_h_pts = (render_box[3] - render_box[1]).abs
      page_w_pts = 612.0 if page_w_pts < 1
      page_h_pts = 792.0 if page_h_pts < 1
      dpi_plan = compute_effective_raster_dpi(opts, page_w_pts, page_h_pts)
      dpi = dpi_plan[:effective]

      use_cropbox = false
      begin
        if media_box.is_a?(Array) && media_box.length >= 4 &&
           render_box.is_a?(Array) && render_box.length >= 4
          use_cropbox = render_box.zip(media_box).any? { |a, b| (a.to_f - b.to_f).abs > 0.01 }
        end
      rescue StandardError => e
        Logger.warn("Raster", "cropbox compare failed: #{e.message}")
      end

      # Render page to PNG
      png_path = File.join(Dir.tmpdir,
        "bc_raster_#{Process.pid}_#{Time.now.to_i}_p#{page_num}.png")

      args = [exe, '-png', '-singlefile', '-r', dpi.to_s]
      args << '-cropbox' if use_cropbox
      args += [
              '-f', page_num.to_s, '-l', page_num.to_s,
              pdf_path, png_path.sub(/\.png$/, '')]
      run = CommandRunner.run(
        args,
        timeout_s: 180,
        context: "Raster.pdftocairo"
      )

      # With -singlefile, output should be exactly png_path.
      # Keep legacy candidates for compatibility with older Poppler builds.
      actual_png = nil
      [png_path,
       png_path.sub(/\.png$/, "-#{page_num}.png"),
       png_path.sub(/\.png$/, "-01.png"),
       png_path.sub(/\.png$/, "-1.png")
      ].each do |candidate|
        if File.exist?(candidate)
          actual_png = candidate
          break
        end
      end

      return false unless run[:ok] && actual_png && File.exist?(actual_png)

        begin
          scale = opts[:scale] || 1.0
          # Image size in inches = page pts / 72
          img_w = page_w_pts / 72.0 * scale
          img_h = page_h_pts / 72.0 * scale
        box_offset_x = (render_min_x - media_min_x) / 72.0 * scale
        box_offset_y = (render_min_y - media_min_y) / 72.0 * scale

        # Match vector page stacking so raster fallback pages do not overlap.
        pt = Geom::Point3d.new(box_offset_x, y_offset.to_f + box_offset_y, 0)
        begin
          # add_image available in SketchUp 2017+
          img = model.active_entities.add_image(actual_png, pt, img_w, img_h)
          if img
            layer = model.layers['PDF Import'] || model.layers.add('PDF Import')
            begin
              img.layer = layer if layer
            rescue StandardError => e
              Logger.warn("Raster", "Image layer assignment failed: #{e.message}")
            end
            box_msg = use_cropbox ? "cropbox" : "mediabox"
            req = dpi_plan[:requested]
            cap = dpi_plan[:cap]
            sharpened = dpi > req
            status_suffix = sharpened ? " (enhanced)" : ""
            Sketchup.status_text = "PDF Import — Page #{page_num} — Raster image placed at #{dpi} DPI#{status_suffix} [#{(Time.now - import_start).round(1)}s]"
            Logger.info(
              "Raster",
              "Page #{page_num}: placed #{box_msg} raster #{img_w.round(3)}x#{img_h.round(3)} in at " \
              "(#{pt.x.round(3)},#{pt.y.round(3)}), dpi req=#{req}, eff=#{dpi}, cap=#{cap}, budget=#{dpi_plan[:pixel_budget]}"
            )
            return true
          end
        rescue StandardError => e
          Logger.warn("Raster", "add_image failed: #{e.message}")
        end
      rescue StandardError => e
        Logger.warn("Raster", "Failed: #{e.message}")
      ensure
        begin
          File.delete(actual_png) if actual_png && File.exist?(actual_png)
        rescue StandardError => e
          Logger.warn("Main", "cleanup temp png failed: #{e.message}")
        end
      end
      false
    end

    # ================================================================
    # PUBLIC ENTRY POINTS
    # ================================================================
    def self.import_pdf
      model = Sketchup.active_model
      return UI.messagebox("No active model.") unless model
      path = UI.openpanel("Select PDF File", "", "PDF Files|*.pdf||")
      return unless path && File.exist?(path)
      begin
        opts = ImportDialog.show(path)
        return unless opts
        stats = run_pipeline(model, path, opts)
        if stats
          ReportDialog.show_report(stats)
        else
          UI.messagebox("No vector content found in PDF.")
        end
      rescue StandardError => e
        safe_abort_operation(model, "Import")
        Logger.error("Import", "Import failed", e)
        log_hint = Logger.log_path ? "\n\nDetails saved to:\n#{Logger.log_path}" : ""
        UI.messagebox("PDF import failed:\n#{e.message}#{log_hint}")
      end
    end

    def self.import_pdf_safe
      model = Sketchup.active_model
      return UI.messagebox("No active model.") unless model
      path = UI.openpanel("Select PDF File (Safe Mode)", "", "PDF Files|*.pdf||")
      return unless path && File.exist?(path)

      begin
        # BCS-ARCH-001: safe mode uses explicit Vector extraction
        # (no raster fallback) — the most predictable pure-vector path.
        mode = ImportDialog::MODES['Vector'] || {}
        sym_attrs = {}
        mode.each { |k, v| sym_attrs[k.to_sym] = v }
        opts = ImportDialog.send(:build_opts, sym_attrs.merge(pages: 'All'))
        stats = run_pipeline(model, path, opts)
        unless stats
          UI.messagebox("No vector content found in PDF.")
        end
      rescue StandardError => e
        safe_abort_operation(model, "ImportSafe")
        Logger.error("ImportSafe", "Safe mode import failed", e)
        log_hint = Logger.log_path ? "\n\nDetails saved to:\n#{Logger.log_path}" : ""
        UI.messagebox("PDF import failed:\n#{e.message}#{log_hint}")
      end
    end

    def self.batch_import
      model = Sketchup.active_model
      return UI.messagebox("No active model.") unless model
      # UI.select_directory is not available in SketchUp Make (free) editions.
      # Fall back to an inputbox for the folder path.
      folder = if UI.respond_to?(:select_directory)
                 UI.select_directory(title: "Select Folder of PDFs")
               else
                 result = UI.inputbox(["Folder path:"], [""], "Select Folder of PDFs")
                 result ? result[0] : nil
               end
      return unless folder && File.directory?(folder)
      pdfs = (Dir.glob(File.join(folder, "*.pdf")) + Dir.glob(File.join(folder, "*.PDF"))).uniq
      return UI.messagebox("No PDF files found.") if pdfs.empty?
      return unless UI.messagebox("Import #{pdfs.length} PDF(s) with Auto mode?", MB_YESNO) == IDYES
      ok = 0; fail_c = 0
      # BCS-ARCH-001: batch import uses Auto mode — per-page strategy selection.
      mode_raw = ImportDialog::MODES['Auto']
      sym_attrs = {}
      mode_raw.each { |k, v| sym_attrs[k.to_sym] = v }
      pdfs.sort.each_with_index do |pdf, idx|
        Sketchup.status_text = "Batch: #{idx+1}/#{pdfs.length} #{File.basename(pdf)}"
        begin
          opts = ImportDialog.send(:build_opts, sym_attrs.merge(pages: 'All'))
          ok += 1 if run_pipeline(model, pdf, opts)
        rescue StandardError => e
          fail_c += 1; Logger.error("Batch", File.basename(pdf), e)
        end
      end
      UI.messagebox("Batch: #{ok} imported, #{fail_c} failed, #{pdfs.length} total.")
    end

    def self.scale_by_reference; ScaleTool.activate; end
    def self.quick_scale; ScaleTool.quick_scale; end

    def self.cleanup_selected
      model = Sketchup.active_model; return unless model
      groups = model.selection.grep(Sketchup::Group)
      return UI.messagebox("Select groups to clean.") if groups.empty?
      model.start_operation("Cleanup", true)
      total = {}
      groups.each { |g| GeometryCleanup.cleanup(g.entities).each { |k,v| total[k]=(total[k]||0)+v } }
      model.commit_operation
      UI.messagebox("Cleanup:\n"+total.select{|_,v|v>0}.map{|k,v|"  #{v} #{k}"}.join("\n"))
    end

    def self.feature_inventory
      model = Sketchup.active_model; return unless model
      t = model.selection.grep(Sketchup::Group).first
      UI.messagebox(Metadata.report(t ? t.entities : model.active_entities))
    end

    def self.visibility_toggles; ReportDialog.show_visibility_menu; end

    # ================================================================
    # MENU & TOOLBAR
    # ================================================================
    if !@loaded && defined?(UI) && UI.respond_to?(:menu)
      UI.menu('File').add_item('Import PDF Vectors...') { self.import_pdf }

      sub = UI.menu('Extensions').add_submenu('PDF Vector Importer')
      sub.add_item('Import PDF...') { self.import_pdf }
      sub.add_item('Import PDF (Safe Mode)...') { self.import_pdf_safe }
      sub.add_item('Batch Import Folder...') { self.batch_import }
      sub.add_separator
      sub.add_item('Scale to Real Dimensions...') { self.scale_by_reference }
      sub.add_item('Quick Scale...') { self.quick_scale }
      sub.add_separator
      sub.add_item('About') {
        UI.messagebox(
          "PDF Vector Importer v#{PLUGIN_VERSION}\n" \
          "by BlueCollar Systems\n\n" \
          "Import PDF drawings as editable SketchUp geometry.\n\n" \
          "BUILT. NOT BOUGHT.")
      }

      @loaded = true
    end

    # ================================================================
    # File Importer — drag-drop + File > Import
    # Guarded: Sketchup::Importer only exists in SU 2017+ Pro/Make
    # (some early 2017 builds may lack it). If missing, the plugin
    # still works via the Extensions menu — just no File > Import.
    # ================================================================
    if defined?(Sketchup::Importer)
    class PDFFileImporter < Sketchup::Importer
      def description; "PDF Vector Drawings (*.pdf)"; end
      def file_extension; "pdf"; end
      def id; "com.bluecollar.pdfvectorimporter"; end
      def supports_options?; true; end

      def load_file(file_path, status)
        opts = ImportDialog.show(file_path)
        return Sketchup::Importer::ImportCanceled unless opts
        model = Sketchup.active_model
        return Sketchup::Importer::ImportFail unless model
        stats = BlueCollarSystems::PDFVectorImporter.run_pipeline(model, file_path, opts)
        stats ? Sketchup::Importer::ImportSuccess : Sketchup::Importer::ImportFail
      rescue StandardError => e
        BlueCollarSystems::PDFVectorImporter.safe_abort_operation(model, "PDFFileImporter")
        Logger.error("PDFFileImporter", "load_file failed", e)
        Sketchup::Importer::ImportFail
      end
    end
    end # if defined?(Sketchup::Importer)

  end
end
