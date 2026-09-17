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
      attr_reader :nonpath_paint_orders, :other_paint_orders
      OTHER_PAINT_OPERATORS = { 'Do' => true, 'sh' => true, 'Tj' => true,
                                'TJ' => true, "'" => true, '"' => true }.freeze

      # Fast character-class lookup tables used by the hot-path tokenizer.
      # Matches prior /[\s\x00]/ and /[\s\[\]<>(){}\/\%]/ classes exactly
      # (Ruby \s = space, tab, LF, VT, FF, CR) so the token stream is unchanged.
      WHITESPACE_CHARS = "\x00\t\n\v\f\r ".freeze
      # Delimiter set intentionally omits NUL — old regex did too; NUL is only
      # skipped via the whitespace check above.
      DELIMITER_CHARS = "\t\n\v\f\r []<>(){}/%".freeze

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
        :layer_name,     # String — OCG layer name, or nil
        :clip_fill_rule  # Exact covered clip contour: :nonzero / :evenodd
      )
      VectorPath.class_eval do
        attr_accessor :source_paint_order, :source_fill_opacity,
                      :source_stroke_opacity, :source_clip_clear,
                      :source_miter_limit, :source_stroke_style_proven
      end

      SubPath = Struct.new(
        :segments,     # Array of Segment
        :closed        # Boolean — was 'h' (closepath) used?
      )

      Segment = Struct.new(
        :type,     # :move, :line, :curve, :rect
        :points    # Array of [x, y] in PDF user space
      )

      # ---------------------------------------------------------------
      # Streaming operator scan (XObject placement / image discovery)
      # ---------------------------------------------------------------
      # Byte classes for the getbyte-based scanner below: the same sets as
      # WHITESPACE_CHARS / DELIMITER_CHARS, indexed by byte value.
      SCAN_WHITESPACE = Array.new(256, false)
      WHITESPACE_CHARS.each_byte { |byte| SCAN_WHITESPACE[byte] = true }
      SCAN_DELIMITER = Array.new(256, false)
      DELIMITER_CHARS.each_byte { |byte| SCAN_DELIMITER[byte] = true }
      SCAN_OPERAND_WINDOW = 32
      SCAN_NUMBER_WORD = /\A[+-]?\d*\.?\d+\z/

      # Walk a content stream operator by operator WITHOUT materialising a
      # token array. The Form XObject placement tracker and the embedded
      # image extractor only need q / Q / cm / Do (and BI for inline-image
      # counting); they used to tokenize the whole stream into hashes under
      # a 500,000-token cap, so on a dense sheet (S-505: 934k tokens, the
      # only image `Do` at 86 % of the stream) every placement after the cap
      # was silently dropped. This walk keeps at most SCAN_OPERAND_WINDOW
      # operands, so it needs no cap and covers the stream end to end.
      #
      # Yields [operator, operands] for each operator named in `wanted`
      # (an Array or Hash of operator strings). `operands` holds the Float
      # numbers and "/Name" strings seen since the previous operator;
      # literal strings, hex strings, dictionaries and arrays are skipped,
      # exactly as the token scanners this replaces did. Inline image bodies
      # (BI ... ID ... EI) are skipped; when 'BI' is wanted it is yielded
      # with empty operands so callers can count inline images. Returns the
      # number of operators yielded.
      def self.scan_operators(stream, wanted)
        return 0 unless stream.is_a?(String) && block_given?
        wanted_map = wanted
        unless wanted.is_a?(Hash)
          wanted_map = {}
          Array(wanted).each { |op| wanted_map[op.to_s] = true }
        end
        bin = stream
        unless bin.encoding == Encoding::BINARY
          bin = stream.dup.force_encoding(Encoding::BINARY)
        end
        whitespace = SCAN_WHITESPACE
        delimiter = SCAN_DELIMITER
        operands = []
        yielded = 0
        i = 0
        len = bin.bytesize
        while i < len
          b = bin.getbyte(i)
          if whitespace[b]
            i += 1
            next
          end

          case b
          when 37 # '%' comment to end of line
            j = i + 1
            while j < len
              nb = bin.getbyte(j)
              break if nb == 13 || nb == 10
              j += 1
            end
            i = j
            next
          when 40 # '(' literal string operand (skipped)
            depth = 1
            j = i + 1
            while j < len && depth > 0
              nb = bin.getbyte(j)
              if nb == 92 # backslash escape
                j += 2
                next
              end
              depth += 1 if nb == 40
              depth -= 1 if nb == 41
              j += 1
            end
            i = j
            next
          when 60 # '<' hex string or '<<' dictionary (skipped)
            if i + 1 < len && bin.getbyte(i + 1) == 60
              depth = 1
              j = i + 2
              while j < len - 1 && depth > 0
                nb = bin.getbyte(j)
                if nb == 60 && bin.getbyte(j + 1) == 60
                  depth += 1
                  j += 2
                elsif nb == 62 && bin.getbyte(j + 1) == 62
                  depth -= 1
                  j += 2
                else
                  j += 1
                end
              end
              i = j
            else
              j = bin.index('>', i) || len
              i = j + 1
            end
            next
          when 62 # '>' -- a stray '>>' after a dictionary, or a lone '>'
            i += (i + 1 < len && bin.getbyte(i + 1) == 62) ? 2 : 1
            next
          when 91 # '[' array operand (skipped)
            depth = 1
            j = i + 1
            while j < len && depth > 0
              nb = bin.getbyte(j)
              depth += 1 if nb == 91
              depth -= 1 if nb == 93
              j += 1
            end
            i = j
            next
          when 93 # ']'
            i += 1
            next
          when 47 # '/' name operand
            j = i + 1
            j += 1 while j < len && !delimiter[bin.getbyte(j)]
            operands.shift if operands.length >= SCAN_OPERAND_WINDOW
            operands << bin.byteslice(i, j - i)
            i = j
            next
          end

          # Number or operator keyword
          j = i
          j += 1 while j < len && !delimiter[bin.getbyte(j)]
          if j == i
            i += 1
            next
          end
          word = bin.byteslice(i, j - i)
          i = j

          if word == 'BI'
            # Inline image data can contain arbitrary bytes: skip to EI.
            id_pos = bin.index(/\sID[\s\n\r]/, i)
            if id_pos
              ei_pos = bin.index(/[\s\n\r]EI(?=[\s\n\r\/\[<])/, id_pos + 3)
              i = ei_pos ? ei_pos + 3 : len
            end
            if wanted_map['BI']
              yield 'BI', []
              yielded += 1
            end
            next
          end

          if word =~ SCAN_NUMBER_WORD
            operands.shift if operands.length >= SCAN_OPERAND_WINDOW
            operands << word.to_f
          elsif wanted_map[word]
            yield word, operands
            yielded += 1
            operands = []
          else
            operands.clear
          end
        end
        yielded
      end

      # Inline Form expansion removes resource-scope markers. A resource name
      # is usable for opacity evidence only when every actual scoped invocation
      # has the same relevant effect. Conflicting/missing resources stay unknown.
      # Omitted ca/CA/BM/SMask entries preserve the current graphics state.
      def self.page_fill_opacity_effects(parser, page_number)
        page_ref = parser.pages.fetch(page_number.to_i - 1)
        page_dict = parser.send(:to_dict, parser.resolve_object(page_ref))
        resources = parser.send(:find_inherited, page_dict, '/Resources')
        resources = parser.send(:to_dict, parser.resolve_object(resources)) || {}
        streams = parser.send(:collect_content_streams, page_dict['/Contents'])
        effects = {}
        visit = lambda do |raw_streams, scope, depth|
          raise 'Form resource proof exceeds expansion depth' if depth > 6
          states = parser.send(:to_dict, parser.resolve_object(scope['/ExtGState'])) || {}
          xobjects = parser.send(:to_dict, parser.resolve_object(scope['/XObject'])) || {}
          Array(raw_streams).each do |stream|
            scan_operators(stream, ['gs', 'Do']) do |operator, operands|
              name = operands.reverse.find { |value| value.is_a?(String) && value.start_with?('/') }
              if operator == 'gs'
                dictionary = parser.send(:to_dict, parser.resolve_object(states[name]))
                effect = fill_opacity_effect(dictionary, parser)
                effects[name] = effect unless effects.key?(name)
                effects[name] = nil unless effects[name] == effect
              elsif name && xobjects[name]
                reference = xobjects[name]
                form = parser.send(:to_dict, parser.resolve_object(reference))
                next unless form && form['/Subtype'] == '/Form'
                raise 'unresolved Form stream' unless reference.is_a?(String) && reference =~ /\A(\d+)\s+\d+\s+R\z/
                body = parser.get_stream_data(Regexp.last_match(1).to_i)
                raise 'missing Form stream' unless body.is_a?(String)
                nested = form.key?('/Resources') ?
                  parser.send(:to_dict, parser.resolve_object(form['/Resources'])) : scope
                raise 'unresolved Form resources' unless nested.is_a?(Hash)
                visit.call([body], nested, depth + 1)
              end
            end
          end
        end
        visit.call(streams, resources, 0)
        effects
      rescue StandardError
        # This proof is optional; rendering is unchanged and every gs becomes
        # unknown if its resource provenance cannot be established completely.
        {}
      end

      def self.fill_opacity_effect(dictionary, parser)
        return nil unless dictionary.is_a?(Hash)
        alphas = {}
        ['/ca', '/CA'].each do |key|
          alphas[key] = :preserve
          next unless dictionary.key?(key)
          raw = parser.resolve_object(dictionary[key])
          return nil unless raw.is_a?(Numeric) ||
                            (raw.is_a?(String) && raw =~ /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/)
          value = raw.to_f
          return nil unless value.finite? && value >= 0.0 && value <= 1.0
          alphas[key] = value
        end
        mask = :preserve
        mask = parser.resolve_object(dictionary['/SMask']) == '/None' if dictionary.key?('/SMask')
        blend = :preserve
        if dictionary.key?('/BM')
          raw = parser.resolve_object(dictionary['/BM'])
          blend = raw == '/Normal' || raw == '/Compatible'
        end
        # Ordinary rendering does not resolve these ExtGState stroke settings.
        # Mark the optional late-overlay proof unsafe instead of guessing them.
        style = ['/LW', '/LC', '/LJ', '/ML', '/D'].any? { |key| dictionary.key?(key) } ? false : :preserve
        { :alpha => alphas['/ca'], :stroke_alpha => alphas['/CA'],
          :mask_clear => mask, :blend_normal => blend, :stroke_style_proven => style }
      end

      def initialize(streams, pdf_parser, ocg_map = {}, opacity_effects = {})
        @streams = streams       # Array of decoded stream strings
        @pdf_parser = pdf_parser
        @ocg_map = ocg_map       # { "MC0" => "Layer Name", ... }
        @opacity_effects = opacity_effects.is_a?(Hash) ? opacity_effects : {}
        @paths = []
      end

      # ---------------------------------------------------------------
      # Parse all streams and return array of VectorPath
      # ---------------------------------------------------------------
      def parse
        @paths = []
        @nonpath_paint_orders = []
        @other_paint_orders = []

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

        @streams.each_with_index do |stream, stream_index|
          next unless stream && !stream.empty?
          @source_stream_index = stream_index
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
        # Evidence for planar white-mask composition only. The renderer's
        # existing material behavior is unchanged. PDF's initial nonstroking
        # alpha is 1; an unresolved ExtGState makes that evidence unknown.
        @fill_opacity = 1.0
        @stroke_opacity = 1.0
        @stroke_style_proven = true
        @fill_mask_clear = true
        @fill_blend_normal = true
        @line_width = 1.0
        @line_cap = 0
        @line_join = 0
        @miter_limit = 10.0
        @dash_pattern = nil
        @color_space_stroke = '/DeviceGray'
        @color_space_fill = '/DeviceGray'
        @clip_regions = []
        @pending_clip_rule = nil
        @text_render_mode = 0
        @text_clip_active = false
        @text_clip_pending = false
      end

      def save_graphics_state
        @gs_stack.push({
          ctm: @ctm.dup,
          stroke_color: @stroke_color.dup,
          fill_color: @fill_color.dup,
          fill_opacity: @fill_opacity,
          stroke_opacity: @stroke_opacity,
          stroke_style_proven: @stroke_style_proven,
          fill_mask_clear: @fill_mask_clear,
          fill_blend_normal: @fill_blend_normal,
          line_width: @line_width,
          line_cap: @line_cap,
          line_join: @line_join,
          miter_limit: @miter_limit,
          dash_pattern: @dash_pattern,
          color_space_stroke: @color_space_stroke,
          color_space_fill: @color_space_fill,
          clip_regions: @clip_regions.dup,
          text_render_mode: @text_render_mode,
          text_clip_active: @text_clip_active,
          text_clip_pending: @text_clip_pending
        })
      end

      def restore_graphics_state
        gs = @gs_stack.pop
        return unless gs
        @ctm = gs[:ctm]
        @stroke_color = gs[:stroke_color]
        @fill_color = gs[:fill_color]
        @fill_opacity = gs[:fill_opacity]
        @stroke_opacity = gs[:stroke_opacity]
        @stroke_style_proven = gs[:stroke_style_proven]
        @fill_mask_clear = gs[:fill_mask_clear]
        @fill_blend_normal = gs[:fill_blend_normal]
        @line_width = gs[:line_width]
        @line_cap = gs[:line_cap]
        @line_join = gs[:line_join]
        @miter_limit = gs[:miter_limit]
        @dash_pattern = gs[:dash_pattern]
        @color_space_stroke = gs[:color_space_stroke]
        @color_space_fill = gs[:color_space_fill]
        @clip_regions = gs[:clip_regions]
        @text_render_mode = gs[:text_render_mode]
        @text_clip_active = gs[:text_clip_active]
        @text_clip_pending = gs[:text_clip_pending]
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
      # Fast manual numeric-literal check matching /\A[+-]?\d*\.?\d+\z/.
      # Trailing-dot forms like "5." are operators, not numbers.
      def numeric_literal?(word)
        return false if word.nil? || word.empty?
        last = word[-1]
        return false if last < '0' || last > '9'
        i = 0
        len = word.length
        i += 1 if word[i] == '+' || word[i] == '-'
        while i < len && word[i] >= '0' && word[i] <= '9'
          i += 1
        end
        if i < len && word[i] == '.'
          i += 1
          return false if i >= len || word[i] < '0' || word[i] > '9'
          while i < len && word[i] >= '0' && word[i] <= '9'
            i += 1
          end
        end
        i == len
      end

      # PDF inline image: BI ... ID <binary> EI
      # Boundary helpers mirror the prior regex markers:
      #   /\sID[\s\n\r]/ and /[\s\n\r]EI(?=[\s\n\r\/\[<])/
      # Ruby \s does not include NUL; keep the same set so binary scans stay equivalent.
      def inline_image_whitespace?(ch)
        ch == ' ' || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\v" || ch == "\f"
      end

      def inline_image_id_marker(stream, start)
        len = stream.length
        return nil if start + 3 > len
        i = start
        while i <= len - 3
          if stream[i] == 'I' && stream[i + 1] == 'D' &&
             i > 0 && inline_image_whitespace?(stream[i - 1]) &&
             inline_image_whitespace?(stream[i + 2])
            return i - 1  # leading whitespace, matching old regex match start
          end
          i += 1
        end
        nil
      end

      def inline_image_ei_marker(stream, start)
        len = stream.length
        return nil if start + 3 > len
        i = start
        while i <= len - 3
          if stream[i] == 'E' && stream[i + 1] == 'I'
            if i > 0 && inline_image_whitespace?(stream[i - 1])
              nxt = (i + 2 < len) ? stream[i + 2] : nil
              if inline_image_whitespace?(nxt) || nxt == '/' || nxt == '[' || nxt == '<'
                # Return leading whitespace so caller +3 lands on the next token
                # (including '/' of "/Name"), matching old regex match start.
                return i - 1
              end
            end
          end
          i += 1
        end
        nil
      end

      def tokenize_content_stream(stream)
        tokens = []
        i = 0
        len = stream.length

        while i < len
          if tokens.length > MAX_TOKENS_PER_STREAM
            @nonpath_paint_orders << nil if @nonpath_paint_orders
            @other_paint_orders << nil if @other_paint_orders
            Logger.warn("ContentParser", "Token limit reached (#{MAX_TOKENS_PER_STREAM}) — truncating stream parse")
            break
          end

          c = stream[i]

          # Whitespace (PDF spec: null 0x00, tab, LF, FF, CR, space)
          if WHITESPACE_CHARS.include?(c)
            i += 1
            next
          end

          # Comment
          if c == '%'
            j = i + 1
            while j < len && c != "\r" && c != "\n"
              c = stream[j]
              j += 1
            end
            i = j
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
            while j < len && !DELIMITER_CHARS.include?(stream[j])
              j += 1
            end
            tokens << { type: :name, value: stream[i...j] }
            i = j
            next
          end

          # Number or keyword
          j = i
          while j < len && !DELIMITER_CHARS.include?(stream[j])
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
            @nonpath_paint_orders << [@source_stream_index, i] if @nonpath_paint_orders
            @other_paint_orders << [@source_stream_index, i] if @other_paint_orders
            # Find 'ID' marker (signals start of binary image data)
            id_pos = inline_image_id_marker(stream, j)
            if id_pos
              # Find 'EI' marker after the binary data.
              # EI must be preceded by whitespace to avoid false matches
              # inside the binary data.
              ei_pos = inline_image_ei_marker(stream, id_pos + 3)
              if ei_pos
                i = ei_pos + 3  # skip past 'EI'
              else
                @nonpath_paint_orders << nil if @nonpath_paint_orders
                @other_paint_orders << nil if @other_paint_orders
                i = len  # malformed — skip to end
              end
            else
              @nonpath_paint_orders << nil if @nonpath_paint_orders
              @other_paint_orders << nil if @other_paint_orders
              i = j  # no ID found — just skip the BI token
            end
            next
          end

          if numeric_literal?(word)
            tokens << { type: :number, value: word.to_f }
          else
            if @nonpath_paint_orders && (word == 'Do' || word == 'sh')
              @nonpath_paint_orders << [@source_stream_index, i]
            end
            if @other_paint_orders && OTHER_PAINT_OPERATORS[word]
              @other_paint_orders << [@source_stream_index, i]
            end
            tokens << { type: :operator, value: word, source_offset: i }
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
            @source_paint_order = [@source_stream_index, token[:source_offset]]
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

        when 'gs'
          # Expanded Form streams can shadow page ExtGState resource names.
          # Use only the resolver's proven equivalent resource-scope effects;
          # never infer opaque paint from an unresolved name or from RGB alone.
          # q/Q still restores the exact previously known/unknown evidence.
          name = operands.reverse.find { |token| token[:type] == :name }
          effect = name && @opacity_effects[name[:value]]
          if effect.is_a?(Hash)
            @fill_opacity = effect[:alpha] unless effect[:alpha] == :preserve
            if effect.key?(:stroke_alpha) && effect[:stroke_alpha] != :preserve
              @stroke_opacity = effect[:stroke_alpha]
            end
            if effect.key?(:stroke_style_proven) && effect[:stroke_style_proven] != :preserve
              @stroke_style_proven = effect[:stroke_style_proven]
            end
            @fill_mask_clear = effect[:mask_clear] unless effect[:mask_clear] == :preserve
            @fill_blend_normal = effect[:blend_normal] unless effect[:blend_normal] == :preserve
          else
            @fill_opacity = nil
            @stroke_opacity = nil
            @stroke_style_proven = false
            @fill_mask_clear = nil
            @fill_blend_normal = nil
          end

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

        when 'M'
          @miter_limit = nums[0]

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

        when 'W', 'W*'
          @pending_clip_rule = op == 'W*' ? :evenodd : :nonzero

        when 'n'   # End path without painting (clipping boundary)
          finish_subpath
          apply_pending_clip!
          clear_path

        # Text-clipping evidence only; native text rendering stays elsewhere.
        # PDF accumulates clipping glyphs until ET, then intersects the clip.
        when 'BT'
          @text_clip_pending = false
        when 'ET'
          @text_clip_active ||= @text_clip_pending
          @text_clip_pending = false
        when 'Tr'
          value = nums[0]
          @text_render_mode = value && value >= 0 && value <= 7 && value == value.to_i ? value.to_i : nil
        when 'Tj', 'TJ', "'", '"'
          @text_clip_pending = true if @text_render_mode.nil? || @text_render_mode >= 4
        when 'Tf', 'Td', 'TD', 'Tm', 'T*', 'Tc', 'Tw', 'Tz', 'TL', 'Ts'
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
        transformed_subpaths = transformed_current_subpaths
        clip_fill_rule = nil
        if fill && !stroke
          resolved = covered_clip_fill(transformed_subpaths)
          if resolved
            transformed_subpaths, clip_fill_rule = resolved
          end
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
          @current_ocg_layer,
          clip_fill_rule
        )

        @paths << path
        path.source_paint_order = @source_paint_order.dup
        path.source_fill_opacity =
          (@fill_mask_clear == true && @fill_blend_normal == true) ? @fill_opacity : nil
        path.source_stroke_opacity =
          (@fill_mask_clear == true && @fill_blend_normal == true) ? @stroke_opacity : nil
        path.source_clip_clear = @clip_regions.empty? && !@text_clip_active && !@text_clip_pending
        path.source_miter_limit = @miter_limit
        path.source_stroke_style_proven = @stroke_style_proven
        apply_pending_clip!
        clear_path
      end

      def transformed_current_subpaths
        @current_subpaths.map do |sp|
          new_segments = sp.segments.map do |seg|
            new_points = seg.points.map { |pt| transform_point(pt[0], pt[1]) }
            Segment.new(seg.type, new_points)
          end
          SubPath.new(new_segments, sp.closed)
        end
      end

      def apply_pending_clip!
        return unless @pending_clip_rule
        paths = transformed_current_subpaths.map { |sp| SubPath.new(sp.segments, true) }
        @clip_regions << { :paths => paths, :rule => @pending_clip_rule }
        @pending_clip_rule = nil
      end

      def contour_bounds(paths)
        points = Array(paths).flat_map { |sp| sp.segments.flat_map(&:points) }
        return nil if points.empty?
        xs = points.map { |pt| pt[0] }
        ys = points.map { |pt| pt[1] }
        [xs.min, ys.min, xs.max, ys.max]
      end

      def rectangle_bounds(paths)
        return nil unless paths.length == 1
        segments = paths[0].segments
        return nil unless segments.all? { |seg| [:move, :line].include?(seg.type) }
        points = segments.flat_map(&:points).uniq
        return nil unless points.length == 4
        box = contour_bounds(paths)
        return nil unless points.all? do |pt|
          [box[0], box[2]].include?(pt[0]) && [box[1], box[3]].include?(pt[1])
        end
        return nil unless segments.select { |seg| seg.type == :line }.all? do |seg|
          seg.points[0][0] == seg.points[1][0] || seg.points[0][1] == seg.points[1][1]
        end
        box
      end

      def box_covers?(outer, inner)
        outer && inner && outer[0] <= inner[0] && outer[1] <= inner[1] &&
          outer[2] >= inner[2] && outer[3] >= inner[3]
      end

      # A covering fill paints the exact clip. If only rectangular boundaries
      # trim a linear clip, intersect its actual segments with those boundaries;
      # do not expand a nearly covering paint rectangle and lose source detail.
      # Curves retain the proved-containment route without approximation.
      def covered_clip_fill(paint_paths)
        paint_box = rectangle_bounds(paint_paths)
        return nil unless paint_box && @clip_regions && !@clip_regions.empty?
        complex = @clip_regions.reject { |clip| rectangle_bounds(clip[:paths]) }
        return nil unless complex.length == 1
        clip = complex[0]
        clip_box = contour_bounds(clip[:paths])
        covered = box_covers?(paint_box, clip_box) && @clip_regions.all? do |other|
          other.equal?(clip) || box_covers?(rectangle_bounds(other[:paths]), clip_box)
        end
        return [clip[:paths], clip[:rule]] if covered

        loops = clip[:paths].map { |subpath| linear_clip_points(subpath) }
        return nil if loops.any?(&:nil?)
        boxes = [paint_box] + @clip_regions.reject { |other| other.equal?(clip) }.map do |other|
          rectangle_bounds(other[:paths])
        end
        return nil if boxes.any?(&:nil?)
        bounds = [boxes.map { |box| box[0] }.max, boxes.map { |box| box[1] }.max,
                  boxes.map { |box| box[2] }.min, boxes.map { |box| box[3] }.min]
        return [[], clip[:rule]] unless bounds[2] > bounds[0] && bounds[3] > bounds[1]

        paths = loops.map do |points|
          clipped = clip_linear_loop_to_rectangle(points, bounds)
          next if clipped.empty?
          segments = [Segment.new(:move, [clipped[0]])]
          clipped.each_with_index do |point, index|
            following = clipped[(index + 1) % clipped.length]
            segments << Segment.new(:line, [point, following])
          end
          SubPath.new(segments, true)
        end.compact
        [paths, clip[:rule]]
      end

      def linear_clip_points(subpath)
        segments = subpath.segments
        return nil if segments.empty? || segments[0].type != :move
        return nil unless segments.drop(1).all? { |segment| segment.type == :line }
        points = [segments[0].points[0]]
        segments.drop(1).each do |segment|
          return nil unless segment.points.length == 2 && segment.points[0] == points[-1]
          points << segment.points[1] unless segment.points[1] == points[-1]
        end
        points.pop if points.length > 1 && points[-1] == points[0]
        return nil unless points.length >= 3 && points.all? do |point|
          point.length == 2 && point.all? { |value| value.is_a?(Numeric) && value.finite? }
        end
        points
      end

      # Sutherland-Hodgman clipping retains the directed contour, so even-odd
      # and nonzero compound fills keep their original winding semantics.
      def clip_linear_loop_to_rectangle(loop, bounds)
        points = loop.map(&:dup)
        [[0, bounds[0], 1], [0, bounds[2], -1],
         [1, bounds[1], 1], [1, bounds[3], -1]].each do |axis, limit, sign|
          break if points.empty?
          output = []
          previous = points[-1]
          previous_inside = sign * (previous[axis] - limit) >= 0.0
          points.each do |point|
            inside = sign * (point[axis] - limit) >= 0.0
            if inside != previous_inside
              fraction = (limit - previous[axis]).to_f / (point[axis] - previous[axis])
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
        points.uniq.length < 3 ? [] : points
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
