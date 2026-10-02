# bc_pdf_vector_importer/pdf_color_space.rb
# Colour spaces for path painting: resolves the name given to CS / cs
# through the /ColorSpace resources in force at that point of the content
# stream and converts SC / SCN / sc / scn operands to the RGB colour a PDF
# viewer shows.
#
# Why this exists: a one-component colour in a named space is not a gray
# level. "/Cs8 CS 1 SCN" with Cs8 = [/Separation /Black ...] is FULL black
# ink; reading the 1 as DeviceGray imports every stroke of the sheet white.
#
# Covered: CalGray, CalRGB, Lab, ICCBased (by /N, honouring /Alternate),
# Indexed (string or stream table), Separation and DeviceN (tint transform
# of function type 0, 2, 3 or 4 evaluated into the alternate space; the
# colorant names are the fallback when the function cannot be evaluated).
# Device spaces and Pattern are deliberately NOT handled here: the content
# stream parser keeps its existing behaviour for them.
#
# Ruby 2.2 safe (SketchUp 2017).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module PdfColorSpace
      # Returned by Space#to_rgb for a Separation / DeviceN space whose only
      # colorant is /None: painting with it leaves no mark at all.
      NO_PAINT = :no_paint

      REFERENCE = /\A(\d+)\s+(\d+)\s+R\z/
      NUMBER = /\A[+-]?(?:\d+\.?\d*|\.\d+)\z/
      MAX_DEPTH = 8

      # Finite Float for any operand; anything else counts as 0.
      def self.float(value)
        number = begin
          Float(value)
        rescue StandardError
          0.0
        end
        (number.nan? || number.infinite?) ? 0.0 : number
      end

      def self.unit(value)
        number = float(value)
        number < 0.0 ? 0.0 : (number > 1.0 ? 1.0 : number)
      end

      def self.bound(value, low, high)
        number = float(value)
        low, high = high, low if low > high
        number < low ? low : (number > high ? high : number)
      end

      # The importer's one CMYK -> RGB conversion for path colours.
      # ContentStreamParser#cmyk_to_rgb (the K / k operators) delegates here,
      # so DeviceCMYK, ICCBased N=4 and every tint transform that lands in a
      # CMYK alternate agree.
      def self.cmyk_to_rgb(cyan, magenta, yellow, black)
        c = unit(cyan)
        m = unit(magenta)
        y = unit(yellow)
        k = unit(black)
        [(1.0 - c) * (1.0 - k), (1.0 - m) * (1.0 - k), (1.0 - y) * (1.0 - k)]
      end

      # ---------------------------------------------------------------
      # PDF object access through the importer's PDFParser (anything with
      # resolve_object / get_stream_data works; nil serves direct values).
      # ---------------------------------------------------------------
      class Objects
        def initialize(parser)
          @parser = parser
        end

        def deref(value)
          current = value
          MAX_DEPTH.times do
            break unless @parser && current.is_a?(String) && current =~ REFERENCE
            current = @parser.resolve_object(current)
          end
          current
        end

        def dict(value)
          current = deref(value)
          return current if current.is_a?(Hash)
          if @parser && current.is_a?(String) && current.include?('<<')
            parsed = @parser.send(:to_dict, current)
            return parsed if parsed.is_a?(Hash)
          end
          nil
        rescue StandardError
          nil
        end

        def array(value)
          current = deref(value)
          return current if current.is_a?(Array)
          if @parser && current.is_a?(String) && current.lstrip.start_with?('[')
            parsed = @parser.send(:parse_array_string, current)
            return parsed if parsed.is_a?(Array)
          end
          nil
        rescue StandardError
          nil
        end

        def number(value)
          current = deref(value)
          return current.to_f if current.is_a?(Numeric)
          return current.to_f if current.is_a?(String) && current.strip =~ NUMBER
          nil
        end

        def numbers(value)
          list = array(value)
          return nil unless list
          result = list.map { |item| number(item) }
          result.include?(nil) ? nil : result
        end

        def name(value)
          current = deref(value)
          current.is_a?(String) && current.start_with?('/') ? current : nil
        end

        # Decoded bytes of the stream object an indirect reference names.
        def stream(value)
          return nil unless @parser && value.is_a?(String) && value =~ REFERENCE
          data = @parser.get_stream_data(Regexp.last_match(1).to_i)
          data.is_a?(String) ? data.dup.force_encoding(Encoding::BINARY) : nil
        rescue StandardError
          nil
        end

        # Bytes of a literal "(...)" or hexadecimal "<...>" string token.
        def string_bytes(value)
          current = deref(value)
          return nil unless current.is_a?(String)
          text = current.dup.force_encoding(Encoding::BINARY).strip
          if text.start_with?('(')
            literal_bytes(text)
          elsif text.start_with?('<') && !text.start_with?('<<')
            hex = text.delete('^0-9A-Fa-f')
            hex += '0' if hex.length.odd?
            [hex].pack('H*')
          end
        end

        private

        def literal_bytes(text)
          out = ''.dup.force_encoding(Encoding::BINARY)
          depth = 1
          index = 1
          length = text.bytesize
          while index < length
            byte = text.getbyte(index)
            if byte == 92 # backslash
              index += 1
              break if index >= length
              escaped = text.getbyte(index)
              if escaped >= 48 && escaped <= 55
                value = 0
                count = 0
                while count < 3 && index < length &&
                      text.getbyte(index) >= 48 && text.getbyte(index) <= 55
                  value = value * 8 + text.getbyte(index) - 48
                  index += 1
                  count += 1
                end
                out << (value & 255)
                next
              end
              case escaped
              when 110 then out << 10
              when 114 then out << 13
              when 116 then out << 9
              when 98 then out << 8
              when 102 then out << 12
              when 13 # backslash + end of line continues the string
                index += 1 if index + 1 < length && text.getbyte(index + 1) == 10
              when 10
                nil
              else
                out << escaped
              end
              index += 1
              next
            end
            if byte == 40
              depth += 1
            elsif byte == 41
              depth -= 1
              break if depth == 0
            end
            out << byte
            index += 1
          end
          out
        end
      end

      # ---------------------------------------------------------------
      # PDF functions (tint transforms)
      # ---------------------------------------------------------------
      class Function
        MAX_FUNCTION_DEPTH = 4
        MAX_SAMPLED_INPUTS = 8

        attr_reader :inputs

        # Returns an evaluator, or nil when the function is absent, of an
        # unsupported type or malformed (the caller then uses colorant names).
        def self.build(value, objects, depth = 0)
          return nil if depth > MAX_FUNCTION_DEPTH
          dict = objects.dict(value)
          return nil unless dict
          type = objects.number(dict['/FunctionType'])
          domain = objects.numbers(dict['/Domain'])
          return nil unless type && domain && domain.length >= 2 && domain.length.even?
          range = objects.numbers(dict['/Range'])
          range = nil unless range && range.length >= 2 && range.length.even?
          case type.to_i
          when 0 then SampledFunction.from(dict, domain, range, objects.stream(value), objects)
          when 2 then ExponentialFunction.from(dict, domain, range, objects)
          when 3 then StitchingFunction.from(dict, domain, range, objects, depth)
          when 4 then CalculatorFunction.from(domain, range, objects.stream(value))
          end
        rescue StandardError
          nil
        end

        def initialize(domain, range)
          @domain = domain
          @range = range
          @inputs = domain.length / 2
        end

        # Array of output numbers, or nil when evaluation fails.
        def evaluate(values)
          args = (0...@inputs).map do |index|
            PdfColorSpace.bound(values[index] || 0.0, @domain[2 * index], @domain[2 * index + 1])
          end
          out = compute(args)
          return nil unless out.is_a?(Array) && !out.empty?
          out = out.map { |value| PdfColorSpace.float(value) }
          if @range
            return nil if out.length < @range.length / 2
            out = out.first(@range.length / 2).each_with_index.map do |value, index|
              PdfColorSpace.bound(value, @range[2 * index], @range[2 * index + 1])
            end
          end
          out
        rescue StandardError
          nil
        end

        private

        def interpolate(x, x_min, x_max, y_min, y_max)
          return y_min if x_max == x_min
          y_min + (x - x_min) * (y_max - y_min) / (x_max - x_min)
        end
      end

      # Type 2: C0 + x^N * (C1 - C0)
      class ExponentialFunction < Function
        def self.from(dict, domain, range, objects)
          c0 = dict.key?('/C0') ? objects.numbers(dict['/C0']) : [0.0]
          c1 = dict.key?('/C1') ? objects.numbers(dict['/C1']) : [1.0]
          exponent = objects.number(dict['/N'])
          return nil unless c0 && c1 && exponent && !c0.empty? && c0.length == c1.length
          new(domain, range, c0, c1, exponent)
        end

        def initialize(domain, range, c0, c1, exponent)
          super(domain, range)
          @c0 = c0
          @c1 = c1
          @exponent = exponent
        end

        private

        def compute(args)
          x = args[0]
          # A negative base with a fractional exponent has no real value.
          x = 0.0 if x < 0.0 && @exponent != @exponent.floor
          power = (x == 0.0 && @exponent < 0.0) ? 0.0 : x**@exponent
          @c0.each_index.map { |index| @c0[index] + power * (@c1[index] - @c0[index]) }
        end
      end

      # Type 0: sample table with multilinear interpolation.
      class SampledFunction < Function
        def self.from(dict, domain, range, data, objects)
          return nil unless range && data
          size = objects.numbers(dict['/Size'])
          bits = objects.number(dict['/BitsPerSample'])
          inputs = domain.length / 2
          return nil unless size && bits && size.length == inputs && inputs <= MAX_SAMPLED_INPUTS
          size = size.map(&:to_i)
          bits = bits.to_i
          return nil unless size.all? { |count| count >= 1 } && [1, 2, 4, 8, 12, 16, 24, 32].include?(bits)
          outputs = range.length / 2
          total = size.inject(1) { |product, count| product * count } * outputs
          return nil if data.bytesize * 8 < total * bits
          encode = dict.key?('/Encode') ? objects.numbers(dict['/Encode']) : nil
          unless encode && encode.length == 2 * inputs
            encode = size.flat_map { |count| [0.0, (count - 1).to_f] }
          end
          decode = dict.key?('/Decode') ? objects.numbers(dict['/Decode']) : nil
          decode = range unless decode && decode.length == range.length
          new(domain, range, size, bits, encode, decode, data)
        end

        def initialize(domain, range, size, bits, encode, decode, data)
          super(domain, range)
          @size = size
          @bits = bits
          @encode = encode
          @decode = decode
          @data = data
          @outputs = range.length / 2
          @sample_max = ((1 << bits) - 1).to_f
        end

        private

        def compute(args)
          corners = [[0, 1.0]]
          stride = 1
          args.each_with_index do |x, index|
            last = @size[index] - 1
            position = interpolate(x, @domain[2 * index], @domain[2 * index + 1],
                                   @encode[2 * index], @encode[2 * index + 1])
            position = PdfColorSpace.bound(position, 0.0, last.to_f)
            lower = position.floor
            lower = last if lower > last
            upper = lower < last ? lower + 1 : lower
            fraction = position - lower
            following = []
            corners.each do |offset, weight|
              following << [offset + lower * stride, weight * (1.0 - fraction)]
              following << [offset + upper * stride, weight * fraction] if fraction > 0.0
            end
            corners = following
            stride *= @size[index]
          end
          (0...@outputs).map do |output|
            value = 0.0
            corners.each { |offset, weight| value += weight * sample(offset * @outputs + output) }
            interpolate(value, 0.0, @sample_max, @decode[2 * output], @decode[2 * output + 1])
          end
        end

        def sample(index)
          return @data.getbyte(index) if @bits == 8
          bit = index * @bits
          value = 0
          @bits.times do |step|
            position = bit + step
            byte = @data.getbyte(position >> 3) || 0
            value = (value << 1) | ((byte >> (7 - (position & 7))) & 1)
          end
          value
        end
      end

      # Type 3: one-input functions stitched over sub-domains.
      class StitchingFunction < Function
        def self.from(dict, domain, range, objects, depth)
          list = objects.array(dict['/Functions'])
          bounds = objects.numbers(dict['/Bounds']) || []
          encode = objects.numbers(dict['/Encode'])
          return nil unless list && !list.empty? && encode
          return nil unless bounds.length == list.length - 1 && encode.length == 2 * list.length
          functions = list.map { |item| Function.build(item, objects, depth + 1) }
          return nil if functions.include?(nil)
          new(domain, range, functions, bounds, encode)
        end

        def initialize(domain, range, functions, bounds, encode)
          super(domain, range)
          @functions = functions
          @bounds = bounds
          @encode = encode
        end

        private

        def compute(args)
          x = args[0]
          index = 0
          index += 1 while index < @bounds.length && x >= @bounds[index]
          low = index == 0 ? @domain[0] : @bounds[index - 1]
          high = index == @bounds.length ? @domain[1] : @bounds[index]
          encoded = interpolate(x, low, high, @encode[2 * index], @encode[2 * index + 1])
          @functions[index].evaluate([encoded])
        end
      end

      # Type 4: PostScript calculator function.
      class CalculatorFunction < Function
        OPERATORS = %w[
          abs add atan ceiling cos cvi cvr div exp floor idiv ln log mod mul neg
          round sin sqrt sub truncate and bitshift eq false ge gt le lt ne not
          or true xor if ifelse copy dup exch index pop roll
        ].each_with_object({}) { |name, table| table[name] = true }.freeze
        INTEGER_TOKEN = /\A[+-]?\d+\z/
        REAL_TOKEN = /\A[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?\z/
        MAX_STEPS = 100_000
        DEGREES = Math::PI / 180.0

        def self.from(domain, range, source)
          return nil unless range && source
          program = parse(source)
          program ? new(domain, range, program) : nil
        end

        # Nested Arrays of numbers, operator names and procedures, or nil.
        def self.parse(source)
          text = source.dup.force_encoding(Encoding::BINARY).gsub(/%[^\r\n]*/n, ' ')
          blocks = []
          text.scan(/[{}]|[^\s{}]+/n) do |token|
            if token == '{'
              blocks.push([])
            elsif token == '}'
              block = blocks.pop
              return nil unless block
              return block if blocks.empty?
              blocks[-1] << block
            else
              return nil if blocks.empty?
              if token =~ INTEGER_TOKEN
                blocks[-1] << token.to_i
              elsif token =~ REAL_TOKEN
                blocks[-1] << token.to_f
              elsif OPERATORS[token]
                blocks[-1] << token
              else
                return nil
              end
            end
          end
          nil
        end

        def initialize(domain, range, program)
          super(domain, range)
          @program = program
        end

        private

        def compute(args)
          stack = args.dup
          @steps = 0
          run(@program, stack)
          count = @range.length / 2
          return nil if stack.length < count
          result = stack.last(count)
          result.all? { |value| value.is_a?(Numeric) } ? result : nil
        end

        def run(block, stack)
          block.each do |item|
            @steps += 1
            raise 'calculator function exceeds its step budget' if @steps > MAX_STEPS
            if item.is_a?(String)
              operate(item, stack)
            else
              stack.push(item)
            end
          end
        end

        def take(stack)
          raise 'calculator stack underflow' if stack.empty?
          stack.pop
        end

        def number(stack)
          value = take(stack)
          raise 'calculator operand is not a number' unless value.is_a?(Numeric)
          value
        end

        def integer(stack)
          value = take(stack)
          raise 'calculator operand is not an integer' unless value.is_a?(Integer)
          value
        end

        def procedure(stack)
          value = take(stack)
          raise 'calculator operand is not a procedure' unless value.is_a?(Array)
          value
        end

        def real(value)
          raise 'calculator result is not a real number' unless value.is_a?(Float) || value.is_a?(Integer)
          value
        end

        def operate(name, stack)
          case name
          when 'abs' then stack.push(number(stack).abs)
          when 'add'
            b = number(stack)
            stack.push(number(stack) + b)
          when 'sub'
            b = number(stack)
            stack.push(number(stack) - b)
          when 'mul'
            b = number(stack)
            stack.push(number(stack) * b)
          when 'div'
            b = number(stack)
            a = number(stack)
            raise ZeroDivisionError, 'calculator division by zero' if b == 0
            stack.push(a.to_f / b)
          when 'idiv'
            b = integer(stack)
            a = integer(stack)
            raise ZeroDivisionError, 'calculator division by zero' if b == 0
            quotient = a.abs / b.abs
            stack.push((a < 0) == (b < 0) ? quotient : -quotient)
          when 'mod'
            b = integer(stack)
            a = integer(stack)
            raise ZeroDivisionError, 'calculator division by zero' if b == 0
            stack.push(a.remainder(b))
          when 'neg' then stack.push(-number(stack))
          when 'ceiling'
            a = number(stack)
            stack.push(a.is_a?(Integer) ? a : a.ceil.to_f)
          when 'floor'
            a = number(stack)
            stack.push(a.is_a?(Integer) ? a : a.floor.to_f)
          when 'round'
            a = number(stack)
            stack.push(a.is_a?(Integer) ? a : (a + 0.5).floor.to_f)
          when 'truncate'
            a = number(stack)
            stack.push(a.is_a?(Integer) ? a : a.truncate.to_f)
          when 'cvi' then stack.push(number(stack).truncate)
          when 'cvr' then stack.push(number(stack).to_f)
          when 'sqrt' then stack.push(Math.sqrt(number(stack)))
          when 'sin' then stack.push(Math.sin(number(stack) * DEGREES))
          when 'cos' then stack.push(Math.cos(number(stack) * DEGREES))
          when 'atan'
            denominator = number(stack)
            numerator = number(stack)
            angle = Math.atan2(numerator, denominator) / DEGREES
            stack.push(angle < 0.0 ? angle + 360.0 : angle)
          when 'exp'
            exponent = number(stack)
            stack.push(real(number(stack).to_f**exponent))
          when 'ln' then stack.push(Math.log(number(stack)))
          when 'log' then stack.push(Math.log10(number(stack)))
          when 'true' then stack.push(true)
          when 'false' then stack.push(false)
          when 'eq'
            b = take(stack)
            stack.push(take(stack) == b)
          when 'ne'
            b = take(stack)
            stack.push(take(stack) != b)
          when 'gt'
            b = number(stack)
            stack.push(number(stack) > b)
          when 'ge'
            b = number(stack)
            stack.push(number(stack) >= b)
          when 'lt'
            b = number(stack)
            stack.push(number(stack) < b)
          when 'le'
            b = number(stack)
            stack.push(number(stack) <= b)
          when 'and', 'or', 'xor'
            b = take(stack)
            a = take(stack)
            both_boolean = (a == true || a == false) && (b == true || b == false)
            unless both_boolean || (a.is_a?(Integer) && b.is_a?(Integer))
              raise 'calculator operands are neither booleans nor integers'
            end
            stack.push(name == 'and' ? (a & b) : (name == 'or' ? (a | b) : (a ^ b)))
          when 'not'
            a = take(stack)
            if a == true || a == false
              stack.push(!a)
            elsif a.is_a?(Integer)
              stack.push(~a)
            else
              raise 'calculator operand is neither boolean nor integer'
            end
          when 'bitshift'
            shift = integer(stack)
            a = integer(stack)
            stack.push(shift >= 0 ? a << shift : a >> -shift)
          when 'if'
            block = procedure(stack)
            condition = take(stack)
            run(block, stack) if condition == true
          when 'ifelse'
            otherwise = procedure(stack)
            block = procedure(stack)
            condition = take(stack)
            run(condition == true ? block : otherwise, stack)
          when 'pop' then take(stack)
          when 'dup'
            raise 'calculator stack underflow' if stack.empty?
            stack.push(stack[-1])
          when 'exch'
            b = take(stack)
            a = take(stack)
            stack.push(b)
            stack.push(a)
          when 'copy'
            count = integer(stack)
            raise 'calculator stack underflow' if count < 0 || count > stack.length
            stack.concat(stack.last(count))
          when 'index'
            depth = integer(stack)
            raise 'calculator stack underflow' if depth < 0 || depth >= stack.length
            stack.push(stack[-1 - depth])
          when 'roll'
            shift = integer(stack)
            count = integer(stack)
            raise 'calculator stack underflow' if count < 0 || count > stack.length
            if count > 0
              top = stack.pop(count)
              stack.concat(top.rotate(-(shift % count)))
            end
          else
            raise 'unsupported calculator operator ' + name
          end
        end
      end

      # ---------------------------------------------------------------
      # A resolved colour space
      # ---------------------------------------------------------------
      class Space
        attr_reader :kind, :components

        # kind: :gray, :rgb, :cmyk, :lab, :indexed or :tint
        def initialize(kind, components, options = {})
          @kind = kind
          @components = components
          @options = options
        end

        # Operands of the colour a CS / cs operator selects by itself.
        def initial
          case @kind
          when :cmyk then [0.0, 0.0, 0.0, 1.0]
          when :tint then Array.new(@components, 1.0)
          else Array.new(@components, 0.0)
          end
        end

        # [r, g, b] in 0..1, NO_PAINT, or nil when the operands cannot be
        # converted (the caller keeps its own best effort in that case).
        def to_rgb(values)
          list = values.is_a?(Array) ? values : []
          comps = (0...@components).map { |index| PdfColorSpace.float(list[index] || 0.0) }
          case @kind
          when :gray
            value = PdfColorSpace.unit(comps[0])
            [value, value, value]
          when :rgb
            comps.map { |value| PdfColorSpace.unit(value) }
          when :cmyk
            PdfColorSpace.cmyk_to_rgb(comps[0], comps[1], comps[2], comps[3])
          when :lab
            lab_to_rgb(comps)
          when :indexed
            indexed_to_rgb(comps[0])
          when :tint
            tint_to_rgb(comps)
          end
        end

        # Components of this space for one Indexed table entry (bytes / 255).
        def from_table_entry(entry)
          return entry unless @kind == :lab
          range = @options[:range]
          [entry[0] * 100.0,
           range[0] + entry[1] * (range[1] - range[0]),
           range[2] + entry[2] * (range[3] - range[2])]
        end

        private

        # L*a*b* relative to the space's own white point, shown as sRGB: the
        # white point maps to sRGB white (XYZ scaling to D65), so neutral
        # colours stay neutral whatever /WhitePoint says.
        def lab_to_rgb(comps)
          range = @options[:range]
          lightness = PdfColorSpace.bound(comps[0], 0.0, 100.0)
          a = PdfColorSpace.bound(comps[1], range[0], range[1])
          b = PdfColorSpace.bound(comps[2], range[2], range[3])
          fy = (lightness + 16.0) / 116.0
          x, y, z = [fy + a / 500.0, fy, fy - b / 200.0].map do |t|
            t >= 6.0 / 29.0 ? t * t * t : (108.0 / 841.0) * (t - 4.0 / 29.0)
          end
          x *= 0.9505
          z *= 1.0890
          [3.2406 * x - 1.5372 * y - 0.4986 * z,
           -0.9689 * x + 1.8758 * y + 0.0415 * z,
           0.0557 * x - 0.2040 * y + 1.0570 * z].map do |linear|
            value = PdfColorSpace.unit(linear)
            PdfColorSpace.unit(value <= 0.0031308 ? 12.92 * value : 1.055 * (value**(1.0 / 2.4)) - 0.055)
          end
        end

        def indexed_to_rgb(operand)
          base = @options[:base]
          table = @options[:table]
          index = operand.round
          index = 0 if index < 0
          index = @options[:hival] if index > @options[:hival]
          count = base.components
          offset = index * count
          return nil if table.bytesize < offset + count
          entry = (0...count).map { |step| table.getbyte(offset + step) / 255.0 }
          base.to_rgb(base.from_table_entry(entry))
        end

        def tint_to_rgb(comps)
          return NO_PAINT if @options[:none]
          tints = comps.map { |value| PdfColorSpace.unit(value) }
          function = @options[:function]
          alternate = @options[:alternate]
          if function && alternate
            out = function.evaluate(tints)
            if out && out.length >= alternate.components
              rgb = alternate.to_rgb(out)
              return rgb if rgb.is_a?(Array)
            end
          end
          colorant_rgb(tints)
        end

        # Tint transform unavailable: the colorant names say what the ink is.
        # Process names map to their CMYK channel; /Black, /All and every
        # spot name darken (gray 1 - t), so full tint is never white.
        def colorant_rgb(tints)
          cyan = magenta = yellow = black = 0.0
          @options[:names].each_with_index do |name, index|
            tint = tints[index] || 0.0
            case name
            when '/Cyan' then cyan += tint
            when '/Magenta' then magenta += tint
            when '/Yellow' then yellow += tint
            when '/None' then nil
            else black += tint
            end
          end
          PdfColorSpace.cmyk_to_rgb(cyan, magenta, yellow, black)
        end
      end

      GRAY = Space.new(:gray, 1)
      RGB = Space.new(:rgb, 3)
      CMYK = Space.new(:cmyk, 4)

      # ---------------------------------------------------------------
      # Name -> Space through /ColorSpace resource dictionaries
      # ---------------------------------------------------------------
      class Resolver
        # Handled by the content stream parser itself, exactly as before.
        PARSER_OWNED = { '/DeviceGray' => true, '/DeviceRGB' => true,
                         '/DeviceCMYK' => true, '/Pattern' => true }.freeze

        # Names that are defined in the resources but could not be built.
        attr_reader :unsupported

        def initialize(parser)
          @objects = Objects.new(parser)
          @cache = {}.compare_by_identity
          @unsupported = {}
        end

        # name: the CS / cs operand ("/Cs8"). chain: resource dictionaries,
        # innermost first. Returns a Space, or nil when the parser's own
        # handling applies (device and Pattern spaces, unknown names).
        def space(name, chain)
          return nil if name.nil? || PARSER_OWNED[name] || !chain.is_a?(Array)
          chain.each do |resources|
            next unless resources.is_a?(Hash)
            entries = (@cache[resources] ||= {})
            entries[name] = lookup(name, resources) unless entries.key?(name)
            found = entries[name]
            next if found == :missing
            return found.is_a?(Space) ? found : nil
          end
          nil
        end

        private

        def lookup(name, resources)
          spaces = @objects.dict(resources['/ColorSpace'])
          return :missing unless spaces && spaces.key?(name)
          built = build(spaces[name], 0)
          @unsupported[name] = true if built.nil?
          built || :unsupported
        rescue StandardError
          @unsupported[name] = true
          :unsupported
        end

        # Space, :pattern, or nil when the definition cannot be used.
        def build(value, depth)
          return nil if depth > MAX_DEPTH
          direct = @objects.deref(value)
          if direct.is_a?(String) && direct.start_with?('/')
            parts = [direct]
          else
            parts = @objects.array(direct)
          end
          return nil unless parts && !parts.empty?
          case @objects.name(parts[0])
          when '/DeviceGray', '/CalGray' then GRAY
          when '/DeviceRGB', '/CalRGB' then RGB
          when '/DeviceCMYK' then CMYK
          when '/Pattern' then :pattern
          when '/Lab' then build_lab(parts)
          when '/ICCBased' then build_icc(parts, depth)
          when '/Indexed' then build_indexed(parts, depth)
          when '/Separation' then build_tint([@objects.name(parts[1])], parts, depth)
          when '/DeviceN'
            names = (@objects.array(parts[1]) || []).map { |item| @objects.name(item) }
            build_tint(names, parts, depth)
          end
        end

        def build_lab(parts)
          dict = @objects.dict(parts[1]) || {}
          range = @objects.numbers(dict['/Range'])
          range = [-100.0, 100.0, -100.0, 100.0] unless range && range.length == 4
          Space.new(:lab, 3, :range => range)
        end

        # /Alternate is honoured when it has the profile's component count;
        # otherwise /N decides: 1 gray, 3 RGB, 4 CMYK.
        def build_icc(parts, depth)
          profile = @objects.dict(parts[1])
          return nil unless profile
          count = @objects.number(profile['/N'])
          count = count.to_i if count
          if profile.key?('/Alternate')
            alternate = build(profile['/Alternate'], depth + 1)
            if alternate.is_a?(Space) && (count.nil? || alternate.components == count)
              return alternate
            end
          end
          case count
          when 1 then GRAY
          when 3 then RGB
          when 4 then CMYK
          end
        end

        def build_indexed(parts, depth)
          base = build(parts[1], depth + 1)
          return nil unless base.is_a?(Space) && base.kind != :indexed
          hival = @objects.number(parts[2])
          table = @objects.stream(parts[3]) || @objects.string_bytes(parts[3])
          return nil unless hival && table
          hival = hival.to_i
          hival = 0 if hival < 0
          hival = 255 if hival > 255
          Space.new(:indexed, 1, :base => base, :hival => hival, :table => table)
        end

        def build_tint(names, parts, depth)
          return nil if names.empty? || names.include?(nil)
          alternate = build(parts[2], depth + 1)
          alternate = nil unless alternate.is_a?(Space)
          function = Function.build(parts[3], @objects)
          function = nil unless function && function.inputs == names.length
          Space.new(:tint, names.length,
                    :names => names, :alternate => alternate, :function => function,
                    :none => names.all? { |name| name == '/None' })
        end
      end

      # ---------------------------------------------------------------
      # Which resource dictionary is in force at a byte of a content stream
      # ---------------------------------------------------------------
      # PDFParser#page_data inlines Form XObjects into the page streams, so a
      # colour-space name inside the inlined bytes must be looked up in the
      # Form's own /Resources (falling back to the invoking scope, which is
      # also what a Form without /Resources uses). The scope travels WITH the
      # stream String (ResourceScope.attach / .of), so every caller that hands
      # page_data's streams to ContentStreamParser gets the right resources
      # without passing anything extra.
      class ResourceScope
        TAG = :@bc_pdf_resource_scope

        def self.attach(stream, scope)
          if stream.is_a?(String) && !stream.frozen?
            stream.instance_variable_set(TAG, scope)
          end
          stream
        end

        def self.of(stream)
          return nil unless stream.is_a?(String) && stream.instance_variable_defined?(TAG)
          stream.instance_variable_get(TAG)
        end

        def self.chain(value)
          return [value] if value.is_a?(Hash)
          value.is_a?(Array) ? value.select { |item| item.is_a?(Hash) } : []
        end

        # base: the stream's own resource dictionary (or chain, innermost
        # first). ranges: [[start, stop, chain], ...] byte ranges that came
        # from inlined Forms; ranges nest or are disjoint.
        def initialize(base, ranges = nil)
          @base = ResourceScope.chain(base)
          @points = ranges && !ranges.empty? ? change_points(ranges) : nil
        end

        def chain_at(offset)
          return @base unless @points && offset.is_a?(Integer)
          low = 0
          high = @points.length - 1
          found = nil
          while low <= high
            middle = (low + high) / 2
            if @points[middle][0] <= offset
              found = middle
              low = middle + 1
            else
              high = middle - 1
            end
          end
          found ? @points[found][1] : @base
        end

        private

        # Nested ranges flattened to [offset, chain] change points in
        # ascending offset order.
        def change_points(ranges)
          points = []
          open = []
          ordered = ranges.sort_by { |row| [row[0], -row[1]] }
          ordered.each do |start, stop, chain|
            while !open.empty? && open[-1][0] <= start
              closed = open.pop
              points << [closed[0], open.empty? ? @base : open[-1][1]]
            end
            usable = ResourceScope.chain(chain)
            open << [stop, usable]
            points << [start, usable]
          end
          until open.empty?
            closed = open.pop
            points << [closed[0], open.empty? ? @base : open[-1][1]]
          end
          points
        end
      end
    end
  end
end
