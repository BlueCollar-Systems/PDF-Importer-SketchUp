# bc_pdf_vector_importer/cairo_glyph_source.rb
# Round 23 (F-1): glyph SOURCE selection + telemetry for the requested
# Glyphs/Outlines text mode.
#
# TEXTMODE-1: the source is a decision INSIDE the delivered Glyphs mode,
# never a mode change. Sources, in preference order:
#
#   cairo_svg  - the bundled poppler pdftocairo -svg pipeline
#                (SvgTextRenderer). Outlines come from the PDF's own
#                embedded fonts, so condensed/anisotropic title-block runs
#                keep their declared extents. Non-embedded fonts still
#                depend on host substitution and are reported, never
#                assumed perfect (see missing_fonts /
#                missing_language_packs below).
#   mupdf_svg  - the same SVG pipeline through an installed MuPDF mutool
#                when pdftocairo is unavailable (existing shipped
#                alternative, honestly named in telemetry).
#   internal   - the internal outline path: StrokeFont single-stroke
#                lettering of the extractor spans (GeometryBuilder
#                glyph_outline_text). Degraded fidelity, same
#                representation type (outline edges), fully reported.
#
# The decision is made ONCE per import and recorded in
# stats[:glyph_source]; a failure of the SVG source before it has
# delivered any page demotes the whole import to the internal source
# (fallback_reason says why). After the SVG source has delivered a page,
# later per-page failures use the existing per-page mode ladder so a
# single import never mixes glyph sources.
#
# R17-3: rendered glyph ink is position-matched back to extractor spans
# (pen point inside the span's declared bbox) so span_ids/provenance stay
# attached and disagreement is VISIBLE: runs_unmatched counts extractor
# spans with no glyph ink (e.g. poppler dropped a run: missing language
# pack / font); placements_unmatched counts glyph ink the extractor never
# declared. Zero glyph ink on a page where the extractor found spans is
# treated as a source failure, not success (no false green).
#
# Ruby 2.2 (SketchUp Make 2017) safe syntax throughout — the RB22 rules
# from the contributor card apply to every line of this file.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'svg_text_renderer')
require File.join(File.dirname(__FILE__), 'logger')

module BlueCollarSystems
  module PDFVectorImporter
    module CairoGlyphSource

      PDF_PT_TO_INCH = 1.0 / 72.0

      SOURCE_CAIRO = 'cairo_svg'.freeze
      SOURCE_MUPDF = 'mupdf_svg'.freeze
      SOURCE_INTERNAL = 'internal'.freeze

      # Pen-in-bbox tolerance (PDF points). Probe: first-glyph pen sits
      # within 0.39 pt of the declared span xMin; 2 pt absorbs baseline vs
      # box-bottom semantics without crossing to neighbouring spans.
      SPAN_MATCH_TOLERANCE_PT = 2.0

      # ------------------------------------------------------------------
      # Per-import decision
      # ------------------------------------------------------------------

      # Returns the single per-import glyph-source decision, creating and
      # recording it in stats[:glyph_source] on first use.
      def self.import_decision(stats)
        return nil unless stats.is_a?(Hash)
        existing = stats[:glyph_source]
        return existing if existing.is_a?(Hash)
        decision = new_decision
        stats[:glyph_source] = decision
        decision
      end

      def self.new_decision
        kind = preferred_renderer_kind
        if kind == :pdftocairo
          base_decision(SOURCE_CAIRO, nil)
        elsif kind == :mutool
          base_decision(SOURCE_MUPDF, 'pdftocairo_missing')
        else
          decision = base_decision(SOURCE_INTERNAL, 'pdftocairo_missing')
          decision[:locked] = true
          decision
        end
      end

      def self.base_decision(source, fallback_reason)
        {
          source: source,
          fallback_reason: fallback_reason,
          locked: false,
          pages: 0,
          runs_matched: 0,
          runs_unmatched: 0,
          placements_unmatched: 0,
          missing_fonts: [],
          missing_language_packs: []
        }
      end

      def self.preferred_renderer_kind
        renderer = SvgTextRenderer.find_svg_renderer
        renderer ? renderer[:kind] : nil
      rescue StandardError => e
        warn_safe("preferred_renderer_kind failed: #{e.message}")
        nil
      end

      def self.svg_source?(decision)
        return false unless decision.is_a?(Hash)
        decision[:source] == SOURCE_CAIRO || decision[:source] == SOURCE_MUPDF
      end

      def self.internal_source?(decision)
        decision.is_a?(Hash) && decision[:source] == SOURCE_INTERNAL
      end

      # Demote the import decision to the internal source. Only allowed
      # while the SVG source has not delivered any page yet (single
      # per-import decision — never mix sources mid-import). Returns true
      # when the demotion happened.
      def self.demote_to_internal!(decision, reason)
        return false unless decision.is_a?(Hash)
        return true if decision[:source] == SOURCE_INTERNAL
        return false if decision[:pages].to_i > 0 || decision[:locked]
        decision[:source] = SOURCE_INTERNAL
        decision[:fallback_reason] = reason.to_s.empty? ? 'svg_source_failed' : reason.to_s
        decision[:locked] = true
        Logger.warn('CairoGlyphSource',
          "Glyphs mode SVG source unavailable (#{decision[:fallback_reason]}); " \
          'delivering internal stroke-outline source for this import (reported).')
        true
      rescue StandardError
        false
      end

      # Map an SvgTextRenderer failure_info sink to a fallback reason.
      def self.failure_reason(failure_info)
        info = failure_info.is_a?(Hash) ? failure_info : {}
        case info[:reason].to_s
        when 'no_renderer' then 'pdftocairo_missing'
        when 'timeout' then 'pdftocairo_timeout'
        when 'svg_zero_placements' then 'svg_zero_placements'
        when '' then 'pdftocairo_failed'
        else 'pdftocairo_failed'
        end
      end

      # False-green guard (R23, forward-fix of the pinned review finding):
      # an SVG render that produced NO glyph ink on a page where the
      # extractor found text spans must count as a source failure.
      def self.zero_placement_false_green?(svg_result, text_items)
        return false unless svg_result.is_a?(Hash)
        return false if svg_result[:glyphs].to_i > 0
        span_count = 0
        Array(text_items).each do |item|
          span_count += 1 unless item_text(item).empty?
        end
        span_count > 0
      rescue StandardError
        false
      end

      # ------------------------------------------------------------------
      # Page recording + span matching (R17-3)
      # ------------------------------------------------------------------

      # Record a successful SVG-source page: accumulates telemetry and
      # attaches provenance entries for matched spans. Returns the match
      # result hash.
      def self.record_svg_page!(decision, page_num, svg_result, text_items,
                                media_box, provenance_bucket)
        return nil unless decision.is_a?(Hash)
        placements = svg_result.is_a?(Hash) ? svg_result[:placements_pdf] : nil
        match = match_spans(placements, text_items, media_box)
        decision[:pages] = decision[:pages].to_i + 1
        decision[:runs_matched] = decision[:runs_matched].to_i + match[:runs_matched].to_i
        decision[:runs_unmatched] = decision[:runs_unmatched].to_i + match[:runs_unmatched].to_i
        decision[:placements_unmatched] =
          decision[:placements_unmatched].to_i + match[:placements_unmatched].to_i
        merge_names!(decision, :missing_fonts, svg_result[:missing_fonts])
        merge_names!(decision, :missing_language_packs, svg_result[:missing_language_packs])
        record_span_provenance(provenance_bucket, page_num,
                               match[:matched_items], decision[:source])
        if match[:runs_unmatched].to_i > 0
          Logger.warn('CairoGlyphSource',
            "Page #{page_num}: #{match[:runs_unmatched]} extractor text span(s) " \
            'have no rendered glyph ink at their declared position — see ' \
            'extra.glyph_source in the import report.')
        end
        match
      rescue StandardError => e
        warn_safe("record_svg_page! failed: #{e.message}")
        nil
      end

      # Record an internal-source page (StrokeFont outlines render straight
      # from the extractor spans, so delivered spans are matched runs by
      # construction; provenance is recorded per span by GeometryBuilder).
      def self.record_internal_page!(decision, delivered_count)
        return nil unless decision.is_a?(Hash)
        decision[:pages] = decision[:pages].to_i + 1
        decision[:runs_matched] = decision[:runs_matched].to_i + delivered_count.to_i
        decision
      rescue StandardError
        nil
      end

      def self.merge_names!(decision, key, names)
        list = decision[key]
        list = decision[key] = [] unless list.is_a?(Array)
        Array(names).each do |name|
          s = name.to_s
          next if s.empty?
          list << s unless list.include?(s)
        end
        list
      rescue StandardError
        nil
      end

      # Position-match rendered glyph pen points (PDF points, media-origin
      # relative, y-up) against extractor span bboxes. Returns counts plus
      # the matched item objects (for provenance).
      def self.match_spans(placements_pdf, text_items, media_box)
        result = {
          matched_items: [],
          runs_matched: 0,
          runs_unmatched: 0,
          placements_unmatched: 0
        }
        pens = Array(placements_pdf)
        pen_used = Array.new(pens.length, false)
        base_x = media_box.is_a?(Array) && media_box.length >= 2 ? media_box[0].to_f : 0.0
        base_y = media_box.is_a?(Array) && media_box.length >= 2 ? media_box[1].to_f : 0.0
        tol = SPAN_MATCH_TOLERANCE_PT

        Array(text_items).each do |item|
          next if item_text(item).empty?
          box = item_bbox_media_relative(item, base_x, base_y)
          if box.nil?
            result[:runs_unmatched] += 1
            next
          end
          x0 = box[0] - tol
          y0 = box[1] - tol
          x1 = box[2] + tol
          y1 = box[3] + tol
          matched = false
          pens.each_with_index do |pen, idx|
            px = pen[:x].to_f
            py = pen[:y].to_f
            next if px < x0 || px > x1 || py < y0 || py > y1
            matched = true
            pen_used[idx] = true
          end
          if matched
            result[:runs_matched] += 1
            result[:matched_items] << item
          else
            result[:runs_unmatched] += 1
          end
        end

        unmatched_pens = 0
        pen_used.each { |used| unmatched_pens += 1 unless used }
        result[:placements_unmatched] = pens.empty? ? 0 : unmatched_pens
        result
      end

      def self.item_text(item)
        if item.respond_to?(:text)
          item.text.to_s.strip
        else
          ''
        end
      rescue StandardError
        ''
      end

      # Span bbox in the same space as SvgTextRenderer placements_pdf:
      # PDF points relative to the media-box origin, y-up. External
      # (pdftotext) items are already offset into that space; internal
      # content-stream items carry absolute user-space coordinates, so the
      # media origin is subtracted.
      def self.item_bbox_media_relative(item, base_x, base_y)
        return nil unless item.respond_to?(:bbox_x0)
        vals = [item.bbox_x0, item.bbox_y0, item.bbox_x1, item.bbox_y1]
        return nil if vals.any? { |v| v.nil? }
        x0 = vals[0].to_f
        y0 = vals[1].to_f
        x1 = vals[2].to_f
        y1 = vals[3].to_f
        return nil if (x1 - x0).abs <= 1.0e-6 || (y1 - y0).abs <= 1.0e-6
        external = false
        begin
          external = item.respond_to?(:font_name) && item.font_name.to_s == 'pdftotext'
        rescue StandardError
          external = false
        end
        unless external
          x0 -= base_x
          x1 -= base_x
          y0 -= base_y
          y1 -= base_y
        end
        [x0, y0, x1, y1]
      rescue StandardError
        nil
      end

      # R17-3: matched spans keep their deterministic source-span identity
      # in the provenance sidecar even though glyph geometry is stamped by
      # the SVG renderer rather than per-span builders.
      def self.record_span_provenance(bucket, page_num, matched_items, source)
        return unless bucket.is_a?(Array)
        Array(matched_items).each do |item|
          idx = bucket.length
          entry = {
            object_id: "text_span:#{page_num}:#{idx}",
            page: page_num.to_i,
            source_kind: 'text_span',
            created_entity_type: 'glyph_outline',
            glyph_source: source.to_s
          }
          begin
            if item.respond_to?(:source_span_id) && item.source_span_id
              entry[:span_id] = item.source_span_id
            end
          rescue StandardError
            # keep entry without span_id (never fabricate one — RB-01)
          end
          bbox = raw_item_bbox(item)
          entry[:source_bbox_pdf] = bbox if bbox
          bucket << entry
        end
        nil
      rescue StandardError => e
        warn_safe("record_span_provenance failed: #{e.message}")
        nil
      end

      def self.raw_item_bbox(item)
        return nil unless item.respond_to?(:bbox_x0)
        vals = [item.bbox_x0, item.bbox_y0, item.bbox_x1, item.bbox_y1]
        return nil if vals.any? { |v| v.nil? }
        vals.map { |v| v.to_f }
      rescue StandardError
        nil
      end

      # ------------------------------------------------------------------
      # Pure SVG -> model-space outline loops (fixture-tested; also the
      # core reused by the corpus oracle work, F-2).
      # ------------------------------------------------------------------

      # Parses a pdftocairo -svg document (glyph <defs> + <use> placements)
      # and returns GeometryBuilder-ready outline loops in model inches:
      # an array of { :glyph_id, :pen_pdf => [x_pt, y_pt], :loops =>
      # [[Geom::Point3d, ...], ...] } — one entry per placed glyph. The
      # coordinate mapping is the probe-verified production mapping
      # (SvgTextRenderer): SVG user unit == PDF point; single page-height
      # Y flip; glyph-local outlines baseline-relative with Y negated.
      def self.model_space_loops(svg, media_box, opts = {})
        scale = (opts[:scale] || 1.0).to_f
        y_offset = (opts[:y_offset] || 0.0).to_f
        svg_page_box = opts[:svg_page_box] || media_box
        media_min_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
        media_min_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
        svg_min_x = svg_page_box.is_a?(Array) ? svg_page_box[0].to_f : 0.0
        svg_min_y = svg_page_box.is_a?(Array) ? svg_page_box[1].to_f : 0.0
        box_offset_x_in = (svg_min_x - media_min_x) * PDF_PT_TO_INCH * scale
        box_offset_y_in = (svg_min_y - media_min_y) * PDF_PT_TO_INCH * scale

        unit = PDF_PT_TO_INCH * scale
        vb = SvgTextRenderer.parse_viewbox(svg)
        vb_min_x = vb[0].to_f
        vb_min_y = vb[1].to_f
        vb_h = vb[3].to_f
        if vb_h <= 0.0 && svg_page_box.is_a?(Array) && svg_page_box.length >= 4
          vb_h = (svg_page_box[3] - svg_page_box[1]).abs.to_f
        end

        glyph_paths = {}
        SvgTextRenderer.parse_glyph_defs(svg).each do |glyph_id, path_d|
          next if path_d.strip.empty?
          subpaths = SvgTextRenderer.svg_path_to_points(path_d, unit, unit)
          glyph_paths[glyph_id] = subpaths unless subpaths.empty?
        end

        out = []
        SvgTextRenderer.parse_use_placements(svg).each do |p|
          local = glyph_paths[p[:glyph_id]]
          next unless local

          m = p[:matrix]
          if m.is_a?(Array) && m.length >= 6
            a = m[0].to_f
            b = m[1].to_f
            c = m[2].to_f
            d = m[3].to_f
            e = m[4].to_f + p[:x].to_f
            f = m[5].to_f + p[:y].to_f
          else
            a = 1.0
            b = 0.0
            c = 0.0
            d = 1.0
            e = p[:x].to_f
            f = p[:y].to_f
          end

          tx = (e - vb_min_x) * unit + box_offset_x_in
          ty = (vb_h + vb_min_y - f) * unit + y_offset + box_offset_y_in

          loops = []
          local.each do |pts|
            loop_pts = []
            pts.each do |pt|
              # Local glyph points are already inch-scaled and Y-flipped
              # (svg_path_to_points). Apply the same axes SvgTextRenderer
              # uses for placement: x' = a*x - c*y, y' = -b*x + d*y.
              lx = pt.x.to_f
              ly = pt.y.to_f
              wx = tx + (a * lx) - (c * ly)
              wy = ty - (b * lx) + (d * ly)
              loop_pts << Geom::Point3d.new(wx, wy, 0.0)
            end
            loops << loop_pts if loop_pts.length >= 2
          end
          next if loops.empty?

          pen_x_pdf = (e - vb_min_x) + (svg_min_x - media_min_x)
          pen_y_pdf = (vb_h + vb_min_y - f) + (svg_min_y - media_min_y)
          out << { glyph_id: p[:glyph_id], pen_pdf: [pen_x_pdf, pen_y_pdf], loops: loops }
        end
        out
      end

      # Combined extent of loops from model_space_loops, in model inches:
      # [min_x, min_y, max_x, max_y] or nil.
      def self.loops_extent(placed)
        min_x = nil
        min_y = nil
        max_x = nil
        max_y = nil
        Array(placed).each do |entry|
          Array(entry.is_a?(Hash) ? entry[:loops] : entry).each do |pts|
            Array(pts).each do |pt|
              x = pt.x.to_f
              y = pt.y.to_f
              min_x = x if min_x.nil? || x < min_x
              max_x = x if max_x.nil? || x > max_x
              min_y = y if min_y.nil? || y < min_y
              max_y = y if max_y.nil? || y > max_y
            end
          end
        end
        return nil if min_x.nil?
        [min_x, min_y, max_x, max_y]
      end

      def self.warn_safe(message)
        Logger.warn('CairoGlyphSource', message)
      rescue StandardError
        # Logger may be unavailable in minimal runtime/test contexts.
      end

    end
  end
end
