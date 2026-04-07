# bc_pdf_vector_importer/pdf_parser.rb
# Pure-Ruby PDF parser for extracting page geometry data.
# Handles cross-reference tables, object streams, FlateDecode,
# page trees, MediaBox, and content streams.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    class PDFParser

      attr_reader :page_count, :pages

      def initialize(filepath)
        @filepath = filepath
        @data = nil
        @objects = {}       # obj_num => { :gen, :offset, :raw, :parsed }
        @pages = []         # ordered array of page object references
        @page_count = 0
        @xref_offsets = []
        @trailer = nil
        @font_map_cache = {}
        @ocg_map_cache = {}
      end

      # ---------------------------------------------------------------
      # Top-level parse
      # ---------------------------------------------------------------
      MAX_FILE_SIZE = 500 * 1024 * 1024  # 500 MB

      def parse
        file_size = File.size(@filepath)
        if file_size > MAX_FILE_SIZE
          raise "PDF file too large (#{(file_size / 1024.0 / 1024.0).round(1)} MB). " \
                "Maximum supported size is #{MAX_FILE_SIZE / 1024 / 1024} MB."
        end

        @data = File.binread(@filepath)

        # Validate PDF header
        unless @data[0, 5] == '%PDF-'
          raise "Not a valid PDF file (missing %PDF- header)"
        end

        find_xref
        parse_xref

        # Check for encrypted PDFs — these produce garbage geometry instead
        # of a useful error message if we proceed.
        if @trailer && @trailer['/Encrypt']
          raise "This PDF is encrypted and cannot be imported. " \
                "Please remove the encryption (e.g., print to a new PDF) and try again."
        end

        build_page_list
        @page_count = @pages.length
      end

      # ---------------------------------------------------------------
      # Release the raw file buffer and object cache to free memory.
      # Call this after all pages have been processed.
      # ---------------------------------------------------------------
      def release
        @data = nil
        @objects = {}
        @font_map_cache = {}
        @ocg_map_cache = {}
      end

      # ---------------------------------------------------------------
      # Return data for a given 1-based page number
      # ---------------------------------------------------------------
      def page_data(page_num)
        return nil if page_num < 1 || page_num > @page_count
        page_ref = @pages[page_num - 1]
        page_obj = resolve_object(page_ref)
        return nil unless page_obj

        dict = to_dict(page_obj)
        return nil unless dict

        # Page boxes — may be inherited from parent
        media_box = find_inherited(dict, '/MediaBox')
        media_box = parse_array_nums(media_box) if media_box
        crop_box = find_inherited(dict, '/CropBox')
        crop_box = parse_array_nums(crop_box) if crop_box

        # Content streams
        contents = dict['/Contents']
        streams = []
        if contents
          streams = collect_content_streams(contents)
        end

        { media_box: media_box, crop_box: crop_box, content_streams: streams }
      end

      # ---------------------------------------------------------------
      # Return OCG property map for a page: { "MC0" => "Layer Name", ... }
      # Maps Properties names to their resolved OCG layer names.
      # ---------------------------------------------------------------
      def page_ocg_map(page_num)
        return {} if page_num < 1 || page_num > @page_count
        return @ocg_map_cache[page_num] if @ocg_map_cache.key?(page_num)

        page_ref = @pages[page_num - 1]
        page_obj = resolve_object(page_ref)
        page_dict = to_dict(page_obj)
        return (@ocg_map_cache[page_num] = {}) unless page_dict

        resources = find_inherited(page_dict, '/Resources')
        res_dict = to_dict(resolve_object(resources))
        return (@ocg_map_cache[page_num] = {}) unless res_dict

        props = res_dict['/Properties']
        props_dict = to_dict(resolve_object(props))
        return (@ocg_map_cache[page_num] = {}) unless props_dict.is_a?(Hash)

        result = {}
        props_dict.each do |mc_name, mc_ref|
          # mc_name is like "/MC0", mc_ref points to an OCMD or OCG dict
          ocmd = to_dict(resolve_object(mc_ref))
          next unless ocmd.is_a?(Hash)

          key = mc_name.to_s.sub(/\A\//, '')  # "MC0"

          if ocmd['/Type'] == '/OCG' && ocmd['/Name']
            # Direct OCG reference
            result[key] = ocmd['/Name'].to_s.gsub(/\A\(|\)\z/, '')
          elsif ocmd['/OCGs']
            # OCMD — resolve first OCG for the name
            ocgs_val = resolve_object(ocmd['/OCGs'])
            refs = ocgs_val.is_a?(Array) ? ocgs_val : [ocgs_val]
            refs.each do |ref|
              ocg = to_dict(resolve_object(ref))
              next unless ocg.is_a?(Hash) && ocg['/Name']
              result[key] = ocg['/Name'].to_s.gsub(/\A\(|\)\z/, '')
              break
            end
          end
        end

        @ocg_map_cache[page_num] = result
      end

      # ---------------------------------------------------------------
      # Return ToUnicode font maps for a page keyed by font resource name
      # (example keys: "/F5", "F5"). Each value is:
      #   { map: { byte_string => utf8_string }, code_lengths: [2,1] }
      # ---------------------------------------------------------------
      def page_font_maps(page_num)
        return {} if page_num < 1 || page_num > @page_count
        return @font_map_cache[page_num] if @font_map_cache.key?(page_num)

        page_ref = @pages[page_num - 1]
        page_obj = resolve_object(page_ref)
        page_dict = to_dict(page_obj)
        return (@font_map_cache[page_num] = {}) unless page_dict

        resources = find_inherited(page_dict, '/Resources')
        res_dict = to_dict(resolve_object(resources))
        return (@font_map_cache[page_num] = {}) unless res_dict

        fonts = res_dict['/Font']
        font_dict = to_dict(resolve_object(fonts))
        return (@font_map_cache[page_num] = {}) unless font_dict.is_a?(Hash)

        maps = {}
        font_dict.each do |font_name, font_ref|
          cmap = extract_font_to_unicode_map(font_ref)
          next unless cmap && cmap[:map].is_a?(Hash) && !cmap[:map].empty?

          key = font_name.to_s
          maps[key] = cmap
          maps[key.sub(/\A\//, '')] = cmap
        end

        @font_map_cache[page_num] = maps
      end

      # ---------------------------------------------------------------
      # Resolve an indirect reference "X Y R" to its parsed value
      # ---------------------------------------------------------------
      def resolve_object(ref)
        if ref.is_a?(String) && ref =~ /\A(\d+)\s+(\d+)\s+R\z/
          obj_num = $1.to_i
          return resolve_parsed_object(obj_num)
        end
        ref
      end

      # ---------------------------------------------------------------
      # Decompress a stream given its object number
      # ---------------------------------------------------------------
      def get_stream_data(obj_num)
        raw = get_raw_object(obj_num)
        return nil unless raw

        # Find the stream within the object
        if raw =~ /stream\r?\n/
          stream_start = $~.end(0)
          dict_part = raw[0, raw.index('stream')]
          stream_len = parse_stream_length(raw)
          stream_bytes = nil

          if stream_len && stream_len > 0
            # Use declared /Length when possible. This avoids false early matches
            # when compressed binary data contains the literal word "endstream".
            if stream_start + stream_len <= raw.bytesize
              stream_bytes = raw.byteslice(stream_start, stream_len)
            end
          end

          unless stream_bytes
            # Fallback for malformed length entries.
            endstream_pos = raw.index('endstream', stream_start)
            return nil unless endstream_pos
            stream_bytes = raw[stream_start...endstream_pos]
            stream_bytes = stream_bytes.sub(/\r?\n\z/, '')
          end

          decoded = stream_bytes

          filters = extract_stream_filters(raw, dict_part)
          filters.each do |filter|
            case filter
            when '/ASCII85Decode'
              decoded = ascii85_decode(decoded)
            when '/ASCIIHexDecode'
              decoded = ascii_hex_decode(decoded)
            when '/FlateDecode'
              begin
                decoded = Zlib::Inflate.inflate(decoded)
              rescue Zlib::DataError
                begin
                  # Try raw deflate (no zlib header).
                  decoded = Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(decoded)
                rescue StandardError => e
                  Logger.warn("PdfParser", "FlateDecode failed: #{e.message}")
                  decoded = nil
                end
              rescue StandardError => e
                Logger.warn("PdfParser", "FlateDecode failed: #{e.message}")
                decoded = nil
              end
            when '/RunLengthDecode'
              decoded = run_length_decode(decoded)
            when '/LZWDecode'
              Logger.warn("PdfParser", "LZWDecode is not supported for content streams — skipping stream")
              decoded = nil
            else
              Logger.warn("PdfParser", "Unsupported stream filter #{filter} — skipping stream")
              decoded = nil
            end
            break unless decoded
          end

          return nil unless decoded

          # Apply PNG predictor if specified in DecodeParms
          if dict_part =~ /\/Predictor\s+(\d+)/
            predictor = $1.to_i
            columns = 1
            columns = $1.to_i if dict_part =~ /\/Columns\s+(\d+)/
            if predictor >= 10
              decoded = apply_png_predictor(decoded, columns)
            end
          end

          decoded
        end
      end

      def parse_stream_length(raw_obj)
        dict = tokenize_dict(extract_dict(raw_obj))
        return nil unless dict.is_a?(Hash) && dict['/Length']

        val = resolve_numeric_object(dict['/Length'])
        return nil if val.nil?
        n = val.to_i
        n > 0 ? n : nil
      rescue StandardError => e
        Logger.warn("PdfParser", "stream length parse failed: #{e.message}")
        nil
      end

      def resolve_numeric_object(val)
        case val
        when Numeric
          val
        when String
          s = val.strip
          if s =~ /\A(\d+)\s+(\d+)\s+R\z/
            ref_val = resolve_object(s)
            return resolve_numeric_object(ref_val)
          end
          return s.to_i if s =~ /\A[+-]?\d+\z/
          nil
        else
          nil
        end
      rescue StandardError
        nil
      end

      def extract_stream_filters(raw_obj, dict_part)
        filters = []

        begin
          dict = tokenize_dict(extract_dict(raw_obj))
          f = dict['/Filter'] if dict.is_a?(Hash)
          if f.is_a?(Array)
            f.each { |v| filters << normalize_filter_name(v) }
          elsif f
            filters << normalize_filter_name(f)
          end
        rescue StandardError => e
          Logger.warn("PdfParser", "filter parse failed, using regex fallback: #{e.message}")
        end

        # Fallback for malformed dictionaries that fail tokenize_dict.
        if filters.empty?
          if dict_part =~ /\/Filter\s*\[([^\]]+)\]/m
            $1.scan(/\/([A-Za-z0-9]+)/) { |m| filters << "/#{m[0]}" }
          elsif dict_part =~ /\/Filter\s*\/([A-Za-z0-9]+)/m
            filters << "/#{$1}"
          end
        end

        filters.compact.uniq
      end

      def normalize_filter_name(val)
        s = val.to_s.strip
        return nil if s.empty?
        s.start_with?('/') ? s : "/#{s}"
      end

      def ascii85_decode(data)
        src = data.to_s.dup
        src.force_encoding('BINARY')
        src = src.sub(/\A\s*<~/, '')
        src = src.sub(/~>\s*\z/, '')
        src.gsub!(/\s+/, '')

        out = ''.dup.force_encoding('BINARY')
        tuple = []

        src.each_byte do |b|
          if b == 122 # 'z'
            if tuple.empty?
              out << "\x00\x00\x00\x00"
              next
            else
              Logger.warn("PdfParser", "Invalid ASCII85 stream ('z' inside tuple)")
              return nil
            end
          end

          next if b < 33 || b > 117
          tuple << (b - 33)

          if tuple.length == 5
            v = ((((tuple[0] * 85 + tuple[1]) * 85 + tuple[2]) * 85 + tuple[3]) * 85 + tuple[4])
            out << [v].pack('N')
            tuple.clear
          end
        end

        if !tuple.empty?
          pad = 5 - tuple.length
          while tuple.length < 5
            tuple << 84 # 'u' padding
          end
          v = ((((tuple[0] * 85 + tuple[1]) * 85 + tuple[2]) * 85 + tuple[3]) * 85 + tuple[4])
          chunk = [v].pack('N')
          out << chunk[0, 4 - pad]
        end

        out
      rescue StandardError => e
        Logger.warn("PdfParser", "ASCII85 decode failed: #{e.message}")
        nil
      end

      def ascii_hex_decode(data)
        src = data.to_s.gsub(/\s+/, '')
        src = src.sub(/>\z/, '')
        src += '0' if src.length.odd?
        [src].pack('H*')
      rescue StandardError => e
        Logger.warn("PdfParser", "ASCIIHex decode failed: #{e.message}")
        nil
      end

      def run_length_decode(data)
        src = data.to_s
        out = ''.dup.force_encoding('BINARY')
        i = 0
        while i < src.bytesize
          len = src.getbyte(i)
          i += 1
          break if len.nil? || len == 128

          if len <= 127
            count = len + 1
            chunk = src.byteslice(i, count)
            break unless chunk
            out << chunk
            i += count
          else
            count = 257 - len
            b = src.getbyte(i)
            break if b.nil?
            out << b.chr * count
            i += 1
          end
        end
        out
      rescue StandardError => e
        Logger.warn("PdfParser", "RunLength decode failed: #{e.message}")
        nil
      end

      # Apply PNG predictor decoding (predictors 10-15)
      # Each row is [filter_byte, data...] where data is `columns` bytes.
      def apply_png_predictor(data, columns)
        row_size = columns + 1  # 1 byte filter type + columns data bytes
        rows = data.bytesize / row_size
        return data if rows == 0

        out = ''.dup.force_encoding('BINARY')
        prev_row = Array.new(columns, 0)

        rows.times do |r|
          offset = r * row_size
          filter_type = data.getbyte(offset) || 0
          current_row = Array.new(columns) { |c| data.getbyte(offset + 1 + c) || 0 }

          case filter_type
          when 0 # None
            # data as-is
          when 1 # Sub
            (1...columns).each { |c| current_row[c] = (current_row[c] + current_row[c - 1]) & 0xFF }
          when 2 # Up
            columns.times { |c| current_row[c] = (current_row[c] + prev_row[c]) & 0xFF }
          when 3 # Average
            columns.times do |c|
              left = c > 0 ? current_row[c - 1] : 0
              up = prev_row[c]
              current_row[c] = (current_row[c] + ((left + up) / 2)) & 0xFF
            end
          when 4 # Paeth
            columns.times do |c|
              left = c > 0 ? current_row[c - 1] : 0
              up = prev_row[c]
              up_left = c > 0 ? prev_row[c - 1] : 0
              current_row[c] = (current_row[c] + paeth_predict(left, up, up_left)) & 0xFF
            end
          end

          out << current_row.pack('C*')
          prev_row = current_row
        end

        out
      end

      def paeth_predict(a, b, c)
        p = a + b - c
        pa = (p - a).abs
        pb = (p - b).abs
        pc = (p - c).abs
        if pa <= pb && pa <= pc then a
        elsif pb <= pc then b
        else c
        end
      end

      private

      # ---------------------------------------------------------------
      # Find the startxref offset
      # ---------------------------------------------------------------
      def find_xref
        # Search from end of file for startxref
        tail = @data[-1024..-1] || @data
        if tail =~ /startxref\s+(\d+)/
          @xref_offsets << $1.to_i
        else
          raise "Cannot find startxref in PDF"
        end
      end

      # ---------------------------------------------------------------
      # Parse cross-reference table(s) and trailer(s)
      # ---------------------------------------------------------------
      def parse_xref
        @xref_offsets.each do |offset|
          parse_xref_at(offset)
        end
      end

      def parse_xref_at(offset)
        chunk = @data[offset, [40000, @data.length - offset].min]

        if chunk.start_with?('xref')
          parse_traditional_xref(offset)
        else
          # Cross-reference stream (PDF 1.5+)
          parse_xref_stream(offset)
        end
      end

      def parse_traditional_xref(offset)
        chunk = @data[offset..-1]
        lines = chunk.split(/\r?\n|\r/)
        i = 0
        # Skip 'xref' line
        i += 1 if lines[i] && lines[i].strip == 'xref'

        while i < lines.length
          line = lines[i].strip
          break if line.start_with?('trailer') || line.empty? && i > 2 && lines[i-1].strip.start_with?('trailer')

          if line =~ /\A(\d+)\s+(\d+)\z/
            first_obj = $1.to_i
            count = $2.to_i
            count.times do |j|
              i += 1
              entry = lines[i].to_s.strip
              if entry =~ /\A(\d{10})\s+(\d{5})\s+([fn])/
                obj_offset = $1.to_i
                gen = $2.to_i
                in_use = $3 == 'n'
                obj_num = first_obj + j
                if in_use && obj_offset > 0 && !@objects.key?(obj_num)
                  @objects[obj_num] = { gen: gen, offset: obj_offset }
                end
              end
            end
          end
          i += 1
        end

        # Parse trailer
        trailer_idx = chunk.index('trailer')
        trailer_text = trailer_idx ? chunk[trailer_idx..-1] : nil
        if trailer_text
          @trailer ||= parse_trailer_dict(trailer_text)
          # Follow /Prev for incremental updates
          if @trailer['/Prev']
            prev_offset = @trailer['/Prev'].to_i
            unless @xref_offsets.include?(prev_offset)
              @xref_offsets << prev_offset
            end
          end
        end
      end

      def parse_xref_stream(offset)
        # Object number for the xref stream object
        chunk = @data[offset, [10000, @data.length - offset].min]
        if chunk =~ /\A(\d+)\s+(\d+)\s+obj/
          obj_num = $1.to_i
          @objects[obj_num] = { gen: $2.to_i, offset: offset } unless @objects.key?(obj_num)

          # Parse the xref stream dictionary and stream data
          dict_str = extract_dict(chunk)
          dict = tokenize_dict(dict_str)

          @trailer ||= dict

          # Decode the xref stream
          stream_data = get_stream_data(obj_num)
          if stream_data && dict['/W'] && dict['/Size']
            w_array = parse_array_ints(dict['/W'])
            size = dict['/Size'].to_i
            index_array = dict['/Index'] ? parse_array_ints(dict['/Index']) : [0, size]

            pos = 0
            i = 0
            while i < index_array.length
              first_obj = index_array[i]
              count = index_array[i + 1] || 0
              count.times do |j|
                fields = w_array.map do |w|
                  if w == 0
                    0
                  else
                    val = 0
                    w.times do
                      val = (val << 8) | (stream_data.getbyte(pos) || 0)
                      pos += 1
                    end
                    val
                  end
                end

                type = w_array[0] == 0 ? 1 : fields[0]
                on = first_obj + j

                case type
                when 1 # Regular object
                  unless @objects.key?(on)
                    @objects[on] = { gen: fields[2] || 0, offset: fields[1] }
                  end
                when 2 # Compressed object in object stream
                  unless @objects.key?(on)
                    @objects[on] = {
                      gen: 0,
                      offset: nil,
                      in_object_stream: fields[1],
                      index_in_stream: fields[2]
                    }
                  end
                end
              end
              i += 2
            end
          end

          # Follow /Prev
          if dict['/Prev']
            prev_offset = dict['/Prev'].to_i
            unless @xref_offsets.include?(prev_offset)
              @xref_offsets << prev_offset
              parse_xref_at(prev_offset)
            end
          end
        end
      end

      # ---------------------------------------------------------------
      # Page tree traversal
      # ---------------------------------------------------------------
      def build_page_list
        return unless @trailer
        root_ref = @trailer['/Root']
        return unless root_ref

        root = resolve_object(root_ref)
        root_dict = to_dict(root)
        return unless root_dict

        pages_ref = root_dict['/Pages']
        return unless pages_ref

        collect_pages(pages_ref)
      end

      MAX_PAGE_TREE_DEPTH = 64

      def collect_pages(ref, depth = 0)
        return if depth > MAX_PAGE_TREE_DEPTH  # guard against circular refs
        obj = resolve_object(ref)
        dict = to_dict(obj)
        return unless dict

        type = dict['/Type']
        if type == '/Page'
          @pages << ref
        elsif type == '/Pages'
          kids = dict['/Kids']
          if kids.is_a?(Array)
            kids.each { |kid_ref| collect_pages(kid_ref, depth + 1) }
          end
        end
      end

      # ---------------------------------------------------------------
      # Inherited attributes (MediaBox, CropBox, etc.)
      # ---------------------------------------------------------------
      def find_inherited(dict, key, depth = 0)
        return nil if depth > MAX_PAGE_TREE_DEPTH  # guard against circular refs
        return dict[key] if dict[key]
        if dict['/Parent']
          parent = resolve_object(dict['/Parent'])
          parent_dict = to_dict(parent)
          return find_inherited(parent_dict, key, depth + 1) if parent_dict
        end
        nil
      end

      # ---------------------------------------------------------------
      # Content stream collection
      # ---------------------------------------------------------------
      def collect_content_streams(contents)
        resolved = resolve_object(contents)
        if resolved.is_a?(Array)
          # Array of stream references
          resolved.map { |ref|
            r = resolve_object(ref)
            extract_stream_from_value(r, ref)
          }.compact
        elsif resolved.is_a?(String) && resolved =~ /\A(\d+)\s+(\d+)\s+R\z/
          obj_num = $1.to_i
          data = get_stream_data(obj_num)
          data ? [data] : []
        else
          # Single stream reference
          data = extract_stream_from_value(resolved, contents)
          data ? [data] : []
        end
      end

      def extract_stream_from_value(val, original_ref)
        if original_ref.is_a?(String) && original_ref =~ /\A(\d+)\s+(\d+)\s+R\z/
          return get_stream_data($1.to_i)
        end
        nil
      end

      # ---------------------------------------------------------------
      # Object access helpers
      # ---------------------------------------------------------------
      def get_raw_object(obj_num)
        info = @objects[obj_num]
        return nil unless info

        # Object in object stream
        if info[:in_object_stream]
          return get_object_from_object_stream(obj_num, info[:in_object_stream], info[:index_in_stream])
        end

        return nil unless info[:offset]
        offset = info[:offset]
        # Read a chunk starting at offset
        chunk_size = [32768, @data.length - offset].min
        chunk = @data[offset, chunk_size]

        # Find endobj
        endobj_pos = chunk.index('endobj')
        if endobj_pos
          return chunk[0..endobj_pos + 5]
        end

        # If not found in chunk, extend
        extended = @data[offset, [131072, @data.length - offset].min]
        endobj_pos = extended.index('endobj')
        return endobj_pos ? extended[0..endobj_pos + 5] : extended
      end

      def get_object_from_object_stream(obj_num, stream_obj_num, index)
        stream_data = get_stream_data(stream_obj_num)
        return nil unless stream_data

        # Get the object stream dictionary for /N and /First
        raw = get_raw_object(stream_obj_num)
        return nil unless raw
        dict_str = extract_dict(raw)
        dict = tokenize_dict(dict_str)

        n = (dict['/N'] || '0').to_i
        first = (dict['/First'] || '0').to_i

        # Parse the index pairs
        header = stream_data[0, first]
        pairs = header.strip.split(/\s+/).map(&:to_i)

        # Find our object
        target_offset = nil
        i = 0
        while i < pairs.length
          on = pairs[i]
          off = pairs[i + 1]
          if on == obj_num
            target_offset = first + off
            break
          end
          i += 2
        end

        return nil unless target_offset

        # Find the end (next object offset or end of stream)
        next_offset = nil
        i = 0
        while i < pairs.length
          off = pairs[i + 1]
          adjusted = first + off
          if adjusted > target_offset
            next_offset = adjusted if next_offset.nil? || adjusted < next_offset
          end
          i += 2
        end
        next_offset ||= stream_data.length

        stream_data[target_offset...next_offset]
      end

      def resolve_parsed_object(obj_num)
        raw = get_raw_object(obj_num)
        return nil unless raw
        parse_object_value(raw, obj_num)
      end

      # ---------------------------------------------------------------
      # Font / ToUnicode extraction
      # ---------------------------------------------------------------
      def extract_font_to_unicode_map(font_ref)
        font_obj = resolve_object(font_ref)
        font_dict = to_dict(font_obj)
        return nil unless font_dict.is_a?(Hash)

        to_unicode_ref = font_dict['/ToUnicode']

        # Some PDFs may put ToUnicode on descendant font dictionaries.
        if !to_unicode_ref && font_dict['/DescendantFonts'].is_a?(Array)
          font_dict['/DescendantFonts'].each do |desc_ref|
            desc = to_dict(resolve_object(desc_ref))
            if desc && desc['/ToUnicode']
              to_unicode_ref = desc['/ToUnicode']
              break
            end
          end
        end
        return nil unless to_unicode_ref

        stream_data = stream_from_ref(to_unicode_ref)
        return nil unless stream_data && !stream_data.empty?

        parse_tounicode_cmap(stream_data)
      rescue StandardError => e
        Logger.warn("PdfParser", "get_tounicode_map failed: #{e.message}")
        nil
      end

      def stream_from_ref(ref)
        if ref.is_a?(String) && ref =~ /\A(\d+)\s+(\d+)\s+R\z/
          return get_stream_data($1.to_i)
        end

        resolved = resolve_object(ref)
        if resolved.is_a?(String) && resolved =~ /\A(\d+)\s+(\d+)\s+R\z/
          return get_stream_data($1.to_i)
        end

        nil
      end

      def parse_tounicode_cmap(data)
        text = data.to_s.dup
        text.force_encoding(Encoding::BINARY) if text.respond_to?(:force_encoding)

        map = {}
        code_lens = {}

        # beginbfchar ... endbfchar
        text.scan(/beginbfchar(.*?)endbfchar/m).each do |match|
          section = match[0].to_s
          section.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/) do |src_hex, dst_hex|
            src_bytes = [src_hex].pack('H*')
            utf8 = unicode_hex_to_utf8(dst_hex)
            next if utf8.nil? || utf8.empty?
            map[src_bytes] = utf8
            code_lens[src_bytes.bytesize] = true
          end
        end

        # beginbfrange ... endbfrange
        text.scan(/beginbfrange(.*?)endbfrange/m).each do |match|
          section = match[0].to_s
          section.each_line do |line|
            s = line.strip
            next if s.empty?

            # Form: <srcLo> <srcHi> <dstStart>
            if s =~ /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/
              src_lo = $1
              src_hi = $2
              dst_start = $3

              src_lo_i = src_lo.to_i(16)
              src_hi_i = src_hi.to_i(16)
              dst_i = dst_start.to_i(16)
              src_hex_len = [src_lo.length, src_hi.length].max
              dst_hex_len = [dst_start.length, 4].max

              idx = 0
              (src_lo_i..src_hi_i).each do |src_i|
                src_hex = src_i.to_s(16).rjust(src_hex_len, '0')
                src_bytes = [src_hex].pack('H*')
                dst_hex = (dst_i + idx).to_s(16).rjust(dst_hex_len, '0')
                utf8 = unicode_hex_to_utf8(dst_hex)
                unless utf8.nil? || utf8.empty?
                  map[src_bytes] = utf8
                  code_lens[src_bytes.bytesize] = true
                end
                idx += 1
              end
              next
            end

            # Form: <srcLo> <srcHi> [<dst1> <dst2> ...]
            if s =~ /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[(.+)\]/
              src_lo = $1
              src_hi = $2
              arr = $3.to_s
              dsts = arr.scan(/<([0-9A-Fa-f]+)>/).flatten
              next if dsts.empty?

              src_lo_i = src_lo.to_i(16)
              src_hi_i = src_hi.to_i(16)
              src_hex_len = [src_lo.length, src_hi.length].max

              idx = 0
              (src_lo_i..src_hi_i).each do |src_i|
                break if idx >= dsts.length
                src_hex = src_i.to_s(16).rjust(src_hex_len, '0')
                src_bytes = [src_hex].pack('H*')
                utf8 = unicode_hex_to_utf8(dsts[idx])
                unless utf8.nil? || utf8.empty?
                  map[src_bytes] = utf8
                  code_lens[src_bytes.bytesize] = true
                end
                idx += 1
              end
            end
          end
        end

        return nil if map.empty?
        {
          map: map,
          code_lengths: code_lens.keys.sort.reverse
        }
      rescue StandardError => e
        Logger.warn("PdfParser", "parse_tounicode_cmap failed: #{e.message}")
        nil
      end

      def unicode_hex_to_utf8(hex)
        h = hex.to_s.gsub(/[^0-9A-Fa-f]/, '')
        return "" if h.empty?
        h = "0#{h}" if h.length.odd?
        bytes = [h].pack('H*')

        begin
          txt = bytes.dup.force_encoding(Encoding::UTF_16BE).encode(
            Encoding::UTF_8,
            invalid: :replace,
            undef: :replace,
            replace: ''
          )
          return txt unless txt.empty?
        rescue StandardError => e
          Logger.warn("PdfParser", "unicode_hex_to_utf8 UTF-16BE conversion failed: #{e.message}")
        end

        bytes.encode(Encoding::UTF_8, Encoding::BINARY, invalid: :replace, undef: :replace, replace: '')
      rescue StandardError => e
        Logger.warn("PdfParser", "unicode_hex_to_utf8 failed: #{e.message}")
        ""
      end

      # ---------------------------------------------------------------
      # Object value parsing
      # ---------------------------------------------------------------
      def parse_object_value(raw, obj_num = nil)
        # Strip "X Y obj" prefix if present
        text = raw.sub(/\A\s*\d+\s+\d+\s+obj\s*/, '').sub(/\s*endobj\s*\z/, '').strip

        if text.start_with?('<<')
          return parse_dict_string(text)
        elsif text.start_with?('[')
          return parse_array_string(text)
        else
          return text
        end
      end

      # ---------------------------------------------------------------
      # Dictionary parsing
      # ---------------------------------------------------------------
      def extract_dict(text)
        start = text.index('<<')
        return '' unless start
        depth = 0
        i = start
        while i < text.length - 1
          if text[i, 2] == '<<'
            depth += 1
            i += 2
          elsif text[i, 2] == '>>'
            depth -= 1
            i += 2
            return text[start, i - start] if depth == 0
          else
            i += 1
          end
        end
        text[start..-1]
      end

      def parse_dict_string(text)
        tokenize_dict(extract_dict(text))
      end

      def tokenize_dict(text)
        dict = {}
        return dict unless text

        # Remove outer << >>
        inner = text.sub(/\A\s*<<\s*/, '').sub(/\s*>>\s*\z/, '')

        tokens = tokenize_pdf(inner)
        i = 0
        while i < tokens.length
          token = tokens[i]
          if token.start_with?('/')
            key = token
            i += 1
            value = collect_value(tokens, i)
            i = value[:next_index]
            dict[key] = value[:value]
          else
            i += 1
          end
        end
        dict
      end

      def parse_trailer_dict(text)
        dict_text = extract_dict(text)
        tokenize_dict(dict_text)
      end

      # ---------------------------------------------------------------
      # Array parsing
      # ---------------------------------------------------------------
      def parse_array_string(text)
        start = text.index('[')
        return [] unless start
        depth = 0
        i = start
        while i < text.length
          if text[i] == '['
            depth += 1
          elsif text[i] == ']'
            depth -= 1
            if depth == 0
              inner = text[start + 1...i]
              return tokenize_array(inner)
            end
          end
          i += 1
        end
        []
      end

      def tokenize_array(inner)
        tokens = tokenize_pdf(inner)
        result = []
        i = 0
        while i < tokens.length
          val = collect_value(tokens, i)
          result << val[:value]
          i = val[:next_index]
        end
        result
      end

      # ---------------------------------------------------------------
      # PDF tokenizer
      # ---------------------------------------------------------------
      def tokenize_pdf(text)
        tokens = []
        i = 0
        len = text.length

        while i < len
          c = text[i]

          # Skip whitespace
          if c =~ /[\s\x00]/
            i += 1
            next
          end

          # Comment
          if c == '%'
            eol = text.index(/[\r\n]/, i) || len
            i = eol + 1
            next
          end

          # Name
          if c == '/'
            j = i + 1
            while j < len && text[j] !~ /[\s\[\]<>(){}\/\%]/
              j += 1
            end
            tokens << text[i...j]
            i = j
            next
          end

          # String
          if c == '('
            depth = 1
            j = i + 1
            while j < len && depth > 0
              if text[j] == '(' && (j == 0 || text[j-1] != '\\')
                depth += 1
              elsif text[j] == ')' && (j == 0 || text[j-1] != '\\')
                depth -= 1
              end
              j += 1
            end
            tokens << text[i...j]
            i = j
            next
          end

          # Hex string
          if c == '<' && text[i+1] != '<'
            j = text.index('>', i) || len
            tokens << text[i..j]
            i = j + 1
            next
          end

          # Dict start
          if c == '<' && text[i+1] == '<'
            # Find matching >>
            depth = 1
            j = i + 2
            while j < len - 1 && depth > 0
              if text[j, 2] == '<<'
                depth += 1
                j += 2
              elsif text[j, 2] == '>>'
                depth -= 1
                j += 2
              else
                j += 1
              end
            end
            tokens << text[i...j]
            i = j
            next
          end

          # Array
          if c == '['
            depth = 1
            j = i + 1
            while j < len && depth > 0
              depth += 1 if text[j] == '['
              depth -= 1 if text[j] == ']'
              j += 1
            end
            tokens << text[i...j]
            i = j
            next
          end

          if c == ']'
            i += 1
            next
          end

          if c == '>' && text[i+1] == '>'
            i += 2
            next
          end

          # Number, keyword, or reference
          j = i
          while j < len && text[j] !~ /[\s\[\]<>(){}\/\%]/
            j += 1
          end
          tokens << text[i...j] if j > i
          i = j
        end

        tokens
      end

      def collect_value(tokens, index)
        return { value: nil, next_index: index + 1 } if index >= tokens.length

        token = tokens[index]

        # Check for indirect reference: "X Y R"
        if token =~ /\A\d+\z/ && index + 2 < tokens.length &&
           tokens[index + 1] =~ /\A\d+\z/ && tokens[index + 2] == 'R'
          ref = "#{token} #{tokens[index + 1]} R"
          return { value: ref, next_index: index + 3 }
        end

        # Nested dict
        if token.start_with?('<<')
          return { value: tokenize_dict(token), next_index: index + 1 }
        end

        # Array
        if token.start_with?('[')
          inner = token[1..-1]
          inner = inner.sub(/\]\z/, '') if inner.end_with?(']')
          return { value: tokenize_array(inner), next_index: index + 1 }
        end

        # Boolean / null
        return { value: true, next_index: index + 1 } if token == 'true'
        return { value: false, next_index: index + 1 } if token == 'false'
        return { value: nil, next_index: index + 1 } if token == 'null'

        # Number
        if token =~ /\A[+-]?\d*\.?\d+\z/
          return { value: token, next_index: index + 1 }
        end

        # Default: return as string
        { value: token, next_index: index + 1 }
      end

      # ---------------------------------------------------------------
      # Utility: dict coercion
      # ---------------------------------------------------------------
      def to_dict(obj)
        return obj if obj.is_a?(Hash)
        if obj.is_a?(String)
          if obj.include?('<<')
            return parse_dict_string(obj)
          end
        end
        nil
      end

      def parse_array_nums(val)
        if val.is_a?(Array)
          return val.map { |v| v.to_s.to_f }
        elsif val.is_a?(String)
          arr = parse_array_string(val)
          return arr.map { |v| v.to_s.to_f }
        end
        []
      end

      def parse_array_ints(val)
        parse_array_nums(val).map(&:to_i)
      end

    end
  end
end
