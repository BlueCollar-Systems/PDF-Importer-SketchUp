# bc_pdf_vector_importer/embedded_image_extractor.rb
# Extracts PDF Image XObjects as individual files plus metadata.
#
# JPEG/JPX/JBIG2/CCITT streams are preserved in their native encoded form.
# Flate/other decoded image streams are written as raw bytes with enough
# metadata for external tools or later importers to reconstruct the image.
#
# Copyright 2024-2026 BlueCollar Systems -- BUILT. NOT BOUGHT.

require 'fileutils'
require 'json'
require 'zlib'
require_relative 'png_cropper'

module BlueCollarSystems
  module PDFVectorImporter
    class EmbeddedImageExtractor
      MAX_TOKENS_PER_STREAM = 500_000
      MAX_FORM_DEPTH = 12

      ImageAsset = Struct.new(
        :page_number,
        :name,
        :obj_num,
        :placement_index,
        :width,
        :height,
        :bits_per_component,
        :color_space,
        :filters,
        :decode_parms,
        :ctm,
        :corners_pts,
        :bbox_pts,
        :file_path,
        :metadata_path,
        :bytes_written,
        :encoded
      )

      attr_reader :assets

      def initialize(pdf_parser, output_dir = nil)
        @pdf = pdf_parser
        @output_dir = output_dir
        @assets = []
        @sequence = 0
      end

      def extract_page(page_num, output_dir = @output_dir, write_files = true)
        @assets = []
        @sequence = 0

        raw = @pdf.page_data(page_num)
        return [] unless raw

        resources = page_resources(page_num)
        streams = raw[:content_streams] || []
        walk_streams(
          page_num,
          streams,
          resources,
          identity_matrix,
          output_dir,
          write_files,
          {},
          0
        )
        @assets
      end

      def self.supported_sketchup_image?(path)
        ext = File.extname(path.to_s).downcase
        ['.jpg', '.jpeg', '.png'].include?(ext)
      end

      private

      def page_resources(page_num)
        if @pdf.respond_to?(:page_resources)
          return @pdf.page_resources(page_num)
        end

        pages = @pdf.instance_variable_get(:@pages)
        return {} unless pages && pages[page_num - 1]

        page_obj = @pdf.resolve_object(pages[page_num - 1])
        page_dict = to_dict(page_obj)
        return {} unless page_dict

        resources_ref = find_inherited(page_dict, '/Resources')
        resources = to_dict(@pdf.resolve_object(resources_ref))
        resources || {}
      rescue StandardError => e
        Logger.warn('EmbeddedImages', "page resource scan failed: #{e.message}")
        {}
      end

      def find_inherited(dict, key, depth = 0)
        return nil unless dict
        return dict[key] if dict[key]
        return nil if depth >= 32
        return nil unless dict['/Parent']

        parent = @pdf.resolve_object(dict['/Parent'])
        parent_dict = to_dict(parent)
        find_inherited(parent_dict, key, depth + 1)
      end

      def walk_streams(page_num, streams, resources, initial_ctm, output_dir, write_files, seen_forms, depth)
        return if depth > MAX_FORM_DEPTH

        Array(streams).each do |stream|
          next unless stream
          tokens = tokenize_stream(stream)
          operands = []
          ctm_stack = [initial_ctm.dup]
          current_ctm = initial_ctm.dup

          tokens.each do |tok|
            if tok[:type] == :operator
              case tok[:value]
              when 'q'
                ctm_stack << current_ctm.dup
              when 'Q'
                current_ctm = ctm_stack.pop || initial_ctm.dup
              when 'cm'
                nums = operands.select { |t| t[:type] == :number }.map { |t| t[:value] }
                if nums.length >= 6
                  current_ctm = multiply_matrices(
                    [nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]],
                    current_ctm
                  )
                end
              when 'Do'
                name_tok = operands.reverse.find { |t| t[:type] == :name }
                handle_xobject_do(
                  page_num,
                  name_tok ? name_tok[:value] : nil,
                  resources,
                  current_ctm,
                  output_dir,
                  write_files,
                  seen_forms,
                  depth
                )
              end
              operands = []
            else
              operands << tok
            end
          end
        end
      end

      def handle_xobject_do(page_num, raw_name, resources, current_ctm, output_dir, write_files, seen_forms, depth)
        clean_name = raw_name.to_s.sub(/\A\//, '')
        return if clean_name.empty?

        ref = xobject_ref(resources, clean_name)
        return unless ref

        obj_num = ref_obj_num(ref)
        xobj = @pdf.resolve_object(ref)
        dict = to_dict(xobj)
        return unless dict

        subtype = dict['/Subtype'].to_s
        if subtype == '/Image'
          record_image(page_num, clean_name, obj_num, dict, current_ctm, output_dir, write_files)
        elsif subtype == '/Form'
          return unless obj_num
          key = "#{obj_num}:#{depth}"
          return if seen_forms[key]

          seen_forms[key] = true
          form_stream = @pdf.get_stream_data(obj_num)
          return unless form_stream

          form_resources = to_dict(@pdf.resolve_object(dict['/Resources'])) || resources
          form_matrix = parse_array_nums(dict['/Matrix'])
          form_matrix = identity_matrix unless form_matrix && form_matrix.length >= 6
          combined = multiply_matrices(form_matrix, current_ctm)
          walk_streams(
            page_num,
            [form_stream],
            form_resources,
            combined,
            output_dir,
            write_files,
            seen_forms,
            depth + 1
          )
          seen_forms.delete(key)
        end
      rescue StandardError => e
        Logger.warn('EmbeddedImages', "XObject #{raw_name} scan failed: #{e.message}")
      end

      def record_image(page_num, name, obj_num, dict, ctm, output_dir, write_files)
        return unless obj_num

        @sequence += 1
        filters = normalize_filters(dict['/Filter'], obj_num)
        data_info = image_stream_data(obj_num, filters)
        data = data_info[:data]
        return unless data

        corners = unit_image_corners(ctm)
        bbox = bbox_for(corners)
        asset = ImageAsset.new(
          page_num,
          name,
          obj_num,
          @sequence,
          int_value(dict['/Width']),
          int_value(dict['/Height']),
          int_value(dict['/BitsPerComponent']),
          normalize_pdf_value(dict['/ColorSpace']),
          filters,
          normalize_pdf_value(dict['/DecodeParms']),
          normalize_matrix(ctm),
          corners,
          bbox,
          nil,
          nil,
          data.bytesize,
          data_info[:encoded]
        )

        if write_files && output_dir
          write_asset_files(asset, data, output_dir, data_info[:extension])
        end

        @assets << asset
      rescue StandardError => e
        Logger.warn('EmbeddedImages', "image #{name} extraction failed: #{e.message}")
      end

      def write_asset_files(asset, data, output_dir, extension)
        FileUtils.mkdir_p(output_dir)
        base = "page_%03d_image_%03d_%s_obj_%s" % [
          asset.page_number.to_i,
          asset.placement_index.to_i,
          safe_token(asset.name),
          asset.obj_num.to_i
        ]
        image_path = File.join(output_dir, base + extension)
        File.open(image_path, 'wb') { |f| f.write(data) }

        if extension == '.raw' && asset.width > 0 && asset.height > 0
          pixels = asset.width.to_i * asset.height.to_i
          if pixels > 0 && data.bytesize % pixels == 0
            channels = data.bytesize / pixels
            if [1, 2, 3, 4].include?(channels)
              png_path = File.join(output_dir, base + '.png')
              begin
                PngCropper.raw_to_png!(image_path, asset.width, asset.height, channels, png_path)
                image_path = png_path
              rescue StandardError => e
                Logger.warn(
                  'EmbeddedImages',
                  "raw-to-png conversion for #{asset.name} failed: #{e.message}"
                )
              end
            end
          end
        end

        asset.file_path = image_path

        meta_path = File.join(output_dir, base + '.json')
        File.open(meta_path, 'w') do |f|
          f.write(JSON.pretty_generate(metadata_for(asset)) + "\n")
        end
        asset.metadata_path = meta_path
      end

      def metadata_for(asset)
        {
          schema: 'bcs.embedded_image/1.0',
          page: asset.page_number,
          name: asset.name,
          object: asset.obj_num,
          placement_index: asset.placement_index,
          width: asset.width,
          height: asset.height,
          bits_per_component: asset.bits_per_component,
          color_space: asset.color_space,
          filters: asset.filters,
          decode_parms: asset.decode_parms,
          ctm: asset.ctm,
          corners_pts: asset.corners_pts,
          bbox_pts: asset.bbox_pts,
          file: asset.file_path,
          bytes_written: asset.bytes_written,
          encoded: asset.encoded
        }
      end

      def image_stream_data(obj_num, filters)
        terminal = terminal_image_filter(filters)
        raw = raw_stream_bytes(obj_num)
        return { data: nil, extension: '.bin', encoded: false } unless raw

        if terminal
          data = decode_lossless_prefix(raw, filters, terminal)
          return {
            data: data,
            extension: extension_for_filter(terminal),
            encoded: true
          }
        end

        decoded = begin
          @pdf.get_stream_data(obj_num)
        rescue StandardError
          nil
        end
        decoded ||= raw
        {
          data: decoded,
          extension: '.raw',
          encoded: false
        }
      end

      def terminal_image_filter(filters)
        Array(filters).find do |filter|
          ['/DCTDecode', '/JPXDecode', '/JBIG2Decode', '/CCITTFaxDecode'].include?(filter)
        end
      end

      def extension_for_filter(filter)
        case filter
        when '/DCTDecode' then '.jpg'
        when '/JPXDecode' then '.jp2'
        when '/JBIG2Decode' then '.jb2'
        when '/CCITTFaxDecode' then '.ccitt'
        else '.bin'
        end
      end

      def decode_lossless_prefix(data, filters, terminal)
        out = data
        Array(filters).each do |filter|
          break if filter == terminal
          out = decode_lossless_filter(out, filter)
          break unless out
        end
        out
      end

      def decode_lossless_filter(data, filter)
        case filter
        when '/ASCII85Decode'
          @pdf.ascii85_decode(data)
        when '/ASCIIHexDecode'
          @pdf.ascii_hex_decode(data)
        when '/FlateDecode'
          inflate_data(data)
        when '/RunLengthDecode'
          @pdf.run_length_decode(data)
        else
          data
        end
      end

      def inflate_data(data)
        begin
          Zlib::Inflate.inflate(data)
        rescue Zlib::DataError
          Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(data)
        end
      end

      def raw_stream_bytes(obj_num)
        raw = @pdf.send(:get_raw_object, obj_num)
        return nil unless raw

        marker = /stream\r?\n/.match(raw)
        return nil unless marker

        stream_start = marker.end(0)
        length = begin
          @pdf.send(:parse_stream_length, raw)
        rescue StandardError
          nil
        end

        if length && length > 0 && stream_start + length <= raw.bytesize
          return raw.byteslice(stream_start, length)
        end

        endstream_pos = raw.index('endstream', stream_start)
        return nil unless endstream_pos

        bytes = raw.byteslice(stream_start, endstream_pos - stream_start)
        bytes ? bytes.sub(/\r?\n\z/, '') : nil
      end

      def normalize_filters(value, obj_num = nil)
        filters = []
        if value.is_a?(Array)
          value.each { |v| filters << normalize_filter_name(v) }
        elsif value
          filters << normalize_filter_name(value)
        elsif obj_num
          raw = @pdf.send(:get_raw_object, obj_num)
          if raw
            dict_part = raw[0, raw.index('stream') || 0]
            filters = @pdf.extract_stream_filters(raw, dict_part)
          end
        end
        filters.compact
      rescue StandardError
        []
      end

      def normalize_filter_name(value)
        s = normalize_pdf_value(value).to_s.strip
        return nil if s.empty?
        s.start_with?('/') ? s : "/#{s}"
      end

      def xobject_ref(resources, name)
        return nil unless resources
        xobjs = to_dict(@pdf.resolve_object(resources['/XObject']))
        return nil unless xobjs
        xobjs["/#{name}"] || xobjs[name]
      end

      def ref_obj_num(ref)
        return ref[:obj_num] if ref.is_a?(Hash) && ref[:obj_num]
        if ref.to_s =~ /\A(\d+)\s+(\d+)\s+R\z/
          return $1.to_i
        end
        nil
      end

      def to_dict(obj)
        return obj if obj.is_a?(Hash)
        @pdf.send(:to_dict, obj)
      rescue StandardError
        nil
      end

      def parse_array_nums(value)
        if value.is_a?(Array)
          value.map { |v| v.to_s.to_f }
        elsif value
          @pdf.send(:parse_array_string, value.to_s).map { |v| v.to_s.to_f }
        else
          []
        end
      rescue StandardError
        []
      end

      def int_value(value)
        resolved = @pdf.resolve_object(value)
        resolved.to_i
      rescue StandardError
        value.to_i
      end

      def normalize_pdf_value(value)
        case value
        when Array
          value.map { |v| normalize_pdf_value(v) }
        when Hash
          out = {}
          value.each { |k, v| out[k.to_s] = normalize_pdf_value(v) }
          out
        else
          value.to_s
        end
      end

      def identity_matrix
        [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
      end

      def normalize_matrix(matrix)
        m = matrix.is_a?(Array) ? matrix : identity_matrix
        [
          m[0].to_f, m[1].to_f, m[2].to_f,
          m[3].to_f, m[4].to_f, m[5].to_f
        ]
      end

      def multiply_matrices(m1, m2)
        [
          m1[0] * m2[0] + m1[1] * m2[2],
          m1[0] * m2[1] + m1[1] * m2[3],
          m1[2] * m2[0] + m1[3] * m2[2],
          m1[2] * m2[1] + m1[3] * m2[3],
          m1[4] * m2[0] + m1[5] * m2[2] + m2[4],
          m1[4] * m2[1] + m1[5] * m2[3] + m2[5]
        ]
      end

      def transform_point(pt, matrix)
        x = pt[0].to_f
        y = pt[1].to_f
        [
          matrix[0] * x + matrix[2] * y + matrix[4],
          matrix[1] * x + matrix[3] * y + matrix[5]
        ]
      end

      def unit_image_corners(matrix)
        [[0, 0], [1, 0], [1, 1], [0, 1]].map { |pt| transform_point(pt, matrix) }
      end

      def bbox_for(points)
        xs = points.map { |pt| pt[0].to_f }
        ys = points.map { |pt| pt[1].to_f }
        [xs.min, ys.min, xs.max, ys.max]
      end

      def safe_token(value)
        s = value.to_s.gsub(/[^A-Za-z0-9_.-]+/, '_')
        s.empty? ? 'image' : s
      end

      def tokenize_stream(stream)
        tokens = []
        i = 0
        len = stream.length
        while i < len
          if tokens.length > MAX_TOKENS_PER_STREAM
            Logger.warn('EmbeddedImages', "token limit reached (#{MAX_TOKENS_PER_STREAM})")
            break
          end

          c = stream[i]
          if c =~ /[\s\x00]/
            i += 1
            next
          end
          if c == '%'
            eol = stream.index(/[\r\n]/, i) || len
            i = eol + 1
            next
          end
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
          if c == '<' && (i + 1 >= len || stream[i + 1] != '<')
            j = stream.index('>', i) || len
            tokens << { type: :hex_string, value: stream[i..j] }
            i = j + 1
            next
          end
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
          if c == '/' 
            j = i + 1
            while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/
              j += 1
            end
            tokens << { type: :name, value: stream[i...j] }
            i = j
            next
          end

          j = i
          while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/
            j += 1
          end
          if j == i
            i += 1
            next
          end
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
      end
    end
  end
end
