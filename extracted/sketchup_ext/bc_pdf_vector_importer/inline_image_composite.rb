# bc_pdf_vector_importer/inline_image_composite.rb
#
# Inline images (BI <dict> ID <data> EI) in construction PDFs are almost
# always ONE pasted picture that the producer sliced into one-row strips
# (Bluebeam/Acrobat "flatten"): 2,175 strips make the title-block stamp on
# the A04 sheet, 41,817 make one Attachment-C sheet. Until now they were
# only counted, and the picture became a whole-page raster or an omission.
#
# This module holds the host-free half of the composite delivery:
#   * the inline dictionary parser with the BI abbreviations expanded,
#   * the lossless decoders (ASCIIHex / ASCII85 / RunLength / Flate, PNG
#     predictors, 1-16 bit sample unpacking, Decode inversion),
#   * the orientation frame of a placement (unit-square affine -> the
#     strip's own axes), region clustering of strips that touch, and the
#     canvas plan (native pixel density, bounded by the same pixel budget
#     as XObject images),
#   * the painter that resamples one decoded strip into the region canvas
#     through the exact inverse affine, RGBA so gaps stay transparent.
# EmbeddedImageExtractor drives it, writes the PNG through PngCropper and
# hands the result to the ordinary native Image placement.
#
# Whatever cannot be composited safely raises Unsupported with the reason
# (stencil masks, CCITT/JBIG2/JPX/LZW data, sheared placements, unsupported
# Decode arrays, short data) and is reported as an omission. Nothing is
# guessed and nothing is dropped silently.
#
# Ruby 2.2 (SketchUp 2017) compatible: no safe-navigation operator, no
# squiggly heredoc, no Array#sum / Comparable#clamp / String#unpack1.
#
# Copyright 2024-2026 BlueCollar Systems -- BUILT. NOT BOUGHT.

require 'zlib'
require 'digest'
require_relative 'content_stream_parser'

module BlueCollarSystems
  module PDFVectorImporter
    module InlineImageComposite
      class Unsupported < StandardError; end

      KEY_ABBREVIATIONS = {
        '/BPC' => '/BitsPerComponent', '/CS' => '/ColorSpace',
        '/D' => '/Decode', '/DP' => '/DecodeParms', '/F' => '/Filter',
        '/H' => '/Height', '/W' => '/Width', '/IM' => '/ImageMask',
        '/I' => '/Interpolate', '/L' => '/Length'
      }.freeze
      COLOR_ABBREVIATIONS = {
        '/G' => '/DeviceGray', '/RGB' => '/DeviceRGB',
        '/CMYK' => '/DeviceCMYK', '/I' => '/Indexed'
      }.freeze
      FILTER_ABBREVIATIONS = {
        '/AHx' => '/ASCIIHexDecode', '/A85' => '/ASCII85Decode',
        '/LZW' => '/LZWDecode', '/Fl' => '/FlateDecode',
        '/RL' => '/RunLengthDecode', '/CCF' => '/CCITTFaxDecode',
        '/DCT' => '/DCTDecode'
      }.freeze
      LOSSLESS_FILTERS = [
        '/ASCIIHexDecode', '/ASCII85Decode', '/RunLengthDecode', '/FlateDecode'
      ].freeze
      DEVICE_COMPONENTS = {
        '/DeviceGray' => 1, '/DeviceRGB' => 3, '/DeviceCMYK' => 4
      }.freeze
      # Same budget as EmbeddedImageExtractor::MAX_IMAGE_PIXELS (asserted by
      # test/inline_image_composite_test.rb); a region above it is
      # downsampled, and the record says so.
      MAX_PIXELS = 25_000_000
      # Strips of one picture touch (0.12 pt rows); this gap joins rows and
      # runs of one picture without reaching a neighbouring picture.
      TOUCH_GAP_PT = 0.5
      # Second pass: nearby regions of one stamp (a logo beside its text)
      # become one canvas when the union stays reasonably filled and within
      # budget, so a title block is one Image, not forty.
      MERGE_GAP_PT = 12.0
      MERGE_MIN_FILL = 0.15
      DIRECTION_BIN_DEG = 0.5

      module_function

      # ------------------------------------------------------------------
      # Dictionary
      # ------------------------------------------------------------------

      # Parse the text between BI and ID into a Hash of '/Key' => value.
      # Values: '/Name' strings, '<hex>' / '(literal)' strings kept as
      # source text, Integer/Float numbers, true/false/nil, nested Arrays
      # and Hashes. Keys and colour/filter names keep their abbreviations
      # here; normalize_dictionary expands them.
      def parse_dictionary(text)
        tokens = tokenize(text.to_s)
        dict, _index = parse_pairs(tokens, 0, nil)
        dict
      end

      def tokenize(text)
        bin = text.dup
        bin.force_encoding(Encoding::BINARY) if bin.respond_to?(:force_encoding)
        whitespace = ContentStreamParser::SCAN_WHITESPACE
        delimiter = ContentStreamParser::SCAN_DELIMITER
        tokens = []
        i = 0
        len = bin.bytesize
        while i < len
          b = bin.getbyte(i)
          if whitespace[b]
            i += 1
            next
          end
          case b
          when 47 # '/'
            j = i + 1
            j += 1 while j < len && !delimiter[bin.getbyte(j)]
            tokens << bin.byteslice(i, j - i)
            i = j
          when 91 # '['
            tokens << :array_open
            i += 1
          when 93 # ']'
            tokens << :array_close
            i += 1
          when 60 # '<'
            if i + 1 < len && bin.getbyte(i + 1) == 60
              tokens << :dict_open
              i += 2
            else
              j = bin.index('>', i) || (len - 1)
              tokens << bin.byteslice(i, j - i + 1)
              i = j + 1
            end
          when 62 # '>'
            if i + 1 < len && bin.getbyte(i + 1) == 62
              tokens << :dict_close
              i += 2
            else
              i += 1
            end
          when 40 # '('
            depth = 1
            j = i + 1
            while j < len && depth > 0
              nb = bin.getbyte(j)
              if nb == 92
                j += 2
                next
              end
              depth += 1 if nb == 40
              depth -= 1 if nb == 41
              j += 1
            end
            tokens << bin.byteslice(i, j - i)
            i = j
          else
            j = i
            j += 1 while j < len && !delimiter[bin.getbyte(j)]
            if j == i
              i += 1
              next
            end
            word = bin.byteslice(i, j - i)
            i = j
            tokens << scalar_token(word)
          end
        end
        tokens
      end

      def scalar_token(word)
        case word
        when 'true' then true
        when 'false' then false
        when 'null' then nil
        when /\A[+-]?\d+\z/ then word.to_i
        when /\A[+-]?(?:\d+\.\d*|\.\d+)\z/ then word.to_f
        else word
        end
      end

      def parse_pairs(tokens, index, terminator)
        dict = {}
        while index < tokens.length
          token = tokens[index]
          return [dict, index + 1] if terminator && token == terminator
          index += 1
          next unless token.is_a?(String) && token.start_with?('/')
          value, index = parse_value(tokens, index)
          dict[token] = value
        end
        [dict, index]
      end

      def parse_value(tokens, index)
        token = tokens[index]
        case token
        when :array_open
          list = []
          index += 1
          while index < tokens.length && tokens[index] != :array_close
            value, index = parse_value(tokens, index)
            list << value
          end
          [list, index + 1]
        when :dict_open
          parse_pairs(tokens, index + 1, :dict_close)
        when :array_close, :dict_close
          [nil, index + 1]
        else
          [token, index + 1]
        end
      end

      # Expand the BI abbreviations. Filters become an Array of full names;
      # the colour space keeps its shape (name or array) with device
      # abbreviations expanded in the name and in an Indexed base.
      def normalize_dictionary(raw)
        dict = {}
        raw.each do |key, value|
          dict[KEY_ABBREVIATIONS[key] || key] = value
        end
        if dict.key?('/ColorSpace')
          dict['/ColorSpace'] = normalize_color_space_value(dict['/ColorSpace'])
        end
        if dict.key?('/Filter')
          filters = dict['/Filter'].is_a?(Array) ? dict['/Filter'] : [dict['/Filter']]
          dict['/Filter'] = filters.compact.map { |f| FILTER_ABBREVIATIONS[f] || f }
        end
        dict
      end

      def normalize_color_space_value(value)
        if value.is_a?(Array)
          list = value.dup
          if list[0].is_a?(String)
            list[0] = COLOR_ABBREVIATIONS[list[0]] || list[0]
          end
          if list.length > 1 && list[1].is_a?(String)
            list[1] = COLOR_ABBREVIATIONS[list[1]] || list[1]
          end
          list
        elsif value.is_a?(String)
          COLOR_ABBREVIATIONS[value] || value
        else
          value
        end
      end

      # ------------------------------------------------------------------
      # Sample decoding
      # ------------------------------------------------------------------

      # Describe a normalized inline dictionary for compositing. Returns
      # { :width, :height, :bits, :filters, :kind } where :kind is :lossless
      # (decodable to samples here) or :jpeg (DCT bytes deliverable as a
      # file, never composited). Raises Unsupported otherwise.
      def describe(dict)
        width = dict['/Width'].to_i
        height = dict['/Height'].to_i
        unless width > 0 && height > 0
          raise Unsupported, 'inline image has no positive Width/Height'
        end
        if dict['/ImageMask'] == true
          raise Unsupported, 'stencil mask (ImageMask) inline images are not composited'
        end
        bits = dict.key?('/BitsPerComponent') ? dict['/BitsPerComponent'].to_i : 8
        unless [1, 2, 4, 8, 16].include?(bits)
          raise Unsupported, "inline image BitsPerComponent #{bits} is unsupported"
        end
        filters = Array(dict['/Filter']).map { |f| f.to_s }
        kind = :lossless
        filters.each_with_index do |filter, index|
          next if LOSSLESS_FILTERS.include?(filter)
          if filter == '/DCTDecode' && index == filters.length - 1
            kind = :jpeg
            next
          end
          raise Unsupported, "#{filter.sub(%r{\A/}, '')} inline image data is not composited"
        end
        if width * height > MAX_PIXELS
          raise Unsupported, "inline image exceeds the #{MAX_PIXELS}-pixel safety limit"
        end
        { :width => width, :height => height, :bits => bits,
          :filters => filters, :kind => kind }
      end

      # Decode the inline bytes to 8-bit samples (width * height * components
      # bytes, rows unpadded). `components` comes from the resolved colour
      # space; `indexed` keeps raw palette indices instead of scaling.
      def decode_samples(dict, data, spec, components, indexed)
        bytes = data.dup
        bytes.force_encoding(Encoding::BINARY) if bytes.respond_to?(:force_encoding)
        filters = spec[:filters]
        parms_list = decode_parms_list(dict['/DecodeParms'], filters.length)
        filters.each_with_index do |filter, index|
          bytes = case filter
                  when '/ASCIIHexDecode' then ascii_hex_decode(bytes)
                  when '/ASCII85Decode' then ascii85_decode(bytes)
                  when '/RunLengthDecode' then run_length_decode(bytes)
                  when '/FlateDecode' then inflate(bytes)
                  else raise Unsupported, "#{filter} inline image data is not composited"
                  end
          bytes = apply_predictor(bytes, parms_list[index], spec, components)
        end
        width, height, bits = spec[:width], spec[:height], spec[:bits]
        row_bytes = (width * bits * components + 7) / 8
        expected = row_bytes * height
        if bytes.bytesize < expected
          raise Unsupported,
                "inline image data is short (#{bytes.bytesize} of #{expected} bytes)"
        end
        bytes = bytes.byteslice(0, expected) if bytes.bytesize > expected
        samples = unpack_samples(bytes, width, height, bits, components, !indexed)
        apply_decode_array!(samples, dict['/Decode'], components, bits, indexed)
        samples
      end

      def decode_parms_list(value, count)
        list = value.is_a?(Array) ? value : [value]
        list = list.map { |entry| entry.is_a?(Hash) ? entry : nil }
        list << nil while list.length < count
        list
      end

      def apply_predictor(bytes, parms, spec, components)
        return bytes unless parms.is_a?(Hash)
        predictor = parms['/Predictor'].to_i
        return bytes if predictor <= 1
        if predictor == 2
          raise Unsupported, 'TIFF predictor inline image data is not composited'
        end
        columns = parms.key?('/Columns') ? parms['/Columns'].to_i : 1
        colors = parms.key?('/Colors') ? parms['/Colors'].to_i : 1
        bits = parms.key?('/BitsPerComponent') ? parms['/BitsPerComponent'].to_i : 8
        columns = spec[:width] if columns <= 0
        colors = components if colors <= 0
        png_unpredict(bytes, columns, colors, bits)
      end

      def png_unpredict(data, columns, colors, bits)
        unless columns > 0 && colors > 0 && [1, 2, 4, 8, 16].include?(bits)
          raise Unsupported, 'invalid PNG predictor sample dimensions'
        end
        row_bytes = (columns * colors * bits + 7) / 8
        pixel_bytes = [(colors * bits + 7) / 8, 1].max
        row_size = row_bytes + 1
        unless data.bytesize % row_size == 0
          raise Unsupported, 'PNG predictor inline image data ends inside a row'
        end
        rows = data.bytesize / row_size
        out = blank_bytes(rows * row_bytes)
        prev = Array.new(row_bytes, 0)
        r = 0
        while r < rows
          offset = r * row_size
          filter_type = data.getbyte(offset)
          unless filter_type >= 0 && filter_type <= 4
            raise Unsupported, "unsupported PNG predictor filter #{filter_type}"
          end
          current = Array.new(row_bytes)
          c = 0
          while c < row_bytes
            raw = data.getbyte(offset + 1 + c)
            left = c >= pixel_bytes ? current[c - pixel_bytes] : 0
            up = prev[c]
            up_left = c >= pixel_bytes ? prev[c - pixel_bytes] : 0
            prediction = case filter_type
                         when 0 then 0
                         when 1 then left
                         when 2 then up
                         when 3 then (left + up) / 2
                         else
                           p = left + up - up_left
                           pa = (p - left).abs
                           pb = (p - up).abs
                           pc = (p - up_left).abs
                           if pa <= pb && pa <= pc then left
                           elsif pb <= pc then up
                           else up_left
                           end
                         end
            value = (raw + prediction) & 0xFF
            current[c] = value
            out.setbyte(r * row_bytes + c, value)
            c += 1
          end
          prev = current
          r += 1
        end
        out
      end

      def unpack_samples(data, width, height, bits, components, scale)
        return data if bits == 8
        row_bytes = (width * bits * components + 7) / 8
        per_row = width * components
        out = blank_bytes(per_row * height)
        max = (1 << bits) - 1
        o = 0
        row = 0
        while row < height
          base = row * row_bytes
          if bits == 16
            k = 0
            while k < per_row
              out.setbyte(o, data.getbyte(base + 2 * k))
              o += 1
              k += 1
            end
          else
            per_byte = 8 / bits
            k = 0
            while k < per_row
              byte = data.getbyte(base + k / per_byte)
              shift = 8 - bits * (k % per_byte + 1)
              value = (byte >> shift) & max
              value = (value * 255) / max if scale
              out.setbyte(o, value)
              o += 1
              k += 1
            end
          end
          row += 1
        end
        out
      end

      # Only the default Decode array and its exact inversion are
      # composited; anything else is an omission with its reason.
      def apply_decode_array!(samples, decode, components, bits, indexed)
        return samples unless decode.is_a?(Array) && !decode.empty?
        values = decode.map { |v| v.to_f }
        max = indexed ? ((1 << bits) - 1).to_f : 1.0
        default = []
        inverted = []
        components.times do
          default << 0.0 << max
          inverted << max << 0.0
        end
        return samples if values == default
        if values == inverted && !indexed
          i = 0
          n = samples.bytesize
          while i < n
            samples.setbyte(i, 255 - samples.getbyte(i))
            i += 1
          end
          return samples
        end
        raise Unsupported, 'non-default Decode array inline images are not composited'
      end

      def ascii_hex_decode(data)
        text = data.to_s
        stop = text.index('>')
        text = text[0, stop] if stop
        hex = text.gsub(/[^0-9A-Fa-f]/, '')
        hex += '0' if hex.length.odd?
        [hex].pack('H*')
      end

      def ascii85_decode(data)
        text = data.to_s.dup
        text.force_encoding(Encoding::BINARY) if text.respond_to?(:force_encoding)
        text = text.sub(/\A<~/, '')
        stop = text.index('~>')
        text = text[0, stop] if stop
        out = blank_bytes(0)
        group = []
        text.each_byte do |byte|
          next if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12 || byte == 0
          if byte == 122 && group.empty? # 'z'
            out << [0].pack('N')
            next
          end
          unless byte >= 33 && byte <= 117
            raise Unsupported, 'invalid ASCII85 inline image data'
          end
          group << (byte - 33)
          if group.length == 5
            value = group.inject(0) { |acc, digit| acc * 85 + digit }
            out << [value].pack('N')
            group = []
          end
        end
        unless group.empty?
          missing = 5 - group.length
          missing.times { group << 84 }
          value = group.inject(0) { |acc, digit| acc * 85 + digit }
          out << [value].pack('N').byteslice(0, 4 - missing)
        end
        out
      end

      def run_length_decode(data)
        out = blank_bytes(0)
        i = 0
        len = data.bytesize
        while i < len
          code = data.getbyte(i)
          i += 1
          break if code == 128
          if code < 128
            out << data.byteslice(i, code + 1)
            i += code + 1
          else
            out << data.byteslice(i, 1) * (257 - code)
            i += 1
          end
        end
        out
      end

      def inflate(data)
        Zlib::Inflate.inflate(data)
      rescue Zlib::Error
        begin
          Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(data)
        rescue Zlib::Error => error
          raise Unsupported, "inline image Flate data is corrupt (#{error.message})"
        end
      end

      def blank_bytes(length)
        value = "\0" * length
        value.force_encoding(Encoding::BINARY) if value.respond_to?(:force_encoding)
        value
      end

      # ------------------------------------------------------------------
      # Colour
      # ------------------------------------------------------------------

      # Reduce a resolved colour space (name, or array whose refs are
      # already resolved by the caller) to a device form the sampler
      # understands: '/DeviceGray' | '/DeviceRGB' | '/DeviceCMYK' |
      # ['/Indexed', device_base, hival, lookup]. `stream_n` resolves an
      # ICCBased stream reference to its /N component count.
      def device_color_space(value, stream_n = nil)
        value = '/DeviceGray' if value.nil?
        if value.is_a?(String)
          return value if DEVICE_COMPONENTS.key?(value)
          return '/DeviceGray' if value == '/CalGray'
          return '/DeviceRGB' if value == '/CalRGB'
          raise Unsupported, "#{value.sub(%r{\A/}, '')} colour space inline images are not composited"
        end
        unless value.is_a?(Array) && value[0].is_a?(String)
          raise Unsupported, 'inline image colour space is unreadable'
        end
        case value[0]
        when '/Indexed'
          base = device_color_space(value[1], stream_n)
          unless base.is_a?(String)
            raise Unsupported, 'nested Indexed colour spaces are not composited'
          end
          ['/Indexed', base, value[2].to_i, value[3]]
        when '/ICCBased'
          n = stream_n ? stream_n.call(value[1]) : nil
          case n.to_i
          when 1 then '/DeviceGray'
          when 3 then '/DeviceRGB'
          when 4 then '/DeviceCMYK'
          else raise Unsupported, 'ICCBased colour space without a readable /N is not composited'
          end
        when '/CalGray' then '/DeviceGray'
        when '/CalRGB' then '/DeviceRGB'
        when '/DeviceGray', '/DeviceRGB', '/DeviceCMYK' then value[0]
        else
          raise Unsupported, "#{value[0].sub(%r{\A/}, '')} colour space inline images are not composited"
        end
      end

      def components_for(device)
        return 1 if device.is_a?(Array)
        DEVICE_COMPONENTS[device] || raise(Unsupported, 'colour components unknown')
      end

      # RGB of sample `index` (pixel index, not byte offset).
      # color_info is EmbeddedImageExtractor#color_space_info's Hash.
      def sample_rgb(samples, index, components, color_info)
        offset = index * components
        case color_info[:type]
        when '/DeviceGray'
          gray = samples.getbyte(offset)
          [gray, gray, gray]
        when '/DeviceRGB'
          [samples.getbyte(offset), samples.getbyte(offset + 1), samples.getbyte(offset + 2)]
        when '/DeviceCMYK'
          c = samples.getbyte(offset)
          m = samples.getbyte(offset + 1)
          y = samples.getbyte(offset + 2)
          k = samples.getbyte(offset + 3)
          [255 - [255, c + k].min, 255 - [255, m + k].min, 255 - [255, y + k].min]
        when '/Indexed'
          indexed_rgb(samples.getbyte(offset), color_info)
        else
          raise Unsupported, "#{color_info[:type]} samples are not composited"
        end
      end

      def indexed_rgb(index, color_info)
        high = color_info[:high].to_i
        index = high if index > high
        base = color_info[:base]
        n = DEVICE_COMPONENTS[base]
        lookup = color_info[:lookup]
        raise Unsupported, 'indexed colour lookup is unavailable' unless n && lookup
        offset = index * n
        unless lookup.bytesize >= offset + n
          raise Unsupported, 'indexed colour lookup is truncated'
        end
        case n
        when 1
          gray = lookup.getbyte(offset)
          [gray, gray, gray]
        when 3
          [lookup.getbyte(offset), lookup.getbyte(offset + 1), lookup.getbyte(offset + 2)]
        else
          k = lookup.getbyte(offset + 3)
          [255 - [255, lookup.getbyte(offset) + k].min,
           255 - [255, lookup.getbyte(offset + 1) + k].min,
           255 - [255, lookup.getbyte(offset + 2) + k].min]
        end
      end

      # ------------------------------------------------------------------
      # Geometry
      # ------------------------------------------------------------------

      # The placement's own axes. nil when the affine is degenerate or
      # sheared (a sheared strip cannot be resampled into a rectangle
      # without inventing pixels).
      def frame_for(ctm)
        a, b, c, d = ctm[0].to_f, ctm[1].to_f, ctm[2].to_f, ctm[3].to_f
        return nil unless [a, b, c, d].all? { |v| v.finite? }
        lu = Math.sqrt(a * a + b * b)
        lv = Math.sqrt(c * c + d * d)
        return nil unless lu > 0.0 && lv > 0.0
        return nil unless (a * c + b * d).abs <= 1.0e-6 * lu * lv
        angle = Math.atan2(b / lu, a / lu) * 180.0 / Math::PI
        angle += 180.0 while angle < 0.0
        angle -= 180.0 while angle >= 180.0
        bins = (180.0 / DIRECTION_BIN_DEG).round
        { :key => (angle / DIRECTION_BIN_DEG).round % bins, :angle_deg => angle,
          :u_length => lu, :v_length => lv }
      end

      def axes_for_angle(angle_deg)
        radians = angle_deg * Math::PI / 180.0
        u = [Math.cos(radians), Math.sin(radians)]
        [u, [-u[1], u[0]]]
      end

      def unit_corners(ctm)
        [[0, 0], [1, 0], [1, 1], [0, 1]].map do |p|
          [ctm[0] * p[0] + ctm[2] * p[1] + ctm[4],
           ctm[1] * p[0] + ctm[3] * p[1] + ctm[5]]
        end
      end

      # [smin, tmin, smax, tmax] of the placement in frame (u, n) coordinates.
      def frame_box(ctm, u, n)
        corners = unit_corners(ctm)
        ss = corners.map { |p| p[0] * u[0] + p[1] * u[1] }
        ts = corners.map { |p| p[0] * n[0] + p[1] * n[1] }
        [ss.min, ts.min, ss.max, ts.max]
      end

      def union_box(a, b)
        [[a[0], b[0]].min, [a[1], b[1]].min, [a[2], b[2]].max, [a[3], b[3]].max]
      end

      def touches?(a, b, gap)
        a[0] - gap <= b[2] && b[0] - gap <= a[2] &&
          a[1] - gap <= b[3] && b[1] - gap <= a[3]
      end

      def box_area(box)
        [(box[2] - box[0]), 0.0].max * [(box[3] - box[1]), 0.0].max
      end

      # Group boxes that touch (within `gap`) into regions. One sweep over
      # the boxes sorted by tmin keeps only the regions that can still be
      # reached, so 41,817 strips cost one pass, not a quadratic one.
      # Returns Array of { :members => [indices], :box => union }.
      def cluster(boxes, gap)
        order = (0...boxes.length).sort_by { |i| [boxes[i][1], boxes[i][0], i] }
        active = []
        done = []
        order.each do |i|
          box = boxes[i]
          still = []
          active.each do |region|
            if region[:box][3] + gap < box[1]
              done << region
            else
              still << region
            end
          end
          active = still
          hits = active.select { |region| touches?(region[:box], box, gap) }
          if hits.empty?
            active << { :members => [i], :box => box.dup }
          else
            target = hits.shift
            target[:members] << i
            target[:box] = union_box(target[:box], box)
            hits.each do |other|
              target[:members].concat(other[:members])
              target[:box] = union_box(target[:box], other[:box])
              active.delete(other)
            end
          end
        end
        (done + active).each { |region| region[:members].sort! }
      end

      # Merge nearby regions of one stamp when the union stays reasonably
      # filled and within the pixel budget. `member_area` sums each
      # region's own strip areas; `pixels_for` estimates a box's canvas
      # pixel count.
      def merge_regions(regions, member_area, pixels_for)
        list = regions.map { |r| { :members => r[:members].dup, :box => r[:box].dup, :area => member_area.call(r[:members]) } }
        changed = true
        rounds = 0
        while changed && rounds < 1000
          changed = false
          rounds += 1
          i = 0
          while i < list.length && !changed
            j = i + 1
            while j < list.length
              a, b = list[i], list[j]
              if touches?(a[:box], b[:box], MERGE_GAP_PT)
                union = union_box(a[:box], b[:box])
                fill = box_area(union) > 0.0 ? (a[:area] + b[:area]) / box_area(union) : 0.0
                if fill >= MERGE_MIN_FILL && pixels_for.call(union) <= MAX_PIXELS
                  list[i] = { :members => (a[:members] + b[:members]).sort,
                              :box => union, :area => a[:area] + b[:area] }
                  list.delete_at(j)
                  changed = true
                  break
                end
              end
              j += 1
            end
            i += 1
          end
        end
        list.map { |r| { :members => r[:members], :box => r[:box] } }
      end

      # Canvas pixel plan for a region box at the region's native density.
      def plan_canvas(box, sx, sy, max_pixels = MAX_PIXELS)
        width_pt = box[2] - box[0]
        height_pt = box[3] - box[1]
        raise Unsupported, 'inline region has no area' unless width_pt > 0.0 && height_pt > 0.0
        width = [(width_pt * sx).round, 1].max
        height = [(height_pt * sy).round, 1].max
        downsampled = false
        if width * height > max_pixels
          factor = Math.sqrt(max_pixels.to_f / (width * height))
          width = [(width * factor).floor, 1].max
          height = [(height * factor).floor, 1].max
          downsampled = true
        end
        { :width => width, :height => height, :downsampled => downsampled,
          :width_pt => width_pt, :height_pt => height_pt }
      end

      # Page-space affine of the region canvas: unit square -> region box,
      # u along the strips, image row 0 at the top (t = tmax) as PDF images
      # define it.
      def canvas_ctm(box, u, n)
        origin = [box[0] * u[0] + box[1] * n[0], box[0] * u[1] + box[1] * n[1]]
        width_pt = box[2] - box[0]
        height_pt = box[3] - box[1]
        [width_pt * u[0], width_pt * u[1], height_pt * n[0], height_pt * n[1],
         origin[0], origin[1]]
      end

      def invert(m)
        det = m[0] * m[3] - m[1] * m[2]
        return nil unless det.finite? && det.abs > 1.0e-12
        [m[3] / det, -m[1] / det, -m[2] / det, m[0] / det,
         (m[2] * m[5] - m[3] * m[4]) / det, (m[1] * m[4] - m[0] * m[5]) / det]
      end

      def blank_canvas(width, height)
        blank_bytes(width * height * 4)
      end

      # Resample one decoded strip into the region canvas through the exact
      # inverse of its affine. A canvas pixel whose centre lies inside the
      # strip takes the strip sample under it (later strips overwrite, as
      # PDF paint order says). A pixel whose centre lies within a quarter
      # canvas pixel OUTSIDE the strip is filled only while it is still
      # transparent, so abutting rows leave no hairline yet a strip never
      # steals a pixel its neighbour owns and a real gap stays clear.
      # Returns the number of canvas pixels painted for the first time.
      #   canvas: RGBA bytes; plan: plan_canvas result; box: the region box;
      #   u/n: frame axes; member: { :ctm, :width, :height, :samples,
      #   :components, :color_info }; member_box: its frame box.
      def paint_member!(canvas, plan, box, u, n, member, member_box)
        wc, hc = plan[:width], plan[:height]
        sxc = wc / plan[:width_pt]
        syc = hc / plan[:height_pt]
        cx0 = [((member_box[0] - box[0]) * sxc).floor - 1, 0].max
        cx1 = [((member_box[2] - box[0]) * sxc).ceil, wc - 1].min
        cy0 = [((box[3] - member_box[3]) * syc).floor - 1, 0].max
        cy1 = [((box[3] - member_box[1]) * syc).ceil, hc - 1].min
        return 0 if cx1 < cx0 || cy1 < cy0
        inv = invert(member[:ctm])
        return 0 unless inv
        ox = box[0] * u[0] + box[1] * n[0]
        oy = box[0] * u[1] + box[1] * n[1]
        wpt, hpt = plan[:width_pt], plan[:height_pt]
        dxx = u[0] * wpt / wc
        dxy = u[1] * wpt / wc
        dyx = -n[0] * hpt / hc
        dyy = -n[1] * hpt / hc
        p00x = ox + hpt * n[0] + 0.5 * dxx + 0.5 * dyx
        p00y = oy + hpt * n[1] + 0.5 * dxy + 0.5 * dyy
        ia, ib, ic, id, ie, iff = inv
        u00 = ia * p00x + ic * p00y + ie
        v00 = ib * p00x + id * p00y + iff
        du_x = ia * dxx + ic * dxy
        dv_x = ib * dxx + id * dxy
        du_y = ia * dyx + ic * dyy
        dv_y = ib * dyx + id * dyy
        # A quarter of a canvas pixel: closes the sub-pixel seams of strips
        # whose pitch is not an exact pixel multiple, never the next pixel
        # centre, so a genuine gap of one row or more stays transparent.
        eps_u = 0.25 * (du_x.abs + du_y.abs)
        eps_v = 0.25 * (dv_x.abs + dv_y.abs)
        width, height = member[:width], member[:height]
        samples, components, info = member[:samples], member[:components], member[:color_info]
        gray = info[:type] == '/DeviceGray'
        rgb = info[:type] == '/DeviceRGB'
        painted = 0
        cy = cy0
        while cy <= cy1
          u_row = u00 + cy * du_y
          v_row = v00 + cy * dv_y
          cx = cx0
          while cx <= cx1
            uu = u_row + cx * du_x
            vv = v_row + cx * dv_x
            target = (cy * wc + cx) * 4
            inside = uu >= 0.0 && uu < 1.0 && vv >= 0.0 && vv < 1.0
            if inside ||
               (canvas.getbyte(target + 3) == 0 &&
                uu >= -eps_u && uu <= 1.0 + eps_u && vv >= -eps_v && vv <= 1.0 + eps_v)
              col = (uu * width).floor
              col = 0 if col < 0
              col = width - 1 if col >= width
              row = ((1.0 - vv) * height).floor
              row = 0 if row < 0
              row = height - 1 if row >= height
              index = row * width + col
              if gray
                g = samples.getbyte(index)
                r = g
                b = g
              elsif rgb
                offset = index * 3
                r = samples.getbyte(offset)
                g = samples.getbyte(offset + 1)
                b = samples.getbyte(offset + 2)
              else
                r, g, b = sample_rgb(samples, index, components, info)
              end
              painted += 1 if canvas.getbyte(target + 3) == 0
              canvas.setbyte(target, r)
              canvas.setbyte(target + 1, g)
              canvas.setbyte(target + 2, b)
              canvas.setbyte(target + 3, 255)
            end
            cx += 1
          end
          cy += 1
        end
        painted
      end

      def strip_alpha(canvas, width, height)
        out = blank_bytes(width * height * 3)
        i = 0
        n = width * height
        while i < n
          out.setbyte(i * 3, canvas.getbyte(i * 4))
          out.setbyte(i * 3 + 1, canvas.getbyte(i * 4 + 1))
          out.setbyte(i * 3 + 2, canvas.getbyte(i * 4 + 2))
          i += 1
        end
        out
      end
    end
  end
end
