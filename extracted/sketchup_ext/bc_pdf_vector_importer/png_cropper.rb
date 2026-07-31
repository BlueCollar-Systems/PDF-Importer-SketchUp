# frozen_string_literal: true

require 'zlib'
require 'digest'
require 'json'
require 'open3'
require File.join(File.dirname(__FILE__), 'representation_fidelity')

module BlueCollarSystems
  module PDFVectorImporter
    # Streaming, dependency-free crop support for pdftocairo's 8-bit RGBA PNG.
    # A page is decoded once to a temporary raw RGBA file; every text-span crop
    # then seeks only the rows it owns. This stays compatible with Ruby 2.2 and
    # avoids launching a PDF renderer (or hashing the PDF) for every item.
    module PngCropper
      SIGNATURE = "\x89PNG\r\n\x1a\n".dup
      SIGNATURE.force_encoding(Encoding::BINARY) if
        SIGNATURE.respond_to?(:force_encoding)
      INFLATE_INPUT_SLICE_BYTES = 4096

      module_function

      def native_decoder_path
        File.join(
          File.dirname(__FILE__), 'native', 'png_rgba_decoder.exe'
        )
      end

      def prepare_rgba!(png_path, raw_path, require_alpha = true,
                        native_helper = :default)
        helper = native_helper == :default ? native_decoder_path : native_helper
        native_failure = nil
        if helper && File.file?(helper.to_s)
          begin
            return prepare_rgba_native!(
              png_path, raw_path, helper, require_alpha
            )
          rescue RepresentationFidelity::ContractError => error
            native_failure = error.message
            delete_file(raw_path)
          rescue StandardError => error
            native_failure = "native RGBA preparation failed: #{error.message}"
            delete_file(raw_path)
          end
        end

        prepared = prepare_rgba_ruby!(png_path, raw_path, require_alpha)
        prepared[:decoder_backend] = :ruby_zlib
        prepared[:native_decoder_fallback_reason] = native_failure if
          native_failure
        prepared
      end

      # Decode and hash a complete PNG without materializing a random-access
      # RGBA file. Full-page Raster and saved-host texture verification only
      # need physical pixels, dimensions, visibility, and the canonical digest;
      # item Raster cropping continues to use prepare_rgba! above.
      def inspect_pixels!(png_path, require_alpha = true,
                          native_helper = :default)
        helper = native_helper == :default ? native_decoder_path : native_helper
        native_failure = nil
        if helper && File.file?(helper.to_s)
          begin
            return inspect_pixels_native!(
              png_path, helper, require_alpha
            )
          rescue RepresentationFidelity::ContractError => error
            native_failure = error.message
          rescue StandardError => error
            native_failure = "native PNG inspection failed: #{error.message}"
          end
        end

        inspected = inspect_pixels_ruby!(png_path, require_alpha)
        inspected[:decoder_backend] = :ruby_zlib_stream
        inspected[:native_decoder_fallback_reason] = native_failure if
          native_failure
        inspected
      end

      def inspect_pixels_native!(png_path, helper_path, require_alpha = true)
        source = File.expand_path(png_path.to_s)
        raise_contract('PNG source is missing') unless File.file?(source)
        helper = File.expand_path(helper_path.to_s)
        raise_contract('native PNG decoder is unavailable') unless
          File.file?(helper)

        command = [helper, source, '--inspect-only']
        command << '--allow-rgb' unless require_alpha
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          detail = stderr.to_s.strip
          detail = stdout.to_s.strip if detail.empty?
          detail = "exit #{status.exitstatus}" if detail.empty?
          raise_contract("native PNG inspector failed: #{detail}")
        end
        result = begin
          JSON.parse(stdout.to_s)
        rescue JSON::ParserError => error
          raise_contract("native PNG inspector returned invalid JSON: #{error.message}")
        end
        inspected = inspected_result!(source, result)
        inspected[:decoder_backend] = :native_zlib_stream
        inspected
      rescue RepresentationFidelity::ContractError
        raise
      rescue StandardError => error
        raise_contract("native PNG inspection failed: #{error.message}")
      end
      private_class_method :inspect_pixels_native!

      def inspected_result!(source, result)
        width = Integer(result['pixel_width'])
        height = Integer(result['pixel_height'])
        row_bytes = Integer(result['row_bytes'])
        visual_sha = result['visual_pixel_sha256'].to_s.downcase
        unless width > 0 && height > 0 && row_bytes == width * 4 &&
               visual_sha =~ /\A[0-9a-f]{64}\z/
          raise_contract('PNG pixel inspection contract is invalid')
        end
        {
          :png_path => source,
          :pixel_width => width,
          :pixel_height => height,
          :row_bytes => row_bytes,
          :alpha_channel_verified =>
            result['alpha_channel_verified'] == true,
          :transparent_pixel_present =>
            result['transparent_pixel_present'] == true,
          :visible_pixel_present => result['visible_pixel_present'] == true,
          :visual_pixel_sha256 => visual_sha,
          :content_sha256 => Digest::SHA256.file(source).hexdigest,
          :content_byte_size => File.size(source).to_i,
          :temp_bytes_written => 0
        }
      rescue RepresentationFidelity::ContractError
        raise
      rescue StandardError => error
        raise_contract("PNG pixel inspection contract is invalid: #{error.message}")
      end
      private_class_method :inspected_result!

      def prepare_rgba_native!(png_path, raw_path, helper_path,
                               require_alpha = true)
        source = File.expand_path(png_path.to_s)
        raw = File.expand_path(raw_path.to_s)
        raise_contract('PNG source is missing') unless File.file?(source)
        helper = File.expand_path(helper_path.to_s)
        raise_contract('native PNG decoder is unavailable') unless
          File.file?(helper)

        command = [helper, source, raw]
        command << '--allow-rgb' unless require_alpha
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          detail = stderr.to_s.strip
          detail = stdout.to_s.strip if detail.empty?
          detail = "exit #{status.exitstatus}" if detail.empty?
          raise_contract("native PNG decoder failed: #{detail}")
        end
        begin
          result = JSON.parse(stdout.to_s)
        rescue JSON::ParserError => error
          raise_contract("native PNG decoder returned invalid JSON: #{error.message}")
        end
        width = Integer(result['pixel_width'])
        height = Integer(result['pixel_height'])
        row_bytes = Integer(result['row_bytes'])
        expected_size = width * height * 4
        visual_sha = result['visual_pixel_sha256'].to_s.downcase
        unless width > 0 && height > 0 && row_bytes == width * 4 &&
               File.file?(raw) && File.size(raw) == expected_size &&
               visual_sha =~ /\A[0-9a-f]{64}\z/
          raise_contract('native PNG decoder output contract is invalid')
        end
        {
          :png_path => source,
          :raw_path => raw,
          :pixel_width => width,
          :pixel_height => height,
          :row_bytes => row_bytes,
          :alpha_channel_verified =>
            result['alpha_channel_verified'] == true,
          :transparent_pixel_present =>
            result['transparent_pixel_present'] == true,
          :visible_pixel_present => result['visible_pixel_present'] == true,
          :visual_pixel_sha256 => visual_sha,
          :content_sha256 => Digest::SHA256.file(source).hexdigest,
          :content_byte_size => File.size(source).to_i,
          :decoder_backend => :native_libpng
        }
      rescue RepresentationFidelity::ContractError
        delete_file(raw)
        raise
      rescue StandardError => error
        delete_file(raw)
        raise_contract("native PNG RGBA preparation failed: #{error.message}")
      end
      private_class_method :prepare_rgba_native!

      def prepare_rgba_ruby!(png_path, raw_path, require_alpha = true)
        source = File.expand_path(png_path.to_s)
        raw = File.expand_path(raw_path.to_s)
        raise_contract('PNG source is missing') unless File.file?(source)
        state = {
          :width => nil, :height => nil, :row_bytes => nil,
          :bytes_per_pixel => nil, :color_type => nil,
          :rows => 0, :previous => nil, :pending => binary_string,
          :transparent => false, :visible => false,
          :visual_digest => Digest::SHA256.new
        }
        inflater = nil
        seen_iend = false
        File.open(source, 'rb') do |input|
          raise_contract('PNG signature is invalid') unless
            input.read(8) == SIGNATURE
          File.open(raw, 'wb') do |output|
            loop do
              length_bytes = input.read(4)
              break if length_bytes.nil? || length_bytes.empty?
              raise_contract('PNG chunk length is truncated') unless
                length_bytes.bytesize == 4
              length = length_bytes.unpack('N')[0]
              raise_contract('PNG chunk is unreasonably large') if
                length < 0 || length > 268_435_456
              type = input.read(4)
              data = input.read(length)
              crc_bytes = input.read(4)
              unless type && type.bytesize == 4 && data &&
                     data.bytesize == length && crc_bytes &&
                     crc_bytes.bytesize == 4
                raise_contract('PNG chunk is truncated')
              end
              expected_crc = crc_bytes.unpack('N')[0]
              actual_crc = Zlib.crc32(type + data)
              raise_contract("PNG #{type} CRC is invalid") unless
                expected_crc == actual_crc

              case type
              when 'IHDR'
                read_ihdr!(state, data, require_alpha)
              when 'IDAT'
                raise_contract('PNG IDAT precedes IHDR') unless state[:row_bytes]
                inflater ||= Zlib::Inflate.new
                inflate_png_data!(inflater, data, state, output)
              when 'IEND'
                if inflater
                  state[:pending] << inflater.finish
                  consume_scanlines!(state, output)
                end
                seen_iend = true
                break
              end
            end
          end
        end
        unless seen_iend && state[:width] && state[:height] &&
               state[:rows] == state[:height] && state[:pending].empty?
          raise_contract('PNG scanline stream is incomplete or oversized')
        end
        {
          :png_path => source,
          :raw_path => raw,
          :pixel_width => state[:width],
          :pixel_height => state[:height],
          :row_bytes => state[:row_bytes],
          :alpha_channel_verified => state[:color_type] == 6,
          :transparent_pixel_present => state[:transparent],
          :visible_pixel_present => state[:visible],
          :visual_pixel_sha256 => state[:visual_digest].hexdigest,
          :content_sha256 => Digest::SHA256.file(source).hexdigest,
          :content_byte_size => File.size(source).to_i
        }
      rescue RepresentationFidelity::ContractError
        delete_file(raw)
        raise
      rescue StandardError => error
        delete_file(raw)
        raise_contract("PNG RGBA preparation failed: #{error.message}")
      ensure
        begin
          inflater.close if inflater
        rescue StandardError
          # zlib resources are best-effort after the authoritative result.
        end
      end
      private_class_method :prepare_rgba_ruby!

      def inspect_pixels_ruby!(png_path, require_alpha = true)
        source = File.expand_path(png_path.to_s)
        raise_contract('PNG source is missing') unless File.file?(source)
        state = {
          :width => nil, :height => nil, :row_bytes => nil,
          :bytes_per_pixel => nil, :color_type => nil,
          :rows => 0, :previous => nil, :pending => binary_string,
          :transparent => false, :visible => false,
          :visual_digest => Digest::SHA256.new
        }
        inflater = nil
        seen_iend = false
        File.open(source, 'rb') do |input|
          raise_contract('PNG signature is invalid') unless
            input.read(8) == SIGNATURE
          loop do
            length_bytes = input.read(4)
            break if length_bytes.nil? || length_bytes.empty?
            raise_contract('PNG chunk length is truncated') unless
              length_bytes.bytesize == 4
            length = length_bytes.unpack('N')[0]
            raise_contract('PNG chunk is unreasonably large') if
              length < 0 || length > 268_435_456
            type = input.read(4)
            data = input.read(length)
            crc_bytes = input.read(4)
            unless type && type.bytesize == 4 && data &&
                   data.bytesize == length && crc_bytes &&
                   crc_bytes.bytesize == 4
              raise_contract('PNG chunk is truncated')
            end
            expected_crc = crc_bytes.unpack('N')[0]
            actual_crc = Zlib.crc32(type + data)
            raise_contract("PNG #{type} CRC is invalid") unless
              expected_crc == actual_crc

            case type
            when 'IHDR'
              read_ihdr!(state, data, require_alpha)
            when 'IDAT'
              raise_contract('PNG IDAT precedes IHDR') unless state[:row_bytes]
              inflater ||= Zlib::Inflate.new
              inflate_png_data!(inflater, data, state, nil)
            when 'IEND'
              if inflater
                state[:pending] << inflater.finish
                consume_scanlines!(state, nil)
              end
              seen_iend = true
              break
            end
          end
        end
        unless seen_iend && state[:width] && state[:height] &&
               state[:rows] == state[:height] && state[:pending].empty?
          raise_contract('PNG scanline stream is incomplete or oversized')
        end
        {
          :png_path => source,
          :pixel_width => state[:width],
          :pixel_height => state[:height],
          :row_bytes => state[:width] * 4,
          :alpha_channel_verified => state[:color_type] == 6,
          :transparent_pixel_present => state[:transparent],
          :visible_pixel_present => state[:visible],
          :visual_pixel_sha256 => state[:visual_digest].hexdigest,
          :content_sha256 => Digest::SHA256.file(source).hexdigest,
          :content_byte_size => File.size(source).to_i,
          :temp_bytes_written => 0,
          :decoder_backend => :ruby_zlib_stream
        }
      rescue RepresentationFidelity::ContractError
        raise
      rescue StandardError => error
        raise_contract("PNG pixel inspection failed: #{error.message}")
      ensure
        begin
          inflater.close if inflater
        rescue StandardError
          # zlib resources are best-effort after the authoritative result.
        end
      end
      private_class_method :inspect_pixels_ruby!

      def crop_rgba!(prepared, pixel_crop, output_path)
        unless prepared.is_a?(Hash) && File.file?(prepared[:raw_path].to_s)
          raise_contract('prepared RGBA page is unavailable')
        end
        crop = Array(pixel_crop).map { |value| Integer(value) }
        raise_contract('RGBA crop must contain four integers') unless
          crop.length == 4
        x, y, width, height = crop
        page_width = Integer(prepared[:pixel_width])
        page_height = Integer(prepared[:pixel_height])
        unless x >= 0 && y >= 0 && width > 0 && height > 0 &&
               x + width <= page_width && y + height <= page_height
          raise_contract('RGBA crop is outside the rendered page')
        end

        compressed = binary_string
        visual_digest = Digest::SHA256.new
        deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION)
        transparent = false
        visible = false
        File.open(prepared[:raw_path].to_s, 'rb') do |input|
          height.times do |row_index|
            offset = (((y + row_index) * page_width) + x) * 4
            input.seek(offset, IO::SEEK_SET)
            row = input.read(width * 4)
            raise_contract('prepared RGBA crop row is truncated') unless
              row && row.bytesize == width * 4
            alpha_index = 3
            while alpha_index < row.bytesize
              alpha = row.getbyte(alpha_index)
              transparent = true if alpha < 255
              visible = true if alpha > 0
              alpha_index += 4
            end
            visual_digest.update(canonical_visual_row(row))
            compressed << deflater.deflate(png_filter_none_row(row))
          end
        end
        compressed << deflater.finish
        unless visible
          raise_contract('item Raster crop contains no visible pixels')
        end
        destination = File.expand_path(output_path.to_s)
        File.open(destination, 'wb') do |file|
          file.write(SIGNATURE)
          write_chunk(file, 'IHDR', [
            width, height, 8, 6, 0, 0, 0
          ].pack('N2C5'))
          write_chunk(file, 'IDAT', compressed)
          write_chunk(file, 'IEND', binary_string)
        end
        {
          :png_path => destination,
          :pixel_width => width,
          :pixel_height => height,
          :alpha_channel_verified => true,
          # This proves that the exact crop retained the RGBA channel supplied
          # by the transparent page render. A crop may legitimately be fully
          # covered by opaque source ink; requiring an alpha<255 pixel inside
          # every crop would reject valid source content.
          :transparent_background_verified => true,
          :transparent_pixel_present => transparent,
          :visible_pixel_verified => visible,
          :visual_pixel_sha256 => visual_digest.hexdigest,
          :page_render_once_verified => true,
          :page_render_content_sha256 => prepared[:content_sha256].to_s,
          :content_sha256 => Digest::SHA256.file(destination).hexdigest,
          :content_byte_size => File.size(destination).to_i
        }
      rescue RepresentationFidelity::ContractError
        delete_file(output_path)
        raise
      rescue StandardError => error
        delete_file(output_path)
        raise_contract("PNG RGBA crop failed: #{error.message}")
      ensure
        begin
          deflater.close if deflater
        rescue StandardError
          # zlib resources are best-effort after the authoritative result.
        end
      end

      def read_ihdr!(state, data, require_alpha)
        raise_contract('PNG IHDR size is invalid') unless data.bytesize == 13
        width, height, depth, color, compression, filter, interlace =
          data.unpack('N2C5')
        supported_color = color == 6 || (!require_alpha && color == 2)
        unless width > 0 && height > 0 && depth == 8 && supported_color &&
               compression == 0 && filter == 0 && interlace == 0
          raise_contract(
            require_alpha ?
              'item Raster page must be a noninterlaced 8-bit RGBA PNG' :
              'texture export must be a noninterlaced 8-bit RGB/RGBA PNG'
          )
        end
        raise_contract('PNG contains duplicate IHDR chunks') if state[:width]
        state[:width] = width
        state[:height] = height
        state[:color_type] = color
        state[:bytes_per_pixel] = color == 6 ? 4 : 3
        state[:row_bytes] = width * state[:bytes_per_pixel]
      end
      private_class_method :read_ihdr!

      def inflate_png_data!(inflater, data, state, output)
        offset = 0
        while offset < data.bytesize
          chunk = data.byteslice(offset, INFLATE_INPUT_SLICE_BYTES)
          state[:pending] << inflater.inflate(chunk)
          consume_scanlines!(state, output)
          offset += chunk.bytesize
        end
      end
      private_class_method :inflate_png_data!

      def consume_scanlines!(state, output)
        packet_size = state[:row_bytes] + 1
        pending_offset = 0
        while state[:pending].bytesize - pending_offset >= packet_size &&
              state[:rows] < state[:height]
          packet = state[:pending].byteslice(pending_offset, packet_size)
          pending_offset += packet_size
          filter = packet.getbyte(0)
          row = packet.byteslice(1, state[:row_bytes]).dup
          unfilter!(row, state[:previous], filter, state[:bytes_per_pixel])
          rgba = state[:color_type] == 6 ? row : rgb_to_rgba(row)
          alpha_index = 3
          while alpha_index < rgba.bytesize
            alpha = rgba.getbyte(alpha_index)
            state[:transparent] = true if alpha < 255
            state[:visible] = true if alpha > 0
            alpha_index += 4
          end
          state[:visual_digest].update(canonical_visual_row(rgba))
          output.write(rgba) if output
          state[:previous] = row
          state[:rows] += 1
        end
        if pending_offset > 0
          remaining = state[:pending].bytesize - pending_offset
          state[:pending] = if remaining > 0
                              state[:pending].byteslice(
                                pending_offset, remaining
                              ).dup
                            else
                              binary_string
                            end
        end
      end
      private_class_method :consume_scanlines!

      def rgb_to_rgba(row)
        rgba = binary_string
        opaque = binary_byte(0xff)
        index = 0
        while index < row.bytesize
          rgba << row.byteslice(index, 3) << opaque
          index += 3
        end
        rgba
      end
      private_class_method :rgb_to_rgba

      def png_filter_none_row(row)
        filtered = binary_byte(0x00)
        filtered << row
        filtered
      end
      private_class_method :png_filter_none_row

      def binary_byte(value)
        byte = value.chr
        byte.force_encoding(Encoding::BINARY) if byte.respond_to?(:force_encoding)
        byte
      end
      private_class_method :binary_byte

      def canonical_visual_row(row)
        canonical = binary_string
        index = 0
        while index < row.bytesize
          alpha = row.getbyte(index + 3)
          canonical << [
            ((row.getbyte(index) * alpha) + 127) / 255,
            ((row.getbyte(index + 1) * alpha) + 127) / 255,
            ((row.getbyte(index + 2) * alpha) + 127) / 255,
            alpha
          ].pack('C4')
          index += 4
        end
        canonical
      end
      private_class_method :canonical_visual_row

      def unfilter!(row, previous, filter, bytes_per_pixel)
        index = 0
        while index < row.bytesize
          left = index >= bytes_per_pixel ?
            row.getbyte(index - bytes_per_pixel) : 0
          up = previous ? previous.getbyte(index) : 0
          upper_left = previous && index >= bytes_per_pixel ?
            previous.getbyte(index - bytes_per_pixel) : 0
          predictor = case filter
                      when 0 then 0
                      when 1 then left
                      when 2 then up
                      when 3 then ((left + up) / 2).floor
                      when 4 then paeth(left, up, upper_left)
                      else
                        raise_contract("unsupported PNG row filter #{filter}")
                      end
          row.setbyte(index, (row.getbyte(index) + predictor) & 255)
          index += 1
        end
        row
      end
      private_class_method :unfilter!

      def paeth(left, up, upper_left)
        estimate = left + up - upper_left
        left_distance = (estimate - left).abs
        up_distance = (estimate - up).abs
        diagonal_distance = (estimate - upper_left).abs
        return left if left_distance <= up_distance &&
                       left_distance <= diagonal_distance
        return up if up_distance <= diagonal_distance
        upper_left
      end
      private_class_method :paeth

      def write_chunk(file, type, data)
        payload = type.to_s + data.to_s
        file.write([data.bytesize].pack('N'))
        file.write(payload)
        file.write([Zlib.crc32(payload)].pack('N'))
      end
      private_class_method :write_chunk

      def binary_string
        value = ''.dup
        value.force_encoding(Encoding::BINARY) if value.respond_to?(:force_encoding)
        value
      end
      private_class_method :binary_string

      def delete_file(path)
        File.delete(path.to_s) if path && File.file?(path.to_s)
      rescue StandardError
        nil
      end
      private_class_method :delete_file

      def raw_to_png!(raw_path, width, height, channels, output_path)
        raw = File.expand_path(raw_path.to_s)
        raise_contract('PNG raw source is missing') unless File.file?(raw)
        raise_contract('PNG raw dimensions are invalid') unless width > 0 && height > 0
        raise_contract('PNG raw channel count is invalid') unless [1, 2, 3, 4].include?(channels)
        row_bytes = width * channels
        expected = row_bytes * height
        actual = File.size(raw)
        unless actual == expected
          raise_contract(
            "PNG raw size mismatch for #{width}x#{height}x#{channels}: " \
            "expected #{expected}, got #{actual}"
          )
        end

        color_type = { 1 => 0, 2 => 4, 3 => 2, 4 => 6 }[channels]
        compressed = binary_string
        deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION)
        File.open(raw, 'rb') do |input|
          height.times do
            row = input.read(row_bytes)
            raise_contract('PNG raw row truncated') unless
              row && row.bytesize == row_bytes
            compressed << deflater.deflate(png_filter_none_row(row))
          end
        end
        compressed << deflater.finish

        destination = File.expand_path(output_path.to_s)
        File.open(destination, 'wb') do |file|
          file.write(SIGNATURE)
          write_chunk(file, 'IHDR', [
            width, height, 8, color_type, 0, 0, 0
          ].pack('N2C5'))
          write_chunk(file, 'IDAT', compressed)
          write_chunk(file, 'IEND', binary_string)
        end
        {
          :png_path => destination,
          :pixel_width => width,
          :pixel_height => height,
          :content_sha256 => Digest::SHA256.file(destination).hexdigest,
          :content_byte_size => File.size(destination).to_i
        }
      rescue RepresentationFidelity::ContractError
        delete_file(output_path)
        raise
      rescue StandardError => error
        delete_file(output_path)
        raise_contract("PNG raw-to-png failed: #{error.message}")
      ensure
        begin
          deflater.close if deflater
        rescue StandardError
          nil
        end
      end

      def raise_contract(message)
        raise RepresentationFidelity::ContractError, message.to_s
      end
      private_class_method :raise_contract
    end
  end
end
