# Read-only, bounded paint-order evidence from one already-rendered Cairo SVG.
# Coordinates match CairoGlyphSource.model_space_loops before page rotation.
# Unsupported clipping/compositing is excluded; this never authorizes fallback.
require File.join(File.dirname(__FILE__), 'cairo_glyph_source')

module BlueCollarSystems
  module PDFVectorImporter
    module SvgPaintOrder
      IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze
      NUMBER = /[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/
      TAGS = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\/?\s*[A-Za-z][A-Za-z0-9:_-]*\b[^>]*>/m

      # :loops are arrays of [x,y,0] in model inches. :ink_loops_pdf and
      # :ink_bbox_pdf use media-relative PDF points, y-up. Offsets are in model
      # inches; defaults match the existing glyph geometry mapping exactly.
      def self.build(svg, media_box, opts = {})
        source = svg.to_s
        result = { :white_paths => [], :glyphs => [], :glyphs_by_placement_index => {},
                   :excluded => [], :order_space => 'cairo_svg_document_offset' }
        if source =~ /<\s*style\b|<\s*script\b|<!DOCTYPE|<\?xml-stylesheet/i
          result[:excluded] << { :reason => 'unsupported_document_style_or_entities' }
          return result
        end
        mapping = coordinate_mapping(source, media_box, opts)
        uses = SvgTextRenderer.parse_use_placements(source)
        use_indices = {}
        uses.each_with_index { |use, i| use_indices[use[:source_svg_offset]] = i }
        definitions = SvgTextRenderer.parse_glyph_defs(source)
        clip_definitions = bounded_clip_definitions(source)
        local_loops = {}
        definition_validity = {}
        glyph_events = []
        stack = [initial_context]
        source.scan(TAGS) do |token|
          offset = Regexp.last_match.begin(0) # Before any nested regex calls.
          next if token.start_with?('<!--', '<![CDATA[')
          if token =~ /\A<\s*\/\s*([A-Za-z][A-Za-z0-9:_-]*)/
            name = Regexp.last_match(1).downcase
            raise ArgumentError, 'unbalanced SVG context' unless stack.length > 1 && stack.last[:name] == name
            stack.pop
            next
          end
          name = token[/\A<\s*([A-Za-z][A-Za-z0-9:_-]*)/, 1].to_s.downcase
          attrs = SvgTextRenderer.svg_tag_attribute_map(token)
          frame = context_for(stack.last, name, attrs)
          stack << frame
          if frame[:definitions]
            inspect_definition!(definition_validity, frame, name, attrs)
          elsif name == 'path' || name == 'rect'
            if white?(frame[:fill]) && frame[:alpha] == 1.0
              reason = frame[:reason]
              if reason
                result[:excluded] << { :kind => :white_path, :svg_document_offset => offset, :reason => reason }
              else
                begin
                  loops = shape_loops(name, attrs)
                  record = paint_record(loops, frame, mapping, offset)
                  record[:fill_rule] = frame[:fill_rule]
                  record = resolve_white_clips(record, frame, mapping, clip_definitions, name, attrs)
                  result[:white_paths] << record
                rescue ArgumentError => error
                  result[:excluded] << { :kind => :white_path, :svg_document_offset => offset, :reason => error.message }
                end
              end
            end
          elsif name == 'use'
            href = attrs['xlink:href'] || attrs['href']
            id = href && href.start_with?('#') ? href[1..-1] : nil
            if id && SvgTextRenderer.glyph_reference_id?(id)
              glyph_events << { :glyph_id => id, :attrs => attrs, :context => frame,
                                :offset => offset, :placement_index => use_indices[offset] }
            end
          end
          stack.pop if token =~ /\/\s*>\s*\z/
        end
        raise ArgumentError, 'unclosed SVG context' unless stack.length == 1
        by_physical = {}
        glyph_events.each do |event|
          id = event[:glyph_id]
          frame = event[:context]
          reason = frame[:reason]
          reason ||= 'unsupported_clip-path' unless frame[:clips].empty?
          reason ||= 'empty_source_glyph_definition' if definition_validity[id] == :empty
          reason ||= 'unsupported_glyph_definition' unless definition_validity[id] == true && definitions.key?(id)
          reason ||= 'missing_placement_index' unless event[:placement_index].is_a?(Integer)
          reason ||= 'unknown_glyph_paint' unless frame[:fill].is_a?(Array) && frame[:alpha].is_a?(Numeric)
          if reason
            result[:excluded] << { :kind => :glyph, :placement_index => event[:placement_index],
                                  :svg_document_offset => event[:offset], :reason => reason }
            next
          end
          begin
            local_loops[id] ||= path_loops(definitions[id])
            matrix = multiply(frame[:matrix], [1.0, 0.0, 0.0, 1.0,
              strict_number(event[:attrs]['x'] || '0'), strict_number(event[:attrs]['y'] || '0')])
            glyph_frame = frame.merge(:matrix => matrix)
            record = paint_record(local_loops[id], glyph_frame, mapping, event[:offset])
            record[:glyph_id] = id
            record[:placement_index] = event[:placement_index]
            record[:placement_indices] = [event[:placement_index]]
            record[:paint_orders] = [record[:paint_order]]
            # The renderer retains one physical copy of identical opaque ink.
            # Keep its first index, but the final identical repaint determines
            # whether that ink covers an intervening white mask. Translucent
            # repaints cannot collapse to one effective opaque paint event.
            key = [id, matrix, frame[:fill], frame[:alpha], frame[:fill_rule]]
            previous = frame[:alpha] == 1.0 ? by_physical[key] : nil
            if previous
              previous[:placement_indices] << event[:placement_index]
              previous[:paint_orders] << record[:paint_order]
              previous[:paint_order] = record[:paint_order]
              previous[:svg_document_offset] = record[:svg_document_offset]
              result[:glyphs_by_placement_index][event[:placement_index]] = previous
            else
              by_physical[key] = record if frame[:alpha] == 1.0
              result[:glyphs] << record
              result[:glyphs_by_placement_index][event[:placement_index]] = record
            end
          rescue ArgumentError => error
            result[:excluded] << { :kind => :glyph, :placement_index => event[:placement_index],
                                  :svg_document_offset => event[:offset], :reason => error.message }
          end
        end
        result
      rescue ArgumentError => error
        { :white_paths => [], :glyphs => [], :glyphs_by_placement_index => {},
          :excluded => [{ :reason => error.message }], :order_space => 'cairo_svg_document_offset' }
      end

      def self.initial_context
        { :name => nil, :matrix => IDENTITY, :fill => [0.0, 0.0, 0.0],
          :fill_opacity => 1.0, :opacity_product => 1.0, :alpha => 1.0,
          :fill_rule => :nonzero, :definitions => false, :reason => nil,
          :glyph_definition => nil, :definition_clean => true, :clips => [] }
      end

      def self.context_for(parent, name, attrs)
        style = SvgTextRenderer.svg_style_property_map(attrs['style'])
        get = lambda { |key| style.key?(key) ? style[key] : attrs[key] }
        frame = parent.dup
        frame[:name] = name
        frame[:definitions] ||= ['defs', 'symbol', 'clippath', 'mask', 'pattern'].include?(name)
        frame[:glyph_definition] = attrs['id'] if attrs['id'] && SvgTextRenderer.glyph_reference_id?(attrs['id'])
        frame[:definition_clean] &&= (attrs.keys - ['id', 'd']).empty? if frame[:definitions] && frame[:glyph_definition]
        frame[:reason] ||= 'unsupported_svg_container' unless ['svg', 'g', 'a', 'defs', 'symbol', 'clippath', 'path', 'rect', 'use', 'image', 'title', 'desc', 'metadata'].include?(name)
        frame[:reason] ||= 'unsupported_nested_svg_viewport' if name == 'svg' && parent[:name]
        frame[:reason] ||= 'unsupported_css_class' if attrs['class']
        if style['transform'] || style['transform-origin'] || style['perspective']
          frame[:reason] ||= 'unsupported_css_transform'
        end
        ['mask', 'filter'].each do |key|
          value = get.call(key)
          frame[:reason] ||= 'unsupported_' + key if value && value.strip != 'none'
        end
        frame[:reason] ||= 'non_normal_blend' if get.call('mix-blend-mode') && get.call('mix-blend-mode').strip != 'normal'
        frame[:reason] ||= 'hidden_paint' if get.call('display') == 'none' || ['hidden', 'collapse'].include?(get.call('visibility'))
        frame[:reason] ||= 'unsupported_paint_server' if get.call('fill').to_s.include?('url(')
        frame[:fill] = SvgTextRenderer.parse_svg_color(get.call('fill')) if get.call('fill')
        frame[:fill_opacity] = SvgTextRenderer.parse_svg_opacity(get.call('fill-opacity')) if get.call('fill-opacity')
        local_alpha = get.call('opacity') ? SvgTextRenderer.parse_svg_opacity(get.call('opacity')) : 1.0
        frame[:opacity_product] = SvgTextRenderer.multiply_svg_opacity(parent[:opacity_product], local_alpha)
        frame[:alpha] = SvgTextRenderer.multiply_svg_opacity(frame[:fill_opacity], frame[:opacity_product])
        if get.call('fill-rule')
          rule = get.call('fill-rule').strip
          frame[:reason] ||= 'unknown_fill_rule' unless ['nonzero', 'evenodd'].include?(rule)
          frame[:fill_rule] = rule.to_sym
        end
        begin
          frame[:matrix] = multiply(parent[:matrix], parse_transform(attrs['transform']))
        rescue ArgumentError
          frame[:reason] ||= 'unsupported_transform'
        end
        clip = get.call('clip-path')
        if clip && clip.strip != 'none'
          match = /\Aurl\(#([A-Za-z_][A-Za-z0-9_.:-]*)\)\z/.match(clip.strip)
          if match
            frame[:clips] = parent[:clips] + [{ :id => match[1], :matrix => frame[:matrix] }]
          else
            frame[:reason] ||= 'unsupported_clip-path'
          end
        end
        frame
      end

      # Cairo emits user-space clip definitions as one explicit linear path.
      # Keep compound contours and their actual clip rule, including holes.
      # Other definition structures remain unsupported, never approximated.
      def self.bounded_clip_definitions(source)
        result = {}
        source.scan(/<clipPath\b([^>]*)>(.*?)<\/clipPath>/mi) do |text, body|
          attrs = SvgTextRenderer.svg_tag_attribute_map(text)
          id = attrs['id']
          next unless id
          if result.key?(id)
            result[id] = nil
            next
          end
          result[id] = nil
          next unless (attrs.keys - ['id', 'clippathunits']).empty?
          next if attrs['clippathunits'] && attrs['clippathunits'] != 'userSpaceOnUse'
          path = /\A\s*(<path\b[^>]*\/>)\s*\z/m.match(body)
          next unless path
          p = SvgTextRenderer.svg_tag_attribute_map(path[1])
          next unless (p.keys - ['d', 'clip-rule']).empty? && linear_path?(p['d'])
          # Inherited clip-rule is intentionally outside this bounded parser.
          # Cairo declares it on each path; absence must remain unproven.
          rule = p['clip-rule']
          next unless ['nonzero', 'evenodd'].include?(rule)
          begin
            loops = path_loops(p['d'])
            result[id] = { :loops => loops, :fill_rule => rule.to_sym } unless loops.empty?
          rescue ArgumentError
            # This clip cannot supply proof; callers keep a precise exclusion.
          end
        end
        result
      end

      def self.linear_path?(value)
        !value.to_s.empty? && value.to_s.gsub(NUMBER, '').gsub(/[MmLlHhVvZz\s,]/, '').empty?
      end

      def self.axis_rectangle?(record)
        loops = record[:loops]
        return false unless loops.length == 1
        points = loops[0].map { |point| point.first(2) }
        points.pop if points.length > 1 && points[-1] == points[0]
        return false unless points.length == 4 && points.uniq.length == 4
        x0, y0, x1, y1 = record[:bounds]
        return false unless points.sort == [[x0,y0], [x1,y0], [x1,y1], [x0,y1]].sort
        previous = points[-1]
        points.all? do |point|
          aligned = point[0] == previous[0] || point[1] == previous[1]
          previous = point
          aligned
        end
      end

      def self.bounds_cover?(outer, inner)
        outer[0] <= inner[0] && outer[1] <= inner[1] && outer[2] >= inner[2] && outer[3] >= inner[3]
      end

      def self.resolve_white_clips(record, frame, mapping, definitions, name, attrs)
        return record if frame[:clips].empty?
        unless axis_rectangle?(record) && (name == 'rect' || linear_path?(attrs['d']))
          raise ArgumentError, 'unsupported_clipped_white_shape'
        end
        clips = frame[:clips].map do |clip|
          definition = definitions[clip[:id]]
          raise ArgumentError, 'unsupported_clip-path' unless definition
          clip_frame = frame.merge(:matrix => clip[:matrix], :fill_rule => definition[:fill_rule])
          paint_record(definition[:loops], clip_frame, mapping, record[:svg_document_offset])
        end
        nonrectangular = clips.reject { |clip| axis_rectangle?(clip) }
        raise ArgumentError, 'unsupported_clip_intersection' if nonrectangular.length > 1
        candidates = nonrectangular.empty? ? clips : nonrectangular
        selected = candidates.find do |candidate|
          bounds_cover?(record[:bounds], candidate[:bounds]) && clips.all? do |other|
            other.equal?(candidate) || (axis_rectangle?(other) && bounds_cover?(other[:bounds], candidate[:bounds]))
          end
        end
        unless selected
          # Cairo's covering rectangle can stop one output-grid step before
          # its mask edge. Intersect exact straight source segments with the
          # rectangular bounds; do not expand either contour by a tolerance.
          rectangles = [record] + clips.select { |clip| axis_rectangle?(clip) }
          bounds = [rectangles.map { |r| r[:ink_bbox_pdf][0] }.max,
                    rectangles.map { |r| r[:ink_bbox_pdf][1] }.max,
                    rectangles.map { |r| r[:ink_bbox_pdf][2] }.min,
                    rectangles.map { |r| r[:ink_bbox_pdf][3] }.min]
          raise ArgumentError, 'empty_clipped_white_shape' unless bounds[2] > bounds[0] && bounds[3] > bounds[1]
          source = nonrectangular.empty? ? record : nonrectangular.first
          pdf = source[:ink_loops_pdf].map { |loop| clip_loop_to_rectangle(loop, bounds) }.reject(&:empty?)
          selected = mapped_record(pdf, frame.merge(:fill_rule => source[:fill_rule]), mapping, record[:svg_document_offset])
          selected[:clip_proof] = 'exact_linear_clip_intersection_with_axis_aligned_rectangles'
        end
        selected[:clip_ids] = frame[:clips].map { |clip| clip[:id] }
        selected[:clip_proof] ||= 'opaque_rectangle_covers_exact_linear_clip_with_rectangular_ancestors'
        selected
      end

      def self.clip_loop_to_rectangle(loop, bounds)
        points = loop.map(&:dup)
        points.pop if points.length > 1 && points[-1] == points[0]
        [[0,bounds[0],1], [0,bounds[2],-1], [1,bounds[1],1], [1,bounds[3],-1]].each do |axis, limit, sign|
          break if points.empty?
          output = []
          previous = points[-1]
          previous_inside = sign * (previous[axis] - limit) >= 0.0
          points.each do |point|
            inside = sign * (point[axis] - limit) >= 0.0
            if inside != previous_inside
              fraction = (limit - previous[axis]) / (point[axis] - previous[axis])
              other_axis = 1 - axis
              crossing = [0.0, 0.0]
              crossing[axis] = limit
              crossing[other_axis] = previous[other_axis] + fraction * (point[other_axis] - previous[other_axis])
              output << crossing unless output[-1] == crossing
            end
            output << point if inside && output[-1] != point
            previous, previous_inside = point, inside
          end
          points = output
        end
        points.pop if points.length > 1 && points[-1] == points[0]
        return [] if points.uniq.length < 3
        points + [points[0].dup]
      end

      def self.inspect_definition!(validity, frame, name, attrs)
        id = frame[:glyph_definition]
        return unless id
        if name == 'g' && attrs['id'] == id
          clean = frame[:definition_clean] && frame[:matrix] == IDENTITY && !frame[:reason]
          validity[id] = !validity.key?(id) && clean ? :empty : false
          return
        end
        unless name == 'path'
          validity[id] = false
          return
        end
        clean = frame[:definition_clean] && frame[:matrix] == IDENTITY && !frame[:reason] && attrs['d']
        validity[id] = validity.key?(id) && validity[id] != :empty ? false : !!clean
      end

      def self.white?(rgb)
        rgb.is_a?(Array) && rgb.length == 3 && rgb.all? { |v| (v - 1.0).abs <= 1.0e-12 }
      end

      def self.strict_number(value)
        text = value.to_s.strip
        raise ArgumentError, 'invalid_svg_number' unless text =~ /\A#{NUMBER.source}\z/
        number = text.to_f
        raise ArgumentError, 'nonfinite_svg_number' unless number.finite?
        number
      end

      def self.parse_transform(value)
        return IDENTITY if value.nil? || value.strip.empty?
        matrix = IDENTITY
        consumed = String.new
        value.scan(/([A-Za-z]+)\s*\(([^)]*)\)/) do |name, body|
          consumed << Regexp.last_match(0)
          values = body.split(/[\s,]+/).reject(&:empty?).map { |v| strict_number(v) }
          transform = case name
          when 'matrix'
            raise ArgumentError, 'invalid_matrix' unless values.length == 6
            values
          when 'translate'
            raise ArgumentError, 'invalid_translate' unless [1, 2].include?(values.length)
            [1.0, 0.0, 0.0, 1.0, values[0], values[1] || 0.0]
          when 'scale'
            raise ArgumentError, 'invalid_scale' unless [1, 2].include?(values.length)
            [values[0], 0.0, 0.0, values[1] || values[0], 0.0, 0.0]
          when 'rotate'
            raise ArgumentError, 'invalid_rotate' unless [1, 3].include?(values.length)
            angle = values[0] * Math::PI / 180.0
            rotation = [Math.cos(angle), Math.sin(angle), -Math.sin(angle), Math.cos(angle), 0.0, 0.0]
            if values.length == 3
              multiply(multiply([1.0, 0.0, 0.0, 1.0, values[1], values[2]], rotation),
                       [1.0, 0.0, 0.0, 1.0, -values[1], -values[2]])
            else
              rotation
            end
          else
            raise ArgumentError, 'unsupported_transform_function'
          end
          matrix = multiply(matrix, transform)
        end
        unless consumed.gsub(/[\s,]/, '') == value.gsub(/[\s,]/, '')
          raise ArgumentError, 'unparsed_transform'
        end
        matrix
      end

      def self.multiply(left, right)
        a, b, c, d, e, f = left
        g, h, i, j, k, l = right
        [a*g+c*h, b*g+d*h, a*i+c*j, b*i+d*j, a*k+c*l+e, b*k+d*l+f]
      end

      def self.path_loops(d)
        factory = lambda { |x, y, z| CairoGlyphSource::NumericPoint.new(x, y, z) }
        SvgTextRenderer.svg_path_to_points(d, 1.0 / 72.0, 1.0 / 72.0, factory).select do |loop|
          loop.length >= 3
        end.map do |loop|
          loop.map { |p| [p.x * 72.0, -p.y * 72.0] }
        end
      end

      def self.shape_loops(name, attrs)
        return path_loops(attrs['d']) if name == 'path'
        raise ArgumentError, 'unsupported_rounded_rectangle' if attrs['rx'] || attrs['ry']
        x, y = strict_number(attrs['x'] || '0'), strict_number(attrs['y'] || '0')
        width, height = strict_number(attrs['width']), strict_number(attrs['height'])
        raise ArgumentError, 'invalid_rectangle_size' unless width > 0.0 && height > 0.0
        [[[x,y], [x+width,y], [x+width,y+height], [x,y+height], [x,y]]]
      end

      def self.coordinate_mapping(source, media_box, opts)
        page_box = opts[:svg_page_box] || media_box
        unless [media_box, page_box].all? { |box| box.is_a?(Array) && box.length >= 4 && box.first(4).all? { |v| v.is_a?(Numeric) && v.finite? } }
          raise ArgumentError, 'invalid_page_box'
        end
        viewbox = SvgTextRenderer.parse_viewbox(source)
        raise ArgumentError, 'invalid_svg_viewbox' unless viewbox[2] > 0.0 && viewbox[3] > 0.0
        scale = strict_number(opts[:scale] || 1.0)
        raise ArgumentError, 'invalid_model_scale' unless scale > 0.0
        { :viewbox => viewbox, :dx => page_box[0] - media_box[0], :dy => page_box[1] - media_box[1],
          :unit => scale / 72.0, :x_offset => strict_number(opts[:x_offset] || 0.0),
          :y_offset => strict_number(opts[:y_offset] || 0.0) }
      end

      def self.paint_record(loops, frame, mapping, offset)
        raise ArgumentError, 'empty_source_contours' if loops.empty?
        a, b, c, d, e, f = frame[:matrix]
        vb = mapping[:viewbox]
        pdf = loops.map do |loop|
          loop.map do |point|
            x, y = point
            [a*x+c*y+e-vb[0]+mapping[:dx], vb[3]+vb[1]-(b*x+d*y+f)+mapping[:dy]]
          end
        end
        mapped_record(pdf, frame, mapping, offset)
      end

      def self.mapped_record(pdf, frame, mapping, offset)
        raise ArgumentError, 'empty_source_contours' if pdf.empty?
        points = pdf.flatten(1)
        raise ArgumentError, 'nonfinite_source_contours' unless points.flatten.all? { |v| v.finite? }
        bbox = [points.map { |p| p[0] }.min, points.map { |p| p[1] }.min,
                points.map { |p| p[0] }.max, points.map { |p| p[1] }.max]
        raise ArgumentError, 'degenerate_source_contours' unless bbox[2] > bbox[0] && bbox[3] > bbox[1]
        model = pdf.map { |loop| loop.map { |x,y| [x*mapping[:unit]+mapping[:x_offset], y*mapping[:unit]+mapping[:y_offset], 0.0] } }
        { :svg_document_offset => offset, :paint_order => [0, offset],
          :loops => model, :ink_loops_pdf => pdf, :ink_bbox_pdf => bbox,
          :bounds => [bbox[0]*mapping[:unit]+mapping[:x_offset], bbox[1]*mapping[:unit]+mapping[:y_offset],
                      bbox[2]*mapping[:unit]+mapping[:x_offset], bbox[3]*mapping[:unit]+mapping[:y_offset]],
          :fill_rgb => frame[:fill].dup, :fill_opacity => frame[:alpha],
          :fill_rule => frame[:fill_rule] }
      end
    end
  end
end
