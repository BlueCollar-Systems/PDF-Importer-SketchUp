# Original authored annotation stroke inventory. No native entities or pixels.
# Ruby 2.2 compatible; unknown appearance programs remain explicitly unproven.
require 'digest'
require 'strscan'

module BlueCollarSystems
  module PDFVectorImporter
    module SourceRoundAnnotationInk
      class Unproven < StandardError; end
      IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze
      MAX_DEPTH = 8
      MAX_TOKENS = 4096

      def self.inventory(parser, page_number, source_sha256)
        data = parser.instance_variable_get(:@data)
        unless data.is_a?(String) && Digest::SHA256.hexdigest(data) == source_sha256
          raise Unproven, 'original PDF bytes are not bound to the annotation inventory'
        end
        records = []
        unsupported = []
        page = parser.page_data(page_number)
        raise Unproven, 'original page boxes are unavailable' unless page.is_a?(Hash)
        page_dict = dictionary(parser, parser.pages.fetch(page_number - 1))
        unit = parser.send(:find_inherited, page_dict, '/UserUnit')
        raise Unproven, 'original annotation UserUnit is unsupported' unless unit.nil? || number(unit) == 1.0
        page_clips = [polygon(rectangle(parser, page[:media_box]), IDENTITY)]
        page_clips << polygon(rectangle(parser, page[:crop_box]), IDENTITY) if page[:crop_box]
        parser.page_annotation_entries(page_number).each_with_index do |ref, index|
          dict = dictionary(parser, ref)
          next unless dict['/Subtype'] == '/Ink'
          begin
            record = qualify(parser, ref, dict, page_clips)
            record[:source_pdf_sha256] = source_sha256
            record[:page_number] = page_number
            record[:annotation_index] = index
            record[:page_clip_polygons_pdf] = page_clips
            records << record
          rescue Unproven => error
            unsupported << { :annotation_index => index, :annotation_ref => ref,
              :reason => error.message }
          end
        end
        { :schema => 'bcs.original_round_annotation_inventory/1',
          :source_pdf_sha256 => source_sha256, :page_number => page_number,
          :records => records, :unsupported => unsupported }
      end

      def self.qualify(parser, ref, dict, page_clips)
        flags = number(dict.fetch('/F', '0'))
        raise Unproven, 'annotation visibility flags are invalid' unless flags >= 0 && flags == flags.to_i
        raise Unproven, 'annotation is not screen-visible' unless (flags.to_i & 35) == 0
        raise Unproven, 'view-dependent annotation size/rotation is unsupported' unless (flags.to_i & 24) == 0
        raise Unproven, 'optional-content annotation visibility is unresolved' if dict.key?('/OC')
        rect = rectangle(parser, dict['/Rect'])
        appearance = dictionary(parser, dict['/AP'])['/N']
        form = dictionary(parser, appearance)
        raise Unproven, 'normal appearance is not an authored Form' unless form['/Subtype'] == '/Form'
        matrix = matrix_value(parser, form['/Matrix'])
        box = polygon(rectangle(parser, form['/BBox']), matrix)
        xs, ys = box.map { |p| p[0] }, box.map { |p| p[1] }
        width, height = xs.max - xs.min, ys.max - ys.min
        raise Unproven, 'normal appearance has a degenerate transformed box' unless width > 0 && height > 0
        sx, sy = (rect[2] - rect[0]) / width, (rect[3] - rect[1]) / height
        placement = [sx, 0.0, 0.0, sy, rect[0] - xs.min * sx, rect[1] - ys.min * sy]
        state = { :color => [0.0, 0.0, 0.0], :width => 1.0, :cap => 0,
          :alpha => 1.0, :blend => '/Normal', :matrix => placement }
        state[:alpha] = number(dict['/CA']) if dict.key?('/CA')
        state[:blend] = dict['/BM'] if dict.key?('/BM')
        validate_compositing!(state)
        proof = { :forms => [], :streams => [], :states => [], :strokes => [] }
        annotation_state = { :alpha => state[:alpha], :blend => state[:blend] }
        visit_form(parser, appearance, state, page_clips + [polygon(rect, IDENTITY)], proof, [])
        raise Unproven, 'appearance is not exactly one source stroke' unless proof[:strokes].length == 1
        stroke = proof[:strokes].first
        stroke.merge(:schema => 'bcs.original_round_annotation/1',
          :annotation_ref => ref, :appearance_ref => appearance,
          :annotation_graphics_state => annotation_state,
          :annotation_rect => rect, :forms => proof[:forms],
          :source_streams => proof[:streams], :graphics_states => proof[:states],
          :original_geometry_verified => true,
          :original_composite_pixels_verified => false)
      end

      def self.visit_form(parser, ref, inherited, clips, proof, chain)
        raise Unproven, 'cyclic or excessive appearance Form nesting' if chain.include?(ref) || chain.length >= MAX_DEPTH
        unless ref.is_a?(String) && ref =~ /\A(\d+)\s+\d+\s+R\z/
          raise Unproven, 'appearance stream reference is not bound'
        end
        object_number = Regexp.last_match(1).to_i
        form = dictionary(parser, ref)
        raise Unproven, 'appearance child is not a Form' unless form['/Subtype'] == '/Form'
        raise Unproven, 'optional-content Form visibility is unresolved' if form.key?('/OC')
        group = form.key?('/Group') ? dictionary(parser, form['/Group']) : nil
        if group
          unless group['/S'] == '/Transparency' &&
                 ['false', false, nil].include?(group['/K']) &&
                 ['false', false, 'true', true, nil].include?(group['/I']) &&
                 [nil, '/DeviceRGB'].include?(group['/CS']) &&
                 (group.keys - ['/S', '/I', '/K', '/CS', '/Type']).empty?
            raise Unproven, 'appearance transparency group semantics are unsupported'
          end
        end
        state = inherited.dup
        state[:matrix] = multiply(inherited[:matrix], matrix_value(parser, form['/Matrix']))
        local_clip = polygon(rectangle(parser, form['/BBox']), state[:matrix])
        clips = clips + [local_clip]
        resources = form.key?('/Resources') ? dictionary(parser, form['/Resources']) : {}
        body = parser.get_stream_data(object_number)
        raise Unproven, 'authored appearance stream is unavailable' unless body.is_a?(String)
        proof[:forms] << { :ref => ref, :matrix => state[:matrix], :clip_polygon => local_clip,
          :group => group }
        proof[:streams] << { :object_number => object_number, :sha256 => Digest::SHA256.hexdigest(body) }
        stack = []
        operands = []
        current = []
        tokens(body).each do |token|
          if token.is_a?(Numeric) || token.start_with?('/')
            operands << token
            next
          end
          case token
          when 'q'
            exact_operands!(operands, 0); stack << state.dup
          when 'Q'
            exact_operands!(operands, 0)
            raise Unproven, 'unbalanced appearance graphics state' if stack.empty?
            state = stack.pop
          when 'cm'
            exact_operands!(operands, 6)
            raise Unproven, 'path changes matrix before painting' unless current.empty?
            state[:matrix] = multiply(state[:matrix], operands.map { |n| number(n) })
          when 'RG'
            exact_operands!(operands, 3)
            color = operands.map { |n| number(n) }
            raise Unproven, 'source RGB is outside its declared range' unless color.all? { |n| n >= 0 && n <= 1 }
            state[:color] = color
          when 'w', 'J', 'j'
            exact_operands!(operands, 1)
            value = number(operands.first)
            if token == 'w'
              state[:width] = value
            else
              raise Unproven, 'source cap/join is invalid' unless [0.0, 1.0, 2.0].include?(value)
              state[:cap] = value.to_i if token == 'J'
            end
          when 'gs'
            exact_operands!(operands, 1)
            states = dictionary(parser, resources['/ExtGState'])
            effect = dictionary(parser, states[operands.first])
            allowed = ['/Type', '/CA', '/ca', '/BM', '/SMask']
            raise Unproven, 'appearance graphics state has unresolved paint effects' unless (effect.keys - allowed).empty?
            raise Unproven, 'appearance uses a soft mask' unless [nil, '/None'].include?(effect['/SMask'])
            ['/CA', '/ca'].each do |key|
              raise Unproven, 'appearance has non-unit alpha' if effect.key?(key) && number(effect[key]) != 1.0
            end
            state[:alpha] = number(effect['/CA']) if effect.key?('/CA')
            state[:blend] = effect['/BM'] if effect.key?('/BM')
            validate_compositing!(state)
            proof[:states] << { :form_ref => ref, :resource_name => operands.first, :dictionary => effect }
          when 'Do'
            exact_operands!(operands, 1)
            raise Unproven, 'appearance child interrupts an unfinished path' unless current.empty?
            xobjects = dictionary(parser, resources['/XObject'])
            visit_form(parser, xobjects[operands.first], state, clips, proof, chain + [ref])
          when 'm', 'l'
            exact_operands!(operands, 2)
            raise Unproven, 'appearance is not a single straight subpath' unless
              (token == 'm' && current.empty?) || (token == 'l' && current.length == 1)
            current << point(state[:matrix], operands.map { |n| number(n) })
          when 'S'
            exact_operands!(operands, 0)
            proof[:strokes] << qualify_stroke(current, state, clips)
            current = []
          else
            raise Unproven, "unsupported authored appearance operator #{token}"
          end
          operands = []
        end
        unless operands.empty? && stack.empty? && current.empty?
          raise Unproven, 'unfinished authored appearance program'
        end
      end

      def self.qualify_stroke(points, state, clips)
        validate_compositing!(state)
        raise Unproven, 'source stroke is not a positive-width round single line' unless
          points.length == 2 && state[:cap] == 1 && state[:width] > 0
        m = state[:matrix]
        xx, yy, dot = m[0]**2 + m[1]**2, m[2]**2 + m[3]**2, m[0]*m[2] + m[1]*m[3]
        tolerance = [xx, yy].max * 1.0e-12
        unless xx > 0 && yy > 0 && (xx - yy).abs <= tolerance && dot.abs <= tolerance
          raise Unproven, 'round source stroke becomes an unsupported noncircular footprint'
        end
        radius = state[:width] * Math.sqrt(xx) / 2.0
        raise Unproven, 'zero-length centerline needs a separate source proof' if points[0] == points[1]
        clips.each do |clip|
          area = clip.each_with_index.inject(0.0) do |sum, (p, i)|
            q = clip[(i + 1) % clip.length]; sum + p[0]*q[1] - p[1]*q[0]
          end
          raise Unproven, 'appearance clip is degenerate' if area == 0.0
          sign = area > 0 ? 1.0 : -1.0
          clip.each_with_index do |p, i|
            q = clip[(i + 1) % clip.length]
            dx, dy = q[0] - p[0], q[1] - p[1]
            length = Math.sqrt(dx*dx + dy*dy)
            raise Unproven, 'appearance clip has a zero-length boundary' unless length > 0
            points.each do |v|
              distance = sign * (dx*(v[1] - p[1]) - dy*(v[0] - p[0])) / length
              raise Unproven, 'source capsule is clipped or touches an unproved boundary' unless distance > radius
            end
          end
        end
        { :start_pdf => points[0], :end_pdf => points[1], :radius_pdf => radius,
          :stroke_rgb => state[:color], :blend_mode => state[:blend],
          :stroke_alpha => state[:alpha], :clip_polygons_pdf => clips,
          :full_capsule_clip_verified => true }
      end

      def self.validate_compositing!(state)
        unless state[:alpha] == 1.0 && ['/Normal', '/Compatible', '/Multiply'].include?(state[:blend])
          raise Unproven, 'source appearance blend/alpha is unsupported'
        end
      end

      def self.tokens(body)
        scan = StringScanner.new(body)
        result = []
        until scan.eos?
          next if scan.scan(/\s+/) || scan.scan(/%[^\r\n]*(?:\r?\n|\z)/)
          if raw = scan.scan(/[+-]?(?:\d+(?:\.\d*)?|\.\d+)/)
            result << number(raw)
          elsif raw = scan.scan(/\/[A-Za-z0-9_.-]+|[A-Za-z]+/)
            result << raw
          else
            raise Unproven, 'unsupported authored appearance token'
          end
          raise Unproven, 'authored appearance token budget exceeded' if result.length > MAX_TOKENS
        end
        result
      end

      def self.exact_operands!(operands, count)
        raise Unproven, 'appearance operator operands are malformed' unless operands.length == count
      end

      def self.number(value)
        result = Float(value)
        raise Unproven, 'source numeric value is nonfinite' unless result.finite?
        result
      rescue ArgumentError, TypeError
        raise Unproven, 'source numeric value is invalid'
      end

      def self.dictionary(parser, value)
        result = parser.send(:to_dict, parser.resolve_object(value))
        raise Unproven, 'source resource dictionary is unresolved' unless result.is_a?(Hash)
        result
      end

      def self.array_value(parser, value, count)
        values = parser.resolve_object(value)
        values = parser.send(:parse_array_string, values) if values.is_a?(String) && values.strip.start_with?('[')
        raise Unproven, 'source array is malformed' unless values.is_a?(Array) && values.length == count
        values.map { |n| number(n) }
      end

      def self.rectangle(parser, value)
        box = array_value(parser, value, 4)
        raise Unproven, 'source rectangle is empty' unless box[2] > box[0] && box[3] > box[1]
        box
      end

      def self.matrix_value(parser, value)
        value.nil? ? IDENTITY.dup : array_value(parser, value, 6)
      end

      def self.multiply(a, b)
        [a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1],
         a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3],
         a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5]]
      end

      def self.point(m, p)
        [m[0]*p[0]+m[2]*p[1]+m[4], m[1]*p[0]+m[3]*p[1]+m[5]]
      end

      def self.polygon(box, matrix)
        [[box[0], box[1]], [box[2], box[1]], [box[2], box[3]], [box[0], box[3]]].map { |p| point(matrix, p) }
      end
    end
  end
end
