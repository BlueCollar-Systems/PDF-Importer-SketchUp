# bc_pdf_vector_importer/svg_text_renderer.rb
# Renders PDF text as precise vector geometry using Poppler or MuPDF SVG.
#
# Normal PDFs draw glyphs as raw transformed edges so selecting text does not
# show one bounding box per glyph. Very large glyph runs may use temporary
# component definitions while building, then flatten the placed instances so the
# final model stays box-free.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'digest/md5'
require File.join(File.dirname(__FILE__), 'safe_temp')
require File.join(File.dirname(__FILE__), 'command_runner')
require File.join(File.dirname(__FILE__), 'logger')
require File.join(File.dirname(__FILE__), 'dependency_resolver')
require File.join(File.dirname(__FILE__), 'poppler_result_validator')
require File.join(File.dirname(__FILE__), 'poppler_semantic_proof')

module BlueCollarSystems
  module PDFVectorImporter
    module SvgTextRenderer

      PDF_PT_TO_INCH = 1.0 / 72.0
      DEFAULT_EDGE_GLYPH_THRESHOLD = 5_000
      DEFAULT_RAW_GLYPH_EDGE_BUDGET = 6_000
      DEFAULT_FLATTEN_GLYPH_EDGE_BUDGET = 3_000
      GLYPH_POINT_TOLERANCE = 1.0e-7

      def self.render(entities, pdf_path, page_num, media_box, opts = {})
        created_definitions = []
        # Optional failure sink (R23): callers that must distinguish WHY the
        # SVG text path returned nil (missing renderer / timeout / failed
        # render / exception) pass opts[:failure_info] = {} and read
        # [:reason] back. Purely additive — behaviour is unchanged.
        failure_info = opts[:failure_info].is_a?(Hash) ? opts[:failure_info] : nil
        renderers = find_svg_renderers(find_svg_renderer)
        if renderers.empty?
          failure_info[:reason] = 'no_renderer' if failure_info
          return nil
        end

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

        used_cropbox_fallback = false
        render_ok = false
        render_stderr = ""
        renderer = nil
        poppler_transport_validation = nil
        rendered_with_cropbox = false
        attempt_number = 0
        svg = nil
        glyphs = nil
        placements = nil

        renderers.each do |candidate|
          # Font repair remains a renderer-local transport step. A MuPDF retry
          # receives the original PDF and preserves the same requested glyph
          # geometry representation.
          render_pdf = candidate[:kind] == :pdftocairo ?
            ensure_renderable_pdf(pdf_path, candidate[:exe]) : pdf_path
          arg_variants = svg_render_arg_variants(
            candidate, render_pdf, svg_path, page_num, use_cropbox
          )

          arg_variants.each do |args|
            attempt_number += 1
            begin
              File.delete(svg_path) if File.exist?(svg_path)
            rescue StandardError
              # best-effort cleanup before this attempt owns the path
            end

            run = CommandRunner.run(
              args,
              timeout_s: 90,
              context: "SvgTextRenderer.#{candidate[:kind]}"
            )
            attempt_ok = run[:ok] && File.file?(svg_path) &&
              File.size(svg_path) > 0
            transport_validation = nil
            if candidate[:kind] == :pdftocairo
              transport_validation = PopplerResultValidator.validate(
                run,
                :executable => candidate[:exe],
                :argv => args,
                :context => 'SvgTextRenderer.pdftocairo',
                :page => page_num,
                :attempt => attempt_number,
                :representation => :glyph_geometry,
                :artifacts => [svg_path],
                :artifact_policy => :all_nonempty,
                :defer_semantic_completion => true
              )
              attempt_ok = transport_validation[:ok]
              unless attempt_ok
                PopplerResultValidator.log_rejection(
                  transport_validation, 'SvgTextRenderer'
                )
                failure_info[:reason] =
                  transport_validation[:reason].to_s if failure_info
              end
            end

            candidate_svg = nil
            candidate_glyphs = nil
            candidate_placements = nil
            if attempt_ok
              begin
                candidate_svg = File.read(svg_path, encoding: 'UTF-8')
                structure_failure = svg_structure_failure(candidate_svg)
                if structure_failure
                  attempt_ok = false
                  failure_info[:reason] = structure_failure.to_s if failure_info
                  Logger.warn(
                    'SvgTextRenderer',
                    "Page #{page_num}: rejected #{candidate[:kind]} SVG " \
                      "(#{structure_failure})"
                  )
                else
                  candidate_glyphs = parse_glyph_defs(candidate_svg)
                  candidate_placements = parse_use_placements(candidate_svg)
                end
              rescue StandardError => e
                attempt_ok = false
                failure_info[:reason] = 'svg_structure_invalid' if failure_info
                Logger.warn(
                  'SvgTextRenderer',
                  "Page #{page_num}: SVG inspection failed: #{e.message}"
                )
              end
            end

            if attempt_ok
              renderer = candidate
              rendered_with_cropbox = cropbox_args?(args)
              used_cropbox_fallback = use_cropbox && !rendered_with_cropbox
              render_stderr = run[:stderr].to_s
              poppler_transport_validation = transport_validation
              svg = candidate_svg
              glyphs = candidate_glyphs
              placements = candidate_placements
              failure_info.delete(:reason) if failure_info
              render_ok = true
              break
            end
            if run[:timed_out]
              failure_info[:reason] = 'timeout' if failure_info
              break
            end
          end
          break if render_ok
        end
        unless render_ok
          if failure_info && failure_info[:reason].to_s.empty?
            failure_info[:reason] = 'render_failed'
          end
          return nil
        end
        if used_cropbox_fallback
          Logger.warn("SvgTextRenderer",
            "Page #{page_num}: #{renderer[:kind]} crop box render unavailable; used media box SVG fallback")
        end

        # The coordinate transform must describe the box the successful
        # renderer attempt actually used. A failed CropBox attempt followed by
        # MediaBox success cannot retain CropBox offsets or dimensions.
        svg_page_box = rendered_with_cropbox ? svg_page_box : media_box
        svg_min_x = svg_page_box[0].to_f
        svg_min_y = svg_page_box[1].to_f
        page_w = (svg_page_box[2] - svg_page_box[0]).abs.to_f
        page_h = (svg_page_box[3] - svg_page_box[1]).abs.to_f
        box_offset_x_in = (svg_min_x - media_min_x) * PDF_PT_TO_INCH * scale.to_f
        box_offset_y_in = (svg_min_y - media_min_y) * PDF_PT_TO_INCH * scale.to_f

        # OCR-backed PDFs can contain many "#source-*" uses for embedded images.
        # Do not disable glyph rendering solely because of source image uses:
        # that fallback causes text drift on symbol charts and OCR overlays.
        source_use_count = svg.scan(/<use\b[^>]*(?:xlink:href|href)="#source-[^"]+"/).length
        if source_use_count > 0
          Logger.info("SvgTextRenderer",
            "Page #{page_num}: source_uses=#{source_use_count}, glyph_uses=#{placements.length} (rendering glyph geometry)")
        end

        semantic_svg_placements = placements
        placements, duplicate_physical_placements =
          deduplicate_exact_physical_placements(placements)
        if !duplicate_physical_placements.empty?
          Logger.info(
            'SvgTextRenderer',
            "Page #{page_num}: retained #{placements.length} unique physical " \
              "glyph placements; removed #{duplicate_physical_placements.length} " \
              'exact coincident source duplicate(s)'
          )
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
        missing_glyphs = 0
        placement_failures = 0
        skipped_placement_evidence = []
        placement_failure_evidence = []
        unoutlined_placement_evidence = []
        visible_glyph_instances = 0
        flattened_glyph_instances = 0
        placement_count = placements.length

        # Parse each unique glyph once. Small/medium edge budgets stamp raw
        # edges. Dense pages use reusable glyph components to avoid SketchUp's
        # per-edge insertion bottleneck while preserving the same outlines.
        Sketchup.status_text = "Building #{glyphs.length} glyph shapes..."
        glyph_defs = {}
        glyph_paths = {}
        glyph_edge_counts = {}
        glyphs.each do |glyph_id, path_d|
          next if path_d.strip.empty?
          subpaths = svg_path_to_points(path_d, x_unit_to_in, y_unit_to_in)
          next if subpaths.empty?

          glyph_paths[glyph_id] = subpaths
          glyph_edge_counts[glyph_id] = count_subpath_edges(subpaths)
        end

        estimated_glyph_edges = estimate_glyph_edge_count(placements, glyph_edge_counts)
        raw_edge_glyphs = raw_edge_glyphs?(opts, placement_count, estimated_glyph_edges)
        flatten_glyph_instances = flatten_glyph_instances?(opts, estimated_glyph_edges)
        Logger.info("SvgTextRenderer",
          "Page #{page_num}: glyph_strategy=#{raw_edge_glyphs ? 'raw_edges' : 'components'}, " \
          "placements=#{placement_count}, estimated_edges=#{estimated_glyph_edges}, " \
          "raw_edge_budget=#{raw_glyph_edge_budget}, flatten=#{flatten_glyph_instances}")

        unless raw_edge_glyphs
          glyph_paths.each do |glyph_id, subpaths|
            defn = model.definitions.add("_g_#{glyph_id}")
            created_definitions << defn
            defn_edge_count = 0
            subpaths.each do |pts|
              next if pts.length < 2
              begin
                r = defn.entities.add_edges(pts)
                defn_edge_count += r.length if r
              rescue StandardError => e
                Logger.warn("SvgTextRenderer", "add_edges for glyph failed: #{e.message}")
              end
            end
            if defn.entities.count > 0
              glyph_defs[glyph_id] = defn
              glyph_edge_counts[glyph_id] = defn_edge_count
            end
          end
        end

        text_entities = entities
        component_container = false
        unless raw_edge_glyphs
          begin
            group = entities.add_group
            group.name = "Text Glyph Geometry"
            begin
              group.layer = text_layer if text_layer
            rescue StandardError => e
              Logger.warn("SvgTextRenderer", "set_layer on glyph container failed: #{e.message}")
            end
            text_entities = group.entities
            component_container = true
          rescue StandardError => e
            Logger.warn("SvgTextRenderer", "glyph container group failed: #{e.message}")
            text_entities = entities
          end
        end

        # Guard against font-substitution failures (see collapsed_signature_keys):
        # skip glyphs pdftocairo stamped at one identical transform so they do
        # not pile into a blob.
        collapsed_set = {}
        collapsed_signature_keys(placements).each { |k| collapsed_set[k] = true }
        skipped_collapsed = 0

        # R23: pen points of rendered glyphs in PDF points relative to the
        # media-box origin, y-up — the space extractor span bboxes use.
        # Consumed by CairoGlyphSource for span matching (R17-3).
        placements_pdf = []
        pen_dx = svg_min_x - media_min_x
        pen_dy = svg_min_y - media_min_y

        # Place instances (fast)
        total = placements.length
        placements.each_with_index do |p, idx|
          if idx % 500 == 0
            Sketchup.status_text = "Placing text: #{idx}/#{total} [#{((idx.to_f/total)*100).round}%]"
          end

          glyph_data = raw_edge_glyphs ? glyph_paths[p[:glyph_id]] : glyph_defs[p[:glyph_id]]
          unless glyph_data
            evidence = {
              :index => idx, :glyph_id => p[:glyph_id].to_s,
              :reason => :unoutlined_glyph
            }
            if glyphs.key?(p[:glyph_id])
              missing_glyphs += 1
              evidence[:reason] = :glyph_definition_unusable
              skipped_placement_evidence << evidence
            else
              unoutlined_placement_evidence << evidence
            end
            next
          end

          if collapsed_set[placement_signature(p)]
            skipped_collapsed += 1
            skipped_placement_evidence << {
              :index => idx, :glyph_id => p[:glyph_id].to_s,
              :reason => :collapsed_placement
            }
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
              a = 1.0
              b = 0.0
              c = 0.0
              d = 1.0
              e = p[:x].to_f
              f = p[:y].to_f
              tx = (p[:x].to_f - vb_min_x) * x_unit_to_in + box_offset_x_in
              ty = (vb_h + vb_min_y - p[:y].to_f) * y_unit_to_in + y_offset.to_f + box_offset_y_in
              tr = Geom::Transformation.new(Geom::Point3d.new(tx, ty, 0.0))
            end

            ink_bbox = transformed_source_ink_bbox_pdf(
              glyph_paths[p[:glyph_id]], a, b, c, d, tx, ty,
              x_unit_to_in, y_unit_to_in, y_offset.to_f,
              box_offset_x_in, box_offset_y_in
            )
            placements_pdf << {
              :x => (e - vb_min_x) + pen_dx,
              :y => (vb_h + vb_min_y - f) + pen_dy,
              :placement_index => p[:source_placement_index] || idx,
              :glyph_id => p[:glyph_id],
              :ink_bbox_pdf => ink_bbox,
              :source_primary_axis => a.to_f.abs >= b.to_f.abs ? :x : :y
            }

            if raw_edge_glyphs
              added = add_transformed_glyph_edges(text_entities, glyph_data, tr, text_layer)
              edge_count += added
              if added <= 0
                placement_failures += 1
                placement_failure_evidence << {
                  :index => idx, :glyph_id => p[:glyph_id].to_s,
                  :reason => :zero_edges_created
                }
                next
              end
            else
              inst = text_entities.add_instance(glyph_data, tr)
              raise 'glyph component instance was not created' unless inst
              begin
                inst.layer = text_layer if inst && text_layer
              rescue StandardError => e
                Logger.warn("SvgTextRenderer", "set_layer on glyph instance failed: #{e.message}")
              end
              if flatten_glyph_instances
                exploded_edges = explode_glyph_instance(inst, text_layer)
                if exploded_edges
                  edge_count += exploded_edges
                  flattened_glyph_instances += 1
                else
                  edge_count += glyph_edge_counts[p[:glyph_id]].to_i
                  visible_glyph_instances += 1
                end
              else
                edge_count += glyph_edge_counts[p[:glyph_id]].to_i
                visible_glyph_instances += 1
              end
            end
            glyph_count += 1
          rescue StandardError => e
            placement_failures += 1
            placement_failure_evidence << {
              :index => idx, :glyph_id => p[:glyph_id].to_s,
              :reason => :host_placement_exception,
              :detail => e.message.to_s
            }
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
          render_box_used: rendered_with_cropbox ? :crop_box : :media_box,
          rendered_page_box: svg_page_box.map { |value| value.to_f },
          glyph_instances: visible_glyph_instances,
          raw_edge_glyphs: raw_edge_glyphs,
          flattened_glyph_instances: flattened_glyph_instances,
          estimated_glyph_edges: estimated_glyph_edges,
          text_performance_mode: raw_edge_glyphs ? :raw_edges : :glyph_components,
          component_container: component_container,
          skipped_glyphs: skipped_collapsed, missing_fonts: missing_fonts,
          missing_glyphs: missing_glyphs,
          placement_failures: placement_failures,
          skipped_placement_evidence: skipped_placement_evidence,
          placement_failure_evidence: placement_failure_evidence,
          unoutlined_placement_evidence: unoutlined_placement_evidence,
          duplicate_physical_placement_evidence:
            duplicate_physical_placements,
          created_definitions: created_definitions,
          missing_language_packs: missing_language_packs(render_stderr),
          placements_pdf: placements_pdf,
          semantic_svg_glyphs: glyphs,
          semantic_svg_placements: semantic_svg_placements,
          poppler_transport_validation: poppler_transport_validation }
      rescue StandardError => e
        begin
          Logger.warn("SvgTextRenderer", "Failed: #{e.message}")
        rescue StandardError
          # Logger may be unavailable in minimal runtime/test contexts.
        end
        failure_info[:created_definitions] = created_definitions if
          failure_info && !created_definitions.empty?
        failure_info[:reason] = 'exception' if failure_info && failure_info[:reason].to_s.empty?
        nil
      ensure
        begin
          File.delete(svg_path) if svg_path && File.exist?(svg_path)
        rescue StandardError => e
          Logger.warn("SvgTextRenderer", "cleanup temp svg failed: #{e.message}")
        end
      end

      private

      # Complete a deferred Poppler diagnostic only after the caller has built
      # post-render source-match and host-placement evidence. A literal true is
      # never proof at this active boundary.
      def self.finalize_deferred_semantic_validation(svg_result, proof, evidence)
        return false unless svg_result.is_a?(Hash)
        transport = svg_result[:poppler_transport_validation]
        return true unless transport.is_a?(Hash) &&
                           transport[:semantic_completion_deferred] == true
        return false unless proof.respond_to?(:call)
        return false unless PopplerSemanticProof.complete_failure_evidence?(
          evidence
        )

        semantic_complete = proof.call(evidence) == true
        final = PopplerResultValidator.finalize_deferred(
          transport, semantic_complete
        )
        svg_result[:poppler_final_validation] = final
        PopplerResultValidator.log_rejection(
          final, 'SvgTextRenderer'
        ) unless final[:ok]
        final[:ok] == true
      rescue StandardError => e
        Logger.warn('SvgTextRenderer',
          "semantic completeness proof failed: #{e.message}")
        false
      end

      def self.raw_edge_glyphs?(opts, placement_count, estimated_edge_count = nil)
        return false if opts[:raw_edge_glyphs] == false
        return true if opts[:raw_edge_glyphs] == true
        return false if placement_count.to_i > raw_edge_glyph_threshold
        edge_count = estimated_edge_count.to_i
        return true if edge_count <= 0
        edge_count <= raw_glyph_edge_budget
      end

      def self.raw_edge_glyph_threshold
        raw = ENV['BC_SU_GLYPH_EDGE_THRESHOLD'].to_s.strip
        value = raw.empty? ? DEFAULT_EDGE_GLYPH_THRESHOLD : raw.to_i
        value > 0 ? value : DEFAULT_EDGE_GLYPH_THRESHOLD
      rescue StandardError
        DEFAULT_EDGE_GLYPH_THRESHOLD
      end

      def self.raw_glyph_edge_budget
        raw = ENV['BC_SU_GLYPH_RAW_EDGE_BUDGET'].to_s.strip
        value = raw.empty? ? DEFAULT_RAW_GLYPH_EDGE_BUDGET : raw.to_i
        value > 0 ? value : DEFAULT_RAW_GLYPH_EDGE_BUDGET
      rescue StandardError
        DEFAULT_RAW_GLYPH_EDGE_BUDGET
      end

      def self.flatten_glyph_edge_budget
        raw = ENV['BC_SU_GLYPH_FLATTEN_EDGE_BUDGET'].to_s.strip
        value = raw.empty? ? DEFAULT_FLATTEN_GLYPH_EDGE_BUDGET : raw.to_i
        value > 0 ? value : DEFAULT_FLATTEN_GLYPH_EDGE_BUDGET
      rescue StandardError
        DEFAULT_FLATTEN_GLYPH_EDGE_BUDGET
      end

      def self.flatten_glyph_instances?(opts, estimated_edge_count = nil)
        if opts && opts.key?(:flatten_glyph_instances)
          return opts[:flatten_glyph_instances] ? true : false
        end
        raw = ENV['BC_SU_KEEP_GLYPH_COMPONENTS'].to_s.strip.downcase
        return false if raw == '1' || raw == 'true' || raw == 'yes'
        edge_count = estimated_edge_count.to_i
        return false if edge_count > flatten_glyph_edge_budget
        true
      rescue StandardError
        true
      end

      def self.count_subpath_edges(subpaths)
        total = 0
        Array(subpaths).each do |pts|
          next unless pts
          total += [pts.length.to_i - 1, 0].max
        end
        total
      end

      def self.estimate_glyph_edge_count(placements, glyph_edge_counts)
        total = 0
        Array(placements).each do |p|
          total += glyph_edge_counts[p[:glyph_id]].to_i
        end
        total
      rescue StandardError
        0
      end

      def self.add_transformed_glyph_edges(entities, subpaths, tr, text_layer)
        added = 0
        Array(subpaths).each do |pts|
          next unless pts && pts.length >= 2
          transformed = transformed_glyph_points(pts, tr)
          next if transformed.length < 2

          begin
            edges = entities.add_edges(transformed)
            edges = Array(edges)
            if edges.empty?
              added += add_glyph_segments_from_points(entities, transformed, text_layer)
            else
              edges.each { |edge| set_glyph_edge_layer(edge, text_layer) }
              added += edges.length
            end
          rescue StandardError => e
            Logger.warn("SvgTextRenderer", "add_edges for glyph path failed, falling back: #{e.message}")
            added += add_glyph_segments_from_points(entities, transformed, text_layer)
          end
        end
        added
      end

      def self.transformed_glyph_points(points, tr)
        out = []
        Array(points).each do |pt|
          transformed = transform_glyph_point(pt, tr)
          next unless transformed
          out << transformed if out.empty? || !same_glyph_point?(out.last, transformed)
        end
        out
      end

      def self.transform_glyph_point(point, tr)
        begin
          return point.transform(tr) if point.respond_to?(:transform)
        rescue StandardError
          # Try Transformation#* below.
        end
        begin
          return tr * point if tr
        rescue StandardError
          # Fall through to the original point for test doubles/minimal runtimes.
        end
        point
      end

      def self.add_glyph_segments_from_points(entities, points, text_layer)
        added = 0
        Array(points).each_cons(2) do |pa, pb|
          next if same_glyph_point?(pa, pb)
          begin
            edge = entities.add_line(pa, pb)
            set_glyph_edge_layer(edge, text_layer)
            added += 1 if edge
          rescue StandardError => e
            Logger.warn("SvgTextRenderer", "add_line for glyph edge failed: #{e.message}")
          end
        end
        added
      end

      def self.set_glyph_edge_layer(edge, text_layer)
        return unless edge && text_layer
        begin
          edge.layer = text_layer
        rescue StandardError => e
          Logger.warn("SvgTextRenderer", "set_layer on glyph edge failed: #{e.message}")
        end
      end

      def self.same_glyph_point?(a, b)
        return false unless a && b
        if a.respond_to?(:distance)
          return a.distance(b).to_f <= GLYPH_POINT_TOLERANCE
        end
        if a.respond_to?(:x) && a.respond_to?(:y) && b.respond_to?(:x) && b.respond_to?(:y)
          dx = a.x.to_f - b.x.to_f
          dy = a.y.to_f - b.y.to_f
          dz = (a.respond_to?(:z) && b.respond_to?(:z)) ? (a.z.to_f - b.z.to_f) : 0.0
          return ((dx * dx) + (dy * dy) + (dz * dz)) <= (GLYPH_POINT_TOLERANCE * GLYPH_POINT_TOLERANCE)
        end
        false
      rescue StandardError
        false
      end

      def self.explode_glyph_instance(inst, text_layer)
        return nil unless inst && inst.respond_to?(:explode)
        exploded = inst.explode
        return nil unless exploded

        edge_count = 0
        Array(exploded).each do |ent|
          begin
            ent.layer = text_layer if ent && text_layer && ent.respond_to?(:layer=)
          rescue StandardError => e
            Logger.warn("SvgTextRenderer", "set_layer on exploded glyph entity failed: #{e.message}")
          end
          edge_count += 1 if glyph_edge_entity?(ent)
        end
        edge_count
      rescue StandardError => e
        Logger.warn("SvgTextRenderer", "explode glyph instance failed: #{e.message}")
        nil
      end

      def self.glyph_edge_entity?(ent)
        return false unless ent
        return ent.is_a?(Sketchup::Edge) if defined?(Sketchup::Edge)
        return ent.typename.to_s == 'Edge' if ent.respond_to?(:typename)
        ent.class.name.to_s.split('::').last == 'Edge'
      rescue StandardError
        false
      end

      def self.warn_safe(message)
        Logger.warn("SvgTextRenderer", message)
      rescue StandardError
        # Logger may be unavailable in minimal runtime/test contexts.
      end

      def self.temp_svg_path
        # SafeTemp, never the profile temp: this path is the pdftocairo OUTPUT
        # argument, and the bundled helpers cannot write through a non-ASCII
        # path component such as an accented account name.
        SafeTemp.join(
          "bc_svg_#{Process.pid}_#{Time.now.to_i}_#{rand(100000)}")
      end

      def self.svg_renderer_available?
        !!find_svg_renderer
      end

      def self.find_svg_renderer
        poppler = find_pdftocairo
        return { kind: :pdftocairo, exe: poppler } if poppler

        mupdf = find_mutool
        return { kind: :mutool, exe: mupdf } if mupdf

        nil
      end

      # A helper failure or unusable artifact does not prove that the requested
      # SVG glyph representation is impossible. Keep the primary resolver
      # behavior for compatibility, then try MuPDF only as a same-
      # representation renderer when Poppler was selected first.
      def self.find_svg_renderers(primary = nil)
        primary ||= find_svg_renderer
        return [] unless primary

        renderers = [primary]
        if primary[:kind] == :pdftocairo
          mupdf = find_mutool
          if mupdf && mupdf.to_s != primary[:exe].to_s
            renderers << { :kind => :mutool, :exe => mupdf }
          end
        end
        renderers
      rescue StandardError => e
        Logger.warn('SvgTextRenderer', "renderer inventory failed: #{e.message}")
        primary ? [primary] : []
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

      def self.cropbox_args?(arguments)
        args = Array(arguments).map { |value| value.to_s.downcase }
        return true if args.include?('-cropbox')
        args.each_with_index.any? do |value, index|
          value == '-b' && args[index + 1].to_s == 'cropbox'
        end
      rescue StandardError
        false
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
        svg_text = svg.to_s
        cache_key = Digest::MD5.hexdigest(svg_text)
        @use_placements_cache ||= {}
        cached = @use_placements_cache[cache_key]
        return copy_use_placements(cached) if cached

        placements = parse_use_placements_uncached(svg_text)
        @use_placements_cache[cache_key] = placements
        copy_use_placements(placements)
      end

      def self.copy_use_placements(placements)
        Array(placements).map do |placement|
          copy = placement.dup
          rgb = copy[:fill_rgb]
          copy[:fill_rgb] = rgb.dup if rgb
          matrix = copy[:matrix]
          copy[:matrix] = matrix.dup if matrix
          copy
        end
      end

      def self.parse_use_placements_uncached(svg)
        a = []
        # SVG presentation attributes inherit through nested groups. Cairo
        # emits text color on the wrapping <g>, not on each glyph <use>; a
        # use-only regex therefore discarded the PDF's source ink color.
        # Track every balanced SVG element in document order so valid
        # containers such as <a>, <switch>, and <symbol> cannot sever paint
        # inheritance. This intentionally avoids an XML dependency inside
        # SketchUp 2017's Ruby 2.2 runtime.
        paint_stack = [{
          :name => nil,
          :fill_rgb => [0.0, 0.0, 0.0],
          :fill_opacity => 1.0,
          :opacity_product => 1.0
        }]
        svg.to_s.scan(/<\/?\s*[A-Za-z][A-Za-z0-9:_-]*\b[^>]*>/m) do |m|
          tag = m.is_a?(Array) ? m.first.to_s : m.to_s
          if tag =~ /\A<\s*\/\s*([A-Za-z][A-Za-z0-9:_-]*)\b/i
            paint_stack.pop if paint_stack.length > 1
            next
          end

          name_match = tag.match(/\A<\s*([A-Za-z][A-Za-z0-9:_-]*)\b/i)
          next unless name_match
          element_name = name_match[1].to_s.downcase
          parent = paint_stack.last
          # Path/geometry tags are siblings of <use>, not ancestors. Skip
          # per-attribute regex work unless this tag can carry fill/opacity
          # into a descendant use (or is a use itself).
          needs_paint = element_name == 'use' ||
            tag.include?('fill') || tag.include?('opacity') ||
            tag.include?('style')
          attrs = nil
          if needs_paint
            attrs = svg_tag_attribute_map(tag)
            style_props = svg_style_property_map(attrs['style'])
            fill_value = style_props['fill']
            fill_value = attrs['fill'] if fill_value.nil?
            fill_present = !fill_value.nil?
            direct_fill = fill_present ? parse_svg_color(fill_value) : nil
            fo_value = style_props['fill-opacity']
            fo_value = attrs['fill-opacity'] if fo_value.nil?
            fo_present = !fo_value.nil?
            op_value = style_props['opacity']
            op_value = attrs['opacity'] if op_value.nil?
            op_present = !op_value.nil?
            frame = {
              :name => element_name,
              :fill_rgb => fill_present ? direct_fill : parent[:fill_rgb],
              :fill_opacity => fo_present ? parse_svg_opacity(fo_value) :
                parent[:fill_opacity],
              :opacity_product => multiply_svg_opacity(
                parent[:opacity_product],
                op_present ? parse_svg_opacity(op_value) : 1.0
              )
            }
          else
            frame = {
              :name => element_name,
              :fill_rgb => parent[:fill_rgb],
              :fill_opacity => parent[:fill_opacity],
              :opacity_product => parent[:opacity_product]
            }
          end
          paint_stack << frame
          self_closing = tag =~ /\/\s*>\s*\z/

          if element_name == 'use'
            attrs = svg_tag_attribute_map(tag) if attrs.nil?
            href = attrs['xlink:href'] || attrs['href']
            if href && href.start_with?('#')
              id = href[1..-1]
              if glyph_reference_id?(id)
                x = (attrs['x'] || '0').to_f
                y = (attrs['y'] || '0').to_f

                matrix = nil
                tr = attrs['transform']
                if tr && tr =~ /matrix\(([^)]+)\)/i
                  vals = $1.split(/[,\s]+/).reject(&:empty?).map(&:to_f)
                  matrix = vals[0, 6] if vals.length >= 6
                end

                fill_rgb = frame[:fill_rgb]
                fill_opacity = multiply_svg_opacity(
                  frame[:fill_opacity], frame[:opacity_product]
                )
                a << {
                  glyph_id: id,
                  x: x,
                  y: y,
                  matrix: matrix,
                  fill_rgb: fill_rgb && fill_rgb.dup,
                  fill_opacity: fill_opacity
                }
              end
            end
          end
          paint_stack.pop if self_closing
        end
        a
      end

      def self.svg_tag_attribute_map(tag)
        attrs = {}
        tag.to_s.scan(
          /([A-Za-z_:][A-Za-z0-9:_.-]*)\s*=\s*(['"])(.*?)\2/m
        ) do |name, _quote, value|
          attrs[name.to_s.downcase] = value
        end
        attrs
      end

      def self.svg_style_property_map(style)
        props = {}
        return props if style.nil? || style.to_s.empty?
        style.to_s.split(';').each do |part|
          colon = part.index(':')
          next unless colon
          key = part[0, colon].to_s.strip.downcase
          next if key.empty?
          props[key] = part[(colon + 1)..-1].to_s.strip
        end
        props
      end

      def self.svg_attribute_value(tag, name)
        escaped = Regexp.escape(name.to_s)
        match = tag.to_s.match(/(?:\A|[\s<])#{escaped}\s*=\s*(['"])(.*?)\1/im)
        match ? match[2] : nil
      rescue StandardError
        nil
      end

      # Returns [present, rgb]. present=true/rgb=nil represents an explicit
      # non-solid fill such as "none", which must override inherited color.
      # An inline style wins over the corresponding presentation attribute.
      def self.svg_fill_spec(tag)
        value = svg_style_property_value(tag, 'fill')
        value = svg_attribute_value(tag, 'fill') if value.nil?
        return [false, nil] if value.nil?
        [true, parse_svg_color(value)]
      rescue StandardError
        [false, nil]
      end

      def self.svg_opacity_spec(tag, property)
        value = svg_style_property_value(tag, property)
        value = svg_attribute_value(tag, property) if value.nil?
        return [false, nil] if value.nil?
        [true, parse_svg_opacity(value)]
      rescue StandardError
        [false, nil]
      end

      def self.svg_style_property_value(tag, property)
        style = svg_attribute_value(tag, 'style')
        return nil unless style
        escaped = Regexp.escape(property.to_s)
        match = style.match(/(?:\A|;)\s*#{escaped}\s*:\s*([^;]+)/i)
        match ? match[1].to_s.strip : nil
      rescue StandardError
        nil
      end

      def self.multiply_svg_opacity(left, right)
        return nil unless left.is_a?(Numeric) && right.is_a?(Numeric)
        product = left.to_f * right.to_f
        product.finite? ? product : nil
      rescue StandardError
        nil
      end

      SVG_NUMBER_PATTERN =
        /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/

      def self.parse_svg_opacity(value)
        raw = value.to_s.strip
        percent = raw.end_with?('%')
        number_text = percent ? raw[0...-1].to_s.strip : raw
        return nil unless number_text =~ SVG_NUMBER_PATTERN
        number = number_text.to_f
        return nil unless number.finite?
        number /= 100.0 if percent
        [[number, 0.0].max, 1.0].min
      rescue StandardError
        nil
      end

      def self.parse_svg_color(value)
        text = value.to_s.strip
        return nil if text.empty? || text.downcase == 'none'

        if text =~ /\Argb\(\s*([^)]+)\s*\)\z/i
          parts = $1.split(/\s*,\s*/)
          return nil unless parts.length == 3
          channels = parts.map do |part|
            raw = part.to_s.strip
            percent = raw.end_with?('%')
            number_text = percent ? raw[0...-1].to_s.strip : raw
            return nil unless number_text =~ SVG_NUMBER_PATTERN
            number = number_text.to_f
            return nil unless number.finite?
            number = percent ? number / 100.0 : number / 255.0
            [[number, 0.0].max, 1.0].min
          end
          return channels
        end

        if text =~ /\A#([0-9a-f]{6})\z/i
          hex = $1
          return [
            hex[0, 2].to_i(16) / 255.0,
            hex[2, 2].to_i(16) / 255.0,
            hex[4, 2].to_i(16) / 255.0
          ]
        end
        if text =~ /\A#([0-9a-f]{3})\z/i
          hex = $1
          return [
            (hex[0, 1] * 2).to_i(16) / 255.0,
            (hex[1, 1] * 2).to_i(16) / 255.0,
            (hex[2, 1] * 2).to_i(16) / 255.0
          ]
        end

        named = {
          'black' => [0.0, 0.0, 0.0],
          'white' => [1.0, 1.0, 1.0],
          'red' => [1.0, 0.0, 0.0],
          'green' => [0.0, 128.0 / 255.0, 0.0],
          'blue' => [0.0, 0.0, 1.0]
        }
        named[text.downcase]
      rescue StandardError
        nil
      end

      # A successful helper process and nonempty file do not prove usable
      # glyph output. Both requested outline modes require definitions and
      # placements; empty structure is an attempt failure, never a success
      # result with zero entities.
      def self.svg_structure_failure(svg)
        placements = parse_use_placements(svg.to_s)
        return :svg_zero_placements if placements.empty?
        glyphs = parse_glyph_defs(svg.to_s)
        return :svg_zero_glyph_defs if glyphs.empty?
        nil
      rescue StandardError
        :svg_structure_invalid
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

      def self.exact_physical_placement_signature(placement)
        p = placement.is_a?(Hash) ? placement : {}
        matrix = p[:matrix]
        matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0] unless
          matrix.is_a?(Array) && matrix.length >= 6
        values = matrix.first(6).map { |value| value.to_f }
        effective = values.first(4) + [
          values[4] + p[:x].to_f,
          values[5] + p[:y].to_f
        ]
        [p[:glyph_id].to_s, effective, svg_paint_signature(p)]
      rescue StandardError
        [placement.object_id]
      end

      def self.svg_paint_signature(placement)
        p = placement.is_a?(Hash) ? placement : {}
        fill = p.key?(:fill_rgb) ? p[:fill_rgb] : [0.0, 0.0, 0.0]
        fill_signature = if fill.is_a?(Array) && fill.length >= 3
                           fill.first(3).map { |value| value.to_f }
                         else
                           [:unsupported_fill]
                         end
        opacity = p.key?(:fill_opacity) ? p[:fill_opacity] : 1.0
        opacity_signature = if opacity.is_a?(Numeric) &&
                               opacity.to_f.finite?
                              opacity.to_f
                            else
                              :unsupported_opacity
                            end
        [fill_signature, opacity_signature]
      rescue StandardError
        [[:unsupported_fill], :unsupported_opacity]
      end

      def self.deduplicate_exact_physical_placements(placements)
        unique = []
        duplicates = []
        retained = {}
        Array(placements).each_with_index do |placement, source_index|
          key = exact_physical_placement_signature(placement)
          if retained.key?(key)
            duplicates << {
              :duplicate_placement_index => source_index,
              :retained_placement_index => retained[key],
              :glyph_id => placement[:glyph_id].to_s,
              :reason => :exact_coincident_source_outline
            }
            next
          end
          retained[key] = source_index
          copy = placement.dup
          copy[:source_placement_index] = source_index
          unique << copy
        end
        [unique, duplicates]
      rescue StandardError
        [Array(placements), []]
      end

      # Convert the same flattened source points used to create the host
      # glyph into PDF-relative physical ink bounds. These bounds are
      # independent of Unicode character count and let the ownership layer
      # prove shaped runs without inspecting the newly created entities.
      def self.transformed_source_ink_bbox_pdf(subpaths, a, b, c, d, tx, ty,
                                               x_unit_to_in, y_unit_to_in,
                                               y_offset, box_offset_x_in,
                                               box_offset_y_in)
        return nil if x_unit_to_in.to_f.abs <= 1.0e-12 ||
          y_unit_to_in.to_f.abs <= 1.0e-12
        ratio_xy = x_unit_to_in.to_f / y_unit_to_in.to_f
        ratio_yx = y_unit_to_in.to_f / x_unit_to_in.to_f
        xs = []
        ys = []
        Array(subpaths).each do |points|
          Array(points).each do |point|
            lx = point.x.to_f
            ly = point.y.to_f
            wx = tx.to_f + (a.to_f * lx) -
              (c.to_f * ratio_xy * ly)
            wy = ty.to_f - (b.to_f * ratio_yx * lx) +
              (d.to_f * ly)
            xs << ((wx - box_offset_x_in.to_f) / x_unit_to_in.to_f)
            ys << ((wy - y_offset.to_f - box_offset_y_in.to_f) /
                   y_unit_to_in.to_f)
          end
        end
        return nil if xs.empty? || ys.empty?
        [xs.min, ys.min, xs.max, ys.max]
      rescue StandardError
        nil
      end

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

      # R23: poppler exits 0 while dropping every run of a CID font whose
      # language pack (e.g. Adobe-GB1) is not packaged — the only trace is
      # this stderr line. Surface it so reports can show the loss instead
      # of a silent pass.
      def self.missing_language_packs(stderr)
        return [] unless stderr.is_a?(String) && !stderr.empty?
        stderr.scan(/Missing language pack for '([^']+)'/).map { |mm| mm[0] }.uniq
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
        out = SafeTemp.join(
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

      # Convert one complete SVG path grammar to point arrays. Glyph coords are
      # SVG viewBox units (Y-down); output uses the requested physical X/Y
      # scales and a Y flip. All standard path commands are consumed rather
      # than silently converting an unsupported curve into a straight edge.
      def self.svg_path_to_points(d, scale_or_x_unit_to_in, y_unit_to_in = nil,
                                  point_factory = nil)
        if y_unit_to_in.nil?
          x_unit_to_in = PDF_PT_TO_INCH * scale_or_x_unit_to_in.to_f
          y_unit_to_in = x_unit_to_in
        else
          x_unit_to_in = scale_or_x_unit_to_in.to_f
          y_unit_to_in = y_unit_to_in.to_f
        end

        source = d.to_s
        number_source = '[-+]?(?:\\d*\\.\\d+|\\d+\\.?)(?:[eE][-+]?\\d+)?'
        token_pattern = Regexp.new(
          '[AaCcHhLlMmQqSsTtVvZz]|' + number_source
        )
        tokens = source.scan(token_pattern)
        residue = source.gsub(token_pattern, '').gsub(/[\s,]/, '')
        unless residue.empty?
          raise ArgumentError, "unsupported SVG path token #{residue.inspect}"
        end

        factory = point_factory
        factory = lambda do |x, y, z|
          Geom::Point3d.new(x, y, z)
        end unless factory.respond_to?(:call)
        mk = lambda do |gx, gy|
          factory.call(gx * x_unit_to_in, -gy * y_unit_to_in, 0.0)
        end
        append_point = lambda do |points, point|
          if points.empty? || points.last.distance(point).to_f > 0.0
            points << point
          end
        end
        cubic_to = lambda do |points, from_x, from_y, control1_x, control1_y,
                             control2_x, control2_y, end_x, end_y|
          p0 = points.last || mk.call(from_x, from_y)
          p1 = mk.call(control1_x, control1_y)
          p2 = mk.call(control2_x, control2_y)
          p3 = mk.call(end_x, end_y)
          chord = p0.distance(p3).to_f
          segments = chord < 0.02 ? 2 : (chord < 0.08 ? 3 : 4)
          (1..segments).each do |segment|
            t = segment.to_f / segments
            mt = 1.0 - t
            bx = (mt**3 * p0.x.to_f) +
              (3.0 * mt**2 * t * p1.x.to_f) +
              (3.0 * mt * t**2 * p2.x.to_f) +
              (t**3 * p3.x.to_f)
            by = (mt**3 * p0.y.to_f) +
              (3.0 * mt**2 * t * p1.y.to_f) +
              (3.0 * mt * t**2 * p2.y.to_f) +
              (t**3 * p3.y.to_f)
            append_point.call(points, factory.call(bx, by, 0.0))
          end
        end
        vector_angle = lambda do |ux, uy, vx, vy|
          Math.atan2((ux * vy) - (uy * vx), (ux * vx) + (uy * vy))
        end
        arc_to = lambda do |points, from_x, from_y, radius_x, radius_y,
                           rotation, large_arc, sweep, end_x, end_y|
          rx = radius_x.to_f.abs
          ry = radius_y.to_f.abs
          if (from_x == end_x && from_y == end_y)
            next
          end
          if rx == 0.0 || ry == 0.0
            append_point.call(points, mk.call(end_x, end_y))
            next
          end
          phi = rotation.to_f * Math::PI / 180.0
          cos_phi = Math.cos(phi)
          sin_phi = Math.sin(phi)
          half_dx = (from_x - end_x) * 0.5
          half_dy = (from_y - end_y) * 0.5
          x1p = (cos_phi * half_dx) + (sin_phi * half_dy)
          y1p = (-sin_phi * half_dx) + (cos_phi * half_dy)
          radii_ratio = (x1p * x1p) / (rx * rx) +
            (y1p * y1p) / (ry * ry)
          if radii_ratio > 1.0
            adjustment = Math.sqrt(radii_ratio)
            rx *= adjustment
            ry *= adjustment
          end
          numerator = (rx * rx * ry * ry) -
            (rx * rx * y1p * y1p) - (ry * ry * x1p * x1p)
          denominator = (rx * rx * y1p * y1p) +
            (ry * ry * x1p * x1p)
          coefficient = 0.0
          if denominator > 0.0
            sign = (large_arc == sweep) ? -1.0 : 1.0
            coefficient = sign * Math.sqrt([numerator / denominator, 0.0].max)
          end
          center_xp = coefficient * (rx * y1p / ry)
          center_yp = coefficient * (-ry * x1p / rx)
          center_x = (cos_phi * center_xp) - (sin_phi * center_yp) +
            ((from_x + end_x) * 0.5)
          center_y = (sin_phi * center_xp) + (cos_phi * center_yp) +
            ((from_y + end_y) * 0.5)
          start_ux = (x1p - center_xp) / rx
          start_uy = (y1p - center_yp) / ry
          end_ux = (-x1p - center_xp) / rx
          end_uy = (-y1p - center_yp) / ry
          start_angle = vector_angle.call(1.0, 0.0, start_ux, start_uy)
          delta = vector_angle.call(start_ux, start_uy, end_ux, end_uy)
          delta -= 2.0 * Math::PI if !sweep && delta > 0.0
          delta += 2.0 * Math::PI if sweep && delta < 0.0
          segments = [(delta.abs / (Math::PI / 4.0)).ceil, 1].max
          (1..segments).each do |segment|
            if segment == segments
              append_point.call(points, mk.call(end_x, end_y))
              next
            end
            angle = start_angle + (delta * segment.to_f / segments)
            unit_x = rx * Math.cos(angle)
            unit_y = ry * Math.sin(angle)
            point_x = center_x + (cos_phi * unit_x) - (sin_phi * unit_y)
            point_y = center_y + (sin_phi * unit_x) + (cos_phi * unit_y)
            append_point.call(points, mk.call(point_x, point_y))
          end
        end

        arities = {
          'M' => 2, 'L' => 2, 'H' => 1, 'V' => 1,
          'C' => 6, 'S' => 4, 'Q' => 4, 'T' => 2, 'A' => 7
        }
        subpaths = []
        current = []
        start_point = nil
        start_x = 0.0
        start_y = 0.0
        cx = 0.0
        cy = 0.0
        previous = nil
        last_cubic_x = nil
        last_cubic_y = nil
        last_quadratic_x = nil
        last_quadratic_y = nil
        command = nil
        index = 0
        while index < tokens.length
          token = tokens[index]
          if token =~ /\A[A-Za-z]\z/
            command = token
            index += 1
            if command.upcase == 'Z'
              if current.last && start_point &&
                 current.last.distance(start_point).to_f > 0.0
                current << start_point
              end
              subpaths << current if current.length >= 2
              current = []
              cx = start_x
              cy = start_y
              previous = 'Z'
              last_cubic_x = last_cubic_y = nil
              last_quadratic_x = last_quadratic_y = nil
              command = nil
              next
            end
          elsif command.nil?
            raise ArgumentError, 'SVG path numbers have no command'
          end

          type = command.upcase
          arity = arities[type]
          raise ArgumentError, "unsupported SVG path command #{command}" unless arity
          values = tokens[index, arity]
          if !values || values.length != arity ||
             values.any? { |value| value =~ /\A[A-Za-z]\z/ }
            raise ArgumentError, "incomplete SVG path command #{command}"
          end
          values = values.map { |value| value.to_f }
          index += arity
          relative = command == command.downcase

          if type == 'M'
            x = relative ? cx + values[0] : values[0]
            y = relative ? cy + values[1] : values[1]
            subpaths << current if current.length >= 2
            cx = x
            cy = y
            start_x = x
            start_y = y
            start_point = mk.call(x, y)
            current = [start_point]
            previous = 'M'
            last_cubic_x = last_cubic_y = nil
            last_quadratic_x = last_quadratic_y = nil
            command = relative ? 'l' : 'L'
            next
          end

          if current.empty?
            start_x = cx
            start_y = cy
            start_point = mk.call(cx, cy)
            current << start_point
          end

          case type
          when 'L'
            cx = relative ? cx + values[0] : values[0]
            cy = relative ? cy + values[1] : values[1]
            append_point.call(current, mk.call(cx, cy))
          when 'H'
            cx = relative ? cx + values[0] : values[0]
            append_point.call(current, mk.call(cx, cy))
          when 'V'
            cy = relative ? cy + values[0] : values[0]
            append_point.call(current, mk.call(cx, cy))
          when 'C'
            x1 = relative ? cx + values[0] : values[0]
            y1 = relative ? cy + values[1] : values[1]
            x2 = relative ? cx + values[2] : values[2]
            y2 = relative ? cy + values[3] : values[3]
            x = relative ? cx + values[4] : values[4]
            y = relative ? cy + values[5] : values[5]
            cubic_to.call(current, cx, cy, x1, y1, x2, y2, x, y)
            last_cubic_x = x2
            last_cubic_y = y2
            cx = x
            cy = y
          when 'S'
            x1 = ['C', 'S'].include?(previous) && last_cubic_x ?
              (2.0 * cx) - last_cubic_x : cx
            y1 = ['C', 'S'].include?(previous) && last_cubic_y ?
              (2.0 * cy) - last_cubic_y : cy
            x2 = relative ? cx + values[0] : values[0]
            y2 = relative ? cy + values[1] : values[1]
            x = relative ? cx + values[2] : values[2]
            y = relative ? cy + values[3] : values[3]
            cubic_to.call(current, cx, cy, x1, y1, x2, y2, x, y)
            last_cubic_x = x2
            last_cubic_y = y2
            cx = x
            cy = y
          when 'Q', 'T'
            if type == 'Q'
              quadratic_x = relative ? cx + values[0] : values[0]
              quadratic_y = relative ? cy + values[1] : values[1]
              x = relative ? cx + values[2] : values[2]
              y = relative ? cy + values[3] : values[3]
            else
              quadratic_x = ['Q', 'T'].include?(previous) && last_quadratic_x ?
                (2.0 * cx) - last_quadratic_x : cx
              quadratic_y = ['Q', 'T'].include?(previous) && last_quadratic_y ?
                (2.0 * cy) - last_quadratic_y : cy
              x = relative ? cx + values[0] : values[0]
              y = relative ? cy + values[1] : values[1]
            end
            control1_x = cx + ((quadratic_x - cx) * 2.0 / 3.0)
            control1_y = cy + ((quadratic_y - cy) * 2.0 / 3.0)
            control2_x = x + ((quadratic_x - x) * 2.0 / 3.0)
            control2_y = y + ((quadratic_y - y) * 2.0 / 3.0)
            cubic_to.call(
              current, cx, cy, control1_x, control1_y,
              control2_x, control2_y, x, y
            )
            last_quadratic_x = quadratic_x
            last_quadratic_y = quadratic_y
            cx = x
            cy = y
          when 'A'
            x = relative ? cx + values[5] : values[5]
            y = relative ? cy + values[6] : values[6]
            arc_to.call(
              current, cx, cy, values[0], values[1], values[2],
              values[3] != 0.0, values[4] != 0.0, x, y
            )
            cx = x
            cy = y
          end

          unless ['C', 'S'].include?(type)
            last_cubic_x = last_cubic_y = nil
          end
          unless ['Q', 'T'].include?(type)
            last_quadratic_x = last_quadratic_y = nil
          end
          previous = type
        end
        subpaths << current if current.length >= 2

        subpaths.map do |points|
          clean = [points.first]
          points[1..-1].each do |point|
            clean << point if point.distance(clean.last).to_f > 0.0
          end
          clean.length >= 2 ? clean : nil
        end.compact
      end

    end
  end
end
