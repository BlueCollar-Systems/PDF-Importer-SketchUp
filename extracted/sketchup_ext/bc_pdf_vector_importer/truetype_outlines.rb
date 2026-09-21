# bc_pdf_vector_importer/truetype_outlines.rb
# A minimal TrueType reader: glyph outlines, advances, character map, names.
#
# This exists because recovering text a PDF delivers as raw glyph codes needs
# to compare the shapes an embedded subset draws against the shapes a known
# face draws, and this extension ships as an .rbz to machines that have neither
# fontTools nor Python. Everything here is pure Ruby 2.2.4 and stdlib only.
#
# Scope, deliberately small: the tables needed to answer "what shape does this
# glyph draw, how wide is it, and what character does this face call it".
# There is no rasteriser, no hinting, no CFF/OpenType outline support - a CFF
# face answers nothing and says so rather than guessing.
#
# The signature this produces only ever has to be consistent with ITSELF: it
# compares a subset against a reference face, both read by this same code, on
# one machine. It is not a wire format and nothing else consumes it.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'digest'

module BlueCollarSystems
  module PDFVectorImporter
    module TrueTypeOutlines

      # Raised for anything malformed. Callers treat it as "this font proves
      # nothing", never as an import failure.
      class FontError < StandardError; end

      # A glyph that draws nothing hashes to this in every face, so a match on
      # it is a convention about advance width, not structural equality.
      EMPTY_OUTLINE_SIGNATURE = Digest::SHA256.hexdigest('').freeze

      # Composite glyphs reference other glyphs. Real faces nest one or two
      # deep; anything beyond this is malformed or hostile.
      MAX_COMPOSITE_DEPTH = 5

      class Face
        attr_reader :units_per_em, :num_glyphs

        def initialize(bytes)
          @d = bytes.to_s.dup
          @d.force_encoding(Encoding::BINARY) if @d.respond_to?(:force_encoding)
          raise FontError, 'font is empty' if @d.bytesize < 12
          @tables = {}
          @signature_cache = {}
          read_directory
          read_head
          read_maxp
          read_loca
        end

        def self.open(path)
          new(File.open(path, 'rb') { |f| f.read })
        rescue SystemCallError => e
          raise FontError, "cannot read #{path}: #{e.message}"
        end

        def table?(tag)
          !@tables[tag].nil?
        end

        # A CFF face keeps its outlines somewhere this reader does not go.
        def outlines_readable?
          table?('glyf') && table?('loca') && !@loca.empty?
        end

        # ── byte readers (bounds-checked: a truncated table must raise, never
        #    silently read zeros and hash a wrong shape) ──

        def u8(o)
          b = @d.getbyte(o)
          raise FontError, "read past end of font at #{o}" if b.nil?
          b
        end

        def u16(o)
          (u8(o) << 8) | u8(o + 1)
        end

        def s16(o)
          v = u16(o)
          v >= 0x8000 ? v - 0x10000 : v
        end

        def u32(o)
          (u16(o) << 16) | u16(o + 2)
        end

        def f2dot14(o)
          s16(o) / 16384.0
        end

        # ── table directory ──

        def read_directory
          base = 0
          if @d[0, 4] == 'ttcf'
            raise FontError, 'empty font collection' if u32(8) < 1
            base = u32(12)
          end
          count = u16(base + 4)
          raise FontError, 'no tables' if count < 1
          count.times do |i|
            rec = base + 12 + i * 16
            tag = @d[rec, 4]
            break if tag.nil? || tag.bytesize < 4
            offset = u32(rec + 8)
            length = u32(rec + 12)
            next if offset >= @d.bytesize
            @tables[tag] = [offset, length]
          end
        end

        def read_head
          t = @tables['head']
          raise FontError, 'no head table' unless t
          @units_per_em = u16(t[0] + 18)
          raise FontError, 'unitsPerEm is zero' if @units_per_em.to_i <= 0
          @index_to_loc = s16(t[0] + 50)
        end

        def read_maxp
          t = @tables['maxp']
          raise FontError, 'no maxp table' unless t
          @num_glyphs = u16(t[0] + 4)
        end

        def read_loca
          @loca = []
          t = @tables['loca']
          return unless t
          o = t[0]
          begin
            if @index_to_loc == 0
              (@num_glyphs + 1).times { |i| @loca << u16(o + i * 2) * 2 }
            else
              (@num_glyphs + 1).times { |i| @loca << u32(o + i * 4) }
            end
          rescue FontError
            # A subset whose loca is cut short still answers for the glyphs it
            # kept. Whatever was read stands; the rest simply is not there.
          end
        end

        # ── outlines ──

        # nil when the glyph id is outside this font; [] when it draws nothing.
        def contours(gid, depth = 0)
          raise FontError, 'composite nesting too deep' if depth > MAX_COMPOSITE_DEPTH
          return nil if gid.nil? || gid < 0 || gid + 1 >= @loca.length
          glyf = @tables['glyf']
          return nil unless glyf
          start = @loca[gid]
          stop = @loca[gid + 1]
          return [] if stop <= start
          o = glyf[0] + start
          raise FontError, "glyph #{gid} runs past the font" if o + 10 > @d.bytesize
          count = s16(o)
          return composite_contours(o, depth) if count < 0
          simple_contours(o, count)
        end

        def simple_contours(o, count)
          ends = []
          count.times { |i| ends << u16(o + 10 + i * 2) }
          points = ends.empty? ? 0 : ends[-1] + 1
          instruction_length = u16(o + 10 + count * 2)
          p = o + 10 + count * 2 + 2 + instruction_length

          flags = []
          while flags.length < points
            f = u8(p)
            p += 1
            flags << f
            if (f & 8) != 0
              repeat = u8(p)
              p += 1
              repeat.times { flags << f }
            end
          end
          flags = flags[0, points]

          xs = []
          v = 0
          flags.each do |f|
            if (f & 2) != 0
              dx = u8(p)
              p += 1
              v += ((f & 16) != 0 ? dx : -dx)
            elsif (f & 16) == 0
              v += s16(p)
              p += 2
            end
            xs << v
          end

          ys = []
          v = 0
          flags.each do |f|
            if (f & 4) != 0
              dy = u8(p)
              p += 1
              v += ((f & 32) != 0 ? dy : -dy)
            elsif (f & 32) == 0
              v += s16(p)
              p += 2
            end
            ys << v
          end

          out = []
          first = 0
          ends.each do |last|
            break if last >= points
            contour = []
            (first..last).each do |i|
              contour << [xs[i].to_f, ys[i].to_f, (flags[i] & 1) != 0]
            end
            out << contour
            first = last + 1
          end
          out
        end

        # An accent is recorded as references to other glyphs, not as contours.
        # The references are followed so the shape compares as what it draws. A
        # component the subset no longer carries RAISES: half an outline must
        # never be hashed as if it were the whole glyph.
        def composite_contours(o, depth)
          p = o + 10
          out = []
          loop do
            flags = u16(p)
            index = u16(p + 2)
            p += 4
            if (flags & 1) != 0
              arg1 = s16(p)
              arg2 = s16(p + 2)
              p += 4
            else
              b1 = u8(p)
              b2 = u8(p + 1)
              p += 2
              arg1 = b1 > 127 ? b1 - 256 : b1
              arg2 = b2 > 127 ? b2 - 256 : b2
            end

            xx = 1.0
            xy = 0.0
            yx = 0.0
            yy = 1.0
            if (flags & 8) != 0
              xx = yy = f2dot14(p)
              p += 2
            elsif (flags & 0x40) != 0
              xx = f2dot14(p)
              yy = f2dot14(p + 2)
              p += 4
            elsif (flags & 0x80) != 0
              xx = f2dot14(p)
              xy = f2dot14(p + 2)
              yx = f2dot14(p + 4)
              yy = f2dot14(p + 6)
              p += 8
            end

            dx = 0.0
            dy = 0.0
            if (flags & 2) != 0 # ARGS_ARE_XY_VALUES; point matching is not supported
              dx = arg1.to_f
              dy = arg2.to_f
            end

            component = contours(index, depth + 1)
            if component.nil?
              raise FontError,
                    "composite component glyph #{index} is absent from this font"
            end
            component.each do |contour|
              out << contour.map do |x, y, on_curve|
                [xx * x + yx * y + dx, xy * x + yy * y + dy, on_curve]
              end
            end

            break if (flags & 0x20) == 0 # MORE_COMPONENTS
          end
          out
        end

        # Scale-normalised shape identity. Two faces that draw a character the
        # same way produce the same string here; anything else does not.
        def outline_signature(gid)
          cached = @signature_cache[gid]
          return cached unless cached.nil?
          shape = contours(gid)
          return nil if shape.nil?
          if shape.empty?
            @signature_cache[gid] = EMPTY_OUTLINE_SIGNATURE
            return EMPTY_OUTLINE_SIGNATURE
          end
          scale = 1000.0 / @units_per_em.to_f
          parts = []
          shape.each do |contour|
            parts << 'C'
            contour.each do |x, y, on_curve|
              parts << format('%.3f,%.3f,%d', x * scale, y * scale, on_curve ? 1 : 0)
            end
          end
          @signature_cache[gid] = Digest::SHA256.hexdigest(parts.join("\x1f"))
        end

        # ── advances, in 1000-em units to match a PDF's /W ──

        def advance(gid)
          hhea = @tables['hhea']
          hmtx = @tables['hmtx']
          return nil unless hhea && hmtx
          long = u16(hhea[0] + 34)
          return nil if long < 1
          index = gid < long ? gid : long - 1
          offset = hmtx[0] + index * 4
          return nil if offset + 2 > @d.bytesize
          u16(offset) * (1000.0 / @units_per_em.to_f)
        rescue FontError
          nil
        end

        # ── character map ──

        # {codepoint => glyph id}. Formats 4 and 12 only; a face offering
        # neither answers nothing rather than guessing.
        def character_map
          return @character_map unless @character_map.nil?
          @character_map = {}
          t = @tables['cmap']
          return @character_map unless t
          base = t[0]
          begin
            count = u16(base + 2)
            best = nil
            count.times do |i|
              rec = base + 4 + i * 8
              platform = u16(rec)
              encoding = u16(rec + 2)
              offset = u32(rec + 4)
              score = if platform == 3 && encoding == 10
                        5
                      elsif platform == 3 && encoding == 1
                        4
                      elsif platform == 0
                        3
                      else
                        1
                      end
              best = [score, base + offset] if best.nil? || score > best[0]
            end
            return @character_map if best.nil?
            read_cmap_subtable(best[1])
          rescue FontError
            @character_map = {}
          end
          @character_map
        end

        def read_cmap_subtable(o)
          case u16(o)
          when 4 then read_cmap_format4(o)
          when 12 then read_cmap_format12(o)
          end
        end

        def read_cmap_format4(o)
          seg_x2 = u16(o + 6)
          segments = seg_x2 / 2
          ends = o + 14
          starts = ends + seg_x2 + 2
          deltas = starts + seg_x2
          ranges = deltas + seg_x2
          segments.times do |i|
            last = u16(ends + i * 2)
            first = u16(starts + i * 2)
            delta = u16(deltas + i * 2)
            range_offset = u16(ranges + i * 2)
            next if first > last
            next if first == 0xFFFF && last == 0xFFFF
            (first..last).each do |cp|
              gid = if range_offset == 0
                      (cp + delta) & 0xFFFF
                    else
                      at = ranges + i * 2 + range_offset + (cp - first) * 2
                      next if at + 1 >= @d.bytesize
                      g = u16(at)
                      g == 0 ? 0 : (g + delta) & 0xFFFF
                    end
              @character_map[cp] = gid if gid && gid != 0
            end
          end
        end

        def read_cmap_format12(o)
          groups = u32(o + 12)
          groups.times do |i|
            g = o + 16 + i * 12
            first = u32(g)
            last = u32(g + 4)
            gid = u32(g + 8)
            next if first > last || last - first > 0x10FFFF
            (first..last).each { |cp| @character_map[cp] = gid + (cp - first) }
          end
        end

        # ── names ──

        # The typographic family and subfamily, for matching a PDF's declared
        # font against the faces installed here.
        def names
          return @names unless @names.nil?
          @names = {}
          t = @tables['name']
          return @names unless t
          o = t[0]
          begin
            count = u16(o + 2)
            storage = o + u16(o + 4)
            count.times do |i|
              rec = o + 6 + i * 12
              platform = u16(rec)
              encoding = u16(rec + 2)
              name_id = u16(rec + 6)
              length = u16(rec + 8)
              offset = u16(rec + 10)
              next unless [1, 2, 6, 16, 17].include?(name_id)
              raw = @d[storage + offset, length]
              next if raw.nil?
              text = decode_name(raw, platform, encoding)
              next if text.nil? || text.empty?
              @names[name_id] ||= text
            end
          rescue FontError
            @names = {}
          end
          @names
        end

        def decode_name(raw, platform, encoding)
          if platform == 3 || (platform == 0) || (platform == 2 && encoding == 1)
            # UTF-16BE
            out = String.new
            i = 0
            while i + 1 < raw.bytesize
              cp = (raw.getbyte(i) << 8) | raw.getbyte(i + 1)
              out << cp.chr(Encoding::UTF_8) if cp > 0 && cp < 0xD800
              i += 2
            end
            out
          else
            raw.dup.force_encoding(Encoding::UTF_8)
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
