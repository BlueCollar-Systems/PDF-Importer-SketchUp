# bc_pdf_vector_importer/image_extractor.rb
# Individual embedded-image extraction for SketchUp.
#
# Scans a page's XObject dictionary for Image XObjects (/Subtype /Image),
# decodes and writes each one to a temp PNG/JPEG file, then places it as a
# sized + positioned Sketchup::Image entity in the model.
#
# Placement math:
#   - PDF image CTM = [sx 0 0 sy tx ty] (after tracking cm operators).
#   - Convert (tx, ty) from PDF points to inches: / 72.0 * scale.
#   - Width  = sx / 72.0 * scale inches.
#   - Height = sy / 72.0 * scale inches.
#   - Y-flip: su_y = page_height_in - (ty / 72.0 * scale) - height.
#
# Supported encodings (raw byte dumps written for SketchUp to decode):
#   DCTDecode  → JPEG  (write as-is)
#   FlateDecode → decompress then write raw pixel data wrapped in PNG
#   JPXDecode  → write raw stream bytes with .jp2 extension (SU may handle)
#   Unfiltered → write raw pixel bytes (limited usefulness without wrapping)
#
# Unsupported: JBIG2Decode, CCITTFaxDecode, LZWDecode — those images are
# skipped with a Logger.warn and counted in :skipped.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'zlib'
require 'tmpdir'
require 'fileutils'

module BlueCollarSystems
  module PDFVectorImporter
    module ImageExtractor

      # Max number of pixels in a single extracted image (safety valve).
      MAX_IMAGE_PIXELS = 60_000_000

      # Struct returned per placed image.
      PlacedImage = Struct.new(
        :xobj_name,    # PDF resource name (e.g. "Im1")
        :file_path,    # temp file written (caller cleans up)
        :width_in,     # placed width in inches
        :height_in,    # placed height in inches
        :origin_x,     # SketchUp X in inches
        :origin_y,     # SketchUp Y in inches (Y-flipped)
        :y_offset,     # page stack Y offset in inches
        :skipped,      # Boolean — true when placement was skipped
        :skip_reason   # String reason when skipped
      )

      # ----------------------------------------------------------------
      # Public entry point — call after the page's vector content is built.
      #
      # Returns Array<PlacedImage>.  Each entry that is NOT skipped has a
      # temp file written; add_image is called on page_entities and the
      # temp file is deleted after placement.
      # ----------------------------------------------------------------
      def self.extract_and_place(
            model,
            pdf_parser,
            pdf_path,
            page_num,
            media_box,
            streams,
            page_entities,
            opts = {}
          )

        scale        = (opts[:scale]    || 1.0).to_f
        scale        = 1.0 if scale <= 0.0
        y_offset     = (opts[:y_offset] || 0.0).to_f
        page_rotation = PageTransform.normalize_rotation(opts[:page_rotation])
        layer_mgr    = opts[:layer_manager]

        page_h_pts   = PageTransform.effective_height(media_box, page_rotation)
        page_h_in    = page_h_pts / 72.0 * scale

        images = scan_image_xobjects(pdf_parser, page_num)
        return [] if images.empty?

        placements = track_image_placements(streams, images.keys)
        results    = []

        images.each do |name, img_info|
          ctm_list = placements[name] || []
          if ctm_list.empty?
            results << PlacedImage.new(
              name, nil, 0, 0, 0, 0, y_offset, true,
              "no Do placement found in content stream"
            )
            next
          end

          decode_image_bytes(pdf_parser, img_info)
          file_path, fmt = write_image_temp(img_info, name, page_num)
          unless file_path
            results << PlacedImage.new(
              name, nil, 0, 0, 0, 0, y_offset, true,
              "unsupported encoding: #{img_info[:filter].inspect}"
            )
            next
          end

          ctm_list.each_with_index do |ctm, _idx|
            # PDF image CTM columns: [a b c d e f]
            # For axis-aligned images: a=sx, d=sy, e=tx, f=ty
            sx = ctm[0].to_f.abs
            sy = ctm[3].to_f.abs
            tx = ctm[4].to_f
            ty = ctm[5].to_f

            # Degenerate: skip zero-size images
            if sx < 0.01 || sy < 0.01
              results << PlacedImage.new(
                name, file_path, 0, 0, 0, 0, y_offset, true,
                "zero-size CTM (sx=#{sx.round(3)}, sy=#{sy.round(3)})"
              )
              next
            end

            w_in = sx / 72.0 * scale
            h_in = sy / 72.0 * scale
            x_in = tx / 72.0 * scale

            # Y-flip: PDF origin bottom-left; SketchUp origin top-left of page.
            # ty is the bottom of the image in PDF space.
            su_y = page_h_in - (ty / 72.0 * scale) - h_in + y_offset

            begin
              pt  = Geom::Point3d.new(x_in, su_y, 0.0)
              img = model.active_entities.add_image(file_path, pt, w_in, h_in)
              if img
                # Assign to page layer via layer_manager when available.
                layer = if layer_mgr && layer_mgr.respond_to?(:resolve_layer)
                          layer_mgr.resolve_layer(nil)
                        elsif model.layers['PDF Import']
                          model.layers['PDF Import']
                        else
                          model.layers.add('PDF Import')
                        end
                begin
                  img.layer = layer if layer
                rescue StandardError => e
                  Logger.warn("ImageExtractor", "layer assign failed: #{e.message}")
                end
                Logger.info(
                  "ImageExtractor",
                  "Page #{page_num}: placed #{name} (#{fmt}) " \
                  "#{w_in.round(3)}×#{h_in.round(3)}in at (#{x_in.round(3)},#{su_y.round(3)})"
                )
              end
            rescue StandardError => e
              Logger.warn("ImageExtractor",
                "Page #{page_num}: add_image failed for #{name}: #{e.message}")
            ensure
              begin
                File.delete(file_path) if file_path && File.exist?(file_path)
              rescue StandardError
              end
            end

            results << PlacedImage.new(
              name, file_path, w_in, h_in, x_in, su_y, y_offset, false, nil
            )
          end
        end

        results
      rescue StandardError => e
        Logger.warn("ImageExtractor", "extract_and_place failed on page #{page_num}: #{e.message}")
        []
      end

      # ----------------------------------------------------------------
      # Scan page resources for Image XObjects.
      # Returns { name => { obj_num:, width:, height:, bpc:,
      #                     color_space:, filter:, obj_ref: } }
      # ----------------------------------------------------------------
      def self.scan_image_xobjects(pdf_parser, page_num)
        images = {}
        page_ref = pdf_parser.instance_variable_get(:@pages)[page_num - 1]
        return images unless page_ref

        page_obj  = pdf_parser.resolve_object(page_ref)
        page_dict = to_dict(pdf_parser, page_obj)
        return images unless page_dict

        resources  = find_inherited(pdf_parser, page_dict, '/Resources')
        res_dict   = to_dict(pdf_parser, pdf_parser.resolve_object(resources))
        return images unless res_dict.is_a?(Hash)

        xobj_ref  = res_dict['/XObject']
        return images unless xobj_ref

        xobj_dict = to_dict(pdf_parser, pdf_parser.resolve_object(xobj_ref))
        return images unless xobj_dict.is_a?(Hash)

        xobj_dict.each do |name, ref|
          next unless ref.is_a?(String) && ref =~ /\A\d+\s+\d+\s+R\z/

          obj     = pdf_parser.resolve_object(ref)
          obj_d   = to_dict(pdf_parser, obj)
          next unless obj_d.is_a?(Hash)
          next unless obj_d['/Subtype'] == '/Image'

          obj_num = ref.to_s.split(' ').first.to_i
          w = safe_int(obj_d['/Width']  || obj_d['Width'])
          h = safe_int(obj_d['/Height'] || obj_d['Height'])
          bpc = safe_int(obj_d['/BitsPerComponent'] || obj_d['BitsPerComponent'] || 8)
          cs  = obj_d['/ColorSpace'] || obj_d['ColorSpace']

          # Normalise /Filter — may be a name or an array.
          filter_raw = obj_d['/Filter'] || obj_d['Filter']
          filter = normalise_filter(filter_raw)

          next if (w || 0) <= 0 || (h || 0) <= 0

          # Pixel budget guard
          if w * h > MAX_IMAGE_PIXELS
            Logger.warn("ImageExtractor",
              "Page #{page_num}: skipping #{name} — too large (#{w}×#{h} px)")
            next
          end

          clean_name = name.to_s.sub(/\A\//, '')
          images[clean_name] = {
            obj_num:     obj_num,
            obj_ref:     ref,
            width:       w,
            height:      h,
            bpc:         bpc,
            color_space: cs,
            filter:      filter
          }
        end

        images
      rescue StandardError => e
        Logger.warn("ImageExtractor", "scan_image_xobjects failed: #{e.message}")
        {}
      end

      # ----------------------------------------------------------------
      # Track the CTM (current transformation matrix) at each Do call
      # for image XObjects in the content streams.
      # Returns { name => [ [a,b,c,d,e,f], ... ] }
      # ----------------------------------------------------------------
      def self.track_image_placements(streams, image_names)
        name_set   = image_names.to_a.map(&:to_s).to_set
        placements = {}
        ctm_stack  = [[1.0, 0.0, 0.0, 1.0, 0.0, 0.0]]
        current    = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
        operands   = []

        token_limit = 500_000
        token_count = 0

        Array(streams).each do |stream|
          next unless stream.is_a?(String)
          tokens = tokenize_stream(stream)
          tokens.each do |tok|
            token_count += 1
            break if token_count > token_limit

            case tok[:type]
            when :operator
              case tok[:value]
              when 'q'
                ctm_stack.push(current.dup)
              when 'Q'
                current = ctm_stack.pop || [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
              when 'cm'
                nums = operands.select { |t| t[:type] == :number }.map { |t| t[:value].to_f }
                if nums.length >= 6
                  current = multiply_matrices(
                    [nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]],
                    current
                  )
                end
              when 'Do'
                name_tok = operands.find { |t| t[:type] == :name }
                if name_tok
                  n = name_tok[:value].to_s.sub(/\A\//, '')
                  if name_set.include?(n)
                    placements[n] ||= []
                    placements[n] << current.dup
                  end
                end
              end
              operands.clear
            else
              operands << tok
            end
          end
        end

        placements
      rescue StandardError => e
        Logger.warn("ImageExtractor", "track_image_placements failed: #{e.message}")
        {}
      end

      # ----------------------------------------------------------------
      # Decode and write an image XObject to a temp file.
      # Returns [file_path, format_string] or nil on failure/unsupported.
      # ----------------------------------------------------------------
      def self.write_image_temp(img_info, name, page_num)
        obj_num = img_info[:obj_num]
        filter  = img_info[:filter]
        w       = img_info[:width]
        h       = img_info[:height]
        bpc     = img_info[:bpc] || 8

        # We need the raw (pre-defilter) stream bytes for JPEG/JPX,
        # and the decoded bytes for raw/Flate images.
        # XObjectParser.get_stream_data already applies FlateDecode.
        # For JPEG we want the raw compressed bytes directly.

        case filter
        when '/DCTDecode', 'DCTDecode'
          # JPEG — write raw stream bytes directly.
          raw = get_raw_stream_bytes(img_info)
          return nil unless raw && raw.length > 4
          path = temp_path(name, page_num, 'jpg')
          File.binwrite(path, raw)
          return [path, 'JPEG']

        when '/JPXDecode', 'JPXDecode'
          # JPEG 2000 — write raw bytes. SketchUp may handle .jpg extension.
          raw = get_raw_stream_bytes(img_info)
          return nil unless raw && raw.length > 0
          path = temp_path(name, page_num, 'jpg')
          File.binwrite(path, raw)
          return [path, 'JP2']

        when '/FlateDecode', 'FlateDecode', nil, ''
          # Deflate-compressed or unfiltered raw pixels → write as PNG.
          decoded = img_info[:decoded_bytes]
          return nil unless decoded && decoded.length > 0
          path = temp_path(name, page_num, 'png')
          cs  = img_info[:color_space]
          channels = channels_for_colorspace(cs)
          ok = write_png(path, w, h, bpc, channels, decoded)
          return [path, 'PNG'] if ok

        else
          # JBIG2, CCITTFax, LZW, etc. — not supported.
          Logger.warn("ImageExtractor",
            "Page #{page_num}: #{name} uses unsupported filter #{filter} — skipped.")
          return nil
        end

        nil
      rescue StandardError => e
        Logger.warn("ImageExtractor", "write_image_temp failed for #{name}: #{e.message}")
        nil
      end

      # ----------------------------------------------------------------
      # Write a minimal PNG file from raw pixel bytes.
      # Handles 1/8/16 bpc, 1/3/4 channel images.
      # ----------------------------------------------------------------
      ZLIB_BEST_SPEED = 1

      def self.write_png(path, w, h, bpc, channels, pixels)
        bpc = bpc.to_i
        bpc = 8 unless [1, 8, 16].include?(bpc)
        channels = channels.to_i
        channels = 3 if channels < 1 || channels > 4

        color_type = case channels
                     when 1 then 0   # grayscale
                     when 2 then 4   # grayscale+alpha
                     when 3 then 2   # RGB
                     when 4 then 6   # RGBA
                     else 2
                     end

        bytes_per_sample = bpc <= 8 ? 1 : 2
        stride = w * channels * bytes_per_sample

        # Build PNG IDAT: one filter byte (0=None) per row.
        raw_rows = String.new("", encoding: 'BINARY')
        h.times do |row|
          raw_rows << "\x00"
          raw_rows << (pixels.byteslice(row * stride, stride) || "")
        end

        idat_data = Zlib::Deflate.deflate(raw_rows, ZLIB_BEST_SPEED)

        File.open(path, 'wb') do |f|
          f.write("\x89PNG\r\n\x1A\n")  # PNG signature

          # IHDR
          ihdr_data = [w, h, bpc, color_type, 0, 0, 0].pack('NNCCCCC')
          write_png_chunk(f, 'IHDR', ihdr_data)

          # IDAT
          write_png_chunk(f, 'IDAT', idat_data)

          # IEND
          write_png_chunk(f, 'IEND', '')
        end
        true
      rescue StandardError => e
        Logger.warn("ImageExtractor", "write_png failed: #{e.message}")
        false
      end

      def self.write_png_chunk(io, type, data)
        data = data.to_s.b
        io.write([data.bytesize].pack('N'))
        io.write(type)
        io.write(data)
        crc = Zlib.crc32(data, Zlib.crc32(type))
        io.write([crc].pack('N'))
      end

      # ----------------------------------------------------------------
      # Attach decoded_bytes to each image entry before calling
      # write_image_temp. Call this after get_stream_data.
      # ----------------------------------------------------------------
      def self.decode_image_bytes(pdf_parser, img_info)
        filter = img_info[:filter]
        obj_num = img_info[:obj_num]

        case filter
        when '/DCTDecode', 'DCTDecode', '/JPXDecode', 'JPXDecode'
          # For lossy formats we need the raw (encoded) bytes, not decoded.
          img_info[:raw_bytes] = get_raw_stream_bytes_by_num(pdf_parser, obj_num)
        else
          # For Flate or unfiltered, use the parser's decoder.
          img_info[:decoded_bytes] = pdf_parser.get_stream_data(obj_num)
        end
        img_info
      end

      # ----------------------------------------------------------------
      # Private helpers
      # ----------------------------------------------------------------
      def self.get_raw_stream_bytes(img_info)
        img_info[:raw_bytes]
      end

      def self.get_raw_stream_bytes_by_num(pdf_parser, obj_num)
        raw = pdf_parser.send(:get_raw_object, obj_num)
        return nil unless raw && raw.include?('stream')
        start = raw.index(/stream\r?\n/)
        return nil unless start
        start += raw[start..].match(/stream\r?\n/)[0].length
        len = pdf_parser.send(:parse_stream_length, raw)
        if len && len > 0 && start + len <= raw.bytesize
          raw.byteslice(start, len)
        else
          endpos = raw.index('endstream', start) || raw.length
          raw[start...endpos].sub(/\r?\n\z/, '')
        end
      rescue StandardError => e
        Logger.warn("ImageExtractor", "get_raw_stream_bytes_by_num failed: #{e.message}")
        nil
      end

      def self.temp_path(name, page_num, ext)
        safe = name.to_s.gsub(/[^A-Za-z0-9_-]/, '_')
        File.join(Dir.tmpdir, "bc_img_p#{page_num}_#{safe}_#{Process.pid}.#{ext}")
      end

      def self.channels_for_colorspace(cs)
        case cs.to_s
        when /DeviceGray|CalGray|Indexed/i then 1
        when /DeviceRGB|CalRGB|sRGB/i      then 3
        when /DeviceCMYK/i                  then 4
        else 3
        end
      end

      def self.normalise_filter(raw)
        if raw.is_a?(Array)
          # Take the outermost filter (last applied when decoding).
          raw.first.to_s
        else
          raw.to_s
        end
      end

      def self.safe_int(val)
        return nil unless val
        val.to_s.to_i
      rescue StandardError
        nil
      end

      def self.to_dict(pdf_parser, obj)
        return obj if obj.is_a?(Hash)
        if obj.is_a?(String) && obj.include?('<<')
          begin
            pdf_parser.send(:parse_dict_string, obj)
          rescue StandardError
            nil
          end
        end
      end

      MAX_INHERIT_DEPTH = 32

      def self.find_inherited(pdf_parser, dict, key, depth = 0)
        return dict[key] if dict.is_a?(Hash) && dict[key]
        return nil if depth >= MAX_INHERIT_DEPTH
        if dict.is_a?(Hash) && dict['/Parent']
          parent = pdf_parser.resolve_object(dict['/Parent'])
          pd = to_dict(pdf_parser, parent)
          return find_inherited(pdf_parser, pd, key, depth + 1) if pd
        end
        nil
      end

      def self.multiply_matrices(m1, m2)
        [
          m1[0] * m2[0] + m1[1] * m2[2],
          m1[0] * m2[1] + m1[1] * m2[3],
          m1[2] * m2[0] + m1[3] * m2[2],
          m1[2] * m2[1] + m1[3] * m2[3],
          m1[4] * m2[0] + m1[5] * m2[2] + m2[4],
          m1[4] * m2[1] + m1[5] * m2[3] + m2[5]
        ]
      end

      def self.tokenize_stream(stream)
        # Minimal tokenizer — only needs to track q/Q/cm/Do and operand names/numbers.
        tokens = []
        i      = 0
        len    = stream.length
        while i < len
          c = stream[i]
          if c =~ /[\s\x00]/; i += 1; next; end
          if c == '%'; i = (stream.index(/[\r\n]/, i) || len) + 1; next; end

          if c == '('
            depth = 1; j = i + 1
            while j < len && depth > 0
              stream[j] == '\\' ? j += 2 : (depth += (stream[j] == '(' ? 1 : (stream[j] == ')' ? -1 : 0)); j += 1)
            end
            tokens << { type: :string, value: stream[i...j] }; i = j; next
          end

          if c == '<'
            if i + 1 < len && stream[i + 1] == '<'
              depth = 1; j = i + 2
              while j < len - 1 && depth > 0
                if stream[j, 2] == '<<'; depth += 1; j += 2
                elsif stream[j, 2] == '>>'; depth -= 1; j += 2
                else j += 1
                end
              end
              tokens << { type: :dict, value: stream[i...j] }; i = j; next
            else
              j = (stream.index('>', i) || len)
              tokens << { type: :hex_string, value: stream[i..j] }; i = j + 1; next
            end
          end

          if c == '['
            depth = 1; j = i + 1
            while j < len && depth > 0
              depth += (stream[j] == '[' ? 1 : (stream[j] == ']' ? -1 : 0)); j += 1
            end
            tokens << { type: :array, value: stream[i...j] }; i = j; next
          end

          if c == '/'
            j = i + 1
            while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/; j += 1; end
            tokens << { type: :name, value: stream[i...j] }; i = j; next
          end

          # Skip BI...EI inline image data
          j = i
          while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/; j += 1; end
          if j == i; i += 1; next; end
          word = stream[i...j]

          if word == 'BI'
            id_pos = stream.index(/\sID[\s\n\r]/, j)
            if id_pos
              ei_pos = stream.index(/[\s\n\r]EI(?=[\s\n\r\/\[<])/, id_pos + 3)
              i = ei_pos ? ei_pos + 3 : len
            else
              i = j
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
      rescue StandardError
        []
      end

    end
  end
end
