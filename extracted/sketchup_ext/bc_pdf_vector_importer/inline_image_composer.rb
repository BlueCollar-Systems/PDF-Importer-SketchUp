# bc_pdf_vector_importer/inline_image_composer.rb
# Decode PDF inline images (BI ... ID ... EI) and stitch neighbouring ones
# into one picture.
#
# Some producers (Bluebeam, Acrobat "optimize") emit a raster logo as
# thousands of one-pixel-tall inline images, each a row segment of the
# original picture. Placing each as its own SketchUp Image is unusable, and
# rastering the whole page to keep them throws away every vector path. This
# module rebuilds each connected group as one image on the strips' own pixel
# grid (no resampling when the strips share a grid): strips are painted in
# content-stream order, so a later strip covers an earlier one exactly as in
# the PDF, and pixels no strip paints stay fully transparent.
#
# Only lossless, fully-understood encodings are decoded: 8-bit DeviceGray /
# DeviceRGB with Flate (PNG predictors), ASCIIHex, ASCII85 or RunLength, on
# an axis-aligned CTM. Anything else raises Unsupported with the reason; the
# caller reports those inline images as omitted instead of guessing.
#
# Ruby 2.2 compatible. Copyright 2024-2026 BlueCollar Systems -- BUILT. NOT BOUGHT.

require 'zlib'

module BlueCollarSystems
  module PDFVectorImporter
    module InlineImageComposer
      class Unsupported < StandardError; end

      KEY_ABBREVIATIONS = {
        '/BPC' => '/BitsPerComponent', '/CS' => '/ColorSpace',
        '/D' => '/Decode', '/DP' => '/DecodeParms', '/F' => '/Filter',
        '/H' => '/Height', '/IM' => '/ImageMask', '/I' => '/Interpolate',
        '/W' => '/Width', '/L' => '/Length'
      }.freeze
      COLOR_SPACE_ABBREVIATIONS = {
        '/G' => '/DeviceGray', '/RGB' => '/DeviceRGB',
        '/CMYK' => '/DeviceCMYK', '/I' => '/Indexed'
      }.freeze
      FILTER_ABBREVIATIONS = {
        '/AHx' => '/ASCIIHexDecode', '/A85' => '/ASCII85Decode',
        '/LZW' => '/LZWDecode', '/Fl' => '/FlateDecode',
        '/RL' => '/RunLengthDecode', '/CCF' => '/CCITTFaxDecode',
        '/DCT' => '/DCTDecode'
      }.freeze
      CHANNELS = { '/DeviceGray' => 1, '/DeviceRGB' => 3 }.freeze
      MAX_STRIP_PIXELS = 4_000_000
      MAX_COMPOSITE_PIXELS = 25_000_000
      # Pieces closer than this (PDF points) belong to one picture.
      CLUSTER_GAP_PTS = 6.0
      # Strips must share one pixel grid (relative pitch tolerance).
      PITCH_TOLERANCE = 0.02
      DELIMITERS = " \t\r\n\f\0()<>[]{}/%".freeze

      Strip = Struct.new(:sequence, :ctm, :width, :height, :channels, :pixels,
                         :bbox, :clip_state)

      module_function

      # ---- header ---------------------------------------------------------

      def parse_header(header)
        tokens = tokenize(header.to_s)
        values = []
        index = 0
        while index < tokens.length
          value, index = parse_value(tokens, index)
          values << value
        end
        unless values.length.even?
          raise Unsupported, 'inline image header has an unpaired key'
        end
        dict = {}
        values.each_slice(2) do |key, value|
          unless key.is_a?(String) && key.start_with?('/')
            raise Unsupported, 'inline image header key is not a name'
          end
          full = KEY_ABBREVIATIONS[key] || key
          dict[full] = value
        end
        dict
      end

      def tokenize(text)
        tokens = []
        i = 0
        len = text.length
        while i < len
          ch = text[i]
          if " \t\r\n\f\0".include?(ch)
            i += 1
          elsif ch == '%'
            i += 1 while i < len && text[i] != "\n" && text[i] != "\r"
          elsif text[i, 2] == '<<' || text[i, 2] == '>>'
            tokens << text[i, 2]
            i += 2
          elsif ch == '[' || ch == ']'
            tokens << ch
            i += 1
          elsif ch == '('
            depth = 1
            j = i + 1
            while j < len && depth > 0
              if text[j] == '\\'
                j += 2
                next
              end
              depth += 1 if text[j] == '('
              depth -= 1 if text[j] == ')'
              j += 1
            end
            tokens << [:string, text[i + 1...(j - 1)]]
            i = j
          elsif ch == '<'
            j = text.index('>', i) || len
            tokens << [:string, text[i + 1...j]]
            i = j + 1
          else
            j = i + 1
            j += 1 while j < len && !DELIMITERS.include?(text[j])
            tokens << text[i...j]
            i = j
          end
        end
        tokens
      end

      def parse_value(tokens, index)
        token = tokens[index]
        if token == '['
          items = []
          index += 1
          while index < tokens.length && tokens[index] != ']'
            item, index = parse_value(tokens, index)
            items << item
          end
          return [items, index + 1]
        elsif token == '<<'
          dict = {}
          index += 1
          while index < tokens.length && tokens[index] != '>>'
            key = tokens[index]
            value, index = parse_value(tokens, index + 1)
            dict[key] = value if key.is_a?(String)
          end
          return [dict, index + 1]
        elsif token.is_a?(String) && token =~ /\A[+-]?(?:\d+\.?\d*|\.\d+)\z/
          return [token.include?('.') ? token.to_f : token.to_i, index + 1]
        elsif token == 'true'
          return [true, index + 1]
        elsif token == 'false'
          return [false, index + 1]
        end
        [token, index + 1]
      end

      # ---- samples --------------------------------------------------------

      def decode(dict, data, pdf)
        if dict['/ImageMask'] == true
          raise Unsupported, 'inline stencil masks (/ImageMask) are not composited'
        end
        width = dict['/Width']
        height = dict['/Height']
        unless width.is_a?(Integer) && height.is_a?(Integer) && width > 0 && height > 0
          raise Unsupported, 'inline image dimensions are invalid'
        end
        if width * height > MAX_STRIP_PIXELS
          raise Unsupported, 'inline image exceeds the pixel safety limit'
        end
        bpc = dict['/BitsPerComponent']
        raise Unsupported, "inline image uses #{bpc.inspect}-bit samples" unless bpc == 8
        space = dict['/ColorSpace']
        space = COLOR_SPACE_ABBREVIATIONS[space] || space
        channels = CHANNELS[space]
        unless channels
          raise Unsupported, "inline image color space #{space.inspect} is not composited"
        end
        decode_array = dict['/Decode']
        unless decode_array.nil? || default_decode?(decode_array, channels)
          raise Unsupported, 'inline image /Decode remapping is not composited'
        end
        samples = apply_filters(data, dict['/Filter'], dict['/DecodeParms'], pdf)
        expected = width * height * channels
        if samples.nil? || samples.bytesize < expected
          raise Unsupported, 'inline image samples are shorter than declared'
        end
        [width, height, channels, samples.byteslice(0, expected)]
      end

      def default_decode?(values, channels)
        values.is_a?(Array) && values.length == channels * 2 &&
          values.each_slice(2).all? { |low, high| low.to_f == 0.0 && high.to_f == 1.0 }
      end

      def apply_filters(data, filter_value, parms_value, pdf)
        filters = filter_value.is_a?(Array) ? filter_value : [filter_value].compact
        parms = parms_value.is_a?(Array) ? parms_value : [parms_value]
        out = data.to_s.dup
        out.force_encoding(Encoding::BINARY)
        filters.each_with_index do |raw_name, index|
          name = FILTER_ABBREVIATIONS[raw_name] || raw_name
          case name
          when '/FlateDecode'
            out = inflate(out)
            out = apply_predictor(out, parms[index], pdf)
          when '/ASCIIHexDecode'
            out = pdf_decode(pdf, :ascii_hex_decode, out)
          when '/ASCII85Decode'
            out = pdf_decode(pdf, :ascii85_decode, out)
          when '/RunLengthDecode'
            out = pdf_decode(pdf, :run_length_decode, out)
          else
            raise Unsupported, "inline image filter #{name.inspect} is not composited"
          end
          raise Unsupported, "inline image #{name} decode failed" unless out
          out = out.dup.force_encoding(Encoding::BINARY)
        end
        out
      end

      def pdf_decode(pdf, method_name, *args)
        unless pdf && pdf.respond_to?(method_name)
          raise Unsupported, "inline image decoder #{method_name} is unavailable"
        end
        pdf.public_send(method_name, *args)
      end

      def inflate(data)
        Zlib::Inflate.inflate(data)
      rescue Zlib::Error
        begin
          Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(data)
        rescue Zlib::Error => e
          raise Unsupported, "inline image Flate data is invalid: #{e.message}"
        end
      end

      def apply_predictor(data, parms, pdf)
        return data unless parms.is_a?(Hash)
        predictor = parms['/Predictor'].to_i
        return data if predictor <= 1
        unless predictor >= 10
          raise Unsupported, "inline image TIFF predictor #{predictor} is not composited"
        end
        columns = (parms['/Columns'] || 1).to_i
        colors = (parms['/Colors'] || 1).to_i
        bits = (parms['/BitsPerComponent'] || 8).to_i
        pdf_decode(pdf, :apply_png_predictor, data, columns, colors, bits)
      rescue ArgumentError => e
        raise Unsupported, "inline image predictor failed: #{e.message}"
      end

      # ---- geometry -------------------------------------------------------

      def axis_aligned?(ctm)
        ctm[1].to_f.abs <= 1e-9 && ctm[2].to_f.abs <= 1e-9 &&
          ctm[0].to_f != 0.0 && ctm[3].to_f != 0.0 &&
          ctm.all? { |v| v.to_f.finite? }
      end

      def strip_bbox(ctm)
        xs = [ctm[4], ctm[4] + ctm[0]].map(&:to_f)
        ys = [ctm[5], ctm[5] + ctm[3]].map(&:to_f)
        [xs.min, ys.min, xs.max, ys.max]
      end

      # Connected groups (bboxes within CLUSTER_GAP_PTS), in first-paint order.
      def clusters(strips, gap = CLUSTER_GAP_PTS)
        parent = (0...strips.length).to_a
        find = lambda do |i|
          i = parent[i] = parent[parent[i]] while parent[i] != i
          i
        end
        cell = [gap * 4.0, 1.0].max
        grid = {}
        strips.each_with_index do |strip, index|
          x0, y0, x1, y1 = strip.bbox
          cx0 = ((x0 - gap) / cell).floor
          cx1 = ((x1 + gap) / cell).floor
          cy0 = ((y0 - gap) / cell).floor
          cy1 = ((y1 + gap) / cell).floor
          (cx0..cx1).each do |cx|
            (cy0..cy1).each do |cy|
              (grid[[cx, cy]] ||= []).each do |other|
                next unless near?(strip.bbox, strips[other].bbox, gap)
                a = find.call(index)
                b = find.call(other)
                parent[a] = b unless a == b
              end
            end
          end
          (((x0 / cell).floor)..((x1 / cell).floor)).each do |cx|
            (((y0 / cell).floor)..((y1 / cell).floor)).each do |cy|
              (grid[[cx, cy]] ||= []) << index
            end
          end
        end
        groups = {}
        order = []
        strips.each_with_index do |strip, index|
          root = find.call(index)
          order << root unless groups.key?(root)
          (groups[root] ||= []) << strip
        end
        order.map { |root| groups[root] }
      end

      def near?(a, b, gap)
        a[0] <= b[2] + gap && b[0] <= a[2] + gap &&
          a[1] <= b[3] + gap && b[1] <= a[3] + gap
      end

      def median(values)
        sorted = values.sort
        sorted[sorted.length / 2]
      end

      # One picture from one group. Returns a Hash with :width, :height,
      # :channels (2 gray+alpha or 4 RGBA), :bytes, :ctm, :bbox,
      # :strip_count, :fully_transparent.
      def compose(strips)
        raise Unsupported, 'no inline images to composite' if strips.empty?
        # Pixel-weighted pitch: wide strips carry the precise resolution;
        # narrow ones have extents rounded by the PDF writer.
        pitch_x = strips.inject(0.0) { |sum, s| sum + s.ctm[0].to_f.abs } /
                  strips.inject(0) { |sum, s| sum + s.width }
        pitch_y = strips.inject(0.0) { |sum, s| sum + s.ctm[3].to_f.abs } /
                  strips.inject(0) { |sum, s| sum + s.height }
        unless pitch_x > 0.0 && pitch_y > 0.0 && pitch_x.finite? && pitch_y.finite?
          raise Unsupported, 'inline image pixel pitch is degenerate'
        end
        strips.each do |s|
          unless same_resolution?(s.ctm[0], s.width, pitch_x) &&
                 same_resolution?(s.ctm[3], s.height, pitch_y)
            raise Unsupported,
                  'inline images in one picture use different resolutions'
          end
        end
        x0 = strips.map { |s| s.bbox[0] }.min
        y0 = strips.map { |s| s.bbox[1] }.min
        x1 = strips.map { |s| s.bbox[2] }.max
        y1 = strips.map { |s| s.bbox[3] }.max
        width = [((x1 - x0) / pitch_x).round, 1].max
        height = [((y1 - y0) / pitch_y).round, 1].max
        if width * height > MAX_COMPOSITE_PIXELS
          raise Unsupported, 'stitched inline picture exceeds the pixel safety limit'
        end
        cell_x = (x1 - x0) / width
        cell_y = (y1 - y0) / height
        rgb = strips.any? { |s| s.channels == 3 }
        out_channels = rgb ? 4 : 2
        canvas = "\0" * (width * height * out_channels)
        canvas.force_encoding(Encoding::BINARY)
        strips.sort_by { |s| s.sequence }.each do |s|
          blit(canvas, width, height, out_channels, s, x0, y1, cell_x, cell_y)
        end
        opaque = false
        alpha_index = out_channels - 1
        while alpha_index < canvas.bytesize
          if canvas.getbyte(alpha_index) != 0
            opaque = true
            break
          end
          alpha_index += out_channels
        end
        {
          :width => width, :height => height, :channels => out_channels,
          :bytes => canvas,
          :ctm => [x1 - x0, 0.0, 0.0, y1 - y0, x0, y0],
          :bbox => [x0, y0, x1, y1],
          :pitch_pts => [cell_x, cell_y],
          :strip_count => strips.length,
          :fully_transparent => !opaque
        }
      end

      # A strip matches the picture resolution when its extent is within 2%
      # or within 1.5 picture pixels (writer rounding on narrow strips).
      def same_resolution?(extent, pixels, pitch)
        extent = extent.to_f.abs
        expected = pixels * pitch
        diff = (extent - expected).abs
        diff <= expected * PITCH_TOLERANCE || diff <= pitch * 1.5
      end

      # Every canvas cell whose centre lies inside the strip takes the
      # strip pixel under that centre (inverse mapping: no gaps or seams).
      # Works for any axis-aligned CTM, including mirrored (negative a or d).
      def blit(canvas, width, height, out_channels, strip, x0, y1, cell_x, cell_y)
        a, _b, _c, d, e, f = strip.ctm.map { |v| v.to_f }
        w = strip.width
        h = strip.height
        src = strip.pixels
        channels = strip.channels
        left, right = [e, e + a].min, [e, e + a].max
        bottom, top = [f, f + d].min, [f, f + d].max
        first_col = [((left - x0) / cell_x - 0.5).ceil, 0].max
        last_col = [((right - x0) / cell_x - 0.5).ceil - 1, width - 1].min
        first_row = [((y1 - top) / cell_y - 0.5).ceil, 0].max
        last_row = [((y1 - bottom) / cell_y - 0.5).ceil - 1, height - 1].min
        return if first_col > last_col || first_row > last_row
        columns = (first_col..last_col).map do |target_col|
          u = (x0 + (target_col + 0.5) * cell_x - e) / a
          [[(u * w).floor, 0].max, w - 1].min
        end
        (first_row..last_row).each do |target_row|
          v = (y1 - (target_row + 0.5) * cell_y - f) / d
          # PDF image row 0 sits at unit-square v = 1.
          row = [[((1.0 - v) * h).floor, 0].max, h - 1].min
          row_base = target_row * width
          src_base = row * w * channels
          columns.each_with_index do |col, offset|
            t = (row_base + first_col + offset) * out_channels
            sidx = src_base + col * channels
            if channels == 1
              gray = src.getbyte(sidx)
              canvas.setbyte(t, gray)
              if out_channels == 4
                canvas.setbyte(t + 1, gray)
                canvas.setbyte(t + 2, gray)
              end
            else
              canvas.setbyte(t, src.getbyte(sidx))
              canvas.setbyte(t + 1, src.getbyte(sidx + 1))
              canvas.setbyte(t + 2, src.getbyte(sidx + 2))
            end
            canvas.setbyte(t + out_channels - 1, 255)
          end
        end
      end
    end
  end
end
