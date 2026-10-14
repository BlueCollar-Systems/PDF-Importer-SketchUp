# Exact original PDF TrueType empty-glyph delivery. Unicode whitespace, missing
# renderer output and a final-page crop are never proof of an empty glyph.
# Ruby 2.2 / SketchUp 2017 safe; no external helper or installed font lookup.
require 'json'
require 'digest'
require File.join(File.dirname(__FILE__), 'pdf_color_space')
require File.join(File.dirname(__FILE__), 'representation_fidelity')
require File.join(File.dirname(__FILE__), 'text_parser')

module BlueCollarSystems
  module PDFVectorImporter
    module SourceZeroInk
      extend self
      SCHEMA = 'bcs.sketchup.source_zero_ink/1'.freeze
      DELIVERY_SCHEMA = 'bcs.sketchup.zero_ink_delivery/1'.freeze
      DICTIONARY = 'BC_PDF_ZERO_INK'.freeze
      MAX_FONT_BYTES = 16 * 1024 * 1024
      MAX_CHARACTERS = 100_000
      class Unavailable < StandardError; end

      def canonical(value)
        case value
        when Hash
          value.keys.sort_by(&:to_s).each_with_object({}) do |key, out|
            raise Unavailable, 'duplicate JSON key' if out.key?(key.to_s)
            out[key.to_s] = canonical(value[key])
          end
        when Array then value.map { |entry| canonical(entry) }
        when Float
          raise Unavailable, 'nonfinite source value' unless value.finite?
          value
        when String, Integer, TrueClass, FalseClass, NilClass then value
        else raise Unavailable, 'unsupported source value'
        end
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
      end

      def finite_array(value, length)
        raise Unavailable, 'invalid source coordinate' unless value.is_a?(Array) &&
          value.length == length && value.all? { |v| v.is_a?(Numeric) && v.to_f.finite? && v.abs <= 1.0e12 }
        value.map(&:to_f)
      end

      # Only a genuinely absent glyf byte range qualifies in this first route.
      # A degenerate contour, unsupported font, malformed table, or failed parser
      # is unavailable, never an empty-outline success.
      class TrueTypeProgram
        attr_reader :sha256, :byte_size
        def initialize(bytes)
          @bytes = bytes
          raise Unavailable, 'invalid original font bytes' unless bytes.is_a?(String) &&
            bytes.bytesize >= 12 && bytes.bytesize <= MAX_FONT_BYTES && bytes[0, 4] == "\x00\x01\x00\x00".force_encoding(Encoding::BINARY)
          @sha256 = Digest::SHA256.hexdigest(bytes)
          @byte_size = bytes.bytesize
          @tables = {}
          count = u16(4, @bytes.bytesize)
          raise Unavailable, 'invalid font table inventory' unless count > 0 && count <= 4096 && 12 + count * 16 <= bytes.bytesize
          count.times do |index|
            at = 12 + index * 16
            name = bytes[at, 4]
            offset = u32(at + 8, bytes.bytesize)
            size = u32(at + 12, bytes.bytesize)
            raise Unavailable, 'invalid original font table range' if @tables.key?(name) || offset < 12 + count * 16 || offset + size > bytes.bytesize
            @tables[name] = [offset, size]
          end
          ranges = @tables.values.reject { |row| row[1] == 0 }.sort_by { |row| row[0] }
          ranges.each_cons(2) { |left,right| raise Unavailable, 'overlapping original font tables' if left[0] + left[1] > right[0] }
          ['head', 'maxp', 'loca', 'glyf', 'cmap', 'hhea', 'hmtx'].each { |name| raise Unavailable, 'original font table absent' unless @tables.key?(name) }
          head = @tables['head']; maxp = @tables['maxp']
          raise Unavailable, 'truncated source font metrics' if head[1] < 54 || maxp[1] < 6
          raise Unavailable, 'invalid original TrueType head' unless
            u32(head[0] + 12, head[0] + head[1]) == 0x5f0f3cf5 &&
            u16(head[0] + 18, head[0] + head[1]).between?(16, 16384)
          @glyph_count = u16(maxp[0] + 4, maxp[0] + maxp[1])
          hhea = @tables['hhea']; hmtx = @tables['hmtx']
          raise Unavailable, 'truncated original horizontal metrics' unless hhea[1] >= 36
          metrics = u16(hhea[0] + 34,hhea[0] + hhea[1])
          raise Unavailable, 'invalid original horizontal metrics' unless metrics > 0 && metrics <= @glyph_count && hmtx[1] >= metrics * 4 + (@glyph_count - metrics) * 2
          @loca_format = u16(head[0] + 50, head[0] + head[1])
          raise Unavailable, 'unsupported source loca' unless [0, 1].include?(@loca_format) && @glyph_count > 0
          width = @loca_format == 0 ? 2 : 4
          raise Unavailable, 'truncated source loca' if @tables['loca'][1] < (@glyph_count + 1) * width
          last_offset = 0
          (0..@glyph_count).each do |gid|
            at = @tables['loca'][0] + gid * width
            limit = @tables['loca'][0] + @tables['loca'][1]
            offset = @loca_format == 0 ? u16(at, limit) * 2 : u32(at, limit)
            raise Unavailable, 'invalid original loca inventory' if offset < last_offset || offset > @tables['glyf'][1]
            last_offset = offset
          end
          @cmaps = read_cmaps
          @code_cache = {}
        end

        def u16(at, limit)
          raise Unavailable, 'truncated source font table' unless at >= 0 && at + 2 <= limit && limit <= @bytes.bytesize
          @bytes[at, 2].unpack('n')[0]
        end
        def u32(at, limit)
          raise Unavailable, 'truncated source font table' unless at >= 0 && at + 4 <= limit && limit <= @bytes.bytesize
          @bytes[at, 4].unpack('N')[0]
        end

        def read_cmaps
          base, size = @tables['cmap']; limit = base + size
          count = u16(base + 2, limit)
          raise Unavailable, 'invalid original cmap inventory' unless count > 0 && count <= 256 && base + 4 + count * 8 <= limit
          (0...count).map do |index|
            at = base + 4 + index * 8
            platform = u16(at, limit); encoding = u16(at + 2, limit)
            sub = base + u32(at + 4, limit)
            format = u16(sub, limit)
            length = format == 12 ? u32(sub + 4, limit) : u16(sub + 2, limit)
            raise Unavailable, 'invalid original cmap range' unless sub >= base + 4 + count * 8 && length >= 6 && sub + length <= limit
            { :platform => platform, :encoding => encoding, :format => format, :at => sub, :limit => sub + length }
          end
        end

        def cmap_gid(table, code)
          at = table[:at]; limit = table[:limit]
          case table[:format]
          when 0
            raise Unavailable, 'truncated format 0 cmap' unless limit - at >= 262
            code <= 255 ? @bytes.getbyte(at + 6 + code) : 0
          when 6
            first = u16(at + 6, limit); count = u16(at + 8, limit)
            raise Unavailable, 'truncated format 6 cmap' unless at + 10 + count * 2 <= limit
            code >= first && code < first + count ? u16(at + 10 + (code - first) * 2, limit) : 0
          when 4
            twice = u16(at + 6, limit); count = twice / 2
            raise Unavailable, 'invalid format 4 cmap' unless twice > 0 && twice.even? && at + 16 + count * 8 <= limit
            ends = at + 14; starts = ends + twice + 2; deltas = starts + twice; ranges = deltas + twice
            found = []
            count.times do |index|
              first = u16(starts + index * 2, limit); last = u16(ends + index * 2, limit)
              raise Unavailable, 'descending source cmap segment' if first > last
              next unless code >= first && code <= last
              delta = u16(deltas + index * 2, limit); range = u16(ranges + index * 2, limit)
              gid = if range == 0
                      (code + delta) & 0xffff
                    else
                      raw = u16(ranges + index * 2 + range + (code - first) * 2, limit)
                      raw == 0 ? 0 : (raw + delta) & 0xffff
                    end
              found << gid
            end
            raise Unavailable, 'ambiguous source cmap segment' if found.uniq.length > 1
            found.first || 0
          when 12
            count = u32(at + 12, limit)
            raise Unavailable, 'truncated format 12 cmap' unless count <= 65536 && at + 16 + count * 12 <= limit
            found = []
            count.times do |index|
              row = at + 16 + index * 12
              first = u32(row, limit); last = u32(row + 4, limit); gid = u32(row + 8, limit)
              raise Unavailable, 'descending source cmap group' if first > last
              found << gid + code - first if code >= first && code <= last
            end
            raise Unavailable, 'ambiguous source cmap group' if found.uniq.length > 1
            found.first || 0
          else raise Unavailable, 'unsupported original cmap format'
          end
        end

        def glyph_for_code(code, encoding, flags)
          if encoding == '/WinAnsiEncoding'
            raise Unavailable, 'unproven WinAnsi character name' unless code == 32 && (flags & 32) != 0 && (flags & 4) == 0
          elsif encoding.nil?
            # ISO 32000-1 9.6.6.4: only the explicitly symbolic branch uses
            # direct source codes. A missing Encoding on a nonsymbolic font
            # does not make Mac/symbol cmap agreement authoritative.
            raise Unavailable, 'unproven symbolic source font' unless (flags & 4) != 0 && (flags & 32) == 0
          end
          key = [code, encoding, flags]
          return @code_cache[key] if @code_cache.key?(key)
          candidates = []; routes = []
          @cmaps.each do |table|
            platform = table[:platform]; enc = table[:encoding]
            if encoding == '/WinAnsiEncoding'
                        # This bounded route authenticates ASCII source spaces.
                        # The source byte is the encoding key; ToUnicode cannot
                        # substitute a different glyph by calling it a space.
                        next unless platform == 0 || (platform == 3 && [1, 10].include?(enc))
                        queries = [code]
                      elsif encoding.nil?
                        if platform == 1 && enc == 0
                          queries = [code]
                        elsif platform == 3 && enc == 0
                          queries = [symbol_prefix(table) + code]
                        else
                          next
                        end
                      else
                        raise Unavailable, 'unsupported PDF source encoding'
                      end
            gids = queries.map { |query| cmap_gid(table, query) }.reject { |gid| gid == 0 }.uniq
            raise Unavailable, 'missing or ambiguous original source glyph' unless gids.length == 1
            candidates.concat(gids)
            routes << [platform, enc, table[:format]]
          end
          raise Unavailable, 'original source glyph mapping unavailable' unless candidates.uniq.length == 1 && !routes.empty?
          gid = candidates.first
          raise Unavailable, 'source glyph outside original font' unless gid > 0 && gid < @glyph_count
          @code_cache[key] = [gid, routes]
        end

        def symbol_prefix(table)
          return table[:symbol_prefix] if table.key?(:symbol_prefix)
          at = table[:at]; limit = table[:limit]
          ranges = case table[:format]
                   when 0 then [[0,255]]
                   when 6
                     first = u16(at + 6, limit); count = u16(at + 8, limit)
                     count > 0 ? [[first,first + count - 1]] : []
                   when 4
                     twice = u16(at + 6, limit); count = twice / 2
                     raise Unavailable, 'invalid symbol cmap inventory' unless twice > 0 && twice.even? && at + 16 + count * 8 <= limit
                     ends = at + 14; starts = ends + twice + 2
                     (0...count).map { |i| [u16(starts + i * 2,limit),u16(ends + i * 2,limit)] }
                   when 12
                     count = u32(at + 12,limit)
                     raise Unavailable, 'invalid symbol cmap groups' unless count <= 1024 && at + 16 + count * 12 <= limit
                     (0...count).map { |i| [u32(at + 16 + i * 12,limit),u32(at + 20 + i * 12,limit)] }
                   else raise Unavailable, 'unsupported original symbol cmap'
                   end
          prefixes = []; visited = 0
          ranges.each do |first,last|
            raise Unavailable, 'unbounded original symbol cmap' if first > last || last - first > 255 || (visited += last - first + 1) > 1024
            (first..last).each do |code|
              next if cmap_gid(table,code) == 0
              prefix = code & ~255
              raise Unavailable, 'unsupported original symbol cmap range' unless [0,0xf000,0xf100,0xf200].include?(prefix)
              prefixes << prefix
            end
          end
          raise Unavailable, 'ambiguous original symbol cmap range' unless prefixes.uniq.length == 1
          table[:symbol_prefix] = prefixes.first
        end

        def empty_range(gid)
          base, size = @tables['loca']; limit = base + size
          first, last = if @loca_format == 0
                          [u16(base + gid * 2, limit) * 2, u16(base + (gid + 1) * 2, limit) * 2]
                        else
                          [u32(base + gid * 4, limit), u32(base + (gid + 1) * 4, limit)]
                        end
          raise Unavailable, 'invalid original glyph byte range' unless first <= last && last <= @tables['glyf'][1]
          first == last ? [first, last] : nil
        end
      end

      def qualify(parser, streams, item, page, pdf_sha, cache = {})
        return nil unless item.respond_to?(:text) && item.text.is_a?(String) &&
          !item.text.empty? && item.text.length <= MAX_CHARACTERS && item.text.each_char.all? { |char| char == ' ' } &&
          item.respond_to?(:source_decode_complete) && item.source_decode_complete == true &&
          item.respond_to?(:source_code_tokens) && item.source_code_tokens.is_a?(Array) && !item.source_code_tokens.empty?
        raise Unavailable, 'source PDF binding unavailable' unless pdf_sha.to_s =~ /\A[0-9a-f]{64}\z/ && page.is_a?(Integer) && page > 0
        position = item.source_paint_order
        raise Unavailable, 'source show operand location missing' unless position.is_a?(Array) && position.length == 2 && position.all? { |v| v.is_a?(Integer) && v >= 0 }
        stream = streams[position[0]]
        raise Unavailable, 'source show operand stream missing' unless stream.is_a?(String) && position[1] < stream.bytesize
        operand = item.source_show_operand
        operator = item.source_show_operator
        raise Unavailable, 'original source show operand missing' unless operand.is_a?(String) && !operand.empty? && ['Tj', 'TJ', "'", '"'].include?(operator) && stream[position[1], operator.length] == operator
        operand_end = position[1]
        operand_end -= 1 while operand_end > 0 && stream.getbyte(operand_end - 1).chr =~ /[\x00\t\r\n\f ]/
        operand_start = operand_end - operand.bytesize
        raise Unavailable, 'original source show bytes changed' unless operand_start >= 0 && stream[operand_start, operand.bytesize] == operand
        # Independently decode the bound original operand, not caller-provided
        # token metadata. Font-map equality is checked for every byte below.
        raw_parser = TextParser.new([], {})
        raw_parser.send(:begin_show_operation)
        if operator == 'TJ'
          raw_parser.send(:extract_tj_text, operand, item.font_name)
        else
          raw_parser.send(:decode_text_operand, operand, item.font_name)
        end
        original_tokens = raw_parser.instance_variable_get(:@pending_source_code_tokens)
        raise Unavailable, 'original source codes differ from extracted item' unless canonical(original_tokens) == canonical(item.source_code_tokens)
        scope = PdfColorSpace::ResourceScope.of(stream)
        raise Unavailable, 'source font resource scope missing' unless scope
        objects = PdfColorSpace::Objects.new(parser)
        font_ref = nil
        scope.chain_at(position[1]).each do |resources|
          fonts = objects.dict(resources['/Font'])
          if fonts && fonts.key?(item.font_name.to_s)
            font_ref = fonts[item.font_name.to_s]
            break
          end
        end
        raise Unavailable, 'source font reference missing' unless font_ref.is_a?(String) && font_ref =~ PdfColorSpace::REFERENCE
        font = objects.dict(font_ref)
        raise Unavailable, 'unsupported source font' unless font && font['/Subtype'] == '/TrueType'
        encoding = font['/Encoding']
        raise Unavailable, 'unsupported source encoding' unless encoding.nil? || encoding == '/WinAnsiEncoding'
        descriptor_ref = font['/FontDescriptor']
        raise Unavailable, 'original font descriptor reference missing' unless descriptor_ref.is_a?(String) && descriptor_ref =~ PdfColorSpace::REFERENCE
        descriptor = objects.dict(descriptor_ref)
        flags_raw = descriptor && descriptor['/Flags']
        raise Unavailable, 'original font flags unavailable' unless flags_raw.to_s =~ /\A\d+\z/
        flags = Integer(flags_raw)
        raise Unavailable, 'original font flags conflicting' unless flags.between?(0, 0xffffffff) && ((flags & 4) != 0) != ((flags & 32) != 0)
        program_ref = descriptor['/FontFile2']
        raise Unavailable, 'original TrueType program reference missing' unless program_ref.is_a?(String) && program_ref =~ PdfColorSpace::REFERENCE
        cached = cache[font_ref]
        unless cached
          program = parser.embedded_font_program(font)
          cached = [TrueTypeProgram.new(program), parser.send(:extract_font_to_unicode_map, font_ref)]
          cache[font_ref] = cached
        end
        program, mapping = cached
        raise Unavailable, 'original source decode map missing' unless mapping.is_a?(Hash) && mapping[:map].is_a?(Hash)
        first_char = Integer(font['/FirstChar'])
        widths = objects.array(font['/Widths'])
        raise Unavailable, 'original source widths missing' unless widths
        matrix = finite_array(item.source_text_matrix, 6)
        state = canonical(item.source_text_state)
        expected_keys = ['char_spacing', 'font_size', 'horizontal_scale', 'render_mode', 'rise', 'word_spacing']
        raise Unavailable, 'source text state unavailable' unless state.is_a?(Hash) && state.keys.sort == expected_keys && state.values.all? { |v| v.is_a?(Numeric) && v.to_f.finite? }
        raise Unavailable, 'unsupported source text state' unless state['font_size'] > 0 && state['horizontal_scale'] > 0 && state['render_mode'] == 0 && matrix[0] * matrix[3] - matrix[1] * matrix[2] != 0
        source_box = RepresentationFidelity.strict_source_bbox_pdf(item)
        cursor = 0.0; layout = []
        tokens = canonical(item.source_code_tokens)
        tokens.each do |token|
          raise Unavailable, 'source code token invalid' unless token.is_a?(Hash)
          if token.keys == ['adjustment']
            value = token['adjustment']
            raise Unavailable, 'invalid source text adjustment' unless value.is_a?(Numeric) && value.to_f.finite?
            cursor -= value * state['font_size'] * state['horizontal_scale'] / 1000.0
          elsif token.keys == ['raw_hex']
            raw = token['raw_hex']
            raise Unavailable, 'invalid original character codes' unless raw.is_a?(String) && raw =~ /\A(?:[0-9a-f]{2})+\z/
            [raw].pack('H*').each_byte do |code|
              byte = [code].pack('C')
              raise Unavailable, 'source decode is not an exact ASCII space' unless mapping[:map][byte] == ' '
              gid, glyph_routes = program.glyph_for_code(code, encoding, flags)
              range = program.empty_range(gid)
              return nil unless range
              width = widths[code - first_char] if code >= first_char
              width = Float(width)
              raise Unavailable, 'source glyph advance absent' unless width && width.finite? && width >= 0
              advance = (width * state['font_size'] / 1000.0 + state['char_spacing'] + (code == 32 ? state['word_spacing'] : 0)) * state['horizontal_scale']
              origin = [matrix[4] + cursor * matrix[0] + state['rise'] * matrix[2], matrix[5] + cursor * matrix[1] + state['rise'] * matrix[3]]
              layout << { 'index' => layout.length, 'text' => ' ', 'raw_code' => code,
                'glyph_id' => gid, 'glyph_byte_range' => range, 'advance' => advance,
                'source_width_1000_em' => width,
                'source_origin' => origin, 'cmap_routes' => glyph_routes }
              cursor += advance
            end
          else raise Unavailable, 'unknown source code token'
          end
        end
        raise Unavailable, 'incomplete source character coverage' unless layout.length == item.text.length
        proof = { 'schema' => SCHEMA, 'source_pdf_sha256' => pdf_sha, 'page' => page,
          'source_span_id' => RepresentationFidelity.source_span_id(item),
          'source_text' => item.text, 'source_text_sha256' => Digest::SHA256.hexdigest(item.text),
          'source_character_count' => layout.length, 'source_bbox_pdf' => source_box,
          'source_font_resource' => item.font_name.to_s, 'source_font_reference' => font_ref,
          'source_font_encoding' => encoding,
          'source_font_descriptor_reference' => descriptor_ref, 'source_font_descriptor_flags' => flags,
          'source_font_program_reference' => program_ref,
          'source_font_program_sha256' => program.sha256, 'source_font_program_bytes' => program.byte_size,
          'source_stream_sha256' => ((cache[:stream_digests] ||= {})[position[0]] ||= Digest::SHA256.hexdigest(stream)),
          'source_paint_order' => position, 'source_code_tokens' => tokens,
          'source_show_operator' => operator, 'source_operand_start' => operand_start,
          'source_operand_sha256' => Digest::SHA256.hexdigest(operand),
          'source_text_matrix' => matrix, 'source_text_state' => state,
          'source_character_layout' => layout, 'run_advance' => cursor,
          'proof_basis' => 'original_truetype_code_cmap_gid_empty_glyf_range' }
        proof['proof_sha256'] = digest(proof)
        verify_proof!(proof)
        proof
      rescue Unavailable, ArgumentError, TypeError, NoMethodError, RangeError
        nil
      end

      def verify_proof!(raw)
        proof = canonical(raw)
        sha = proof.delete('proof_sha256')
        fields = %w[schema source_pdf_sha256 page source_span_id source_text source_text_sha256 source_character_count source_bbox_pdf source_font_resource source_font_reference source_font_encoding source_font_descriptor_reference source_font_descriptor_flags source_font_program_reference source_font_program_sha256 source_font_program_bytes source_stream_sha256 source_paint_order source_code_tokens source_show_operator source_operand_start source_operand_sha256 source_text_matrix source_text_state source_character_layout run_advance proof_basis]
        raise Unavailable, 'zero-ink proof fields invalid' unless proof.keys.sort == fields.sort
        raise Unavailable, 'zero-ink proof digest invalid' unless sha.is_a?(String) && sha == digest(proof)
        raise Unavailable, 'zero-ink schema or basis invalid' unless proof['schema'] == SCHEMA && proof['proof_basis'] == 'original_truetype_code_cmap_gid_empty_glyf_range'
        ['source_pdf_sha256', 'source_font_program_sha256', 'source_text_sha256', 'source_stream_sha256', 'source_operand_sha256'].each { |key| raise Unavailable, 'zero-ink hash invalid' unless proof[key].is_a?(String) && proof[key] =~ /\A[0-9a-f]{64}\z/ }
        body = proof['source_text']; page = proof['page']; count = proof['source_character_count']
        raise Unavailable, 'zero-ink source identity invalid' unless page.is_a?(Integer) && page > 0 && proof['source_span_id'].is_a?(String) && proof['source_span_id'] =~ /\Atext_span:#{page}:\d+\z/ && body.is_a?(String) && !body.empty? && body.each_char.all? { |char| char == ' ' } && count.is_a?(Integer) && count == body.length && count <= MAX_CHARACTERS && Digest::SHA256.hexdigest(body) == proof['source_text_sha256']
        raise Unavailable, 'zero-ink original font identity invalid' unless proof['source_font_resource'].is_a?(String) && proof['source_font_resource'] =~ /\A\/[^\s]+\z/ && proof['source_font_reference'].is_a?(String) && proof['source_font_reference'] =~ PdfColorSpace::REFERENCE && proof['source_font_program_bytes'].is_a?(Integer) && proof['source_font_program_bytes'] >= 12 && proof['source_font_program_bytes'] <= MAX_FONT_BYTES
        box = finite_array(proof['source_bbox_pdf'], 4)
        raise Unavailable, 'zero-ink source bbox invalid' unless box[2] > box[0] && box[3] > box[1]
        position = proof['source_paint_order']
        raise Unavailable, 'zero-ink source operand location invalid' unless position.is_a?(Array) && position.length == 2 && position.all? { |v| v.is_a?(Integer) && v >= 0 }
        raise Unavailable, 'zero-ink source show evidence invalid' unless ['Tj', 'TJ', "'", '"'].include?(proof['source_show_operator']) && proof['source_operand_start'].is_a?(Integer) && proof['source_operand_start'] >= 0 && proof['source_operand_start'] < position[1]
        encoding = proof['source_font_encoding']
        raise Unavailable, 'zero-ink original encoding invalid' unless encoding.nil? || encoding == '/WinAnsiEncoding'
        ['source_font_descriptor_reference', 'source_font_program_reference'].each do |key|
          raise Unavailable, 'zero-ink original font reference invalid' unless proof[key].is_a?(String) && proof[key] =~ PdfColorSpace::REFERENCE
        end
        flags = proof['source_font_descriptor_flags']
        raise Unavailable, 'zero-ink original font flags invalid' unless flags.is_a?(Integer) && flags.between?(0, 0xffffffff) && ((flags & 4) != 0) != ((flags & 32) != 0)
        raise Unavailable, 'zero-ink original symbolic branch invalid' if encoding.nil? && ((flags & 4) == 0 || (flags & 32) != 0)
        raise Unavailable, 'zero-ink original WinAnsi branch invalid' if encoding == '/WinAnsiEncoding' && ((flags & 32) == 0 || (flags & 4) != 0)
        matrix = finite_array(proof['source_text_matrix'], 6)
        raise Unavailable, 'singular zero-ink source matrix' if matrix[0] * matrix[3] - matrix[1] * matrix[2] == 0
        layout = proof['source_character_layout']
        raise Unavailable, 'zero-ink character coverage invalid' unless layout.is_a?(Array) && layout.length == count
        state = proof['source_text_state']
        raise Unavailable, 'zero-ink source text state invalid' unless state.is_a?(Hash) && state.keys.sort == %w[char_spacing font_size horizontal_scale render_mode rise word_spacing] && state.values.all? { |v| v.is_a?(Numeric) && v.to_f.finite? } && state['font_size'] > 0 && state['horizontal_scale'] > 0 && state['render_mode'] == 0
        layout.each_with_index do |char, index|
          raise Unavailable, 'zero-ink character evidence invalid' unless char.is_a?(Hash) && char['index'] == index && char['index'].is_a?(Integer) && char['text'] == ' ' && char['raw_code'].is_a?(Integer) && char['raw_code'].between?(0, 255) && char['glyph_id'].is_a?(Integer) && char['glyph_id'] > 0 && char['glyph_byte_range'].is_a?(Array) && char['glyph_byte_range'].length == 2 && char['glyph_byte_range'].all? { |v| v.is_a?(Integer) && v >= 0 } && char['glyph_byte_range'][0] == char['glyph_byte_range'][1] && char['advance'].is_a?(Numeric) && char['advance'].to_f.finite? && char['cmap_routes'].is_a?(Array) && !char['cmap_routes'].empty? && char['cmap_routes'].all? { |row| row.is_a?(Array) && row.length == 3 && row.all? { |v| v.is_a?(Integer) && v >= 0 } }
          finite_array(char['source_origin'], 2)
          raise Unavailable, 'zero-ink original WinAnsi character invalid' if encoding == '/WinAnsiEncoding' && char['raw_code'] != 32
          raise Unavailable, 'zero-ink character fields invalid' unless char.keys.sort == %w[advance cmap_routes glyph_byte_range glyph_id index raw_code source_origin source_width_1000_em text]
          raise Unavailable, 'zero-ink original width invalid' unless char['source_width_1000_em'].is_a?(Numeric) && char['source_width_1000_em'].to_f.finite? && char['source_width_1000_em'] >= 0
          char['cmap_routes'].each do |row|
            applicable = if encoding == '/WinAnsiEncoding'
                           row[0] == 0 || (row[0] == 3 && [1, 10].include?(row[1]))
                         else
                           (row[0] == 1 && row[1] == 0) || (row[0] == 3 && row[1] == 0)
                         end
            raise Unavailable, 'zero-ink original cmap route invalid' unless applicable && [0, 4, 6, 12].include?(row[2])
          end
        end
        tokens = proof['source_code_tokens']
        raise Unavailable, 'zero-ink original tokens missing' unless tokens.is_a?(Array) && !tokens.empty?
        cursor = 0.0; index = 0
        tokens.each do |token|
          raise Unavailable, 'zero-ink original token invalid' unless token.is_a?(Hash)
          if token.keys == ['adjustment']
            value = token['adjustment']
            raise Unavailable, 'zero-ink original adjustment invalid' unless value.is_a?(Numeric) && value.to_f.finite?
            cursor -= value * state['font_size'] * state['horizontal_scale'] / 1000.0
          elsif token.keys == ['raw_hex']
            raw = token['raw_hex']
            raise Unavailable, 'zero-ink original code bytes invalid' unless raw.is_a?(String) && raw =~ /\A(?:[0-9a-f]{2})+\z/
            [raw].pack('H*').each_byte do |code|
              char = layout[index]
              raise Unavailable, 'zero-ink original code coverage mismatch' unless char && char['raw_code'] == code
              advance = (char['source_width_1000_em'] * state['font_size'] / 1000.0 + state['char_spacing'] + (code == 32 ? state['word_spacing'] : 0)) * state['horizontal_scale']
              origin = [matrix[4] + cursor * matrix[0] + state['rise'] * matrix[2], matrix[5] + cursor * matrix[1] + state['rise'] * matrix[3]]
              raise Unavailable, 'zero-ink original layout mismatch' unless char['advance'] == advance && char['source_origin'] == origin
              cursor += advance; index += 1
            end
          else raise Unavailable, 'zero-ink original token unknown'
          end
        end
        raise Unavailable, 'zero-ink run coverage/advance invalid' unless index == count && proof['run_advance'].is_a?(Numeric) && proof['run_advance'].to_f.finite? && proof['run_advance'] == cursor
        true
      end

      # An owned page group is already retained by its geometry. A blank-only
      # page uses one hidden construction point so SketchUp does not discard an
      # empty group during save. It owns no visible glyph ink or raster.
      class UncertainRollback < RepresentationFidelity::ContractError; end

      def persist!(group, proofs, requested_mode, layout)
        raise Unavailable, 'zero-ink page carrier unavailable' unless group &&
          RepresentationFidelity.entity_type(group) == 'Group' &&
          group.respond_to?(:set_attribute) && group.respond_to?(:get_attribute) &&
          group.respond_to?(:delete_attribute) && group.respond_to?(:entities) &&
          proofs.is_a?(Array) && !proofs.empty?
        owner = RepresentationFidelity.stable_entity_id(group)
        records = proofs.map do |proof|
          verify_proof!(proof)
          record = { 'schema' => DELIVERY_SCHEMA, 'status' => 'verified_zero_ink',
            'source_span_id' => proof['source_span_id'], 'page' => proof['page'],
            'requested_mode' => requested_mode.to_s, 'resulting_entity_ids' => [],
            'native_visible_entities_created' => 0, 'page_owner_id' => owner,
            'page_layout' => canonical(layout), 'source_proof' => canonical(proof) }
          record['delivery_sha256'] = digest(record)
          verify_delivery!(record, proof['source_pdf_sha256'], requested_mode, proof['page'])
          record
        end
        prior_raw = group.get_attribute(DICTIONARY, 'ledger_json')
        prior_sha = group.get_attribute(DICTIONARY, 'ledger_sha256')
        prior = prior_raw.nil? && prior_sha.nil? ? [] : verify_page!(group)
        ledger = prior + records
        ids = ledger.map { |record| record['source_span_id'] }
        raise Unavailable, 'duplicate zero-ink source span' unless ids.uniq.length == ids.length
        point = nil
        begin
          if group.entities.to_a.empty?
            raise Unavailable, 'blank page construction point API missing' unless group.entities.respond_to?(:add_cpoint)
            point = group.entities.add_cpoint([0.0, 0.0, 0.0])
            raise Unavailable, 'blank page carrier was not created' unless point &&
              point.respond_to?(:hidden=) && point.respond_to?(:set_attribute) &&
              point.respond_to?(:erase!) && point.respond_to?(:valid?)
            point.hidden = true
            raise Unavailable, 'blank page carrier is visible' unless point.respond_to?(:hidden?) && point.hidden? == true
            point.set_attribute(DICTIONARY, 'page_carrier', true)
          end
          group.set_attribute(DICTIONARY, 'ledger_json', JSON.generate(canonical(ledger)))
          group.set_attribute(DICTIONARY, 'ledger_sha256', digest(ledger))
          verify_page!(group, ledger)
          records
        rescue StandardError => error
          begin
            [['ledger_json', prior_raw], ['ledger_sha256', prior_sha]].each do |key, value|
              value.nil? ? group.delete_attribute(DICTIONARY, key) : group.set_attribute(DICTIONARY, key, value)
              raise Unavailable, 'page ledger restoration not verified' unless group.get_attribute(DICTIONARY, key) == value
            end
            if point && point.valid?
              point.erase!
              raise Unavailable, 'blank carrier cleanup not verified' if point.valid?
            end
          rescue StandardError => cleanup_error
            raise UncertainRollback, "zero-ink rollback uncertain: #{cleanup_error.message}"
          end
          raise error
        end
      end

      def verify_delivery!(raw, pdf_sha = nil, requested = nil, page = nil)
        record = canonical(raw); sha = record.delete('delivery_sha256')
        raise Unavailable, 'zero-ink delivery fields invalid' unless record.keys.sort == %w[native_visible_entities_created page page_layout page_owner_id requested_mode resulting_entity_ids schema source_proof source_span_id status]
        raise Unavailable, 'zero-ink delivery digest invalid' unless sha.is_a?(String) && sha == digest(record)
        proof = record['source_proof']; verify_proof!(proof)
        raise Unavailable, 'zero-ink delivery source binding invalid' unless record['schema'] == DELIVERY_SCHEMA && record['status'] == 'verified_zero_ink' && record['source_span_id'] == proof['source_span_id'] && record['page'] == proof['page'] && record['resulting_entity_ids'] == [] && record['native_visible_entities_created'] == 0 && record['native_visible_entities_created'].is_a?(Integer) && RepresentationFidelity.positive_entity_ids([record['page_owner_id']]) && RepresentationFidelity::MODES.include?(RepresentationFidelity.normalize_mode(record['requested_mode']))
        raise Unavailable, 'zero-ink delivery PDF/mode/page changed' if (pdf_sha && proof['source_pdf_sha256'] != pdf_sha) || (requested && record['requested_mode'] != requested.to_s) || (page && record['page'] != page)
        layout = record['page_layout']
        raise Unavailable, 'zero-ink page layout unavailable' unless layout.is_a?(Hash) && layout.keys.sort == ['media_box', 'page_rotation', 'scale', 'y_offset']
        finite_array(layout['media_box'], 4)
        raise Unavailable, 'zero-ink page layout invalid' unless layout['scale'].is_a?(Numeric) && layout['scale'].to_f.finite? && layout['scale'] > 0 && layout['y_offset'].is_a?(Numeric) && layout['y_offset'].to_f.finite? && layout['page_rotation'].is_a?(Integer) && [0, 90, 180, 270].include?(layout['page_rotation'])
        true
      end

      def verify_page!(group, expected = nil)
        raise Unavailable, 'zero-ink owner is not a durable page group' unless group &&
          RepresentationFidelity.entity_type(group) == 'Group' && group.respond_to?(:entities) &&
          !group.entities.to_a.empty?
        group.entities.to_a.each do |entity|
          next unless entity.respond_to?(:get_attribute) && entity.get_attribute(DICTIONARY, 'page_carrier') == true
          raise Unavailable, 'zero-ink page carrier is not nonpainting' unless
            RepresentationFidelity.entity_type(entity) == 'ConstructionPoint' &&
            entity.respond_to?(:hidden?) && entity.hidden? == true
        end
        raw = group.get_attribute(DICTIONARY, 'ledger_json')
        sha = group.get_attribute(DICTIONARY, 'ledger_sha256')
        raise Unavailable, 'zero-ink page ledger missing' unless raw.is_a?(String) && sha.is_a?(String)
        ledger = JSON.parse(raw)
        raise Unavailable, 'zero-ink page ledger digest invalid' unless ledger.is_a?(Array) && !ledger.empty? && digest(ledger) == sha && (expected.nil? || canonical(expected) == ledger)
        owner = RepresentationFidelity.stable_entity_id(group)
        seen = {}
        ledger.each do |record|
          verify_delivery!(record)
          id = record['source_span_id']
          raise Unavailable, 'zero-ink owner or source duplicate' if record['page_owner_id'] != owner || seen[id]
          seen[id] = true
        end
        ledger
      end
    end
  end
end
