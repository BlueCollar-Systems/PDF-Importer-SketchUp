# bc_pdf_vector_importer/content_stream_parser.rb
# Parses PDF content streams and extracts vector path data.
# Handles all PDF path construction and painting operators,
# graphics state (CTM transforms), and clipping paths.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    class ContentStreamParser
      MAX_TOKENS_PER_STREAM = 1_000_000

      # A VectorPath represents one complete path with its sub-paths
      VectorPath = Struct.new(
        :subpaths,       # Array of SubPath
        :stroke,         # Boolean — was this path stroked?
        :fill,           # Boolean — was this path filled?
        :stroke_color,   # [r, g, b] 0.0–1.0
        :fill_color,     # [r, g, b] 0.0–1.0
        :line_width,     # Float (in PDF points)
        :line_cap,       # 0=butt, 1=round, 2=square
        :line_join,      # 0=miter, 1=round, 2=bevel
        :dash_pattern,   # [array, phase] or nil
        :ctm,            # [a, b, c, d, e, f] transformation matrix at time of painting
        :layer_name      # String — OCG layer name, or nil
      )

      SubPath = Struct.new(
        :segments,     # Array of Segment
        :closed        # Boolean — was 'h' (closepath) used?
      )

      Segment = Struct.new(
        :type,     # :move, :line, :curve, :rect
        :points    # Array of [x, y] in PDF user space
      )

      def initialize(streams, pdf_parser, ocg_map = {})
        @streams = streams       # Array of decoded stream strings
        @pdf_parser = pdf_parser
        @ocg_map = ocg_map       # { "MC0" => "Layer Name", ... }
        @paths = []
      end

      # ---------------------------------------------------------------
      # Parse all streams and return array of VectorPath
      # ---------------------------------------------------------------
      def parse
        @paths = []

        # Graphics state stack
        @gs_stack = []
        reset_graphics_state

        # Current path being constructed
        @current_subpaths = []
        @current_segments = []
        @current_point = nil

        # Marked content / OCG layer tracking
        @mc_layer_stack = []
        @current_ocg_layer = nil

        @streams.each do |stream|
          next unless stream && !stream.empty?
          tokens = tokenize_content_stream(stream)
          execute_operators(tokens)
        end

        @paths
      end

      private

      # ---------------------------------------------------------------
      # Graphics state
      # ---------------------------------------------------------------
      def reset_graphics_state
        @ctm = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]  # Identity matrix
        @stroke_color = [0.0, 0.0, 0.0]
        @fill_color = [0.0, 0.0, 0.0]
        @line_width = 1.0
        @line_cap = 0
        @line_join = 0
        @dash_pattern = nil
        @color_space_stroke = '/DeviceGray'
        @color_space_fill = '/DeviceGray'
      end

      def save_graphics_state
        @gs_stack.push({
          ctm: @ctm.dup,
          stroke_color: @stroke_color.dup,
          fill_color: @fill_color.dup,
          line_width: @line_width,
          line_cap: @line_cap,
          line_join: @line_join,
          dash_pattern: @dash_pattern,
          color_space_stroke: @color_space_stroke,
          color_space_fill: @color_space_fill
        })
      end

      def restore_graphics_state
        gs = @gs_stack.pop
        return unless gs
        @ctm = gs[:ctm]
        @stroke_color = gs[:stroke_color]
        @fill_color = gs[:fill_color]
        @line_width = gs[:line_width]
        @line_cap = gs[:line_cap]
        @line_join = gs[:line_join]
        @dash_pattern = gs[:dash_pattern]
        @color_space_stroke = gs[:color_space_stroke]
        @color_space_fill = gs[:color_space_fill]
      end

      # ---------------------------------------------------------------
      # Matrix operations
      # ---------------------------------------------------------------
      def concat_matrix(a, b, c, d, e, f)
        # Multiply new matrix [a,b,c,d,e,f] by current CTM
        m = @ctm
        @ctm = [
          a * m[0] + b * m[2],
          a * m[1] + b * m[3],
          c * m[0] + d * m[2],
          c * m[1] + d * m[3],
          e * m[0] + f * m[2] + m[4],
          e * m[1] + f * m[3] + m[5]
        ]
      end

      def transform_point(x, y)
        m = @ctm
        tx = m[0] * x + m[2] * y + m[4]
        ty = m[1] * x + m[3] * y + m[5]
        [tx, ty]
      end

      # ---------------------------------------------------------------
      # Content stream tokenizer
      # ---------------------------------------------------------------
      def tokenize_content_stream(stream)
        tokens = []
        i = 0
        len = stream.length

        while i < len
          if tokens.length > MAX_TOKENS_PER_STREAM
            Logger.warn("ContentParser", "Token limit reached (#{MAX_TOKENS_PER_STREAM}) — truncating stream parse")
            break
          end

          c = stream[i]

          # Whitespace
          if c =~ /[\s\x00]/
            i += 1
            next
          end

          # Comment
          if c == '%'
            eol = stream.index(/[\r\n]/, i) || len
            i = eol + 1
            next
          end

          # String literal
          if c == '('
            depth = 1
            j = i + 1
            while j < len && depth > 0
              if stream[j] == '\\' 
                j += 2
                next
              end
              depth += 1 if stream[j] == '('
              depth -= 1 if stream[j] == ')'
              j += 1
            end
            tokens << { type: :string, value: stream[i...j] }
            i = j
            next
          end

          # Hex string
          if c == '<' && (i + 1 >= len || stream[i + 1] != '<')
            j = stream.index('>', i) || len
            tokens << { type: :hex_string, value: stream[i..j] }
            i = j + 1
            next
          end

          # Dict
          if c == '<' && i + 1 < len && stream[i + 1] == '<'
            depth = 1
            j = i + 2
            while j < len - 1 && depth > 0
              if stream[j, 2] == '<<'
                depth += 1
                j += 2
              elsif stream[j, 2] == '>>'
                depth -= 1
                j += 2
              else
                j += 1
              end
            end
            tokens << { type: :dict, value: stream[i...j] }
            i = j
            next
          end

          if c == '>' && i + 1 < len && stream[i + 1] == '>'
            i += 2
            next
          end

          # Array
          if c == '['
            depth = 1
            j = i + 1
            while j < len && depth > 0
              depth += 1 if stream[j] == '['
              depth -= 1 if stream[j] == ']'
              j += 1
            end
            tokens << { type: :array, value: stream[i...j] }
            i = j
            next
          end

          if c == ']'
            i += 1
            next
          end

          # Name
          if c == '/'
            j = i + 1
            while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/
              j += 1
            end
            tokens << { type: :name, value: stream[i...j] }
            i = j
            next
          end

          # Number or keyword
          j = i
          while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/
            j += 1
          end

          # Safety: if current char is an unhandled delimiter (for example '{' or '}'),
          # consume it so we don't loop forever on malformed/binary data.
          if j == i
            i += 1
            next
          end

          word = stream[i...j]

          # Inline image: BI <key-value pairs> ID <binary data> EI
          # When we see 'BI', skip forward past the binary data to 'EI'.
          if word == 'BI'
            # Find 'ID' marker (signals start of binary image data)
            id_pos = stream.index(/\sID[\s\n\r]/, j)
            if id_pos
              # Find 'EI' marker after the binary data.
              # EI must be preceded by whitespace to avoid false matches
              # inside the binary data.
              ei_pos = stream.index(/[\s\n\r]EI(?=[\s\n\r\/\[<])/, id_pos + 3)
              if ei_pos
                i = ei_pos + 3  # skip past 'EI'
              else
                i = len  # malformed — skip to end
              end
            else
              i = j  # no ID found — just skip the BI token
            end
            next
          end

          if word =~ /\A[+-]?\d*\.?\d+\z/
            tokens << { type: :number, value: word.to_f }
          else
            tokens << { type: :operator, value: word }
          end
          i = j
        end

        tokens
      end

      # ---------------------------------------------------------------
      # Execute operators
      # ---------------------------------------------------------------
      def execute_operators(tokens)
        operand_stack = []

        tokens.each do |token|
          if token[:type] == :operator
            op = token[:value]
            handle_operator(op, operand_stack)
            operand_stack.clear
          else
            operand_stack << token
          end
        end
      end

      def handle_operator(op, operands)
        nums = operands.select { |t| t[:type] == :number }.map { |t| t[:value] }

        case op

        # --- Graphics state ---
        when 'q'
          save_graphics_state

        when 'Q'
          restore_graphics_state

        when 'cm'
          if nums.length >= 6
            concat_matrix(nums[0], nums[1], nums[2], nums[3], nums[4], nums[5])
          end

        when 'w'
          @line_width = nums[0] || 1.0

        when 'J'
          @line_cap = (nums[0] || 0).to_i

        when 'j'
          @line_join = (nums[0] || 0).to_i

        when 'd'
          # Dash pattern: array phase
          arr_token = operands.find { |t| t[:type] == :array }
          phase = nums.last || 0
          if arr_token
            dash_nums = arr_token[:value].to_s.gsub(/[\[\]]/, '').strip.split(/\s+/).map(&:to_f)
            @dash_pattern = [dash_nums, phase]
          end

        # --- Color operators ---
        when 'G'  # Stroke gray
          @stroke_color = nums_to_rgb(nums, '/DeviceGray')
          @color_space_stroke = '/DeviceGray'

        when 'g'  # Fill gray
          @fill_color = nums_to_rgb(nums, '/DeviceGray')
          @color_space_fill = '/DeviceGray'

        when 'RG' # Stroke RGB
          if nums.length >= 3
            @stroke_color = nums_to_rgb(nums, '/DeviceRGB')
            @color_space_stroke = '/DeviceRGB'
          end

        when 'rg' # Fill RGB
          if nums.length >= 3
            @fill_color = nums_to_rgb(nums, '/DeviceRGB')
            @color_space_fill = '/DeviceRGB'
          end

        when 'K'  # Stroke CMYK
          if nums.length >= 4
            @stroke_color = cmyk_to_rgb(nums[0], nums[1], nums[2], nums[3])
            @color_space_stroke = '/DeviceCMYK'
          end

        when 'k'  # Fill CMYK
          if nums.length >= 4
            @fill_color = cmyk_to_rgb(nums[0], nums[1], nums[2], nums[3])
            @color_space_fill = '/DeviceCMYK'
          end

        when 'CS' # Stroke color space
          name_token = operands.find { |t| t[:type] == :name }
          @color_space_stroke = name_token[:value] if name_token

        when 'cs' # Fill color space
          name_token = operands.find { |t| t[:type] == :name }
          @color_space_fill = name_token[:value] if name_token

        when 'SC', 'SCN' # Stroke color (general)
          # Pattern-only SCN may provide no numeric components.
          @stroke_color = nums_to_rgb(nums, @color_space_stroke) unless nums.empty?

        when 'sc', 'scn' # Fill color (general)
          # Pattern-only scn may provide no numeric components.
          @fill_color = nums_to_rgb(nums, @color_space_fill) unless nums.empty?

        # --- Path construction ---
        when 'm'  # moveto
          if nums.length >= 2
            finish_subpath
            @current_point = [nums[0], nums[1]]
            @current_segments = [Segment.new(:move, [[nums[0], nums[1]]])]
          end

        when 'l'  # lineto
          if nums.length >= 2 && @current_point
            @current_segments << Segment.new(:line, [@current_point.dup, [nums[0], nums[1]]])
            @current_point = [nums[0], nums[1]]
          end

        when 'c'  # curveto (cubic Bezier)
          if nums.length >= 6 && @current_point
            @current_segments << Segment.new(:curve, [
              @current_point.dup,
              [nums[0], nums[1]],
              [nums[2], nums[3]],
              [nums[4], nums[5]]
            ])
            @current_point = [nums[4], nums[5]]
          end

        when 'v'  # curveto (initial point = current)
          if nums.length >= 4 && @current_point
            @current_segments << Segment.new(:curve, [
              @current_point.dup,
              @current_point.dup,
              [nums[0], nums[1]],
              [nums[2], nums[3]]
            ])
            @current_point = [nums[2], nums[3]]
          end

        when 'y'  # curveto (final point = control 2)
          if nums.length >= 4 && @current_point
            @current_segments << Segment.new(:curve, [
              @current_point.dup,
              [nums[0], nums[1]],
              [nums[2], nums[3]],
              [nums[2], nums[3]]
            ])
            @current_point = [nums[2], nums[3]]
          end

        when 'h'  # closepath
          if @current_segments.length > 0
            # Close back to the first moveto point
            first_seg = @current_segments.find { |s| s.type == :move }
            if first_seg && @current_point
              start_pt = first_seg.points[0]
              unless close_enough?(@current_point, start_pt)
                @current_segments << Segment.new(:line, [@current_point.dup, start_pt.dup])
              end
              @current_point = start_pt.dup
            end
            finish_subpath(true)
          end

        when 're' # rectangle
          if nums.length >= 4
            x, y, w, h = nums[0], nums[1], nums[2], nums[3]
            finish_subpath
            @current_segments = [
              Segment.new(:move, [[x, y]]),
              Segment.new(:line, [[x, y], [x + w, y]]),
              Segment.new(:line, [[x + w, y], [x + w, y + h]]),
              Segment.new(:line, [[x + w, y + h], [x, y + h]]),
              Segment.new(:line, [[x, y + h], [x, y]])
            ]
            @current_point = [x, y]
            finish_subpath(true)
          end

        # --- Path painting ---
        when 'S'   # Stroke
          finish_subpath
          emit_path(true, false)

        when 's'   # Close and stroke
          close_current_subpath
          finish_subpath(true)
          emit_path(true, false)

        when 'f', 'F' # Fill (nonzero winding / old-style)
          finish_subpath
          emit_path(false, true)

        when 'f*'  # Fill (even-odd)
          finish_subpath
          emit_path(false, true)

        when 'B'   # Fill and stroke
          finish_subpath
          emit_path(true, true)

        when 'B*'  # Fill (even-odd) and stroke
          finish_subpath
          emit_path(true, true)

        when 'b'   # Close, fill and stroke
          close_current_subpath
          finish_subpath(true)
          emit_path(true, true)

        when 'b*'  # Close, fill (even-odd) and stroke
          close_current_subpath
          finish_subpath(true)
          emit_path(true, true)

        when 'n'   # End path without painting (clipping boundary)
          finish_subpath
          clear_path

        # --- Text (we skip text content but track state) ---
        when 'BT', 'ET', 'Tf', 'Td', 'TD', 'Tm', 'T*',
             'Tj', 'TJ', "'", '"', 'Tc', 'Tw', 'Tz', 'TL', 'Tr', 'Ts'
          # Text operators — skip for vector import

        # --- Inline image (skip) ---
        when 'BI'
          # Skip — handled by tokenizer advancing past ID...EI

        # --- XObject / Form XObject (Do) ---
        when 'Do'
          # We could recurse into Form XObjects here for maximum accuracy
          # For now, skip

        # --- Marked content (OCG layer tracking) ---
        when 'BDC'
          # BDC takes two operands: tag and properties
          # For OCG: /OC /MC0 BDC
          if operands.length >= 2
            # Operands may be token hashes {type:, value:} or plain strings
            raw_tag = operands[-2]
            raw_props = operands[-1]
            tag = raw_tag.is_a?(Hash) ? raw_tag[:value].to_s : raw_tag.to_s
            props_name = raw_props.is_a?(Hash) ? raw_props[:value].to_s.sub(/\A\//, '') : raw_props.to_s.sub(/\A\//, '')
            if tag == '/OC' && @ocg_map.key?(props_name)
              @mc_layer_stack.push(@current_ocg_layer)
              @current_ocg_layer = @ocg_map[props_name]
            else
              @mc_layer_stack.push(@current_ocg_layer)
            end
          else
            @mc_layer_stack.push(@current_ocg_layer)
          end

        when 'BMC'
          @mc_layer_stack.push(@current_ocg_layer)

        when 'EMC'
          @current_ocg_layer = @mc_layer_stack.pop

        when 'MP', 'DP'
          # Marked point — no nesting, ignore

        else
          # Unknown operator — ignore silently
        end
      end

      # ---------------------------------------------------------------
      # Path management
      # ---------------------------------------------------------------
      def finish_subpath(closed = false)
        if @current_segments && @current_segments.length > 0
          sp = SubPath.new(@current_segments, closed)
          @current_subpaths << sp
        end
        @current_segments = []
      end

      def close_current_subpath
        if @current_segments.length > 0
          first_seg = @current_segments.find { |s| s.type == :move }
          if first_seg && @current_point
            start_pt = first_seg.points[0]
            unless close_enough?(@current_point, start_pt)
              @current_segments << Segment.new(:line, [@current_point.dup, start_pt.dup])
            end
            @current_point = start_pt.dup
          end
        end
      end

      def emit_path(stroke, fill)
        return if @current_subpaths.empty?

        # Transform all points by current CTM
        transformed_subpaths = @current_subpaths.map do |sp|
          new_segments = sp.segments.map do |seg|
            new_points = seg.points.map { |pt| transform_point(pt[0], pt[1]) }
            Segment.new(seg.type, new_points)
          end
          SubPath.new(new_segments, sp.closed)
        end

        path = VectorPath.new(
          transformed_subpaths,
          stroke,
          fill,
          @stroke_color.dup,
          @fill_color.dup,
          @line_width,
          @line_cap,
          @line_join,
          @dash_pattern ? @dash_pattern.dup : nil,
          @ctm.dup,
          @current_ocg_layer
        )

        @paths << path
        clear_path
      end

      def clear_path
        @current_subpaths = []
        @current_segments = []
        # PDF spec: after painting or ending a path, the current point is undefined.
        # Leaving this set can cause a subsequent 'l' operator to connect to stale geometry.
        @current_point = nil
      end

      # ---------------------------------------------------------------
      # Color helpers
      # ---------------------------------------------------------------
      def clamp01(v)
        n = begin
          Float(v)
        rescue StandardError
          0.0
        end
        n = 0.0 if n.nan? || n.infinite?
        [[n, 0.0].max, 1.0].min
      end

      def clamp_rgb(rgb)
        arr = rgb.is_a?(Array) ? rgb : []
        [
          clamp01(arr[0] || 0.0),
          clamp01(arr[1] || arr[0] || 0.0),
          clamp01(arr[2] || arr[1] || arr[0] || 0.0)
        ]
      end

      def cmyk_to_rgb(c, m, y, k)
        c = clamp01(c)
        m = clamp01(m)
        y = clamp01(y)
        k = clamp01(k)
        r = (1.0 - c) * (1.0 - k)
        g = (1.0 - m) * (1.0 - k)
        b = (1.0 - y) * (1.0 - k)
        clamp_rgb([r, g, b])
      end

      def nums_to_rgb(nums, color_space)
        safe = (nums || []).map do |n|
          begin
            Float(n)
          rescue StandardError
            0.0
          end
        end

        case color_space
        when '/DeviceGray'
          v = clamp01(safe[0] || 0.0)
          [v, v, v]
        when '/DeviceRGB'
          clamp_rgb([safe[0] || 0.0, safe[1] || 0.0, safe[2] || 0.0])
        when '/DeviceCMYK'
          cmyk_to_rgb(safe[0] || 0.0, safe[1] || 0.0, safe[2] || 0.0, safe[3] || 0.0)
        else
          # Unknown color space — best-effort fallback:
          # - 4 channels are commonly CMYK-like (ICCBased/Separation wrappers)
          # - otherwise use first 3 channels as RGB, or replicate gray.
          if safe.length >= 4
            cmyk_to_rgb(safe[0], safe[1], safe[2], safe[3])
          elsif safe.length >= 3
            clamp_rgb([safe[0], safe[1], safe[2]])
          elsif safe.length >= 1
            v = clamp01(safe[0])
            [v, v, v]
          else
            [0, 0, 0]
          end
        end
      end

      def close_enough?(pt1, pt2, tolerance = 0.001)
        (pt1[0] - pt2[0]).abs < tolerance && (pt1[1] - pt2[1]).abs < tolerance
      end

    end
  end
end
