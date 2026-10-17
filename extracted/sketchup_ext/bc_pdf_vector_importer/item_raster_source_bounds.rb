require 'digest'
require_relative 'page_transform'
require_relative 'representation_fidelity'

module BlueCollarSystems
  module PDFVectorImporter
    # Extractor boxes describe text layout, not necessarily all painted glyph
    # ink. Keep them immutable and separately bind a conservative enclosure of
    # only the source outlines uniquely assigned by the existing page matcher.
    module ItemRasterSourceBounds
      SCHEMA = 'bcs.item_raster_source_bounds/1'.freeze
      QUALIFIED = 'source_owned_ink_union'.freeze
      UNQUALIFIED = 'extractor_bbox_only'.freeze
      TOLERANCE = 1.0e-7

      def self.value(hash, key)
        return nil unless hash.is_a?(Hash)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def self.box?(box)
        box.is_a?(Array) && box.length == 4 &&
          box.all? { |v| v.is_a?(Numeric) && v.to_f.finite? } &&
          box[2] > box[0] && box[3] > box[1]
      end

      def self.union(boxes)
        return nil if boxes.empty? || !boxes.all? { |box| box?(box) }
        [boxes.map { |b| b[0] }.min, boxes.map { |b| b[1] }.min,
         boxes.map { |b| b[2] }.max, boxes.map { |b| b[3] }.max]
      end

      def self.same_box?(left, right)
        box?(left) && box?(right) && left.each_with_index.all? do |v, i|
          (v - right[i]).abs <= TOLERANCE
        end
      end

      def self.canonical_box(item, media)
        box = CairoGlyphSource.item_bbox_media_relative(item, media[0], media[1])
        return nil unless box.is_a?(Array) && box.length == 4 &&
          box.all? { |v| v.is_a?(Numeric) && v.to_f.finite? }
        x0, x1 = [box[0], box[2]].minmax
        y0, y1 = [box[1], box[3]].minmax
        box = [x0, y0, x1, y1]
        return nil unless box?(box)
        [box[0] + media[0], box[1] + media[1],
         box[2] + media[0], box[3] + media[1]]
      end

      def self.base(item, media, render_box, rotation, page, source_sha, reason)
        { :schema => SCHEMA, :status => UNQUALIFIED, :reason => reason.to_s,
          :source_span_id => RepresentationFidelity.source_span_id(item),
          :source_text_sha256 => Digest::SHA256.hexdigest(item.text.to_s),
          :source_pdf_sha256 => source_sha, :page_number => page.to_i,
          :page_rotation => PageTransform.normalize_rotation(rotation),
          :media_box => media.dup, :render_box => render_box.dup,
          :canonical_source_box => canonical_box(item, media) }
      end

      # SVG already contains intrinsic page rotation. Parse in its displayed
      # viewport, then invert that rotation exactly once before source matching.
      def self.raw_source_point(x, y, display_box, media, rotation)
        raw = PageTransform.inverse_transform_point(
          x + display_box[0], y + display_box[1], media, rotation)
        [raw[0] - media[0], raw[1] - media[1]]
      end

      def self.source_pens(svg, media, render_box, rotation)
        display_box = PageTransform.transform_bbox(*render_box, media, rotation)
        local_box = [0.0, 0.0, display_box[2] - display_box[0],
                     display_box[3] - display_box[1]]
        pens = CairoGlyphSource.pen_placements_pdf(svg, local_box)
        pens.map do |pen|
          copy = pen.dup
          copy[:x], copy[:y] = raw_source_point(
            pen[:x], pen[:y], display_box, media, rotation)
          [:ink_points_pdf, :ink_loops_pdf].each do |key|
            points = pen[key]
            next unless points.is_a?(Array)
            copy[key] = if key == :ink_loops_pdf
                          points.map { |loop| loop.map { |p|
                            raw_source_point(p[0], p[1], display_box, media, rotation) } }
                        else
                          points.map { |p|
                            raw_source_point(p[0], p[1], display_box, media, rotation) }
                        end
          end
          points = copy[:ink_points_pdf]
          copy[:ink_bbox_pdf] = [points.map { |p| p[0] }.min,
            points.map { |p| p[1] }.min, points.map { |p| p[0] }.max,
            points.map { |p| p[1] }.max] if points && !points.empty?
          if [90, 270].include?(PageTransform.normalize_rotation(rotation))
            copy[:source_primary_axis] = pen[:source_primary_axis] == :x ? :y : :x
          end
          copy
        end
      end

      # The path converter's point factory observes Bezier control points as
      # well as flattened points. Their convex hull encloses each complete
      # cubic/quadratic curve, avoiding a flattened-chord underestimate. Cairo
      # glyphs use these commands; unsupported arcs remain explicitly unproved.
      def self.conservative_local_points(path)
        return nil if path.to_s =~ /[Aa]/
        points = []
        factory = lambda do |x, y, z|
          points << [x * 72.0, y * 72.0]
          CairoGlyphSource::NumericPoint.new(x, y, z)
        end
        SvgTextRenderer.svg_path_to_points(path, 1.0 / 72.0,
          1.0 / 72.0, factory)
        return nil if points.empty? || points.flatten.any? { |v| !v.finite? }
        points
      end

      def self.placement_ink_boxes(svg, media, render_box, rotation)
        definitions = SvgTextRenderer.parse_glyph_defs(svg)
        stroked = stroked_placement_indices(svg)
        controls = {}
        display_box = PageTransform.transform_bbox(*render_box, media, rotation)
        view = SvgTextRenderer.parse_viewbox(svg)
        boxes = {}
        SvgTextRenderer.parse_use_placements(svg).each_with_index do |placement, index|
          next if stroked[index]
          glyph = placement[:glyph_id]
          controls[glyph] = conservative_local_points(definitions[glyph]) unless controls.key?(glyph)
          points = controls[glyph]
          next unless points
          matrix = placement[:matrix]
          matrix = [1, 0, 0, 1, 0, 0] unless matrix.is_a?(Array) && matrix.length >= 6
          a, b, c, d, e, f = matrix.map(&:to_f)
          e += placement[:x].to_f
          f += placement[:y].to_f
          raw_points = points.map do |x, y|
            dx = e - view[0].to_f + a * x - c * y
            dy = view[3].to_f + view[1].to_f - f - b * x + d * y
            raw_source_point(dx, dy, display_box, media, rotation)
          end
          relative = [raw_points.map { |p| p[0] }.min,
            raw_points.map { |p| p[1] }.min, raw_points.map { |p| p[0] }.max,
            raw_points.map { |p| p[1] }.max]
          absolute = [relative[0] + media[0], relative[1] + media[1],
                      relative[2] + media[0], relative[3] + media[1]]
          # The original page viewport clips visibility; controls outside it
          # must not enlarge a crop to unrelated off-page content.
          clipped = [[absolute[0], render_box[0]].max,
            [absolute[1], render_box[1]].max, [absolute[2], render_box[2]].min,
            [absolute[3], render_box[3]].min]
          boxes[index] = clipped if box?(clipped)
        end
        boxes
      end

      def self.stroked_placement_indices(svg)
        result, definitions, uses = {}, {}, []
        stack, index = [{ :stroke => 'none', :width => '1', :opacity => '1' }], 0
        svg.to_s.scan(/<\/?\s*[A-Za-z][A-Za-z0-9:_-]*\b[^>]*>/m) do |tag|
          if tag =~ /\A<\s*\//
            stack.pop if stack.length > 1
            next
          end
          attrs = SvgTextRenderer.svg_tag_attribute_map(tag)
          style = SvgTextRenderer.svg_style_property_map(attrs['style'])
          frame = stack.last.dup
          if SvgTextRenderer.glyph_reference_id?(attrs['id'])
            frame[:glyph_definition] = attrs['id']
          end
          { :stroke => 'stroke', :width => 'stroke-width', :opacity => 'stroke-opacity' }.each do |key, name|
            raw = style.key?(name) ? style[name] : attrs[name]
            frame[key] = raw unless raw.nil?
          end
          stack << frame
          visible = frame[:stroke].to_s.strip.downcase != 'none' &&
            frame[:width].to_s.strip != '0' && frame[:opacity].to_s.strip != '0'
          definitions[frame[:glyph_definition]] = true if visible && frame[:glyph_definition]
          if tag =~ /\A<\s*use\b/i
            href = attrs['xlink:href'] || attrs['href']
            if href && href.start_with?('#') && SvgTextRenderer.glyph_reference_id?(href[1..-1])
              uses << [index, href[1..-1], visible]
              index += 1
            end
          end
          stack.pop if tag =~ /\/\s*>\s*\z/
        end
        uses.each { |slot, glyph, visible| result[slot] = true if visible || definitions[glyph] }
        result
      end

      def self.prepare(document, items, media, render_box, rotation, page, source_sha)
        result = {}
        Array(items).each do |item|
          result[RepresentationFidelity.source_span_id(item)] = base(
            item, media, render_box, rotation, page, source_sha, 'source_svg_unavailable')
        end
        if result.length != Array(items).length
          result.each_value { |row| row[:reason] = 'duplicate_source_span_identity' }
          return result
        end
        svg = value(document, :svg).to_s
        return result if svg.empty?
        if svg =~ /<\s*style\b/i
          result.each_value { |row| row[:reason] = 'source_svg_stylesheet_unqualified' }
          return result
        end
        # Some pdftocairo builds reject the -cropbox option for SVG but still
        # emit the PDF CropBox viewport by default. Command-option metadata
        # alone therefore cannot establish the actual SVG origin. Resolve the
        # decoded dimensions against the two source boxes; tied equal-size
        # boxes at different origins are deliberately left unqualified.
        view = SvgTextRenderer.parse_viewbox(svg)
        candidates = [media, render_box].uniq.select do |box|
          (view[2].to_f - PageTransform.effective_width(box, rotation)).abs <= TOLERANCE &&
            (view[3].to_f - PageTransform.effective_height(box, rotation)).abs <= TOLERANCE
        end
        actual_render_box = candidates.length == 1 ? candidates.first : nil
        unless actual_render_box
          result.each_value { |row| row[:reason] = 'source_svg_viewport_unqualified' }
          return result
        end
        render_box = actual_render_box
        result.each_value do |row|
          row[:render_box] = render_box.dup
          row[:source_svg_render_box_used] = render_box == media ? 'media_box' : 'crop_box'
          row[:source_svg_declared_render_box_used] = value(document, :render_box_used).to_s
          row[:source_svg_viewport_basis] = 'unique_source_box_dimensions'
        end
        fonts, languages = value(document, :missing_fonts), value(document, :missing_language_packs)
        unless fonts.is_a?(Array) && languages.is_a?(Array)
          result.each_value { |row| row[:reason] = 'missing_source_resolution_evidence' }
          return result
        end
        if !fonts.empty? || !languages.empty?
          result.each_value { |row| row[:reason] = 'source_svg_font_resolution_unqualified' }
          return result
        end
        if (view[2].to_f - PageTransform.effective_width(render_box, rotation)).abs > TOLERANCE ||
           (view[3].to_f - PageTransform.effective_height(render_box, rotation)).abs > TOLERANCE
          result.each_value { |row| row[:reason] = 'source_svg_viewport_unqualified' }
          return result
        end
        pens = source_pens(svg, media, render_box, rotation)
        match = CairoGlyphSource.match_spans(pens, items, media)
        boxes = placement_ink_boxes(svg, media, render_box, rotation)
        owners = {}
        assignments = {}
        Array(match[:placement_matches]).each do |record|
          index = record[:placement_index]
          owners[index] ||= []
          owners[index] << record[:source_span_id].to_s
          assignments[record[:source_span_id].to_s] ||= []
          assignments[record[:source_span_id].to_s] << record
        end
        svg_sha = Digest::SHA256.hexdigest(svg)
        result.each do |sid, row|
          assigned = Array(assignments[sid])
          indices = assigned.map { |r| r[:placement_index] }
          row[:source_svg_sha256] = svg_sha
          row[:reason] = 'source_ink_ownership_unqualified'
          next if indices.empty? || indices.uniq.length != indices.length ||
            indices.any? { |index| owners[index] != [sid] || !boxes.key?(index) }
          records = indices.sort.map { |index|
            { :placement_index => index, :ink_box => boxes[index] } }
          row[:status] = QUALIFIED
          row[:reason] = 'unique_page_source_match'
          row[:source_placements] = records
          row[:source_ink_box] = union(records.map { |record| record[:ink_box] })
        end
        result
      rescue StandardError => error
        result.each_value do |row|
          row[:status] = UNQUALIFIED
          row[:reason] = 'source_ink_inspection_failed'
          row[:inspection_error] = "#{error.class}: #{error.message}"[0, 300]
          row.delete(:source_placements)
          row.delete(:source_ink_box)
        end
        result
      end

      def self.validate!(evidence, binding = {})
        canonical = value(evidence, :canonical_source_box)
        media = value(evidence, :media_box)
        page = value(evidence, :page_number)
        sid = value(evidence, :source_span_id)
        digest = value(evidence, :source_pdf_sha256)
        status = value(evidence, :status)
        unless value(evidence, :schema) == SCHEMA && box?(canonical) && box?(media) &&
               box?(value(evidence, :render_box)) && page.is_a?(Integer) && page > 0 &&
               /\Atext_span:#{page}:\d+\z/ =~ sid.to_s && /\A[0-9a-f]{64}\z/ =~ digest.to_s &&
               /\A[0-9a-f]{64}\z/ =~ value(evidence, :source_text_sha256).to_s &&
               [0, 90, 180, 270].include?(value(evidence, :page_rotation)) &&
               [QUALIFIED, UNQUALIFIED].include?(status) && !value(evidence, :reason).to_s.empty?
          fail_contract('source bounds metadata is invalid')
        end
        binding.each do |key, expected|
          actual = value(evidence, key)
          equal = [:canonical_source_box, :media_box].include?(key) ? same_box?(actual, expected) : actual == expected
          fail_contract("source bounds #{key} differs from its source") unless equal
        end
        return canonical if status == UNQUALIFIED
        placements = value(evidence, :source_placements)
        unless value(evidence, :reason) == 'unique_page_source_match' &&
               /\A[0-9a-f]{64}\z/ =~ value(evidence, :source_svg_sha256).to_s &&
               placements.is_a?(Array) && !placements.empty? && placements.all? { |p|
                 value(p, :placement_index).is_a?(Integer) && value(p, :placement_index) >= 0 && box?(value(p, :ink_box)) }
          fail_contract('source-owned ink placement evidence is invalid')
        end
        indices = placements.map { |p| value(p, :placement_index) }
        unless indices == indices.uniq.sort && same_box?(value(evidence, :source_ink_box),
                 union(placements.map { |p| value(p, :ink_box) }))
          fail_contract('source-owned ink union differs from its placements')
        end
        union([canonical, value(evidence, :source_ink_box)])
      end

      def self.requested_box!(evidence, media, rotation, padding)
        raw = validate!(evidence, :media_box => media,
          :page_rotation => PageTransform.normalize_rotation(rotation))
        unless padding.is_a?(Numeric) && padding.to_f.finite? && padding >= 0
          fail_contract('source crop padding is invalid')
        end
        [[raw[0] - padding, media[0]].max, [raw[1] - padding, media[1]].max,
         [raw[2] + padding, media[2]].min, [raw[3] + padding, media[3]].min]
      end

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, "item Raster source bounds: #{message}"
      end
    end
  end
end
