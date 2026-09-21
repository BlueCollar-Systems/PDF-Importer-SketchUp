# bc_pdf_vector_importer/glyph_code_recovery.rb
# Recovers the characters of text a PDF delivers as raw glyph codes.
#
# The defect is described in glyph_code_report.rb: a /Type0 font with an
# Identity CMap and no /ToUnicode leaves the content stream holding glyph
# indices into an embedded subset, and nothing in the PDF says what they mean.
# Detection and reporting shipped first; this is the recovery.
#
# What it may do, per character, stopping at the first route that proves one:
#
#   1. embedded_cmap       - the subset's own cmap, reverse mapped.
#   2. post_glyph_name     - a real post table's names through the AGL or
#                            uniXXXX. Names synthesised from the glyph index
#                            (glyph00019) are fabricated from the very index
#                            being decoded and are never accepted.
#   3. outline_identity    - the subset glyph's contours, hashed and looked up
#                            in a reference face's outline -> character table.
#                            Exact structural equality, not similarity and not
#                            recognition: it matches point for point or not at
#                            all. The face is chosen by the PDF font's declared
#                            family, weight, width and slope; the PDF's own /W
#                            advance must agree; the match must be unambiguous.
#   4. blank_glyph_advance - a glyph the subset draws with no contours at all,
#                            whose advance is a reference face's space advance.
#                            Every empty outline hashes alike in every face, so
#                            this is a convention about width rather than the
#                            structural equality route 3 rests on, and it is
#                            named separately for that reason.
#
# There is no fifth route. No offsets, no standard-glyph-order assumption, no
# encoding guesses.
#
# Two rules govern everything else:
#
# * Substitution is ALL-OR-NOTHING per span. If one character of a span is
#   unproven the entire span is left exactly as it was delivered. A
#   half-recovered dimension reads as a measurement and is worse than raw
#   codes.
# * Nothing is ever presented as if the PDF had declared it. Every recovered
#   span records the route that proved it, and every unproven span records its
#   font, location and codes, so the operator can tell the difference.
#
# On the sheets this was built against the subsets carry neither a cmap nor a
# post table, so routes 1 and 2 recover nothing and route 3 does the work -
# which means the characters come from a face installed on THIS machine, not
# from the file. That is a real proof and it is not the same kind of proof as
# reading the document's own map, so the route is always reported.
# BCS_GLYPH_REFERENCE_FONTS overrides the search: a path-separated list of
# directories or files, or the single word "none" to switch it off entirely.
#
# Nothing here raises. A failure anywhere means "nothing is proven for that
# font", which is recorded and reported like any other unproven span.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'truetype_outlines')

module BlueCollarSystems
  module PDFVectorImporter
    module GlyphCodeRecovery

      TTF = TrueTypeOutlines

      ROUTE_EMBEDDED_CMAP = 'embedded_cmap'.freeze
      ROUTE_POST_NAME = 'post_glyph_name'.freeze
      ROUTE_OUTLINE_IDENTITY = 'outline_identity'.freeze
      ROUTE_BLANK_ADVANCE = 'blank_glyph_advance'.freeze

      # Codepoints a recovered character may be: what an engineering drawing
      # carries. Restricting the reference table to this set is what makes
      # "one unambiguous candidate" a test over characters a fabricator reads
      # rather than over every codepoint a system font happens to cover. Arial
      # draws Latin M, Greek Mu and Cyrillic Em identically; without this the
      # route would refuse almost every letter as ambiguous.
      DRAWING_EXTRAS = [
        0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022,
        0x2032, 0x2033, 0x2044, 0x2070, 0x2122, 0x2126, 0x2205,
        0x2206, 0x220F, 0x2211, 0x2212, 0x221A, 0x221E, 0x2220,
        0x2229, 0x222B, 0x2248, 0x2260, 0x2264, 0x2265, 0x25A0,
        0x25B2, 0x25CA, 0x2713
      ].freeze
      CANDIDATE_CODEPOINTS =
        ((0x20..0x7E).to_a + (0xA0..0xFF).to_a + DRAWING_EXTRAS).freeze

      # Private use areas. A cmap that "proves" one of these proves a picture,
      # not a character (the Wingdings case), so they are never accepted.
      PRIVATE_USE = [[0xE000, 0xF8FF], [0xF0000, 0xFFFFD], [0x100000, 0x10FFFD]].freeze

      # A PDF /W advance and a face advance are both in 1000-em units. One unit
      # of slack absorbs rounding; more would start accepting the wrong glyph.
      ADVANCE_TOLERANCE = 1.0

      # Style words inside a PostScript font name. They are identity, not
      # decoration: ArialNarrow must never be matched against Arial.
      WEIGHT_WORDS = %w[extrabold semibold demibold ultrabold bold black heavy
                        light thin book medium regular roman normal].freeze
      WIDTH_WORDS = %w[extracondensed semicondensed narrow condensed extended
                       expanded].freeze
      ITALIC_WORDS = %w[oblique italic].freeze
      FOUNDRY_SUFFIXES = %w[mt ps std pro itc adobe].freeze

      SYNTHETIC_NAME = /\Aglyph\d+\z/
      UNI_NAME = /\Auni([0-9A-Fa-f]{4,6})\z/
      U_NAME = /\Au([0-9A-Fa-f]{4,6})\z/
      SUBSET_PREFIX = /\A[A-Z]{6}\+/

      # Adobe Glyph List names, restricted to the candidate set above: a
      # name resolving outside it could not be accepted anyway. 215 names.
      GLYPH_NAMES = {
        'A' => 0x0041, 'AE' => 0x00C6, 'Aacute' => 0x00C1, 'Acircumflex' => 0x00C2,
        'Adieresis' => 0x00C4, 'Agrave' => 0x00C0, 'Aring' => 0x00C5, 'Atilde' => 0x00C3,
        'B' => 0x0042, 'C' => 0x0043, 'Ccedilla' => 0x00C7, 'D' => 0x0044, 'Delta' => 0x2206,
        'E' => 0x0045, 'Eacute' => 0x00C9, 'Ecircumflex' => 0x00CA, 'Edieresis' => 0x00CB,
        'Egrave' => 0x00C8, 'Eth' => 0x00D0, 'F' => 0x0046, 'G' => 0x0047, 'H' => 0x0048,
        'I' => 0x0049, 'Iacute' => 0x00CD, 'Icircumflex' => 0x00CE, 'Idieresis' => 0x00CF,
        'Igrave' => 0x00CC, 'J' => 0x004A, 'K' => 0x004B, 'L' => 0x004C, 'M' => 0x004D,
        'N' => 0x004E, 'Ntilde' => 0x00D1, 'O' => 0x004F, 'Oacute' => 0x00D3,
        'Ocircumflex' => 0x00D4, 'Odieresis' => 0x00D6, 'Ograve' => 0x00D2, 'Omega' => 0x2126,
        'Oslash' => 0x00D8, 'Otilde' => 0x00D5, 'P' => 0x0050, 'Q' => 0x0051, 'R' => 0x0052,
        'S' => 0x0053, 'T' => 0x0054, 'Thorn' => 0x00DE, 'U' => 0x0055, 'Uacute' => 0x00DA,
        'Ucircumflex' => 0x00DB, 'Udieresis' => 0x00DC, 'Ugrave' => 0x00D9, 'V' => 0x0056,
        'W' => 0x0057, 'X' => 0x0058, 'Y' => 0x0059, 'Yacute' => 0x00DD, 'Z' => 0x005A,
        'a' => 0x0061, 'aacute' => 0x00E1, 'acircumflex' => 0x00E2, 'acute' => 0x00B4,
        'adieresis' => 0x00E4, 'ae' => 0x00E6, 'agrave' => 0x00E0, 'ampersand' => 0x0026,
        'angle' => 0x2220, 'approxequal' => 0x2248, 'aring' => 0x00E5, 'asciicircum' => 0x005E,
        'asciitilde' => 0x007E, 'asterisk' => 0x002A, 'at' => 0x0040, 'atilde' => 0x00E3,
        'b' => 0x0062, 'backslash' => 0x005C, 'bar' => 0x007C, 'braceleft' => 0x007B,
        'braceright' => 0x007D, 'bracketleft' => 0x005B, 'bracketright' => 0x005D,
        'brokenbar' => 0x00A6, 'bullet' => 0x2022, 'c' => 0x0063, 'ccedilla' => 0x00E7,
        'cedilla' => 0x00B8, 'cent' => 0x00A2, 'colon' => 0x003A, 'comma' => 0x002C,
        'copyright' => 0x00A9, 'currency' => 0x00A4, 'd' => 0x0064, 'degree' => 0x00B0,
        'dieresis' => 0x00A8, 'divide' => 0x00F7, 'dollar' => 0x0024, 'e' => 0x0065,
        'eacute' => 0x00E9, 'ecircumflex' => 0x00EA, 'edieresis' => 0x00EB, 'egrave' => 0x00E8,
        'eight' => 0x0038, 'emdash' => 0x2014, 'emptyset' => 0x2205, 'endash' => 0x2013,
        'equal' => 0x003D, 'eth' => 0x00F0, 'exclam' => 0x0021, 'exclamdown' => 0x00A1,
        'f' => 0x0066, 'filledbox' => 0x25A0, 'five' => 0x0035, 'four' => 0x0034,
        'fraction' => 0x2044, 'g' => 0x0067, 'germandbls' => 0x00DF, 'grave' => 0x0060,
        'greater' => 0x003E, 'greaterequal' => 0x2265, 'guillemotleft' => 0x00AB,
        'guillemotright' => 0x00BB, 'h' => 0x0068, 'hyphen' => 0x002D, 'i' => 0x0069,
        'iacute' => 0x00ED, 'icircumflex' => 0x00EE, 'idieresis' => 0x00EF, 'igrave' => 0x00EC,
        'infinity' => 0x221E, 'integral' => 0x222B, 'intersection' => 0x2229, 'j' => 0x006A,
        'k' => 0x006B, 'l' => 0x006C, 'less' => 0x003C, 'lessequal' => 0x2264,
        'logicalnot' => 0x00AC, 'lozenge' => 0x25CA, 'm' => 0x006D, 'macron' => 0x00AF,
        'minus' => 0x2212, 'minute' => 0x2032, 'mu' => 0x00B5, 'multiply' => 0x00D7,
        'n' => 0x006E, 'nine' => 0x0039, 'notequal' => 0x2260, 'ntilde' => 0x00F1,
        'numbersign' => 0x0023, 'o' => 0x006F, 'oacute' => 0x00F3, 'ocircumflex' => 0x00F4,
        'odieresis' => 0x00F6, 'ograve' => 0x00F2, 'one' => 0x0031, 'onehalf' => 0x00BD,
        'onequarter' => 0x00BC, 'ordfeminine' => 0x00AA, 'ordmasculine' => 0x00BA,
        'oslash' => 0x00F8, 'otilde' => 0x00F5, 'p' => 0x0070, 'paragraph' => 0x00B6,
        'parenleft' => 0x0028, 'parenright' => 0x0029, 'percent' => 0x0025, 'period' => 0x002E,
        'periodcentered' => 0x00B7, 'plus' => 0x002B, 'plusminus' => 0x00B1,
        'product' => 0x220F, 'q' => 0x0071, 'question' => 0x003F, 'questiondown' => 0x00BF,
        'quotedbl' => 0x0022, 'quotedblleft' => 0x201C, 'quotedblright' => 0x201D,
        'quoteleft' => 0x2018, 'quoteright' => 0x2019, 'quotesingle' => 0x0027, 'r' => 0x0072,
        'radical' => 0x221A, 'registered' => 0x00AE, 's' => 0x0073, 'second' => 0x2033,
        'section' => 0x00A7, 'semicolon' => 0x003B, 'seven' => 0x0037, 'six' => 0x0036,
        'slash' => 0x002F, 'space' => 0x0020, 'sterling' => 0x00A3, 'summation' => 0x2211,
        't' => 0x0074, 'thorn' => 0x00FE, 'three' => 0x0033, 'threequarters' => 0x00BE,
        'trademark' => 0x2122, 'triagup' => 0x25B2, 'two' => 0x0032, 'u' => 0x0075,
        'uacute' => 0x00FA, 'ucircumflex' => 0x00FB, 'udieresis' => 0x00FC, 'ugrave' => 0x00F9,
        'underscore' => 0x005F, 'v' => 0x0076, 'w' => 0x0077, 'x' => 0x0078, 'y' => 0x0079,
        'yacute' => 0x00FD, 'ydieresis' => 0x00FF, 'yen' => 0x00A5, 'z' => 0x007A,
        'zero' => 0x0030,
      }.freeze

      # Reading 800-odd installed faces' name tables takes seconds, and a
      # document may resolve several fonts. Both caches are keyed on the file's
      # path, mtime and size, so a font replaced on disk is re-read.
      @style_cache = {}
      @table_cache = {}

      def self.clear_reference_cache
        @style_cache = {}
        @table_cache = {}
      end

      def self.cache_key(path)
        stat = File.stat(path)
        [path.to_s.downcase, stat.mtime.to_i, stat.size]
      rescue SystemCallError
        nil
      end

      def self.cached_style(path)
        key = cache_key(path)
        return @style_cache[key] if key && @style_cache.key?(key)
        value = nil
        begin
          face = TTF::Face.open(path)
          if face.outlines_readable?
            names = face.names
            family = (names[16] || names[1]).to_s
            subfamily = (names[17] || names[2]).to_s
            value = parse_font_style(family + '-' + subfamily)
          end
        rescue TTF::FontError, StandardError
          value = nil
        end
        @style_cache[key] = value if key
        value
      end

      def self.cached_outline_table(path)
        key = cache_key(path)
        return @table_cache[key] if key && @table_cache.key?(key)
        value = { :table => {}, :space => nil }
        begin
          face = TTF::Face.open(path)
          value = { :table => outline_table(face), :space => space_advance(face) }
        rescue TTF::FontError, StandardError
          value = { :table => {}, :space => nil }
        end
        @table_cache[key] = value if key
        value
      end

      module_function

      def private_use?(codepoint)
        PRIVATE_USE.any? { |lo, hi| codepoint >= lo && codepoint <= hi }
      end

      # ── the PDF font's declared style ──

      # "ABCDEF+Arial,Bold" -> {:family => 'arial', :bold => true, ...}
      def parse_font_style(base_font)
        name = base_font.to_s.sub(/\A\//, '').sub(SUBSET_PREFIX, '')
        name = name.tr('_', '-')
        lowered = name.downcase
        style = { :bold => false, :italic => false, :width => '' }
        tail = ''
        if lowered.include?(',')
          parts = lowered.split(',', 2)
          lowered = parts[0]
          tail = parts[1].to_s
        end
        if lowered.include?('-')
          parts = lowered.split('-', 2)
          lowered = parts[0]
          tail = tail + ' ' + parts[1].to_s
        end
        haystack = lowered + ' ' + tail

        WIDTH_WORDS.each do |w|
          if haystack.include?(w)
            style[:width] = w
            break
          end
        end
        ITALIC_WORDS.each { |w| style[:italic] = true if haystack.include?(w) }
        style[:bold] = true if haystack.include?('bold') || haystack.include?('black') ||
                               haystack.include?('heavy')

        family = lowered.dup
        (WIDTH_WORDS + ITALIC_WORDS + WEIGHT_WORDS).each do |w|
          family = family.gsub(w, '')
        end
        FOUNDRY_SUFFIXES.each { |s| family = family.sub(/#{s}\z/, '') }
        family = family.gsub(/[^a-z0-9]/, '')
        style[:family] = family
        style
      end

      # ── reference faces installed on this machine ──

      def reference_directories
        override = ENV['BCS_GLYPH_REFERENCE_FONTS'].to_s.strip
        return [] if override.downcase == 'none'
        unless override.empty?
          return override.split(File::PATH_SEPARATOR).reject { |p| p.to_s.empty? }
        end
        dirs = []
        windir = ENV['WINDIR'].to_s
        dirs << File.join(windir, 'Fonts') unless windir.empty?
        local = ENV['LOCALAPPDATA'].to_s
        unless local.empty?
          dirs << File.join(local, 'Microsoft', 'Windows', 'Fonts')
        end
        dirs << '/Library/Fonts' << '/System/Library/Fonts' << '/usr/share/fonts'
        dirs.select { |d| File.directory?(d) }
      end

      FONT_EXTENSIONS = %w[.ttf .ttc].freeze

      # Listed rather than globbed on purpose: Dir.glob treats a backslash as
      # an escape, so a Windows font directory ("C:\WINDOWS/Fonts") silently
      # matches nothing at all. This also makes the extension test
      # case-insensitive without globbing twice.
      def reference_font_files(directories)
        files = []
        Array(directories).each do |entry|
          if File.file?(entry)
            files << entry
            next
          end
          next unless File.directory?(entry)
          begin
            Dir.entries(entry).each do |name|
              next if name == '.' || name == '..'
              next unless FONT_EXTENSIONS.include?(File.extname(name).downcase)
              path = File.join(entry, name)
              files << path if File.file?(path)
            end
          rescue SystemCallError
            next
          end
        end
        files.uniq
      end

      # Faces on this machine whose family, weight, width and slope match the
      # PDF's declared font. A face that is not the right face matches nothing
      # and answers nothing, so a wrong match here costs a refusal, not a wrong
      # character - but it is still checked, because the outline table is what
      # the proof rests on.
      def reference_faces_for(style, directories = nil)
        dirs = directories.nil? ? reference_directories : directories
        out = []
        reference_font_files(dirs).each do |path|
          face_style = GlyphCodeRecovery.cached_style(path)
          next if face_style.nil?
          next unless face_style[:family] == style[:family]
          next unless face_style[:bold] == style[:bold]
          next unless face_style[:italic] == style[:italic]
          next unless face_style[:width] == style[:width]
          out << path
        end
        out
      end

      # {signature => {codepoint => advance}} over the candidate set only.
      def outline_table(face)
        table = {}
        cmap = face.character_map
        CANDIDATE_CODEPOINTS.each do |codepoint|
          gid = cmap[codepoint]
          next if gid.nil?
          begin
            signature = face.outline_signature(gid)
            next if signature.nil?
            next if signature == TTF::EMPTY_OUTLINE_SIGNATURE
            table[signature] ||= {}
            table[signature][codepoint] = face.advance(gid)
          rescue TTF::FontError, StandardError
            next
          end
        end
        table
      end

      # The space advance of a reference face, for route 4.
      def space_advance(face)
        gid = face.character_map[0x20]
        return nil if gid.nil?
        face.advance(gid)
      rescue StandardError
        nil
      end

      # One codepoint, or nil. The PDF's own advance has to agree, and where
      # several characters still agree exactly one printable ASCII candidate
      # resolves it - Arial draws hyphen-minus and soft hyphen identically, and
      # a drawing means the hyphen.
      def unambiguous_candidate(candidates, declared_width)
        return nil if candidates.nil? || candidates.empty?
        agreeing = candidates.keys.sort.select do |codepoint|
          advance = candidates[codepoint]
          declared_width.nil? || advance.nil? ||
            (advance - declared_width).abs <= ADVANCE_TOLERANCE
        end
        return nil if agreeing.empty?
        return agreeing[0] if agreeing.length == 1
        ascii = agreeing.select { |c| c >= 0x20 && c <= 0x7E }
        ascii.length == 1 ? ascii[0] : nil
      end

      # ── one embedded font, resolved once ──

      class FontProof
        attr_reader :reason, :routes, :looked_for

        # program        - the embedded font program bytes, or nil
        # base_font      - the PDF's /BaseFont
        # widths         - {glyph id => advance in 1000-em units} from /W
        # default_width  - /DW, or nil
        def initialize(program, base_font, widths = {}, default_width = nil,
                       directories = nil)
          @base_font = base_font.to_s
          @widths = widths.is_a?(Hash) ? widths : {}
          @default_width = default_width
          @characters = {}
          @routes = {}
          @reason = ''
          @looked_for = ''
          @subset = nil
          @tables = []
          @space_advances = []
          prepare(program, directories)
        end

        def prepare(program, directories)
          if program.nil? || program.to_s.empty?
            @reason = 'the PDF embeds no font program for this font'
            return
          end
          begin
            @subset = TTF::Face.new(program)
          rescue TTF::FontError => e
            @reason = "the embedded font program could not be read: #{e.message}"
            return
          end
          unless @subset.outlines_readable?
            @reason = 'the embedded font program carries no readable outlines ' \
                      '(a CFF/OpenType subset is not supported)'
            @subset = nil
            return
          end

          style = GlyphCodeRecovery.parse_font_style(@base_font)
          @looked_for = style[:family].to_s
          faces = GlyphCodeRecovery.reference_faces_for(style, directories)
          if faces.empty?
            # Routes 1 and 2 may still work; only 3 and 4 need a reference.
            @reason = "no reference face for #{@looked_for.inspect} is installed here"
          end
          faces.each do |path|
            built = GlyphCodeRecovery.cached_outline_table(path)
            @tables << built[:table] unless built[:table].empty?
            @space_advances << built[:space] unless built[:space].nil?
          end
        end

        def usable?
          !@subset.nil?
        end

        def declared_width(gid)
          w = @widths[gid]
          w.nil? ? @default_width : w
        end

        # [codepoint, route] or nil. Cached per glyph id per document.
        def character_for(gid)
          return nil unless usable?
          return @characters[gid] if @characters.key?(gid)
          @characters[gid] = resolve(gid)
        end

        def resolve(gid)
          [:embedded_cmap_route, :post_name_route, :outline_route, :blank_route].each do |m|
            begin
              hit = send(m, gid)
              return hit unless hit.nil?
            rescue TTF::FontError, StandardError
              next
            end
          end
          nil
        end

        def embedded_cmap_route(gid)
          @reverse_cmap ||= begin
            reverse = {}
            @subset.character_map.each do |cp, g|
              next if GlyphCodeRecovery.private_use?(cp)
              reverse[g] = cp if reverse[g].nil? || cp < reverse[g]
            end
            reverse
          end
          cp = @reverse_cmap[gid]
          cp.nil? ? nil : [cp, ROUTE_EMBEDDED_CMAP]
        end

        # Not implemented as a table read: this reader does not parse post
        # format 2.0 name arrays, and every subset measured carries no post
        # table at all. It is named here so the route list stays honest about
        # what exists rather than pretending the route ran.
        def post_name_route(_gid)
          nil
        end

        def outline_route(gid)
          return nil if @tables.empty?
          signature = @subset.outline_signature(gid)
          return nil if signature.nil?
          return nil if signature == TTF::EMPTY_OUTLINE_SIGNATURE
          width = declared_width(gid)
          candidates = {}
          @tables.each do |table|
            found = table[signature]
            next if found.nil?
            found.each { |cp, adv| candidates[cp] = adv if candidates[cp].nil? }
          end
          cp = GlyphCodeRecovery.unambiguous_candidate(candidates, width)
          cp.nil? ? nil : [cp, ROUTE_OUTLINE_IDENTITY]
        end

        # A glyph that draws nothing, whose advance is a space's. Every empty
        # outline hashes alike in every face, so this is a convention about
        # width and is reported on its own route.
        def blank_route(gid)
          return nil if @space_advances.empty?
          shape = @subset.contours(gid)
          return nil unless shape && shape.empty?
          width = declared_width(gid)
          return nil if width.nil?
          agrees = @space_advances.any? do |advance|
            (advance - width).abs <= ADVANCE_TOLERANCE
          end
          agrees ? [0x20, ROUTE_BLANK_ADVANCE] : nil
        end
      end

      # ── the public call ──

      # Recover one span's glyph ids. Returns nil when the span cannot be fully
      # proven - ALL OR NOTHING - otherwise [text, route] where route is the
      # weakest route any character needed.
      def recover_span(proof, glyph_ids)
        return nil if proof.nil? || !proof.usable?
        return nil if glyph_ids.nil? || glyph_ids.empty?
        out = String.new
        weakest = 0
        order = [ROUTE_EMBEDDED_CMAP, ROUTE_POST_NAME, ROUTE_OUTLINE_IDENTITY,
                 ROUTE_BLANK_ADVANCE]
        glyph_ids.each do |gid|
          hit = proof.character_for(gid)
          return nil if hit.nil?
          codepoint = hit[0]
          return nil if private_use?(codepoint)
          begin
            out << codepoint.chr(Encoding::UTF_8)
          rescue StandardError
            return nil
          end
          rank = order.index(hit[1]) || 0
          weakest = rank if rank > weakest
        end
        [out, order[weakest]]
      end

      # "0030003600100016" -> [0x30, 0x36, 0x10, 0x16]. An Identity CMap is two
      # bytes per code by definition, which is four hex digits.
      def glyph_ids_from_hex(hex)
        s = hex.to_s
        return [] if s.empty? || (s.length % 4) != 0
        out = []
        i = 0
        while i < s.length
          out << s[i, 4].to_i(16)
          i += 4
        end
        out
      end
    end
  end
end
