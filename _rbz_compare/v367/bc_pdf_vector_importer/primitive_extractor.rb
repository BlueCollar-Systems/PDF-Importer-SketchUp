# bc_pdf_vector_importer/primitive_extractor.rb
# Converts PDF content stream parser output (VectorPath/SubPath/Segment)
# into host-neutral Primitive objects. This is the seam between
# PDF parsing and recognition/host-building.
#
# Rule 1: Parser modules must not know about domain-specific logic.
# This module only normalizes coordinates and classifies geometry types.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module PrimitiveExtractor

      PDF_PT_TO_INCH = 1.0 / 72.0

      # ---------------------------------------------------------------
      # Convert parsed PDF paths + text into PageData
      # ---------------------------------------------------------------
      def self.extract(paths, text_items, media_box, page_num, opts = {})
        scale = opts[:scale] || 1.0
        bezier_segs = opts[:bezier_segments] || 16
        origin_x = media_box[0]
        origin_y = media_box[1]
        page_w = (media_box[2] - media_box[0]) * PDF_PT_TO_INCH * scale
        page_h = (media_box[3] - media_box[1]) * PDF_PT_TO_INCH * scale

        # NOTE: Do NOT reset IDGen here — IDs must be unique across all pages
        # in a multi-page import. IDGen.reset is called once in run_pipeline.

        primitives = []
        paths.each do |path|
          next unless path.subpaths && !path.subpaths.empty?
          path.subpaths.each do |sp|
            prim = subpath_to_primitive(sp, path, origin_x, origin_y, scale, bezier_segs, page_num)
            primitives << prim if prim
          end
        end

        norm_texts = []
        (text_items || []).each do |ti|
          nt = normalize_text_item(ti, origin_x, origin_y, scale, page_num)
          norm_texts << nt if nt
        end

        PageData.new(
          page_num,
          page_w,
          page_h,
          primitives,
          norm_texts,
          [],  # layers filled by OCG parser
          []   # xobject names filled by xobject parser
        )
      end

      private

      def self.subpath_to_primitive(subpath, path, ox, oy, scale, bezier_segs, page_num)
        points = []
        subpath.segments.each do |seg|
          case seg.type
          when :move
            points << convert_pt(seg.points[0], ox, oy, scale)
          when :line
            points << convert_pt(seg.points[1], ox, oy, scale)
          when :curve
            p0, p1, p2, p3 = seg.points
            curve_pts = Bezier.cubic_to_points(p0, p1, p2, p3,
              max_segments: bezier_segs, tolerance: 0.25)
            curve_pts[1..-1].each { |pt| points << convert_pt(pt, ox, oy, scale) }
          when :rect
            seg.points.each { |pt| points << convert_pt(pt, ox, oy, scale) }
          end
        end

        return nil if points.length < 2

        # Remove consecutive duplicates
        cleaned = [points[0]]
        points[1..-1].each do |pt|
          d = Math.sqrt((pt[0] - cleaned.last[0])**2 + (pt[1] - cleaned.last[1])**2)
          cleaned << pt if d > 0.0005
        end
        return nil if cleaned.length < 2

        # Classify type
        is_closed = subpath.closed ||
          (cleaned.length >= 3 &&
           Math.sqrt((cleaned.first[0] - cleaned.last[0])**2 +
                     (cleaned.first[1] - cleaned.last[1])**2) < 0.01)

        # Compute bounding box
        xs = cleaned.map { |p| p[0] }
        ys = cleaned.map { |p| p[1] }
        bbox = [xs.min, ys.min, xs.max, ys.max]

        # Compute area for closed loops
        area = nil
        if is_closed && cleaned.length >= 3
          area = polygon_area(cleaned)
        end

        # Determine type
        ptype = if cleaned.length == 2
                  :line
                elsif is_closed && cleaned.length >= 6
                  :closed_loop
                elsif is_closed
                  :closed_loop
                else
                  :polyline
                end

        Primitive.new(
          IDGen.next,
          ptype,
          cleaned,
          nil,            # center — filled by arc fitter if applicable
          nil,            # radius
          nil, nil,       # start/end angle
          bbox,
          path.stroke_color,
          path.fill_color,
          path.dash_pattern,
          path.line_width,
          nil,            # layer_name — filled by OCG tracker
          is_closed,
          area,
          page_num
        )
      end

      def self.convert_pt(pdf_pt, ox, oy, scale)
        x = (pdf_pt[0] - ox) * PDF_PT_TO_INCH * scale
        y = (pdf_pt[1] - oy) * PDF_PT_TO_INCH * scale
        [x, y]
      end

      def self.normalize_text_item(ti, ox, oy, scale, page_num)
        return nil unless ti.text && !ti.text.strip.empty?

        ins = convert_pt([ti.x, ti.y], ox, oy, scale)
        fs = ti.font_size * PDF_PT_TO_INCH * scale
        fs = 0.05 if fs < 0.01

        # Estimate bbox from insertion + font size
        text_w = ti.text.length * fs * 0.6
        text_h = fs * 1.2
        bbox = [ins[0], ins[1] - text_h * 0.3, ins[0] + text_w, ins[1] + text_h * 0.7]

        normalized = ti.text.strip.upcase.gsub(/\s+/, ' ')

        # Generic tags only — no domain-specific classification at this layer
        generic_tags = classify_generic(ti.text)

        NormalizedText.new(
          IDGen.next,
          ti.text.strip,
          normalized,
          ins,
          bbox,
          fs,
          ti.angle || 0.0,
          ti.font_name || "",
          page_num,
          generic_tags  # domain classification happens later in the pipeline
        )
      end

      def self.polygon_area(pts)
        n = pts.length
        area = 0.0
        n.times do |i|
          j = (i + 1) % n
          area += pts[i][0] * pts[j][1]
          area -= pts[j][0] * pts[i][1]
        end
        (area / 2.0).abs
      end

      # Domain-neutral text classification — domain-neutral,
      # just structural document understanding.
      def self.classify_generic(text)
        tags = []
        t = text.strip
        tu = t.upcase

        # Dimension-like: contains numbers with unit markers or fractions
        if t =~ /\d+['']\s*[-–]?\s*\d/ || t =~ /\d+\s*\/\s*\d+/ ||
           t =~ /\d+\.?\d*\s*(?:"|mm|cm|in|ft)/i || t =~ /\d+\s*['']/
          tags << :dimension_like
        end

        # Scale notation
        if tu =~ /SCALE[:\s]*\d/ || t =~ /\d+\s*:\s*\d+/ ||
           t =~ /\d+\s*\/\s*\d+\s*"?\s*=\s*/
          tags << :scale_like
        end

        # Note/label: short text, often capitalized
        if t.length > 1 && t.length < 60 && tu =~ /[A-Z]{2,}/
          tags << :label_like
        end

        # Title block keywords
        if tu =~ /\b(DRAWN|CHECKED|DATE|SCALE|REV|SHEET|PROJECT|DWG|TITLE|APPROVED|ENGINEER)\b/
          tags << :titleblock_like
        end

        # Table-like: very short, possibly a cell value
        if t =~ /\A\d{1,4}\z/ || t =~ /\A[A-Z]\d{1,3}\z/
          tags << :table_like
        end

        # Callout: has diameter, radius, or quantity markers
        if t =~ /Ø|\bDIA\b|\bRAD\b|\bR\d/i
          tags << :callout_like
        end

        # Quantity prefix
        if t =~ /\A\s*\(?\d+\)?\s*[-xX×]/
          tags << :callout_like
        end

        tags
      end

    end
  end
end
